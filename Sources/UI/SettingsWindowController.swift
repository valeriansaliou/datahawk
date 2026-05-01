// SettingsWindowController.swift
// DataHawk
//
// Manages the Settings window as a singleton so that multiple clicks reuse
// the same window instead of opening duplicates. Posts a notification when
// the window closes so StatusBarController can re-check the connection
// (the user may have added or changed a hotspot).

import AppKit
import SwiftUI

final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private override init() {}

    // MARK: - Public API

    /// Shows the settings window, or brings it to the front if already open.
    func show() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView())

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 440),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        win.title                 = "Manage known hotspots"
        win.contentViewController = hosting
        win.isReleasedWhenClosed  = false
        win.delegate              = self
        win.center()
        win.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)

        self.window = win
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Notify StatusBarController to re-check the active connection.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .datahawkSettingsDidClose, object: nil)
        }
    }
}

// MARK: - Custom notification

extension Notification.Name {
    /// Posted when the Settings window closes, signalling that hotspot
    /// configurations may have changed.
    static let datahawkSettingsDidClose = Notification.Name("com.datahawk.settingsDidClose")

    /// Posted when an action (open admin UI, show QR code) should immediately
    /// close the popover.
    static let datahawkHidePopover = Notification.Name("com.datahawk.hidePopover")
}
