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

import Foundation
import Combine
import CoreLocation

final class ClusterCache: ObservableObject {
    static let shared = ClusterCache()

    // MARK: - Cluster model

    struct Cluster: Identifiable, Codable {
        /// ID of the most recent (representative) session in this cluster.
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
    static let distanceThreshold: CLLocationDistance = 20

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
    func updateForSession(_ session: SessionRecord) {
        guard let loc = session.location else { return }
        let sessionLoc = CLLocation(latitude: loc.latitude, longitude: loc.longitude)

        if let idx = clusters.firstIndex(where: {
            $0.sessionIDs.contains(session.id)
            && CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                .distance(from: sessionLoc) <= Self.distanceThreshold
        }) {
            // Session already registered in this cluster — refresh display fields
            // if it is the representative (newest).
            if clusters[idx].sessionIDs.first == session.id {
                clusters[idx].latestSignal     = session.averageSignal
                clusters[idx].latestGeneration = session.generation
            }
        } else if let idx = clusters.firstIndex(where: {
            CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                .distance(from: sessionLoc) <= Self.distanceThreshold
        }) {
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
    func rebuild() {
        guard !isRebuilding else { return }
        isRebuilding = true
        let snapshot = SessionStore.shared.sessions

        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await Task.detached(priority: .utility) {
                ClusterCache.computeClusters(from: snapshot)
            }.value
            self.clusters     = result
            self.isRebuilding = false
            self.save()
        }
    }

    // MARK: - Cluster computation (pure, runs off main thread)

    private static func computeClusters(from sessions: [SessionRecord]) -> [Cluster] {
        let withLoc = sessions
            .filter { $0.location != nil }
            .sorted { $0.startDate > $1.startDate }

        var result: [Cluster] = []

        for session in withLoc {
            let loc = CLLocation(
                latitude:  session.location!.latitude,
                longitude: session.location!.longitude
            )
            if let i = result.firstIndex(where: {
                CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                    .distance(from: loc) <= distanceThreshold
            }) {
                result[i].sessionIDs.append(session.id)
            } else {
                result.append(Cluster(
                    id:               session.id,
                    latitude:         session.location!.latitude,
                    longitude:        session.location!.longitude,
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
