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
