import AppKit
import SwiftUI

/// Opens (or brings to front) the settings window.
/// Uses a singleton so multiple clicks don't create multiple windows.
class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private override init() {}

    func show() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView())

        let win = NSWindow(
            contentRect : NSRect(x: 0, y: 0, width: 460, height: 360),
            styleMask   : [.titled, .closable, .miniaturizable],
            backing     : .buffered,
            defer       : false
        )
        win.title                    = "DataHawk — Settings"
        win.contentViewController    = hosting
        win.isReleasedWhenClosed     = false
        win.delegate                 = self
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = win
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Re-check the active connection after the user may have added/changed a hotspot.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .datahawkSettingsDidClose, object: nil)
        }
    }
}

extension Notification.Name {
    static let datahawkSettingsDidClose = Notification.Name("com.datahawk.settingsDidClose")
}
