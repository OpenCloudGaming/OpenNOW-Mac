import Foundation


@objc(OPNActiveSessionObject)
@objcMembers
final class OPNActiveSessionObject: NSObject {
    let sessionId: String
    let appId: Int
    let status: Int
    let serverIp: String
    let streamingBaseUrl: String
    let signalingUrl: String

    init(sessionId: String, appId: Int, status: Int, serverIp: String, streamingBaseUrl: String, signalingUrl: String) {
        self.sessionId = sessionId
        self.appId = appId
        self.status = status
        self.serverIp = serverIp
        self.streamingBaseUrl = streamingBaseUrl
        self.signalingUrl = signalingUrl
        super.init()
    }
}

enum OPNActiveSessionService {
    private static let persistedSessionIdKey = "OpenNOW.Stream.ActiveSessionId"

    static func loadPersistedActiveSessionId() -> String {
        UserDefaults.standard.string(forKey: persistedSessionIdKey) ?? ""
    }

    static func clearPersistedActiveSessionId(_ sessionId: String = "") {
        let current = loadPersistedActiveSessionId()
        guard sessionId.isEmpty || current == sessionId else { return }
        UserDefaults.standard.removeObject(forKey: persistedSessionIdKey)
    }

    static func fetchActiveSessions(accessToken: String, streamingBaseUrl: String = OPNStreamPreferences.loadSelectedStreamingBaseUrl(), completion: @escaping @Sendable (Bool, [OPNActiveSessionObject], String) -> Void) {
        guard !accessToken.isEmpty else {
            completion(false, [], "No access token")
            return
        }
        let base = normalizedBaseURL(streamingBaseUrl)
        guard var request = CloudMatchRequestFactory.activeSessionsRequest(baseURLString: base, accessToken: accessToken, deviceId: OPNDeviceIdentity.stableCloudmatchDeviceId()) else {
            completion(false, [], "Invalid sessions URL")
            return
        }
        let networkStart = OPNNetworkLog.start(&request, operation: "activeSession.fetch")
        let tracedRequest = request
        URLSession.shared.dataTask(with: tracedRequest) { data, response, error in
            OPNNetworkLog.finish(tracedRequest, operation: "activeSession.fetch", startedAt: networkStart, data: data, response: response, error: error)
            if let error {
                completion(false, [], error.localizedDescription)
                return
            }
            guard let data else {
                completion(false, [], "No active sessions response")
                return
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                completion(false, [], "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(false, [], "Failed to parse sessions response")
                return
            }
            guard CloudMatchResponseParser.requestSucceeded(json) else {
                completion(false, [], "API error from sessions endpoint")
                return
            }
            let sessions = (json["sessions"] as? [[String: Any]] ?? []).compactMap { activeSession(from: $0, streamingBaseUrl: base) }
            completion(true, sessions, "")
        }.resume()
    }

    static func stopSession(accessToken: String, sessionId: String, serverIp: String, completion: @escaping @Sendable (Bool, String) -> Void) {
        guard !accessToken.isEmpty else {
            completion(false, "No access token")
            return
        }
        guard !sessionId.isEmpty else {
            completion(false, "No session id")
            return
        }
        clearPersistedActiveSessionId(sessionId)
        let base = normalizedBaseURL(serverIp.isEmpty ? OPNStreamPreferences.loadSelectedStreamingBaseUrl() : serverIp)
        guard var request = CloudMatchRequestFactory.stopSessionRequest(baseURLString: base, sessionId: sessionId, accessToken: accessToken, deviceId: OPNDeviceIdentity.stableCloudmatchDeviceId()) else {
            completion(false, "Invalid stop session URL")
            return
        }
        let networkStart = OPNNetworkLog.start(&request, operation: "activeSession.stop")
        let tracedRequest = request
        URLSession.shared.dataTask(with: tracedRequest) { data, response, error in
            OPNNetworkLog.finish(tracedRequest, operation: "activeSession.stop", startedAt: networkStart, data: data, response: response, error: error)
            if let error {
                completion(false, error.localizedDescription)
                return
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                completion(false, "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0): \(body)")
                return
            }
            completion(true, "")
        }.resume()
    }

    private static func activeSession(from dictionary: [String: Any], streamingBaseUrl: String) -> OPNActiveSessionObject? {
        guard let descriptor = CloudMatchActiveSessionParser.descriptor(from: dictionary, streamingBaseURL: streamingBaseUrl) else { return nil }
        return OPNActiveSessionObject(sessionId: descriptor.sessionId, appId: descriptor.appId, status: descriptor.status, serverIp: descriptor.resumeServer, streamingBaseUrl: descriptor.streamingBaseURL, signalingUrl: descriptor.signalingURL)
    }

    private static func normalizedBaseURL(_ value: String) -> String {
        let raw = value.isEmpty ? OPNStreamPreferences.defaultStreamingBaseUrl : value
        var normalized = raw.hasPrefix("http://") || raw.hasPrefix("https://") ? raw : "https://\(raw)"
        if !normalized.hasSuffix("/") { normalized += "/" }
        return normalized
    }

}
