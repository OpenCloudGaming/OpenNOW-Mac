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

public extension NesAuth {
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
}
