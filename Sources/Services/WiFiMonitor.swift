// WiFiMonitor.swift
// DataHawk
//
// Monitors WiFi connectivity via NWPathMonitor and exposes the current SSID
// and BSSID on demand. Fires `onNetworkChange` whenever the path changes
// (connect, disconnect, roam) so the caller can re-check which hotspot is
// in range.

import Foundation
import CoreWLAN
import Network

class WiFiMonitor {

    /// Called on the main thread whenever the WiFi path changes.
    var onNetworkChange: (() -> Void)?

    private let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private let queue   = DispatchQueue(label: "com.datahawk.wifi-monitor", qos: .utility)

    // MARK: - Lifecycle

    func start() {
        monitor.pathUpdateHandler = { [weak self] _ in
            // Bounce to main so the callback can safely touch AppKit / AppState.
            DispatchQueue.main.async { self?.onNetworkChange?() }
        }

        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }

    // MARK: - SSID detection

    /// Returns the SSID of the currently associated WiFi network, or `nil`
    /// if no interface is connected.
    func currentSSID() -> String? {
        for iface in CWWiFiClient.shared().interfaces() ?? [] {
            if let ssid = iface.ssid(), !ssid.isEmpty {
                return ssid
            }
        }

        return nil
    }

    // MARK: - BSSID detection

    /// Returns the BSSID of the currently associated access point.
    ///
    /// Two strategies are tried in order:
    ///
    ///   1. **CoreWLAN** (`CWInterface.bssid()`) — the preferred method, but
    ///      returns `nil` unless Location Services is granted (macOS 10.15+).
    ///
    ///   2. **ipconfig getsummary** — reads from configd with no location
    ///      permission required. Reliable fallback when the user hasn't
    ///      granted location access yet.
    func currentBSSID() -> String? {
        let client = CWWiFiClient.shared()

        // Collect all WiFi interface names for the ipconfig fallback.
        let ifaceNames: [String] = (client.interfaces() ?? [])
            .compactMap { $0.interfaceName }
            .filter { !$0.isEmpty }
            .nonEmptyOrDefault(["en0", "en1"])

        // Strategy 1: CoreWLAN (requires location permission).
        for iface in client.interfaces() ?? [] {
            if let bssid = iface.bssid(), !bssid.isEmpty {
                print("[DataHawk] BSSID via CoreWLAN (\(iface.interfaceName ?? "?")): \(bssid)")
                return bssid
            }
        }

        // Strategy 2: ipconfig getsummary (no location permission needed).
        for name in ifaceNames {
            if let bssid = bssidViaIPConfig(interface: name) {
                print("[DataHawk] BSSID via ipconfig (\(name)): \(bssid)")
                return bssid
            }
        }

        print("[DataHawk] currentBSSID: no BSSID found on interfaces \(ifaceNames)")
        return nil
    }

    // MARK: - ipconfig fallback (private)

    /// Shells out to `/usr/sbin/ipconfig getsummary <iface>` and parses the
    /// BSSID from the key-value output. Lines look like:
    ///
    ///     BSSID : aa:bb:cc:dd:ee:ff
    ///
    private func bssidViaIPConfig(interface: String) -> String? {
        let process = Process()

        process.executableURL  = URL(fileURLWithPath: "/usr/sbin/ipconfig")
        process.arguments      = ["getsummary", interface]

        let outPipe = Pipe()

        process.standardOutput = outPipe
        process.standardError  = Pipe()   // silence stderr

        guard (try? process.run()) != nil else { return nil }

        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }

        let output = String(
            data: outPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Split on " : " to separate key from value.
            let parts = trimmed.components(separatedBy: " : ")

            guard parts.count >= 2,
                  parts[0].trimmingCharacters(in: .whitespaces).uppercased() == "BSSID"
            else { continue }

            let bssid = parts[1...]
                .joined(separator: " : ")
                .trimmingCharacters(in: .whitespaces)
                .lowercased()

            if !bssid.isEmpty { return bssid }
        }

        return nil
    }
}

// MARK: - Array helper

private extension Array {
    /// Returns `self` when non-empty, otherwise a fallback default.
    func nonEmptyOrDefault(_ fallback: [Element]) -> [Element] {
        isEmpty ? fallback : self
    }
}
