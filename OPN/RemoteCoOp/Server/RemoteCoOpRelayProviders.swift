//  Relay credentials from somewhere other than Cloudflare.
//
//  Cloudflare has the largest free allowance but the most setup: an account, a subscription with a
//  card on file, and an API token. Other providers ask for far less - ExpressTURN gives 1,000 GB a
//  month against a username and a password - and a self-hoster running coturn on a spare VPS wants
//  neither an account nor an API.
//
//  Rather than a client per vendor, this implements the two schemes they nearly all speak:
//
//  - **Static credentials.** A username and password that do not expire. ExpressTURN, Xirsys and
//    Metered all hand these out, and every TURN server understands them.
//  - **Shared secret**, the TURN REST API of RFC 5766 as coturn implements it under
//    `--use-auth-secret`. Credentials are derived locally with an HMAC and expire on their own, so
//    there is no API to call and no long-lived password to hand a guest.
//
//  The second is the better of the two wherever it is offered: a static password is one leaked invite
//  away from being someone else's relay, where a derived one is good for hours.
//

import CryptoKit
import Foundation

public enum OPNRemoteCoOpRelayProvider: String, CaseIterable, Codable, Sendable {
    case none
    case cloudflare
    case staticCredentials
    case sharedSecret

    /// Named for the provider a host is most likely to have heard of, rather than for the credential
    /// scheme underneath. "Username & Password" describes the mechanism accurately and tells nobody
    /// which option to pick; `summary` carries the breadth, because neither of the generic schemes is
    /// tied to the provider it is named after.
    public var label: String {
        switch self {
        case .none: "Off"
        case .cloudflare: "Cloudflare"
        case .staticCredentials: "ExpressTURN"
        case .sharedSecret: "coturn"
        }
    }

    public var summary: String {
        switch self {
        case .none:
            "No relay. Guests whose network blocks a direct connection will not connect."
        case .cloudflare:
            "1,000 GB a month, and this app creates the key for you. Needs a Cloudflare account with a card on file."
        case .staticCredentials:
            "ExpressTURN gives 1,000 GB a month for a username and password, with no card. Also covers Metered, Xirsys, Turnix, Twilio - any provider that hands you a username and password."
        case .sharedSecret:
            "For a coturn server you run yourself, and any provider offering a shared secret instead of a password. Credentials are derived here and expire on their own, so nothing long-lived reaches a guest."
        }
    }

    /// Shown under the picker whatever is selected, so a host running Metered or Xirsys can see their
    /// provider is covered without selecting an option named after someone else's.
    public static var pickerFootnote: String {
        "Named for the best-known provider of each kind. ExpressTURN also covers Metered, Xirsys, Turnix and Twilio; coturn also covers any provider that gives you a shared secret rather than a password."
    }
}

/// A username and password that do not expire, plus the URLs they authenticate against.
///
/// Fields are stored exactly as typed and normalised only when read. Normalising on the way in looks
/// harmless and is not: the settings rows commit on every keystroke, so a `turn:` filter applied
/// there rejects every prefix of a URL a host is halfway through typing, and the empty result is
/// written straight back into the field they are typing in.
public struct OPNRemoteCoOpStaticRelay: Equatable, Sendable {
    public let urlText: String
    public let rawUsername: String
    public let rawPassword: String

    public init(urlText: String, username: String, password: String) {
        self.urlText = urlText
        self.rawUsername = username
        self.rawPassword = password
    }

    public init(urls: [String], username: String, password: String) {
        self.init(urlText: urls.joined(separator: "\n"), username: username, password: password)
    }

