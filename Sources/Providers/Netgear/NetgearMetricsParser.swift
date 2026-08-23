// NetgearMetricsParser.swift
// DataHawk
//
// Extracts RouterMetrics from the NETGEAR model.json response and provides
// lightweight JSON-path helpers for navigating the nested dictionary.
//
// Separated from NetgearProvider.swift to keep authentication / HTTP logic
// distinct from data-mapping logic.

import Foundation

/// `sms.msgs[].rxTime` is sometimes a raw Unix epoch seconds value (modem
/// RTC, needs drift correction — see `parseSMSMessages`), and sometimes an
/// already-correct, pre-formatted UTC timestamp string like
/// "07/26/26 11:53:59 AM" straight from the router.
private let smsRxTimeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MM/dd/yy hh:mm:ss a"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    return f
}()

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
        // wwan.registerNetworkDisplay reflects the active (possibly roaming) network;
        // sim.SPN is the home-SIM name and used as a fallback when not roaming.
        let provider = stringValue(
            model,
            "wwan.registerNetworkDisplay",
            "sim.SPN"
        ) ?? "Unknown"

        // -- Roaming ----------------------------------------------------------
        // wwan.roaming is a plain boolean; wwan.roamingType is unreliable (always "Home").
        // Resolved early because parseDataUsage needs it to choose the right
        // billing-cycle limit flag.
        let isRoaming = boolValue(model, "wwan.roaming") ?? false

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

        // -- System info ------------------------------------------------------
        let uptimeSeconds = numberValue(model, "general.upTime").map(Int.init)

        let useMetricSystem    = boolValue(model, "general.useMetricSystem") ?? true
        let routerTemperature  = numberValue(model, "general.devTemperature")
        let deviceTempCritical = boolValue(model, "power.deviceTempCritical") ?? false

        // -- Offload ------------------------------------------------------------
        // Ethernet offload wins when the router reports both links.
        // WiFi offload is only live when the feature is enabled, the radio
        // reports "On", and the router actually joined a network.
        let ethernetOffload = (boolValue(model, "ethernet.offload.enabled") ?? false)
            && (boolValue(model, "ethernet.offload.on") ?? false)

        let wifiOffloadSupported = boolValue(model, "wifi.offload.supported") ?? false
        let wifiOffloadEnabled   = boolValue(model, "wifi.offload.enabled") ?? false
        let wifiOffloadStatus    = stringValue(model, "wifi.offload.status") ?? ""
        let wifiOffloadSSID      = stringValue(model, "wifi.offload.connectionSsid") ?? ""
        let wifiOffloadSecurity  = stringValue(model, "wifi.offload.securityStatus") ?? ""

        let offload: OffloadLink? = {
            if ethernetOffload { return .ethernet }

            guard wifiOffloadSupported,
                  wifiOffloadEnabled,
                  wifiOffloadStatus.caseInsensitiveCompare("On") == .orderedSame,
                  !wifiOffloadSSID.isEmpty else {
                return nil
            }

            return .wifi(
                ssid:   wifiOffloadSSID,
                secure: wifiOffloadSecurity.caseInsensitiveCompare("Secured") == .orderedSame
            )
        }()

        // -- SMS ----------------------------------------------------------------
        let smsReady       = boolValue(model, "sms.ready") ?? false
        let smsUnreadCount = Int(numberValue(model, "sms.unreadMsgs") ?? 0)
        let smsTotalCount  = Int(numberValue(model, "sms.msgCount") ?? 0)
        let smsMessages    = parseSMSMessages(model)

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
            offload:                  offload,
            firmwareUpdateAvailable:  firmwareUpdateAvailable,
            adminURL:                 baseURL,
            uptimeSeconds:            uptimeSeconds,
            routerTemperature:        routerTemperature,
            useMetricSystem:          useMetricSystem,
            deviceTempCritical:       deviceTempCritical,
            smsReady:                 smsReady,
            smsUnreadCount:           smsUnreadCount,
            smsTotalCount:            smsTotalCount,
            smsMessages:              smsMessages
        )
    }
}

// MARK: - SMS parser

extension NetgearProvider {

    /// Parses `sms.msgs`. The router pads the array with a trailing empty
    /// object (`{}`) — entries without an "id" key are discarded.
    ///
    /// The modem's RTC is sometimes unsynced when it stamps incoming SMS,
    /// so `rxTime` can be years off. `general.currTime` reports the modem's
    /// own idea of "now" — `realNow - currTime` is the clock drift, and
    /// adding that same drift to `rxTime` recovers the true rxDate while
    /// preserving the message's real age (`currTime - rxTime`).
    func parseSMSMessages(_ model: [String: Any]) -> [SMSMessage] {
        // Cast element-by-element rather than the whole array at once: the
        // router sometimes pads this array with malformed/non-object entries
        // (e.g. a JSON `null` instead of `{}`), and a single bad element
        // would otherwise fail the whole-array cast and silently drop every
        // message.
        guard let rawArray = nestedValue(model, "sms.msgs") as? [Any] else {
            return []
        }
        let raw = rawArray.compactMap { $0 as? [String: Any] }

        let modemNow = stringToDouble(nestedValue(model, "general.currTime"))
        let realNow  = Date().timeIntervalSince1970
        let drift    = modemNow.map { realNow - $0 } ?? 0

        return raw.compactMap { entry -> SMSMessage? in
            guard let rawID = entry["id"] else { return nil }

            // A "0" or unparseable rxTime means the router has no real
            // receive timestamp (seen on carrier-injected welcome SMS).
            let rxSeconds = stringToDouble(entry["rxTime"]) ?? 0
            let rxDate: Date?
            if rxSeconds > 0 {
                // Raw modem epoch seconds — RTC may be unsynced, correct for drift.
                rxDate = Date(timeIntervalSince1970: rxSeconds + drift)
            } else if let rawString = entry["rxTime"] as? String,
                      let parsed = smsRxTimeFormatter.date(from: rawString) {
                // Already a real, pre-formatted UTC timestamp from the router.
                rxDate = parsed
            } else {
                rxDate = nil
            }

            return SMSMessage(
                id:      String(describing: rawID),
                rxDate:  rxDate,
                text:    entry["text"] as? String ?? "",
                sender:  entry["sender"] as? String ?? "",
                isRead:  (entry["read"] as? Bool) ?? false
            )
        }
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
        let dataTransferredKey = isRoaming ? "dataTransferredRoaming" : "dataTransferred"
        if let generic = nestedValue(model, "wwan.dataUsage.generic") as? [String: Any],
           let usedBytes = doubleValue(generic[dataTransferredKey]) {

            let usedGB  = usedBytes / bytesPerGB
            var limitGB: Double? = nil

            let limitValidKey = isRoaming ? "dataLimitRoamingValid" : "dataLimitValid"
            let limitValid    = (generic[limitValidKey] as? Bool) ?? false

            if limitValid {
                let limitEnabled = isRoaming
                    ? (generic["billingCycleLimitRoamingEnabled"] as? Bool) ?? false
                    : (generic["billingCycleLimitEnabled"] as? Bool) ?? false
                let limitValueKey = isRoaming ? "billingCycleLimitRoaming" : "billingCycleLimit"

                if limitEnabled, let lb = doubleValue(generic[limitValueKey]) {
                    limitGB = lb / bytesPerGB
                }
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
