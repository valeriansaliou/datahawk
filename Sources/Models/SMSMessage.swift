// SMSMessage.swift
// DataHawk
//
// Value type for a single SMS message reported by the router's model.json.
// Parsed fresh on every poll cycle — the router is the source of truth, there
// is no local persistence (unlike SessionRecord).

import Foundation

struct SMSMessage: Identifiable, Equatable {
    var id: String
    /// `nil` when the router reports no usable receive time (e.g. a
    /// carrier-injected welcome SMS with `rxTime` of "0").
    var rxDate: Date?
    var text: String
    var sender: String
    var isRead: Bool
}
