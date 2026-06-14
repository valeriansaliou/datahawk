// SessionTracker.swift
// DataHawk
//
// Combine-based service that tracks hotspot connection sessions. Watches
// AppState for connect/disconnect transitions, samples signal bars on every
// poll cycle, requests a one-shot CLLocation fix at session open, and checks
// for significant movement every 10 minutes to split sessions automatically.
//
// All AppState Combine subscriptions deliver on the main thread (AppState
// mutations are always main-thread). The CLLocationManager is created on the
// main thread (via the static singleton), so delegate callbacks also arrive
// on the main thread. Timer callbacks fire on the main run loop.

import Foundation
import Combine
import CoreLocation

final class SessionTracker: NSObject, CLLocationManagerDelegate {
    static let shared = SessionTracker()

    private var activeSession: SessionRecord?
    private var cancellables: Set<AnyCancellable> = []
    private var locationManager: CLLocationManager
    private var locationCheckTimer: Timer?
    private var lastKnownLocation: CLLocation?
    private var isAwaitingFirstFix = false
    private var lastSamplePersist: Date = .distantPast

    /// How long to wait between location checks (debounces rapid movement).
    private let locationCheckInterval: TimeInterval = 600  // 10 minutes
    /// Minimum movement to consider the user in a new location.
    private let locationChangeDist: CLLocationDistance = 100  // metres
    /// Fixed interval between signal-sample DB flushes, independent of refresh interval.
    private let samplePersistInterval: TimeInterval = 300   // 5 minutes

