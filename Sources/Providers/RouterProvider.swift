import Foundation

// MARK: - Protocol

protocol RouterProvider {
    /// Fetch current metrics from the router.
    func fetchMetrics(config: HotspotConfig, baseURL: String) async throws -> RouterMetrics
}

// MARK: - Typed error

struct ProviderError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { self.errorDescription = message }
}
