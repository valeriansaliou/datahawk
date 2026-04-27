import Foundation

// MARK: - Protocol

protocol RouterProvider {
    /// Fetch current metrics from the router.
    func fetchMetrics(config: HotspotConfig, baseURL: String) async throws -> RouterMetrics
    /// Flush all cached auth state (cookies, tokens, etc.).  Default: no-op.
    func flushAuth()
}

extension RouterProvider {
    func flushAuth() {}
}

// MARK: - Typed error

struct ProviderError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { self.errorDescription = message }
}
