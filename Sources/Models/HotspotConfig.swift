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

struct HotspotConfig: Identifiable, Equatable {
    var id = UUID()

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

// MARK: - Codable (password excluded)

// Custom Codable lives in an extension so the synthesized memberwise init
// stays available. The password is deliberately NEVER encoded: it lives in
// the Keychain (see ConfigStore), keyed by the hotspot's id. Decoding still
// accepts a `password` key so pre-Keychain configs load once and migrate.
extension HotspotConfig: Codable {

    private enum CodingKeys: String, CodingKey {
        case id, name, macAddress, vendor, username, password, customBaseURL
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        id            = try c.decode(UUID.self,          forKey: .id)
        name          = try c.decode(String.self,        forKey: .name)
        macAddress    = try c.decode(String.self,        forKey: .macAddress)
        vendor        = try c.decode(RouterVendor.self,  forKey: .vendor)
        username      = try c.decode(String.self,        forKey: .username)
        customBaseURL = try c.decodeIfPresent(String.self, forKey: .customBaseURL)

        // Legacy plain-text password (pre-Keychain storage). ConfigStore
        // migrates it to the Keychain on load, then re-persists without it.
        password      = try c.decodeIfPresent(String.self, forKey: .password) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)

        try c.encode(id,            forKey: .id)
        try c.encode(name,          forKey: .name)
        try c.encode(macAddress,    forKey: .macAddress)
        try c.encode(vendor,        forKey: .vendor)
        try c.encode(username,      forKey: .username)
        try c.encodeIfPresent(customBaseURL, forKey: .customBaseURL)
        // password intentionally not encoded — Keychain only.
    }
}
