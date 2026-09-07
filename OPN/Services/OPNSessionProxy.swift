import Foundation
import Security

public enum OPNSessionProxyScheme: String, CaseIterable, Sendable {
    case http
    case socks5

    public var title: String { rawValue.uppercased() }
}

/// Which control-plane requests leave through the proxy. The catalog (games.geforce.com and the
/// account/ownership lookups) decides what the store shows; CloudMatch decides where the seat is.
/// A user in one region reading another region's catalog usually still wants their own seat: a
/// seat allocated where the proxy exits adds the proxy's distance to every frame. `catalogOnly`
/// keeps CloudMatch direct, so the selected region (or the automatic one, from the real address)
/// still picks the seat.
public enum OPNSessionProxyScope: String, CaseIterable, Sendable {
    case everything
    case catalogOnly

    public var title: String {
        switch self {
        case .everything: "Catalog + Sessions"
        case .catalogOnly: "Catalog Only"
        }
    }
}

/// What a control-plane request is for, so the scope can route it.
public enum OPNSessionProxyPurpose: Sendable {
    /// Catalog, account, ownership and region lookups.
    case catalog
    /// CloudMatch session create/poll/claim/stop and the active-session service.
    case session
}

public struct OPNSessionProxySettings: Equatable, Sendable {
    public var isEnabled: Bool
    public var scheme: OPNSessionProxyScheme
    public var host: String
    public var port: String
    public var username: String
    public var scope: OPNSessionProxyScope

    public init(
        isEnabled: Bool = false,
        scheme: OPNSessionProxyScheme = .http,
        host: String = "",
        port: String = "",
        username: String = "",
        scope: OPNSessionProxyScope = .everything
    ) {
        self.isEnabled = isEnabled
        self.scheme = scheme
        self.host = host
        self.port = port
        self.username = username
        self.scope = scope
    }

    public func routes(_ purpose: OPNSessionProxyPurpose) -> Bool {
        guard isEnabled else { return false }
        switch (scope, purpose) {
        case (.everything, _), (.catalogOnly, .catalog): return true
        case (.catalogOnly, .session): return false
        }
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
    private static let enabledKey = "OpenNOW.Stream.SessionProxyEnabled"
    private static let schemeKey = "OpenNOW.Stream.SessionProxyScheme"
    private static let hostKey = "OpenNOW.Stream.SessionProxyHost"
    private static let portKey = "OpenNOW.Stream.SessionProxyPort"
    private static let usernameKey = "OpenNOW.Stream.SessionProxyUsername"
    private static let scopeKey = "OpenNOW.Stream.SessionProxyScope"
    /// Builds before the keychain move kept the password beside the host and port, in a plist any
    /// process running as this user can read. The key survives so that copy can be migrated out and
    /// deleted; nothing writes to it any more.
    private static let legacyPlaintextPasswordKey = "OpenNOW.Stream.SessionProxyPassword"
    private static let keychainService = "OpenNOW.SessionProxy"
    private static let keychainAccount = "password"

    public static func load() -> OPNSessionProxySettings {
        let storage = OPNAppPreferenceStorage.standard
        let schemeRaw = storage.object(forKey: schemeKey) as? String ?? ""
        let scopeRaw = storage.object(forKey: scopeKey) as? String ?? ""
        return OPNSessionProxySettings(
            isEnabled: storage.bool(forKey: enabledKey),
            scheme: OPNSessionProxyScheme(rawValue: schemeRaw) ?? .http,
            host: storage.object(forKey: hostKey) as? String ?? "",
            port: storage.object(forKey: portKey) as? String ?? "",
            username: storage.object(forKey: usernameKey) as? String ?? "",
            scope: OPNSessionProxyScope(rawValue: scopeRaw) ?? .everything
        )
    }

    public static func save(_ settings: OPNSessionProxySettings) {
        let storage = OPNAppPreferenceStorage.standard
        storage.set(settings.isEnabled, forKey: enabledKey)
        storage.set(settings.scheme.rawValue, forKey: schemeKey)
        storage.set(settings.host, forKey: hostKey)
        storage.set(settings.port, forKey: portKey)
        storage.set(settings.username, forKey: usernameKey)
        storage.set(settings.scope.rawValue, forKey: scopeKey)
    }

    public static func loadPassword() -> String {
        migrateLegacyPlaintextPasswordIfNeeded()
        return keychainPassword() ?? ""
    }

    /// Writes through to the keychain, so a `false` means this password was not stored and whatever
    /// was stored before is still what the proxy authenticates with — the settings card says so
    /// rather than showing a SAVE that silently kept the old secret.
    @discardableResult
    public static func savePassword(_ password: String) -> Bool {
        guard writeKeychainPassword(password) else { return false }
        OPNAppPreferenceStorage.standard.removeObject(forKey: legacyPlaintextPasswordKey)
        return true
    }

    /// A password left in the preferences by an earlier build is moved into the keychain and the
    /// plaintext copy deleted. When the keychain refuses the write the copy stays put and the move
    /// is retried on the next read: dropping it would break a working proxy, and the plaintext was
    /// already on disk. An empty value only drops the stale key — unlike an explicit `savePassword("")`,
    /// a migration is not the user asking to clear a secret, so it must not delete a keychain item.
    private static func migrateLegacyPlaintextPasswordIfNeeded() {
        let storage = OPNAppPreferenceStorage.standard
        guard let legacyPassword = storage.string(forKey: legacyPlaintextPasswordKey) else { return }
        guard !legacyPassword.isEmpty else {
            storage.removeObject(forKey: legacyPlaintextPasswordKey)
            return
        }
        guard writeKeychainPassword(legacyPassword) else {
            OpenNOWLog.warning(.auth, "Session proxy password could not be moved into the keychain; it stays in the preferences for now")
            return
        }
        storage.removeObject(forKey: legacyPlaintextPasswordKey)
    }

    private static func keychainQuery() -> CFDictionary {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ] as CFDictionary
    }

