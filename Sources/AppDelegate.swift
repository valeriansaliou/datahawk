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
    }

    func applicationWillTerminate(_ notification: Notification) {
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
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")

        NSApp.mainMenu = mainMenu
    }
}
