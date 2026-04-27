// HotspotConfig.swift
// DataHawk
//
// Persistent configuration for a single monitored hotspot. Stored as JSON in
// UserDefaults via ConfigStore. Each entry pairs a WiFi BSSID with the
// credentials and vendor needed to poll the router's admin API.

import Foundation

// MARK: - Router vendor

/// Supported router manufacturers. Each case maps to a concrete
/// `RouterProvider` implementation in the Providers directory.
enum RouterVendor: String, Codable, CaseIterable, Identifiable {
    case netgear = "NETGEAR"

    var id: String { rawValue }
}

// MARK: - Hotspot configuration

struct HotspotConfig: Identifiable, Codable {
    var id            = UUID()

    /// Human-readable label shown in the popover, e.g. "Office M6 Pro".
    var name: String

    /// BSSID of the access point as seen by CoreWLAN, e.g. "aa:bb:cc:dd:ee:ff".
    /// Used to auto-detect when this hotspot is in range.
    var macAddress: String

    /// Router manufacturer — determines which provider handles API calls.
    var vendor: RouterVendor

    /// Router admin username (typically "admin" for NETGEAR devices).
    var username: String

    /// Router admin password.
    var password: String

    /// Optional override for the router's admin URL. When `nil` the provider
    /// falls back to its default (e.g. "http://mywebui" for NETGEAR).
    var customBaseURL: String?

    /// Normalised lower-case hex-only representation of the MAC address.
    /// Strips colons, dashes, and spaces so that "AA:BB:CC:DD:EE:FF",
    /// "aa-bb-cc-dd-ee-ff", and "aabbccddeeff" all compare equal.
    var normalizedMAC: String {
        macAddress.lowercased().filter { $0.isHexDigit }
    }
}
