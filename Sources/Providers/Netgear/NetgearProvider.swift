import Foundation

/// NETGEAR Nighthawk provider (M3 / M6 / M6 Pro).
///
/// Authentication flow (full — run on first connect or after a cookie miss):
///
///   1. GET  /sess_cd_tmp             → anonymous Set-Cookie
///   2. GET  /api/model.json          → session.secToken  (anonymous)
///   3. POST /Forms/config            → authenticated Set-Cookie
///   4. GET  /api/model.json          → full data model
///
/// Fast path (subsequent refreshes):
///
///   - Inject the cached auth cookie into a new session (3 s timeout)
///   - GET  /api/model.json  → full data model (one round-trip)
///   - Up to 2 attempts; if both time out the router is likely not ready yet,
///     so we wait 10 s before falling through to the full auth flow.
///   - If the response is missing `wwan.connection` (stale / expired cookie),
///     discard the cache and fall through to full auth immediately.
///
class NetgearProvider: RouterProvider {

    /// Auth cookie cache keyed by normalized base URL.
    /// Loaded from disk on init and persisted after every update.
    private var cachedCookies: [String: [HTTPCookie]] = [:]

    private let cookiesDefaultsKey = "netgear_cookies_v1"

    init() {
        cachedCookies = Self.loadCookies(forKey: cookiesDefaultsKey)
    }

    // MARK: - Cookie persistence

    /// Serialises the cache to UserDefaults.
    private func persistCookies() {
        let serialized: [String: [[String: Any]]] = cachedCookies.mapValues { cookies in
            cookies.compactMap { cookie -> [String: Any]? in
                guard let props = cookie.properties else { return nil }
                // Only keep plist-safe value types; convert URL → String.
                var dict: [String: Any] = [:]
                for (key, val) in props {
                    switch val {
                    case let s as String:   dict[key.rawValue] = s
                    case let d as Date:     dict[key.rawValue] = d
                    case let n as NSNumber: dict[key.rawValue] = n
                    case let u as URL:      dict[key.rawValue] = u.absoluteString
                    default: break
                    }
                }
                return dict.isEmpty ? nil : dict
            }
        }
        UserDefaults.standard.set(serialized, forKey: cookiesDefaultsKey)
    }

    /// Deserialises the cache from UserDefaults.
    private static func loadCookies(forKey key: String) -> [String: [HTTPCookie]] {
        guard let raw = UserDefaults.standard.dictionary(forKey: key)
                        as? [String: [[String: Any]]] else { return [:] }
        return raw.compactMapValues { dicts in
            let cookies = dicts.compactMap { dict -> HTTPCookie? in
                let props = Dictionary(
                    uniqueKeysWithValues: dict.map { (HTTPCookiePropertyKey($0.key), $0.value) }
                )
                return HTTPCookie(properties: props)
            }
            return cookies.isEmpty ? nil : cookies
        }
    }

    func flushAuth() {
        cachedCookies = [:]
        UserDefaults.standard.removeObject(forKey: cookiesDefaultsKey)
    }

    func fetchMetrics(config: HotspotConfig, baseURL: String) async throws -> RouterMetrics {
        let base = normalizedBase(baseURL)

        // Fast path — cached cookie, short timeout, up to 2 attempts.
        if let cookies = cachedCookies[base] {
            var timedOutOnAll = false
            for attempt in 1...2 {
                do {
                    let model = try await fetchModelWithCookies(cookies, base: base, requestTimeout: 5)
                    if isAuthenticated(model) {
                        return extractMetrics(from: model, baseURL: base)
                    }
                    // Valid response but unauthenticated — stale cookie, go to full auth now.
                    break
                } catch let urlErr as URLError where urlErr.code == .timedOut {
                    if attempt < 2 { continue }
                    timedOutOnAll = true
                } catch {
                    break  // other network error — fall through to full auth
                }
            }
            cachedCookies[base] = nil; persistCookies()
            if timedOutOnAll {
                // Router not yet reachable (e.g. just switched networks).
                // Wait before the heavier full-auth flow.
                try await Task.sleep(nanoseconds: 10 * 1_000_000_000)
            }
        }

        // Full auth flow (standard timeouts).
        let session = makeFreshSession()

        try await fetchRaw(session, "\(base)/sess_cd_tmp")

        let pubModel = try await fetchJSON(session, "\(base)/api/model.json")
        guard let secToken = string(pubModel, "session.secToken"), !secToken.isEmpty else {
            throw ProviderError("Router returned an unexpected response")
        }

        try await login(session, baseURL: base, secToken: secToken, password: config.password)

        let model = try await fetchJSON(session, "\(base)/api/model.json")

        // Cache the auth cookies for the next refresh.
        if let url = URL(string: base) {
            cachedCookies[base] = session.configuration.httpCookieStorage?.cookies(for: url) ?? []
            persistCookies()
        }

        return extractMetrics(from: model, baseURL: base)
    }

