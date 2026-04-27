// main.swift
// DataHawk
//
// Application entry point. This is the only file where top-level executable
// code is allowed. All further orchestration is driven by AppDelegate.

import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()

app.delegate = delegate
app.run()
