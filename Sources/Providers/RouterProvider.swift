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

    /// Marks a single received text message as read on the router.
    ///
    /// - Parameters:
    ///   - id:      The message identifier as reported in `RouterMetrics.smsMessages`.
    ///   - config:  The hotspot configuration (credentials, vendor, etc.).
    ///   - baseURL: Resolved admin URL for the router.
    /// - Throws: `ProviderError` when the router rejects the write, or
    ///           `URLError` for transport-level issues.
    func markSMSRead(id: String, config: HotspotConfig, baseURL: String) async throws

    /// Deletes every text message currently stored on the router.
    ///
    /// - Parameters:
    ///   - config:  The hotspot configuration (credentials, vendor, etc.).
    ///   - baseURL: Resolved admin URL for the router.
    /// - Returns: The router's state as read back *after* the wipe, so the
    ///            caller can publish the authoritative message list without
    ///            paying for a second round-trip.
    /// - Throws: `ProviderError` when the router rejects the delete, or
    ///           `URLError` for transport-level issues.
    func deleteAllSMS(config: HotspotConfig, baseURL: String) async throws -> RouterMetrics
}

extension RouterProvider {
    func flushAuth() async {}

    /// Vendors without an SMS write API inherit this. Surfaced to the user
    /// rather than silently ignored, so a half-supported router is obvious.
    func markSMSRead(id: String, config: HotspotConfig, baseURL: String) async throws {
        throw ProviderError("This router does not support marking messages as read")
    }

    /// Vendors without an SMS write API inherit this.
    func deleteAllSMS(config: HotspotConfig, baseURL: String) async throws -> RouterMetrics {
        throw ProviderError("This router does not support deleting messages")
    }
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