    private static func keychainPassword() -> String? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &item)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            OpenNOWLog.warning(.auth, "Session proxy password could not be read from the keychain (\(status))")
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func writeKeychainPassword(_ password: String) -> Bool {
        guard !password.isEmpty else {
            let status = SecItemDelete(keychainQuery())
            guard status == errSecSuccess || status == errSecItemNotFound else {
                logKeychainFailure("clear", status: status)
                return false
            }
            return true
        }
        let data = Data(password.utf8)
        let updateStatus = SecItemUpdate(keychainQuery(), [kSecValueData as String: data] as CFDictionary)
        guard updateStatus != errSecSuccess else { return true }
        // Only "not found" justifies an add; anything else is a real keychain failure, and adding on
        // top of it would mask the cause.
        guard updateStatus == errSecItemNotFound else {
            logKeychainFailure("update", status: updateStatus)
            return false
        }
        let addStatus = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ] as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            logKeychainFailure("add", status: addStatus)
            return false
        }
        return true
    }

    private static func logKeychainFailure(_ operation: String, status: OSStatus) {
        OpenNOWLog.warning(.auth, "Session proxy password keychain \(operation) failed (\(status))")
    }

    public static func configuration() -> OPNSessionProxyConfiguration? {
        let settings = load()
        guard settings.isEnabled else { return nil }
        return configuration(from: settings, password: loadPassword())
    }

    /// The proxy for one request, or nil when the request should connect directly — proxy off,
    /// configuration invalid, or a session request under `catalogOnly`.
    public static func configuration(for purpose: OPNSessionProxyPurpose) -> OPNSessionProxyConfiguration? {
        let settings = load()
        guard settings.routes(purpose) else { return nil }
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

    let lock = NSLock()
    private var state = State()
    private let now: @Sendable () -> TimeInterval

    public init(now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        self.now = now
    }

    public func controlPlaneURLSession(for purpose: OPNSessionProxyPurpose = .catalog) -> URLSession {
        guard let configuration = OPNSessionProxyStore.configuration(for: purpose) else { return .shared }
        lock.lock()
        let inCooldown = state.cooldownUntil > now()
        lock.unlock()
        guard !inCooldown else { return .shared }
        return session(for: configuration)
    }

    public func data(for request: URLRequest, purpose: OPNSessionProxyPurpose = .catalog) async throws -> (Data, URLResponse) {
        let session = controlPlaneURLSession(for: purpose)
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

    func session(for configuration: OPNSessionProxyConfiguration) -> URLSession {
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
