import Foundation


public enum JarvisAuthStatus: String, CaseIterable, Sendable {
    case authorizationError = "AUTHORIZATION_ERROR"
    case unknown = "UNKNOWN"
    case loggedIn = "LOGGED_IN"
    case notLoggedIn = "NOT_LOGGED_IN"
    case pendingLogin = "PENDING_LOGIN"
}

public enum JarvisAuthType: String, CaseIterable, Sendable {
    case none = "NONE"
    case jwt = "JWT"
    case jwtGFN = "JWT_GFN"
    case jwtPartner = "JWT_PARTNER"
}

public protocol JarvisTelemetrySpan: Sendable {
    func setAttribute(_ key: String, value: String)
    func finish(success: Bool)
}

public protocol JarvisTelemetry: Sendable {
    func startSpan(name: String, operation: Jarvis.Operation?, attributes: [String: String]) -> JarvisTelemetrySpan
    func recordBreadcrumb(_ message: String, attributes: [String: String])
    func recordCounter(name: String, attributes: [String: String])
    func recordError(_ error: Error, operation: Jarvis.Operation?, attributes: [String: String])
}

public struct JarvisNoOpTelemetry: JarvisTelemetry {
    public init() {}

    public func startSpan(name: String, operation: Jarvis.Operation?, attributes: [String: String]) -> JarvisTelemetrySpan {
        _ = name
        _ = operation
        _ = attributes
        return JarvisNoOpTelemetrySpan()
    }

    public func recordBreadcrumb(_ message: String, attributes: [String: String]) {
        _ = message
        _ = attributes
    }

    public func recordCounter(name: String, attributes: [String: String]) {
        _ = name
        _ = attributes
    }

    public func recordError(_ error: Error, operation: Jarvis.Operation?, attributes: [String: String]) {
        _ = error
        _ = operation
        _ = attributes
    }
}

public struct JarvisNoOpTelemetrySpan: JarvisTelemetrySpan {
    public init() {}
    public func setAttribute(_ key: String, value: String) { _ = key; _ = value }
    public func finish(success: Bool) { _ = success }
}

public protocol JarvisSessionStore: Sendable {
    func loadSession() async throws -> JarvisSession
    func saveSession(_ session: JarvisSession) async throws
    func clearSession() async throws
    func loadUserInfo() async throws -> JarvisUserInfo
    func saveUserInfo(_ userInfo: JarvisUserInfo) async throws
    func clearUserInfo() async throws
}

public struct JarvisNoOpSessionStore: JarvisSessionStore {
    public init() {}
    public func loadSession() async throws -> JarvisSession { JarvisSession() }
    public func saveSession(_ session: JarvisSession) async throws { _ = session }
    public func clearSession() async throws {}
    public func loadUserInfo() async throws -> JarvisUserInfo { JarvisUserInfo() }
    public func saveUserInfo(_ userInfo: JarvisUserInfo) async throws { _ = userInfo }
    public func clearUserInfo() async throws {}
}

public actor JarvisInMemorySessionStore: JarvisSessionStore {
    private var storedSession: JarvisSession
    private var storedUserInfo: JarvisUserInfo

    public init(session: JarvisSession = JarvisSession(), userInfo: JarvisUserInfo = JarvisUserInfo()) {
        self.storedSession = session
        self.storedUserInfo = userInfo
    }

    public func loadSession() async throws -> JarvisSession { storedSession }
    public func saveSession(_ session: JarvisSession) async throws { storedSession = session }
    public func clearSession() async throws { storedSession = JarvisSession() }
    public func loadUserInfo() async throws -> JarvisUserInfo { storedUserInfo }
    public func saveUserInfo(_ userInfo: JarvisUserInfo) async throws { storedUserInfo = userInfo }
    public func clearUserInfo() async throws { storedUserInfo = JarvisUserInfo() }
}

public enum JarvisSessionPersistenceMode: String, CaseIterable, Sendable {
    case automatic = "AUTOMATIC"
    case manual = "MANUAL"
}

public enum JarvisAuthFailureCategory: String, CaseIterable, Sendable {
    case invalidRequest = "INVALID_REQUEST"
    case authorization = "AUTHORIZATION"
    case offline = "OFFLINE"
    case timeout = "TIMEOUT"
    case server = "SERVER"
    case rateLimited = "RATE_LIMITED"
    case unavailable = "UNAVAILABLE"
    case parsing = "PARSING"
    case missingData = "MISSING_DATA"
    case unknown = "UNKNOWN"
}

