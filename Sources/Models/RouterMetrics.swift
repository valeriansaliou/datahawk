// RouterMetrics.swift
// DataHawk
//
// Value type carrying every metric fetched from the router in a single poll
// cycle. Created by a RouterProvider implementation and consumed by the UI
// layer. All properties are plain value types — no optionals except where
// the router genuinely may not report a value.

import Foundation

struct RouterMetrics {

    // MARK: - Cellular connection

    /// Cellular generation (5G, 4G, 3G, ...).
    var networkType: NetworkType

    /// Raw technology string from the API, e.g. "5GSUB6", "LteService".
    /// More detailed than `networkType` — shown in diagnostic tooltips.
    var technology: String

    /// Connection status as reported by the API, e.g. "Connected", "Connecting".
    var connectionStatus: String

    /// Signal strength expressed as 0–5 bars (clamped by the provider).
    var signalStrength: Int

    /// Carrier name, e.g. "Orange F", "Verizon".
    var provider: String

    /// Whether the device is currently roaming (i.e. not on the home network).
    var isRoaming: Bool

    /// Whether the SIM card is locked (e.g. PIN required).
    var isSimLocked: Bool

    // MARK: - Data usage

    /// Bytes consumed in the current billing period, converted to GB.
    /// `nil` when the router does not report billing-cycle counters.
    var dataUsedGB: Double?

    /// Billing-period cap in GB. `nil` when unlimited or unknown.
    var dataLimitGB: Double?

    /// Router-configured high-usage warning threshold (0–100 %).
    /// `nil` when the API reports 0 or does not include the field.
    var dataHighUsageWarningPct: Int?

    /// Fraction of the data cap consumed (0.0–1.0), or `nil` when either
    /// `dataUsedGB` or `dataLimitGB` is unknown.
    var dataUsagePercent: Double? {
        guard let used = dataUsedGB, let limit = dataLimitGB, limit > 0 else {
            return nil
        }

        return min(used / limit, 1.0)
    }

    /// `true` when the consumed percentage meets or exceeds the router's
    /// high-usage warning threshold.
    var isHighDataUsage: Bool {
        guard let threshold = dataHighUsageWarningPct, threshold > 0,
              let usedPct = dataUsagePercent else {
            return false
        }

        return usedPct * 100 >= Double(threshold)
    }

    // MARK: - Battery

    /// Battery level 0–100, or `nil` when the device has no battery slot.
    var batteryPercent: Int?

    /// `true` when the device is actively charging (battery present, on AC).
    var isCharging: Bool

    /// `true` when the device has no battery slot (always on external power).
    var noBattery: Bool

    /// Low-battery threshold percentage from the API (e.g. 20).
    var batteryLowThreshold: Int

    /// Convenience: `true` when the device is on external power — either
    /// because it has no battery or because it is currently charging.
    var isPluggedIn: Bool { noBattery || isCharging }

    // MARK: - WiFi & clients

    /// Number of clients currently connected to the router's WiFi.
    var connectedUsers: Int

    /// Whether the router's WiFi radio is on.
    var wifiEnabled: Bool

    /// SSID broadcast by the router (`nil` when WiFi is off or unavailable).
    var wifiSSID: String?

    /// WiFi passphrase (`nil` when unavailable).
    var wifiPassphrase: String?

    // MARK: - Firmware & admin

    /// `true` when a firmware update is available for the router.
    var firmwareUpdateAvailable: Bool

    /// URL opened when the user taps "Open Admin UI".
    var adminURL: String
}
