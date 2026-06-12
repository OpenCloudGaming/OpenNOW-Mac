public enum Starfleet: Sendable {
    public static let systemName = "Starfleet"
    public static let loginBaseURLString = "https://login.nvidia.com"
    public static let defaultOrigin = "https://nvfile"
    public static let defaultReferer = "https://nvfile/"
    public static let defaultUserAgent = "NVIDIACEFClient/HEAD/debb5919f6 GFN-PC/2.0.80.173"
    public static let oauthScope = "openid consent email tk_client age"
}

public extension Starfleet {
    enum Endpoint: String, CaseIterable, Sendable {
        case authorize = "/authorize"
        case token = "/token"
        case userInfo = "/userinfo"
        case clientToken = "/client_token"
        case logout = "/logout"

        public var urlString: String { Starfleet.loginBaseURLString + rawValue }
    }

    enum GrantType: String, CaseIterable, Sendable {
        case authorizationCode = "authorization_code"
        case refreshToken = "refresh_token"
        case clientToken = "urn:ietf:params:oauth:grant-type:client_token"
    }
}

public struct StarfleetTokenSet: Equatable, Sendable {
    public let accessToken: String
    public let idToken: String
    public let refreshToken: String
    public let clientToken: String

    public init(accessToken: String, idToken: String, refreshToken: String, clientToken: String) {
        self.accessToken = accessToken
        self.idToken = idToken
        self.refreshToken = refreshToken
        self.clientToken = clientToken
    }
}
