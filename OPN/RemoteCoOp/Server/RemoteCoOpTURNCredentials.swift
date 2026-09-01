//
//  RemoteCoOpTURNCredentials.swift
//  OpenNOW
//
//  Mints short-lived Cloudflare Realtime TURN credentials so a guest whose network refuses a direct
//  connection can still play.
//
//  Direct-only hosting assumes the guest can reach the host, which is exactly what fails on the
//  networks people are most often on when they are not at home - schools, libraries, cafes - where
//  UDP is filtered and no port can be opened. STUN does not help there: it discovers an address that
//  nothing can route to. A relay is the only thing that does, and the relevant URL is
//  `turns:turn.cloudflare.com:443?transport=tcp`, which looks like ordinary HTTPS on the wire.
//
//  Two credentials, not one, and they are not interchangeable:
//
//  - A **TURN key** (`uid` + bearer `key`) authenticates minting at `rtc.live.cloudflare.com`. It is
//    not a Cloudflare API token and does not work anywhere else.
//  - A **Cloudflare API token** authenticates `api.cloudflare.com`, which is where the TURN key is
//    created and where usage is read.
//
//  Conflating them fails silently in one direction: minting with the API token is rejected outright,
//  but a usage query sent with the TURN key returns a 403 that reads like a missing permission.
//
//  The host pastes the API token once and `OPNRemoteCoOpTURNProvisioner` derives the rest. Neither
//  secret leaves this machine - guests receive only the minted credentials, which expire on their own.
//

import Foundation

/// Long-lived minting credential. Cloudflare shows the bearer `key` once, at creation, and never
/// again - it cannot be recovered by listing keys, so a lost one means provisioning a new key.
public struct OPNRemoteCoOpTURNKey: Equatable, Sendable {
    public let keyID: String
    public let keyToken: String

    public init(keyID: String, keyToken: String) {
        self.keyID = keyID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.keyToken = keyToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isUsable: Bool { !keyID.isEmpty && !keyToken.isEmpty }
}

/// Cloudflare account credentials, for `api.cloudflare.com` only.
public struct OPNRemoteCoOpCloudflareAccount: Equatable, Sendable {
    public let accountID: String
    public let apiToken: String

    public init(accountID: String, apiToken: String) {
        self.accountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var hasToken: Bool { !apiToken.isEmpty }
    public var canReportUsage: Bool { hasToken && !accountID.isEmpty }
}

public struct OPNRemoteCoOpRelayCredentials: Equatable, Sendable {
    public var provider: OPNRemoteCoOpRelayProvider
    public var turnKey: OPNRemoteCoOpTURNKey
    public var account: OPNRemoteCoOpCloudflareAccount
    public var staticRelay: OPNRemoteCoOpStaticRelay
    public var sharedSecretRelay: OPNRemoteCoOpSharedSecretRelay

    public init(provider: OPNRemoteCoOpRelayProvider = .cloudflare,
                turnKey: OPNRemoteCoOpTURNKey,
                account: OPNRemoteCoOpCloudflareAccount,
                staticRelay: OPNRemoteCoOpStaticRelay = OPNRemoteCoOpStaticRelay(urls: [], username: "", password: ""),
                sharedSecretRelay: OPNRemoteCoOpSharedSecretRelay = OPNRemoteCoOpSharedSecretRelay(urls: [], secret: "")) {
        self.provider = provider
        self.turnKey = turnKey
        self.account = account
        self.staticRelay = staticRelay
        self.sharedSecretRelay = sharedSecretRelay
    }

    public var canRelay: Bool {
        switch provider {
        case .none: false
        case .cloudflare: turnKey.isUsable
        case .staticCredentials: staticRelay.isUsable
        case .sharedSecret: sharedSecretRelay.isUsable
        }
    }

    /// Only Cloudflare reports usage. The others either have no API to ask, or are a server the host
    /// runs themselves and can measure directly.
    public var canReportUsage: Bool { provider == .cloudflare && turnKey.isUsable && account.canReportUsage }

