// SettingsView.swift
// DataHawk
//
// Settings window with three tabs: Hotspots (CRUD for monitored routers),
// Options (refresh interval), and About (version, author, links).
// Presented by SettingsWindowController.

import SwiftUI

// MARK: - Root settings view

struct SettingsView: View {
    var body: some View {
        TabView {
            HotspotsTab()
                .tabItem { Label("Hotspots", systemImage: "antenna.radiowaves.left.and.right") }

            OptionsTab()
                .tabItem { Label("Options", systemImage: "slider.horizontal.3") }

            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 380, height: 420)
    }
}

// MARK: - Hotspots tab

/// Lists all configured hotspots with hover-reveal edit / delete buttons.
/// An "Add Hotspot" button and an empty-state CTA are provided.
private struct HotspotsTab: View {
    @ObservedObject private var store = ConfigStore.shared

    @State private var showingForm = false
    @State private var editTarget: HotspotConfig? = nil

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if store.hotspots.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(store.hotspots) { hotspot in
                            HotspotRowView(hotspot: hotspot) {
                                editTarget  = hotspot
                                showingForm = true
                            } onDelete: {
                                store.remove(id: hotspot.id)
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .sheet(isPresented: $showingForm) {
            HotspotFormView(existing: editTarget) {
                showingForm = false
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Hotspots")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("\(store.hotspots.count) router\(store.hotspots.count == 1 ? "" : "s") configured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                editTarget  = nil
                showingForm = true
            } label: {
                Label("Add Hotspot", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()

            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
                    .frame(width: 72, height: 72)
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(spacing: 5) {
                Text("No hotspots yet")
                    .font(.headline)
                Text("Add your router to start monitoring\nyour 5G hotspot metrics.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                editTarget  = nil
                showingForm = true
            } label: {
                Label("Add First Hotspot", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .padding(.top, 4)
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Options tab

/// Simple form with a stepper for the auto-refresh interval.
private struct OptionsTab: View {
    @ObservedObject private var store = ConfigStore.shared

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $store.launchAtLogin)
            } header: {
                Text("General")
            } footer: {
                Text("Start DataHawk automatically when you log in.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                HStack {
                    Text("Auto-refresh every")
                    Spacer()

                    Stepper(value: $store.refreshInterval, in: 5...3600, step: 5) {
                        EmptyView()
                    }
                    .labelsHidden()

                    Text("\(store.refreshInterval)s")
                        .monospacedDigit()
                        .frame(width: 46, alignment: .trailing)
                }
            } header: {
                Text("Data refresh")
            } footer: {
                Text("How often DataHawk fetches metrics from your router. Minimum 5 seconds.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About tab

/// Shows app name, version, author, a GitHub link, and a disabled "Check for Updates" button.
private struct AboutTab: View {
    private let githubURL = URL(string: "https://github.com/valeriansaliou/datahawk")!

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 20) {
                // App icon badge.
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.accentColor.opacity(0.10))
                        .frame(width: 80, height: 80)
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Color.accentColor)
                }

                // Name + version + author.
                VStack(spacing: 5) {
                    Text("DataHawk")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Version \(appVersion)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("by Valerian Saliou")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                // Actions.
                VStack(spacing: 10) {
                    Link(destination: githubURL) {
                        Label("View on GitHub", systemImage: "arrow.up.right.square")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .onHover { inside in
                        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }

                    Button {
                        // Not yet implemented.
                    } label: {
                        Label("Check for Updates", systemImage: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .controlSize(.small)
                    .disabled(true)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Hotspot row

/// A single row in the hotspot list showing name, vendor, and MAC address.
/// Edit and delete buttons appear on hover.
private struct HotspotRowView: View {
    let hotspot: HotspotConfig
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            // Icon badge.
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 42, height: 42)
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Color.accentColor)
            }

            // Labels.
            VStack(alignment: .leading, spacing: 3) {
                Text(hotspot.name)
                    .font(.system(size: 13, weight: .semibold))

                HStack(spacing: 6) {
                    Text(hotspot.vendor.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\u{00B7}")  // middle dot
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(hotspot.macAddress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fontDesign(.monospaced)
                }
            }

            Spacer()

            // Action buttons (visible on hover).
            if isHovered {
                HStack(spacing: 4) {
                    IconButton(systemImage: "pencil", help: "Edit") { onEdit() }
                    IconButton(systemImage: "trash", help: "Delete", tint: .red) { onDelete() }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.04) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

// MARK: - Icon button

/// Small icon-only button with hover highlight, used for row actions.
private struct IconButton: View {
    let systemImage: String
    var help: String = ""
    var tint: Color  = .secondary
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovered ? tint : tint.opacity(0.7))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isHovered ? tint.opacity(0.12) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { inside in
            isHovered = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - Add / Edit form

/// Sheet form for creating or editing a hotspot configuration. Fields:
/// name, BSSID, vendor, username, password, and an optional admin URL.
struct HotspotFormView: View {
    let existing: HotspotConfig?
    let onDismiss: () -> Void

    @ObservedObject private var store = ConfigStore.shared

    @State private var name          = ""
    @State private var macAddress    = ""
    @State private var vendor        = RouterVendor.netgear
    @State private var username      = ""
    @State private var password      = ""
    @State private var customBaseURL = ""

    private var isEditing: Bool { existing != nil }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Identity") {
                    TextField("Name (e.g. My Hotspot)", text: $name)
                    TextField("BSSID (aa:bb:cc:dd:ee:ff)", text: $macAddress)
                        .fontDesign(.monospaced)
                    Picker("Vendor", selection: $vendor) {
                        ForEach(RouterVendor.allCases) { v in
                            Text(v.rawValue).tag(v)
                        }
                    }
                }

                Section("Credentials") {
                    TextField("Username", text: $username)
                    SecureField("Password", text: $password)
                }

                Section {
                    TextField("Admin URL", text: $customBaseURL)
                        .fontDesign(.monospaced)
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("When empty, DataHawk detects the router admin URL automatically.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Cancel", action: onDismiss)
                    .onHover { inside in
                        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }

                Spacer()

                Button(isEditing ? "Save" : "Add") {
                    commit()
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || macAddress.isEmpty || username.isEmpty)
                .onHover { inside in
                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }
            .padding()
        }
        .frame(width: 420, height: 440)
        .onAppear { prefill() }
    }

    // MARK: - Helpers

    /// Pre-fills the form fields when editing an existing hotspot.
    private func prefill() {
        guard let h = existing else { return }

        name          = h.name
        macAddress    = h.macAddress
        vendor        = h.vendor
        username      = h.username
        password      = h.password
        customBaseURL = h.customBaseURL ?? ""
    }

    /// Writes the form data to ConfigStore (add or update).
    private func commit() {
        let url = customBaseURL.trimmingCharacters(in: .whitespaces)

        if var h = existing {
            h.name          = name
            h.macAddress    = macAddress
            h.vendor        = vendor
            h.username      = username
            h.password      = password
            h.customBaseURL = url.isEmpty ? nil : url
            store.update(h)
        } else {
            let h = HotspotConfig(
                name:          name,
                macAddress:    macAddress,
                vendor:        vendor,
                username:      username,
                password:      password,
                customBaseURL: url.isEmpty ? nil : url
            )
            store.add(h)
        }
    }
}
