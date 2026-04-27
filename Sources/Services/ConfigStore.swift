import Foundation
import Combine

/// Persists and exposes the list of known hotspot configurations.
/// Storage: UserDefaults (JSON-encoded). Credentials are stored in plain text
/// for the MVP; migrate to Keychain before shipping publicly.
class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    private let hotspotsKey       = "datahawk.hotspots.v1"
    private let refreshIntervalKey = "datahawk.refreshInterval.v1"

    @Published var hotspots: [HotspotConfig] = [] {
        didSet { persist() }
    }

    @Published var refreshInterval: Int = 60 {
        didSet {
            let clamped = max(5, min(3600, refreshInterval))
            if clamped != refreshInterval { refreshInterval = clamped; return }
            UserDefaults.standard.set(refreshInterval, forKey: refreshIntervalKey)
        }
    }

    private init() {
        load()
    }

    // MARK: - Lookup

    func hotspot(forBSSID bssid: String) -> HotspotConfig? {
        let key = bssid.lowercased().filter { $0.isHexDigit }
        print("[DataHawk] Looking up BSSID '\(key)' in \(hotspots.map { $0.normalizedMAC })")
        return hotspots.first { $0.normalizedMAC == key }
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

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(hotspots) else { return }
        UserDefaults.standard.set(data, forKey: hotspotsKey)
    }

    private func load() {
        if let data    = UserDefaults.standard.data(forKey: hotspotsKey),
           let decoded = try? JSONDecoder().decode([HotspotConfig].self, from: data) {
            hotspots = decoded
        }
        let stored = UserDefaults.standard.integer(forKey: refreshIntervalKey)
        if stored > 0 {
            refreshInterval = max(5, min(3600, stored))
        }
    }
}
