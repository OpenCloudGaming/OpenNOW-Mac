import AppKit
import AppKit
import Foundation
import Security

public struct TwitchOAuthToken: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    public let scopes: [String]

    public var requiresRefresh: Bool {
        expiresAt.timeIntervalSinceNow < 120
    }
}

public struct TwitchUser: Codable, Equatable, Sendable {
    public let id: String
    public let login: String
    public let displayName: String

    private enum CodingKeys: String, CodingKey {
        case id
        case login
        case displayName = "display_name"
    }
}

public struct TwitchStreamMarker: Decodable, Equatable, Sendable {
    public let id: String
    public let createdAt: Date
    public let positionSeconds: Int

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case positionSeconds = "position_seconds"
    }
}

public struct TwitchStreamStatus: Decodable, Equatable, Sendable {
    public let id: String
    public let userID: String
    public let type: String

    public var isLive: Bool {
        type.lowercased() == "live"
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case type
    }
}

public struct TwitchGame: Decodable, Equatable, Sendable {
    public let id: String
    public let name: String
}

public struct TwitchIngestServer: Decodable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let urlTemplate: String
    public let priority: Int
    public let isDefault: Bool

    public var rtmpURL: String? {
        let url = urlTemplate.replacingOccurrences(of: "/{stream_key}", with: "")
        return URL(string: url) == nil ? nil : url
    }

    private enum CodingKeys: String, CodingKey {
        case id = "_id"
        case name
        case urlTemplate = "url_template"
        case priority
        case isDefault = "default"
    }
}

public enum TwitchIngestService {
    private static let endpoint = URL(string: "https://ingest.twitch.tv/ingests")!

    public static func refreshDefaultServer() async {
        guard let servers = try? await ingestServers(), let server = preferredServer(from: servers), let rtmpURL = server.rtmpURL else { return }
        TwitchIngestServerStore.save(defaultRTMPURL: rtmpURL)
    }

    private static func ingestServers() async throws -> [TwitchIngestServer] {
        struct Response: Decodable { let ingests: [TwitchIngestServer] }
        let (data, response) = try await URLSession.shared.data(from: endpoint)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return [] }
        return try JSONDecoder().decode(Response.self, from: data).ingests
    }

    private static func preferredServer(from servers: [TwitchIngestServer]) -> TwitchIngestServer? {
        servers.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.priority < rhs.priority
        }.first
    }
}

public enum TwitchIngestServerStore {
    private static let key = "OpenNOW.Twitch.DefaultIngestRTMPURL"

    public static func defaultRTMPURL() -> String? {
        UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    public static func save(defaultRTMPURL: String) {
        UserDefaults.standard.set(defaultRTMPURL, forKey: key)
    }
}

public enum TwitchServiceError: LocalizedError, Sendable {
    case missingClientID
    case missingToken
    case invalidResponse(String)
    case streamNotLive(String)
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .missingClientID: return "Enter a Twitch Client ID before connecting."
        case .missingToken: return "Twitch is not connected."
        case .invalidResponse(let message): return message.isEmpty ? "Twitch returned an invalid response." : message
        case .streamNotLive(let message): return message.isEmpty ? "Twitch did not report this channel live." : message
        case .keychain(let status): return "Keychain operation failed with status \(status)."
        }
    }
}

public enum TwitchOAuthService {
    public static let clientID = "alymw1mbm3hayczv6a7mbqna6a9344"
    private static let deviceEndpoint = URL(string: "https://id.twitch.tv/oauth2/device")!
    private static let revokeEndpoint = URL(string: "https://id.twitch.tv/oauth2/revoke")!
    private static let tokenEndpoint = URL(string: "https://id.twitch.tv/oauth2/token")!
    private static let validateEndpoint = URL(string: "https://id.twitch.tv/oauth2/validate")!
    private static let scopes = [
        "user:read:email",
        "channel:read:stream_key",
        "channel:manage:broadcast",
        "chat:read",
        "chat:edit",
        "moderator:read:chat_settings",
        "moderator:manage:chat_settings",
        "channel:read:subscriptions",
        "channel:read:redemptions",
        "moderator:read:followers",
        "bits:read",
    ]

