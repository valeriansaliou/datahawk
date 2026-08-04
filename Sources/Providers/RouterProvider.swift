// RouterProvider.swift
// DataHawk
//
// Defines the contract that every router vendor implementation must satisfy.
// Each provider translates a vendor-specific admin API into the common
// `RouterMetrics` value type consumed by the rest of the app.

import Foundation

// MARK: - Provider protocol

/// Refines Sendable: provider instances cross isolation domains (created on
/// the main actor, awaited from polling tasks). Actor implementations are
/// implicitly Sendable; a class implementation must be thread-safe.
protocol RouterProvider: Sendable {
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
    /// Async so that actor-based providers can satisfy it with an isolated
    /// method (state mutation is then serialised with in-flight fetches).
    func flushAuth() async
}

extension RouterProvider {
    func flushAuth() async {}
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
