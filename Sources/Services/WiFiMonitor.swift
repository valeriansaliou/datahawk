// WiFiMonitor.swift
// DataHawk
//
// Monitors WiFi connectivity via NWPathMonitor and SCDynamicStore. Fires
// `onNetworkChange` on WiFi path changes (association, roam, disconnect) AND
// when any WiFi interface's IPv4 state changes in the System Configuration
// database (i.e. DHCP lease acquired, renewed, or released). The two
// sources complement each other: NWPathMonitor is fast for link-layer events;
// SCDynamicStore is authoritative for IP-layer readiness.

import Foundation
import CoreWLAN
import Network
import SystemConfiguration

// MARK: - SCDynamicStore C callback

// Must be a global function (not a closure) to be used as a C function pointer.
private func ipv4StoreCallback(
    _: SCDynamicStore,
    _: CFArray,
    _ info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    let monitor = Unmanaged<WiFiMonitor>.fromOpaque(info).takeUnretainedValue()
    DispatchQueue.main.async { monitor.onNetworkChange?() }
}

// MARK: -

final class WiFiMonitor {

    /// Called on the main thread whenever the WiFi path or IPv4 state changes.
    var onNetworkChange: (() -> Void)?

    private let monitor  = NWPathMonitor(requiredInterfaceType: .wifi)
    private let queue    = DispatchQueue(label: "com.datahawk.wifi-monitor", qos: .utility)
    private var dynStore: SCDynamicStore?

    // MARK: - Lifecycle

    func start() {
        // NWPathMonitor — fast signal for WiFi association / disassociation.
        monitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.onNetworkChange?() }
        }
        monitor.start(queue: queue)

        // SCDynamicStore — fires precisely when any interface's IPv4 config
        // changes in configd (DHCP lease acquired, renewed, or released).
        var ctx = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        guard let store = SCDynamicStoreCreate(
            nil, "com.datahawk.wifi-monitor" as CFString,
            ipv4StoreCallback, &ctx
        ) else { return }

        // Watch all interfaces with a regex pattern key.
        let patterns = ["State:/Network/Interface/.*/IPv4"] as CFArray
        SCDynamicStoreSetNotificationKeys(store, nil, patterns)
        SCDynamicStoreSetDispatchQueue(store, queue)

        dynStore = store
    }

    func stop() {
        monitor.cancel()
        dynStore = nil  // releasing the store unregisters the dispatch queue
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
        let ifaceNames = wifiInterfaceNames()

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

    // MARK: - LAN IP detection

    /// Returns `true` if any WiFi interface has a routable IPv4 address in the
    /// System Configuration database, meaning DHCP has completed successfully.
    /// Link-local `169.254.x.x` addresses (APIPA / DHCP failure) are excluded.
    func hasLANIPAddress() -> Bool {
        guard let store = dynStore else { return false }

        for name in wifiInterfaceNames() {
            let key = "State:/Network/Interface/\(name)/IPv4" as CFString

            guard let dict     = SCDynamicStoreCopyValue(store, key) as? [String: Any],
                  let addrs    = dict["Addresses"] as? [String],
                  addrs.contains(where: { !$0.hasPrefix("169.254.") }) else { continue }

            print("[DataHawk] LAN IP ready on \(name) (SCDynamicStore)")
            return true
        }

        print("[DataHawk] hasLANIPAddress: no routable IPv4 on WiFi interfaces")
        return false
    }

    // MARK: - Private helpers

    /// Returns WiFi interface names from CoreWLAN, falling back to ["en0", "en1"].
    private func wifiInterfaceNames() -> [String] {
        let client = CWWiFiClient.shared()
        return (client.interfaces() ?? [])
            .compactMap { $0.interfaceName }
            .filter { !$0.isEmpty }
            .nonEmptyOrDefault(["en0", "en1"])
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