public struct JarvisRetryPolicy: Equatable, Sendable {
    public let maxRetries: Int
    public let baseDelayMs: UInt64
    public let retryableHTTPStatuses: Set<Int>

    public init(maxRetries: Int = 1, baseDelayMs: UInt64 = 250, retryableHTTPStatuses: Set<Int> = [408, 425, 429, 500, 502, 503, 504]) {
        self.maxRetries = max(0, maxRetries)
        self.baseDelayMs = baseDelayMs
        self.retryableHTTPStatuses = retryableHTTPStatuses
    }

    public static let gfnPC = JarvisRetryPolicy()

    public func shouldRetry(_ error: JarvisAuthError, attempt: Int) -> Bool {
        guard attempt < maxRetries else { return false }
        return switch error {
        case .httpStatus(let status): retryableHTTPStatuses.contains(status)
        case .transportFailure(_, let category): category == .timeout || category == .offline || category == .unavailable
        default: false
        }
    }

    public func delayNanoseconds(forAttempt attempt: Int) -> UInt64 {
        guard baseDelayMs > 0 else { return 0 }
        let multiplier = UInt64(max(1, attempt + 1))
        return baseDelayMs * multiplier * 1_000_000
    }
}

public struct JarvisAuthToken: Equatable, Sendable {
    public let tokenType: JarvisAuthType
    public let token: String
    public let userId: String
    public let externalUserId: String
    public let idpId: String

    public init(tokenType: JarvisAuthType, token: String, userId: String = "", externalUserId: String = "", idpId: String = "") {
        self.tokenType = tokenType
        self.token = token
        self.userId = userId
        self.externalUserId = externalUserId
        self.idpId = idpId
    }
}

public struct JarvisUserInfo: Equatable, Sendable {
    public var userId: String
    public var externalId: String
    public var idpId: String
    public var idpName: String
    public var preferredUsername: String
    public var displayName: String
    public var email: String
    public var consent: [String: String]
    public var isAuthenticated: Bool
    public var isNetworkCall: Bool

    public init(
        userId: String = "",
        externalId: String = "",
        idpId: String = "",
        idpName: String = "",
        preferredUsername: String = "",
        displayName: String = "",
        email: String = "",
        consent: [String: String] = [:],
        isAuthenticated: Bool = false,
        isNetworkCall: Bool = false
    ) {
        self.userId = userId
        self.externalId = externalId
        self.idpId = idpId
        self.idpName = idpName
        self.preferredUsername = preferredUsername
        self.displayName = displayName
        self.email = email
        self.consent = consent
        self.isAuthenticated = isAuthenticated
        self.isNetworkCall = isNetworkCall
    }
}

public struct JarvisConsentBlock: Equatable, Sendable {
    public var userId: String
    public var externalUserId: String
    public var idpId: String
    public var userConsent: [String: String]

    public init(userId: String = "", externalUserId: String = "", idpId: String = "", userConsent: [String: String] = [:]) {
        self.userId = userId
        self.externalUserId = externalUserId
        self.idpId = idpId
        self.userConsent = userConsent
    }
}

public struct JarvisDelegateToken: Equatable, Sendable {
    public var token: String
    public var userId: String
    public var expiresIn: String

    public init(token: String = "", userId: String = "", expiresIn: String = "") {
        self.token = token
        self.userId = userId
        self.expiresIn = expiresIn
    }
}

public struct JarvisProviderInfo: Equatable, Sendable {
    public var idpId: String
    public var providerName: String
    public var loginProvider: String
    public var loginProviderCode: String
    public var loginRequired: Bool
    public var preferredProviders: [String]
    public var isAffiliate: Bool

    public init(idpId: String = "", providerName: String = "", loginProvider: String = "", loginProviderCode: String = "", loginRequired: Bool = false, preferredProviders: [String] = [], isAffiliate: Bool = false) {
        self.idpId = idpId
        self.providerName = providerName
        self.loginProvider = loginProvider
        self.loginProviderCode = loginProviderCode
        self.loginRequired = loginRequired
        self.preferredProviders = preferredProviders
        self.isAffiliate = isAffiliate
    }
}

public struct JarvisPinStatus: Equatable, Sendable {
    public var isSet: Bool
    public var isVerified: Bool
    public var attemptsRemaining: Int
    public var challengeId: String
    public var message: String

