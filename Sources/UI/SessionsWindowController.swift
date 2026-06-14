// SessionsWindowController.swift
// DataHawk
//
// Manages the Session History window as a singleton so that multiple clicks
// reuse the same window instead of opening duplicates.

import AppKit
import SwiftUI

final class SessionsWindowController: NSObject, NSWindowDelegate {
    static let shared = SessionsWindowController()

    private var window: NSWindow?

    private override init() {}

    // MARK: - Public API

    func show() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: SessionsView())
        // Prevent the hosting controller from auto-shrinking the window to the
        // SwiftUI view's ideal (content) size — we want to control the size.
        hosting.sizingOptions = []

        // Desired size: 30% wider and 10% taller than the previous default.
        // Cap at 92% of the screen's visible frame so we never overflow smaller
        // displays (e.g. 13″ MacBook Air or external monitors at low resolutions).
        let desired = NSSize(width: 1248, height: 748)
        let screen   = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let winSize  = NSSize(
            width:  min(desired.width,  screen.width  * 0.92),
            height: min(desired.height, screen.height * 0.92)
        )
        let minSize  = NSSize(width: 750, height: 540)

        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: winSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        win.title                        = "Hotspot WiFi Session History"
        win.titleVisibility              = .visible
        win.titlebarAppearsTransparent   = false
        win.contentViewController        = hosting
        win.isReleasedWhenClosed         = false
        win.delegate                     = self
        win.minSize               = minSize
        win.setContentSize(winSize)
        win.center()
        win.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)

        self.window = win
    }
}
