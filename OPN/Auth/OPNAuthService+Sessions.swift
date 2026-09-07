//  Saved sessions and the account list they live in: which account is active, how one is added or
//  removed, and the stay-signed-in preference.
//

import AppKit
import CryptoKit
import Darwin
import Foundation

extension OPNAuthService {
    func saveUserInfo(_ userInfo: JarvisUserInfo) {
        guard userInfo.isAuthenticated else {
            clearUserInfo()
            return
        }
        var session = loadSavedSession()
        guard session.isAuthenticated else { return }
        let oldIdentity = sessionIdentity(from: session)
        if !userInfo.userId.isEmpty { session.userId = userInfo.userId }
        if !userInfo.displayName.isEmpty { session.displayName = userInfo.displayName }
        else if !userInfo.preferredUsername.isEmpty { session.displayName = userInfo.preferredUsername }
        if !userInfo.email.isEmpty { session.email = userInfo.email }
        if !userInfo.idpId.isEmpty { session.idpId = userInfo.idpId }
        saveSession(session, replacingIdentity: oldIdentity)
    }

    func clearUserInfo() {
        var session = loadSavedSession()
        guard session.isAuthenticated else { return }
        let oldIdentity = sessionIdentity(from: session)
        session.userId = ""
        session.displayName = ""
        session.email = ""
        session.idpId = Self.defaultIdpId
        saveSession(session, replacingIdentity: oldIdentity)
    }

    func loadSavedSession() -> OPNAuthSession {
        let defaults = Self.authUserDefaults()
        var activeUserId: String?
        let accounts = loadAccountDictionaries(activeUserId: &activeUserId)
        let preferredUserId = defaults.string(forKey: "OPN_ActiveUserId") ?? activeUserId
        var fallback: NSDictionary?

        for account in accounts {
            if fallback == nil { fallback = account }
            let identity = sessionIdentity(from: account)
            if preferredUserId?.isEmpty == false, identity == preferredUserId {
                let session = session(from: account)
                if session.isAuthenticated { return session }
            }
        }

        if let fallback {
            let session = session(from: fallback)
            if let identity = sessionIdentity(from: fallback), !identity.isEmpty {
                defaults.set(identity, forKey: "OPN_ActiveUserId")
            }
            defaults.set(true, forKey: "OPN_HasSavedSession")
            return session
        }

        if !defaults.bool(forKey: "OPN_HasSavedSession") && !defaults.bool(forKey: "GFN_HasSavedSession") {
            return OPNAuthSession()
        }
        let legacy = loadLegacySingleSession()
        if legacy.isAuthenticated {
            saveSession(legacy)
            // The session now lives in accounts.plist with its tokens in the keychain, so the
            // legacy files are a second, plaintext copy of the same refresh token. Drop them.
            removeLegacySessionFiles()
        }
        return legacy
    }

    func loadSavedSessions() -> [OPNAuthSession] {
        var sessions = loadAccountDictionaries(activeUserId: nil).map(session).filter(\.isAuthenticated)
        if sessions.isEmpty {
            let legacy = loadLegacySingleSession()
            if legacy.isAuthenticated { sessions.append(legacy) }
        }
        return sessions
    }

    func loadSavedSession(forUserId userId: String) -> OPNAuthSession {
        guard !userId.isEmpty else { return OPNAuthSession() }
        for account in loadAccountDictionaries(activeUserId: nil) {
            if sessionIdentity(from: account) == userId {
                return session(from: account)
            }
        }
        return OPNAuthSession()
    }

    func setActiveSessionUserId(_ userId: String) {
        guard !userId.isEmpty else { return }
        var activeUserId: String?
        let accounts = loadAccountDictionaries(activeUserId: &activeUserId)
        guard accounts.contains(where: { sessionIdentity(from: $0) == userId }) else { return }
        saveAccountDictionaries(accounts, activeUserId: userId)
        let defaults = Self.authUserDefaults()
        defaults.set(userId, forKey: "OPN_ActiveUserId")
        defaults.set(true, forKey: "OPN_HasSavedSession")
    }

    func removeSavedSession(userId: String) {
        removeStoredAccounts(matchingProfileFields: [userId])
    }

    /// Ends the credential this service holds for one account, together with the keychain tokens
    /// behind it.
    ///
    /// Sign-in stores every session twice: here, keyed by the profile identity, and in SwiftData,
    /// keyed by the session id. `LoginSession.purgeTokens()` only reaches the second copy, so
    /// without this a signed-out or forgotten account keeps a complete, refreshable credential in
    /// `accounts.plist` and the keychain — the refresh token outliving the access token by far.
    func endSavedSession(userId: String, email: String) {
        guard removeStoredAccounts(matchingProfileFields: [userId, email]) else { return }
        Task { [jarvisAuthService, starfleetService] in
            await jarvisAuthService.clearSession()
            await starfleetService.clearSession()
        }
    }

