import Foundation
import CoreWLAN
import Network

/// Monitors WiFi connectivity and fires `onNetworkChange` whenever the path
/// changes (connect, disconnect, roam).  The current BSSID is read on-demand.
class WiFiMonitor {
    var onNetworkChange: (() -> Void)?

    private let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private let queue   = DispatchQueue(label: "com.datahawk.wifi-monitor", qos: .utility)

    // MARK: - Lifecycle

    func start() {
        monitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.onNetworkChange?() }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }

    // MARK: - SSID detection

    /// Returns the SSID of the currently associated access point via CoreWLAN.
    func currentSSID() -> String? {
        for iface in CWWiFiClient.shared().interfaces() ?? [] {
            if let ssid = iface.ssid(), !ssid.isEmpty { return ssid }
        }
        return nil
    }

    // MARK: - BSSID detection

    /// Returns the BSSID of the currently associated access point.
    ///
    /// Strategy:
    ///   1. CoreWLAN `CWInterface.bssid()` — works when Location Services is
    ///      granted (macOS 10.15+).
    ///   2. `ipconfig getsummary <iface>` — reads from configd, no location
    ///      permission required; reliable fallback.
    func currentBSSID() -> String? {
        let client = CWWiFiClient.shared()

        // Collect all WiFi interface names so we can try each one.
        let ifaceNames: [String] = (client.interfaces() ?? [])
            .compactMap { $0.interfaceName }
            .filter { !$0.isEmpty }
            .nonEmptyOrDefault(["en0", "en1"])

        // 1 — CoreWLAN (requires location permission)
        for iface in client.interfaces() ?? [] {
            if let bssid = iface.bssid(), !bssid.isEmpty {
                print("[DataHawk] BSSID via CoreWLAN (\(iface.interfaceName ?? "?")): \(bssid)")
                return bssid
            }
        }

        // 2 — ipconfig getsummary fallback
        for name in ifaceNames {
            if let bssid = bssidViaIPConfig(interface: name) {
                print("[DataHawk] BSSID via ipconfig (\(name)): \(bssid)")
                return bssid
            }
        }

        print("[DataHawk] currentBSSID: no BSSID found on interfaces \(ifaceNames)")
        return nil
    }

    // MARK: - ipconfig fallback

    private func bssidViaIPConfig(interface: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ipconfig")
        process.arguments     = ["getsummary", interface]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError  = Pipe()   // silence errors

        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8) ?? ""

        // Lines look like:  "  BSSID : aa:bb:cc:dd:ee:ff"
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Split on " : " to separate key from value
            let parts = trimmed.components(separatedBy: " : ")
            guard parts.count >= 2,
                  parts[0].trimmingCharacters(in: .whitespaces).uppercased() == "BSSID"
            else { continue }
            let bssid = parts[1...].joined(separator: " : ")
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            if !bssid.isEmpty { return bssid }
        }
        return nil
    }
}

// MARK: - Helpers

private extension Array {
    func nonEmptyOrDefault(_ fallback: [Element]) -> [Element] {
        isEmpty ? fallback : self
    }
}
