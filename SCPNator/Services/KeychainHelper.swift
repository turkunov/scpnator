import Foundation
import Security

enum KeychainError: Error {
    case unexpectedStatus(OSStatus)
    case itemNotFound
}

final class KeychainHelper {
    static let shared = KeychainHelper()
    private init() {}

    func setPassword(_ password: String, service: String, account: String) throws {
        let passwordData = password.data(using: .utf8) ?? Data()

        // Try update first
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: passwordData
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        if status != errSecItemNotFound {
            throw KeychainError.unexpectedStatus(status)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = passwordData
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    func getPassword(service: String, account: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { throw KeychainError.itemNotFound }
        if status != errSecSuccess { throw KeychainError.unexpectedStatus(status) }
        guard let data = item as? Data, let password = String(data: data, encoding: .utf8) else { return "" }
        return password
    }
}


