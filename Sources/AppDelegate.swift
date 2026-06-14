// AppDelegate.swift
// DataHawk
//
// Handles application lifecycle: hides from the Dock, registers as a login
// item, boots the status-bar controller, and requests Location Services
// permission (required for BSSID detection on macOS 10.15+).

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController!

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep the app out of the Dock even if Info.plist's LSUIElement was
        // somehow overridden at runtime.
        NSApp.setActivationPolicy(.accessory)

        // Accessory-policy apps have no default menu, so Cmd+V never reaches
        // text fields. Install a minimal menu with just Paste to wire it up.
        setupPasteMenu()

        // Boot the status-bar icon and begin monitoring WiFi.
        statusBarController = StatusBarController()
        statusBarController.start()

        // CoreWLAN's bssid() returns nil unless Location Services is granted.
        // Request permission now; once granted, re-check the active connection
        // so the hotspot is recognised without waiting for a WiFi event.
        LocationPermissionManager.shared.onAuthorizationChange = { [weak self] in
            DispatchQueue.main.async { self?.statusBarController.checkConnection() }
        }

        LocationPermissionManager.shared.requestIfNeeded()

        // Check for a newer release 5 s after launch (non-blocking).
        UpdateChecker.checkForUpdates()

        // Start watching notification prefs. Permission is only requested
        // when the user enables at least one alert in Settings.
        NotificationManager.shared.start()

        // Start session tracker. Only records data when the user opts in via
        // Settings → Options → Record session history.
        SessionTracker.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        SessionTracker.shared.closeOnTermination()
        statusBarController.stop()
    }

    // MARK: - Menu

    private func setupPasteMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        appItem.submenu = NSMenu()

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }
}
