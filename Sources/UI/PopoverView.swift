import SwiftUI
import AppKit

// MARK: - Root popover view

struct PopoverView: View {
    @ObservedObject private var state = AppState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderSection(state: state)

            if state.metrics?.isHighDataUsage == true, let m = state.metrics {
                Divider()
                HighDataUsageAlertSection(metrics: m)
            }

            if let error = state.fetchError {
                Divider()
                ErrorBannerSection(reason: error)
            }

            if state.connectionState == .disconnected {
                Divider()
                DisconnectedSection()
            } else if state.metrics != nil {
                Divider()
                MetricsSection(state: state)
                Divider()
                AdminButtonSection(state: state)
                if state.metrics?.firmwareUpdateAvailable == true {
                    Divider()
                    FirmwareAlertSection()
                }
            }

            Divider()
            FooterSection()
        }
        .frame(width: 280)
    }
}

// MARK: - Header

private struct HeaderSection: View {
    @ObservedObject var state: AppState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 20))
                .foregroundColor(
                    (state.connectionState == .disconnected || state.connectionState == .failed)
                        ? .secondary : .primary
                )
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 5) {
                titleText
                subtitleText
            }

            Spacer()

            if state.metrics?.isRoaming == true {
                Text("Roaming")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(colorScheme == .dark ? .black : .white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.orange)
                    .clipShape(Capsule())
            }

            if state.connectionState != .disconnected {
                if state.isFetching {
                    ProgressView()
                        .scaleEffect(0.45)
                        .frame(width: 13, height: 13)
                } else {
                    Button {
                        if NSEvent.modifierFlags.contains(.option) {
                            RouterService.shared.forceFullRefresh()
                        } else {
                            RouterService.shared.refresh()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 20, height: 20)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var titleText: some View {
        if state.connectionState == .connected, let m = state.metrics {
            HStack(spacing: 8) {
                Text(m.provider)
                    .font(.headline)
                Text(m.networkType.rawValue)
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(colorScheme == .dark ? .black : .white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(colorScheme == .dark ? Color.white : Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        } else {
            Text("DataHawk")
                .font(.headline)
        }
    }

    @ViewBuilder
    private var subtitleText: some View {
        switch state.connectionState {
        case .disconnected:
            Text("No hotspot detected")
                .font(.caption)
                .foregroundColor(.secondary)
        case .loading:
            Text("Acquiring…")
                .font(.caption)
                .foregroundColor(.secondary)
        case .failed:
            Text("Could not refresh")
                .font(.caption)
                .foregroundColor(.secondary)
        case .connected:
            if let m = state.metrics {
                HStack(spacing: 4) {
                    Image(systemName: batteryIconName(m))
                        .font(.system(size: 15.5))
                        .foregroundColor(batteryIconColor(m))
                    Text(batteryStateText(m))
                        .font(.caption)
                        .foregroundColor(isBatteryLow(m) ? .red : .secondary)
                }
            }
        }
    }

    private func batteryIconName(_ m: RouterMetrics) -> String {
        if m.isPluggedIn { return "battery.100percent.bolt" }
        switch m.batteryPercent ?? 0 {
        case 0..<10:  return "battery.0percent"
        case 10..<25: return "battery.25percent"
        case 25..<50: return "battery.50percent"
        case 50..<75: return "battery.75percent"
        default:      return "battery.100percent"
        }
    }

    private func isBatteryLow(_ m: RouterMetrics) -> Bool {
        guard !m.isPluggedIn, let pct = m.batteryPercent else { return false }
        return pct < m.batteryLowThreshold
    }

    private func batteryIconColor(_ m: RouterMetrics) -> Color {
        if m.isPluggedIn { return .green }
        return isBatteryLow(m) ? .red : .secondary
    }

    private func batteryStateText(_ m: RouterMetrics) -> String {
        if m.noBattery {
            return m.isPluggedIn ? "Plugged in" : "No battery"
        }
        guard let pct = m.batteryPercent else { return "—" }
        if m.isCharging  { return "\(pct)% (Charging)" }
        if isBatteryLow(m) { return "\(pct)% (Low Battery)" }
        return "\(pct)%"
    }

    private var iconName: String {
        (state.connectionState == .disconnected || state.connectionState == .failed)
            ? "antenna.radiowaves.left.and.right.slash"
            : "antenna.radiowaves.left.and.right"
    }
}

// MARK: - Error banner

private struct ErrorBannerSection: View {
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

private struct DisconnectedSection: View {
    @ObservedObject private var state = AppState.shared
    @State private var copied = false

    var body: some View {
        VStack(spacing: 8) {
            Text("Connect to a known WiFi hotspot")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 0) {
                Text("Add your router in ")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("Settings") { SettingsWindowController.shared.show() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .onHover { inside in
                        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                Text(" to get started.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

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
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(bssid, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
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

// MARK: - Metrics

private struct MetricsSection: View {
    @ObservedObject var state: AppState

    var body: some View {
        if let m = state.metrics {
            VStack(alignment: .leading, spacing: 0) {
                // Group 1: connection info
                metricGroup {
                    if let name = state.activeHotspot?.name {
                        metricRow("Hotspot") {
                            Text(name).fontDesign(.monospaced)
                        }
                    }
                    metricRow("Connection", isSpinner: m.connectionStatus.lowercased() != "connected") {
                        Text(m.connectionStatus).fontDesign(.monospaced)
                    }
                    metricRow("Signal") {
                        Text("\(m.signalStrength * 20)%").fontDesign(.monospaced)
                    }
                }

                Divider()

                // Group 2: WiFi
                metricGroup {
                    metricRow("WiFi network") {
                        if m.wifiEnabled {
                            Text(state.detectedSSID ?? "—").fontDesign(.monospaced)
                        } else {
                            Text("OFF").fontDesign(.monospaced).foregroundColor(.secondary)
                        }
                    }
                    metricRow("WiFi users") {
                        Text("\(m.connectedUsers)").fontDesign(.monospaced)
                    }
                }

                // Group 3: data (only when at least one data field is present)
                if m.dataUsedGB != nil || m.dataLimitGB != nil || m.dataUsagePercent != nil {
                    Divider()
                    metricGroup {
                        if let pct = m.dataUsagePercent {
                            metricRow("Data left") {
                                Text(String(format: "%.1f%%", (1.0 - pct) * 100)).fontDesign(.monospaced)
                            }
                        }
                        if let used = m.dataUsedGB {
                            metricRow("Data used") {
                                Text(String(format: "%.2f GB", used)).fontDesign(.monospaced)
                            }
                        }
                        if let limit = m.dataLimitGB {
                            metricRow("Data limit") {
                                Text(String(format: "%.0f GB", limit)).fontDesign(.monospaced)
                            }
                        }
                    }
                }


            }
        }
    }

    @ViewBuilder
    private func metricGroup<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

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

private struct HighDataUsageAlertSection: View {
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

// MARK: - Firmware alert

private struct FirmwareAlertSection: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundColor(.orange)
            Text("Firmware update available")
                .font(.subheadline)
                .foregroundColor(.orange)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.08))
    }
}

// MARK: - Admin UI button

private struct AdminButtonSection: View {
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

    private func openAdminUI() {
        guard
            let urlStr = state.metrics?.adminURL,
            let url    = URL(string: urlStr)
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func openWiFiQR() {
        guard let m = state.metrics, m.wifiEnabled,
              let ssid = m.wifiSSID, let pass = m.wifiPassphrase
        else { return }
        WiFiQRWindowController.shared.show(ssid: ssid, passphrase: pass)
    }
}

// MARK: - Footer (Settings + Quit)

private struct FooterSection: View {
    var body: some View {
        HStack {
            Button {
                SettingsWindowController.shared.show()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "gear")
                    Text("Settings")
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)

            Spacer()

            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Reusable sub-views

/// A labelled metric row with a fixed-width leading label and trailing content.
struct MetricRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label   = label
        self.content = content
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(width: 62, alignment: .leading)
            content()
            Spacer()
        }
    }
}

/// Animated progress bar for data usage.  Colour transitions green → orange → red.
struct DataUsageBar: View {
    let percent: Double   // 0.0 – 1.0

    private var barColor: Color {
        if percent < 0.70 { return .green }
        if percent < 0.90 { return .orange }
        return .red
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: 6)
                RoundedRectangle(cornerRadius: 3)
                    .fill(barColor)
                    .frame(width: geo.size.width * CGFloat(percent), height: 6)
                    .animation(.easeOut(duration: 0.4), value: percent)
            }
        }
        .frame(height: 6)
    }
}

/// Five-bar cellular signal indicator.
struct SignalBarsView: View {
    let strength: Int   // 0–5

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(i <= strength ? Color.primary : Color.secondary.opacity(0.25))
                    .frame(width: 4, height: CGFloat(4 + i * 3))
            }
        }
    }
}
