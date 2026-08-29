// RouterMetrics.swift
// DataHawk
//
// Value type carrying every metric fetched from the router in a single poll
// cycle. Created by a RouterProvider implementation and consumed by the UI
// layer. All properties are plain value types — no optionals except where
// the router genuinely may not report a value.

import Foundation

/// Upstream link the router offloads its WAN traffic to instead of using the
/// cellular modem. Wired offload wins when the router reports both.
enum OffloadLink: Equatable {
    case ethernet
    case wifi(ssid: String, secure: Bool)
}

struct RouterMetrics {

    // MARK: - Cellular connection

    /// Cellular generation (5G, 4G, 3G, ...).
    var networkType: NetworkType

    /// Raw technology string from the API, e.g. "5GSUB6", "LteService".
    /// More detailed than `networkType` — shown in diagnostic tooltips.
    var technology: String

    /// Connection status as reported by the API, e.g. "Connected", "Connecting".
    var connectionStatus: String

    /// `true` when `connectionStatus` indicates an active cellular link
    /// (case-insensitive match against "Connected").
    var isRouterConnected: Bool {
        connectionStatus.caseInsensitiveCompare("Connected") == .orderedSame
    }

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

        return usedPct >= Double(threshold) / 100
    }

    // MARK: - Battery

    /// Battery level 0–100, or `nil` when the device has no battery slot.
    var batteryPercent: Int?

    /// `true` when the device is actively charging (battery present, on AC).
    var isCharging: Bool

    /// Raw charge source reported by the router (e.g. `"QuickCharge"`, `"None"`).
    var chargeSource: String

    /// Raw charge algorithm reported by the router (e.g. `"Normal"`, `"Heat"`).
    var chargeAlgorithm: String?

    /// `true` when the device has no battery slot (always on external power).
    var noBattery: Bool

    /// Low-battery threshold percentage from the API (e.g. 20).
    var batteryLowThreshold: Int

    /// Convenience: `true` when the device is on external power — either
    /// because it has no battery or because a charge source is attached.
    var isPluggedIn: Bool {
        noBattery || chargeSource.caseInsensitiveCompare("None") != .orderedSame
    }

    /// `true` when the router is charging under its heat-mitigation algorithm —
    /// charging is slowed down or paused until the battery cools off.
    var isHeatThrottledCharging: Bool {
        guard isCharging, let algorithm = chargeAlgorithm else { return false }
        return algorithm.caseInsensitiveCompare("Heat") == .orderedSame
    }

    /// `true` when the device is on battery power and below the router's
    /// configured low-battery threshold.
    var isBatteryLow: Bool {
        guard !isPluggedIn, let pct = batteryPercent else { return false }
        return pct < batteryLowThreshold
    }

    // MARK: - WiFi & clients

    /// Number of clients currently connected to the router's WiFi.
    var connectedUsers: Int

    /// Clients currently connected to the router, when it reports a list.
    /// May be empty even though `connectedUsers` is non-zero (the router only
    /// exposes the detailed list to authenticated sessions on some firmwares).
    var clients: [WiFiClient]

    /// Whether the router's WiFi radio is on.
    var wifiEnabled: Bool

    /// SSID broadcast by the router (`nil` when WiFi is off or unavailable).
    var wifiSSID: String?

    /// WiFi passphrase (`nil` when unavailable).
    var wifiPassphrase: String?

    // MARK: - Offload

    /// Upstream link currently carrying the router's WAN traffic in place of
    /// the cellular modem. `nil` when the router is on cellular.
    var offload: OffloadLink?

    /// `true` when the router routes its traffic over an upstream Ethernet or
    /// WiFi link instead of the cellular one.
    var isOffloading: Bool { offload != nil }

    // MARK: - Firmware & admin

    /// `true` when a firmware update is available for the router.
    var firmwareUpdateAvailable: Bool

    /// URL opened when the user taps "Open Admin UI".
    var adminURL: String

    // MARK: - System info

    /// Seconds the router has been running since last boot, or `nil` when unavailable.
    var uptimeSeconds: Int?

    /// Router chassis temperature in the unit selected by `useMetricSystem`.
    var routerTemperature: Double?

    /// `true` → temperatures in °C; `false` → °F.
    var useMetricSystem: Bool

    /// `true` when the router reports a critical device temperature.
    var deviceTempCritical: Bool

    /// Battery temperature in the unit selected by `useMetricSystem`, or `nil`
    /// when unavailable (no battery inserted, or unsupported hardware).
    var batteryTemperature: Double?

    /// Raw battery temperature state reported by the router, e.g. `"Normal"`.
    var batteryTempState: String?

    /// `true` when the router reports a battery temperature state other than
    /// "Normal" (only meaningful when a battery is inserted).
    var isBatteryTempAbnormal: Bool {
        guard !noBattery, let state = batteryTempState, !state.isEmpty else { return false }
        return state.caseInsensitiveCompare("Normal") != .orderedSame
    }

    /// `true` when either the chassis or the battery reports a temperature
    /// problem — drives the heat glyph in the status-bar icon.
    var isOverheating: Bool { deviceTempCritical || isBatteryTempAbnormal }

    // MARK: - SMS

    /// `true` when the router's SMS feature is supported and ready to use.
    var smsReady: Bool

    /// Number of unread messages, straight from the router (free — no extra fetch).
    var smsUnreadCount: Int

    /// Total number of messages stored on the router.
    var smsTotalCount: Int

    /// Parsed message list, newest first is not guaranteed — sort at display time.
    var smsMessages: [SMSMessage]
}
