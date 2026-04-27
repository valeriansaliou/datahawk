// RouterProvider.swift
// DataHawk
//
// Defines the contract that every router vendor implementation must satisfy.
// Each provider translates a vendor-specific admin API into the common
// `RouterMetrics` value type consumed by the rest of the app.

import Foundation

// MARK: - Provider protocol

protocol RouterProvider {
    /// Fetches the current metrics snapshot from the router.
    ///
    /// - Parameters:
    ///   - config:  The hotspot configuration (credentials, vendor, etc.).
    ///   - baseURL: Resolved admin URL for the router (may be auto-detected or
    ///              user-overridden).
    /// - Returns: A fully populated `RouterMetrics` value.
    /// - Throws: `ProviderError` for domain-specific failures, or `URLError`
    ///           for transport-level issues.
    func fetchMetrics(config: HotspotConfig, baseURL: String) async throws -> RouterMetrics

    /// Discards all cached authentication state (cookies, tokens, etc.) so
    /// that the next `fetchMetrics` call performs a full login.
    /// The default implementation is a no-op for providers that don't cache.
    func flushAuth()
}

extension RouterProvider {
    func flushAuth() {}
}

// MARK: - Provider error

/// A human-readable error surfaced in the popover's error banner.
/// Providers throw this instead of raw `URLError` when they can give the
/// user a more actionable message (e.g. "check username / password").
struct ProviderError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        self.errorDescription = message
    }
}
