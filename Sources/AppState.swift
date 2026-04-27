import Foundation
import Combine

// MARK: - Connection state

enum ConnectionState: Equatable {
    case disconnected   // No WiFi or BSSID not in whitelist
    case loading        // Known hotspot; actively fetching first metrics
    case failed         // Known hotspot; initial fetch failed, no metrics yet
    case connected      // Metrics available
}

// MARK: - Network type

enum NetworkType: String, Codable {
    case fiveG    = "5G"
    case fourG    = "4G"
    case threeG   = "3G"
    case twoG     = "2G"
    case oneG     = "1G"
    case noSignal = "No Signal"
    case unknown  = "—"
}

// MARK: - Shared observable state

/// Single source of truth observed by the SwiftUI views and the status bar icon.
class AppState: ObservableObject {
    static let shared = AppState()

    @Published var connectionState: ConnectionState = .disconnected
    @Published var metrics: RouterMetrics?          = nil
    @Published var activeHotspot: HotspotConfig?    = nil
    @Published var lastUpdated: Date?               = nil
    @Published var fetchError: String?              = nil
    @Published var fetchingFromURL: String?         = nil
    @Published var isFetching: Bool                 = false
    /// Raw BSSID last seen by WiFiMonitor — shown in the UI when disconnected for debugging.
    @Published var detectedBSSID: String?           = nil
    @Published var detectedSSID: String?            = nil

    private init() {}
}
