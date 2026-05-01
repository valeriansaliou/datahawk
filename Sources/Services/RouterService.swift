// RouterService.swift
// DataHawk
//
// Drives the periodic polling of the active hotspot's router API. Call
// `start(with:)` when a known hotspot is detected and `stop()` on
// disconnect. All AppState mutations happen on the main actor.

import Foundation

// MARK: - Single-flight gate

/// Serialises concurrent fetch attempts. Whichever caller acquires first
/// runs the HTTP cycle; subsequent callers return immediately so the
/// in-flight requests are never aborted by a competing fetch.
private actor FetchGate {
    private var inFlight = false

    func tryAcquire() -> Bool {
        guard !inFlight else { return false }

        inFlight = true
        return true
    }

    func release() {
        inFlight = false
    }
}

// MARK: - Router service

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
    private let fetchGate = FetchGate()

    /// One provider instance per vendor. Looked up by `HotspotConfig.vendor`.
    private let providers: [RouterVendor: any RouterProvider] = [
        .netgear: NetgearProvider(),
    ]

    private init() {}

    // MARK: - Public control

    /// Triggers a single ad-hoc refresh (soft — reuses cached auth).
    func refresh() {
        guard let config = currentConfig else { return }

        refreshTask?.cancel()
        refreshTask = Task {
            await fetchAndPublish(config: config)
        }
    }

    /// Flushes all cached auth state and metrics, then performs a full
    /// re-authentication cycle. Use when the user Option-clicks Refresh.
    func forceFullRefresh() {
        guard let config = currentConfig else { return }

        // Discard cached cookies / tokens for this vendor.
        providers[config.vendor]?.flushAuth()

        Task { @MainActor in
            AppState.shared.metrics    = nil
            AppState.shared.fetchError = nil
        }

        // Restart the polling loop from scratch.
        start(with: config)
    }

    /// Begins periodic polling for the given hotspot. Cancels any previous
    /// polling loop first so there is never more than one active loop.
    func start(with config: HotspotConfig) {
        stop()

        currentConfig = config

        pollingTask = Task {
            // Immediate first fetch, then repeat at the configured interval.
            await fetchAndPublish(config: config)

            while !Task.isCancelled {
                // Use a shorter interval when the fetch failed or when the
                // router's cellular connection is not yet "Connected", so
                // the UI catches the transition to connected quickly.
                let useRetryInterval = await MainActor.run {
                    let state = AppState.shared.connectionState
                    let routerConnected = AppState.shared.metrics?.isRouterConnected ?? false
                    return state == .failed || (state == .connected && !routerConnected)
                }

                let interval = useRetryInterval ? retryInterval : pollInterval

                try? await Task.sleep(for: .seconds(interval))

                guard !Task.isCancelled else { break }

                await fetchAndPublish(config: config)
            }
        }
    }

    /// Cancels all in-flight and scheduled work and releases the fetch gate
    /// so the next `start(with:)` can acquire it immediately.
    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        refreshTask?.cancel()
        refreshTask = nil

        // Release the gate so the next start() can fetch immediately.
        // We await it to avoid a fire-and-forget race where start() calls
        // tryAcquire() before the release has landed.
        Task { await fetchGate.release() }
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

    /// Runs a single fetch-and-publish cycle. Protected by `FetchGate` to
    /// ensure only one HTTP cycle runs at a time.
    private func fetchAndPublish(config: HotspotConfig) async {
        // Single-flight: if another fetch is already in progress, bail out
        // so we don't abort in-flight HTTP requests.
        guard await fetchGate.tryAcquire() else { return }
        defer { Task { await self.fetchGate.release() } }

        guard let provider = providers[config.vendor] else {
            await MainActor.run {
                AppState.shared.fetchError =
                    "No provider available for \(config.vendor.rawValue)"
            }

            return
        }

        let base = baseURL(for: config)

        // Transition to .loading on the very first fetch (no metrics yet).
        await MainActor.run {
            if AppState.shared.metrics == nil {
                AppState.shared.connectionState = .loading
            }

            AppState.shared.fetchingFromURL = base
            AppState.shared.isFetching      = true
        }

        do {
            let metrics = try await provider.fetchMetrics(config: config, baseURL: base)

            await MainActor.run {
                AppState.shared.metrics         = metrics
                AppState.shared.connectionState = .connected
                AppState.shared.lastUpdated     = Date()
                AppState.shared.fetchError      = nil
                AppState.shared.fetchingFromURL = nil
                AppState.shared.isFetching      = false
            }
        } catch {
            await MainActor.run {
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