    /// Credentials for one invite.
    ///
    /// Cloudflare is the only provider that needs a round trip; the other two are computed here, which
    /// is why this returns rather than throws - a relay that cannot be built leaves the session
    /// direct-only, exactly where it was before.
    public func iceServers(now: Date = Date()) async -> [OPNRemoteCoOpICEServer] {
        switch provider {
        case .none:
            return []
        case .cloudflare:
            guard turnKey.isUsable else { return [] }
            return (try? await OPNRemoteCoOpTURNCredentials.iceServers(for: turnKey)) ?? []
        case .staticCredentials:
            return staticRelay.iceServers
        case .sharedSecret:
            return sharedSecretRelay.iceServers(now: now)
        }
    }
}

/// Relay bandwidth used this calendar month, against Cloudflare's free allowance.
public struct OPNRemoteCoOpTURNUsage: Equatable, Sendable {
    /// Cloudflare's free tier, shared between SFU and TURN rather than one allowance each.
    ///
    /// Monthly and recurring: the pricing docs never say so, but the Realtime subscribe page states
    /// "1,000GB / month free" against "a monthly usage-based model". Overage bills automatically at
    /// $0.05/GB with no warning at the threshold, which is what the usage readout is for.
    public static let freeTierBytes: Int64 = 1_000 * 1_000_000_000

    public let egressBytes: Int64

    public init(egressBytes: Int64) {
        self.egressBytes = egressBytes
    }

    public var usedGigabytes: Double { Double(egressBytes) / 1_000_000_000 }
    public var remainingGigabytes: Double { max(0, Double(Self.freeTierBytes - egressBytes) / 1_000_000_000) }
    public var fractionUsed: Double { min(1, max(0, Double(egressBytes) / Double(Self.freeTierBytes))) }

    /// Says "this month" rather than "this billing period": the query is calendar month-to-date, which
    /// is not necessarily where Cloudflare's billing cycle starts, and the free allowance is shared
    /// with the SFU, so this is a floor on usage rather than the whole picture.
    public var summary: String {
        String(format: "%.1f of %.0f GB used this month", usedGigabytes, Double(Self.freeTierBytes) / 1_000_000_000)
    }

    /// Roughly how much play the remaining allowance buys, at a preset's low-latency bitrate. Only a
    /// relayed guest consumes it, so this is a worst case where every guest is relayed.
    public func remainingHours(atPreset preset: OPNRemoteCoOpQualityPreset) -> Double {
        let bitsPerSecond = Double(preset.videoMaxBitrateBps(for: .lowLatency))
        guard bitsPerSecond > 0 else { return 0 }
        return remainingGigabytes * 8_000_000_000 / bitsPerSecond / 3_600
    }
}

public enum OPNRemoteCoOpTURNError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case requestFailed(String)
    case rejected(status: Int)
    /// Cloudflare's own message, which names the missing permission far better than a status code.
    case cloudflare(String)
    case noAccounts
    case ambiguousAccount([String])

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "No Cloudflare TURN key is configured."
        case .requestFailed(let message): "Could not reach Cloudflare: \(message)"
        case .rejected(let status): "Cloudflare refused the request (HTTP \(status))."
        case .cloudflare(let message): message
        case .noAccounts:
            "That token cannot list accounts. Add the Account Settings (Read) permission to it, or paste your account ID below - it is the hex string in your dashboard URL, dash.cloudflare.com/<account id>."
        case .ambiguousAccount(let names):
            "That token can see \(names.count) accounts (\(names.joined(separator: ", "))). Paste the account ID you want to use."
        }
    }
}

// MARK: - Minting

public enum OPNRemoteCoOpTURNCredentials {
    static let endpoint = "https://rtc.live.cloudflare.com/v1/turn/keys"
    /// Cloudflare caps a credential at 48 hours. An invite lasts an hour by default, and the margin
    /// covers a host who leaves one open rather than forcing a mid-session refresh.
    public static let credentialTTLSeconds = 21_600

