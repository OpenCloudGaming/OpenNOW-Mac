import Foundation
import Security

public enum GFNTokenStore {
    private static let service = "OpenNOW.GFN"
    private static let tokenKeyPrefix = "tokens."

    public struct Tokens: Codable, Sendable, Equatable {
        public var accessToken: String
        public var idToken: String
        public var refreshToken: String
        public var clientToken: String

        public init(accessToken: String, idToken: String, refreshToken: String, clientToken: String) {
            self.accessToken = accessToken
            self.idToken = idToken
            self.refreshToken = refreshToken
            self.clientToken = clientToken
        }

        public var isEmpty: Bool {
            accessToken.isEmpty && idToken.isEmpty && refreshToken.isEmpty && clientToken.isEmpty
        }
    }

    public static func save(_ tokens: Tokens, forIdentity identity: String) {
        guard !identity.isEmpty, !tokens.isEmpty else { return }
        let account = tokenKeyPrefix + identity
        do {
            let data = try JSONEncoder().encode(tokens)
            upsert(data: data, account: account)
        } catch {
            OPNAuthService.shared.logKeychainError("save", identity: identity, error: error)
        }
    }

    public static func load(forIdentity identity: String) -> Tokens? {
        guard !identity.isEmpty else { return nil }
        let account = tokenKeyPrefix + identity
        guard let data = loadRaw(account: account) else { return nil }
        do {
            return try JSONDecoder().decode(Tokens.self, from: data)
        } catch {
            OPNAuthService.shared.logKeychainError("load", identity: identity, error: error)
            return nil
        }
    }

    public static func delete(forIdentity identity: String) {
        guard !identity.isEmpty else { return }
        let account = tokenKeyPrefix + identity
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    public static func deleteAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func upsert(data: Data, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            OPNAuthService.shared.logKeychainStatus("update", account: account, status: updateStatus)
            return
        }
        var add = query
        attributes.forEach { add[$0.key] = $0.value }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus != errSecSuccess {
            OPNAuthService.shared.logKeychainStatus("add", account: account, status: addStatus)
        }
    }

    private static func loadRaw(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                OPNAuthService.shared.logKeychainStatus("load", account: account, status: status)
            }
            return nil
        }
        return item as? Data
    }
}
