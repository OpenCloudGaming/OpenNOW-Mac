import Foundation

@MainActor
protocol GameLaunchBridging {
    /// `deviceId` is the launching account's own, so the seat's session lookup answers about that
    /// account rather than about the machine - two accounts stream under two device identities.
    func prepareLaunchPlan(game: OPNCatalogGameObject, accessToken: String, idToken: String, userId: String, idpId: String, variantIndex: Int, deviceId: String, completion: @escaping OPNGameLaunchPlanCompletion)
    func stopActiveSession(_ session: OPNActiveStreamSessionDescriptor, accessToken: String, deviceId: String, completion: @escaping OPNGameLaunchSessionStopCompletion)
}

protocol GameLaunchServiceConfiguring {
    func setAccessToken(_ token: String)
    func setAccountLinkingToken(_ token: String)
    func setUserId(_ id: String)
    func setVpcId(_ id: String)
    func resolveLaunchAppId(game: OPNGameInfo, variantIndex: Int, completion: @escaping OPNLaunchAppIdCallback)
}

extension OPNGameLaunchBridge: GameLaunchBridging {}
extension OPNGameService: GameLaunchServiceConfiguring {}