    public static func start(clientID: String) async throws -> TwitchAccountStatus {
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { throw TwitchServiceError.missingClientID }
        let device = try await createDeviceAuthorization(clientID: clientID)
        guard let verificationURL = URL(string: device.verificationURI) else { throw TwitchServiceError.invalidResponse("Twitch returned an invalid activation URL.") }
        NSWorkspace.shared.open(verificationURL)
        let token = try await pollDeviceAuthorization(clientID: clientID, device: device)
        return try await finishConnection(clientID: clientID, token: token)
    }

    public static func refreshStatus(clientID: String) async throws -> TwitchAccountStatus {
        await TwitchIngestService.refreshDefaultServer()
        let client = try await authorizedClient(clientID: clientID)
        let user = try await client.currentUser()
        let streamKey = try await client.streamKey(broadcasterID: user.id)
        if !streamKey.isEmpty { try TwitchStreamKeyStore.save(streamKey) }
        _ = try? await client.chatSettings(broadcasterID: user.id, moderatorID: user.id)
        _ = try? await client.eventSubSubscriptions()
        return TwitchAccountStatus(isConnected: true, displayName: user.displayName, login: user.login, channelID: user.id, streamKeyAvailable: TwitchStreamKeyStore.exists())
    }

    public static func prepareBroadcast(clientID: String, title: String, applicationID: String) async throws -> String {
        await TwitchIngestService.refreshDefaultServer()
        let preferences = TwitchPreferencesStore.load()
        let client = try await authorizedClient(clientID: clientID)
        let user = try await client.currentUser()
        let gameTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "OpenNOW Live"
        let broadcastTitle = preferences.autoTitleFromGame ? gameTitle : nil
        let category = try? await client.game(named: gameTitle)
        try await client.updateChannel(broadcasterID: user.id, title: broadcastTitle, gameID: category?.id)
        switch (broadcastTitle, category?.name) {
        case (let broadcastTitle?, let categoryName?): return "Twitch title set to \"\(broadcastTitle)\" and category set to \"\(categoryName)\"."
        case (let broadcastTitle?, nil): return "Twitch title set to \"\(broadcastTitle)\". Category not found for \"\(gameTitle)\"."
        case (nil, let categoryName?): return "Twitch category set to \"\(categoryName)\"."
        case (nil, nil): return "Twitch broadcast ready. Category not found for \"\(gameTitle)\"."
        }
    }

    public static func createStreamMarker(clientID: String, description: String) async throws -> String {
        let client = try await authorizedClient(clientID: clientID)
        let user = try await client.currentUser()
        let marker = try await client.createStreamMarker(broadcasterID: user.id, description: description)
        return "Marker created at \(marker.createdAt.formatted(date: .omitted, time: .standard))."
    }

    public static func verifyLiveBroadcast(clientID: String) async throws -> String {
        let client = try await authorizedClient(clientID: clientID)
        let user = try await client.currentUser()
        let deadline = Date().addingTimeInterval(75)
        while Date() < deadline {
            let stream = try await client.stream(userID: user.id)
            if stream?.isLive == true {
                return "Twitch confirmed this stream is live."
            }
            try await Task.sleep(for: .seconds(5))
        }
        throw TwitchServiceError.streamNotLive("Twitch did not report this channel live after publishing started.")
    }

    public static func disconnect(clientID: String) async {
        guard let token = try? TwitchTokenStore.load(), !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            TwitchTokenStore.delete()
            TwitchStreamKeyStore.delete()
            return
        }
        var request = URLRequest(url: revokeEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(["client_id": clientID, "token": token.accessToken])
        _ = try? await URLSession.shared.data(for: request)
        TwitchTokenStore.delete()
        TwitchStreamKeyStore.delete()
    }

    private static func finishConnection(clientID: String, token: TwitchOAuthToken) async throws -> TwitchAccountStatus {
        try TwitchTokenStore.save(token)
        let accessToken = token.accessToken
        let client = TwitchHelixClient(clientID: clientID, tokenProvider: { accessToken })
        let user = try await client.currentUser()
        let streamKey = try await client.streamKey(broadcasterID: user.id)
        if !streamKey.isEmpty { try TwitchStreamKeyStore.save(streamKey) }
        _ = try? await client.chatSettings(broadcasterID: user.id, moderatorID: user.id)
        _ = try? await client.eventSubSubscriptions()
        return TwitchAccountStatus(isConnected: true, displayName: user.displayName, login: user.login, channelID: user.id, streamKeyAvailable: TwitchStreamKeyStore.exists())
    }

