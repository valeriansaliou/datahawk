import Foundation

/// Serialises concurrent fetch attempts: whichever caller acquires first runs;
/// subsequent callers return immediately so the in-flight HTTP requests are
/// never aborted by a competing fetch cycle.
private actor FetchGate {
    private var inFlight = false
    func tryAcquire() -> Bool {
        guard !inFlight else { return false }
        inFlight = true
        return true
    }
    func release() { inFlight = false }
}

/// Drives the periodic polling of the active hotspot's router API.
/// Call `start(with:)` when a known hotspot is detected and `stop()` on
/// disconnect.  All `AppState` mutations happen on the main actor.
class RouterService {
    static let shared = RouterService()

    private var pollInterval      : TimeInterval { TimeInterval(ConfigStore.shared.refreshInterval) }
    private let retryInterval     : TimeInterval = 10
    private var pollingTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var currentConfig: HotspotConfig?
    private let fetchGate = FetchGate()

    private let providers: [RouterVendor: any RouterProvider] = [
        .netgear: NetgearProvider(),
    ]

    private init() {}

    // MARK: - Control

    func refresh() {
        guard let config = currentConfig else { return }
        refreshTask?.cancel()
        refreshTask = Task {
            await fetchAndPublish(config: config)
        }
    }

    /// Flushes all cached auth state and metrics, then runs a full re-authentication cycle.
    func forceFullRefresh() {
        guard let config = currentConfig else { return }
        providers[config.vendor]?.flushAuth()
        Task { @MainActor in
            AppState.shared.metrics      = nil
            AppState.shared.fetchError   = nil
        }
        start(with: config)
    }

    func start(with config: HotspotConfig) {
        stop()
        currentConfig = config
        pollingTask = Task {
            // Immediate first fetch, then repeat every pollInterval seconds.
            await fetchAndPublish(config: config)
            while !Task.isCancelled {
                let isFailed = await MainActor.run { AppState.shared.connectionState == .failed }
                let interval = isFailed ? retryInterval : pollInterval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if !Task.isCancelled {
                    await fetchAndPublish(config: config)
                }
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        // Release the gate so the next start() can fetch immediately.
        Task { await fetchGate.release() }
    }

    // MARK: - Base URL resolution

    /// Resolves the base URL synchronously — no subprocesses, no blocking.
    /// NETGEAR Nighthawk devices always use `mywebui` as their local hostname.
    /// Other vendors fall back to 192.168.1.1 unless a custom URL is set.
    private func baseURL(for config: HotspotConfig) -> String {
        if let custom = config.customBaseURL, !custom.isEmpty {
            return custom.trimmingCharacters(in: CharacterSet(charactersIn: "/").union(.whitespaces))
        }
        switch config.vendor {
        case .netgear: return "http://mywebui"
        }
    }

    // MARK: - Fetch

    private func fetchAndPublish(config: HotspotConfig) async {
        // Single-flight gate: if a fetch is already in progress, return immediately
        // so in-flight HTTP requests are never aborted by a competing cycle.
        guard await fetchGate.tryAcquire() else { return }
        defer { Task { await self.fetchGate.release() } }

        guard let provider = providers[config.vendor] else {
            await MainActor.run {
                AppState.shared.fetchError = "No provider available for \(config.vendor.rawValue)"
            }
            return
        }

        let base = baseURL(for: config)

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
                    // No data yet — surface a failed state so the icon
                    // stops blinking and the header says "Could not refresh".
                    AppState.shared.connectionState = .failed
                }
            }
        }
    }

    // MARK: - Error formatting

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
            case .notConnectedToInternet:      return "No internet connection"
            case .userAuthenticationRequired:  return "Authentication required"
            case .badServerResponse:           return "Unexpected response from router"
            default:                           return "Network error (\(urlError.code.rawValue))"
            }
        }
        return error.localizedDescription
    }
}
