// SMSView.swift
// DataHawk
//
// Text Messages window: a master-detail layout listing every SMS reported by
// the router (sms.msgs), newest first, with an unread indicator. Selecting an
// unread message marks it read on the router itself, and the toolbar can wipe
// the router's whole inbox (deleting a single message is not implemented).

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
    /// Set when a write (mark read / delete all) is rejected by the router.
    /// Cleared by the next successful write.
    @State private var errorMessage: String?
    @State private var showDeleteAllAlert = false
    @State private var isDeleting         = false

    private var messages: [SMSMessage] {
        // Messages with an unknown rxDate sort to the bottom.
        (state.metrics?.smsMessages ?? []).sorted {
            ($0.rxDate ?? .distantPast) > ($1.rxDate ?? .distantPast)
        }
    }

    private var isSupported: Bool { state.metrics?.smsReady == true }

    var body: some View {
        VStack(spacing: 0) {
            if isSupported {
                headerBar
                Divider()
            }

            if let errorMessage {
                SMSErrorBanner(message: errorMessage)
            }

            content
                .disabled(isDeleting)
        }
        .alert("Delete All Text Messages?", isPresented: $showDeleteAllAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All", role: .destructive, action: deleteAll)
        } message: {
            Text("All \(messages.count) message\(messages.count == 1 ? "" : "s") will be permanently deleted from the router. This cannot be undone.")
        }
        .onChange(of: messages.map(\.id)) { _, ids in
            // Drop stale selection if the router's message list changed underneath us.
            if let selectedID, !ids.contains(selectedID) {
                self.selectedID = nil
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !isSupported {
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

    // MARK: - Header bar

    private var headerBar: some View {
        HStack(spacing: 12) {
            Text(summary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Spacer()

            // Hidden when there is nothing to delete. `isDeleting` keeps it
            // on screen for the last frames of a wipe, when the list has
            // already emptied but the spinner has not been dismissed yet.
            if !messages.isEmpty || isDeleting {
                Button { showDeleteAllAlert = true } label: {
                    HStack(spacing: 5) {
                        // Fixed-width leading slot so the label doesn't shift
                        // when the icon swaps for the spinner.
                        Group {
                            if isDeleting {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "trash")
                            }
                        }
                        .frame(width: 12)

                        Text(isDeleting ? "Deleting\u{2026}" : "Delete All")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isDeleting ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))
                }
                .controlSize(.regular)
                .disabled(isDeleting)
                .help("Permanently delete every message stored on the router")
                .onHover { inside in
                    guard !isDeleting else { return }
                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var summary: String {
        let total = messages.count

        guard total > 0 else { return "No messages" }

        let unread = messages.filter { !$0.isRead }.count
        let base   = "\(total) message\(total == 1 ? "" : "s")"

        return unread > 0 ? "\(base) \u{00B7} \(unread) unread" : base
    }

    // MARK: - Message list

    private var messageList: some View {
        List(messages, selection: Binding(
            get: { selectedID },
            set: { newID in
                selectedID = newID
                if let newID { markRead(newID) }
            }
        )) { message in
            SMSRow(message: message)
                .tag(message.id)
        }
        .listStyle(.sidebar)
    }

    /// Writes the read flag back to the router. `RouterService` flips the
    /// flag in `AppState` optimistically, so the row updates before the
    /// request completes and rolls back if it fails.
    private func markRead(_ id: String) {
        Task { @MainActor in
            errorMessage = (await RouterService.shared.markSMSRead(id: id))
                .map { "Could not mark as read \u{2014} \($0)" }
        }
    }

    /// Wipes the router's inbox. `RouterService` only returns once the write
    /// has been confirmed by a fresh `model.json` read, so the spinner runs
    /// until the authoritative list is on screen.
    private func deleteAll() {
        isDeleting = true

        Task { @MainActor in
            errorMessage = (await RouterService.shared.deleteAllSMS())
                .map { "Could not delete messages \u{2014} \($0)" }
            selectedID = nil
            isDeleting = false
        }
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

    private var isRead: Bool { message.isRead }

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

// MARK: - Write failure banner

private struct SMSErrorBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
            Text(message)
                .font(.system(size: 11))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Color.red.opacity(0.85))
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
