// StatusBarController.swift
// DataHawk
//
// Owns the NSStatusItem (menu-bar icon) and the NSPopover (dropdown panel).
// Coordinates WiFi monitoring, connection checks, and icon updates. This is
// the central "glue" between the system tray, AppState, and RouterService.

import AppKit
import SwiftUI
import Combine

class StatusBarController: NSObject, NSPopoverDelegate {

    // MARK: - Properties

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!

    /// Global monitor for clicks outside the popover (other tray icons, Dock).
    private var clickMonitor: Any?

    /// Local monitor for ESC key to dismiss the popover.
    private var keyMonitor: Any?

    /// KVO observer that keeps the popover pinned below the status-bar button
    /// whenever NSPopover resizes its window (e.g. during loading).
    private var frameObserver: NSKeyValueObservation?

    private let wifiMonitor  = WiFiMonitor()
    private var cancellables = Set<AnyCancellable>()

    /// Timer driving the blink animation while in the .loading state.
    private var blinkTimer: Timer?

    /// Phase accumulator for the sine-wave blink (0 -> 2pi per cycle).
    private var blinkPhase: CGFloat = 0

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

    // MARK: - Status item setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem.button else { return }

        button.image  = IconRenderer.icon(state: .noHotspot, networkType: nil)
        button.action = #selector(handleClick)
        button.target = self

        // Respond to both left- and right-click.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    // MARK: - Popover setup

    private func setupPopover() {
        popover = NSPopover()
        popover.contentViewController = NSHostingController(rootView: PopoverView())
        popover.behavior              = .applicationDefined
        popover.animates              = false
        popover.delegate              = self
    }

    /// Shows the popover anchored below the status-bar button.
    private func showPopover() {
        guard let button       = statusItem.button,
              let buttonWindow = button.window else { return }

        // Show at a temporary anchor — NSPopover positions incorrectly for
        // status items due to the flipped coordinate space.
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        // Reposition before the first render cycle so the popover sits
        // exactly below the button.
        if let popoverWindow = popover.contentViewController?.view.window {
            let buttonOnScreen = buttonWindow.convertToScreen(
                button.convert(button.bounds, to: nil)
            )

            // NSPopover computes X correctly (arrow points at the button).
            // Only fix Y to sit just below the button.
            let anchorX   = popoverWindow.frame.origin.x
            let anchorTop = (buttonOnScreen.minY - 5).rounded()
            let y         = (anchorTop - popoverWindow.frame.height).rounded()

            popoverWindow.setFrameOrigin(NSPoint(x: anchorX, y: y))

            // Re-lock Y whenever the popover resizes (e.g. content height
            // changes during loading). NSPopover recalculates its position
            // using the wrong anchor — pin the top edge so the arrow stays
            // attached to the button.
            frameObserver = popoverWindow.observe(
                \.frame, options: [.new]
            ) { [anchorX, anchorTop] win, change in
                guard let newFrame = change.newValue else { return }
                let expectedY = (anchorTop - newFrame.height).rounded()

                if abs(newFrame.origin.y - expectedY) > 0.5 {
                    win.setFrameOrigin(NSPoint(x: anchorX, y: expectedY))
                }
            }

            // Auto-focus the popover so keyboard events (ESC) work
            // without the user clicking inside first.
            NSApp.activate(ignoringOtherApps: true)
            popoverWindow.makeKey()

            // Re-apply button highlight after AppKit's mouseUp clears it.
            DispatchQueue.main.async { [weak self] in
                guard self?.popover.isShown == true else { return }
                self?.statusItem.button?.highlight(true)
            }
        }

        // Global monitor: catches clicks on other system UI (tray icons, Dock)
        // that .applicationDefined doesn't handle automatically.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.hidePopover()
        }

