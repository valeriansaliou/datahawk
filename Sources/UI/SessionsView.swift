// SessionsView.swift
// DataHawk
//
// Session History window: a Map tab with clustered pins coloured by signal
// quality, and a List tab with a searchable, sortable table and export / wipe
// toolbar actions.

import SwiftUI
import MapKit
import AppKit
import CoreLocation
import UniformTypeIdentifiers

// MARK: - Sort proxies (UI-only helpers for Table column sorting)

extension SessionRecord {
    var endDateForSort:    Date   { endDate ?? .distantFuture }
    var durationForSort:   Double { duration ?? -1 }
    var dataUsedForSort:   Double { dataUsedGB ?? -1 }
    var signalForSort:     Double { averageSignal ?? -1 }
    var locationForSort:   String { location?.geocodedName ?? "" }
    var hotspotForSort:    String { hotspotName }
    var providerForSort:   String { provider ?? "" }
    var generationForSort: String { generation ?? "" }
    var roamingForSort:    Int    { isRoaming.map { $0 ? 1 : 0 } ?? -1 }
}


// MARK: - Root view

struct SessionsView: View {
    @ObservedObject private var store    = SessionStore.shared
    @ObservedObject private var appState = AppState.shared

    @State private var selectedTab:          SessionTab = .map
    @State private var selectedSessionID:    UUID?       = nil
    @State private var showWipeAllAlert:     Bool        = false
    @State private var showNewSessionAlert:  Bool        = false

    enum SessionTab { case map, list }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            tabContent
        }
        .alert("Delete All Sessions?", isPresented: $showWipeAllAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All", role: .destructive) { SessionStore.shared.wipeAll() }
        } message: {
            Text("All sessions will be permanently deleted. This cannot be undone.")
        }
        .alert("Start a New Session?", isPresented: $showNewSessionAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Start New Session") { SessionTracker.shared.forceRestartSession() }
        } message: {
            Text("This will end your current session and immediately open a new one.\n\nYou typically don\u{2019}t need to do this \u{2014} DataHawk starts and ends sessions automatically based on your Wi\u{2011}Fi connection and GPS location.")
        }
    }

    // MARK: - Header bar

    private var headerBar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $selectedTab) {
                Label("Sessions Map", systemImage: "map.fill").tag(SessionTab.map)
                Label("List of All Sessions", systemImage: "list.bullet").tag(SessionTab.list)
            }
            .pickerStyle(.segmented)
            .frame(width: 280)
            .labelsHidden()
            .controlSize(.large)

            Spacer()

            if selectedTab == .list {
                listToolbar
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Tab content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .map:
            SessionMapView(sessions: store.sessions) { sessionID in
                selectedSessionID = sessionID
                selectedTab = .list
            }
        case .list:
            SessionListView(sessions: store.sessions, selectedID: $selectedSessionID)
        }
    }

    // MARK: - List toolbar

    private var listToolbar: some View {
        HStack(spacing: 6) {
            Button { showNewSessionAlert = true } label: {
                Label("Start New Session", systemImage: "arrow.clockwise.circle")
                    .font(.system(size: 11, weight: .medium))
            }
            .controlSize(.regular)
            .disabled(appState.connectionState != .connected)
            .help("End the current session and start a fresh one")
            .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }

            Divider().frame(height: 16)

            Button { exportCSV() } label: {
                Label("Export CSV", systemImage: "square.and.arrow.up")
                    .font(.system(size: 11, weight: .medium))
            }
            .controlSize(.regular)
            .disabled(store.sessions.isEmpty)
            .help("Export all sessions to a CSV file")
            .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }

            Button { showWipeAllAlert = true } label: {
                Label("Wipe All", systemImage: "trash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
            }
            .controlSize(.regular)
            .disabled(store.sessions.isEmpty)
            .help("Permanently delete all sessions")
            .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        }
    }

    private func exportCSV() {
        let csv   = SessionStore.shared.exportCSV()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "datahawk-sessions.csv"
        panel.allowedContentTypes  = [.commaSeparatedText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? csv.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Map tab

struct SessionMapView: View {
    let sessions: [SessionRecord]
    var onSelect: (UUID) -> Void

    @ObservedObject private var cache = ClusterCache.shared
    @State private var mapPosition: MapCameraPosition = .automatic

    /// Initial camera fitted to cached clusters with 1.8× padding.
    private var fittedPosition: MapCameraPosition {
        let coords = cache.clusters.map { $0.coordinate }
        guard !coords.isEmpty else { return .automatic }
        if coords.count == 1 {
            return .region(MKCoordinateRegion(
                center: coords[0],
                span: MKCoordinateSpan(latitudeDelta: 0.12, longitudeDelta: 0.12)
            ))
        }
        let lats = coords.map { $0.latitude }
        let lons = coords.map { $0.longitude }
        let spanLat = max(0.05, lats.max()! - lats.min()!) * 1.8
        let spanLon = max(0.05, lons.max()! - lons.min()!) * 1.8
        return .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude:  (lats.min()! + lats.max()!) / 2,
                longitude: (lons.min()! + lons.max()!) / 2
            ),
            span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLon)
        ))
    }

    var body: some View {
        if sessions.isEmpty {
            emptyState(icon: "map",
                       title: "No sessions yet",
                       subtitle: "Sessions will appear here once you connect to a known hotspot.")
        } else if cache.clusters.isEmpty && !cache.isRebuilding {
            emptyState(icon: "location.slash",
                       title: "No location data",
                       subtitle: "Sessions were recorded without a location fix.")
        } else if cache.clusters.isEmpty && cache.isRebuilding {
            VStack(spacing: 12) {
                Spacer()
                ProgressView("Building map\u{2026}")
                    .progressViewStyle(.circular)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Map(position: $mapPosition) {
                ForEach(cache.clusters) { cluster in
                    Annotation("", coordinate: cluster.coordinate) {
                        SessionPinView(
                            generation:    cluster.latestGeneration,
                            averageSignal: cluster.latestSignal,
                            clusterCount:  cluster.count
                        ) { onSelect(cluster.id) }
                    }
                }
            }
            .mapControls { MapZoomStepper() }
            .overlay(alignment: .topTrailing) {
                if cache.isRebuilding {
                    ProgressView()
                        .scaleEffect(0.7)
                        .padding(10)
                }
            }
            .onAppear { mapPosition = fittedPosition }
        }
    }

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 60)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Map pin

