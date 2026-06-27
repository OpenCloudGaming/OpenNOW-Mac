import AppKit
import CryptoKit
import Foundation
import Network
import Security

extension Notification.Name {
    static let openNOWTwitchOAuthCallback = Notification.Name("OpenNOWTwitchOAuthCallback")
}

struct TwitchOAuthToken: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let scopes: [String]

    var requiresRefresh: Bool {
        expiresAt.timeIntervalSinceNow < 120
    }
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

struct TwitchStreamMarker: Decodable, Equatable, Sendable {
    let id: String
    let createdAt: Date
    let positionSeconds: Int

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case positionSeconds = "position_seconds"
    }
}

struct TwitchStreamStatus: Decodable, Equatable, Sendable {
    let id: String
    let userID: String
    let type: String

    var isLive: Bool {
        type.lowercased() == "live"
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case type
    }
}

struct TwitchGame: Decodable, Equatable, Sendable {
    let id: String
    let name: String
}

struct TwitchIngestServer: Decodable, Equatable, Sendable {
    let id: Int
    let name: String
    let urlTemplate: String
    let priority: Int
    let isDefault: Bool

    var rtmpURL: String? {
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

enum TwitchIngestService {
    private static let endpoint = URL(string: "https://ingest.twitch.tv/ingests")!

    static func refreshDefaultServer() async {
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

enum TwitchIngestServerStore {
    private static let key = "OpenNOW.Twitch.DefaultIngestRTMPURL"

    static func defaultRTMPURL() -> String? {
        UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    static func save(defaultRTMPURL: String) {
        UserDefaults.standard.set(defaultRTMPURL, forKey: key)
    }
}

enum TwitchServiceError: LocalizedError, Sendable {
    case missingClientID
    case invalidCallback
    case stateMismatch
    case missingAuthorizationCode
    case missingToken
    case invalidResponse(String)
    case streamNotLive(String)
    case callbackServer(String)
    case keychain(OSStatus)
    case secureRandom(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingClientID: return "Enter a Twitch Client ID before connecting."
        case .invalidCallback: return "Twitch returned an invalid OAuth callback."
        case .stateMismatch: return "Twitch OAuth state did not match this login attempt."
        case .missingAuthorizationCode: return "Twitch did not return an authorization code."
        case .missingToken: return "Twitch is not connected."
        case .invalidResponse(let message): return message.isEmpty ? "Twitch returned an invalid response." : message
        case .streamNotLive(let message): return message.isEmpty ? "Twitch did not report this channel live." : message
        case .callbackServer(let message): return message.isEmpty ? "Unable to start the Twitch OAuth callback server." : message
        case .keychain(let status): return "Keychain operation failed with status \(status)."
        case .secureRandom(let status): return "Secure random generation failed with status \(status)."
        }
    }
}

enum TwitchOAuthService {
    static let clientID = "alymw1mbm3hayczv6a7mbqna6a9344"
    private static let callbackHost = "127.0.0.1"
    private static let callbackPort: UInt16 = 43_897
    static let redirectURI = "http://\(callbackHost):\(callbackPort)/"

    private static let authorizeEndpoint = URL(string: "https://id.twitch.tv/oauth2/authorize")!
    private static let revokeEndpoint = URL(string: "https://id.twitch.tv/oauth2/revoke")!
    private static let tokenEndpoint = URL(string: "https://id.twitch.tv/oauth2/token")!
    private static let validateEndpoint = URL(string: "https://id.twitch.tv/oauth2/validate")!
    private static let stateKey = "OpenNOW.Twitch.OAuth.State"
    private static let verifierKey = "OpenNOW.Twitch.OAuth.Verifier"
    nonisolated(unsafe) private static var callbackServer: TwitchOAuthCallbackServer?
    private static let scopes = [
        "user:read:email",
        "channel:read:stream_key",
        "channel:manage:broadcast",
        "chat:read",
        "chat:edit",
        "moderator:read:chat_settings",
        "moderator:manage:chat_settings",
        "channel:read:subscriptions",
        "bits:read",
    ]

    nonisolated static func isCallbackURL(_ url: URL) -> Bool {
        url.scheme == "http" && url.host == callbackHost && url.port == Int(callbackPort) && (url.path.isEmpty || url.path == "/")
    }

    static func start(clientID: String) async throws -> TwitchAccountStatus {
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { throw TwitchServiceError.missingClientID }
        let verifier = try randomURLSafeString(byteCount: 48)
        let state = try randomURLSafeString(byteCount: 32)
        UserDefaults.standard.set(state, forKey: stateKey)
        UserDefaults.standard.set(verifier, forKey: verifierKey)
        callbackServer?.stop()
        let server = TwitchOAuthCallbackServer(host: callbackHost, port: callbackPort)
        try await server.start()
        callbackServer = server
        var components = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "force_verify", value: "true"),
        ]
        guard let url = components?.url else { throw TwitchServiceError.invalidResponse("Unable to create Twitch authorization URL.") }
        NSWorkspace.shared.open(url)
        return statusFromStoredToken() ?? TwitchAccountStatus()
    }

    static func complete(callbackURL: URL, clientID: String) async throws -> TwitchAccountStatus {
        guard isCallbackURL(callbackURL), let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else { throw TwitchServiceError.invalidCallback }
        defer {
            callbackServer?.stop()
            callbackServer = nil
        }
        let items = safeQueryItems(components.queryItems ?? [])
        guard items["state"] == UserDefaults.standard.string(forKey: stateKey) else { throw TwitchServiceError.stateMismatch }
        guard let code = items["code"], !code.isEmpty else { throw TwitchServiceError.missingAuthorizationCode }
        guard let verifier = UserDefaults.standard.string(forKey: verifierKey), !verifier.isEmpty else { throw TwitchServiceError.invalidCallback }
        let token = try await exchangeCode(code, verifier: verifier, clientID: clientID)
        return try await finishConnection(clientID: clientID, token: token)
    }

    static func refreshStatus(clientID: String) async throws -> TwitchAccountStatus {
        await TwitchIngestService.refreshDefaultServer()
        let client = try await authorizedClient(clientID: clientID)
        let user = try await client.currentUser()
        let streamKey = try await client.streamKey(broadcasterID: user.id)
        if !streamKey.isEmpty { try TwitchStreamKeyStore.save(streamKey) }
        _ = try? await client.chatSettings(broadcasterID: user.id, moderatorID: user.id)
        _ = try? await client.eventSubSubscriptions()
        return TwitchAccountStatus(isConnected: true, displayName: user.displayName, login: user.login, channelID: user.id, streamKeyAvailable: TwitchStreamKeyStore.exists())
    }

    static func prepareBroadcast(clientID: String, title: String, applicationID: String) async throws -> String {
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

    static func createStreamMarker(clientID: String, description: String) async throws -> String {
        let client = try await authorizedClient(clientID: clientID)
        let user = try await client.currentUser()
        let marker = try await client.createStreamMarker(broadcasterID: user.id, description: description)
        return "Marker created at \(marker.createdAt.formatted(date: .omitted, time: .standard))."
    }

    static func verifyLiveBroadcast(clientID: String) async throws -> String {
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

    static func disconnect(clientID: String) async {
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
        callbackServer?.stop()
        callbackServer = nil
        TwitchTokenStore.delete()
        TwitchStreamKeyStore.delete()
    }

    private static func finishConnection(clientID: String, token: TwitchOAuthToken) async throws -> TwitchAccountStatus {
        try TwitchTokenStore.save(token)
        UserDefaults.standard.removeObject(forKey: stateKey)
        UserDefaults.standard.removeObject(forKey: verifierKey)
        let accessToken = token.accessToken
        let client = TwitchHelixClient(clientID: clientID, tokenProvider: { accessToken })
        let user = try await client.currentUser()
        let streamKey = try await client.streamKey(broadcasterID: user.id)
        if !streamKey.isEmpty { try TwitchStreamKeyStore.save(streamKey) }
        _ = try? await client.chatSettings(broadcasterID: user.id, moderatorID: user.id)
        _ = try? await client.eventSubSubscriptions()
        return TwitchAccountStatus(isConnected: true, displayName: user.displayName, login: user.login, channelID: user.id, streamKeyAvailable: TwitchStreamKeyStore.exists())
    }

    private static func authorizedClient(clientID: String) async throws -> TwitchHelixClient {
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { throw TwitchServiceError.missingClientID }
        let token = try await validToken(clientID: clientID)
        return TwitchHelixClient(clientID: clientID, tokenProvider: { token.accessToken })
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
        return try decodeToken(data)
    }

    private static func decodeToken(_ data: Data) throws -> TwitchOAuthToken {
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        return TwitchOAuthToken(accessToken: decoded.accessToken, refreshToken: decoded.refreshToken, expiresAt: Date().addingTimeInterval(decoded.expiresIn), scopes: decoded.scope)
    }

    private static func statusFromStoredToken() -> TwitchAccountStatus? {
        guard (try? TwitchTokenStore.load()) != nil else { return nil }
        return TwitchAccountStatus(isConnected: true, displayName: "Twitch", login: "", channelID: "", streamKeyAvailable: TwitchStreamKeyStore.exists())
    }

    private static func randomURLSafeString(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw TwitchServiceError.secureRandom(status) }
        return Data(bytes).base64URLEncodedString()
    }

    private static func safeQueryItems(_ queryItems: [URLQueryItem]) -> [String: String] {
        var items: [String: String] = [:]
        for item in queryItems {
            guard let value = item.value, items[item.name] == nil else { continue }
            items[item.name] = value
        }
        return items
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
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private final class TwitchOAuthCallbackServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.opencg.opennow.twitch.oauth.callback")
    private let host: String
    private let port: UInt16
    private var listener: NWListener?

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: TwitchServiceError.callbackServer("Twitch OAuth callback server is unavailable."))
                    return
                }
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(self.host), port: NWEndpoint.Port(rawValue: self.port)!)
                    let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: self.port)!)
                    let callbackQueue = self.queue
                    self.listener = listener
                    let resumeGate = TwitchContinuationResumeGate()
                    listener.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            guard resumeGate.claim() else { return }
                            continuation.resume()
                        case .failed(let error):
                            guard resumeGate.claim() else { return }
                            continuation.resume(throwing: TwitchServiceError.callbackServer("Unable to listen on http://\(self.host):\(self.port)/. Close anything using that callback port and try again. \(error.localizedDescription)"))
                        case .cancelled:
                            guard resumeGate.claim() else { return }
                            continuation.resume(throwing: TwitchServiceError.callbackServer("Twitch OAuth callback server stopped before it was ready."))
                        default:
                            break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        self?.handle(connection)
                    }
                    listener.start(queue: callbackQueue)
                } catch {
                    continuation.resume(throwing: TwitchServiceError.callbackServer("Unable to listen on http://\(self.host):\(self.port)/. Close anything using that callback port and try again. \(error.localizedDescription)"))
                }
            }
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let url = self.callbackURL(from: request)
            let accepted = url.map(TwitchOAuthService.isCallbackURL) ?? false
            let body = accepted ? "Twitch connected. You can close this window and return to OpenNOW." : "OpenNOW did not receive a valid Twitch callback. Return to OpenNOW and try connecting again."
            let statusLine = accepted ? "HTTP/1.1 200 OK" : "HTTP/1.1 400 Bad Request"
            self.sendResponse(statusLine: statusLine, body: body, connection: connection)
            if let url, accepted {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .openNOWTwitchOAuthCallback, object: url)
                }
            }
        }
    }

    private func callbackURL(from request: String) -> URL? {
        guard let requestLine = request.components(separatedBy: "\r\n").first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return URL(string: "http://\(host):\(port)\(parts[1])")
    }

    private func sendResponse(statusLine: String, body: String, connection: NWConnection) {
        let html = """
        <!doctype html><html><head><meta charset=\"utf-8\"><title>OpenNOW Twitch</title></head><body><p>\(body)</p></body></html>
        """
        let bodyData = Data(html.utf8)
        let header = "\(statusLine)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(bodyData)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

private final class TwitchContinuationResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return false }
        didResume = true
        return true
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

    static func exists() -> Bool {
        (try? load().isEmpty == false) ?? false
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

    func stream(userID: String) async throws -> TwitchStreamStatus? {
        struct Response: Decodable { let data: [TwitchStreamStatus] }
        let response: Response = try await request(path: "/helix/streams", queryItems: [URLQueryItem(name: "user_id", value: userID)])
        return response.data.first
    }

    func game(named name: String) async throws -> TwitchGame? {
        struct Response: Decodable { let data: [TwitchGame] }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        let response: Response = try await request(path: "/helix/games", queryItems: [URLQueryItem(name: "name", value: trimmedName)])
        return response.data.first { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame } ?? response.data.first
    }

    func updateChannel(broadcasterID: String, title: String?, gameID: String?) async throws {
        var body: [String: String] = [:]
        if let title, !title.isEmpty { body["title"] = String(title.prefix(140)) }
        if let gameID, !gameID.isEmpty { body["game_id"] = gameID }
        guard !body.isEmpty else { return }
        try await requestWithoutResponse(path: "/helix/channels", method: "PATCH", queryItems: [URLQueryItem(name: "broadcaster_id", value: broadcasterID)], body: body)
    }

    func createStreamMarker(broadcasterID: String, description: String) async throws -> TwitchStreamMarker {
        struct Response: Decodable { let data: [TwitchStreamMarker] }
        let trimmedDescription = String(description.trimmingCharacters(in: .whitespacesAndNewlines).prefix(140))
        let response: Response = try await request(path: "/helix/streams/markers", method: "POST", body: ["user_id": broadcasterID, "description": trimmedDescription])
        guard let marker = response.data.first else { throw TwitchServiceError.invalidResponse("Twitch did not return a stream marker.") }
        return marker
    }

    func chatSettings(broadcasterID: String, moderatorID: String) async throws -> TwitchChatSettings {
        struct Response: Decodable { let data: [TwitchChatSettings] }
        let response: Response = try await request(path: "/helix/chat/settings", queryItems: [URLQueryItem(name: "broadcaster_id", value: broadcasterID), URLQueryItem(name: "moderator_id", value: moderatorID)])
        guard let settings = response.data.first else { throw TwitchServiceError.invalidResponse("Twitch did not return chat settings.") }
        return settings
    }

    func eventSubSubscriptions() async throws -> [TwitchEventSubSubscription] {
        struct Response: Decodable { let data: [TwitchEventSubSubscription] }
        let response: Response = try await request(path: "/helix/eventsub/subscriptions")
        return response.data
    }

    private func request<T: Decodable>(path: String, method: String = "GET", queryItems: [URLQueryItem] = [], body: [String: String]? = nil) async throws -> T {
        let data = try await requestData(path: path, method: method, queryItems: queryItems, body: body)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    private func requestWithoutResponse(path: String, method: String, queryItems: [URLQueryItem] = [], body: [String: String]? = nil) async throws {
        _ = try await requestData(path: path, method: method, queryItems: queryItems, body: body)
    }

    private func requestData(path: String, method: String, queryItems: [URLQueryItem], body: [String: String]?) async throws -> Data {
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
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TwitchServiceError.invalidResponse(String(data: data, encoding: .utf8) ?? "Twitch request failed.")
        }
        return data
    }
}

struct TwitchChatSettings: Decodable, Equatable, Sendable {
    let broadcasterID: String
    let slowMode: Bool
    let followerMode: Bool
    let subscriberMode: Bool
    let emoteMode: Bool

    private enum CodingKeys: String, CodingKey {
        case broadcasterID = "broadcaster_id"
        case slowMode = "slow_mode"
        case followerMode = "follower_mode"
        case subscriberMode = "subscriber_mode"
        case emoteMode = "emote_mode"
    }
}

struct TwitchEventSubSubscription: Decodable, Equatable, Sendable {
    let id: String
    let status: String
    let type: String
    let version: String
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