    public var urls: [String] { OPNRemoteCoOpRelayURLs.parse(OPNRemoteCoOpRelayURLs.split(urlText)) }
    public var username: String { rawUsername.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var password: String { rawPassword.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var isUsable: Bool { !urls.isEmpty && !username.isEmpty && !password.isEmpty }

    public var iceServers: [OPNRemoteCoOpICEServer] {
        guard isUsable else { return [] }
        return [OPNRemoteCoOpICEServer(urls: urls, username: username, credential: password)]
    }
}

/// coturn's `--use-auth-secret` scheme: the username carries its own expiry and the password is an
/// HMAC of it, so the server validates without being told anything in advance.
public struct OPNRemoteCoOpSharedSecretRelay: Equatable, Sendable {
    /// Six hours, matching the Cloudflare path. Long enough that an invite left open does not die
    /// mid-session, short enough that a leaked one is not a standing grant.
    public static let defaultTTLSeconds = 21_600

    public let urlText: String
    public let rawSecret: String
    public let rawUsername: String

    public init(urlText: String, secret: String, username: String = "opennow") {
        self.urlText = urlText
        self.rawSecret = secret
        self.rawUsername = username
    }

    public init(urls: [String], secret: String, username: String = "opennow") {
        self.init(urlText: urls.joined(separator: "\n"), secret: secret, username: username)
    }

    public var urls: [String] { OPNRemoteCoOpRelayURLs.parse(OPNRemoteCoOpRelayURLs.split(urlText)) }
    public var secret: String { rawSecret.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var username: String {
        let trimmed = rawUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "opennow" : trimmed
    }

    public var isUsable: Bool { !urls.isEmpty && !secret.isEmpty }

    /// `username = <unix expiry>:<name>`, `credential = base64(HMAC-SHA1(secret, username))`.
    ///
    /// SHA-1 is not a choice: coturn specifies it, and it is a MAC rather than a digest here, so the
    /// collision attacks that retired SHA-1 for signatures do not apply.
    public func iceServers(now: Date = Date(), ttlSeconds: Int = defaultTTLSeconds) -> [OPNRemoteCoOpICEServer] {
        guard isUsable else { return [] }
        let expiry = Int(now.timeIntervalSince1970) + max(60, ttlSeconds)
        let user = "\(expiry):\(username)"
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(user.utf8), using: SymmetricKey(data: Data(secret.utf8)))
        return [OPNRemoteCoOpICEServer(urls: urls, username: user, credential: Data(mac).base64EncodedString())]
    }
}

enum OPNRemoteCoOpRelayURLs {
    /// Hosts paste these from a provider's dashboard, so they arrive newline-separated, comma
    /// separated, or with the surrounding quotes of a JavaScript snippet still attached.
    static func split(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == " " }).map(String.init)
    }

    private static let relaySchemes = ["turn:", "turns:", "stun:", "stuns:"]

    /// Keeps only what a peer connection can use, so a pasted `https://` line cannot make the whole
    /// entry invalid at negotiation time, and supplies a scheme when a host pasted a bare host:port.
    static func parse(_ urls: [String]) -> [String] {
        var seen = Set<String>()
        return urls
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"',")) }
            .flatMap(normalise)
            .filter { seen.insert($0).inserted }
    }

    /// Supplies a scheme for a bare `host:port`, and on the TLS ports supplies *both*.
    ///
    /// Port 443 usually means TLS, but not always: ExpressTURN's free tier serves plain TURN on 443
    /// and reserves `turns:` for paid plans, so guessing `turns:` there yields a URL that looks right
    /// and never allocates. Guessing `turn:` instead would give up TLS wherever it is available.
    ///
    /// The ambiguity is not resolvable from a hostname, so it is not guessed: both are offered and
    /// ICE keeps whichever allocates. The cost is one extra URL in the list.
    static func normalise(_ candidate: String) -> [String] {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if relaySchemes.contains(where: { trimmed.lowercased().hasPrefix($0) }) { return [trimmed] }
        // A pasted dashboard link, not a relay URL.
        guard !trimmed.contains("://") else { return [] }
        // Requires something host-shaped, so a half-typed letter is not counted as a recognised URL.
        guard trimmed.contains(".") else { return [] }

        switch port(of: trimmed) {
        case 443, 5349:
            return ["turns:\(trimmed)", "turn:\(trimmed)?transport=tcp"]
        case 80:
            // Never TLS, and TCP is the whole reason to be on 80.
            return ["turn:\(trimmed)?transport=tcp"]
        default:
            return ["turn:\(trimmed)"]
        }
    }

    private static func port(of hostPort: String) -> Int? {
        let withoutQuery = hostPort.split(separator: "?", maxSplits: 1).first.map(String.init) ?? hostPort
        guard let separator = withoutQuery.lastIndex(of: ":") else { return nil }
        return Int(withoutQuery[withoutQuery.index(after: separator)...])
    }
}
