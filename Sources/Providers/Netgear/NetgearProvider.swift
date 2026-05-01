// NetgearProvider.swift
// DataHawk
//
// NETGEAR Nighthawk provider (M3 / M6 / M6 Pro).
//
// Authentication flow (full — run on first connect or after a cookie miss):
//
//   1. GET  /sess_cd_tmp        → anonymous Set-Cookie
//   2. GET  /api/model.json     → session.secToken (anonymous)
//   3. POST /Forms/config       → authenticated Set-Cookie
//   4. GET  /api/model.json     → full data model with metrics
//
// Fast path (subsequent refreshes):
//
//   - Inject the cached auth cookie into a fresh ephemeral session.
//   - GET /api/model.json → full data model (single round-trip).
//   - Up to 2 attempts with a short timeout; if both time out the router
//     is likely not ready yet, so we wait before falling through to the
//     full auth flow.
//   - If the response is missing `wwan.connection` (stale / expired cookie),
//     discard the cache and fall through to full auth immediately.

import Foundation

class NetgearProvider: RouterProvider {

    // MARK: - Cookie cache

    /// Auth cookies keyed by normalised base URL.
    /// Loaded from UserDefaults on init and persisted after every update.
    private var cachedCookies: [String: [HTTPCookie]] = [:]

    /// UserDefaults key for the serialised cookie cache.
    private let cookiesDefaultsKey = "netgear_cookies_v1"

    init() {
        cachedCookies = Self.loadCookies(forKey: cookiesDefaultsKey)
    }

    // MARK: - RouterProvider conformance

    /// Discards all cached cookies so the next fetch performs a full login.
    func flushAuth() {
        cachedCookies = [:]
        UserDefaults.standard.removeObject(forKey: cookiesDefaultsKey)
    }

    /// Fetches metrics from the router, using the fast path (cached cookie)
    /// when possible and falling back to the full auth flow otherwise.
    func fetchMetrics(config: HotspotConfig, baseURL: String) async throws -> RouterMetrics {
        let base = normalizedBase(baseURL)

        // -- Fast path: reuse cached auth cookie ----------------------------

        if let cookies = cachedCookies[base] {
            var timedOutOnAll = false

            for attempt in 1...2 {
                do {
                    let model = try await fetchModelWithCookies(
                        cookies, base: base, requestTimeout: 5
                    )

                    // If the response contains wwan data the cookie is still valid.
                    if isAuthenticated(model) {
                        return extractMetrics(from: model, baseURL: base)
                    }

                    // Valid HTTP response but unauthenticated — stale cookie.
                    break
                } catch let urlErr as URLError where urlErr.code == .timedOut {
                    if attempt < 2 { continue }

                    timedOutOnAll = true
                } catch {
                    // Other network error — fall through to full auth.
                    break
                }
            }

            // Invalidate the stale/expired cookie.
            cachedCookies[base] = nil
            persistCookies()

            if timedOutOnAll {
                // Router likely not yet reachable (e.g. just switched networks).
                // Wait before the heavier full-auth flow to give it time.
                try await Task.sleep(for: .seconds(10))
            }
        }

        // -- Full auth flow (standard timeouts) -----------------------------

        let session = makeFreshSession()

        // Step 1: Obtain an anonymous session cookie.
        try await fetchRaw(session, "\(base)/sess_cd_tmp")

        // Step 2: Read the security token from the public model.
        let pubModel = try await fetchJSON(session, "\(base)/api/model.json")

        guard let secToken = stringValue(pubModel, "session.secToken"),
              !secToken.isEmpty else {
            throw ProviderError("Router returned an unexpected response")
        }

        // Step 3: POST credentials to authenticate the session.
        try await login(
            session, baseURL: base, secToken: secToken, password: config.password
        )

        // Step 4: Fetch the full (authenticated) model.
        let model = try await fetchJSON(session, "\(base)/api/model.json")

        // Persist the auth cookies for subsequent fast-path refreshes.
        if let url = URL(string: base) {
            cachedCookies[base] =
                session.configuration.httpCookieStorage?.cookies(for: url) ?? []
            persistCookies()
        }

        return extractMetrics(from: model, baseURL: base)
    }

    // MARK: - Fast-path helper

    /// Fetches `/api/model.json` with pre-seeded cookies (no login).
    private func fetchModelWithCookies(
        _ cookies: [HTTPCookie],
        base: String,
        requestTimeout: TimeInterval = 8
    ) async throws -> [String: Any] {
        let session = makeFreshSession(requestTimeout: requestTimeout)

        if let storage = session.configuration.httpCookieStorage {
            for cookie in cookies { storage.setCookie(cookie) }
        }

        return try await fetchJSON(session, "\(base)/api/model.json")
    }

