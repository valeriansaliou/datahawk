// RouterService.swift
// DataHawk
//
// Drives the periodic polling of the active hotspot's router API. Call
// `start(with:)` when a known hotspot is detected and `stop()` on
// disconnect. The service is @MainActor-isolated: the polling Task inherits
// the main actor, so AppState/ConfigStore access is direct and the main
// thread is only ever suspended (never blocked) across provider awaits.

import Foundation

// MARK: - Router service

@MainActor
final class RouterService {
    static let shared = RouterService()

    // MARK: - Configuration

    /// Live polling interval read from the user's settings on every cycle.
    private var pollInterval: TimeInterval {
        TimeInterval(ConfigStore.shared.refreshInterval)
    }

    /// Shorter interval used when the last fetch failed, so recovery is fast.
    private let retryInterval: TimeInterval = 10

    // MARK: - Internal state

    private var pollingTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var currentConfig: HotspotConfig?

    /// One provider instance per vendor. Looked up by `HotspotConfig.vendor`.
    private let providers: [RouterVendor: any RouterProvider] = [
        .netgear: NetgearProvider(),
    ]

    private init() {}

    // MARK: - Public control

    /// Triggers a single ad-hoc refresh (soft — reuses cached auth).
    /// No-ops while a cycle is already in flight — that cycle will deliver
    /// fresh data anyway, and skipping avoids queueing duplicate HTTP cycles
    /// on the provider when the button is clicked repeatedly.
    func refresh() {
        guard let config = currentConfig else { return }
        guard !AppState.shared.isFetching else { return }

        refreshTask?.cancel()
        refreshTask = Task {
            await fetchAndPublish(config: config)
        }
    }

    /// Flushes all cached auth state and metrics, then performs a full
    /// re-authentication cycle. Use when the user Option-clicks Refresh.
    func forceFullRefresh() {
        guard let config = currentConfig else { return }

        AppState.shared.metrics    = nil
        AppState.shared.fetchError = nil

        // Restart the polling loop from scratch. The auth flush happens
        // inside the new polling task, before its first fetch, so the flush
        // and the re-authentication are strictly ordered on the provider.
        start(with: config, flushAuthFirst: true)
    }

    /// Begins periodic polling for the given hotspot. Cancels any previous
    /// polling loop first so there is never more than one active loop.
    /// When `flushAuthFirst` is set, cached provider auth state is discarded
    /// before the first fetch (full re-login).
    func start(with config: HotspotConfig, flushAuthFirst: Bool = false) {
        stop()

        currentConfig = config

        pollingTask = Task {
            if flushAuthFirst {
                await providers[config.vendor]?.flushAuth()
            }

            // Immediate first fetch, then repeat at the configured interval.
            await fetchAndPublish(config: config)

            while !Task.isCancelled {
                // Use a shorter interval when the fetch failed or when the
                // router's cellular connection is not yet "Connected", so
                // the UI catches the transition to connected quickly.
                let state = AppState.shared.connectionState
                let routerConnected = AppState.shared.metrics?.isRouterConnected ?? false
                let useRetryInterval =
                    state == .failed || (state == .connected && !routerConnected)

                let interval = useRetryInterval ? retryInterval : pollInterval

                try? await Task.sleep(for: .seconds(interval))

                guard !Task.isCancelled else { break }

                await fetchAndPublish(config: config)
            }
        }
    }

    // MARK: - SMS actions

    /// Marks a text message as read on the router.
    ///
    /// The flag is flipped locally first so the list row and the menu-bar
    /// unread badge react instantly, then written to the router; a failed
    /// write is rolled back. A successful one is followed by a refresh so the
    /// router stays the source of truth.
    ///
    /// - Returns: `nil` on success, a human-readable error string on failure.
    @discardableResult
    func markSMSRead(id: String) async -> String? {
        guard let config = currentConfig,
              let provider = providers[config.vendor] else { return nil }

        // Unknown id, or the router already considers it read — nothing to do.
        // This also collapses repeat calls for a message opened twice.
        guard AppState.shared.metrics?
            .smsMessages.first(where: { $0.id == id })?.isRead == false else { return nil }

        setLocalReadFlag(id: id, isRead: true)

        do {
            try await provider.markSMSRead(
                id: id, config: config, baseURL: baseURL(for: config)
            )
        } catch {
            setLocalReadFlag(id: id, isRead: false)

            return Self.humanReadable(error)
        }

        // Reconcile: the router recomputes the unread count, and messages may
        // have arrived while the write was in flight.
        refresh()

        return nil
    }

    /// Deletes every text message stored on the router.
    ///
    /// Unlike `markSMSRead` this is not optimistic: the write can fail, so
    /// nothing is cleared locally. The provider reads `model.json` back once
    /// the router confirms the wipe and returns that snapshot, which is
    /// published here — so by the time this returns the UI already shows the
    /// authoritative list. A failure falls back to a plain refresh.
    ///
    /// - Returns: `nil` on success, a human-readable error string on failure.
    @discardableResult
    func deleteAllSMS() async -> String? {
        guard let config = currentConfig,
              let provider = providers[config.vendor] else { return nil }

        do {
            let metrics = try await provider.deleteAllSMS(
                config: config, baseURL: baseURL(for: config)
            )

            AppState.shared.metrics     = metrics
            AppState.shared.lastUpdated = Date()

            return nil
        } catch {
            // Resync: the wipe may have landed partially, or not at all.
            refresh()

            return Self.humanReadable(error)
        }
    }

    // MARK: - Data usage actions

