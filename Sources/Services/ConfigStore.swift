// ConfigStore.swift
// DataHawk
//
// Persists and exposes the list of known hotspot configurations and the
// user's options (refresh interval, etc.).
//
// Storage: UserDefaults with JSON-encoded payloads for everything except
// router passwords, which live in the Keychain (one generic-password item
// per hotspot, keyed by its UUID). Pre-Keychain configs that still carry a
// plain-text password in the JSON are migrated on first load: the password
// is written to the Keychain and the JSON is re-persisted without it.

import Foundation
import Combine
import ServiceManagement

@MainActor
final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    // MARK: - UserDefaults keys

    private let hotspotsKey              = "datahawk.hotspots.v1"
    private let refreshIntervalKey       = "datahawk.refreshInterval.v1"
    private let launchAtLoginKey         = "datahawk.launchAtLogin.v1"
    private let notifyBatteryLowKey      = "datahawk.notifyBatteryLow.v1"
    private let notifyNoServiceKey       = "datahawk.notifyNoService.v1"
    private let recordSessionHistoryKey  = "datahawk.recordSessionHistory.v1"
    private let maxSessionCountKey       = "datahawk.maxSessionCount.v1"

    // MARK: - Published state

    /// All configured hotspots. Automatically persisted on every mutation.
    @Published var hotspots: [HotspotConfig] = [] {
        didSet { persist() }
    }

    /// Whether to register as a login item. Defaults to true (auto-start on
    /// login). Persisted to UserDefaults; toggling calls SMAppService.
    @Published var launchAtLogin: Bool = true {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: launchAtLoginKey)

            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("[DataHawk] Login item update failed: \(error.localizedDescription)")
            }
        }
    }

    /// Whether to notify when the battery is low.
    @Published var notifyBatteryLow: Bool = false {
        didSet { UserDefaults.standard.set(notifyBatteryLow, forKey: notifyBatteryLowKey) }
    }

    /// Whether to notify when there is no cellular service.
    @Published var notifyNoService: Bool = false {
        didSet { UserDefaults.standard.set(notifyNoService, forKey: notifyNoServiceKey) }
    }

    /// Whether to record connection sessions (location, signal, data usage).
    /// Opt-out; defaults to true.
    @Published var recordSessionHistory: Bool = true {
        didSet { UserDefaults.standard.set(recordSessionHistory, forKey: recordSessionHistoryKey) }
    }

    /// Maximum number of sessions to retain. Oldest completed sessions are
    /// dropped automatically when this limit is exceeded. Defaults to 10,000.
    @Published var maxSessionCount: Int = 10_000 {
        didSet {
            let rounded = (maxSessionCount / 1_000) * 1_000
            let clamped = max(1_000, min(100_000, rounded))
            if clamped != maxSessionCount { maxSessionCount = clamped; return }
            UserDefaults.standard.set(maxSessionCount, forKey: maxSessionCountKey)
        }
    }

    /// Polling interval in seconds (clamped to 5–3600). Persisted to
    /// UserDefaults whenever the value changes.
    @Published var refreshInterval: Int = 60 {
        didSet {
            // Clamp to the allowed range. If the value was already in range
            // this is a no-op; otherwise we write back the clamped value
            // (which triggers didSet once more, but the second pass is a
            // no-op because the clamped value equals the stored value).
            let clamped = max(5, min(3600, refreshInterval))

            if clamped != refreshInterval {
                refreshInterval = clamped
                return
            }

            UserDefaults.standard.set(refreshInterval, forKey: refreshIntervalKey)
        }
    }

    // MARK: - Init

    private init() {
        load()
    }

    // MARK: - Lookup

    /// Finds the hotspot whose normalised MAC matches the given BSSID.
    /// Comparison is case-insensitive and ignores separators (colons, dashes).
    func hotspot(forBSSID bssid: String) -> HotspotConfig? {
        let normalised = bssid.lowercased().filter { $0.isHexDigit }
        return hotspots.first { $0.normalizedMAC == normalised }
    }

    // MARK: - Mutations

    func add(_ config: HotspotConfig) {
        hotspots.append(config)
    }

    func update(_ config: HotspotConfig) {
        guard let index = hotspots.firstIndex(where: { $0.id == config.id }) else { return }

        hotspots[index] = config
    }

    func remove(id: UUID) {
        KeychainStore.delete(account: Self.passwordAccount(id))
        hotspots.removeAll { $0.id == id }
    }

    // MARK: - Persistence (private)

    /// Keychain account name for a hotspot's admin password.
    private static func passwordAccount(_ id: UUID) -> String {
        "hotspot-password.\(id.uuidString)"
    }

    /// Encodes the current hotspot list to JSON (passwords excluded — see
    /// HotspotConfig's Codable) and writes it to UserDefaults; passwords go
    /// to the Keychain, one item per hotspot.
    private func persist() {
        guard let data = try? JSONEncoder().encode(hotspots) else { return }

        UserDefaults.standard.set(data, forKey: hotspotsKey)

        for hotspot in hotspots {
            if hotspot.password.isEmpty {
                KeychainStore.delete(account: Self.passwordAccount(hotspot.id))
            } else {
                KeychainStore.writeString(
                    hotspot.password, account: Self.passwordAccount(hotspot.id)
                )
            }
        }
    }

    /// Reads both hotspots and options from UserDefaults on launch.
    private func load() {
        // Hotspots. Passwords come from the Keychain; a non-empty password
        // decoded from the JSON is legacy plain-text storage — keeping it in
        // memory and assigning `hotspots` triggers persist(), which writes
        // it to the Keychain and strips it from UserDefaults (migration).
        if let data    = UserDefaults.standard.data(forKey: hotspotsKey),
           var decoded = try? JSONDecoder().decode([HotspotConfig].self, from: data) {
            for index in decoded.indices where decoded[index].password.isEmpty {
                decoded[index].password =
                    KeychainStore.readString(account: Self.passwordAccount(decoded[index].id)) ?? ""
            }

            hotspots = decoded
        }

        // Refresh interval (0 means "never stored" — keep the default).
        let stored = UserDefaults.standard.integer(forKey: refreshIntervalKey)

        if stored > 0 {
            refreshInterval = max(5, min(3600, stored))
        }

        // Launch at login (nil means "never stored" — default to true and register).
        if UserDefaults.standard.object(forKey: launchAtLoginKey) != nil {
            launchAtLogin = UserDefaults.standard.bool(forKey: launchAtLoginKey)
        } else {
            launchAtLogin = true  // first launch: enable and register
        }

        // Notification prefs (default false — no permission requested at launch).
        notifyBatteryLow = UserDefaults.standard.bool(forKey: notifyBatteryLowKey)
        notifyNoService  = UserDefaults.standard.bool(forKey: notifyNoServiceKey)

        // Session history (opt-out, default true — respect stored preference if set).
        if UserDefaults.standard.object(forKey: recordSessionHistoryKey) != nil {
            recordSessionHistory = UserDefaults.standard.bool(forKey: recordSessionHistoryKey)
        }

        // Max session count (0 means "never stored" — keep default of 10,000).
        let storedMax = UserDefaults.standard.integer(forKey: maxSessionCountKey)
        if storedMax > 0 { maxSessionCount = storedMax }
    }
}