    private override init() {
        locationManager = CLLocationManager()
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    // MARK: - Public API

    func start() {
        // Close sessions left open by a crash on the previous run. A clean exit
        // always calls closeOnTermination(), so any open session at startup is
        // an orphan. Stamp them with the current time as the best approximation.
        closeOrphanedSessions()

        // React to the feature toggle changing after launch.
        ConfigStore.shared.$recordSessionHistory
            .dropFirst()
            .sink { [weak self] enabled in
                if enabled {
                    // Just enabled — start a session immediately if connected.
                    guard AppState.shared.connectionState == .connected else { return }
                    self?.openSession()
                } else {
                    // Just disabled — close any running session before going dark.
                    self?.closeActiveSession()
                }
            }
            .store(in: &cancellables)

        // Open / close sessions on connection state transitions.
        AppState.shared.$connectionState
            .scan((ConnectionState.noHotspot, ConnectionState.noHotspot)) { ($0.1, $1) }
            .sink { [weak self] previous, current in
                self?.handleStateTransition(from: previous, to: current)
            }
            .store(in: &cancellables)

        // Sample signal bars on every metrics update.
        AppState.shared.$metrics
            .compactMap { $0 }
            .sink { [weak self] metrics in
                self?.recordSample(from: metrics)
            }
            .store(in: &cancellables)
    }

    /// Called from applicationWillTerminate — closes the active session cleanly.
    func closeOnTermination() {
        closeActiveSession()
    }

    /// Closes the current session and immediately opens a fresh one. Only
    /// meaningful when the router is connected; no-ops otherwise.
    func forceRestartSession() {
        guard ConfigStore.shared.recordSessionHistory else { return }
        closeActiveSession()
        if AppState.shared.connectionState == .connected {
            openSession()
        }
    }

    // MARK: - Crash recovery

    private func closeOrphanedSessions() {
        guard ConfigStore.shared.recordSessionHistory else { return }
        let orphans = SessionStore.shared.sessions.filter { $0.isActive }
        guard !orphans.isEmpty else { return }
        let now = Date()
        for var session in orphans {
            session.endDate = now
            SessionStore.shared.upsert(session)
        }
        print("[DataHawk] Closed \(orphans.count) orphaned session(s) from previous run.")
    }

    // MARK: - Session lifecycle

    private func handleStateTransition(from previous: ConnectionState, to current: ConnectionState) {
        guard ConfigStore.shared.recordSessionHistory else { return }

        if current == .connected, previous != .connected {
            openSession()
        } else if previous == .connected, current != .connected {
            closeActiveSession()
        }
    }

    private func openSession() {
        let metrics = AppState.shared.metrics
        var session = SessionRecord(
            startDate: Date(),
            hotspotName: AppState.shared.activeHotspot?.name ?? "",
            hotspotBSSID: AppState.shared.activeHotspot?.normalizedMAC,
            provider: metrics?.provider,
            generation: metrics?.networkType.rawValue,
            isRoaming: metrics?.isRoaming,
            dataStartGB: metrics?.dataUsedGB
        )
        if let bars = metrics?.signalStrength {
            session.signalSamples = [bars]
        }

        activeSession = session
        lastSamplePersist = Date()
        SessionStore.shared.upsert(session)
        requestLocationFix()
        startLocationTimer()
    }

    private func closeActiveSession() {
        guard var session = activeSession else { return }
        let metrics = AppState.shared.metrics
        session.endDate = Date()
        if let dataEnd = metrics?.dataUsedGB { session.dataEndGB = dataEnd }

        activeSession = nil
        stopLocationTimer()
        lastKnownLocation = nil

        SessionStore.shared.upsert(session)
    }

    private func recordSample(from metrics: RouterMetrics) {
        guard activeSession != nil else { return }
        activeSession?.signalSamples.append(metrics.signalStrength)
        // Flush to disk every 5 minutes regardless of the configured refresh interval.
        let now = Date()
        if now.timeIntervalSince(lastSamplePersist) >= samplePersistInterval {
            lastSamplePersist = now
            if let s = activeSession { SessionStore.shared.upsert(s) }
        }
    }

    // MARK: - Location

    private var isLocationAuthorized: Bool {
        let s = locationManager.authorizationStatus
        return s == .authorizedAlways || s == .authorized
    }

    private func requestLocationFix() {
        guard isLocationAuthorized else { return }
        isAwaitingFirstFix = true
        locationManager.requestLocation()
    }

    private func startLocationTimer() {
        locationCheckTimer?.invalidate()
        locationCheckTimer = Timer.scheduledTimer(
            withTimeInterval: locationCheckInterval,
            repeats: true
        ) { [weak self] _ in
            guard let self, self.isLocationAuthorized else { return }
            self.locationManager.requestLocation()
        }
    }

    private func stopLocationTimer() {
        locationCheckTimer?.invalidate()
        locationCheckTimer = nil
        isAwaitingFirstFix = false
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last else { return }

        if isAwaitingFirstFix {
            isAwaitingFirstFix = false
            lastKnownLocation = fix
            guard activeSession != nil else { return }

            activeSession?.location = SessionLocation(
                latitude: fix.coordinate.latitude,
                longitude: fix.coordinate.longitude
            )
            if let s = activeSession { SessionStore.shared.upsert(s) }

            geocode(fix) { [weak self] name in
                guard var s = self?.activeSession else { return }
                s.location?.geocodedName = name
                self?.activeSession = s
                SessionStore.shared.upsert(s)
            }
        } else if let last = lastKnownLocation {
            guard fix.distance(from: last) > locationChangeDist else { return }
            // User has moved significantly — split into a new session.
            closeActiveSession()
            lastKnownLocation = fix
            openSession()
        } else {
            lastKnownLocation = fix
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        isAwaitingFirstFix = false
        print("[DataHawk] Session location fix failed: \(error.localizedDescription)")
    }

    // MARK: - Reverse geocoding

    // CLGeocoder is deprecated in macOS 26 in favour of MKReverseGeocodingRequest.
    // Migration deferred until the replacement API stabilises post-WWDC 2025.
    private func geocode(_ location: CLLocation, completion: @escaping (String?) -> Void) {
        CLGeocoder().reverseGeocodeLocation(location) { placemarks, _ in
            let name = placemarks?.first.map { p -> String in
                [p.locality, p.administrativeArea, p.country]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: ", ")
            }
            DispatchQueue.main.async { completion(name) }
        }
    }
}
