// SessionStore.swift
// DataHawk
//
// Persists SessionRecord values as a JSON Lines file (one record per line) in
// Application Support. Append-only WAL semantics:
//
//   • New session / close / signal sample → one line appended   O(1)
//   • Delete / trim                       → compact() rewrite   O(n)
//
// Updates append a new line for the same UUID; last occurrence wins on load.
// @MainActor-isolated — all access is compiler-enforced to the main actor.

import Foundation
import Combine

@MainActor
final class SessionStore: ObservableObject {
    static let shared = SessionStore()

    @Published private(set) var sessions: [SessionRecord] = []

    private let fileURL: URL

    /// Shared encoder/decoder — allocating either of these is non-trivial, so
    /// we keep one of each around for the lifetime of the store.
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("DataHawk", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("sessions.jsonl")
        load()
    }

    // MARK: - CRUD

    func upsert(_ session: SessionRecord) {
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx] = session
            appendLine(session)
            ClusterCache.shared.updateForSession(session)   // delta: O(clusters)
        } else {
            sessions.append(session)
            if trimIfNeeded() {
                // compact() rewrites the file AND triggers ClusterCache.rebuild(),
                // so the newly-appended session lands via the rebuild path.
                compact()
            } else {
                appendLine(session)
                ClusterCache.shared.updateForSession(session)
            }
        }
    }

    func wipeSession(id: UUID) {
        sessions.removeAll { $0.id == id }
        compact()
    }

    func wipeSessions(ids: Set<UUID>) {
        sessions.removeAll { ids.contains($0.id) }
        compact()
    }

    func wipeAll() {
        sessions.removeAll()
        compact()
    }


    static func formatDuration(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    private static func csvEscape(_ str: String) -> String {
        guard str.contains(",") || str.contains("\"") || str.contains("\n") else { return str }
        return "\"" + str.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - Trim

    /// Removes oldest completed sessions when the count has grown 10% beyond
    /// the configured limit. Removes 10% of the limit in one batch so the next
    /// compaction doesn't happen until another 10% worth of sessions accumulate.
    /// Returns true when rows were removed (caller must compact the file).
    @discardableResult
    private func trimIfNeeded() -> Bool {
        let limit = ConfigStore.shared.maxSessionCount
        guard limit > 0 else { return false }
        let triggerAt = Int(Double(limit) * 1.1)   // compact when 10% over limit
        guard sessions.count > triggerAt else { return false }

        let removeCount = max(1, Int(Double(limit) * 0.1))  // drop 10% of limit
        let toRemove = Set(
            sessions
                .filter { !$0.isActive }
                .sorted { $0.startDate < $1.startDate }
                .prefix(removeCount)
                .map { $0.id }
        )
        guard !toRemove.isEmpty else { return false }

        sessions.removeAll { toRemove.contains($0.id) }
        return true
    }

    // MARK: - Persistence (JSONL)

    private func load() {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return }

        // Read every non-empty line; last occurrence per UUID wins (WAL semantics).
        var byID: [UUID: SessionRecord] = [:]
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data   = String(line).data(using: .utf8),
                  let record = try? decoder.decode(SessionRecord.self, from: data) else { continue }
            byID[record.id] = record
        }
        sessions = Array(byID.values).sorted { $0.startDate > $1.startDate }
    }

    /// Appends one JSON line for `session` — never rewrites the whole file.
    private func appendLine(_ session: SessionRecord) {
        guard var line = try? encoder.encode(session) else { return }
        line.append(0x0A)  // \n

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? line.write(to: fileURL, options: .atomic)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    /// Rewrites the JSONL file with the current deduplicated session list and
    /// triggers a background cluster cache rebuild (since rows were deleted).
    private func compact() {
        let data = sessions
            .compactMap { try? encoder.encode($0) }
            .reduce(into: Data()) { $0 += $1; $0.append(0x0A) }
        try? data.write(to: fileURL, options: .atomic)
        ClusterCache.shared.rebuild()
    }
}
