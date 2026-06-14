// ClusterCache.swift
// DataHawk
//
// Pre-computes map clusters and persists them to clusters.json so the Sessions
// Map tab can render instantly without any O(n²) work on the main thread.
//
// Two update paths:
//   • updateForSession(_:) — delta, O(clusters), called on every session upsert.
//   • rebuild()            — full recompute on a background task, called after
//                            deletions or trim where delta tracking is impractical.
//
// On startup the cache is read from disk; if the file is absent or corrupt,
// rebuild() is triggered automatically in the background.
//
// All mutations to `clusters` happen on the main thread.

import Foundation
import Combine
import CoreLocation

final class ClusterCache: ObservableObject {
    static let shared = ClusterCache()

    // MARK: - Cluster model

    struct Cluster: Identifiable, Codable {
        /// ID of the most recent (representative) session in this cluster.
        /// Updates whenever a newer session joins — drives pin tap navigation.
        var id: UUID
        var latitude: Double
        var longitude: Double
        /// All session IDs that belong to this cluster, newest first.
        var sessionIDs: [UUID]
        /// averageSignal of the representative session — drives pin colour.
        var latestSignal: Double?
        /// generation of the representative session — drives pin label.
        var latestGeneration: String?

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
        var count: Int { sessionIDs.count }
    }

    // MARK: - Published state

    @Published private(set) var clusters: [Cluster] = []
    @Published private(set) var isRebuilding = false

    private let fileURL: URL

    /// Two sessions within this many metres are merged into the same cluster.
    static let distanceThreshold: CLLocationDistance = 20

    /// Set when an update arrives while a rebuild is in flight. Triggers a
    /// follow-up rebuild so the in-flight delta isn't lost.
    private var rebuildDirty = false

    private init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("DataHawk", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("clusters.json")
        load()
    }

    // MARK: - Delta update (O(clusters))

    /// Called after a single session is appended or updated in SessionStore.
    /// Does NOT recompute the whole dataset — only adjusts the affected cluster.
    ///
    /// If a rebuild is already in flight, the update is skipped (the rebuild's
    /// snapshot would overwrite it anyway). `rebuildDirty` is set so a follow-up
    /// rebuild runs as soon as the current one finishes.
    func updateForSession(_ session: SessionRecord) {
        guard let loc = session.location else { return }

        if isRebuilding {
            rebuildDirty = true
            return
        }

        let sessionLoc = CLLocation(latitude: loc.latitude, longitude: loc.longitude)

        if let idx = clusters.firstIndex(where: {
            $0.sessionIDs.contains(session.id) && $0.isWithin(Self.distanceThreshold, of: sessionLoc)
        }) {
            // Session already registered in this cluster — refresh display fields
            // if it is still the representative (newest).
            if clusters[idx].sessionIDs.first == session.id {
                clusters[idx].latestSignal     = session.averageSignal
                clusters[idx].latestGeneration = session.generation
            }
        } else if let idx = clusters.firstIndex(where: { $0.isWithin(Self.distanceThreshold, of: sessionLoc) }) {
            // New session that falls inside an existing cluster.
            clusters[idx].sessionIDs.insert(session.id, at: 0)
            clusters[idx].id               = session.id
            clusters[idx].latestSignal     = session.averageSignal
            clusters[idx].latestGeneration = session.generation
        } else {
            // No nearby cluster — start a new one.
            clusters.append(Cluster(
                id:               session.id,
                latitude:         loc.latitude,
                longitude:        loc.longitude,
                sessionIDs:       [session.id],
                latestSignal:     session.averageSignal,
                latestGeneration: session.generation
            ))
        }
        save()
    }

    // MARK: - Full rebuild (background)

    /// Rebuilds the cache from scratch on a background task and posts the result
    /// to the main actor. Called after deletions or trim operations.
    ///
    /// If called while already rebuilding, sets `rebuildDirty` so a follow-up
    /// rebuild captures any updates that landed in the meantime.
    func rebuild() {
        if isRebuilding {
            rebuildDirty = true
            return
        }
        isRebuilding = true
        rebuildDirty = false
        let snapshot = SessionStore.shared.sessions

        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await Task.detached(priority: .utility) {
                ClusterCache.computeClusters(from: snapshot)
            }.value
            self.clusters     = result
            self.isRebuilding = false
            self.save()

            // Updates may have arrived during the rebuild — re-run once to pick them up.
            if self.rebuildDirty {
                self.rebuildDirty = false
                self.rebuild()
            }
        }
    }

    // MARK: - Cluster computation (pure, runs off main thread)

    private static func computeClusters(from sessions: [SessionRecord]) -> [Cluster] {
        let withLoc = sessions
            .compactMap { session -> (SessionRecord, SessionLocation)? in
                guard let loc = session.location else { return nil }
                return (session, loc)
            }
            .sorted { $0.0.startDate > $1.0.startDate }

        var result: [Cluster] = []

        for (session, loc) in withLoc {
            let sessionLoc = CLLocation(latitude: loc.latitude, longitude: loc.longitude)
            if let i = result.firstIndex(where: { $0.isWithin(distanceThreshold, of: sessionLoc) }) {
                result[i].sessionIDs.append(session.id)
            } else {
                result.append(Cluster(
                    id:               session.id,
                    latitude:         loc.latitude,
                    longitude:        loc.longitude,
                    sessionIDs:       [session.id],
                    latestSignal:     session.averageSignal,
                    latestGeneration: session.generation
                ))
            }
        }
        return result
    }

    // MARK: - Persistence

    private func load() {
        if let data    = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Cluster].self, from: data) {
            clusters = decoded
        } else {
            rebuild()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(clusters) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Cluster proximity helper

private extension ClusterCache.Cluster {
    /// True when this cluster's centre is within `metres` of `location`.
    func isWithin(_ metres: CLLocationDistance, of location: CLLocation) -> Bool {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: location) <= metres
    }
}
