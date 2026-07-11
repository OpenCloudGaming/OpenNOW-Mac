import Foundation

public enum NesAuth: Sendable {
    public static let systemName = "NES Auth"
    public static let componentName = "NesAuthComponent"
    public static let launcherComponentName = "NesAuthLauncherComponent"
    public static let errorComponentName = "NesAuthErrorComponent"
    public static let uiServiceName = "gfn/NesAuthUIService"
    public static let routeName = "nesAuth"
    public static let errorRouteName = "streamerError/nesAuthError"
    public static let telemetryOperationName = "NesAuthorization"
}

public struct NesAuthConfiguration: Equatable, Sendable {
    public let serverURLString: String
    public let version: String
    public let layoutServerURLString: String
    public let layoutServerVersion: String
    public let serviceName: String
    public let userAgent: String

    public init(
        serverURLString: String = "https://mes.geforcenow.com",
        version: String = "v4",
        layoutServerURLString: String = "https://pcs.geforcenow.com",
        layoutServerVersion: String = "v1",
        serviceName: String = "gfn_pc",
        userAgent: String = "NVIDIACEFClient/HEAD/debb5919f6 GFN-PC/2.0.80.173"
    ) {
        self.serverURLString = Self.normalizedBaseURL(serverURLString)
        self.version = version.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.layoutServerURLString = Self.normalizedBaseURL(layoutServerURLString)
        self.layoutServerVersion = layoutServerVersion.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.serviceName = serviceName
        self.userAgent = userAgent
    }

    public static let gfnPC = NesAuthConfiguration()

    private static func normalizedBaseURL(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return "" }
        return trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") ? trimmed : "https://\(trimmed)"
    }
}

public enum NesAuthRequestFactory {
    public static let swCacheBypassHeader = "x-sw-cachebypass"
    public static let swNotifyFetchHeader = "sw-notify-fetch"

    public static func request(operation: NesAuth.Operation, accessToken: String = "", parameters: [URLQueryItem] = [], configuration: NesAuthConfiguration = .gfnPC, timeoutInterval: TimeInterval = 15, bypassCache: Bool = false, notifyFetch: Bool = false) -> URLRequest? {
        let route = route(for: operation)
        var components = URLComponents(string: buildURL(path: route.path, useLayoutServer: route.useLayoutServer, configuration: configuration))
        var queryItems = [URLQueryItem(name: "serviceName", value: configuration.serviceName)]
        queryItems.append(contentsOf: parameters)
        components?.queryItems = queryItems
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeoutInterval)
        request.httpMethod = route.method
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        if !accessToken.isEmpty { request.setValue("GFNJWT \(accessToken)", forHTTPHeaderField: "Authorization") }
        if route.method != "GET" { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if bypassCache { request.setValue("true", forHTTPHeaderField: swCacheBypassHeader) }
        if notifyFetch { request.setValue("true", forHTTPHeaderField: swNotifyFetchHeader) }
        return request
    }

    public static func buildURL(path: String, useLayoutServer: Bool = false, configuration: NesAuthConfiguration = .gfnPC) -> String {
        let base = useLayoutServer ? configuration.layoutServerURLString : configuration.serverURLString
        let version = useLayoutServer ? configuration.layoutServerVersion : configuration.version
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        return "\(base)/\(version)\(normalizedPath)"
    }

    private static func route(for operation: NesAuth.Operation) -> (method: String, path: String, useLayoutServer: Bool) {
        return switch operation {
        case .getSubscriptions:
            ("GET", "/subscriptions", false)
        case .getClientStreamingQuality:
            ("GET", "/client/streaming-qualities", false)
        case .getServiceUrls:
            ("GET", "/serviceUrls", true)
        case .getProducts:
            ("GET", "/products", false)
        case .getCredits:
            ("GET", "/credits", false)
        case .getPlayTime:
            ("GET", "/playtime", false)
        case .getProductCredits:
            ("GET", "/productCredits", false)
        case .getApps:
            ("GET", "/apps", false)
        case .getResource:
            ("GET", "/resource", false)
        case .install:
            ("POST", "/apps/install", false)
        case .uninstall:
            ("DELETE", "/apps/uninstall", false)
        case .cancelSubscription:
            ("DELETE", "/subscriptions", false)
        case .updateSubscription:
            ("POST", "/subscriptions", false)
        case .nes:
            ("GET", "", false)
        }
    }
}

public protocol NesAuthHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct NesAuthURLSessionTransport: NesAuthHTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw NesAuthServiceError.invalidHTTPResponse }
        return (data, httpResponse)
    }
}

public enum NesAuthServiceError: LocalizedError, Equatable, Sendable {
    case invalidRequest(NesAuth.Operation)
    case invalidHTTPResponse
    case httpStatus(Int)
    case invalidJSONResponse

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let operation): "Invalid NES request for \(operation.rawValue)"
        case .invalidHTTPResponse: "Invalid NES HTTP response"
        case .httpStatus(let status): "NES HTTP status \(status)"
        case .invalidJSONResponse: "Invalid NES JSON response"
        }
    }
}

