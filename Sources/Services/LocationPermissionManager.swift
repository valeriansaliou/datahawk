// LocationPermissionManager.swift
// DataHawk
//
// Wraps CLLocationManager to request the "always" location authorisation that
// macOS requires before CoreWLAN's CWInterface.bssid() returns a real value.
//
// Usage:
//   1. Set `onAuthorizationChange` to a callback.
//   2. Call `requestIfNeeded()` once at launch.
//   3. The callback fires whenever the user grants or denies the prompt,
//      and once immediately if permission was already granted.

import CoreLocation

@MainActor
final class LocationPermissionManager: NSObject, CLLocationManagerDelegate {
    static let shared = LocationPermissionManager()

    private let manager = CLLocationManager()

    /// Called on the main actor whenever the authorisation status changes.
    var onAuthorizationChange: (@MainActor () -> Void)?

    // MARK: - Init

    private override init() {
        super.init()

        manager.delegate = self
    }

    // MARK: - Public API

    /// `true` when location access has been granted ("always" is needed for
    /// background BSSID detection on macOS).
    var isAuthorized: Bool {
        manager.authorizationStatus == .authorizedAlways
    }

    /// Presents the system permission dialog if the user hasn't decided yet.
    /// If permission was already granted, fires the callback immediately so
    /// that callers don't need a separate "already authorised" code path.
    func requestIfNeeded() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestAlwaysAuthorization()
        case .authorizedAlways:
            // Already good — notify immediately.
            onAuthorizationChange?()
        default:
            break
        }
    }

    // MARK: - CLLocationManagerDelegate

    // nonisolated to satisfy the protocol; the manager lives on the main run
    // loop, so the callback arrives on the main actor (assumeIsolated traps
    // if that invariant is ever violated).
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            onAuthorizationChange?()
        }
    }
}
