// PopoverSections.swift
// DataHawk
//
// Content sections displayed between the header and footer of the popover.
// Each section is a self-contained SwiftUI view that renders one logical
// block: error banner, disconnected placeholder, live metrics, alerts,
// or action buttons.

import SwiftUI
import AppKit

// MARK: - Error banner

/// Red banner shown when the most recent fetch failed. Displays both a title
/// and the human-readable error reason from RouterService.
struct ErrorBannerSection: View {
    let reason: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundColor(.red)
                .font(.caption)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text("Could not refresh data")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.red)
                Text(reason)
                    .font(.caption)
                    .foregroundColor(.red.opacity(0.8))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - Disconnected placeholder

/// Shown when no known hotspot is in range. Prompts the user to add a router
/// in Settings, and displays the detected BSSID for easy copy-paste.
struct DisconnectedSection: View {
    @ObservedObject private var state = AppState.shared
    @State private var copied = false

    var body: some View {
        VStack(spacing: 8) {
            Text("Connect to a known WiFi hotspot")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            // Inline link to open the Settings window.
            HStack(spacing: 0) {
                Text("Add your router in ")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("Settings") {
                    NotificationCenter.default.post(name: .datahawkHidePopover, object: nil)
                    SettingsWindowController.shared.show()
                }
                    .buttonStyle(.link)
                    .font(.caption)
                    .onHover { inside in
                        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                Text(" to get started.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Show the raw BSSID so the user can copy it into Settings.
            if let bssid = state.detectedBSSID {
                HStack(spacing: 4) {
                    Text("Detected BSSID: ")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(bssid)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fontDesign(.monospaced)
                        .textSelection(.enabled)
                        .onHover { inside in
                            if inside { NSCursor.iBeam.push() } else { NSCursor.pop() }
                        }

                    // Copy-to-clipboard button with brief checkmark feedback.
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(bssid, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            copied = false
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9))
                            .foregroundColor(copied ? .green : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .onHover { inside in
                        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
    }
}

// MARK: - Live metrics

/// Displays the current router metrics in grouped rows: connection info,
/// WiFi status, and data usage.
struct MetricsSection: View {
    @ObservedObject var state: AppState

    var body: some View {
        if let m = state.metrics {
            VStack(alignment: .leading, spacing: 0) {
                // Group 1: cellular connection info.
                metricGroup {
                    if let name = state.activeHotspot?.name {
                        metricRow("Hotspot") {
                            Text(name).fontDesign(.monospaced)
                        }
                    }

                    metricRow(
                        "Connection",
                        isSpinner: m.connectionStatus.lowercased() != "connected"
                    ) {
                        Text(m.connectionStatus).fontDesign(.monospaced)
                    }

                    metricRow("Signal") {
                        Text("\(m.signalStrength * 20)%").fontDesign(.monospaced)
                    }
                }

                Divider()

                // Group 2: WiFi network and connected users.
                metricGroup {
                    metricRow("WiFi network") {
                        if m.wifiEnabled {
                            Text(state.detectedSSID ?? "\u{2014}")
                                .fontDesign(.monospaced)
                        } else {
                            Text("OFF")
                                .fontDesign(.monospaced)
                                .foregroundColor(.secondary)
                        }
                    }

                    metricRow("WiFi users") {
                        Text("\(m.connectedUsers)").fontDesign(.monospaced)
                    }
                }

                // Group 3: data usage (only when at least one value is known).
                if m.dataUsedGB != nil || m.dataLimitGB != nil || m.dataUsagePercent != nil {
                    Divider()

                    metricGroup {
                        if let pct = m.dataUsagePercent {
                            metricRow("Data left") {
                                Text(String(format: "%.1f%%", (1.0 - pct) * 100))
                                    .fontDesign(.monospaced)
                            }
                        }
                        if let used = m.dataUsedGB {
                            metricRow("Data used") {
                                Text(String(format: "%.2f GB", used))
                                    .fontDesign(.monospaced)
                            }
                        }
                        if let limit = m.dataLimitGB {
                            metricRow("Data limit") {
                                Text(String(format: "%.0f GB", limit))
                                    .fontDesign(.monospaced)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Row builders

    /// Wraps a group of metric rows in consistent padding.
    @ViewBuilder
    private func metricGroup<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// A single metric row with a fixed-width label on the left and content
    /// on the right. Optionally shows a spinner next to the content.
    @ViewBuilder
    private func metricRow<Content: View>(
        _ label: String,
        isSpinner: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)

            if isSpinner {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
            }

            content()
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - High data usage alert

/// Orange banner warning the user that data consumption has reached the
/// router's configured high-usage threshold.
struct HighDataUsageAlertSection: View {
    let metrics: RouterMetrics

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.bar.fill")
                .foregroundColor(.orange)
            Text(label)
                .font(.subheadline)
                .foregroundColor(.orange)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.08))
    }

    private var label: String {
        if let pct = metrics.dataUsagePercent {
            let used = Int((pct * 100).rounded())
            return "High data usage (\(used)% used)"
        }

        return "High data usage"
    }
}

// MARK: - Firmware update alert

/// Orange banner shown when the router reports that a firmware update is
/// available.
struct FirmwareAlertSection: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundColor(.orange)
            Text("Router firmware update available")
                .font(.subheadline)
                .foregroundColor(.orange)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.08))
    }
}

// MARK: - App update banner

/// Accent-coloured banner shown when a newer DataHawk release is available.
/// Tapping "Install" closes the popover and starts the download + install flow.
struct UpdateAvailableSection: View {
    let downloadURL: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.app.fill")
                .foregroundColor(.accentColor)
            Text("App update available")
                .font(.subheadline)
                .foregroundColor(.accentColor)
            Spacer()
            Button("Install") {
                NotificationCenter.default.post(name: .datahawkHidePopover, object: nil)
                startUpdate(downloadURL: downloadURL)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.08))
    }
}

// MARK: - Admin UI & WiFi QR buttons

/// Row of action buttons: "Open Admin UI" (opens the router's web interface)
/// and a QR code button (shows a WiFi sharing sheet).
struct AdminButtonSection: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 8) {
            Button(action: openAdminUI) {
                HStack {
                    Image(systemName: "safari")
                    Text("Open Admin UI")
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.regular)
            .disabled(state.metrics?.adminURL == nil)

            Button(action: openWiFiQR) {
                Image(systemName: "qrcode")
            }
            .controlSize(.regular)
            .disabled(state.metrics?.wifiEnabled != true)
            .help("Share WiFi via QR code")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    private func openAdminUI() {
        guard let urlStr = state.metrics?.adminURL,
              let url = URL(string: urlStr) else { return }

        NotificationCenter.default.post(name: .datahawkHidePopover, object: nil)
        NSWorkspace.shared.open(url)
    }

    private func openWiFiQR() {
        guard let m = state.metrics, m.wifiEnabled,
              let ssid = m.wifiSSID,
              let pass = m.wifiPassphrase else { return }

        NotificationCenter.default.post(name: .datahawkHidePopover, object: nil)
        WiFiQRWindowController.shared.show(ssid: ssid, passphrase: pass)
    }
}