    private struct Response: Decodable {
        struct Server: Decodable {
            let urls: URLList
            let username: String?
            let credential: String?
        }

        /// Confirmed live against Cloudflare's real endpoint: `iceServers` is an array of two entries,
        /// a STUN-only one with no credential and a TURN one with both - not the single object every
        /// existing fixture here assumed. Accepting both shapes rather than replacing one with the
        /// other, since nothing here proves the object shape can never come back.
        let iceServers: [Server]

        private enum CodingKeys: String, CodingKey { case iceServers }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let array = try? container.decode([Server].self, forKey: .iceServers) {
                iceServers = array
            } else {
                iceServers = [try container.decode(Server.self, forKey: .iceServers)]
            }
        }
    }

    /// `urls` is a string on some responses and an array on others.
    struct URLList: Decodable {
        let values: [String]

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let single = try? container.decode(String.self) {
                values = [single]
                return
            }
            values = (try? container.decode([String].self)) ?? []
        }
    }

    public static func iceServers(for key: OPNRemoteCoOpTURNKey,
                                  ttlSeconds: Int = credentialTTLSeconds,
                                  session: URLSession = .shared) async throws -> [OPNRemoteCoOpICEServer] {
        guard key.isUsable else { throw OPNRemoteCoOpTURNError.notConfigured }
        guard let url = URL(string: "\(endpoint)/\(key.keyID)/credentials/generate-ice-servers") else {
            throw OPNRemoteCoOpTURNError.notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key.keyToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["ttl": ttlSeconds])
        // An invite is blocked on this call, so it fails fast rather than hanging the button.
        request.timeoutInterval = 10

        let (data, status) = try await OPNCloudflareRequest.send(request, session: session)
        guard (200...299).contains(status) else { throw OPNRemoteCoOpTURNError.rejected(status: status) }
        return parse(data)
    }

    /// One `OPNRemoteCoOpICEServer` per entry Cloudflare returns, dropping URL schemes the guest
    /// cannot use and any entry left with none. A malformed reply yields an empty list rather than
    /// throwing: losing the relay degrades a session to direct-only, and failing the whole invite over
    /// it would be worse.
    static func parse(_ data: Data) -> [OPNRemoteCoOpICEServer] {
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        return decoded.iceServers.compactMap { server -> OPNRemoteCoOpICEServer? in
            let urls = server.urls.values.filter { $0.hasPrefix("turn:") || $0.hasPrefix("turns:") || $0.hasPrefix("stun:") }
            guard !urls.isEmpty else { return nil }
            return OPNRemoteCoOpICEServer(urls: urls, username: server.username, credential: server.credential)
        }
    }
}

// MARK: - Provisioning

enum OPNCloudflareRequest {
    static func send(_ request: URLRequest, session: URLSession) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw OPNRemoteCoOpTURNError.requestFailed(error.localizedDescription)
        }
    }

    /// Cloudflare reports failures in the body, sometimes alongside a 200. Its message names the
    /// missing permission, so surfacing it beats reporting the status code.
    static func firstErrorMessage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let errors = object["errors"] as? [[String: Any]] {
            let messages = errors.compactMap { $0["message"] as? String }.filter { !$0.isEmpty }
            if !messages.isEmpty { return messages.joined(separator: " ") }
        }
        return nil
    }
}

/// Turns one pasted Cloudflare API token into everything the relay needs.
///
/// Asking a user for a key ID, a TURN key token and an account ID means three trips through a
/// dashboard, and two of the three are derivable. This does the derivation: it finds the account the
/// token can see and creates a TURN key on it.
public enum OPNRemoteCoOpTURNProvisioner {
    static let apiBase = "https://api.cloudflare.com/client/v4"
    static let keyName = "OpenNOW Remote Co-Op"

    private struct AccountsResponse: Decodable {
        struct Account: Decodable {
            let id: String
            let name: String?
        }
        let result: [Account]?
    }

    private struct CreateKeyResponse: Decodable {
        struct Result: Decodable {
            let uid: String
            let key: String
        }
        let result: Result?
    }