/// Circular pin coloured by average signal strength. Single sessions show the
/// cellular generation; clustered pins also show the session count.
struct SessionPinView: View {
    let generation:    String?
    let averageSignal: Double?
    let clusterCount:  Int
    var onTap:         () -> Void

    @State private var isHovered = false

    private var pinSize: CGFloat { clusterCount > 1 ? 42 : 34 }

    var body: some View {
        ZStack {
            Circle()
                .fill(signalColor)
                .frame(width: pinSize, height: pinSize)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                .overlay {
                    // Subtle white tint on hover to signal clickability.
                    Circle().fill(Color.white.opacity(isHovered ? 0.18 : 0))
                }

            if clusterCount > 1 {
                VStack(spacing: 0) {
                    Text(generation ?? "?")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                    Text("\(clusterCount)×")
                        .font(.system(size: 8))
                        .foregroundColor(.white.opacity(0.85))
                }
            } else {
                Text(generation ?? "?")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
            }
        }
        .onTapGesture { onTap() }
        .onHover { inside in
            isHovered = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    private var signalColor: Color {
        guard let avg = averageSignal else { return .gray }
        switch avg {
        case 4...: return .green
        case 3..<4: return Color(hue: 0.22, saturation: 0.9, brightness: 0.72)
        case 2..<3: return .orange
        case 1..<2: return .red
        default:    return .gray
        }
    }
}

// MARK: - List tab

struct SessionListView: View {
    let sessions:    [SessionRecord]
    @Binding var selectedID: UUID?

    @ObservedObject private var config = ConfigStore.shared
    @State private var searchText = ""
    @State private var sortOrder: [KeyPathComparator<SessionRecord>] = [
        KeyPathComparator(\.startDate, order: .reverse)
    ]

    private var displayedSessions: [SessionRecord] {
        let base: [SessionRecord]
        if searchText.isEmpty {
            base = sessions
        } else {
            let q = searchText.lowercased()
            base = sessions.filter { s in
                // Location name
                s.location?.geocodedName?.lowercased().contains(q) == true
                // Raw coordinates
                || s.location.map {
                    "\(String(format: "%.5f", $0.latitude)) \(String(format: "%.5f", $0.longitude))"
                }?.contains(q) == true
                // Provider
                || s.provider?.lowercased().contains(q) == true
                // Start date — ISO prefix (e.g. "2026", "2026-06", "2026-06-14")
                || isoDate(s.startDate).hasPrefix(q)
                // Start date — locale short format (e.g. "6/14/26")
                || formatDate(s.startDate).lowercased().hasPrefix(q)
            }
        }
        return base.sorted(using: sortOrder)
    }

    var body: some View {
        if sessions.isEmpty {
            emptyState(
                icon: "clock.arrow.trianglepath.counterclockwise",
                title: "No sessions yet",
                subtitle: "Sessions will be recorded once you connect to a known hotspot."
            )
        } else {
            VStack(spacing: 0) {
                searchBar
                Divider()
                if displayedSessions.isEmpty {
                    emptyState(
                        icon: "magnifyingglass",
                        title: "No results",
                        subtitle: "No sessions match \"\(searchText)\"."
                    )
                } else {
                    Table(displayedSessions, selection: $selectedID, sortOrder: $sortOrder) {
                        TableColumn("Start Date", value: \.startDate) { s in
                            Text(formatDate(s.startDate))
                                .font(.system(size: 11))
                                .help(formatDateLong(s.startDate))
                        }
                        .width(min: 110, ideal: 130)

                        TableColumn("Duration", value: \.durationForSort) { s in
                            if s.isActive {
                                Text("Active")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.green)
                            } else if let d = s.duration {
                                Text(SessionStore.formatDuration(d))
                                    .font(.system(size: 11))
                            } else {
                                Text("\u{2014}").font(.system(size: 11))
                            }
                        }
                        .width(min: 60, ideal: 75)

                        TableColumn("Location", value: \.locationForSort) { s in
                            if let name = s.location?.geocodedName {
                                Text(name).font(.system(size: 11))
                            } else if let loc = s.location {
                                Text(String(format: "%.5f, %.5f", loc.latitude, loc.longitude))
                                    .font(.system(size: 11))
                                    .fontDesign(.monospaced)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("No location detected")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .width(min: 120, ideal: 180)

                        TableColumn("Hotspot", value: \.hotspotForSort) { s in
                            let info = resolvedHotspot(s)
                            Text(info.name)
                                .font(.system(size: 11))
                                .foregroundStyle(info.removed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                        }
                        .width(min: 80, ideal: 120)

                        TableColumn("Provider", value: \.providerForSort) { s in
                            Text(s.provider ?? "\u{2014}")
                                .font(.system(size: 11))
                        }
                        .width(min: 70, ideal: 90)

                        TableColumn("Roaming", value: \.roamingForSort) { s in
                            switch s.isRoaming {
                            case true:
                                Text("Yes")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.orange)
                            case false:
                                Text("No")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            case nil:
                                Text("\u{2014}")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .width(min: 52, ideal: 60, max: 70)

                        TableColumn("Generation", value: \.generationForSort) { s in
                            Text(s.generation ?? "\u{2014}")
                                .font(.system(size: 11, weight: .semibold))
                                .fontDesign(.monospaced)
                        }
                        .width(min: 60, ideal: 70, max: 80)

                        TableColumn("Data Used", value: \.dataUsedForSort) { s in
                            if let gb = s.dataUsedGB {
                                Text(String(format: "%.2f GB", gb))
                                    .font(.system(size: 11))
                            } else if s.isActive {
                                Text("\u{2014}")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("?")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .help("Billing cycle may have rolled over during this session.")
                            }
                        }
                        .width(min: 64, ideal: 80)

                        TableColumn("Average Signal", value: \.signalForSort) { s in
                            if let avg = s.averageSignal {
                                Text(String(format: "%.1f/5", avg))
                                    .font(.system(size: 11))
                                    .foregroundStyle(signalColor(avg))
                            } else {
                                Text("\u{2014}").font(.system(size: 11))
                            }
                        }
                        .width(min: 80, ideal: 100)
                    }
                    .contextMenu(forSelectionType: UUID.self) { ids in
                        if ids.count == 1,
                           let session = displayedSessions.first(where: { ids.contains($0.id) }) {
                            Button {
                                copyToPasteboard(sessionAsText(session))
                            } label: {
                                Label("Copy as Text", systemImage: "doc.on.doc")
                            }
                            if session.location != nil {
                                Button {
                                    copyToPasteboard(sessionGPS(session))
                                } label: {
                                    Label("Copy GPS Coordinates", systemImage: "location")
                                }
                            }
                            Divider()
                        }
                        if !ids.isEmpty {
                            Button(role: .destructive) {
                                SessionStore.shared.wipeSessions(ids: ids)
                            } label: {
                                let label = ids.count == 1 ? "Delete Session" : "Delete \(ids.count) Sessions"
                                Label(label, systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            TextField("Filter by location, provider, date\u{2026}", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Empty / no-results state

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 60)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Hotspot lookup

    private struct HotspotInfo { let name: String; let removed: Bool }

    private func resolvedHotspot(_ session: SessionRecord) -> HotspotInfo {
        if let bssid = session.hotspotBSSID {
            if let hotspot = config.hotspot(forBSSID: bssid) {
                return HotspotInfo(name: hotspot.name, removed: false)
            }
            return HotspotInfo(name: "Removed hotspot", removed: true)
        }
        // Older records without a stored BSSID — fall back to the name snapshot.
        let name = session.hotspotName
        return HotspotInfo(name: name.isEmpty ? "\u{2014}" : name, removed: false)
    }

    // MARK: - Clipboard helpers

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func sessionGPS(_ session: SessionRecord) -> String {
        guard let loc = session.location else { return "" }
        return String(format: "%.5f, %.5f", loc.latitude, loc.longitude)
    }

    private func sessionAsText(_ session: SessionRecord) -> String {
        var lines: [String] = []
        let hotspot = resolvedHotspot(session)
        lines.append("Hotspot: \(hotspot.name)")
        lines.append("Start: \(formatDateLong(session.startDate))")
        if let end = session.endDate   { lines.append("End: \(formatDateLong(end))") }
        if let d = session.duration    { lines.append("Duration: \(SessionStore.formatDuration(d))") }
        if let loc = session.location  {
            if let name = loc.geocodedName { lines.append("Location: \(name)") }
            lines.append("Coordinates: \(String(format: "%.5f, %.5f", loc.latitude, loc.longitude))")
        }
        if let p = session.provider    { lines.append("Provider: \(p)") }
        if let r = session.isRoaming   { lines.append("Roaming: \(r ? "Yes" : "No")") }
        if let g = session.generation  { lines.append("Generation: \(g)") }
        if let gb = session.dataUsedGB { lines.append(String(format: "Data Used: %.2f GB", gb)) }
        if let sig = session.averageSignal { lines.append(String(format: "Avg Signal: %.1f/5", sig)) }
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: date)
    }

    private func isoDate(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date).lowercased()
    }

    private func formatDateLong(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .medium
        return f.string(from: date)
    }

    private func signalColor(_ avg: Double) -> Color {
        switch avg {
        case 4...: return .green
        case 3..<4: return Color(hue: 0.22, saturation: 0.9, brightness: 0.65)
        case 2..<3: return .orange
        case 1..<2: return .red
        default:    return .gray
        }
    }
}
