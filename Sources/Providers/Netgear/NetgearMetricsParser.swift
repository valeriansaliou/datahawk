// NetgearMetricsParser.swift
// DataHawk
//
// Extracts RouterMetrics from the NETGEAR model.json response and provides
// lightweight JSON-path helpers for navigating the nested dictionary.
//
// Separated from NetgearProvider.swift to keep authentication / HTTP logic
// distinct from data-mapping logic.

import Foundation

// MARK: - Metrics extraction

extension NetgearProvider {

    /// Maps the raw `model.json` dictionary into a fully populated
    /// `RouterMetrics` value. Each section is annotated with the JSON paths
    /// it reads from so future maintainers can trace values back to the API.
    func extractMetrics(
        from model: [String: Any],
        baseURL: String
    ) -> RouterMetrics {

        // -- Network type -----------------------------------------------------
        // connectionText is the cleanest label (e.g. "5G", "4G").
        // Fall back to currentNWserviceType ("Nr5gService", "LteService", ...).
        let rawType = stringValue(
            model,
            "wwan.connectionText",
            "wwan.currentNWserviceType",
            "wwan.currentPSserviceType"
        ) ?? ""

        let networkType = parseNetworkType(rawType)

        // -- Signal bars (0–5) ------------------------------------------------
        let bars = Int(numberValue(model, "wwan.signalStrength.bars") ?? 0)

        // -- Carrier name -----------------------------------------------------
        // sim.SPN is from the physical SIM and is the most authoritative.
        let provider = stringValue(
            model,
            "sim.SPN",
            "wwan.registerNetworkDisplay"
        ) ?? "Unknown"

        // -- Roaming ----------------------------------------------------------
        // roamingType == "Home" means not roaming; anything else counts.
        // Resolved early because parseDataUsage needs it to choose the right
        // billing-cycle limit flag.
        let roamingType = stringValue(model, "wwan.roamingType") ?? "Home"
        let isRoaming   = roamingType.caseInsensitiveCompare("Home") != .orderedSame

        // -- SIM lock ---------------------------------------------------------
        let simStatus   = stringValue(model, "sim.status") ?? ""
        let isSimLocked = simStatus.caseInsensitiveCompare("Locked") == .orderedSame

        // -- Data usage -------------------------------------------------------
        let (dataUsedGB, dataLimitGB, dataHighUsageWarningPct) =
            parseDataUsage(model, isRoaming: isRoaming)

        // -- Battery ----------------------------------------------------------
        // batteryState == "NoBattery" → device has no battery (USB-C only).
        let battState  = stringValue(model, "power.batteryState") ?? ""
        let noBattery  = battState.caseInsensitiveCompare("NoBattery") == .orderedSame
        let isCharging = boolValue(model, "power.charging") ?? false

        // Show percentage even when charging; nil only when there's no battery.
        let batteryPercent: Int? = noBattery
            ? nil
            : numberValue(model, "power.battChargeLevel").map(Int.init)

        let batteryLowThreshold = Int(
            numberValue(model, "power.battLowThreshold") ?? 20
        )

        // -- Connected clients ------------------------------------------------
        let connectedUsers = Int(numberValue(
            model,
            "router.clientList.count",
            "wifi.clientCount"
        ) ?? 0)

        // -- Technology (detailed sub-type) -----------------------------------
        // currentPSserviceType carries the specific band info, e.g. "5GSUB6".
        let technology = stringValue(
            model,
            "wwan.currentPSserviceType",
            "wwan.currentNWserviceType"
        ) ?? rawType

        // -- Connection status ------------------------------------------------
        let connectionStatus = stringValue(model, "wwan.connection") ?? "Unknown"

        // -- Firmware update --------------------------------------------------
        // general.newFirmware can be a Bool, "1", or 1 depending on FW version.
        let firmwareUpdateAvailable = parseFirmwareFlag(
            nestedValue(model, "general.newFirmware")
        )

        // -- Assemble ---------------------------------------------------------

        return RouterMetrics(
            networkType:              networkType,
            technology:               technology,
            connectionStatus:         connectionStatus,
            signalStrength:           min(max(bars, 0), 5),
            provider:                 provider,
            isRoaming:                isRoaming,
            isSimLocked:              isSimLocked,
            dataUsedGB:               dataUsedGB,
            dataLimitGB:              dataLimitGB,
            dataHighUsageWarningPct:  dataHighUsageWarningPct,
            batteryPercent:           batteryPercent,
            isCharging:               isCharging,
            noBattery:                noBattery,
            batteryLowThreshold:      batteryLowThreshold,
            connectedUsers:           connectedUsers,
            wifiEnabled:              boolValue(model, "wifi.enabled") ?? false,
            wifiSSID:                 stringValue(model, "wifi.SSID"),
            wifiPassphrase:           stringValue(model, "wifi.passPhrase"),
            firmwareUpdateAvailable:  firmwareUpdateAvailable,
            adminURL:                 baseURL
        )
    }
}

// MARK: - Network type parser

extension NetgearProvider {

