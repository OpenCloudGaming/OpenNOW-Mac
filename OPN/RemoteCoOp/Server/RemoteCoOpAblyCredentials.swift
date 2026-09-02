//
//  RemoteCoOpAblyCredentials.swift
//  OpenNOW
//
//  Mints the credential a guest presents to the hosted signaling channel.
//
//  Signed here, on this machine, with no network call: an Ably JWT is HS256 over the key secret, so
//  the host's key never leaves the keychain and creating an invite gains no latency and no failure
//  mode. That is the opposite of the relay path, where credentials cost a round trip to Cloudflare.
//
//  The obvious alternative does not work and is recorded so nobody retries it. A signed
//  `TokenRequest` is also created offline, but Ably requires it to be exchanged within two minutes of
//  its timestamp and the nonce makes it single-use. Invites live an hour, get pasted into a chat and
//  opened later, and serve up to three guests, so a TokenRequest would be dead before most guests
//  clicked it and usable by only the first.
//

import CryptoKit
import Foundation

/// An Ably API key, in the `APP_ID.KEY_ID:KEY_SECRET` form the dashboard hands out.
///
/// Split rather than stored whole because the two halves play different roles: the name identifies
/// the key to Ably in the JWT header, and only the secret ever signs anything.
public struct OPNRemoteCoOpAblyKey: Equatable, Sendable {
    public let name: String
    public let secret: String

    public init(name: String, secret: String) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parses the pasted form. Returns nil rather than a half-populated key: a name without a secret
    /// signs nothing, and failing here is how the settings row knows to say so.
    public init?(pasted: String) {
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let name = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        // The name is `APP_ID.KEY_ID`; without the dot this is not an Ably key and signing it would
        // produce a JWT Ably rejects with an error the host cannot act on.
        guard !secret.isEmpty, name.contains("."), !name.hasPrefix("."), !name.hasSuffix(".") else { return nil }
        self.init(name: name, secret: secret)
    }

    public var isUsable: Bool { !name.isEmpty && !secret.isEmpty }

    /// Safe to show: identifies the key without revealing what signs with it.
    public var displayName: String { name }
}

public enum OPNRemoteCoOpAblyJWT {
    /// A JWT scoped to one channel, expiring with the invite.
    ///
    /// Multi-use by design: one invite admits up to three guests, and every one of them presents this
    /// same credential. Ably caps a token's capability at the issuing key's, so an over-broad user key
    /// still yields a correctly narrow JWT.
    /// The credential handed to guests inside the invite.
    ///
    /// Guests may publish **only** on the guest channel, and may only *read* the host channel. That
    /// asymmetry is the whole security boundary of this transport, and it has to be a capability
    /// rather than a client-side check: with one channel and channel-wide `publish`, any invite
    /// holder could publish under the message name `"host"` and every other guest would believe them
    /// - spoofing offers to hijack a guest's WebRTC session, or replacing their ICE servers to route
    /// that guest's media through an attacker. Ably enforces this server-side, so a malicious guest
    /// cannot opt out of it.
    ///
    /// Multi-use by design: one invite admits up to three guests and every one of them presents this
    /// same credential. Ably caps a token's capability at the issuing key's, so an over-broad user key
    /// still yields a correctly narrow JWT.
    ///
    /// Known residual: all guests share the guest channel's readership of the host channel, so a
    /// targeted host message is still *visible* to the other invite holders. Fixing that needs a
    /// channel per guest, which needs a token per guest - not available when the invite is minted,
    /// before anyone has joined. Nothing secret is targeted this way.
    public static func mintGuestToken(key: OPNRemoteCoOpAblyKey,
                                      channel: String,
                                      issuedAt: Date = Date(),
                                      expiresAt: Date) -> String? {
        capabilityToken(
            key: key,
            capability: #"{"\#(hostChannelName(base: channel))":["subscribe"],"\#(guestChannelName(base: channel))":["publish","presence"]}"#,
            channel: channel,
            issuedAt: issuedAt,
            expiresAt: expiresAt
        )
    }

    /// The host's own credential. Never leaves this machine, and is the mirror of the guest's: publish
    /// on the host channel, read and watch presence on the guest channel.
    public static func mintHostToken(key: OPNRemoteCoOpAblyKey,
                                     channel: String,
                                     issuedAt: Date = Date(),
                                     expiresAt: Date) -> String? {
        capabilityToken(
            key: key,
            capability: #"{"\#(hostChannelName(base: channel))":["publish"],"\#(guestChannelName(base: channel))":["subscribe","presence"]}"#,
            channel: channel,
            issuedAt: issuedAt,
            expiresAt: expiresAt
        )
    }

