// AppState.swift
// DataHawk
//
// Single source of truth for all runtime state. SwiftUI views and the
// status-bar icon observe this object via Combine's @Published properties.
// All mutations MUST happen on the main thread (enforced by callers via
// DispatchQueue.main or MainActor.run).

import Foundation
import Combine

// MARK: - Connection state machine

/// Represents the lifecycle of a hotspot connection from detection to data
/// availability. The status-bar icon and popover header both derive their
/// appearance from this value.
enum ConnectionState: Equatable {
    /// No WiFi network, or the current BSSID is not in the configured list.
    case noHotspot
    /// A known hotspot was detected but no fetch has been attempted yet.
    case disconnected
    /// A known hotspot was detected; the first metrics fetch is in progress.
    case loading
    /// A known hotspot was detected but the initial fetch failed (no data yet).
    case failed
    /// At least one successful fetch has completed — metrics are available.
    case connected

    /// `true` when a known hotspot is in range (either connected, attempting,
    /// or failed). `false` only for `.noHotspot`.
    var isHotspotKnown: Bool {
        self != .noHotspot
    }
}

// MARK: - Network type

/// Cellular generation reported by the router, used for the status-bar badge
/// and the popover header pill.
enum NetworkType: String, Codable {
    case fiveG    = "5G"
    case fourG    = "4G"
    case threeG   = "3G"
    case twoG     = "2G"
    case oneG     = "1G"
    case noSignal = "No Signal"
    case unknown  = "Unknown"
}

// MARK: - Shared observable state

/// Singleton holding every piece of live state that the UI needs. Properties
/// are grouped by concern: connection lifecycle, fetched metrics, and raw
/// WiFi detection info (shown in the disconnected view for debugging).
final class AppState: ObservableObject {
    static let shared = AppState()

    // -- Connection lifecycle --------------------------------------------------

    @Published var connectionState: ConnectionState = .noHotspot
    @Published var activeHotspot: HotspotConfig?
    @Published var lastUpdated: Date?

    // -- Fetched metrics -------------------------------------------------------

    @Published var metrics: RouterMetrics?
    @Published var fetchError: String?
    @Published var fetchingFromURL: String?
    @Published var isFetching: Bool = false

    // -- Raw WiFi detection (debugging) ----------------------------------------

    /// BSSID last seen by WiFiMonitor — displayed when disconnected so the user
    /// can copy it into the Settings form.
    @Published var detectedBSSID: String?
    @Published var detectedSSID: String?

    // -- Updates ---------------------------------------------------------------

    /// Non-nil when a newer release DMG is available for download. Set by
    /// UpdateChecker; cleared after a successful install by UpdateInstaller.
    @Published var updateDownloadURL: String?

    private init() {}
}
