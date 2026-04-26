import AppKit

// main.swift is the only file where top-level code is executed.
// Everything else is driven from AppDelegate.

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
