import Foundation
import Security

public protocol TokenStoring: Sendable {
    func save(_ token: String, account: String) async throws
    func read(account: String) async throws -> String?
    func delete(account: String) async throws
    func deleteAll() async throws
}

public struct KeychainStore: TokenStoring, Sendable {
    public let service: String

    public init(service: String = "com.shlummie.viziocontrol.smartcast") {
        self.service = service
    }

    public func save(_ token: String, account: String) async throws {
        guard !account.isEmpty, let data = token.data(using: .utf8) else {
            throw VizioControlError.message("Pairing token could not be encoded.")
        }
        let query = baseQuery(account: account)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updates: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ]
            try check(
                SecItemUpdate(query as CFDictionary, updates as CFDictionary),
                operation: "updated"
            )
        } else {
            try check(status, operation: "saved")
        }
    }

    public func read(account: String) async throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        try check(status, operation: "read")
        guard let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
            throw VizioControlError.message("Pairing token in Keychain is unreadable.")
        }
        return token
    }

    public func delete(account: String) async throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        if status != errSecItemNotFound { try check(status, operation: "deleted") }
    }

    public func deleteAll() async throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status, operation: "deleted") }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func check(_ status: OSStatus, operation: String) throws {
        guard status == errSecSuccess else {
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            throw VizioControlError.message("Pairing token could not be \(operation): \(detail).")
        }
    }
}
