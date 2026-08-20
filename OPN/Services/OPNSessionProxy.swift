import Foundation
import Security

public enum OPNSessionProxyScheme: String, CaseIterable, Sendable {
    case http
    case socks5

    public var title: String { rawValue.uppercased() }
}

public struct OPNSessionProxySettings: Equatable, Sendable {
    public var isEnabled: Bool
    public var scheme: OPNSessionProxyScheme
    public var host: String
    public var port: String
    public var username: String

    public init(
        isEnabled: Bool = false,
        scheme: OPNSessionProxyScheme = .http,
        host: String = "",
        port: String = "",
        username: String = ""
    ) {
        self.isEnabled = isEnabled
        self.scheme = scheme
        self.host = host
        self.port = port
        self.username = username
    }
}

public struct OPNSessionProxyConfiguration: Equatable, Sendable {
    public let scheme: OPNSessionProxyScheme
    public let host: String
    public let port: Int
    public let username: String
    public let password: String

    public var cacheKey: String {
        "\(scheme.rawValue)://\(username):\(password)@\(host):\(port)"
    }

    public var endpointDescription: String {
        "\(scheme.title) \(host):\(port)"
    }

    public var connectionProxyDictionary: [AnyHashable: Any] {
        var dictionary: [AnyHashable: Any] = [:]
        switch scheme {
        case .http:
            dictionary[kCFNetworkProxiesHTTPEnable] = NSNumber(value: 1)
            dictionary[kCFNetworkProxiesHTTPProxy] = host
            dictionary[kCFNetworkProxiesHTTPPort] = NSNumber(value: port)
            dictionary[kCFNetworkProxiesHTTPSEnable] = NSNumber(value: 1)
            dictionary[kCFNetworkProxiesHTTPSProxy] = host
            dictionary[kCFNetworkProxiesHTTPSPort] = NSNumber(value: port)
        case .socks5:
            dictionary[kCFNetworkProxiesSOCKSEnable] = NSNumber(value: 1)
            dictionary[kCFNetworkProxiesSOCKSProxy] = host
            dictionary[kCFNetworkProxiesSOCKSPort] = NSNumber(value: port)
        }
        if !username.isEmpty {
            dictionary[kCFProxyUsernameKey] = username
            dictionary[kCFProxyPasswordKey] = password
        }
        return dictionary
    }

    public var credential: URLCredential? {
        guard !username.isEmpty else { return nil }
        return URLCredential(user: username, password: password, persistence: .none)
    }

    public var proxyAuthorizationHeader: String? {
        guard !username.isEmpty, let data = "\(username):\(password)".data(using: .utf8) else { return nil }
        return "Basic \(data.base64EncodedString())"
    }
}

public enum OPNSessionProxyStore {
    private static let enabledKey = "MacForceNow.Stream.SessionProxyEnabled"
    private static let schemeKey = "MacForceNow.Stream.SessionProxyScheme"
    private static let hostKey = "MacForceNow.Stream.SessionProxyHost"
    private static let portKey = "MacForceNow.Stream.SessionProxyPort"
    private static let usernameKey = "MacForceNow.Stream.SessionProxyUsername"
    private static let passwordKey = "MacForceNow.Stream.SessionProxyPassword"
    private static let legacyKeychainPurgeKey = "MacForceNow.Stream.SessionProxyLegacyKeychainPurged"

    public static func load() -> OPNSessionProxySettings {
        purgeLegacyKeychainPasswordIfNeeded()
        let storage = OPNAppPreferenceStorage.standard
        let schemeRaw = storage.object(forKey: schemeKey) as? String ?? ""
        return OPNSessionProxySettings(
            isEnabled: storage.bool(forKey: enabledKey),
            scheme: OPNSessionProxyScheme(rawValue: schemeRaw) ?? .http,
            host: storage.object(forKey: hostKey) as? String ?? "",
            port: storage.object(forKey: portKey) as? String ?? "",
            username: storage.object(forKey: usernameKey) as? String ?? ""
        )
    }

    public static func save(_ settings: OPNSessionProxySettings) {
        let storage = OPNAppPreferenceStorage.standard
        storage.set(settings.isEnabled, forKey: enabledKey)
        storage.set(settings.scheme.rawValue, forKey: schemeKey)
        storage.set(settings.host, forKey: hostKey)
        storage.set(settings.port, forKey: portKey)
        storage.set(settings.username, forKey: usernameKey)
    }

    public static func loadPassword() -> String {
        purgeLegacyKeychainPasswordIfNeeded()
        return OPNAppPreferenceStorage.standard.string(forKey: passwordKey) ?? ""
    }

    @discardableResult
    public static func savePassword(_ password: String) -> Bool {
        OPNAppPreferenceStorage.standard.set(password, forKey: passwordKey)
        return true
    }

