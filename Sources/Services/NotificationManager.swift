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

    /// One case per alert the app can raise. Every alert is condition-driven:
    /// raised on the rising edge, withdrawn as soon as the condition is false.
    private enum Alert: String, CaseIterable {
        case batteryLow = "com.datahawk.battery-low"
        case noSignal   = "com.datahawk.no-signal"
    }

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

        // Every alert describes the hotspot, so none of them survive losing it.
        // Leaving the network (bag closed, drove off, hotspot switched) also
        // means the last metrics are stale, so withdraw the lot.
        AppState.shared.$connectionState
            .sink { state in
                MainActor.assumeIsolated {
                    guard state != .connected else { return }
                    Self.withdrawAll()
                }
            }
            .store(in: &cancellables)
    }

    private func checkBatteryLow(previous: RouterMetrics?, current: RouterMetrics?) {
        guard let current else { return }

        evaluate(
            .batteryLow,
            wasActive: previous?.isBatteryLow ?? false,
            isActive: current.isBatteryLow,
            enabled: ConfigStore.shared.notifyBatteryLow,
            title: "Hotspot battery getting low",
            body: "Plug your router to power to stay connected."
        )
    }

    private func checkNoSignal(previous: RouterMetrics?, current: RouterMetrics?) {
        guard let current else { return }

        evaluate(
            .noSignal,
            // Treat "no previous sample" as already-active so the very first
            // fetch after connecting doesn't alert about a pre-existing outage.
            wasActive: previous.map { $0.networkType == .noSignal } ?? true,
            isActive: current.networkType == .noSignal,
            enabled: ConfigStore.shared.notifyNoService,
            title: "Cellular signal was lost",
            body: "You will be offline until your hotspot reconnects."
        )
    }

    // MARK: - Dispatch

    /// Raises `alert` on the rising edge of its condition and withdraws it once
    /// the condition clears. The withdrawal deliberately ignores `enabled`, so
    /// switching the option off mid-alert can't strand a delivered banner.
    private func evaluate(
        _ alert: Alert,
        wasActive: Bool,
        isActive: Bool,
        enabled: Bool,
        title: String,
        body: String
    ) {
        guard isActive else {
            Self.withdraw(alert)
            return
        }

        guard enabled, !wasActive else { return }

        send(alert, title: title, body: body)
    }

    /// Pulls an already-delivered notification out of Notification Center (and
    /// cancels it if it somehow hasn't been delivered yet).
    private static func withdraw(_ alert: Alert) {
        let center = UNUserNotificationCenter.current()

        center.removeDeliveredNotifications(withIdentifiers: [alert.rawValue])
        center.removePendingNotificationRequests(withIdentifiers: [alert.rawValue])
    }

    private static func withdrawAll() {
        Alert.allCases.forEach { withdraw($0) }
    }

    private func send(_ alert: Alert, title: String, body: String) {
        let id = alert.rawValue

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
