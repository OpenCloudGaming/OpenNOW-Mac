import Foundation
import Starfleet

public enum Jarvis: Sendable {
    public static let systemName = "Jarvis"
    public static let oauthLoggerName = "jarvis/o-auth"
    public static let oauthSpanName = "JarvisOAuth"
    public static let loginTelemetryName = "JARVIS_LOGIN"
    public static let logoutTelemetryName = "JARVIS_LOGOUT"
    public static let monitorLoginStatusTelemetryName = "JARVIS_MONITOR_LOGIN_STATUS"
    public static let defaultIdpId = "PDiAhv2kJTFeQ7WOPqiQ2tRZ7lGhR2X11dXvM4TZSxg"

    public static let operations: [Operation] = [
        .chainSession,
        .getDelegateToken,
        .getLoginToken,
        .getSessionToken,
        .getThirdPartyProviderInfo,
        .getUserInfo,
        .getUserToken,
        .redeemDelegateToken,
        .requestEmailVerify,
    ]
}

public extension Jarvis {
    enum Operation: String, CaseIterable, Sendable {
        case chainSession = "JARVIS_Chain_Session"
        case getDelegateToken = "JARVIS_Get_Delegate_Token"
        case getLoginToken = "JARVIS_Get_Login_Token"
        case getSessionToken = "JARVIS_Get_Session_Token"
        case getThirdPartyProviderInfo = "JARVIS_Get_Third_Party_Provider_Info"
        case getUserInfo = "JARVIS_Get_User_Info"
        case getUserToken = "JARVIS_Get_User_Token"
        case redeemDelegateToken = "JARVIS_Redeem_Delegate_Token"
        case requestEmailVerify = "JARVIS_Request_Email_Verify"
        case getPin = "JARVIS_Get_Pin"
        case setPin = "JARVIS_Set_Pin"
        case verifyPin = "JARVIS_Verify_Pin"
    }
}

public struct JarvisIdentity: Equatable, Sendable {
    public let userId: String
    public let externalUserId: String
    public let idpId: String

    public init(userId: String, externalUserId: String, idpId: String) {
        self.userId = userId
        self.externalUserId = externalUserId
        self.idpId = idpId
    }
}

public struct JarvisCredentials: Equatable, Sendable {
    public var email: String
    public var providerIdpId: String
    public var stayLoggedIn: Bool

    public init(email: String = "", providerIdpId: String = "", stayLoggedIn: Bool = true) {
        self.email = email
        self.providerIdpId = providerIdpId
        self.stayLoggedIn = stayLoggedIn
    }
}

public struct JarvisSession: Equatable, Sendable {
    public var accessToken: String
    public var idToken: String
    public var refreshToken: String
    public var userId: String
    public var displayName: String
    public var email: String
    public var membershipTier: String
    public var idpId: String
    public var expiresAt: Int64
    public var isAuthenticated: Bool
    public var clientToken: String
    public var clientTokenExpiry: Int64
    public var clientTokenExpiryLength: Int64
    public var idTokenExpiry: Int64
    public var accessTokenExpiry: Int64

    public init(
        accessToken: String = "",
        idToken: String = "",
        refreshToken: String = "",
        userId: String = "",
        displayName: String = "",
        email: String = "",
        membershipTier: String = "",
        idpId: String = "",
        expiresAt: Int64 = 0,
        isAuthenticated: Bool = false,
        clientToken: String = "",
        clientTokenExpiry: Int64 = 0,
        clientTokenExpiryLength: Int64 = 0,
        idTokenExpiry: Int64 = 0,
        accessTokenExpiry: Int64 = 0
    ) {
        self.accessToken = accessToken
        self.idToken = idToken
        self.refreshToken = refreshToken
        self.userId = userId
        self.displayName = displayName
        self.email = email
        self.membershipTier = membershipTier
        self.idpId = idpId
        self.expiresAt = expiresAt
        self.isAuthenticated = isAuthenticated
        self.clientToken = clientToken
        self.clientTokenExpiry = clientTokenExpiry
        self.clientTokenExpiryLength = clientTokenExpiryLength
        self.idTokenExpiry = idTokenExpiry
        self.accessTokenExpiry = accessTokenExpiry
    }

    public static func currentEpochMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000.0)
    }

    public var isClientTokenValid: Bool {
        !clientToken.isEmpty && clientTokenExpiry > Self.currentEpochMs()
    }

    public var isAccessTokenValid: Bool {
        !accessToken.isEmpty && accessTokenExpiry > Self.currentEpochMs()
    }

    public var hasAccessToken: Bool {
        !accessToken.isEmpty
    }

    public mutating func clear() {
        self = JarvisSession()
    }
}

public typealias JarvisOAuthState = StarfleetOAuthState
public typealias JarvisOAuthConfiguration = StarfleetOAuthConfiguration
public typealias JarvisOAuthRequestFactory = StarfleetOAuthRequestFactory

public enum JarvisSessionParser {
    public static func parseTokenResponse(_ json: [String: Any], now: Date = Date(), defaultIdpId: String = Jarvis.defaultIdpId) -> JarvisSession {
        let response = StarfleetTokenParser.parseTokenResponse(json, issuedAt: now)
        let claims = StarfleetTokenParser.jwtClaims(response.tokenSet.idToken)
        var session = JarvisSession()
        session.accessToken = response.tokenSet.accessToken
        session.idToken = response.tokenSet.idToken
        session.refreshToken = response.tokenSet.refreshToken
        session.clientToken = response.tokenSet.clientToken
        session.accessTokenExpiry = response.accessTokenExpiryMs
        session.expiresAt = response.expiresAtSeconds
        session.clientTokenExpiry = response.clientTokenExpiryMs
        session.clientTokenExpiryLength = response.clientTokenExpiryLengthMs
        if !session.idToken.isEmpty {
            session.idTokenExpiry = StarfleetTokenParser.idTokenExpiry(session.idToken)
            session.userId = claims["sub"] as? String ?? ""
            session.displayName = claims["name"] as? String ?? (claims["preferred_username"] as? String ?? "")
            session.email = claims["email"] as? String ?? ""
            session.membershipTier = claims["membership_tier"] as? String ?? "Free"
            session.idpId = claims["idp_id"] as? String ?? ""
        }
        if !session.idToken.isEmpty, session.membershipTier.isEmpty { session.membershipTier = "Free" }
        if session.idpId.isEmpty { session.idpId = defaultIdpId }
        if session.expiresAt == 0 {
            session.expiresAt = Int64(now.timeIntervalSince1970) + 86400
            session.accessTokenExpiry = Int64(now.timeIntervalSince1970 * 1000.0) + 86_400_000
        }
        session.isAuthenticated = !session.accessToken.isEmpty
        return session
    }

    public static func parseQueryString(_ query: String?) -> [String: String] {
        StarfleetTokenParser.parseQueryString(query)
    }

    public static func jwtClaims(_ idToken: String) -> [String: Any] {
        StarfleetTokenParser.jwtClaims(idToken)
    }

    public static func idTokenExpiry(_ idToken: String) -> Int64 {
        StarfleetTokenParser.idTokenExpiry(idToken)
    }

    public static func int64Value(_ value: Any?) -> Int64? {
        StarfleetTokenParser.int64Value(value)
    }
}
