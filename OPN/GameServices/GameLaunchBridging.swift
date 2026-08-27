//
//  GameLaunchBridging.swift
//  OpenNOW
//

import Foundation

@MainActor
protocol GameLaunchBridging {
    func prepareLaunchPlan(game: OPNCatalogGameObject, accessToken: String, idToken: String, userId: String, idpId: String, variantIndex: Int, completion: @escaping OPNGameLaunchPlanCompletion)
    func stopActiveSession(_ session: OPNActiveStreamSessionDescriptor, accessToken: String, completion: @escaping OPNGameLaunchSessionStopCompletion)
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
