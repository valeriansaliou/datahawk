// AppDelegate.swift
// DataHawk
//
// Handles application lifecycle: hides from the Dock, registers as a login
// item, boots the status-bar controller, and requests Location Services
// permission (required for BSSID detection on macOS 10.15+).

import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController!

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep the app out of the Dock even if Info.plist's LSUIElement was
        // somehow overridden at runtime.
        NSApp.setActivationPolicy(.accessory)

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
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusBarController.stop()
    }
}
