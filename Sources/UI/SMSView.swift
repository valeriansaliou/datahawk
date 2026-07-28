// SMSView.swift
// DataHawk
//
// Text Messages window: a master-detail layout listing every SMS reported by
// the router (sms.msgs), newest first, with an unread indicator. Selecting a
// message marks it read locally — write-back to the router (actually marking
// read, deleting) is not implemented yet.

import SwiftUI
import AppKit

// MARK: - Date formatting (shared, cached)

private enum SMSDateFormat {
    static let short: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
    static let long: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .medium
        return f
    }()
}

private func formatDate(_ date: Date?) -> String {
    date.map(SMSDateFormat.short.string(from:)) ?? "Unknown date"
}
private func formatDateLong(_ date: Date?) -> String {
    date.map(SMSDateFormat.long.string(from:)) ?? "Unknown date"
}

// MARK: - Root view

struct SMSView: View {
    @ObservedObject private var state = AppState.shared

    @State private var selectedID: String?
    /// Message IDs the user has opened this window session. Overlaid on top
    /// of the router-reported `isRead` flag since marking-as-read on the
    /// router itself is not implemented yet.
    @State private var locallyRead: Set<String> = []

    private var messages: [SMSMessage] {
        // Messages with an unknown rxDate sort to the bottom.
        (state.metrics?.smsMessages ?? []).sorted {
            ($0.rxDate ?? .distantPast) > ($1.rxDate ?? .distantPast)
        }
    }

    var body: some View {
        Group {
            if state.metrics?.smsReady != true {
                EmptyStateView(
                    icon: "text.bubble",
                    title: "Text messages not supported",
                    subtitle: "This router does not report SMS as ready."
                )
            } else if messages.isEmpty {
                EmptyStateView(
                    icon: "text.bubble",
                    title: "No text messages",
                    subtitle: "Messages received by the router will appear here."
                )
            } else {
                HSplitView {
                    messageList
                        .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
                    detailPane
                        .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onChange(of: messages.map(\.id)) { _, ids in
            // Drop stale selection if the router's message list changed underneath us.
            if let selectedID, !ids.contains(selectedID) {
                self.selectedID = nil
            }
        }
    }

    // MARK: - Message list

    private var messageList: some View {
        List(messages, selection: Binding(
            get: { selectedID },
            set: { newID in
                selectedID = newID
                if let newID { locallyRead.insert(newID) }
            }
        )) { message in
            SMSRow(
                message: message,
                isRead: message.isRead || locallyRead.contains(message.id)
            )
            .tag(message.id)
        }
        .listStyle(.sidebar)
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let message = messages.first(where: { $0.id == selectedID }) {
            SMSDetailView(message: message)
        } else {
            EmptyStateView(
                icon: "text.bubble",
                title: "No message selected",
                subtitle: "Select a message from the list to read it."
            )
        }
    }
}

// MARK: - Message row

private struct SMSRow: View {
    let message: SMSMessage
    let isRead: Bool

    private var preview: String {
        message.text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(isRead ? Color.clear : Color.blue)
                .frame(width: 7, height: 7)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                Text(message.sender.isEmpty ? "Unknown sender" : message.sender)
                    .font(.system(size: 12, weight: isRead ? .regular : .semibold))
                    .lineLimit(1)

                Text(preview)
                    .font(.system(size: 11, weight: isRead ? .regular : .semibold))
                    .foregroundStyle(isRead ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(2)

                Text(formatDate(message.rxDate))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Message detail

private struct SMSDetailView: View {
    let message: SMSMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(message.sender.isEmpty ? "Unknown sender" : message.sender)
                    .font(.system(size: 15, weight: .semibold))
                Text(formatDateLong(message.rxDate))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Divider()

            ScrollView {
                Text(message.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
    }
}

// MARK: - Empty / no-results state

private struct EmptyStateView: View {
    let icon:     String
    let title:    String
    let subtitle: String

    var body: some View {
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
