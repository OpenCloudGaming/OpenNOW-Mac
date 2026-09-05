//  On-disk session storage: where the property lists live, how a session is written to and read
//  from one, and the legacy-token drain.
//

import AppKit
import CryptoKit
import Darwin
import Foundation

extension OPNAuthService {
    static func authUserDefaults() -> UserDefaults {
        if let suiteName = ProcessInfo.processInfo.environment["OPN_AUTH_USER_DEFAULTS_SUITE"], !suiteName.isEmpty {
            return UserDefaults(suiteName: suiteName) ?? .standard
        }
        return .standard
    }

    func applicationSupportBasePath() -> String? {
        if let overridePath = ProcessInfo.processInfo.environment["OPN_AUTH_APPLICATION_SUPPORT_DIR"], !overridePath.isEmpty {
            return overridePath
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path
    }

    func sessionStorageDirectory() -> String? {
        guard let basePath = applicationSupportBasePath(), !basePath.isEmpty else { return nil }
        let directory = (basePath as NSString).appendingPathComponent("OpenNOW")
        if !FileManager.default.fileExists(atPath: directory) {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        return directory
    }

    func legacySessionFilePath() -> String? {
        guard let basePath = applicationSupportBasePath(), !basePath.isEmpty else { return nil }
        return ((basePath as NSString).appendingPathComponent("com.nvidia.geforcenow") as NSString).appendingPathComponent("session.plist")
    }

    func sessionFilePath() -> String? {
        sessionStorageDirectory().map { ($0 as NSString).appendingPathComponent("session.plist") }
    }

    func accountsFilePath() -> String? {
        sessionStorageDirectory().map { ($0 as NSString).appendingPathComponent("accounts.plist") }
    }

    func sessionFilePathForRead() -> String? {
        if let path = sessionFilePath(), FileManager.default.fileExists(atPath: path) { return path }
        if let path = legacySessionFilePath(), FileManager.default.fileExists(atPath: path) { return path }
        return sessionFilePath()
    }

    func loadLegacySingleSession() -> OPNAuthSession {
        guard let path = sessionFilePathForRead(), let dictionary = loadPropertyListDictionary(path: path) else { return OPNAuthSession() }
        return session(from: dictionary)
    }

    func loadAccountDictionaries(activeUserId: UnsafeMutablePointer<String?>?) -> [NSDictionary] {
        let store = accountsFilePath().flatMap(loadPropertyListDictionary)
        let storedActiveUserId = store?["active_user_id"] as? String
        activeUserId?.pointee = storedActiveUserId
        let accounts = store?["accounts"] as? [NSDictionary] ?? []
        return drainLegacyTokens(from: accounts, activeUserId: storedActiveUserId)
    }

    func saveAccountDictionaries(_ accounts: [NSDictionary], activeUserId: String?) {
        guard let path = accountsFilePath() else { return }
        let store = NSMutableDictionary()
        store["accounts"] = accounts
        if let activeUserId, !activeUserId.isEmpty { store["active_user_id"] = activeUserId }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: store, format: .xml, options: 0) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    func loadPropertyListDictionary(path: String) -> NSDictionary? {
        guard FileManager.default.fileExists(atPath: path), let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? NSDictionary
    }

    /// The profile fields only. The access token is deliberately NOT a fallback here: the identity
    /// is written to UserDefaults, to `accounts.plist`, and to the keychain account name, so using
    /// a token would scatter a live credential across all three. It also rotates on every refresh,
    /// which orphaned a keychain item each time. `saveSession` mints a stable opaque id instead.
    func sessionIdentity(from session: OPNAuthSession) -> String? {
        [session.userId, session.email, session.displayName].first { !$0.isEmpty }
    }

    /// `identity` first: an account whose profile fields are all blank still round-trips, which the
    /// profile-only form could not do — the entry became unfindable and only the fallback path
    /// reached it.
    func sessionIdentity(from dictionary: NSDictionary) -> String? {
        ["identity", "user_id", "email", "display_name"].compactMap { dictionary[$0] as? String }.first { !$0.isEmpty }
    }

    static func newAnonymousIdentity() -> String {
        "anon." + UUID().uuidString
    }

    static let legacyTokenKeys = ["access_token", "id_token", "refresh_token", "client_token"]

    func dictionary(from session: OPNAuthSession, identity: String) -> NSDictionary {
        let dictionary = NSMutableDictionary()
        put(identity, key: "identity", into: dictionary)
        put(session.userId, key: "user_id", into: dictionary)
        put(session.displayName, key: "display_name", into: dictionary)
        put(session.email, key: "email", into: dictionary)
        put(session.membershipTier, key: "membership_tier", into: dictionary)
        put(session.idpId, key: "idp_id", into: dictionary)
        dictionary["expires_at"] = session.expiresAt
        dictionary["access_token_expiry"] = session.accessTokenExpiry
        dictionary["client_token_expiry"] = session.clientTokenExpiry
        dictionary["client_token_expiry_length"] = session.clientTokenExpiryLength
        dictionary["id_token_expiry"] = session.idTokenExpiry
        let tokens = GFNTokenStore.Tokens(
            accessToken: session.accessToken,
            idToken: session.idToken,
            refreshToken: session.refreshToken,
            clientToken: session.clientToken
        )
        GFNTokenStore.save(tokens, forIdentity: identity)
        return dictionary
    }

    /// Pre-keychain builds wrote the tokens straight into `accounts.plist`. Migrating them on read
    /// is not enough on its own: the file keeps its plaintext copy — including the long-lived
    /// refresh token — until something rewrites it, so strip them here, once.
    ///
    /// An entry is only stripped once the keychain is confirmed to hold its tokens. Stripping on a
    /// failed keychain write would sign the user out and lose the refresh token entirely.
    func drainLegacyTokens(from accounts: [NSDictionary], activeUserId: String?) -> [NSDictionary] {
        var didDrain = false
        let scrubbed: [NSDictionary] = accounts.map { account in
            guard Self.legacyTokenKeys.contains(where: { account[$0] != nil }) else { return account }
            guard let identity = sessionIdentity(from: account), !identity.isEmpty else { return account }
            if GFNTokenStore.load(forIdentity: identity) == nil {
                let tokens = GFNTokenStore.Tokens(
                    accessToken: account["access_token"] as? String ?? "",
                    idToken: account["id_token"] as? String ?? "",
                    refreshToken: account["refresh_token"] as? String ?? "",
                    clientToken: account["client_token"] as? String ?? ""
                )
                guard !tokens.isEmpty else { return account }
                GFNTokenStore.save(tokens, forIdentity: identity)
                guard GFNTokenStore.load(forIdentity: identity) != nil else { return account }
            }
            let copy = NSMutableDictionary(dictionary: account)
            Self.legacyTokenKeys.forEach { copy.removeObject(forKey: $0) }
            didDrain = true
            return copy
        }
        if didDrain { saveAccountDictionaries(scrubbed, activeUserId: activeUserId) }
        return scrubbed
    }

    /// The single-session plists predate `accounts.plist` and hold plaintext tokens of their own.
    /// Removed once the session they carried has been re-saved through the keychain path.
    func removeLegacySessionFiles() {
        [sessionFilePath(), legacySessionFilePath()].forEach { path in
            if let path { try? FileManager.default.removeItem(atPath: path) }
        }
    }

    func session(from dictionary: NSDictionary) -> OPNAuthSession {
        let identity = sessionIdentity(from: dictionary)
        let keychainTokens = identity.flatMap { GFNTokenStore.load(forIdentity: $0) }
        let accessToken = (keychainTokens?.accessToken ?? (dictionary["access_token"] as? String)) ?? ""
        guard !accessToken.isEmpty else { return OPNAuthSession() }
        var session = OPNAuthSession()
        session.accessToken = accessToken
        session.idToken = keychainTokens?.idToken ?? (dictionary["id_token"] as? String ?? "")
        session.refreshToken = keychainTokens?.refreshToken ?? (dictionary["refresh_token"] as? String ?? "")
        session.clientToken = keychainTokens?.clientToken ?? (dictionary["client_token"] as? String ?? "")
        session.userId = dictionary["user_id"] as? String ?? ""
        session.displayName = dictionary["display_name"] as? String ?? ""
        session.email = dictionary["email"] as? String ?? ""
        session.membershipTier = dictionary["membership_tier"] as? String ?? "Free"
        session.idpId = dictionary["idp_id"] as? String ?? Self.defaultIdpId
        session.expiresAt = JarvisSessionParser.int64Value(dictionary["expires_at"]) ?? 0
        session.accessTokenExpiry = JarvisSessionParser.int64Value(dictionary["access_token_expiry"]) ?? 0
        session.clientTokenExpiry = JarvisSessionParser.int64Value(dictionary["client_token_expiry"]) ?? 0
        session.clientTokenExpiryLength = JarvisSessionParser.int64Value(dictionary["client_token_expiry_length"]) ?? 0
        session.idTokenExpiry = JarvisSessionParser.int64Value(dictionary["id_token_expiry"]) ?? 0
        session.isAuthenticated = true
        if let identity, !identity.isEmpty, keychainTokens == nil,
           let legacyAccess = dictionary["access_token"] as? String, !legacyAccess.isEmpty {
            let tokens = GFNTokenStore.Tokens(
                accessToken: legacyAccess,
                idToken: dictionary["id_token"] as? String ?? "",
                refreshToken: dictionary["refresh_token"] as? String ?? "",
                clientToken: dictionary["client_token"] as? String ?? ""
            )
            GFNTokenStore.save(tokens, forIdentity: identity)
        }
        return session
    }

    static func opnSession(from session: StarfleetSession) -> OPNAuthSession {
        var mapped = OPNAuthSession()
        mapped.accessToken = session.accessToken
        mapped.idToken = session.idToken
        mapped.refreshToken = session.refreshToken
        mapped.clientToken = session.clientToken
        mapped.userId = session.userId
        mapped.displayName = session.displayName
        mapped.email = session.email
        mapped.idpId = session.idpId
        mapped.expiresAt = session.expiresAt
        mapped.isAuthenticated = session.isAuthenticated
        mapped.clientTokenExpiry = session.clientTokenExpiry
        mapped.clientTokenExpiryLength = session.clientTokenExpiryLength
        mapped.idTokenExpiry = session.idTokenExpiry
        mapped.accessTokenExpiry = session.accessTokenExpiry
        if !session.idToken.isEmpty {
            mapped.membershipTier = StarfleetTokenParser.jwtClaims(session.idToken)["membership_tier"] as? String ?? "Free"
        }
        return mapped
    }

    static func starfleetSession(from session: OPNAuthSession) -> StarfleetSession {
        StarfleetSession(
            accessToken: session.accessToken,
            idToken: session.idToken,
            refreshToken: session.refreshToken,
            userId: session.userId,
            displayName: session.displayName,
            email: session.email,
            idpId: session.idpId.isEmpty ? defaultIdpId : session.idpId,
            expiresAt: session.expiresAt,
            isAuthenticated: session.isAuthenticated,
            clientToken: session.clientToken,
            clientTokenExpiry: session.clientTokenExpiry,
            clientTokenExpiryLength: session.clientTokenExpiryLength,
            idTokenExpiry: session.idTokenExpiry,
            accessTokenExpiry: session.accessTokenExpiry
        )
    }

    func put(_ value: String, key: String, into dictionary: NSMutableDictionary) {
        if !value.isEmpty { dictionary[key] = value }
    }

    struct ServiceError: LocalizedError, Sendable {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