    /// Fetches /api/model.json with pre-seeded cookies, without going through auth.
    private func fetchModelWithCookies(
        _ cookies: [HTTPCookie],
        base: String,
        requestTimeout: TimeInterval = 8
    ) async throws -> [String: Any] {
        let session = makeFreshSession(requestTimeout: requestTimeout)
        if let storage = session.configuration.httpCookieStorage,
           let url = URL(string: base) {
            for cookie in cookies { storage.setCookie(cookie) }
            // Ensure the cookie domain is matched even if it differs slightly.
            HTTPCookieStorage.shared.setCookies(cookies, for: url, mainDocumentURL: nil)
        }
        return try await fetchJSON(session, "\(base)/api/model.json")
    }

    /// Returns true when the model contains the wwan data only present in an
    /// authenticated response. An unauthenticated response returns a skeleton
    /// without these fields.
    private func isAuthenticated(_ model: [String: Any]) -> Bool {
        nested(model, "wwan.connection") != nil
    }

    // MARK: - Base URL normalization

    /// Strips trailing slashes and rewrites bare-IP URLs to use the NETGEAR
    /// hostname `mywebui`.  The router's HTTP server validates the Host header
    /// and returns `sessionId=unknown` (auth failure) when addressed by IP.
    private func normalizedBase(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/").union(.whitespaces))
        // If the URL's host is an IPv4 address (e.g. http://10.0.2.1), replace
        // it with the NETGEAR alias that the device's mDNS / hosts entry points to.
        if let url = URL(string: s),
           let host = url.host,
           host.first?.isNumber == true {
            // Rebuild URL with mywebui as the host.
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.host = "mywebui"
            if let rewritten = components?.url?.absoluteString {
                s = rewritten.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
        }
        return s
    }

    // MARK: - Session factory

    private func makeFreshSession(requestTimeout: TimeInterval = 8) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieAcceptPolicy     = .always
        cfg.httpShouldSetCookies       = true
        cfg.timeoutIntervalForRequest  = requestTimeout
        cfg.timeoutIntervalForResource = max(requestTimeout + 4, 12)
        return URLSession(configuration: cfg)
    }

    // MARK: - HTTP primitives

