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
    @ObservedObject private var state  = AppState.shared
    @ObservedObject private var config = ConfigStore.shared
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

            if config.recordSessionHistory && !SessionStore.shared.sessions.isEmpty {
                Button {
                    NotificationCenter.default.post(name: .datahawkHidePopover, object: nil)
                    SessionsWindowController.shared.show()
                } label: {
                    Label("See Past Sessions", systemImage: "map")
                        .font(.system(size: 11, weight: .medium))
                }
                .controlSize(.small)
                .padding(.top, 6)
                .onHover { inside in
                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
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
                // Group 0: upstream offload link (only while offloading).
                if let offload = m.offload {
                    metricGroup {
                        metricRow("Offloading to") {
                            HStack(spacing: 4) {
                                Image(systemName: offloadIcon(offload))
                                    .foregroundColor(offloadIconColor(offload))
                                    .font(.system(size: 11))
                                Text(offloadLabel(offload)).fontDesign(.monospaced)
                            }
                        }
                    }

                    Divider()
                }

                // Group 1: cellular connection info.
                metricGroup {
                    if let name = state.activeHotspot?.name {
                        metricRow("Hotspot") {
                            Text(name).fontDesign(.monospaced)
                        }
                    }

                    metricRow(
                        "Connection",
                        isSpinner: m.connectionStatus.lowercased() == "connecting"
                    ) {
                        Text(m.connectionStatus).fontDesign(.monospaced)
                    }

                    metricRow("Signal") {
                        Text(signalLabel(m.signalStrength))
                            .fontDesign(.monospaced)
                            .foregroundColor(m.signalStrength <= 2 ? .orange : nil)
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

                // Group 4: system info (uptime + temperatures).
                let hasBatteryTemp = !m.noBattery && m.batteryTemperature != nil

                let hasSystemInfo = m.uptimeSeconds != nil
                    || m.routerTemperature != nil
                    || hasBatteryTemp

                if hasSystemInfo {
                    Divider()

                    metricGroup {
                        if let uptime = m.uptimeSeconds {
                            metricRow("Uptime") {
                                Text(formatUptime(uptime)).fontDesign(.monospaced)
                            }
                        }

                        if let temp = m.routerTemperature {
                            metricRow("Device temp.") {
                                let tempColor: Color? = m.deviceTempCritical
                                    ? .red
                                    : (temp > (m.useMetricSystem ? 55 : 130) ? .orange : nil)

                                HStack(spacing: 4) {
                                    if m.deviceTempCritical {
                                        Image(systemName: "exclamationmark.circle.fill")
                                            .foregroundColor(.red)
                                            .font(.system(size: 11))
                                    }
                                    Text(formatTemperature(temp, metric: m.useMetricSystem))
                                        .fontDesign(.monospaced)
                                        .foregroundColor(tempColor)
                                }
                            }
                        }

                        if hasBatteryTemp, let battTemp = m.batteryTemperature {
                            metricRow("Battery temp.") {
                                let battTempColor: Color? = m.isBatteryTempAbnormal
                                    ? .red
                                    : (battTemp > (m.useMetricSystem ? 40 : 104) ? .yellow : nil)

                                HStack(spacing: 4) {
                                    if m.isBatteryTempAbnormal {
                                        Image(systemName: "heat.waves")
                                            .foregroundColor(.red)
                                            .font(.system(size: 11))
                                    }
                                    Text(formatTemperature(battTemp, metric: m.useMetricSystem))
                                        .fontDesign(.monospaced)
                                        .foregroundColor(battTempColor)
                                }
                            }
                        }

                    }
                }
            }
        }
    }

    // MARK: - Formatters

    private func offloadIcon(_ link: OffloadLink) -> String {
        switch link {
        case .ethernet:                return "network"
        case .wifi(_, let secure):     return secure ? "wifi" : "wifi.exclamationmark"
        }
    }

    /// Orange flags an unsecured upstream WiFi network.
    private func offloadIconColor(_ link: OffloadLink) -> Color {
        switch link {
        case .ethernet:                return .blue
        case .wifi(_, let secure):     return secure ? .blue : .orange
        }
    }

    private func offloadLabel(_ link: OffloadLink) -> String {
        switch link {
        case .ethernet:            return "Ethernet"
        case .wifi(let ssid, _):   return ssid
        }
    }

    private func signalLabel(_ bars: Int) -> String {
        switch bars {
        case 0:  return "None"
        case 1:  return "Very Poor"
        case 2:  return "Poor"
        case 3:  return "Okay"
        case 4:  return "Good"
        default: return "Excellent"
        }
    }

    private func formatUptime(_ seconds: Int) -> String {
        let d = seconds / 86400
        let h = (seconds % 86400) / 3600
        let m = (seconds % 3600) / 60

        if d > 0 { return "\(d)d" }
        if h > 0 { return "\(h)h" }
        return "\(m)m"
    }

    private func formatTemperature(_ temp: Double, metric: Bool) -> String {
        if metric {
            return String(format: "%.0f°C", temp)
        } else {
            return String(format: "%.0f°F", temp)
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
                    .scaleEffect(0.3)
                    .frame(width: 6, height: 6)
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
    @ObservedObject private var config = ConfigStore.shared

    var body: some View {
        HStack(spacing: 8) {
            Button(action: openAdminUI) {
                HStack {
                    Image(systemName: "safari")
                    Text("Admin UI")
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.regular)
            .disabled(state.metrics?.adminURL == nil)
            .onHover { inside in
                guard state.metrics?.adminURL != nil else { return }
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }

            if config.recordSessionHistory {
                Button(action: openSessions) {
                    Image(systemName: "map")
                }
                .controlSize(.regular)
                .help("Show session history")
                .onHover { inside in
                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }

            Button(action: openWiFiQR) {
                Image(systemName: "qrcode")
            }
            .controlSize(.regular)
            .disabled(state.metrics?.wifiEnabled != true)
            .help("Share WiFi via QR code")
            .onHover { inside in
                guard state.metrics?.wifiEnabled == true else { return }
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }

            Button(action: openSMS) {
                Image(systemName: "text.bubble")
            }
            .controlSize(.regular)
            .disabled(state.metrics?.smsReady != true)
            .help(state.metrics?.smsReady == true ? "Show text messages" : "Text messages not supported")
            .onHover { inside in
                guard state.metrics?.smsReady == true else { return }
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .overlay(alignment: .topTrailing) {
                if let unread = state.metrics?.smsUnreadCount, unread > 0 {
                    Text(unread > 9 ? "9+" : "\(unread)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(Color.red))
                        .offset(x: 8, y: -6)
                }
            }
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

    private func openSessions() {
        NotificationCenter.default.post(name: .datahawkHidePopover, object: nil)
        SessionsWindowController.shared.show()
    }

    private func openSMS() {
        NotificationCenter.default.post(name: .datahawkHidePopover, object: nil)
        SMSWindowController.shared.show()
    }

    private func openWiFiQR() {
        guard let m = state.metrics, m.wifiEnabled,
              let ssid = m.wifiSSID,
              let pass = m.wifiPassphrase else { return }

        NotificationCenter.default.post(name: .datahawkHidePopover, object: nil)
        WiFiQRWindowController.shared.show(ssid: ssid, passphrase: pass)
    }
}