    /// A TURN key is created only when there is not already a usable one, because Cloudflare returns a
    /// key's bearer token once and listing keys cannot recover it - re-running setup would otherwise
    /// leave a new orphaned key on the account every time.
    public static func provision(apiToken: String,
                                 accountID: String = "",
                                 existingKey: OPNRemoteCoOpTURNKey = OPNRemoteCoOpTURNKey(keyID: "", keyToken: ""),
                                 session: URLSession = .shared) async throws -> OPNRemoteCoOpRelayCredentials {
        let token = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw OPNRemoteCoOpTURNError.notConfigured }

        let resolvedAccount = try await resolveAccountID(apiToken: token, preset: accountID, session: session)
        let account = OPNRemoteCoOpCloudflareAccount(accountID: resolvedAccount, apiToken: token)
        if existingKey.isUsable {
            return OPNRemoteCoOpRelayCredentials(turnKey: existingKey, account: account)
        }
        let key = try await createTURNKey(account: account, session: session)
        return OPNRemoteCoOpRelayCredentials(turnKey: key, account: account)
    }

    /// A pasted account ID wins, and is usually what happens.
    ///
    /// `GET /accounts` is user-scoped: a token without Account Settings (Read) gets HTTP 200 and an
    /// empty list rather than an error, so the failure has to name that permission and the dashboard
    /// URL instead of reading as a bad token.
    static func resolveAccountID(apiToken: String, preset: String, session: URLSession) async throws -> String {
        let trimmed = preset.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        guard let url = URL(string: "\(apiBase)/accounts") else { throw OPNRemoteCoOpTURNError.notConfigured }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (data, status) = try await OPNCloudflareRequest.send(request, session: session)
        // 401 means the token itself is wrong, which no amount of pasting an account ID fixes. Any
        // other refusal is just scope, and reads the same as the empty list a scoped token gets.
        if status == 401 {
            throw OPNRemoteCoOpTURNError.cloudflare("Cloudflare rejected the API token while listing accounts: "
                + (OPNCloudflareRequest.firstErrorMessage(data) ?? "HTTP 401")
                + ". Check the token is active and that its Account Resources include the account you want.")
        }
        guard (200...299).contains(status) else { throw OPNRemoteCoOpTURNError.noAccounts }
        let accounts = (try? JSONDecoder().decode(AccountsResponse.self, from: data))?.result ?? []
        switch accounts.count {
        case 0: throw OPNRemoteCoOpTURNError.noAccounts
        case 1: return accounts[0].id
        default: throw OPNRemoteCoOpTURNError.ambiguousAccount(accounts.map { $0.name ?? $0.id })
        }
    }

    static func createTURNKey(account: OPNRemoteCoOpCloudflareAccount, session: URLSession) async throws -> OPNRemoteCoOpTURNKey {
        guard let url = URL(string: "\(apiBase)/accounts/\(account.accountID)/calls/turn_keys") else {
            throw OPNRemoteCoOpTURNError.notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(account.apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": keyName])
        request.timeoutInterval = 15

        let (data, status) = try await OPNCloudflareRequest.send(request, session: session)
        guard (200...299).contains(status) else {
            throw OPNRemoteCoOpTURNError.cloudflare("Cloudflare would not create a TURN key: "
                + (OPNCloudflareRequest.firstErrorMessage(data) ?? "HTTP \(status)")
                + ". The token needs Cloudflare Calls (Edit), listed as Cloudflare Realtime on newer accounts, and its Account Resources must include this account.")
        }
        guard let result = (try? JSONDecoder().decode(CreateKeyResponse.self, from: data))?.result else {
            throw OPNRemoteCoOpTURNError.cloudflare("Cloudflare returned no TURN key: "
                + (OPNCloudflareRequest.firstErrorMessage(data) ?? "unrecognised reply")
                + ".")
        }
        return OPNRemoteCoOpTURNKey(keyID: result.uid, keyToken: result.key)
    }
}

// MARK: - Usage

public enum OPNRemoteCoOpTURNUsageReporter {
    static let endpoint = "https://api.cloudflare.com/client/v4/graphql"

    private struct Response: Decodable {
        struct Group: Decodable {
            struct Sum: Decodable { let egressBytes: Int64 }
            let sum: Sum
        }
        struct Account: Decodable { let callsTurnUsageAdaptiveGroups: [Group] }
        struct Viewer: Decodable { let accounts: [Account] }
        struct Data: Decodable { let viewer: Viewer? }
        let data: Data?
    }

    /// Month-to-date relay egress for one TURN key.
    ///
    /// Authenticated with the account's API token, not the TURN key's - the latter is rejected here.
    /// Needs the "Account Analytics" permission on top of Calls, which is a separate checkbox when the
    /// token is created, hence the distinct message rather than reporting zero usage.
    public static func monthToDateEgress(for account: OPNRemoteCoOpCloudflareAccount,
                                         keyID: String,
                                         now: Date = Date(),
                                         calendar: Calendar = Calendar(identifier: .gregorian),
                                         session: URLSession = .shared) async throws -> OPNRemoteCoOpTURNUsage {
        guard account.canReportUsage, !keyID.isEmpty else { throw OPNRemoteCoOpTURNError.notConfigured }
        guard let url = URL(string: endpoint) else { throw OPNRemoteCoOpTURNError.notConfigured }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(account.apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": graphQLQuery,
            "variables": [
                "accountId": account.accountID,
                "dateFrom": formatter.string(from: startOfMonth),
                "dateTo": formatter.string(from: now),
                "keyId": keyID,
            ],
        ])

        let (data, status) = try await OPNCloudflareRequest.send(request, session: session)
        guard (200...299).contains(status) else { throw OPNRemoteCoOpTURNError.rejected(status: status) }
        // GraphQL reports a missing permission in a 200 body, so the body decides, not the status.
        if let message = OPNCloudflareRequest.firstErrorMessage(data) {
            throw OPNRemoteCoOpTURNError.cloudflare("Cloudflare refused the usage query: \(message)")
        }
        return OPNRemoteCoOpTURNUsage(egressBytes: totalEgressBytes(data))
    }

    static func totalEgressBytes(_ data: Data) -> Int64 {
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let accounts = decoded.data?.viewer?.accounts else { return 0 }
        return accounts.flatMap(\.callsTurnUsageAdaptiveGroups).reduce(0) { $0 + $1.sum.egressBytes }
    }

    static let graphQLQuery = """
    query OpenNOWTurnEgress($accountId: String!, $dateFrom: Date!, $dateTo: Date!, $keyId: String!) {
      viewer {
        accounts(filter: { accountTag: $accountId }) {
          callsTurnUsageAdaptiveGroups(
            filter: { date_geq: $dateFrom, date_leq: $dateTo, keyId: $keyId }
            limit: 100
          ) {
            sum { egressBytes }
          }
        }
      }
    }
    """
}

