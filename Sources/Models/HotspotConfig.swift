import Foundation

// MARK: - Vendor

enum RouterVendor: String, Codable, CaseIterable, Identifiable {
    case netgear = "NETGEAR"

    var id: String { rawValue }
}

// MARK: - Hotspot configuration

struct HotspotConfig: Identifiable, Codable {
    var id            = UUID()
    /// Human-readable label, e.g. "Office M6 Pro"
    var name          : String
    /// BSSID of the access point as seen by CoreWLAN, e.g. "aa:bb:cc:dd:ee:ff"
    var macAddress    : String
    var vendor        : RouterVendor
    var username      : String
    var password      : String
    /// When nil the router gateway is auto-detected from the active route.
    var customBaseURL : String?

    /// Normalised lower-case hex digits only — strips colons, dashes, spaces.
    /// Allows matching regardless of separator style (aa:bb:.. vs AA-BB-..).
    var normalizedMAC: String {
        macAddress.lowercased().filter { $0.isHexDigit }
    }
}