    private static func capabilityToken(key: OPNRemoteCoOpAblyKey,
                                        capability: String,
                                        channel: String,
                                        issuedAt: Date,
                                        expiresAt: Date) -> String? {
        guard key.isUsable, !channel.isEmpty, expiresAt > issuedAt else { return nil }
        let header: [String: Any] = ["alg": "HS256", "typ": "JWT", "kid": key.name]
        let claims: [String: Any] = [
            "iat": Int(issuedAt.timeIntervalSince1970),
            "exp": Int(expiresAt.timeIntervalSince1970),
            "x-ably-capability": capability,
            // Without this claim the token is anonymous, and Ably raises a clientId-mismatch error
            // the moment a client that declares one - which the browser guest does, setting its own
            // participant ID - tries to connect with it.
            //
            // The wildcard means `clientId` is an *assertion*, not an identity: one invite holder can
            // claim another's. So nothing downstream may treat it as authentication. The host binds a
            // participant only after `registerGuest` verifies the signed invite, and presence-leave is
            // corroborated rather than trusted on its own. A per-guest bound clientId is not available
            // here - the invite is minted before anyone has joined.
            "x-ably-clientId": "*",
        ]

        guard let headerData = try? JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]),
              let claimsData = try? JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys]) else { return nil }

        let signingInput = "\(base64URL(headerData)).\(base64URL(claimsData))"
        let signature = HMAC<SHA256>.authenticationCode(for: Data(signingInput.utf8), using: SymmetricKey(data: Data(key.secret.utf8)))
        return "\(signingInput).\(base64URL(Data(signature)))"
    }

    /// The base name one invite talks under. Both directions derive from it.
    ///
    /// Namespaced so a capability can never be written that reaches beyond Remote Co-Op, and keyed on
    /// the invite rather than the host: a new invite is a new channel, so an expired invite's
    /// credential has nothing left to address even if the JWT outlived it.
    public static func channelName(inviteID: UUID) -> String {
        "opennow-remote-coop:\(inviteID.uuidString.lowercased())"
    }

    /// Host publishes here, guests may only subscribe. Kept as separate functions rather than string
    /// interpolation at the call sites so the browser guest and this side cannot drift on the suffix -
    /// if they do, signaling silently goes nowhere.
    public static func hostChannelName(base: String) -> String { "\(base):host" }

    /// Guests publish and enter presence here; the host subscribes.
    public static func guestChannelName(base: String) -> String { "\(base):guest" }

    /// JWT base64url: no padding, URL-safe alphabet.
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The Ably key, kept in the keychain rather than in preferences.
///
/// It signs credentials that spend the host's Ably quota, so it is a secret in its own right: it must
/// not sit beside the display settings, and it must never enter a stream's launch metadata, which is
/// copied around and logged. Same rule as the relay credentials.
public enum OPNRemoteCoOpAblyKeyStore {
    private static let service = "OpenNOW.RemoteCoOp.Ably"
    private static let account = "ably-api-key"
    private static let nameDefaultsKey = "OpenNOW.RemoteCoOp.AblyKeyName"

    public static func load() -> OPNRemoteCoOpAblyKey {
        OPNRemoteCoOpAblyKey(
            name: OPNAppPreferenceStorage.standard.string(forKey: nameDefaultsKey) ?? "",
            secret: secret() ?? ""
        )
    }

    public static func save(_ key: OPNRemoteCoOpAblyKey) {
        OPNAppPreferenceStorage.standard.set(key.name, forKey: nameDefaultsKey)
        OPNAppPreferenceStorage.standard.synchronize()
        save(secret: key.secret)
    }

    private static func query() -> CFDictionary {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary
    }

    private static func secret() -> String? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ] as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func save(secret: String) {
        guard !secret.isEmpty else {
            SecItemDelete(query())
            return
        }
        let data = Data(secret.utf8)
        let update = SecItemUpdate(query(), [kSecValueData as String: data] as CFDictionary)
        guard update != errSecSuccess else { return }
        // Only "not found" justifies an add; anything else is a real keychain failure and adding on
        // top of it would mask the cause.
        guard update == errSecItemNotFound else {
            OpenNOWLog.error(.stream, "Remote Co-Op could not update the stored Ably key (\(update))")
            return
        }
        let addStatus = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ] as CFDictionary, nil)
        if addStatus != errSecSuccess {
            OpenNOWLog.error(.stream, "Remote Co-Op could not store the Ably key (\(addStatus))")
        }
    }
}
