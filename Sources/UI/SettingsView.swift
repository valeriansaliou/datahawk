import SwiftUI

// MARK: - Settings root view

struct SettingsView: View {
    @ObservedObject private var store = ConfigStore.shared
    @State private var showingForm    = false
    @State private var editTarget     : HotspotConfig? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("Known Hotspots")
                    .font(.headline)
                Spacer()
                Button {
                    editTarget   = nil
                    showingForm  = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add a new hotspot")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if store.hotspots.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(store.hotspots) { hotspot in
                        HotspotRowView(hotspot: hotspot) {
                            editTarget  = hotspot
                            showingForm = true
                        } onDelete: {
                            store.remove(id: hotspot.id)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 460, height: 360)
        .sheet(isPresented: $showingForm) {
            HotspotFormView(existing: editTarget) {
                showingForm = false
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text("No hotspots configured")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text("Click + to add a known router.")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Hotspot row

private struct HotspotRowView: View {
    let hotspot  : HotspotConfig
    let onEdit   : () -> Void
    let onDelete : () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(hotspot.name)
                    .font(.body)
                HStack(spacing: 8) {
                    Text(hotspot.vendor.rawValue)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(hotspot.macAddress)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fontDesign(.monospaced)
                }
            }
            Spacer()
            Button("Edit",   action: onEdit)
                .buttonStyle(.borderless)
                .font(.caption)
            Button("Delete", action: onDelete)
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundColor(.red)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Add / Edit form

struct HotspotFormView: View {
    let existing  : HotspotConfig?
    let onDismiss : () -> Void

    @ObservedObject private var store = ConfigStore.shared

    @State private var name         : String = ""
    @State private var macAddress   : String = ""
    @State private var vendor       : RouterVendor = .netgear
    @State private var username     : String = ""
    @State private var password     : String = ""
    @State private var customBaseURL: String = ""

    private var isEditing: Bool { existing != nil }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Identity") {
                    TextField("Friendly name (e.g. Office M6 Pro)", text: $name)
                    TextField("MAC address  (aa:bb:cc:dd:ee:ff)",  text: $macAddress)
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
                    TextField("Base URL  (leave empty to auto-detect)", text: $customBaseURL)
                        .fontDesign(.monospaced)
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("When empty, DataHawk detects the router IP from the active network route.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Cancel", action: onDismiss)
                Spacer()
                Button(isEditing ? "Save" : "Add") {
                    commit()
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || macAddress.isEmpty || username.isEmpty)
            }
            .padding()
        }
        .frame(width: 420, height: 440)
        .onAppear { prefill() }
    }

    // MARK: - Helpers

    private func prefill() {
        guard let h = existing else { return }
        name          = h.name
        macAddress    = h.macAddress
        vendor        = h.vendor
        username      = h.username
        password      = h.password
        customBaseURL = h.customBaseURL ?? ""
    }

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
