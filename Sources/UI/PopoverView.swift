// PopoverView.swift
// DataHawk
//
// Root SwiftUI view displayed inside the NSPopover attached to the status-bar
// icon. Composes the header, content sections, and footer into a single
// vertical stack. The view reacts to AppState changes via @ObservedObject.

import SwiftUI
import AppKit

// MARK: - Root popover view

struct PopoverView: View {
    @ObservedObject private var state = AppState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderSection(state: state)

            // High data usage warning (above all other content).
            if state.metrics?.isHighDataUsage == true, let m = state.metrics {
                Divider()
                HighDataUsageAlertSection(metrics: m)
            }

            // Error banner (shown alongside metrics when a refresh fails
            // after a previously successful fetch).
            if let error = state.fetchError {
                Divider()
                ErrorBannerSection(reason: error)
            }

            // Main content: disconnected placeholder or live metrics.
            if state.connectionState == .noHotspot || state.connectionState == .disconnected {
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

            if let url = state.updateDownloadURL {
                Divider()
                UpdateAvailableSection(downloadURL: url)
            }

            Divider()
            FooterSection()
        }
        .frame(width: 280)
    }
}

// MARK: - Header

/// Top section showing the carrier name, network type badge, battery status,
/// refresh button, and optional roaming pill. Adapts its appearance to the
/// current connection state.
struct HeaderSection: View {
    @ObservedObject var state: AppState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Antenna icon (dimmed when disconnected / failed).
            Image(systemName: iconName)
                .font(.system(size: 20))
                .foregroundColor(isInactive ? .secondary : .primary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 5) {
                titleText
                subtitleText
            }

            Spacer()

            // Roaming badge.
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

            // Refresh button / spinner (hidden when not on a known hotspot).
            if state.connectionState != .noHotspot && state.connectionState != .disconnected {
                if state.isFetching {
                    ProgressView()
                        .scaleEffect(0.45)
                        .frame(width: 13, height: 13)
                } else {
                    Button {
                        // Option-click: full re-auth; plain click: soft refresh.
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

    // MARK: - Title (carrier + network type badge)

    @ViewBuilder
    private var titleText: some View {
        if state.connectionState == .connected, let m = state.metrics {
            HStack(spacing: 8) {
                Text(m.provider)
                    .font(.headline)

                // Network generation pill (e.g. "5G", "4G").
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

    // MARK: - Subtitle (battery state or connection status text)

    @ViewBuilder
    private var subtitleText: some View {
        switch state.connectionState {
        case .noHotspot:
            Text("No hotspot detected")
                .font(.caption)
                .foregroundColor(.secondary)
        case .disconnected:
            Text("Connecting\u{2026}")
                .font(.caption)
                .foregroundColor(.secondary)
        case .loading:
            Text("Acquiring\u{2026}")
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

    // MARK: - Battery helpers

    private var isInactive: Bool {
        state.connectionState == .noHotspot
            || state.connectionState == .disconnected
            || state.connectionState == .failed
    }

    private var iconName: String {
        state.connectionState == .noHotspot
            ? "antenna.radiowaves.left.and.right.slash"
            : "antenna.radiowaves.left.and.right"
    }

    private func isBatteryLow(_ m: RouterMetrics) -> Bool {
        guard !m.isPluggedIn, let pct = m.batteryPercent else { return false }
        return pct < m.batteryLowThreshold
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

    private func batteryIconColor(_ m: RouterMetrics) -> Color {
        if m.isPluggedIn { return .green }
        return isBatteryLow(m) ? .red : .secondary
    }

    private func batteryStateText(_ m: RouterMetrics) -> String {
        if m.noBattery {
            return m.isPluggedIn ? "Plugged in" : "No battery"
        }

        guard let pct = m.batteryPercent else { return "\u{2014}" }

        if m.isCharging    { return "\(pct)% (Charging)" }
        if isBatteryLow(m) { return "\(pct)% (Low Battery)" }

        return "\(pct)%"
    }
}

// MARK: - Footer (Settings + Quit)

/// Bottom bar with a Settings shortcut and a Quit button.
struct FooterSection: View {
    var body: some View {
        HStack {
            Button {
                NotificationCenter.default.post(name: .datahawkHidePopover, object: nil)
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
