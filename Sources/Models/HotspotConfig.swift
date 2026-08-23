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
    /// Used to auto-detect when this hotspot is in range. May contain `*`
    /// wildcards to cover a range of BSSIDs with a single entry, e.g.
    /// "aa:bb:cc:dd:ee:*" for a router that hands out several BSSIDs.
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

    /// Normalised lower-case representation of the MAC address: hex digits and
    /// `*` wildcards only. Strips colons, dashes, and spaces so that
    /// "AA:BB:CC:DD:EE:FF", "aa-bb-cc-dd-ee-ff", and "aabbccddeeff" all
    /// compare equal.
    var normalizedMAC: String {
        HotspotConfig.normalizeMAC(macAddress)
    }

    /// True when the configured address is a glob pattern rather than one
    /// literal BSSID. Exact entries win over wildcards during lookup.
    var hasMACWildcard: Bool {
        normalizedMAC.contains("*")
    }

    /// Whether the given BSSID is covered by this hotspot's address pattern.
    func matches(bssid: String) -> Bool {
        HotspotConfig.glob(pattern: normalizedMAC,
                           matches: HotspotConfig.normalizeMAC(bssid))
    }

    /// Lower-cases and drops every character that isn't a hex digit or `*`.
    static func normalizeMAC(_ raw: String) -> String {
        raw.lowercased().filter { $0.isHexDigit || $0 == "*" }
    }

    /// Minimal glob matcher — `*` matches any run of characters (including
    /// none), every other character must match literally. Iterative with
    /// backtracking, so it stays linear-ish and never recurses deeply.
    static func glob(pattern: String, matches input: String) -> Bool {
        let p = Array(pattern)
        let s = Array(input)

        var pi = 0, si = 0
        var starPi = -1, starSi = 0

        while si < s.count {
            if pi < p.count, p[pi] == "*" {
                starPi = pi
                starSi = si
                pi += 1
            } else if pi < p.count, p[pi] == s[si] {
                pi += 1
                si += 1
            } else if starPi >= 0 {
                // Backtrack: let the last `*` swallow one more character.
                starSi += 1
                si = starSi
                pi = starPi + 1
            } else {
                return false
            }
        }

        // Trailing wildcards may still match the empty remainder.
        while pi < p.count, p[pi] == "*" { pi += 1 }

        return pi == p.count
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
