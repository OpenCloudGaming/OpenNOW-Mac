import Foundation

/// Everything one session's requests authenticate with and are scoped by, carried per call rather
/// than parked on the manager: two accounts can stream at once, and a shared slot would let one
/// session's poll or ad report run on the other account's credentials.
struct StreamSessionRequestContext: Sendable, Equatable {
    let accessToken: String
    let streamingBaseURL: String
    /// The launching account's own device id. The seat allows one live session per device, so this
    /// is what keeps a second account from being refused as the same device as the first.
    let deviceId: String
}

protocol StreamSessionManaging {
    func createSession(appId: String, internalTitle: String, settings: [String: Any], context: StreamSessionRequestContext) async -> (Bool, [String: Any], String)
    func pollSession(sessionId: String, serverIp: String, context: StreamSessionRequestContext) async -> (Bool, [String: Any], String)
    func getActiveSessions(context: StreamSessionRequestContext) async -> (Bool, [[String: Any]], String)
    func reportSessionAd(session: [String: Any], adId: String, action: String, watchedTimeInMs: Int, pausedTimeInMs: Int, cancelReason: String, context: StreamSessionRequestContext) async -> (Bool, [String: Any], String)
    func claimSession(sessionId: String, serverIp: String, appId: String, settings: [String: Any], recoveryMode: Bool, context: StreamSessionRequestContext, completion: @escaping (Bool, [String: Any], String) -> Void)
    func selectSessionLimitReuseEntry(_ sessions: [[String: Any]], requestedAppId: Int) -> [String: Any]?
}

extension OPNSessionManager: StreamSessionManaging {}