    /// Drops every stored account whose profile matches `fields`, deletes the keychain tokens
    /// behind them, and re-points the active id at whatever is left. Returns whether the credential
    /// the store considered active was among the ones removed.
    ///
    /// Matching covers the identity plus the two fields that are unique per account. Display name
    /// is deliberately left out: it is not unique, and matching on it could end the session of an
    /// unrelated account that happens to share one.
    @discardableResult
    private func removeStoredAccounts(matchingProfileFields fields: [String]) -> Bool {
        let keys = Set(fields.filter { !$0.isEmpty })
        guard !keys.isEmpty else { return false }
        var activeUserId: String?
        let existing = loadAccountDictionaries(activeUserId: &activeUserId)
        func belongsToAccount(_ account: NSDictionary) -> Bool {
            if let identity = self.sessionIdentity(from: account), keys.contains(identity) { return true }
            return ["user_id", "email"].compactMap { account[$0] as? String }.contains { keys.contains($0) }
        }
        let removedIdentities: [String] = existing.filter(belongsToAccount).compactMap { sessionIdentity(from: $0) }
        guard !removedIdentities.isEmpty else { return false }
        removedIdentities.forEach(GFNTokenStore.delete(forIdentity:))
        let accounts = existing.filter { !belongsToAccount($0) }
        let identities: [String] = accounts.compactMap { sessionIdentity(from: $0) }
        let newActive: String? = if let activeUserId, identities.contains(activeUserId) {
            activeUserId
        } else {
            identities.first
        }
        saveAccountDictionaries(accounts, activeUserId: newActive)
        let defaults = Self.authUserDefaults()
        if let newActive, !newActive.isEmpty {
            defaults.set(newActive, forKey: "OPN_ActiveUserId")
            defaults.set(true, forKey: "OPN_HasSavedSession")
        } else {
            defaults.removeObject(forKey: "OPN_ActiveUserId")
            defaults.removeObject(forKey: "OPN_HasSavedSession")
        }
        guard let activeUserId else { return false }
        return removedIdentities.contains(activeUserId)
    }

    func clearSession() {
        let defaults = Self.authUserDefaults()
        // Only take the per-account path when the stored id still names a real account. Builds
        // before the identity change could leave an access token here, which matches nothing — and
        // signing out would then clear neither the account nor its tokens.
        if let activeUserId = defaults.string(forKey: "OPN_ActiveUserId"), !activeUserId.isEmpty,
           loadAccountDictionaries(activeUserId: nil).contains(where: { sessionIdentity(from: $0) == activeUserId }) {
            removeSavedSession(userId: activeUserId)
            Task { [jarvisAuthService, starfleetService] in
                await jarvisAuthService.clearSession()
                await starfleetService.clearSession()
            }
            return
        }
        GFNTokenStore.deleteAll()
        [accountsFilePath(), sessionFilePath(), legacySessionFilePath()].forEach { path in
            if let path { try? FileManager.default.removeItem(atPath: path) }
        }
        defaults.removeObject(forKey: "OPN_HasSavedSession")
        defaults.removeObject(forKey: "GFN_HasSavedSession")
        defaults.removeObject(forKey: "OPN_ActiveUserId")
        Task { [jarvisAuthService, starfleetService] in
            await jarvisAuthService.clearSession()
            await starfleetService.clearSession()
        }
    }

    func getStayLoggedIn() -> Bool {
        let defaults = Self.authUserDefaults()
        if defaults.object(forKey: "OPN_StayLoggedIn") != nil { return defaults.bool(forKey: "OPN_StayLoggedIn") }
        if defaults.object(forKey: "GFN_StayLoggedIn") != nil { return defaults.bool(forKey: "GFN_StayLoggedIn") }
        return true
    }

    func setStayLoggedIn(_ value: Bool) {
        let defaults = Self.authUserDefaults()
        defaults.set(value, forKey: "OPN_StayLoggedIn")
    }

    static func parseOAuthSession(json: NSDictionary) -> OPNAuthSession {
        opnSession(from: StarfleetSessionParser.parseTokenResponse(json as? [String: Any] ?? [:], defaultIdpId: defaultIdpId))
    }

    static func parseQueryString(_ query: String?) -> NSDictionary {
        let params = NSMutableDictionary()
        for (key, value) in JarvisSessionParser.parseQueryString(query) {
            params[key] = value
        }
        return params
    }
}
