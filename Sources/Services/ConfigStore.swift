import Foundation
import Combine

/// Persists and exposes the list of known hotspot configurations.
/// Storage: UserDefaults (JSON-encoded). Credentials are stored in plain text
/// for the MVP; migrate to Keychain before shipping publicly.
class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    private let defaultsKey = "datahawk.hotspots.v1"

    @Published var hotspots: [HotspotConfig] = [] {
        didSet { persist() }
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
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private func load() {
        guard
            let data    = UserDefaults.standard.data(forKey: defaultsKey),
            let decoded = try? JSONDecoder().decode([HotspotConfig].self, from: data)
        else { return }
        hotspots = decoded
    }
}