    public static func authorizedClient(clientID: String) async throws -> TwitchHelixClient {
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { throw TwitchServiceError.missingClientID }
        let token = try await validToken(clientID: clientID)
        return TwitchHelixClient(clientID: clientID, tokenProvider: { token.accessToken })
    }

    public static func validStoredToken(clientID: String) async throws -> TwitchOAuthToken {
        try await validToken(clientID: clientID)
    }

    private static func validToken(clientID: String) async throws -> TwitchOAuthToken {
        let token = try TwitchTokenStore.load()
        if token.requiresRefresh { return try await refreshToken(clientID: clientID, refreshToken: token.refreshToken) }
        do {
            try await validate(token: token.accessToken)
            return token
        } catch {
            return try await refreshToken(clientID: clientID, refreshToken: token.refreshToken)
        }
    }

    private static func validate(token: String) async throws {
        var request = URLRequest(url: validateEndpoint)
        request.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TwitchServiceError.invalidResponse(twitchErrorMessage(data: data, fallback: "Twitch OAuth token is no longer valid."))
        }
    }

    private static func refreshToken(clientID: String, refreshToken: String) async throws -> TwitchOAuthToken {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(["client_id": clientID, "grant_type": "refresh_token", "refresh_token": refreshToken])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TwitchServiceError.invalidResponse(Self.twitchErrorMessage(data: data, fallback: "Twitch token refresh failed."))
        }
        let token = try decodeToken(data)
        try TwitchTokenStore.save(token)
        return token
    }

    private static func createDeviceAuthorization(clientID: String) async throws -> DeviceAuthorizationResponse {
        var request = URLRequest(url: deviceEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(["client_id": clientID, "scopes": scopes.joined(separator: " ")])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TwitchServiceError.invalidResponse(Self.twitchErrorMessage(data: data, fallback: "Twitch device authorization failed."))
        }
        return try JSONDecoder().decode(DeviceAuthorizationResponse.self, from: data)
    }

    private static func pollDeviceAuthorization(clientID: String, device: DeviceAuthorizationResponse) async throws -> TwitchOAuthToken {
        let deadline = Date().addingTimeInterval(TimeInterval(device.expiresIn))
        var interval = max(1, device.interval)
        while Date() < deadline {
            try await Task.sleep(for: .seconds(interval))
            var request = URLRequest(url: tokenEndpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = formBody([
                "client_id": clientID,
                "device_code": device.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "scopes": scopes.joined(separator: " "),
            ])
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                return try decodeToken(data)
            }
            let message = twitchErrorMessage(data: data, fallback: "Twitch device authorization is pending.")
            switch message {
            case "authorization_pending":
                continue
            case "slow_down":
                interval += 5
            default:
                throw TwitchServiceError.invalidResponse(message)
            }
        }
        throw TwitchServiceError.invalidResponse("Twitch authorization expired before approval was completed.")
    }

    private static func decodeToken(_ data: Data) throws -> TwitchOAuthToken {
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        return TwitchOAuthToken(accessToken: decoded.accessToken, refreshToken: decoded.refreshToken, expiresAt: Date().addingTimeInterval(decoded.expiresIn), scopes: decoded.scope)
    }

    private static func statusFromStoredToken() -> TwitchAccountStatus? {
        guard (try? TwitchTokenStore.load()) != nil else { return nil }
        return TwitchAccountStatus(isConnected: true, displayName: "Twitch", login: "", channelID: "", streamKeyAvailable: TwitchStreamKeyStore.exists())
    }

    private static func formBody(_ values: [String: String]) -> Data {
        values.map { key, value in "\(formEncode(key))=\(formEncode(value))" }.joined(separator: "&").data(using: .utf8) ?? Data()
    }

    private static func formEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))) ?? value
    }

    private static func twitchErrorMessage(data: Data, fallback: String) -> String {
        struct ErrorResponse: Decodable { let message: String }
        if let decoded = try? JSONDecoder().decode(ErrorResponse.self, from: data), !decoded.message.isEmpty { return decoded.message }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? fallback
    }

    private static func readableTwitchError(_ message: String) -> String {
        if message == "invalid client" { return "Twitch rejected OpenNOW's built-in Client ID. Make sure the Twitch Developer app is enabled." }
        return message
    }

    private struct TokenResponse: Decodable {
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

    private struct DeviceAuthorizationResponse: Decodable {
        let deviceCode: String
        let expiresIn: Int
        let interval: Int
        let userCode: String
        let verificationURI: String

        private enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case expiresIn = "expires_in"
            case interval
            case userCode = "user_code"
            case verificationURI = "verification_uri"
        }
    }
}

