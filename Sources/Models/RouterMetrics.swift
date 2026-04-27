import Foundation

struct RouterMetrics {
    /// Cellular generation (5G, 4G, …)
    var networkType    : NetworkType
    /// Raw technology string from the API, e.g. "5GSUB6", "LteService"
    var technology        : String
    /// Connection status from the API, e.g. "Connected", "Connecting"
    var connectionStatus  : String
    /// Signal bars 0–5
    var signalStrength : Int
    /// Carrier name, e.g. "Orange F", "Verizon"
    var provider       : String
    /// Bytes consumed in the current billing period (nil = unknown)
    var dataUsedGB     : Double?
    /// Billing period cap (nil = unlimited / unknown)
    var dataLimitGB    : Double?
    /// nil when the device has no battery
    var batteryPercent        : Int?
    /// true when actively charging (battery present, on AC)
    var isCharging            : Bool
    /// true when device has no battery slot (always on AC)
    var noBattery             : Bool
    /// Low-battery threshold % from the API (e.g. 20)
    var batteryLowThreshold   : Int

    var isPluggedIn: Bool { noBattery || isCharging }
    var connectedUsers        : Int
    var isRoaming             : Bool
    var firmwareUpdateAvailable: Bool
    /// URL opened when the user taps "Open Admin UI"
    var adminURL              : String
    /// Whether the router's WiFi radio is on
    var wifiEnabled           : Bool
    /// SSID broadcast by the router (nil when WiFi is off or unavailable)
    var wifiSSID              : String?
    /// WiFi passphrase (nil when unavailable)
    var wifiPassphrase        : String?
    /// Router-configured high-usage warning threshold (0–100 %).
    /// nil when the API reports 0 or does not include the field.
    var dataHighUsageWarningPct: Int?

    /// Returns 0.0–1.0 when both values are known, otherwise nil.
    var dataUsagePercent: Double? {
        guard let used = dataUsedGB, let limit = dataLimitGB, limit > 0 else { return nil }
        return min(used / limit, 1.0)
    }

    /// True when data used ≥ the router's high-usage warning threshold.
    var isHighDataUsage: Bool {
        guard let threshold = dataHighUsageWarningPct, threshold > 0,
              let usedPct = dataUsagePercent else { return false }
        return usedPct * 100 >= Double(threshold)
    }
}
