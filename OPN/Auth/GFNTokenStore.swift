import Foundation
import Security

public enum GFNTokenStore {
    private static let baseServiceName = "OpenNOW.GFN"
    private static let tokenKeyPrefix = "tokens."

    /// The release build keeps the historical service name so existing installs find their tokens;
    /// every other identity gets its own so two running copies cannot read or purge each other's.
    private static var service: String {
        guard let identifier = Bundle.main.bundleIdentifier, !identifier.isEmpty,
              identifier != OPNProductIdentity.releaseBundleIdentifier else { return baseServiceName }
        return "\(baseServiceName).\(identifier)"
    }

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

    public static func save(_ tokens: Tokens, forIdentity identity: String, service override: String? = nil) {
        guard !identity.isEmpty, !tokens.isEmpty else { return }
        let account = tokenKeyPrefix + identity
        do {
            let data = try JSONEncoder().encode(tokens)
            upsert(data: data, account: account, service: override ?? service)
        } catch {
            logKeychainError("save", identity: identity, error: error)
        }
    }

    public static func load(forIdentity identity: String, service override: String? = nil) -> Tokens? {
        guard !identity.isEmpty else { return nil }
        let account = tokenKeyPrefix + identity
        guard let data = loadRaw(account: account, service: override ?? service) else { return nil }
        do {
            return try JSONDecoder().decode(Tokens.self, from: data)
        } catch {
            logKeychainError("load", identity: identity, error: error)
            return nil
        }
    }

    public static func delete(forIdentity identity: String, service override: String? = nil) {
        guard !identity.isEmpty else { return }
        let account = tokenKeyPrefix + identity
        SecItemDelete(baseQuery(account: account, service: override ?? service) as CFDictionary)
    }

    /// A service-only delete is unreliable, so every account is removed by service and account.
    public static func deleteAll(service override: String? = nil) {
        let serviceName = override ?? service
        delete(accountNames: storedAccountNames(service: serviceName), service: serviceName)
    }

    private static func storedAccountNames(service serviceName: String) -> [String] {
        var query = baseQuery(account: nil, service: serviceName)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecSuccess else {
            let items = result as? [[String: Any]] ?? []
            return items.compactMap { $0[kSecAttrAccount as String] as? String }
        }
        guard status != errSecItemNotFound else { return [] }
        logKeychainStatus("enumerate", account: "*", status: status)
        return []
    }

    private static func delete(accountNames: [String], service serviceName: String) {
        for account in accountNames where !account.isEmpty {
            let status = SecItemDelete(baseQuery(account: account, service: serviceName) as CFDictionary)
            guard status != errSecSuccess else { continue }
            guard status != errSecItemNotFound else { continue }
            logKeychainStatus("delete", account: account, status: status)
        }
    }

    private static func upsert(data: Data, account: String, service serviceName: String) {
        let query = baseQuery(account: account, service: serviceName)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard updateStatus != errSecSuccess else { return }
        guard updateStatus == errSecItemNotFound else {
            logKeychainStatus("update", account: account, status: updateStatus)
            return
        }
        var add = query
        attributes.forEach { add[$0.key] = $0.value }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus != errSecSuccess else { return }
        logKeychainStatus("add", account: account, status: addStatus)
    }

    private static func loadRaw(account: String, service serviceName: String) -> Data? {
        var query = baseQuery(account: account, service: serviceName)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecSuccess else { return item as? Data }
        guard status != errSecItemNotFound else { return nil }
        logKeychainStatus("load", account: account, status: status)
        return nil
    }

    private static func baseQuery(account: String?, service serviceName: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
        ]
        guard let account, !account.isEmpty else { return query }
        query[kSecAttrAccount as String] = account
        return query
    }

    private static func logKeychainError(_ operation: String, identity: String, error: Error) {
        OPNLog.warning(.auth, "GFNTokenStore \(operation) failed identity=\(identity) error=\(error.localizedDescription)")
    }

    private static func logKeychainStatus(_ operation: String, account: String, status: OSStatus) {
        OPNLog.warning(.auth, "GFNTokenStore \(operation) failed account=\(account) status=\(status)")
    }
}
