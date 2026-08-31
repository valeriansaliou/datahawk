// ResetDataUsageAlert.swift
// DataHawk
//
// Standard macOS alerts for the data usage counter reset: a confirmation
// before the write, and a failure alert if the router rejects it.
//
// `NSAlert` closes as soon as a button is clicked and offers no hook to keep
// it open, so progress cannot be shown on its buttons. Instead the write
// raises `AppState.isFetching`, which lights the popover's header spinner for
// its duration.

import AppKit

enum ResetDataUsageAlert {

    // MARK: - Public API

    /// Asks the user to confirm, then performs the reset.
    ///
    /// Runs the confirmation modally (returning to the caller before any
    /// network work starts), then detaches the write so the main run loop is
    /// never blocked on the router.
    @MainActor
    static func confirmAndReset() {
        let alert = NSAlert()

        alert.alertStyle      = .warning
        alert.messageText     = "Are you sure you want to reset your data usage counter?"
        alert.informativeText =
            "Your router should auto-reset your usage counter when a new billing period starts."

        // First button is the default (Return); Cancel also takes Escape.
        alert.addButton(withTitle: "Reset Counter")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.last?.keyEquivalent = "\u{1b}"

        // Brings the alert in front of the popover, which stays open behind it
        // (.applicationDefined behaviour means it doesn't dismiss itself).
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task { @MainActor in
            guard let failure = await RouterService.shared.resetDataUsage() else { return }

            showFailure(failure)
        }
    }

    // MARK: - Failure

    /// Reports a rejected reset. Separate alert rather than an inline banner:
    /// the confirmation is already gone by the time the router answers.
    @MainActor
    private static func showFailure(_ reason: String) {
        let alert = NSAlert()

        alert.alertStyle      = .critical
        alert.messageText     = "Could not reset data usage counter!"
        alert.informativeText = reason

        alert.addButton(withTitle: "OK")

        NSApp.activate(ignoringOtherApps: true)

        alert.runModal()
    }
}
