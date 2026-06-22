import AppKit
import CryptoKit
import Foundation
import Security

extension Notification.Name {
    static let openNOWTwitchOAuthCallback = Notification.Name("OpenNOWTwitchOAuthCallback")
}

struct TwitchOAuthToken: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let scopes: [String]
}

struct TwitchUser: Codable, Equatable, Sendable {
    let id: String
    let login: String
    let displayName: String

    private enum CodingKeys: String, CodingKey {
        case id
        case login
        case displayName = "display_name"
    }
}

enum TwitchServiceError: LocalizedError, Sendable {
    case missingClientID
    case invalidCallback
    case stateMismatch
    case missingAuthorizationCode
    case missingToken
    case invalidResponse(String)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingClientID: return "Enter a Twitch Client ID before connecting."
        case .invalidCallback: return "Twitch returned an invalid OAuth callback."
        case .stateMismatch: return "Twitch OAuth state did not match this login attempt."
        case .missingAuthorizationCode: return "Twitch did not return an authorization code."
        case .missingToken: return "Twitch is not connected."
        case .invalidResponse(let message): return message.isEmpty ? "Twitch returned an invalid response." : message
        case .keychain(let status): return "Keychain operation failed with status \(status)."
        }
    }
}

enum TwitchOAuthService {
    private static let authorizationEndpoint = URL(string: "https://id.twitch.tv/oauth2/authorize")!
    private static let tokenEndpoint = URL(string: "https://id.twitch.tv/oauth2/token")!
    private static let redirectURI = "opennow://twitch/oauth"
    private static let stateKey = "OpenNOW.Twitch.OAuth.State"
    private static let verifierKey = "OpenNOW.Twitch.OAuth.Verifier"
    private static let scopes = [
        "user:read:email",
        "channel:read:stream_key",
        "channel:manage:broadcast",
        "chat:read",
        "chat:edit",
    ]

    static func isCallbackURL(_ url: URL) -> Bool {
        url.scheme == "opennow" && url.host == "twitch" && url.path == "/oauth"
    }

    static func start(clientID: String) throws {
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { throw TwitchServiceError.missingClientID }
        let verifier = randomURLSafeString(byteCount: 48)
        let state = randomURLSafeString(byteCount: 32)
        UserDefaults.standard.set(state, forKey: stateKey)
        UserDefaults.standard.set(verifier, forKey: verifierKey)

        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = components.url else { throw TwitchServiceError.invalidResponse("Unable to create Twitch authorization URL.") }
        NSWorkspace.shared.open(url)
    }

    static func complete(callbackURL: URL, clientID: String) async throws -> TwitchAccountStatus {
        guard isCallbackURL(callbackURL), let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else { throw TwitchServiceError.invalidCallback }
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } })
        guard items["state"] == UserDefaults.standard.string(forKey: stateKey) else { throw TwitchServiceError.stateMismatch }
        guard let code = items["code"], !code.isEmpty else { throw TwitchServiceError.missingAuthorizationCode }
        guard let verifier = UserDefaults.standard.string(forKey: verifierKey), !verifier.isEmpty else { throw TwitchServiceError.invalidCallback }
        let token = try await exchangeCode(code, verifier: verifier, clientID: clientID)
        try TwitchTokenStore.save(token)
        UserDefaults.standard.removeObject(forKey: stateKey)
        UserDefaults.standard.removeObject(forKey: verifierKey)
        let accessToken = token.accessToken
        let client = TwitchHelixClient(clientID: clientID, tokenProvider: { accessToken })
        let user = try await client.currentUser()
        let streamKey = try await client.streamKey(broadcasterID: user.id)
        try TwitchStreamKeyStore.save(streamKey)
        return TwitchAccountStatus(isConnected: true, displayName: user.displayName, login: user.login, channelID: user.id, streamKeyAvailable: !streamKey.isEmpty)
    }

    private static func exchangeCode(_ code: String, verifier: String, clientID: String) async throws -> TwitchOAuthToken {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ]
        request.httpBody = formBody(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TwitchServiceError.invalidResponse(String(data: data, encoding: .utf8) ?? "Twitch token exchange failed.")
        }
        struct TokenResponse: Decodable {
            let accessToken: String
            let refreshToken: String
            let expiresIn: Double
            let scope: [String]

            private enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
                case expiresIn = "expires_in"
                case scope
            }
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        return TwitchOAuthToken(accessToken: decoded.accessToken, refreshToken: decoded.refreshToken, expiresAt: Date().addingTimeInterval(decoded.expiresIn), scopes: decoded.scope)
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private static func codeChallenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }

    private static func formBody(_ values: [String: String]) -> Data {
        values.map { key, value in "\(formEncode(key))=\(formEncode(value))" }.joined(separator: "&").data(using: .utf8) ?? Data()
    }

    private static func formEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))) ?? value
    }
}

enum TwitchTokenStore {
    private static let service = "OpenNOW.Twitch"
    private static let account = "OAuthToken"

    static func save(_ token: TwitchOAuthToken) throws {
        let data = try JSONEncoder().encode(token)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            attributes.forEach { add[$0.key] = $0.value }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw TwitchServiceError.keychain(addStatus) }
            return
        }
        guard status == errSecSuccess else { throw TwitchServiceError.keychain(status) }
    }

    static func load() throws -> TwitchOAuthToken {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { throw TwitchServiceError.missingToken }
        return try JSONDecoder().decode(TwitchOAuthToken.self, from: data)
    }

    static func delete() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

enum TwitchStreamKeyStore {
    private static let service = "OpenNOW.Twitch"
    private static let account = "StreamKey"

    static func save(_ streamKey: String) throws {
        let data = Data(streamKey.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            attributes.forEach { add[$0.key] = $0.value }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw TwitchServiceError.keychain(addStatus) }
            return
        }
        guard status == errSecSuccess else { throw TwitchServiceError.keychain(status) }
    }

    static func load() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty else { throw TwitchServiceError.missingToken }
        return value
    }

    static func delete() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

struct TwitchHelixClient: Sendable {
    let clientID: String
    let tokenProvider: @Sendable () throws -> String

    func currentUser() async throws -> TwitchUser {
        struct Response: Decodable { let data: [TwitchUser] }
        let response: Response = try await request(path: "/helix/users")
        guard let user = response.data.first else { throw TwitchServiceError.invalidResponse("Twitch did not return a user profile.") }
        return user
    }

    func streamKey(broadcasterID: String) async throws -> String {
        struct Key: Decodable { let streamKey: String; private enum CodingKeys: String, CodingKey { case streamKey = "stream_key" } }
        struct Response: Decodable { let data: [Key] }
        let response: Response = try await request(path: "/helix/streams/key", queryItems: [URLQueryItem(name: "broadcaster_id", value: broadcasterID)])
        return response.data.first?.streamKey ?? ""
    }

    private func request<T: Decodable>(path: String, queryItems: [URLQueryItem] = []) async throws -> T {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.twitch.tv"
        components.path = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else { throw TwitchServiceError.invalidResponse("Invalid Twitch API URL.") }
        var request = URLRequest(url: url)
        request.setValue(clientID, forHTTPHeaderField: "Client-Id")
        request.setValue("Bearer \(try tokenProvider())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TwitchServiceError.invalidResponse(String(data: data, encoding: .utf8) ?? "Twitch request failed.")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
