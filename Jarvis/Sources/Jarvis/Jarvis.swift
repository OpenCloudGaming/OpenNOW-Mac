import Foundation

public enum Jarvis: Sendable {
    public static let systemName = "Jarvis"
    public static let oauthLoggerName = "jarvis/o-auth"
    public static let oauthSpanName = "JarvisOAuth"
    public static let loginTelemetryName = "JARVIS_LOGIN"
    public static let logoutTelemetryName = "JARVIS_LOGOUT"

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
