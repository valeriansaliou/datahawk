import AppKit
import SwiftUI
import Combine

/// Owns the NSStatusItem and the drop-down popover.
class StatusBarController: NSObject, NSPopoverDelegate {
    private var statusItem    : NSStatusItem!
    private var popover       : NSPopover!
    private var clickMonitor       : Any?
    private var frameObserver      : NSKeyValueObservation?

    private let wifiMonitor  = WiFiMonitor()
    private var cancellables = Set<AnyCancellable>()
    private var blinkTimer   : Timer?
    private var blinkPhase   : CGFloat = 0

    // MARK: - Lifecycle

    func start() {
        setupStatusItem()
        setupPopover()
        setupStateObserver()
        setupWiFiMonitor()
        checkConnection()
    }

    func stop() {
        wifiMonitor.stop()
        RouterService.shared.stop()
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

    // MARK: - Popover

    private func setupPopover() {
        popover = NSPopover()
        popover.contentViewController = NSHostingController(rootView: PopoverView())
        popover.behavior              = .applicationDefined
        popover.animates              = false
        popover.delegate              = self
    }

    private func showPopover() {
        guard
            let button       = statusItem.button,
            let buttonWindow = button.window
        else { return }

        // Show at a temporary anchor — NSPopover positions incorrectly for
        // status items due to the flipped coordinate space of NSStatusBarButton.
        // We grab its window right after and reposition using the same math
        // that works reliably for manual panel placement.
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        // Reposition before the first render cycle.
        if let popoverWindow = popover.contentViewController?.view.window {
            let buttonOnScreen = buttonWindow.convertToScreen(
                button.convert(button.bounds, to: nil)
            )
            // NSPopover computes X correctly (arrow points to button), but Y is
            // wrong due to the flipped coordinate space. Keep NSPopover's X and
            // only fix Y to sit just below the button.
            let anchorX = popoverWindow.frame.origin.x
            let anchorTop = (buttonOnScreen.minY - 5).rounded()   // top edge, stays fixed
            let y = (anchorTop - popoverWindow.frame.height).rounded()
            popoverWindow.setFrameOrigin(NSPoint(x: anchorX, y: y))

            // Whenever NSPopover resizes the window (content height changes during
            // loading), it recalculates position using its wrong anchor and jumps.
            // Re-lock Y after every frame change, keeping the top edge fixed so
            // the arrow always points to the button.
            frameObserver = popoverWindow.observe(\.frame, options: [.new]) { [anchorX, anchorTop] win, change in
                guard let newFrame = change.newValue else { return }
                let expectedY = (anchorTop - newFrame.height).rounded()
                if abs(newFrame.origin.y - expectedY) > 0.5 {
                    win.setFrameOrigin(NSPoint(x: anchorX, y: expectedY))
                }
            }

            // Auto-focus so keyboard events (and ESC) work without clicking first.
            NSApp.activate(ignoringOtherApps: true)
            popoverWindow.makeKey()
        }

        DispatchQueue.main.async { self.statusItem.button?.highlight(true) }

        // Global monitor catches clicks on system UI (other tray icons, Dock, etc.)
        // that NSPopover's .transient behavior misses because they run in a
        // separate process (SystemUIServer).
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in self?.hidePopover() }
    }

    private func hidePopover() {
        popover.performClose(nil)
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }

    private var isPopoverVisible: Bool { popover.isShown }

    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        frameObserver?.invalidate(); frameObserver = nil
    }

    // MARK: - State observer (icon updates)

    private func setupStateObserver() {
        Publishers.CombineLatest(
            Publishers.CombineLatest3(
                AppState.shared.$connectionState,
                AppState.shared.$metrics.map { $0?.networkType },
                AppState.shared.$metrics.map { m -> Bool in
                    guard let m, !m.isPluggedIn, let pct = m.batteryPercent else { return false }
                    return pct < m.batteryLowThreshold
                }
            ),
            AppState.shared.$metrics.map { $0?.isHighDataUsage == true }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] tuple, highDataUsage in
            let (state, networkType, batteryLow) = tuple
            self?.applyIcon(state: state, networkType: networkType, batteryLow: batteryLow, highDataUsage: highDataUsage)
        }
        .store(in: &cancellables)
    }

    private func applyIcon(state: ConnectionState, networkType: NetworkType?, batteryLow: Bool, highDataUsage: Bool) {
        switch state {
        case .loading:
            guard blinkTimer == nil else { return }
            blinkPhase = 0
            statusItem.button?.image = IconRenderer.loadingIcon()
            let ticksPerCycle: CGFloat = 14
            blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.blinkPhase += (2 * .pi) / ticksPerCycle
                let t     = (sin(self.blinkPhase) + 1) / 2
                let alpha = 0.4 + t * 0.6
                self.statusItem.button?.image = IconRenderer.loadingIcon(alpha: alpha)
            }
        case .failed:
            blinkTimer?.invalidate()
            blinkTimer = nil
            statusItem.button?.image = IconRenderer.icon(state: .disconnected, networkType: nil)
        case .disconnected, .connected:
            blinkTimer?.invalidate()
            blinkTimer = nil
            statusItem.button?.image = IconRenderer.icon(state: state, networkType: networkType, batteryLow: batteryLow, highDataUsage: highDataUsage)
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
        if isPopoverVisible {
            hidePopover()
        } else {
            checkConnection()
            showPopover()
        }
    }
}