    public init(isSet: Bool = false, isVerified: Bool = false, attemptsRemaining: Int = 0, challengeId: String = "", message: String = "") {
        self.isSet = isSet
        self.isVerified = isVerified
        self.attemptsRemaining = attemptsRemaining
        self.challengeId = challengeId
        self.message = message
    }
}

public struct JarvisEmailVerificationStatus: Equatable, Sendable {
    public var email: String
    public var requested: Bool
    public var status: String
    public var message: String

    public init(email: String = "", requested: Bool = false, status: String = "", message: String = "") {
        self.email = email
        self.requested = requested
        self.status = status
        self.message = message
    }
}

public struct JarvisOAuthWindowParameters: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var left: Int
    public var top: Int
    public var resizable: Bool
    public var scrollbars: Bool

    public init(width: Int = 480, height: Int = 720, left: Int = 0, top: Int = 0, resizable: Bool = true, scrollbars: Bool = true) {
        self.width = width
        self.height = height
        self.left = left
        self.top = top
        self.resizable = resizable
        self.scrollbars = scrollbars
    }

    public var featureString: String {
        [
            "width=\(width)",
            "height=\(height)",
            "left=\(left)",
            "top=\(top)",
            "resizable=\(resizable ? "yes" : "no")",
            "scrollbars=\(scrollbars ? "yes" : "no")",
        ].joined(separator: ",")
    }
}

public struct JarvisOAuthLoginRequest: Equatable, Sendable {
    public let url: URL
    public let popUpWindowName: String
    public let windowParameters: JarvisOAuthWindowParameters
    public let useAppURL: Bool
    public let state: JarvisOAuthState

    public init(url: URL, popUpWindowName: String = "app_oauth_window_with_back_button", windowParameters: JarvisOAuthWindowParameters = JarvisOAuthWindowParameters(), useAppURL: Bool = false, state: JarvisOAuthState) {
        self.url = url
        self.popUpWindowName = popUpWindowName
        self.windowParameters = windowParameters
        self.useAppURL = useAppURL
        self.state = state
    }
}

public struct JarvisOAuthCallback: Equatable, Sendable {
    public let code: String
    public let state: String
    public let error: String
    public let errorDescription: String

    public init(code: String = "", state: String = "", error: String = "", errorDescription: String = "") {
        self.code = code
        self.state = state
        self.error = error
        self.errorDescription = errorDescription
    }

    public var isSuccess: Bool { !code.isEmpty && error.isEmpty && errorDescription.isEmpty }
    public var resolvedError: String { errorDescription.isEmpty ? error : errorDescription }
}

public struct JarvisOperationRequest: Equatable, Sendable {
    public let operation: Jarvis.Operation
    public let parameters: [String: String]

    public init(operation: Jarvis.Operation, parameters: [String: String] = [:]) {
        self.operation = operation
        self.parameters = parameters
    }
}

public enum JarvisOperationFactory {
    public static func chainSession(sessionId: String) -> JarvisOperationRequest {
        JarvisOperationRequest(operation: .chainSession, parameters: ["sessionId": sessionId])
    }

    public static func getDelegateToken(userId: String = "") -> JarvisOperationRequest {
        JarvisOperationRequest(operation: .getDelegateToken, parameters: userId.isEmpty ? [:] : ["userId": userId])
    }

    public static func getLoginToken(email: String = "") -> JarvisOperationRequest {
        JarvisOperationRequest(operation: .getLoginToken, parameters: email.isEmpty ? [:] : ["email": email])
    }

    public static func getSessionToken(userId: String = "") -> JarvisOperationRequest {
        JarvisOperationRequest(operation: .getSessionToken, parameters: userId.isEmpty ? [:] : ["userId": userId])
    }

    public static func getThirdPartyProviderInfo(idpId: String) -> JarvisOperationRequest {
        JarvisOperationRequest(operation: .getThirdPartyProviderInfo, parameters: ["idpId": idpId])
    }

    public static func getUserInfo(userId: String = "") -> JarvisOperationRequest {
        JarvisOperationRequest(operation: .getUserInfo, parameters: userId.isEmpty ? [:] : ["userId": userId])
    }

    public static func getUserToken(userId: String = "") -> JarvisOperationRequest {
        JarvisOperationRequest(operation: .getUserToken, parameters: userId.isEmpty ? [:] : ["userId": userId])
    }

    public static func redeemDelegateToken(delegateToken: String) -> JarvisOperationRequest {
        JarvisOperationRequest(operation: .redeemDelegateToken, parameters: ["delegateToken": delegateToken])
    }

