// main.swift
// DataHawk
//
// Application entry point. This is the only file where top-level executable
// code is allowed. All further orchestration is driven by AppDelegate.

import AppKit

// Process entry runs on the main thread; assumeIsolated makes that explicit
// so the @MainActor-isolated AppDelegate can be constructed here.
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }

app.delegate = delegate
app.run()