    /// Maps a raw technology string (e.g. "Nr5gService", "LteService",
    /// "5GSUB6") to a `NetworkType` enum case.
    func parseNetworkType(_ raw: String) -> NetworkType {
        let s = raw.uppercased()

        // 5G variants: "5G", "Nr5gService" → "NR5GSERVICE", "5GSUB6", "NR5G"
        if s.contains("5G") || s.hasPrefix("NR") { return .fiveG }

        // 4G / LTE variants
        if s.contains("LTE") || s.contains("4G") { return .fourG }

        // 3G variants: HSPA/HSPA+, WCDMA, UMTS, EV-DO, TD-SCDMA, H/H+ shorthands
        if s.contains("HSPA") || s.contains("WCDMA") || s.contains("UMTS")
            || s.contains("EVDO") || s.contains("EV-DO") || s.contains("TD-SCDMA")
            || s.contains("3G") || s == "H" || s == "H+" { return .threeG }

        // 2G variants: EDGE, GPRS, GSM, E/G shorthands
        if s.contains("EDGE") || s.contains("GPRS") || s.contains("GSM")
            || s.contains("2G") || s == "E" || s == "G" { return .twoG }

        // 1G variants: CDMA, 1xRTT
        if s.contains("CDMA") || s.contains("1X") || s.contains("1G") { return .oneG }

        // No signal
        if s.isEmpty || s.contains("NO SERVICE") || s.contains("NO SIGNAL") { return .noSignal }

        return .unknown
    }
}

// MARK: - Data-usage parser

extension NetgearProvider {

    /// Parses data usage from the model, returning (used GB, limit GB,
    /// high-usage warning %).
    ///
    /// Two sources are tried:
    ///
    ///   1. **Billing-cycle counters** under `wwan.dataUsage.generic` (bytes).
    ///      These reset with the billing period so they're the most useful.
    ///
    ///   2. **Session counters** under `wwan.dataTransferred` (byte strings).
    ///      Less useful (resets on reboot) but better than nothing.
    func parseDataUsage(
        _ model: [String: Any],
        isRoaming: Bool
    ) -> (used: Double?, limit: Double?, highUsageWarningPct: Int?) {

        let bytesPerGB: Double = 1_073_741_824  // 1024^3

        // Source 1: billing-cycle counters.
        if let generic = nestedValue(model, "wwan.dataUsage.generic") as? [String: Any],
           let usedBytes = doubleValue(generic["dataTransferred"]) {

            let usedGB  = usedBytes / bytesPerGB
            var limitGB: Double? = nil

            // When roaming, the router enforces its roaming cap; otherwise
            // the standard billing-cycle limit flag applies.
            let limitKey = isRoaming
                ? "billingCycleLimitRoaming"
                : "billingCycleLimitEnabled"
            let limitEnabled = (generic[limitKey] as? Bool) ?? false
            let limitValid   = (generic["dataLimitValid"] as? Bool) ?? false

            if limitEnabled && limitValid,
               let lb = doubleValue(generic["billingCycleLimit"]) {
                limitGB = lb / bytesPerGB
            }

            // usageHighWarning is 0–100; treat 0 as "not configured".
            let rawWarning = Int(doubleValue(generic["usageHighWarning"]) ?? 0)
            let highPct: Int? = rawWarning > 0 ? rawWarning : nil

            return (usedGB, limitGB, highPct)
        }

        // Source 2: session counters (values arrive as strings, e.g. "762096481").
        if let xf = nestedValue(model, "wwan.dataTransferred") as? [String: Any] {
            if let total = stringToDouble(xf["totalb"]) {
                return (total / bytesPerGB, nil, nil)
            }

            // Derive total from rx + tx if totalb is absent.
            if let rx = stringToDouble(xf["rxb"]),
               let tx = stringToDouble(xf["txb"]) {
                return ((rx + tx) / bytesPerGB, nil, nil)
            }
        }

        return (nil, nil, nil)
    }
}

// MARK: - Firmware flag parser

extension NetgearProvider {

    /// `general.newFirmware` can arrive as Bool, String ("1"/"true"), or Int.
    func parseFirmwareFlag(_ raw: Any?) -> Bool {
        switch raw {
        case let b as Bool:   return b
        case let s as String: return s == "1" || s.lowercased() == "true"
        case let n as Int:    return n == 1
        default:              return false
        }
    }
}

// MARK: - JSON path helpers

extension NetgearProvider {

    /// Traverses a dot-separated key path in a nested dictionary.
    /// e.g. `nestedValue(model, "wwan.signalStrength.bars")`.
    func nestedValue(_ root: [String: Any], _ path: String) -> Any? {
        var current: Any = root

        for key in path.split(separator: ".") {
            guard let dict = current as? [String: Any],
                  let value = dict[String(key)] else {
                return nil
            }

            current = value
        }

        return current
    }

    /// Returns the first non-nil `String` found at any of the given paths.
    func stringValue(_ root: [String: Any], _ paths: String...) -> String? {
        paths.lazy.compactMap { self.nestedValue(root, $0) as? String }.first
    }

    /// Returns the first non-nil numeric value (`Double`) at any of the given paths.
    func numberValue(_ root: [String: Any], _ paths: String...) -> Double? {
        paths.lazy.compactMap { self.doubleValue(self.nestedValue(root, $0)) }.first
    }

    /// Returns the first non-nil `Bool` found at any of the given paths.
    func boolValue(_ root: [String: Any], _ paths: String...) -> Bool? {
        paths.lazy.compactMap { self.nestedValue(root, $0) as? Bool }.first
    }

    /// Converts a JSON numeric value to `Double` regardless of whether it
    /// arrived as Double, Int, or NSNumber.
    func doubleValue(_ v: Any?) -> Double? {
        switch v {
        case let d as Double: return d
        case let i as Int:    return Double(i)
        default:              return nil
        }
    }

    /// Converts a value that may be a numeric string (e.g. "762096481") or
    /// a native numeric type to `Double`.
    func stringToDouble(_ v: Any?) -> Double? {
        if let d = doubleValue(v) { return d }
        if let s = v as? String   { return Double(s) }

        return nil
    }
}
