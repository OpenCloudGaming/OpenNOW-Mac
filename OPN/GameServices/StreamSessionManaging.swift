//
//  StreamSessionManaging.swift
//  MacForceNow
//

import Foundation

protocol StreamSessionManaging {
    func setAccessToken(_ token: String)
    func setStreamingBaseUrl(_ url: String)
    func createSession(appId: String, internalTitle: String, settings: [String: Any], completion: @escaping (Bool, [String: Any], String) -> Void)
    func pollSession(sessionId: String, serverIp: String, completion: @escaping (Bool, [String: Any], String) -> Void)
    func getActiveSessions(completion: @escaping (Bool, [[String: Any]], String) -> Void)
    func reportSessionAd(session: [String: Any], adId: String, action: String, watchedTimeInMs: Int, pausedTimeInMs: Int, cancelReason: String, completion: @escaping (Bool, [String: Any], String) -> Void)
    func claimSession(sessionId: String, serverIp: String, appId: String, settings: [String: Any], recoveryMode: Bool, completion: @escaping (Bool, [String: Any], String) -> Void)
    func selectSessionLimitReuseEntry(_ sessions: [[String: Any]], requestedAppId: Int) -> [String: Any]?
}

extension OPNSessionManager: StreamSessionManaging {}
