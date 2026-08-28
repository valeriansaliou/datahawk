// WiFiUsersWindowController.swift
// DataHawk
//
// Manages the WiFi users window as a singleton so repeated clicks reuse the
// same window instead of opening duplicates.

import AppKit
import SwiftUI

final class WiFiUsersWindowController: NSObject, NSWindowDelegate {
    static let shared = WiFiUsersWindowController()

    private var window: NSWindow?

    private override init() {}

    // MARK: - Public API

    func show() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: WiFiUsersView())
        hosting.sizingOptions = []

        let winSize = NSSize(width: 520, height: 300)
        let minSize = NSSize(width: 420, height: 220)

        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: winSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        win.title                      = "WiFi users"
        win.titleVisibility            = .visible
        win.titlebarAppearsTransparent = false
        win.contentViewController      = hosting
        win.isReleasedWhenClosed       = false
        win.delegate                   = self
        win.minSize                    = minSize
        win.setContentSize(winSize)
        win.center()
        win.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)

        self.window = win
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
