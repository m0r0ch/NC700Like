import Foundation
import Security

enum KeychainStore {
    enum Error: Swift.Error {
        case unexpectedStatus(OSStatus)
    }

    private static var service: String {
        Bundle.main.bundleIdentifier ?? "jp.nc700like.NC700Like"
    }

    static func save(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecItemNotFound:
            var addQuery = query
            for (k, v) in attributes { addQuery[k] = v }
            status = SecItemAdd(addQuery as CFDictionary, nil)
        case errSecSuccess:
            status = SecItemUpdate(
                query as CFDictionary,
                attributes as CFDictionary
            )
        default:
            break
        }
        guard status == errSecSuccess else {
            throw Error.unexpectedStatus(status)
        }
    }

    static func load(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func deleteAll() {
        delete(Account.accessToken)
        delete(Account.refreshToken)
        delete(Account.expiresAt)
    }

    /// アカウント名の定義。トークン文字列自体はここには出さない。
    enum Account {
        static let accessToken = "spotify.accessToken"
        static let refreshToken = "spotify.refreshToken"
        static let expiresAt = "spotify.expiresAt"
    }
}
