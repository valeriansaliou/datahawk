// WiFiUsersView.swift
// DataHawk
//
// WiFi users window: a flat table of every client the router currently
// reports in router.clientList. Re-parsed on every poll cycle, so the table
// follows AppState.metrics live — there is nothing to persist or refresh here.

import SwiftUI
import AppKit

private let cellFont: Font = .system(size: 11)

struct WiFiUsersView: View {
    @ObservedObject private var state = AppState.shared

    @State private var sortOrder = [KeyPathComparator(\WiFiClient.name)]
    @State private var selectedID: String?

    private var clients: [WiFiClient] {
        (state.metrics?.clients ?? []).sorted(using: sortOrder)
    }

    var body: some View {
        Group {
            if clients.isEmpty {
                emptyState
            } else {
                table
            }
        }
        .frame(minWidth: 420, minHeight: 200)
    }

    // MARK: - Table

    private var table: some View {
        Table(clients, selection: $selectedID, sortOrder: $sortOrder) {
            TableColumn("Client Name", value: \.name) { c in
                Text(c.name.isEmpty ? "Unknown device" : c.name)
                    .font(cellFont)
                    .foregroundStyle(c.name.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            }
            .width(min: 100, ideal: 160)

            TableColumn("IP Address", value: \.ipAddress) { c in
                Text(c.ipAddress.isEmpty ? "\u{2014}" : c.ipAddress)
                    .font(cellFont)
                    .fontDesign(.monospaced)
            }
            .width(min: 90, ideal: 120)

            TableColumn("MAC Address", value: \.macAddress) { c in
                Text(c.macAddress.isEmpty ? "\u{2014}" : c.macAddress.uppercased())
                    .font(cellFont)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 150)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.count == 1, let client = clients.first(where: { ids.contains($0.id) }) {
                Button {
                    copyToPasteboard(clientAsText(client))
                } label: {
                    Label("Copy as Text", systemImage: "doc.on.doc")
                }
                if !client.ipAddress.isEmpty {
                    Button {
                        copyToPasteboard(client.ipAddress)
                    } label: {
                        Label("Copy IP Address", systemImage: "network")
                    }
                }
                if !client.macAddress.isEmpty {
                    Button {
                        copyToPasteboard(client.macAddress.uppercased())
                    } label: {
                        Label("Copy MAC Address", systemImage: "personalhotspot")
                    }
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("No connected clients")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func clientAsText(_ c: WiFiClient) -> String {
        """
        Name: \(c.name.isEmpty ? "Unknown device" : c.name)
        IP: \(c.ipAddress.isEmpty ? "\u{2014}" : c.ipAddress)
        MAC: \(c.macAddress.isEmpty ? "\u{2014}" : c.macAddress.uppercased())
        """
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
