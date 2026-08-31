//
//  RemoteCoOpInviteSecretStore.swift
//  OpenNOW
//
//  The HMAC secret invite tokens are signed with, shared with the signaling broker.
//
//  The broker verifies every invite signature server-side - it rejects both the host registration
//  and each guest join when the signature does not check out - and derives its key from
//  `OPENNOW_REMOTE_COOP_INVITE_SECRET`. Two separate things stopped the host from ever agreeing
//  with it, and either alone was enough to answer every join with "Invalid or expired invite
//  token" no matter how the rest of the session was configured:
//
//  - The host read that variable out of its own process environment, which a GUI app launched from
//    Finder never has, and fell back to a fresh random secret per launch. Nothing distributed a
//    secret to the app at all. The keychain item below is that missing channel.
//  - Even given the variable, the two sides derived different keys from it. See `key(for:)`.
//
//  The secret lives in the keychain rather than in preferences because it is a signing key: a
//  plist value would be readable by anything that can read the container, and anyone holding it
//  can mint invites for a session they were never given.
//

import Foundation
import Security

public enum OPNRemoteCoOpInviteSecretStore {
    private static let service = "OpenNOW.RemoteCoOp"
    private static let account = "invite-secret"

    /// The configured secret, byte for byte as the broker's environment variable holds it. Empty
    /// when none has been configured.
    public static func load() -> String {
        // The environment still wins, so a development host launched from a shell alongside
        // `run-servers.mjs` keeps working without touching the keychain.
        if let raw = ProcessInfo.processInfo.environment["OPENNOW_REMOTE_COOP_INVITE_SECRET"], !raw.isEmpty {
            return raw
        }
        guard let data = loadRaw(), let secret = String(data: data, encoding: .utf8) else { return "" }
        return secret
    }

    public static func save(_ secret: String) {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return delete() }
        guard let data = trimmed.data(using: .utf8) else { return }
        upsert(data: data)
    }

    public static func delete() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    /// The HMAC key for a configured secret, derived the way the broker derives it.
    ///
    /// The broker calls `createHmac("sha256", inviteSharedSecret)` with the environment variable's
    /// *string*, and Node keys a string with its UTF-8 bytes. The host used to base64url-decode the
    /// same string and key with the decoded bytes, so the two sides computed different digests from
    /// identical configuration and every signature check failed - the host's own registration
    /// included. `run-servers.mjs` generates the secret as `randomBytes(32).toString("base64url")`,
    /// which is exactly the shape that made the mismatch look like a correct setup.
    ///
    /// The bytes of the secret are the key; whether the operator's value happens to be base64 is
    /// not this side's business, and treating it as opaque is what keeps the two implementations
    /// agreeing for any string.
    public static func key(for secret: String) -> Data {
        Data(secret.utf8)
    }

    /// The signer the host session uses. Falls back to a random per-process secret when nothing is
    /// configured, which keeps a purely in-process session (no broker) working and keeps a
    /// misconfigured one from signing with a predictable key.
    public static func signer() -> OPNRemoteCoOpInviteTokenSigner {
        let secret = load()
        guard !secret.isEmpty else { return OPNRemoteCoOpInviteTokenSigner() }
        return OPNRemoteCoOpInviteTokenSigner(secret: key(for: secret))
    }

    /// Whether a secret is configured at all. Any non-empty string is usable as an HMAC key, so
    /// there is nothing further to validate here - the only failure mode left is the operator
    /// pasting a value that differs from the broker's, which no local check can see.
    public static func isConfigured() -> Bool {
        !load().isEmpty
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func upsert(data: Data) {
        let query = baseQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            OpenNOWLog.warning(.auth, "Remote Co-Op invite secret update failed status=\(updateStatus)")
            return
        }
        var add = query
        attributes.forEach { add[$0.key] = $0.value }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus != errSecSuccess {
            OpenNOWLog.warning(.auth, "Remote Co-Op invite secret add failed status=\(addStatus)")
        }
    }

    private static func loadRaw() -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                OpenNOWLog.warning(.auth, "Remote Co-Op invite secret load failed status=\(status)")
            }
            return nil
        }
        return item as? Data
    }
}
