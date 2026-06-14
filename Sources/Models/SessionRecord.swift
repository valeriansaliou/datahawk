// SessionRecord.swift
// DataHawk
//
// Value types for a single hotspot connection session. Persisted as JSON by
// SessionStore. A session is "active" (endDate == nil) while the connection
// is live, and "completed" once the WiFi session with the router ends.

import Foundation
import CoreLocation

// MARK: - Location snapshot

struct SessionLocation: Codable {
    var latitude: Double
    var longitude: Double
    /// Human-readable locality from CLGeocoder, stored once at session open.
    var geocodedName: String?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Session record

struct SessionRecord: Identifiable, Codable {
    var id: UUID = UUID()
    var startDate: Date
    var endDate: Date?
    var hotspotName: String
    /// Normalised lower-case hex-only BSSID of the access point. Used to look
    /// up the current hotspot name from ConfigStore at display time.
    var hotspotBSSID: String?

    var location: SessionLocation?

    /// Carrier name (e.g. "Orange F").
    var provider: String?
    /// Cellular generation raw value (e.g. "5G", "4G").
    var generation: String?
    /// Whether the device was roaming at session open.
    var isRoaming: Bool?

    /// Billing-cycle GB counter snapshotted at session open.
    var dataStartGB: Double?
    /// Billing-cycle GB counter snapshotted at session close.
    var dataEndGB: Double?

    /// Signal bar readings (0–5) collected once per poll cycle.
    var signalSamples: [Int] = []

    // MARK: - Computed

    var isActive: Bool { endDate == nil }

    var duration: TimeInterval? {
        guard let end = endDate else { return nil }
        return end.timeIntervalSince(startDate)
    }

    var averageSignal: Double? {
        guard !signalSamples.isEmpty else { return nil }
        return Double(signalSamples.reduce(0, +)) / Double(signalSamples.count)
    }

    /// GB consumed during the session. Returns nil when the billing counter
    /// rolled over mid-session (end < start) or when either snapshot is missing.
    var dataUsedGB: Double? {
        guard let start = dataStartGB, let end = dataEndGB, end >= start else { return nil }
        return end - start
    }
}