// MARK: - Storage

/// Both secrets live in the keychain rather than in preferences.
///
/// The API token can create billable resources on the host's account and the TURN key token mints
/// bandwidth billed to it, so neither belongs beside the display settings, and neither may enter a
/// stream's launch metadata, which is copied around and logged.
public enum OPNRemoteCoOpTURNKeyStore {
    private static let service = "OpenNOW.RemoteCoOp.TURN"
    private static let turnKeyAccount = "turn-key-token"
    private static let apiTokenAccount = "cloudflare-api-token"
    private static let staticPasswordAccount = "static-relay-password"
    private static let sharedSecretAccount = "shared-relay-secret"
    private static let keyIDDefaultsKey = "OpenNOW.RemoteCoOp.TURNKeyID"
    private static let accountIDDefaultsKey = "OpenNOW.RemoteCoOp.TURNAccountID"
    private static let providerDefaultsKey = "OpenNOW.RemoteCoOp.RelayProvider"
    private static let staticURLsDefaultsKey = "OpenNOW.RemoteCoOp.StaticRelayURLs"
    private static let staticUsernameDefaultsKey = "OpenNOW.RemoteCoOp.StaticRelayUsername"
    private static let secretURLsDefaultsKey = "OpenNOW.RemoteCoOp.SecretRelayURLs"
    private static let secretUsernameDefaultsKey = "OpenNOW.RemoteCoOp.SecretRelayUsername"