    private func fetchJSON(_ session: URLSession, _ rawURL: String) async throws -> [String: Any] {
        guard let url = URL(string: rawURL) else { throw ProviderError("Invalid router URL — check Settings") }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await session.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError("Router returned an unexpected response")
        }
        return json
    }

    private func fetchRaw(_ session: URLSession, _ rawURL: String) async throws {
        guard let url = URL(string: rawURL) else { throw ProviderError("Invalid router URL — check Settings") }
        _ = try await session.data(from: url)
    }

    private func login(
        _ session : URLSession,
        baseURL   : String,
        secToken  : String,
        password  : String
    ) async throws {
        guard let url = URL(string: "\(baseURL)/Forms/config") else {
            throw ProviderError("Invalid router URL — check Settings")
        }

        // application/x-www-form-urlencoded body
        let body: String = [
            ("token",            secToken),
            ("session.password", password),
        ]
        .map { key, val in "\(key)=\(formEncode(val))" }
        .joined(separator: "&")

        var req = URLRequest(url: url)
        req.httpMethod       = "POST"
        req.timeoutInterval  = 60   // /Forms/config can be very slow on NETGEAR hardware
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody         = body.data(using: .utf8)

        let (_, response) = try await session.data(for: req)

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        if statusCode < 200 || statusCode >= 300 {
            throw ProviderError("NETGEAR login failed — check username / password in Settings")
        }
    }

    /// Percent-encodes a form value conservatively so that '&', '=', '+', etc.
    /// are always escaped.
    private func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: - Metrics extraction

    private func extractMetrics(from model: [String: Any], baseURL: String) -> RouterMetrics {

        // ── Network type ─────────────────────────────────────────────────
        // connectionText is the cleanest label (e.g. "5G", "4G").
        // Fall back to currentNWserviceType ("Nr5gService", "LteService" …).
        let rawType = string(model,
            "wwan.connectionText",
            "wwan.currentNWserviceType",
            "wwan.currentPSserviceType"
        ) ?? ""
        let networkType = parseNetworkType(rawType)

        // ── Signal bars 0–5 ──────────────────────────────────────────────
        let bars = Int(number(model, "wwan.signalStrength.bars") ?? 0)

        // ── Carrier name ─────────────────────────────────────────────────
        // sim.SPN comes from the physical SIM and is the most authoritative.
        let provider = string(model,
            "sim.SPN",
            "wwan.registerNetworkDisplay"
        ) ?? "Unknown"

        // ── Roaming ───────────────────────────────────────────────────────
        // roamingType == "Home" means not roaming; anything else means roaming.
        // Resolved early because parseDataUsage needs it to pick the right limit flag.
        let roamingType = string(model, "wwan.roamingType") ?? "Home"
        let isRoaming = roamingType.caseInsensitiveCompare("Home") != .orderedSame

        // ── Data usage ───────────────────────────────────────────────────
        let (dataUsedGB, dataLimitGB, dataHighUsageWarningPct) = parseDataUsage(model, isRoaming: isRoaming)

        // ── Battery ──────────────────────────────────────────────────────
        // batteryState == "NoBattery"  → device has no battery (e.g. plugged via USB-C only)
        let battState           = string(model, "power.batteryState") ?? ""
        let noBattery           = battState.caseInsensitiveCompare("NoBattery") == .orderedSame
        let isCharging          = bool(model, "power.charging") ?? false
        // Show percentage even when charging; nil only when there's no battery.
        let batteryPercent: Int? = noBattery
            ? nil
            : number(model, "power.battChargeLevel").map(Int.init)
        let batteryLowThreshold = Int(number(model, "power.battLowThreshold") ?? 20)

        // ── Connected clients ─────────────────────────────────────────────
        let connectedUsers = Int(number(model,
            "router.clientList.count",
            "wifi.clientCount"
        ) ?? 0)

        // ── Technology (detailed sub-type) ────────────────────────────────
        // currentPSserviceType carries the specific band info, e.g. "5GSUB6".
        let technology = string(model, "wwan.currentPSserviceType", "wwan.currentNWserviceType") ?? rawType

        // ── Connection status ─────────────────────────────────────────────
        let connectionStatus = string(model, "wwan.connection") ?? "Unknown"

        // ── Firmware update ───────────────────────────────────────────────
        // general.newFirmware is "1" or true when an update is available.
        let fwRaw = nested(model, "general.newFirmware")
        let firmwareUpdateAvailable: Bool
        if let b = fwRaw as? Bool        { firmwareUpdateAvailable = b }
        else if let s = fwRaw as? String { firmwareUpdateAvailable = s == "1" || s.lowercased() == "true" }
        else if let n = fwRaw as? Int    { firmwareUpdateAvailable = n == 1 }
        else                             { firmwareUpdateAvailable = false }

        return RouterMetrics(
            networkType:              networkType,
            technology:               technology,
            connectionStatus:         connectionStatus,
            signalStrength:           min(max(bars, 0), 5),
            provider:                 provider,
            dataUsedGB:               dataUsedGB,
            dataLimitGB:              dataLimitGB,
            batteryPercent:           batteryPercent,
            isCharging:               isCharging,
            noBattery:                noBattery,
            batteryLowThreshold:      batteryLowThreshold,
            connectedUsers:           connectedUsers,
            isRoaming:                isRoaming,
            firmwareUpdateAvailable:  firmwareUpdateAvailable,
            adminURL:                 baseURL,
            wifiEnabled:              bool(model, "wifi.enabled") ?? false,
            wifiSSID:                 string(model, "wifi.SSID"),
            wifiPassphrase:           string(model, "wifi.passPhrase"),
            dataHighUsageWarningPct:  dataHighUsageWarningPct
        )
    }

    // MARK: - Network type parser

    private func parseNetworkType(_ raw: String) -> NetworkType {
        let s = raw.uppercased()
        // "5G", "Nr5gService"→"NR5GSERVICE", "5GSUB6", "NR5G" …
        if s.contains("5G") || s.hasPrefix("NR")                              { return .fiveG   }
        // "LteService"→"LTESERVICE", "4G", "LTE" …
        if s.contains("LTE") || s.contains("4G")                              { return .fourG   }
        // "HSPA", "WCDMA", "3G" …
        if s.contains("HSPA") || s.contains("WCDMA") || s.contains("3G")     { return .threeG  }
        // "EDGE", "GPRS", "2G" …
        if s.contains("EDGE") || s.contains("GPRS")  || s.contains("2G")     { return .twoG    }
        // "CDMA", "1XRTT", "1G" …
        if s.contains("CDMA") || s.contains("1X")    || s.contains("1G")     { return .oneG    }
        if s.isEmpty || s.contains("NO SERVICE") || s.contains("NO SIGNAL")  { return .noSignal }
        return .unknown
    }

    // MARK: - Data-usage parser

    private func parseDataUsage(
        _ model: [String: Any],
        isRoaming: Bool
    ) -> (used: Double?, limit: Double?, highUsageWarningPct: Int?) {
        // Primary: billing-cycle counters under wwan.dataUsage.generic (bytes).
        // These reset with the billing period so they're the most useful.
        if let generic = nested(model, "wwan.dataUsage.generic") as? [String: Any] {
            if let usedBytes = doubleValue(generic["dataTransferred"]) {
                let usedGB  = usedBytes / 1_073_741_824
                var limitGB : Double? = nil

                // When roaming, the router enforces the roaming cap; otherwise
                // use the standard billing-cycle limit flag.
                let limitFlagKey = isRoaming ? "billingCycleLimitRoaming" : "billingCycleLimitEnabled"
                let limitEnabled = (generic[limitFlagKey] as? Bool) ?? false
                let limitValid   = (generic["dataLimitValid"] as? Bool) ?? false
                if limitEnabled && limitValid, let lb = doubleValue(generic["billingCycleLimit"]) {
                    limitGB = lb / 1_073_741_824
                }

                // usageHighWarning is 0–100; treat 0 as "not configured".
                let rawWarning = Int(doubleValue(generic["usageHighWarning"]) ?? 0)
                let highUsageWarningPct: Int? = rawWarning > 0 ? rawWarning : nil

                return (usedGB, limitGB, highUsageWarningPct)
            }
        }

        // Fallback: session counters under wwan.dataTransferred.
        // Note: the API returns these as *strings*, e.g. "762096481".
        if let xf = nested(model, "wwan.dataTransferred") as? [String: Any] {
            let total = stringToDouble(xf["totalb"])
            if let total {
                return (total / 1_073_741_824, nil, nil)
            }
            // Derive total from rx + tx if totalb is absent.
            if let rx = stringToDouble(xf["rxb"]), let tx = stringToDouble(xf["txb"]) {
                return ((rx + tx) / 1_073_741_824, nil, nil)
            }
        }

        return (nil, nil, nil)
    }

    // MARK: - JSON path helpers

    /// Traverses a dot-separated key path in a nested dictionary.
    private func nested(_ root: [String: Any], _ path: String) -> Any? {
        var cur: Any = root
        for key in path.split(separator: ".") {
            guard let d = cur as? [String: Any], let v = d[String(key)] else { return nil }
            cur = v
        }
        return cur
    }

    /// Returns the first non-nil String found at any of the given paths.
    private func string(_ root: [String: Any], _ paths: String...) -> String? {
        paths.lazy.compactMap { self.nested(root, $0) as? String }.first
    }

    /// Returns the first non-nil numeric value (Double) found at any of the given paths.
    private func number(_ root: [String: Any], _ paths: String...) -> Double? {
        paths.lazy.compactMap { self.doubleValue(self.nested(root, $0)) }.first
    }

    /// Returns the first non-nil Bool found at any of the given paths.
    private func bool(_ root: [String: Any], _ paths: String...) -> Bool? {
        paths.lazy.compactMap { self.nested(root, $0) as? Bool }.first
    }

    /// Converts a JSON value to Double regardless of whether it arrived as
    /// Double, Int, or NSNumber.
    private func doubleValue(_ v: Any?) -> Double? {
        switch v {
        case let d as Double: return d
        case let i as Int:    return Double(i)
        default:              return nil
        }
    }

    /// Converts a value that may be a String like "762096481" or a numeric type.
    private func stringToDouble(_ v: Any?) -> Double? {
        if let d = doubleValue(v)          { return d }
        if let s = v as? String            { return Double(s) }
        return nil
    }
}
