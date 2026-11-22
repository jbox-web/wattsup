import Foundation
import Security

/// Where NUT passwords live. The app uses the login Keychain; tests use a double.
protocol SecretStore {
    /// nil when there is no such entry.
    func password(service: String, account: String) throws -> String?
    func setPassword(_ password: String, service: String, account: String) throws
    /// Deleting an entry that does not exist is not an error.
    func delete(service: String, account: String) throws
}

struct KeychainError: LocalizedError {
    let status: OSStatus

    /// What went wrong, without the "Keychain" prefix.
    var reason: String {
        SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
    }

    var errorDescription: String? {
        "Keychain: \(reason)"
    }
}

/// Generic passwords of the login Keychain, also readable by the `wattsup` CLI.
struct Keychain: SecretStore {
    private func query(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func password(service: String, account: String) throws -> String? {
        var query = query(service, account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return String(data: data, encoding: .utf8)
    }

    func setPassword(_ password: String, service: String, account: String) throws {
        let data = Data(password.utf8)
        var status = SecItemUpdate(query(service, account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(service, account)
            item[kSecValueData as String] = data
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func delete(service: String, account: String) throws {
        let status = SecItemDelete(query(service, account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
