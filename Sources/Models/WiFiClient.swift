// WiFiClient.swift
// DataHawk
//
// Value type for a single client connected to the router, as reported by
// model.json. Re-parsed on every poll cycle — the router is the source of
// truth, there is no local persistence.

import Foundation

struct WiFiClient: Identifiable, Equatable {
    /// MAC address when the router reports one, otherwise the IP — the router
    /// occasionally omits either field.
    var id: String { macAddress.isEmpty ? ipAddress : macAddress }

    var name: String
    var ipAddress: String
    var macAddress: String
}
