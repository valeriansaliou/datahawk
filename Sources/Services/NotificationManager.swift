// NotificationManager.swift
// DataHawk
//
// Manages UNUserNotificationCenter authorization and dispatches alert
// notifications. Permission is never requested at launch; it is requested
// only when the user enables at least one notification option in Settings.
// Notifications fire on state *transitions* — not on every polling cycle —
// so the user is only alerted once per event, not repeatedly while the
// condition persists.

import UserNotifications
import Combine

final class NotificationManager {
    static let shared = NotificationManager()

    private var cancellables: Set<AnyCancellable> = []

    private init() {}

    // MARK: - Public API

    func start() {
        watchPermissionRequest()
        watchBatteryLow()
        watchNoSignal()
    }

    // MARK: - Permission

    private func watchPermissionRequest() {
        ConfigStore.shared.$notifyBatteryLow
            .combineLatest(ConfigStore.shared.$notifyNoService)
            .sink { [weak self] batteryLow, noService in
                if batteryLow || noService {
                    self?.requestAuthorizationIfNeeded()
                }
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

    // MARK: - Battery low

    private func watchBatteryLow() {
        AppState.shared.$metrics
            .scan((nil as RouterMetrics?, nil as RouterMetrics?)) { ($0.1, $1) }
            .sink { [weak self] previous, current in
                self?.checkBatteryLow(previous: previous, current: current)
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

    // MARK: - No signal

    private func watchNoSignal() {
        AppState.shared.$metrics
            .scan((nil as RouterMetrics?, nil as RouterMetrics?)) { ($0.1, $1) }
            .sink { [weak self] previous, current in
                self?.checkNoSignal(previous: previous, current: current)
            }
            .store(in: &cancellables)
    }

    private func checkNoSignal(previous: RouterMetrics?, current: RouterMetrics?) {
        guard ConfigStore.shared.notifyNoService else { return }
        guard let previous, let current else { return }
        guard current.networkType == .noSignal, previous.networkType != .noSignal else { return }

        send(
            id: "com.datahawk.no-signal",
            title: "Cellular signal was lost",
            body: "You will be offline until your hotspot reconnects."
        )
    }

    // MARK: - Dispatch

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
