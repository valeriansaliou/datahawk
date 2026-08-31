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
//   - If `session.userRole` is not "Admin" (stale / expired cookie),
//     discard the cache and fall through to full auth immediately.
//
// Write actions (mark SMS read, …) reuse the same auth, then POST to
// /Forms/config with a CSRF token taken from the very model.json response
// that proved the session is authenticated.
//
// Every public entry point takes `RouterLock` for its whole duration, so
// only one flow is ever on the wire. New entry points must do the same; the
// private HTTP helpers must not, or they would deadlock against it.

import Foundation

actor NetgearProvider: RouterProvider {

    // MARK: - Cookie cache

    /// Auth cookies keyed by normalised base URL.
    /// Loaded from the Keychain on init and persisted after every update.
    /// Actor isolation serialises all access — the cache is mutated both by
    /// fetch cycles (background tasks) and by flushAuth() (user-initiated).
    private var cachedCookies: [String: [HTTPCookie]] = [:]

    /// Keychain account for the serialised cookie cache.
    private static let cookiesKeychainAccount = "netgear-cookies-v1"

    /// Legacy UserDefaults key — cookies lived there (plain text) before the
    /// Keychain move. Kept only so the one-time migration can find them.
    private static let legacyCookiesDefaultsKey = "netgear_cookies_v1"

    init() {
        // One-time migration: pre-Keychain versions stored the session
        // cookies in UserDefaults. Pull them out, re-persist to the
        // Keychain, and remove the plain-text copy. The legacy value is
        // already in plist form, so it's written to the Keychain directly
        // (an actor init cannot call the isolated persistCookies()).
        if let legacy = UserDefaults.standard.dictionary(forKey: Self.legacyCookiesDefaultsKey)
            as? [String: [[String: Any]]] {
            UserDefaults.standard.removeObject(forKey: Self.legacyCookiesDefaultsKey)
            cachedCookies = Self.cookies(fromPlist: legacy)

            if let data = try? PropertyListSerialization.data(
                fromPropertyList: legacy, format: .binary, options: 0
            ) {
                KeychainStore.writeData(data, account: Self.cookiesKeychainAccount)
            }
        } else {
            cachedCookies = Self.loadCookies()
        }
    }

    // MARK: - RouterProvider conformance

    /// Discards all cached cookies so the next fetch performs a full login.
    func flushAuth() {
        cachedCookies = [:]
        KeychainStore.delete(account: Self.cookiesKeychainAccount)
    }

    /// Fetches metrics from the router, using the fast path (cached cookie)
    /// when possible and falling back to the full auth flow otherwise.
    ///
    /// Holds `RouterLock` for the whole cycle, including the 10 s wait in the
    /// `.timedOut` branch — a router that just timed out twice has nothing to
    /// offer a queued write anyway.
    func fetchMetrics(config: HotspotConfig, baseURL: String) async throws -> RouterMetrics {
        await RouterLock.shared.acquire()
        defer { RouterLock.shared.release() }

        let base = normalizedBase(baseURL)

        // -- Fast path: reuse cached auth cookie ----------------------------

        if let cookies = cachedCookies[base] {
            switch await tryFastPath(cookies: cookies, base: base) {
            case .success(let metrics):
                return metrics

            case .stale:
                // Valid HTTP response but unauthenticated — drop the cookie
                // and fall through to full auth.
                dropCookies(for: base)

            case .timedOut:
                // Router likely not yet reachable (e.g. just switched networks).
                // Drop the cookie and wait before the heavier full-auth flow.
                dropCookies(for: base)
                try await Task.sleep(for: .seconds(10))
            }
        }

        // -- Full auth flow (standard timeouts) -----------------------------

        let (_, model) = try await fullAuth(config: config, base: base)

        return extractMetrics(from: model, baseURL: base)
    }

    // MARK: - SMS write actions

    /// Marks a single message as read on the router.
    ///
    /// NETGEAR models this as an ordinary `/Forms/config` write keyed by the
    /// message id. The token read and the write are one atomic block: the
    /// token rotates per response, so two overlapping writes would invalidate
    /// each other's token. Actor isolation cannot provide that — actors are
    /// reentrant and release at every `await` — hence `RouterLock`.
    func markSMSRead(id: String, config: HotspotConfig, baseURL: String) async throws {
        await RouterLock.shared.acquire()
        defer { RouterLock.shared.release() }

        let base = normalizedBase(baseURL)
        let (session, model) = try await authenticatedSession(config: config, base: base)

        try await postConfig(
            session,
            baseURL:  base,
            secToken: try secToken(from: model),
            fields:   ["sms.readId": id]
        )
    }

    /// Deletes every message stored on the router in a single write.
    ///
    /// `sms.deleteAll` wipes the whole inbox router-side, so no per-message
    /// loop is needed. The write is followed by a fresh `model.json` read
    /// which both proves the wipe took effect and gives the caller the
    /// authoritative post-delete state to publish.
    func deleteAllSMS(config: HotspotConfig, baseURL: String) async throws -> RouterMetrics {
        // Held across the write and the read-back: polls queue behind it and
        // then observe the emptied inbox, instead of racing it and
        // republishing deleted rows.
        await RouterLock.shared.acquire()
        defer { RouterLock.shared.release() }

        let base = normalizedBase(baseURL)
        let (session, model) = try await authenticatedSession(config: config, base: base)

        try await postConfig(
            session,
            baseURL:  base,
            secToken: try secToken(from: model),
            fields:   ["sms.deleteAll": "1"]
        )

        let updated = try await fetchModel(session, base: base)

        guard parseSMSMessages(updated).isEmpty else {
            throw ProviderError("Router did not delete the messages")
        }

        return extractMetrics(from: updated, baseURL: base)
    }

    // MARK: - Data usage actions

    /// Zeroes the billing-cycle data usage counter.
    ///
    /// Same shape as `deleteAllSMS`: one `/Forms/config` write followed by a
    /// `model.json` read-back inside the same lock, so the caller can publish
    /// the reset counter straight away and no poll can interleave and
    /// republish the pre-reset value.
    func resetDataUsage(config: HotspotConfig, baseURL: String) async throws -> RouterMetrics {
        await RouterLock.shared.acquire()
        defer { RouterLock.shared.release() }

        let base = normalizedBase(baseURL)
        let (session, model) = try await authenticatedSession(config: config, base: base)

        try await postConfig(
            session,
            baseURL:  base,
            secToken: try secToken(from: model),
            fields:   ["wwan.dataUsage.generic.reset": "1"]
        )

        let updated = try await fetchModel(session, base: base)

        return extractMetrics(from: updated, baseURL: base)
    }

    // MARK: - Authentication

    /// Runs the full four-step login flow and caches the resulting cookies
    /// for subsequent fast-path refreshes.
    /// - Returns: The authenticated session and the model.json it produced.
    private func fullAuth(
        config: HotspotConfig,
        base: String
    ) async throws -> (session: URLSession, model: [String: Any]) {
        let session = makeFreshSession()

        // Step 1: Obtain an anonymous session cookie.
        try await fetchRaw(session, "\(base)/sess_cd_tmp")

        // Step 2: Read the security token from the public model.
        let pubModel = try await fetchModel(session, base: base)
        let token    = try secToken(from: pubModel)

        // Step 3: POST credentials to authenticate the session.
        try await login(
            session, baseURL: base, secToken: token, password: config.password
        )

        // Step 4: Fetch the full (authenticated) model.
        let model = try await fetchModel(session, base: base)

        // Persist the auth cookies for subsequent fast-path refreshes.
        if let url = URL(string: base) {
            cachedCookies[base] =
                session.configuration.httpCookieStorage?.cookies(for: url) ?? []
            persistCookies()
        }

        return (session, model)
    }

    /// Returns a session known to be authenticated, together with the
    /// model.json response that proved it — writes need a CSRF token from
    /// that very round-trip, since the token rotates per response.
    ///
    /// Uses the cached cookie when it still holds; otherwise falls back to a
    /// full login. Unlike the metrics fast path there is no short-timeout
    /// retry: a write is user-initiated and infrequent, so one attempt at the
    /// standard timeout is enough.
    private func authenticatedSession(
        config: HotspotConfig,
        base: String
    ) async throws -> (session: URLSession, model: [String: Any]) {
        if let cookies = cachedCookies[base] {
            let session = sessionWithCookies(cookies)

            if let model = try? await fetchModel(session, base: base),
               isAuthenticated(model) {
                return (session, model)
            }

            dropCookies(for: base)
        }

        return try await fullAuth(config: config, base: base)
    }

    /// Extracts the CSRF token a `/Forms/config` write must carry.
    private func secToken(from model: [String: Any]) throws -> String {
        guard let token = stringValue(model, "session.secToken"),
              !token.isEmpty else {
            throw ProviderError("Router returned an unexpected response")
        }

        return token
    }

    /// Forgets the cached cookie for a base URL so the next call re-logs in.
    private func dropCookies(for base: String) {
        cachedCookies[base] = nil
        persistCookies()
    }

    // MARK: - Fast-path helper

    /// Outcome of an attempt to refresh metrics with the cached cookie.
    private enum FastPathResult {
        case success(RouterMetrics)
        case stale       // Cookie rejected by router or response missing wwan data.
        case timedOut    // Both attempts exceeded the short fast-path timeout.
    }

    /// Tries up to two short-timeout fetches with the cached auth cookie.
    /// Returns `.success` on the first authenticated response, `.stale` when
    /// the router responds but rejects the cookie, and `.timedOut` only when
    /// every attempt ran out of time.
    private func tryFastPath(
        cookies: [HTTPCookie],
        base: String
    ) async -> FastPathResult {
        let attempts = 2

        for attempt in 1...attempts {
            do {
                let model = try await fetchModel(
                    sessionWithCookies(cookies, requestTimeout: 5), base: base
                )

                // session.userRole == "Admin" means the cookie is still valid.
                if isAuthenticated(model) {
                    return .success(extractMetrics(from: model, baseURL: base))
                }

                // Valid HTTP response but unauthenticated — stale cookie.
                return .stale
            } catch let urlErr as URLError where urlErr.code == .timedOut {
                if attempt == attempts { return .timedOut }
                // Otherwise: retry.
            } catch {
                // Other network error — treat as stale so we proceed to full auth.
                return .stale
            }
        }

        return .stale
    }

    /// Builds a fresh ephemeral session pre-seeded with cached auth cookies.
    private func sessionWithCookies(
        _ cookies: [HTTPCookie],
        requestTimeout: TimeInterval = 8
    ) -> URLSession {
        let session = makeFreshSession(requestTimeout: requestTimeout)

        if let storage = session.configuration.httpCookieStorage {
            for cookie in cookies { storage.setCookie(cookie) }
        }

        return session
    }

    /// Returns `true` when `session.userRole` is "Admin". The router returns
    /// this field in every model.json response; an expired or missing cookie
    /// yields a non-Admin role (e.g. "Guest") even if `wwan.connection` is
    /// present in the reduced public model.
    private func isAuthenticated(_ model: [String: Any]) -> Bool {
        (nestedValue(model, "session.userRole") as? String)?
            .caseInsensitiveCompare("Admin") == .orderedSame
    }

    // MARK: - Base URL normalisation

    /// Strips trailing slashes. The URL's host is used as-is — URLSession sets
    /// the `Host` header from it automatically, so no override is needed.
    private func normalizedBase(_ raw: String) -> String {
        raw.trimmingCharacters(
            in: CharacterSet(charactersIn: "/").union(.whitespaces)
        )
    }

    // MARK: - URLSession factory

    /// Creates an ephemeral session that accepts and sends cookies but shares
    /// no state with other sessions. Proxies are disabled so VPN-injected
    /// system proxies don't intercept requests to the local router IP.
    private func makeFreshSession(requestTimeout: TimeInterval = 8) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral

        cfg.httpCookieAcceptPolicy     = .always
        cfg.httpShouldSetCookies       = true
        cfg.timeoutIntervalForRequest  = requestTimeout
        cfg.timeoutIntervalForResource = max(requestTimeout + 4, 12)
        cfg.connectionProxyDictionary  = [:]

        return URLSession(configuration: cfg)
    }

    // MARK: - HTTP primitives

    /// GETs `/api/model.json` — the router's single state document, and the
    /// only JSON endpoint this provider reads. The path is built here so no
    /// call site has to repeat it.
    private func fetchModel(
        _ session: URLSession,
        base: String
    ) async throws -> [String: Any] {
        guard let url = URL(string: "\(base)/api/model.json") else {
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

    /// POSTs a form-encoded write to `/Forms/config` on an already
    /// authenticated session.
    ///
    /// The router answers with a redirect to `ok_redirect` / `err_redirect`,
    /// which URLSession follows transparently — so a rejected write arrives
    /// as HTTP 200 carrying an `errno` payload, not as an error status. Both
    /// failure shapes are checked.
    private func postConfig(
        _ session: URLSession,
        baseURL: String,
        secToken: String,
        fields: [String: String]
    ) async throws {
        guard let url = URL(string: "\(baseURL)/Forms/config") else {
            throw ProviderError("Invalid router URL — check Settings")
        }

        var pairs: [(String, String)] = [
            ("token",        secToken),
            ("ok_redirect",  "/success.json"),
            ("err_redirect", "/error.json"),
        ]
        pairs.append(contentsOf: fields.sorted { $0.key < $1.key })

        let body: String = pairs
            .map { key, val in "\(key)=\(formEncode(val))" }
            .joined(separator: "&")

        var req = URLRequest(url: url)

        req.httpMethod = "POST"
        req.setValue(
            "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"
        )
        req.httpBody = body.data(using: .utf8)

        let (data, response) = try await session.data(for: req)

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        if statusCode < 200 || statusCode >= 300 {
            throw ProviderError("Router rejected the request (HTTP \(statusCode))")
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errno = json["errno"] {
            let detail = json["errdetail"] as? String ?? String(describing: errno)
            throw ProviderError("Router rejected the request (\(detail))")
        }
    }

    /// Percent-encodes a form value so that `&`, `=`, `+`, etc. are escaped.
    private func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")

        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: - Cookie persistence (Keychain)

    /// Serialises the cookie cache to a binary plist and stores it as a
    /// single Keychain item (cookies are session credentials — they don't
    /// belong in plain-text UserDefaults). Only plist-safe types (String,
    /// Date, NSNumber, URL-as-String) are kept.
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

        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: serialized, format: .binary, options: 0
        ) else { return }

        KeychainStore.writeData(data, account: Self.cookiesKeychainAccount)
    }

    /// Deserialises the cookie cache from the Keychain.
    private static func loadCookies() -> [String: [HTTPCookie]] {
        guard let data = KeychainStore.readData(account: cookiesKeychainAccount),
              let raw  = (try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              )) as? [String: [[String: Any]]] else {
            return [:]
        }

        return cookies(fromPlist: raw)
    }

    /// Rebuilds HTTPCookie values from their plist representation.
    private static func cookies(
        fromPlist raw: [String: [[String: Any]]]
    ) -> [String: [HTTPCookie]] {
        raw.compactMapValues { dicts in
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