    /// Returns `true` when the model contains `wwan.connection`, which is
    /// only present in an authenticated response.
    private func isAuthenticated(_ model: [String: Any]) -> Bool {
        nestedValue(model, "wwan.connection") != nil
    }

    // MARK: - Base URL normalisation

    /// Strips trailing slashes and rewrites bare-IP URLs to use the NETGEAR
    /// hostname `mywebui`. The router's HTTP server validates the Host header
    /// and returns `sessionId=unknown` (auth failure) when addressed by IP.
    private func normalizedBase(_ raw: String) -> String {
        var s = raw.trimmingCharacters(
            in: CharacterSet(charactersIn: "/").union(.whitespaces)
        )

        // If the URL's host is a bare IPv4 address (e.g. http://10.0.2.1),
        // replace it with the NETGEAR alias that mDNS / hosts points to.
        if let url = URL(string: s),
           let host = url.host,
           host.first?.isNumber == true {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)

            components?.host = "mywebui"

            if let rewritten = components?.url?.absoluteString {
                s = rewritten.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
        }

        return s
    }

    // MARK: - URLSession factory

    /// Creates an ephemeral session that accepts and sends cookies but shares
    /// no state with other sessions.
    private func makeFreshSession(requestTimeout: TimeInterval = 8) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral

        cfg.httpCookieAcceptPolicy     = .always
        cfg.httpShouldSetCookies       = true
        cfg.timeoutIntervalForRequest  = requestTimeout
        cfg.timeoutIntervalForResource = max(requestTimeout + 4, 12)

        return URLSession(configuration: cfg)
    }

    // MARK: - HTTP primitives

    /// GETs a URL expecting a JSON dictionary response.
    private func fetchJSON(
        _ session: URLSession,
        _ rawURL: String
    ) async throws -> [String: Any] {
        guard let url = URL(string: rawURL) else {
            throw ProviderError("Invalid router URL — check Settings")
        }

        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, _) = try await session.data(for: req)

        guard let json = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            throw ProviderError("Router returned an unexpected response")
        }

        return json
    }

    /// GETs a URL discarding the response body (used to obtain a Set-Cookie).
    private func fetchRaw(_ session: URLSession, _ rawURL: String) async throws {
        guard let url = URL(string: rawURL) else {
            throw ProviderError("Invalid router URL — check Settings")
        }

        _ = try await session.data(from: url)
    }

    /// POSTs credentials to the NETGEAR login endpoint.
    private func login(
        _ session: URLSession,
        baseURL: String,
        secToken: String,
        password: String
    ) async throws {
        guard let url = URL(string: "\(baseURL)/Forms/config") else {
            throw ProviderError("Invalid router URL — check Settings")
        }

        // Build an application/x-www-form-urlencoded body.
        let body: String = [
            ("token",            secToken),
            ("session.password", password),
        ]
        .map { key, val in "\(key)=\(formEncode(val))" }
        .joined(separator: "&")

        var req = URLRequest(url: url)

        req.httpMethod      = "POST"
        req.timeoutInterval = 60  // /Forms/config can be very slow on NETGEAR HW
        req.setValue(
            "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"
        )
        req.httpBody = body.data(using: .utf8)

        let (_, response) = try await session.data(for: req)

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        if statusCode < 200 || statusCode >= 300 {
            throw ProviderError(
                "NETGEAR login failed — check username / password in Settings"
            )
        }
    }

    /// Percent-encodes a form value so that `&`, `=`, `+`, etc. are escaped.
    private func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")

        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: - Cookie persistence

    /// Serialises the cookie cache to UserDefaults. Only plist-safe types
    /// (String, Date, NSNumber, URL-as-String) are kept.
    private func persistCookies() {
        let serialized: [String: [[String: Any]]] = cachedCookies.mapValues { cookies in
            cookies.compactMap { cookie -> [String: Any]? in
                guard let props = cookie.properties else { return nil }

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

    /// Deserialises the cookie cache from UserDefaults.
    private static func loadCookies(
        forKey key: String
    ) -> [String: [HTTPCookie]] {
        guard let raw = UserDefaults.standard.dictionary(forKey: key)
                as? [String: [[String: Any]]] else {
            return [:]
        }

        return raw.compactMapValues { dicts in
            let cookies = dicts.compactMap { dict -> HTTPCookie? in
                let props = Dictionary(
                    uniqueKeysWithValues: dict.map {
                        (HTTPCookiePropertyKey($0.key), $0.value)
                    }
                )

                return HTTPCookie(properties: props)
            }

            return cookies.isEmpty ? nil : cookies
        }
    }
}
