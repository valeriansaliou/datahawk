// KeychainStore.swift
// DataHawk
//
// Thin wrapper around Security.framework generic-password items. Used for
// everything secret: router admin passwords (ConfigStore) and cached NETGEAR
// auth cookies (NetgearProvider). Items are scoped to a fixed service name;
// callers pick a stable per-secret account string.
//
// All functions are synchronous and thread-safe (SecItem* is), and fail
// soft: a read miss returns nil, a failed write is logged and dropped —
// consistent with how the rest of the persistence layer behaves.

import Foundation
import Security

enum KeychainStore {

    /// Service under which every DataHawk keychain item is filed.
    private static let service = "com.datahawk.app"

    // MARK: - String convenience

    static func readString(account: String) -> String? {
        readData(account: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func writeString(_ value: String, account: String) {
        guard let data = value.data(using: .utf8) else { return }
        writeData(data, account: account)
    }

    // MARK: - Data primitives

    static func readData(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData  as String: true,
            kSecMatchLimit  as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else { return nil }

        return result as? Data
    }

    static func writeData(_ data: Data, account: String) {
        let query: [String: Any] = [
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        // Update in place when the item exists; add it otherwise.
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)

        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }

        if status != errSecSuccess {
            print("[DataHawk] Keychain write failed for '\(account)' (status \(status))")
        }
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        SecItemDelete(query as CFDictionary)
    }
}
