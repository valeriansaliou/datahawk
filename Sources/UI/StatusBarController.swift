import AppKit
import SwiftUI
import Combine

/// NSPanel subclass that can become key and swallows ESC.
private class KeyablePanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}

/// Owns the NSStatusItem and the drop-down panel.
/// We use a manually-positioned NSPanel instead of NSPopover so that we have
/// precise control over the vertical offset — NSPopover's window repositioning
/// (triggered by makeKey / size negotiation) caused a large gap on some setups.
class StatusBarController {
    private var statusItem   : NSStatusItem!
    private var panel        : KeyablePanel?
    private var panelVC      : NSHostingController<PopoverView>?
    private var sizingObserver: NSKeyValueObservation?
    private var clickMonitor : Any?

    private let wifiMonitor  = WiFiMonitor()
    private var cancellables = Set<AnyCancellable>()
    private var blinkTimer   : Timer?
    private var blinkPhase   : CGFloat = 0

    // MARK: - Lifecycle

    func start() {
        setupStatusItem()
        setupPanel()
        setupStateObserver()
        setupWiFiMonitor()
        checkConnection()
    }

    func stop() {
        wifiMonitor.stop()
        RouterService.shared.stop()
        sizingObserver?.invalidate()
        blinkTimer?.invalidate()
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.image  = IconRenderer.icon(state: .disconnected, networkType: nil)
        button.action = #selector(handleClick)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    // MARK: - Panel

    private func setupPanel() {
        let vc = NSHostingController(rootView: PopoverView())

        let win = KeyablePanel(
            contentRect : NSRect(x: 0, y: 0, width: 280, height: 320),
            styleMask   : [.borderless, .nonactivatingPanel],
            backing     : .buffered,
            defer       : false
        )
        win.onEscape = { [weak self] in self?.hidePanel() }
        win.contentViewController = vc
        win.isOpaque              = false
        win.backgroundColor       = .clear
        win.hasShadow             = true
        win.level                 = .popUpMenu
        win.collectionBehavior    = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Track SwiftUI's preferred size and resize the panel to match.
        sizingObserver = vc.observe(\.preferredContentSize, options: [.new]) { [weak win] _, change in
            guard let size = change.newValue, size.width > 0, size.height > 0 else { return }
            DispatchQueue.main.async { win?.setContentSize(size) }
        }

        panelVC = vc
        panel   = win
    }

    private func showPanel() {
        guard
            let panel        = panel,
            let button       = statusItem.button,
            let buttonWindow = button.window
        else { return }

        // Determine panel size — use SwiftUI's ideal size when available,
        // fall back to a sensible default for the very first display.
        let preferred = panelVC?.preferredContentSize ?? .zero
        let size = (preferred.width > 0 && preferred.height > 0)
            ? preferred
            : NSSize(width: 280, height: 320)

        panel.setContentSize(size)

        // Convert the button's bounds to screen coordinates.
        let buttonOnScreen = buttonWindow.convertToScreen(
            button.convert(button.bounds, to: nil)
        )

        // Centre the panel below the button, with a small gap below the menu bar.
        let x = (buttonOnScreen.midX - size.width / 2).rounded()
        let y = (buttonOnScreen.minY  - size.height - 5).rounded()

        panel.setFrameOrigin(NSPoint(x: x, y: y))
        // Activate the app so key events (ESC) are routed to our panel.
        // .accessory activation policy means no Dock icon appears.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // Show the active background on the status item (like WiFi / Bluetooth menus).
        // Deferred one run-loop tick so AppKit's own mouse-up reset fires first.
        DispatchQueue.main.async { self.statusItem.button?.highlight(true) }

        // Dismiss when the user clicks anywhere outside the panel.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.hidePanel()
        }
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        statusItem.button?.highlight(false)
    }

    private var isPanelVisible: Bool { panel?.isVisible ?? false }

    // MARK: - State observer (icon updates)

    private func setupStateObserver() {
        Publishers.CombineLatest3(
            AppState.shared.$connectionState,
            AppState.shared.$metrics.map { $0?.networkType },
            AppState.shared.$metrics.map { m -> Bool in
                guard let m, !m.isPluggedIn, let pct = m.batteryPercent else { return false }
                return pct < m.batteryLowThreshold
            }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] state, networkType, batteryLow in
            self?.applyIcon(state: state, networkType: networkType, batteryLow: batteryLow)
        }
        .store(in: &cancellables)
    }

    private func applyIcon(state: ConnectionState, networkType: NetworkType?, batteryLow: Bool) {
        switch state {
        case .loading:
            guard blinkTimer == nil else { return }
            blinkPhase = 0
            statusItem.button?.image = IconRenderer.loadingIcon()
            // 10 FPS, full sine cycle in ~1.4 s
            let ticksPerCycle: CGFloat = 14
            blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.blinkPhase += (2 * .pi) / ticksPerCycle
                // Oscillate between 0.25 and 1.0
                let t     = (sin(self.blinkPhase) + 1) / 2   // 0 → 1
                let alpha = 0.4 + t * 0.6
                self.statusItem.button?.image = IconRenderer.loadingIcon(alpha: alpha)
            }
        default:
            blinkTimer?.invalidate()
            blinkTimer = nil
            statusItem.button?.image = IconRenderer.icon(state: state, networkType: networkType, batteryLow: batteryLow)
        }
    }

    // MARK: - WiFi monitor

    private func setupWiFiMonitor() {
        wifiMonitor.onNetworkChange = { [weak self] in self?.checkConnection() }
        wifiMonitor.start()

        NotificationCenter.default.addObserver(
            forName: .datahawkSettingsDidClose,
            object  : nil,
            queue   : .main
        ) { [weak self] _ in self?.checkConnection() }
    }

    // MARK: - Connection check

    func checkConnection() {
        let bssid  = wifiMonitor.currentBSSID()
        let store  = ConfigStore.shared
        let state  = AppState.shared

        state.detectedBSSID = bssid
        state.detectedSSID  = wifiMonitor.currentSSID()

        if let bssid, let hotspot = store.hotspot(forBSSID: bssid) {
            if state.activeHotspot?.id != hotspot.id {
                state.activeHotspot = hotspot
                state.metrics       = nil
                state.fetchError    = nil
                RouterService.shared.start(with: hotspot)
            }
        } else {
            if state.activeHotspot != nil || state.connectionState != .disconnected {
                state.activeHotspot   = nil
                state.metrics         = nil
                state.fetchError      = nil
                state.connectionState = .disconnected
                state.lastUpdated     = nil
                RouterService.shared.stop()
            }
        }
    }

    // MARK: - Click handler

    @objc private func handleClick(_ sender: Any?) {
        if isPanelVisible {
            hidePanel()
        } else {
            checkConnection()
            showPanel()
        }
    }
}