    private static func purgeLegacyKeychainPasswordIfNeeded() {
        let storage = OPNAppPreferenceStorage.standard
        guard !storage.bool(forKey: legacyKeychainPurgeKey) else { return }
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "MacForceNow.SessionProxy",
            kSecAttrAccount as String: "password",
        ] as CFDictionary)
        storage.set(true, forKey: legacyKeychainPurgeKey)
    }

    public static func configuration() -> OPNSessionProxyConfiguration? {
        let settings = load()
        guard settings.isEnabled else { return nil }
        return configuration(from: settings, password: loadPassword())
    }

    public static func configuration(from settings: OPNSessionProxySettings, password: String) -> OPNSessionProxyConfiguration? {
        let host = settings.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !host.contains("://"), !host.contains("/"), !host.contains(" ") else { return nil }
        guard let port = Int(settings.port.trimmingCharacters(in: .whitespacesAndNewlines)), (1...65535).contains(port) else { return nil }
        let username = settings.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard password.isEmpty || !username.isEmpty else { return nil }
        return OPNSessionProxyConfiguration(
            scheme: settings.scheme,
            host: host,
            port: port,
            username: username,
            password: password
        )
    }

}

public final class OPNSessionProxySessionProvider: NSObject, URLSessionDelegate, @unchecked Sendable {
    public static let shared = OPNSessionProxySessionProvider()

    public static let directFallbackStatuses: Set<Int> = [407, 408, 425, 429, 500, 502, 503, 504]
    public static let cooldownDuration: TimeInterval = 60

    private struct State {
        var sessions: [String: URLSession] = [:]
        var credentialsBySession: [ObjectIdentifier: URLCredential] = [:]
        var cooldownUntil: TimeInterval = 0
    }

    private let lock = NSLock()
    private var state = State()
    private let now: @Sendable () -> TimeInterval

    public init(now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        self.now = now
    }

    public func controlPlaneURLSession() -> URLSession {
        guard let configuration = OPNSessionProxyStore.configuration() else { return .shared }
        lock.lock()
        let inCooldown = state.cooldownUntil > now()
        lock.unlock()
        guard !inCooldown else { return .shared }
        return session(for: configuration)
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let session = controlPlaneURLSession()
        let proxied = session !== URLSession.shared
        do {
            let (data, response) = try await session.data(for: request)
            if proxied, let http = response as? HTTPURLResponse, Self.directFallbackStatuses.contains(http.statusCode) {
                recordFailure()
                return try await URLSession.shared.data(for: request)
            }
            return (data, response)
        } catch {
            if proxied, Self.shouldFallbackToDirect(after: error) {
                recordFailure()
                return try await URLSession.shared.data(for: request)
            }
            throw error
        }
    }

    public static let connectionTestURL = "https://play.geforcenow.com"
    public static let connectionTestTimeout: TimeInterval = 10

    public func testConnection(configuration: OPNSessionProxyConfiguration) async -> Result<Int, any Error> {
        guard let url = URL(string: Self.connectionTestURL) else {
            return .failure(URLError(.badURL))
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.connectionTestTimeout
        let startedAt = now()
        do {
            let (_, response) = try await session(for: configuration).data(for: request)
            guard response is HTTPURLResponse else {
                return .failure(URLError(.badServerResponse))
            }
            return .success(max(0, Int((now() - startedAt) * 1000)))
        } catch {
            return .failure(error)
        }
    }

    public func recordFailure() {
        lock.lock()
        state.cooldownUntil = now() + Self.cooldownDuration
        lock.unlock()
    }

    public func resetCooldown() {
        lock.lock()
        state.cooldownUntil = 0
        lock.unlock()
    }

    public static func shouldFallbackToDirect(after error: any Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet,
             .timedOut, .dnsLookupFailed, .secureConnectionFailed, .cannotLoadFromNetwork,
             .userAuthenticationRequired:
            return true
        default:
            return false
        }
    }

    private func session(for configuration: OPNSessionProxyConfiguration) -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let existing = state.sessions[configuration.cacheKey] { return existing }
        let urlConfiguration = URLSessionConfiguration.ephemeral
        urlConfiguration.connectionProxyDictionary = configuration.connectionProxyDictionary
        urlConfiguration.waitsForConnectivity = false
        if let proxyAuthorization = configuration.proxyAuthorizationHeader {
            urlConfiguration.httpAdditionalHeaders = ["Proxy-Authorization": proxyAuthorization]
        }
        let session = URLSession(configuration: urlConfiguration, delegate: self, delegateQueue: nil)
        state.sessions[configuration.cacheKey] = session
        if let credential = configuration.credential {
            state.credentialsBySession[ObjectIdentifier(session)] = credential
        }
        return session
    }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        guard method == "NSURLAuthenticationMethodHTTPProxy" || method == "NSURLAuthenticationMethodSOCKSProxy" else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard challenge.previousFailureCount == 0 else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        lock.lock()
        let credential = state.credentialsBySession[ObjectIdentifier(session)]
        lock.unlock()
        if let credential {
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
