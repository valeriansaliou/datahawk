// NotificationManager.swift
// DataHawk
//
// Manages UNUserNotificationCenter authorization and dispatches alert
// notifications. Permission is never requested at launch; it is requested
// only when the user enables at least one notification option in Settings.
// Notifications fire on state *transitions* — not on every polling cycle —
// so the user is only alerted once per event, not repeatedly while the
// condition persists. They are also withdrawn again as soon as the condition
// clears (or the hotspot goes away), so a banner never outlives what it
// reported — the lid may have been shut while the alert was on screen.

@preconcurrency import UserNotifications
import Combine

@MainActor
final class NotificationManager {
    static let shared = NotificationManager()

    /// Withdrawable alert — see `checkNoSignal` and `watchTransitions`.
    private static let noSignalID = "com.datahawk.no-signal"

    private var cancellables: Set<AnyCancellable> = []

    private init() {}

    // MARK: - Public API

    func start() {
        watchPermissionRequest()
        watchTransitions()
    }

    // MARK: - Permission

    private func watchPermissionRequest() {
        let batteryEnabled = ConfigStore.shared.$notifyBatteryLow.filter { $0 }
        let signalEnabled = ConfigStore.shared.$notifyNoService.filter { $0 }

        Publishers.Merge(batteryEnabled, signalEnabled)
            .sink { [weak self] _ in
                // Fires synchronously on ConfigStore mutations (main-actor enforced).
                MainActor.assumeIsolated { self?.requestAuthorizationIfNeeded() }
            }
            .store(in: &cancellables)
    }

    private func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()

        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }

            center.requestAuthorization(options: [.alert, .sound]) { _, error in
                if let error {
                    print("[DataHawk] Notification authorization failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Transition watching

    private func watchTransitions() {
        AppState.shared.$metrics
            .scan((nil as RouterMetrics?, nil as RouterMetrics?)) { ($0.1, $1) }
            .sink { [weak self] previous, current in
                // Fires synchronously on AppState mutations (main-actor enforced).
                MainActor.assumeIsolated {
                    self?.checkBatteryLow(previous: previous, current: current)
                    self?.checkNoSignal(previous: previous, current: current)
                }
            }
            .store(in: &cancellables)

        // The no-signal alert is only meaningful while the hotspot is still
        // there. Leaving the network (bag closed, drove off, hotspot switched)
        // withdraws it rather than leaving a stale banner behind.
        AppState.shared.$connectionState
            .sink { state in
                MainActor.assumeIsolated {
                    guard state != .connected else { return }
                    NotificationManager.withdraw(id: Self.noSignalID)
                }
            }
            .store(in: &cancellables)
    }

    private func checkBatteryLow(previous: RouterMetrics?, current: RouterMetrics?) {
        guard ConfigStore.shared.notifyBatteryLow else { return }
        guard let current, current.isBatteryLow else { return }
        guard previous?.isBatteryLow != true else { return }

        send(
            id: "com.datahawk.battery-low",
            title: "Hotspot battery getting low",
            body: "Plug your router to power to stay connected."
        )
    }

    private func checkNoSignal(previous: RouterMetrics?, current: RouterMetrics?) {
        // Recovery withdraws the alert even if the option was turned off in the
        // meantime, so a delivered banner never outlives the condition.
        guard let current else { return }

        guard current.networkType == .noSignal else {
            Self.withdraw(id: Self.noSignalID)
            return
        }

        guard ConfigStore.shared.notifyNoService else { return }
        guard let previous, previous.networkType != .noSignal else { return }

        send(
            id: Self.noSignalID,
            title: "Cellular signal was lost",
            body: "You will be offline until your hotspot reconnects."
        )
    }

    // MARK: - Dispatch

    /// Pulls an already-delivered notification out of Notification Center (and
    /// cancels it if it somehow hasn't been delivered yet).
    private static func withdraw(id: String) {
        let center = UNUserNotificationCenter.current()

        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    private func send(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[DataHawk] Failed to deliver notification '\(id)': \(error.localizedDescription)")
            }
        }
    }
}