    /// Resets the router's billing-cycle data usage counter.
    ///
    /// Like `deleteAllSMS`, not optimistic: the provider reads `model.json`
    /// back once the router confirms the write and that snapshot is published
    /// here, so the zeroed counter is on screen by the time this returns. A
    /// failure falls back to a plain refresh.
    ///
    /// `isFetching` is raised for the duration so the popover's header spinner
    /// reports the in-flight write — the confirmation alert is a standard
    /// `NSAlert` and closes on click, so this is where the progress shows.
    ///
    /// - Returns: `nil` on success, a human-readable error string on failure.
    @discardableResult
    func resetDataUsage() async -> String? {
        guard let config = currentConfig,
              let provider = providers[config.vendor] else {
            return "No hotspot is currently connected"
        }

        AppState.shared.isFetching = true

        do {
            let metrics = try await provider.resetDataUsage(
                config: config, baseURL: baseURL(for: config)
            )

            AppState.shared.metrics     = metrics
            AppState.shared.lastUpdated = Date()
            AppState.shared.isFetching  = false

            return nil
        } catch {
            // Lowered before the resync: refresh() no-ops while isFetching.
            AppState.shared.isFetching = false

            // Resync: the reset may have landed even though the read-back failed.
            refresh()

            return Self.humanReadable(error)
        }
    }

    /// Flips the read flag of one message inside the published metrics and
    /// keeps `smsUnreadCount` in sync. No-op when the message is gone or
    /// already in the requested state.
    ///
    /// Republishing `metrics` re-runs the observers of `AppState.$metrics`,
    /// but every value other than the SMS flags is identical — notification
    /// transitions don't fire and the session tracker just re-samples the
    /// same signal reading.
    private func setLocalReadFlag(id: String, isRead: Bool) {
        guard var metrics = AppState.shared.metrics,
              let index = metrics.smsMessages.firstIndex(where: { $0.id == id }),
              metrics.smsMessages[index].isRead != isRead else { return }

        metrics.smsMessages[index].isRead = isRead
        metrics.smsUnreadCount = max(0, metrics.smsUnreadCount + (isRead ? -1 : 1))

        AppState.shared.metrics = metrics
    }

    /// Cancels all in-flight and scheduled work. Cancellation propagates
    /// into URLSession, so an in-flight HTTP cycle aborts promptly; its
    /// post-await cancellation guards prevent it from publishing anything.
    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    // MARK: - Base URL resolution

    /// Resolves the admin URL for the given hotspot. NETGEAR Nighthawk
    /// devices always use `mywebui` as their local hostname; other vendors
    /// would fall back to 192.168.1.1 unless a custom URL is set.
    private func baseURL(for config: HotspotConfig) -> String {
        if let custom = config.customBaseURL, !custom.isEmpty {
            return custom.trimmingCharacters(
                in: CharacterSet(charactersIn: "/").union(.whitespaces)
            )
        }

        switch config.vendor {
        case .netgear:
            return "http://mywebui"
        }
    }

    // MARK: - Fetch cycle

    /// Runs a single fetch-and-publish cycle. HTTP cycles serialise on the
    /// provider actor: a competing cycle queues behind the in-flight one
    /// instead of aborting it, so no explicit single-flight gate is needed.
    private func fetchAndPublish(config: HotspotConfig) async {
        guard let provider = providers[config.vendor] else {
            AppState.shared.fetchError =
                "No provider available for \(config.vendor.rawValue)"
            return
        }

        let base = baseURL(for: config)

        // Transition to .loading on the very first fetch (no metrics yet).
        if AppState.shared.metrics == nil {
            AppState.shared.connectionState = .loading
        }

        AppState.shared.fetchingFromURL = base
        AppState.shared.isFetching      = true

        do {
            let metrics = try await provider.fetchMetrics(config: config, baseURL: base)

            // A cancelled cycle (stop() / hotspot switch) must not publish:
            // by now AppState may describe a different hotspot, or none.
            guard !Task.isCancelled else { return }

            AppState.shared.metrics         = metrics
            AppState.shared.connectionState = .connected
            AppState.shared.lastUpdated     = Date()
            AppState.shared.fetchError      = nil
            AppState.shared.fetchingFromURL = nil
            AppState.shared.isFetching      = false
        } catch {
            // Cancellation surfaces as an error (URLError.cancelled /
            // CancellationError) — that's teardown, not a fetch failure.
            guard !Task.isCancelled else { return }

            AppState.shared.fetchError      = Self.humanReadable(error)
            AppState.shared.fetchingFromURL = nil
            AppState.shared.isFetching      = false

            if AppState.shared.metrics != nil {
                // Keep .connected so we don't lose the last good metrics.
                AppState.shared.connectionState = .connected
            } else {
                // No data yet — show a failed state so the icon stops
                // blinking and the header says "Could not refresh".
                AppState.shared.connectionState = .failed
            }
        }
    }

    // MARK: - Error formatting

    /// Converts a raw error into a short, human-readable string suitable
    /// for the popover's error banner.
    private static func humanReadable(_ error: Error) -> String {
        if let providerError = error as? ProviderError {
            return providerError.errorDescription ?? "Unknown error"
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:                    return "Connection timed out"
            case .cannotFindHost,
                 .cannotConnectToHost,
                 .dnsLookupFailed:             return "Router unreachable"
            case .networkConnectionLost:       return "Network connection lost"
            case .notConnectedToInternet:      return "No network connection"
            case .userAuthenticationRequired:  return "Authentication required"
            case .badServerResponse:           return "Unexpected response from router"
            default:                           return "Network error (\(urlError.code.rawValue))"
            }
        }

        return error.localizedDescription
    }
}