public enum TwitchTokenStore {
    private static let service = "OpenNOW.Twitch"
    private static let account = "OAuthToken"

    public static func save(_ token: TwitchOAuthToken) throws {
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

    public static func load() throws -> TwitchOAuthToken {
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

    public static func delete() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

public enum TwitchStreamKeyStore {
    private static let service = "OpenNOW.Twitch"
    private static let account = "StreamKey"

    public static func save(_ streamKey: String) throws {
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

    public static func load() throws -> String {
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

    public static func exists() -> Bool {
        (try? load().isEmpty == false) ?? false
    }

    public static func delete() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

public struct TwitchHelixClient: Sendable {
    public let clientID: String
    public let tokenProvider: @Sendable () throws -> String

    public init(clientID: String, tokenProvider: @escaping @Sendable () throws -> String) {
        self.clientID = clientID
        self.tokenProvider = tokenProvider
    }

    public func currentUser() async throws -> TwitchUser {
        struct Response: Decodable { let data: [TwitchUser] }
        let response: Response = try await request(path: "/helix/users")
        guard let user = response.data.first else { throw TwitchServiceError.invalidResponse("Twitch did not return a user profile.") }
        return user
    }

    public func streamKey(broadcasterID: String) async throws -> String {
        struct Key: Decodable { let streamKey: String; private enum CodingKeys: String, CodingKey { case streamKey = "stream_key" } }
        struct Response: Decodable { let data: [Key] }
        let response: Response = try await request(path: "/helix/streams/key", queryItems: [URLQueryItem(name: "broadcaster_id", value: broadcasterID)])
        return response.data.first?.streamKey ?? ""
    }

    public func stream(userID: String) async throws -> TwitchStreamStatus? {
        struct Response: Decodable { let data: [TwitchStreamStatus] }
        let response: Response = try await request(path: "/helix/streams", queryItems: [URLQueryItem(name: "user_id", value: userID)])
        return response.data.first
    }

    public func game(named name: String) async throws -> TwitchGame? {
        struct Response: Decodable { let data: [TwitchGame] }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        let response: Response = try await request(path: "/helix/games", queryItems: [URLQueryItem(name: "name", value: trimmedName)])
        return response.data.first { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame } ?? response.data.first
    }

    public func updateChannel(broadcasterID: String, title: String?, gameID: String?) async throws {
        var body: [String: String] = [:]
        if let title, !title.isEmpty { body["title"] = String(title.prefix(140)) }
        if let gameID, !gameID.isEmpty { body["game_id"] = gameID }
        guard !body.isEmpty else { return }
        try await requestWithoutResponse(path: "/helix/channels", method: "PATCH", queryItems: [URLQueryItem(name: "broadcaster_id", value: broadcasterID)], body: body)
    }

    public func createStreamMarker(broadcasterID: String, description: String) async throws -> TwitchStreamMarker {
        struct Response: Decodable { let data: [TwitchStreamMarker] }
        let trimmedDescription = String(description.trimmingCharacters(in: .whitespacesAndNewlines).prefix(140))
        let response: Response = try await request(path: "/helix/streams/markers", method: "POST", body: ["user_id": broadcasterID, "description": trimmedDescription])
        guard let marker = response.data.first else { throw TwitchServiceError.invalidResponse("Twitch did not return a stream marker.") }
        return marker
    }

    public func chatSettings(broadcasterID: String, moderatorID: String) async throws -> TwitchChatSettings {
        struct Response: Decodable { let data: [TwitchChatSettings] }
        let response: Response = try await request(path: "/helix/chat/settings", queryItems: [URLQueryItem(name: "broadcaster_id", value: broadcasterID), URLQueryItem(name: "moderator_id", value: moderatorID)])
        guard let settings = response.data.first else { throw TwitchServiceError.invalidResponse("Twitch did not return chat settings.") }
        return settings
    }

    public func eventSubSubscriptions() async throws -> [TwitchEventSubSubscription] {
        struct Response: Decodable { let data: [TwitchEventSubSubscription] }
        let response: Response = try await request(path: "/helix/eventsub/subscriptions")
        return response.data
    }

    public func createEventSubSubscription(type: String, version: String, condition: [String: String], sessionID: String) async throws -> TwitchEventSubSubscription {
        struct Response: Decodable { let data: [TwitchEventSubSubscription] }
        let body = TwitchEventSubSubscriptionRequest(type: type, version: version, condition: condition, transport: TwitchEventSubTransport(method: "websocket", sessionID: sessionID))
        let response: Response = try await request(path: "/helix/eventsub/subscriptions", method: "POST", encodableBody: body)
        guard let subscription = response.data.first else { throw TwitchServiceError.invalidResponse("Twitch did not return an EventSub subscription.") }
        return subscription
    }

    private func request<T: Decodable>(path: String, method: String = "GET", queryItems: [URLQueryItem] = [], body: [String: String]? = nil) async throws -> T {
        let data = try await requestData(path: path, method: method, queryItems: queryItems, body: body)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    private func request<T: Decodable, Body: Encodable>(path: String, method: String, queryItems: [URLQueryItem] = [], encodableBody: Body) async throws -> T {
        let data = try await requestData(path: path, method: method, queryItems: queryItems, bodyData: try JSONEncoder().encode(encodableBody))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    private func requestWithoutResponse(path: String, method: String, queryItems: [URLQueryItem] = [], body: [String: String]? = nil) async throws {
        _ = try await requestData(path: path, method: method, queryItems: queryItems, body: body)
    }

    private func requestData(path: String, method: String, queryItems: [URLQueryItem], body: [String: String]?) async throws -> Data {
        try await requestData(path: path, method: method, queryItems: queryItems, bodyData: body.map { try JSONEncoder().encode($0) })
    }

    private func makeRequest(path: String, method: String, queryItems: [URLQueryItem], bodyData: Data?) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.twitch.tv"
        components.path = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else { throw TwitchServiceError.invalidResponse("Invalid Twitch API URL.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(clientID, forHTTPHeaderField: "Client-Id")
        request.setValue("Bearer \(try tokenProvider())", forHTTPHeaderField: "Authorization")
        if let bodyData {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = bodyData
        }
        return request
    }

    private func requestData(path: String, method: String, queryItems: [URLQueryItem], bodyData: Data?) async throws -> Data {
        let request = try makeRequest(path: path, method: method, queryItems: queryItems, bodyData: bodyData)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TwitchServiceError.invalidResponse(String(data: data, encoding: .utf8) ?? "Twitch request failed.")
        }
        return data
    }
}

public struct TwitchChatSettings: Decodable, Equatable, Sendable {
    public let broadcasterID: String
    public let slowMode: Bool
    public let followerMode: Bool
    public let subscriberMode: Bool
    public let emoteMode: Bool

    private enum CodingKeys: String, CodingKey {
        case broadcasterID = "broadcaster_id"
        case slowMode = "slow_mode"
        case followerMode = "follower_mode"
        case subscriberMode = "subscriber_mode"
        case emoteMode = "emote_mode"
    }
}

public struct TwitchEventSubSubscription: Decodable, Equatable, Sendable {
    public let id: String
    public let status: String
    public let type: String
    public let version: String
}

private struct TwitchEventSubSubscriptionRequest: Encodable {
    let type: String
    let version: String
    let condition: [String: String]
    let transport: TwitchEventSubTransport
}

private struct TwitchEventSubTransport: Encodable {
    let method: String
    let sessionID: String

    private enum CodingKeys: String, CodingKey {
        case method
        case sessionID = "session_id"
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