    public static func requestEmailVerify(email: String) -> JarvisOperationRequest {
        JarvisOperationRequest(operation: .requestEmailVerify, parameters: ["email": email])
    }

    public static func getPin(userId: String = "") -> JarvisOperationRequest {
        JarvisOperationRequest(operation: .getPin, parameters: userId.isEmpty ? [:] : ["userId": userId])
    }

    public static func setPin(pin: String) -> JarvisOperationRequest {
        JarvisOperationRequest(operation: .setPin, parameters: ["pin": pin])
    }

    public static func verifyPin(pin: String) -> JarvisOperationRequest {
        JarvisOperationRequest(operation: .verifyPin, parameters: ["pin": pin])
    }
}

public protocol JarvisHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct JarvisURLSessionTransport: JarvisHTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await OPNURLSessionHTTPTransport.send(request, operation: "jarvis.http", invalidHTTPResponseError: JarvisAuthError.invalidHTTPResponse)
    }
}

public enum JarvisAuthError: LocalizedError, Equatable, Sendable {
    case invalidOAuthURL
    case invalidTokenURL
    case invalidUserInfoURL
    case invalidClientTokenURL
    case invalidOperationURL
    case invalidCallbackRequest
    case oauthError(String)
    case stateMismatch
    case missingAuthorizationCode
    case noSavedSession
    case noRefreshMechanism
    case invalidHTTPResponse
    case httpStatus(Int)
    case invalidJSONResponse
    case missingClientToken
    case missingAccessToken
    case missingDelegateToken

    case transportFailure(String, JarvisAuthFailureCategory)

    public var category: JarvisAuthFailureCategory {
        switch self {
        case .invalidOAuthURL, .invalidTokenURL, .invalidUserInfoURL, .invalidClientTokenURL, .invalidOperationURL, .invalidCallbackRequest, .stateMismatch, .missingAuthorizationCode:
            .invalidRequest
        case .oauthError, .noSavedSession, .noRefreshMechanism, .missingAccessToken:
            .authorization
        case .invalidHTTPResponse:
            .unavailable
        case .httpStatus(let status):
            Self.category(forHTTPStatus: status)
        case .invalidJSONResponse:
            .parsing
        case .missingClientToken, .missingDelegateToken:
            .missingData
        case .transportFailure(_, let category):
            category
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .httpStatus(let status): JarvisRetryPolicy.gfnPC.retryableHTTPStatuses.contains(status)
        case .transportFailure(_, let category): category == .timeout || category == .offline || category == .unavailable
        default: false
        }
    }

    public static func category(forHTTPStatus status: Int) -> JarvisAuthFailureCategory {
        switch status {
        case 400, 404, 409, 422: .invalidRequest
        case 401, 403: .authorization
        case 408: .timeout
        case 429: .rateLimited
        case 500...599: status == 503 || status == 504 ? .unavailable : .server
        default: .unknown
        }
    }

    public static func transportFailure(_ error: Error) -> JarvisAuthError {
        let nsError = error as NSError
        let category: JarvisAuthFailureCategory
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut:
                category = .timeout
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed, NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed:
                category = .offline
            default:
                category = .unavailable
            }
        } else {
            category = .unknown
        }
        return .transportFailure(error.localizedDescription, category)
    }

    public var errorDescription: String? {
        switch self {
        case .invalidOAuthURL: "Invalid OAuth URL"
        case .invalidTokenURL: "Invalid token URL"
        case .invalidUserInfoURL: "Invalid userinfo URL"
        case .invalidClientTokenURL: "Invalid client token URL"
        case .invalidOperationURL: "Invalid Jarvis operation URL"
        case .invalidCallbackRequest: "Invalid OAuth callback request"
        case .oauthError(let message): message
        case .stateMismatch: "State mismatch"
        case .missingAuthorizationCode: "Missing authorization code"
        case .noSavedSession: "No saved session available"
        case .noRefreshMechanism: "No refresh mechanism available"
        case .invalidHTTPResponse: "Invalid HTTP response"
        case .httpStatus(let status): "HTTP \(status)"
        case .invalidJSONResponse: "Invalid JSON response"
        case .missingClientToken: "No client_token in response"
        case .missingAccessToken: "Missing access token"
        case .missingDelegateToken: "No delegate token in response"
        case .transportFailure(let message, _): message
        }
    }
}