public struct NesAuthService<Transport: NesAuthHTTPTransport>: Sendable {
    private let configuration: NesAuthConfiguration
    private let transport: Transport

    public init(configuration: NesAuthConfiguration = .gfnPC, transport: Transport) {
        self.configuration = configuration
        self.transport = transport
    }

    public func fetchSubscriptions(accessToken: String, parameters: [URLQueryItem] = [], bypassCache: Bool = false, notifyFetch: Bool = false) async throws -> [String: Any] {
        try await perform(operation: .getSubscriptions, accessToken: accessToken, parameters: parameters, bypassCache: bypassCache, notifyFetch: notifyFetch)
    }

    public func fetchClientStreamingQuality(accessToken: String = "", parameters: [URLQueryItem] = []) async throws -> [String: Any] {
        try await perform(operation: .getClientStreamingQuality, accessToken: accessToken, parameters: parameters)
    }

    public func fetchServiceUrls(accessToken: String = "", parameters: [URLQueryItem] = []) async throws -> [String: Any] {
        try await perform(operation: .getServiceUrls, accessToken: accessToken, parameters: parameters)
    }

    public func perform(operation: NesAuth.Operation, accessToken: String = "", parameters: [URLQueryItem] = [], bypassCache: Bool = false, notifyFetch: Bool = false) async throws -> [String: Any] {
        guard let request = NesAuthRequestFactory.request(operation: operation, accessToken: accessToken, parameters: parameters, configuration: configuration, bypassCache: bypassCache, notifyFetch: notifyFetch) else { throw NesAuthServiceError.invalidRequest(operation) }
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else { throw NesAuthServiceError.httpStatus(response.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NesAuthServiceError.invalidJSONResponse }
        return json
    }
}

public extension NesAuth {
    enum Operation: String, CaseIterable, Sendable {
        case nes = "NES"
        case cancelSubscription = "NES_Cancel_Subscription"
        case getApps = "NES_Get_Apps"
        case getCredits = "NES_Get_Credits"
        case getPlayTime = "NES_Get_PlayTime"
        case getProductCredits = "NES_Get_Product_Credits"
        case getProducts = "NES_Get_Products"
        case getResource = "NES_Get_Resource"
        case getServiceUrls = "NES_Get_ServiceUrls"
        case getSubscriptions = "NES_Get_Subscriptions"
        case getClientStreamingQuality = "NES_GetClientStreamingQuality"
        case install = "NES_Install"
        case uninstall = "NES_Uninstall"
        case updateSubscription = "NES_Update_Subscription"
    }

    enum LaunchStatus: String, CaseIterable, Sendable {
        case failed = "NesAuthFailed"
        case notEntitled = "NesNotEntitled"
        case autoAuthorization = "NesAutoAuthorization"
    }

    enum ElementName: String, CaseIterable, Sendable {
        case auth = "gfn-nes-auth"
        case authError = "gfn-nes-auth-error"
        case authErrorDialog = "gfn-nes-auth-error-dialog"
        case authErrorLauncher = "gfn-nes-auth-error-launcher"
        case authLauncher = "gfn-nes-auth-launcher"
    }

    enum AuthorizationState: String, CaseIterable, Sendable {
        case pending = "PENDING"
        case authorized = "AUTHORIZED"
        case notEntitled = "NOT_ENTITLED"
        case failed = "FAILED"
    }
}

public struct NesAuthorizationResult: Equatable, Sendable {
    public let state: NesAuth.AuthorizationState
    public let errorCode: String

    public init(state: NesAuth.AuthorizationState, errorCode: String = "") {
        self.state = state
        self.errorCode = errorCode
    }

    public var launchStatus: NesAuth.LaunchStatus? {
        switch state {
        case .authorized:
            nil
        case .notEntitled:
            .notEntitled
        case .failed:
            .failed
        case .pending:
            nil
        }
    }
}

public struct NesAuthorizationPolicy: Equatable, Sendable {
    public let skipForJWTAuth: Bool
    public let autoAuthorizeWhenSkipped: Bool

    public init(skipForJWTAuth: Bool = true, autoAuthorizeWhenSkipped: Bool = true) {
        self.skipForJWTAuth = skipForJWTAuth
        self.autoAuthorizeWhenSkipped = autoAuthorizeWhenSkipped
    }

    public func result(authType: String, entitlementErrorCode: String = "") -> NesAuthorizationResult {
        let normalizedAuthType = authType.uppercased()
        if skipForJWTAuth, normalizedAuthType.contains("JWT") {
            return NesAuthorizationResult(state: autoAuthorizeWhenSkipped ? .authorized : .pending)
        }
        if entitlementErrorCode == "NVB_R_USER_IS_NOT_ENTITLED" || entitlementErrorCode == "351" {
            return NesAuthorizationResult(state: .notEntitled, errorCode: entitlementErrorCode)
        }
        if !entitlementErrorCode.isEmpty {
            return NesAuthorizationResult(state: .failed, errorCode: entitlementErrorCode)
        }
        return NesAuthorizationResult(state: .authorized)
    }
}