        // Local monitor: catches ESC key (not handled natively with
        // .applicationDefined behaviour).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {  // 53 = Escape
                self?.hidePopover()
                return nil
            }

            return event
        }
    }

    /// Closes the popover and tears down the click-away monitor.
    private func hidePopover() {
        popover.performClose(nil)

        // Note: remaining cleanup (key monitor, frame observer, highlight)
        // happens in popoverDidClose(_:) to handle all dismissal paths.
    }

    // MARK: - NSPopoverDelegate

    /// Single cleanup point for all popover dismissals (click-away, ESC,
    /// programmatic close). Removes event monitors and the frame observer.
    func popoverDidClose(_ notification: Notification) {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if let m = keyMonitor   { NSEvent.removeMonitor(m); keyMonitor   = nil }

        frameObserver?.invalidate()
        frameObserver = nil

        statusItem.button?.highlight(false)
    }

    // MARK: - State observer (icon updates)

    /// Subscribes to AppState changes and updates the status-bar icon
    /// whenever the connection state, network type, battery, or data usage
    /// changes.
    private func setupStateObserver() {
        Publishers.CombineLatest(
            Publishers.CombineLatest3(
                AppState.shared.$connectionState,
                AppState.shared.$metrics.map { $0?.networkType },
                AppState.shared.$metrics.map { m -> Bool in
                    guard let m, !m.isPluggedIn, let pct = m.batteryPercent else {
                        return false
                    }
                    return pct < m.batteryLowThreshold
                }
            ),
            AppState.shared.$metrics.map { $0?.isHighDataUsage == true }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] tuple, highDataUsage in
            let (state, networkType, batteryLow) = tuple

            self?.applyIcon(
                state: state,
                networkType: networkType,
                batteryLow: batteryLow,
                highDataUsage: highDataUsage
            )
        }
        .store(in: &cancellables)
    }

    /// Sets the status-bar icon for the current state. Manages the blink
    /// timer lifecycle (created on .loading, invalidated otherwise).
    private func applyIcon(
        state: ConnectionState,
        networkType: NetworkType?,
        batteryLow: Bool,
        highDataUsage: Bool
    ) {
        switch state {
        case .loading:
            // Start the smooth blink animation if not already running.
            guard blinkTimer == nil else { return }

            blinkPhase = 0
            statusItem.button?.image = IconRenderer.loadingIcon()

            let ticksPerCycle: CGFloat = 14

            blinkTimer = Timer.scheduledTimer(
                withTimeInterval: 0.1, repeats: true
            ) { [weak self] _ in
                guard let self else { return }

                self.blinkPhase += (2 * .pi) / ticksPerCycle

                // Sine wave oscillates opacity between 0.4 and 1.0.
                let t     = (sin(self.blinkPhase) + 1) / 2
                let alpha = 0.4 + t * 0.6

                self.statusItem.button?.image = IconRenderer.loadingIcon(alpha: alpha)
            }

        case .noHotspot, .disconnected, .failed, .connected:
            blinkTimer?.invalidate()
            blinkTimer = nil
            statusItem.button?.image = IconRenderer.icon(
                state: state,
                networkType: networkType,
                batteryLow: batteryLow,
                highDataUsage: highDataUsage
            )
        }
    }

    // MARK: - WiFi monitor

    /// Starts monitoring WiFi path changes and listens for the "settings
    /// closed" notification to re-check after the user edits a hotspot.
    private func setupWiFiMonitor() {
        wifiMonitor.onNetworkChange = { [weak self] in self?.checkConnection() }
        wifiMonitor.start()

        NotificationCenter.default.addObserver(
            forName: .datahawkSettingsDidClose,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkConnection()
        }

        NotificationCenter.default.addObserver(
            forName: .datahawkHidePopover,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hidePopover()
        }
    }

    // MARK: - Connection check

    /// Reads the current BSSID, looks it up in ConfigStore, and starts or
    /// stops RouterService accordingly. Called on WiFi changes, location
    /// permission grants, and settings-window close.
    func checkConnection() {
        let bssid = wifiMonitor.currentBSSID()
        let store = ConfigStore.shared
        let state = AppState.shared

        // Always publish the raw detection info for the disconnected view.
        state.detectedBSSID = bssid
        state.detectedSSID  = wifiMonitor.currentSSID()

        if let bssid, let hotspot = store.hotspot(forBSSID: bssid) {
            // Known hotspot detected — start polling if it's a new one.
            if state.activeHotspot?.id != hotspot.id {
                state.activeHotspot = hotspot
                state.metrics       = nil
                state.fetchError    = nil
                RouterService.shared.start(with: hotspot)
            }
        } else {
            // No known hotspot — tear down everything.
            if state.activeHotspot != nil || state.connectionState != .noHotspot {
                state.activeHotspot   = nil
                state.metrics         = nil
                state.fetchError      = nil
                state.connectionState = .noHotspot
                state.lastUpdated     = nil
                RouterService.shared.stop()
            }
        }
    }

    // MARK: - Click handler

    /// Handles left/right clicks on the status-bar button.
    /// Option-click opens the WiFi QR share sheet (if WiFi data is available).
    /// Normal click toggles the popover.
    @objc private func handleClick(_ sender: Any?) {
        // Option-click shortcut: show WiFi QR code.
        if NSEvent.modifierFlags.contains(.option) {
            if let m = AppState.shared.metrics, m.wifiEnabled,
               let ssid = m.wifiSSID, let pass = m.wifiPassphrase {
                WiFiQRWindowController.shared.show(ssid: ssid, passphrase: pass)
                return
            }
        }

        if popover.isShown {
            hidePopover()
        } else {
            checkConnection()
            showPopover()
        }
    }
}