    public static func load() -> OPNRemoteCoOpRelayCredentials {
        let defaults = OPNAppPreferenceStorage.standard
        return OPNRemoteCoOpRelayCredentials(
            provider: OPNRemoteCoOpRelayProvider(rawValue: defaults.string(forKey: providerDefaultsKey) ?? "") ?? .cloudflare,
            turnKey: OPNRemoteCoOpTURNKey(
                keyID: defaults.string(forKey: keyIDDefaultsKey) ?? "",
                keyToken: token(for: turnKeyAccount) ?? ""
            ),
            account: OPNRemoteCoOpCloudflareAccount(
                accountID: defaults.string(forKey: accountIDDefaultsKey) ?? "",
                apiToken: token(for: apiTokenAccount) ?? ""
            ),
            staticRelay: OPNRemoteCoOpStaticRelay(
                urlText: defaults.string(forKey: staticURLsDefaultsKey) ?? "",
                username: defaults.string(forKey: staticUsernameDefaultsKey) ?? "",
                password: token(for: staticPasswordAccount) ?? ""
            ),
            sharedSecretRelay: OPNRemoteCoOpSharedSecretRelay(
                urlText: defaults.string(forKey: secretURLsDefaultsKey) ?? "",
                secret: token(for: sharedSecretAccount) ?? "",
                username: defaults.string(forKey: secretUsernameDefaultsKey) ?? ""
            )
        )
    }

    public static func save(_ credentials: OPNRemoteCoOpRelayCredentials) {
        let defaults = OPNAppPreferenceStorage.standard
        defaults.set(credentials.provider.rawValue, forKey: providerDefaultsKey)
        defaults.set(credentials.turnKey.keyID, forKey: keyIDDefaultsKey)
        defaults.set(credentials.account.accountID, forKey: accountIDDefaultsKey)
        // Raw text, so a half-typed URL survives the round trip back into the field.
        defaults.set(credentials.staticRelay.urlText, forKey: staticURLsDefaultsKey)
        defaults.set(credentials.staticRelay.rawUsername, forKey: staticUsernameDefaultsKey)
        defaults.set(credentials.sharedSecretRelay.urlText, forKey: secretURLsDefaultsKey)
        defaults.set(credentials.sharedSecretRelay.rawUsername, forKey: secretUsernameDefaultsKey)
        defaults.synchronize()
        save(token: credentials.turnKey.keyToken, for: turnKeyAccount)
        save(token: credentials.account.apiToken, for: apiTokenAccount)
        // A static password is as good as a standing grant on the host's relay, and the shared secret
        // mints credentials outright, so both belong in the keychain beside the Cloudflare tokens.
        save(token: credentials.staticRelay.password, for: staticPasswordAccount)
        save(token: credentials.sharedSecretRelay.secret, for: sharedSecretAccount)
    }

    private static func query(for account: String) -> CFDictionary {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary
    }

    private static func token(for account: String) -> String? {
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

    private static func save(token: String, for account: String) {
        guard !token.isEmpty else {
            SecItemDelete(query(for: account))
            return
        }
        let data = Data(token.utf8)
        let update = SecItemUpdate(query(for: account), [kSecValueData as String: data] as CFDictionary)
        guard update != errSecSuccess else { return }
        // Only "not found" justifies an add; anything else is a real keychain failure and adding on
        // top of it would mask the cause.
        guard update == errSecItemNotFound else {
            OpenNOWLog.error(.stream, "Remote Co-Op could not update the stored \(account) (\(update))")
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
            OpenNOWLog.error(.stream, "Remote Co-Op could not store the \(account) (\(addStatus))")
        }
    }
}
