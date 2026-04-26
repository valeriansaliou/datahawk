import Foundation

/// Drives the periodic polling of the active hotspot's router API.
/// Call `start(with:)` when a known hotspot is detected and `stop()` on
/// disconnect.  All `AppState` mutations happen on the main actor.
class RouterService {
    static let shared = RouterService()

    private let pollInterval: TimeInterval = 60
    private var pollingTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var currentConfig: HotspotConfig?

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

    func start(with config: HotspotConfig) {
        stop()
        currentConfig = config
        pollingTask = Task {
            // Immediate first fetch, then repeat every pollInterval seconds.
            await fetchAndPublish(config: config)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                if !Task.isCancelled {
                    await fetchAndPublish(config: config)
                }
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
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
        default:       return "http://192.168.1.1"
        }
    }

    // MARK: - Fetch

    private func fetchAndPublish(config: HotspotConfig) async {
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
                AppState.shared.fetchError      = error.localizedDescription
                AppState.shared.fetchingFromURL = nil
                AppState.shared.isFetching      = false
                // Keep .connected so we don't lose the last good metrics.
                if AppState.shared.metrics != nil {
                    AppState.shared.connectionState = .connected
                }
            }
        }
    }
}
