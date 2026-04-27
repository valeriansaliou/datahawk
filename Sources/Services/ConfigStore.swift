// ConfigStore.swift
// DataHawk
//
// Persists and exposes the list of known hotspot configurations and the
// user's options (refresh interval, etc.).
//
// Storage: UserDefaults with JSON-encoded payloads. Credentials are stored
// in plain text for the MVP; migrate to Keychain before shipping publicly.

import Foundation
import Combine

class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    // MARK: - UserDefaults keys

    private let hotspotsKey        = "datahawk.hotspots.v1"
    private let refreshIntervalKey = "datahawk.refreshInterval.v1"

    // MARK: - Published state

    /// All configured hotspots. Automatically persisted on every mutation.
    @Published var hotspots: [HotspotConfig] = [] {
        didSet { persist() }
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

        print("[DataHawk] Looking up BSSID '\(normalised)' in \(hotspots.map { $0.normalizedMAC })")

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
        hotspots.removeAll { $0.id == id }
    }

    // MARK: - Persistence (private)

    /// Encodes the current hotspot list to JSON and writes it to UserDefaults.
    private func persist() {
        guard let data = try? JSONEncoder().encode(hotspots) else { return }

        UserDefaults.standard.set(data, forKey: hotspotsKey)
    }

    /// Reads both hotspots and options from UserDefaults on launch.
    private func load() {
        // Hotspots
        if let data    = UserDefaults.standard.data(forKey: hotspotsKey),
           let decoded = try? JSONDecoder().decode([HotspotConfig].self, from: data) {
            hotspots = decoded
        }

        // Refresh interval (0 means "never stored" — keep the default).
        let stored = UserDefaults.standard.integer(forKey: refreshIntervalKey)

        if stored > 0 {
            refreshInterval = max(5, min(3600, stored))
        }
    }
}
