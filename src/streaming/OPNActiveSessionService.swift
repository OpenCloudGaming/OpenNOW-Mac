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
    private static let persistedSessionIdKey = "OpenNOW.ActiveSessionId"
    private static let nvClientId = "ec7e38d4-03af-4b58-b131-cfb0495903ab"
    private static let nvClientVersion = "2.0.80.173"

    static func loadPersistedActiveSessionId() -> String {
        UserDefaults.standard.string(forKey: persistedSessionIdKey) ?? ""
    }

    static func clearPersistedActiveSessionId(_ sessionId: String = "") {
        let current = loadPersistedActiveSessionId()
        guard sessionId.isEmpty || current == sessionId else { return }
        UserDefaults.standard.removeObject(forKey: persistedSessionIdKey)
    }

    static func fetchActiveSessions(accessToken: String, completion: @escaping @Sendable (Bool, [OPNActiveSessionObject], String) -> Void) {
        guard !accessToken.isEmpty else {
            completion(false, [], "No access token")
            return
        }
        let base = normalizedBaseURL(OPNStreamPreferences.loadSelectedStreamingBaseUrl())
        guard let url = URL(string: base + "v2/session") else {
            completion(false, [], "Invalid sessions URL")
            return
        }
        var request = URLRequest(url: url)
        request.setValue(userAgent(), forHTTPHeaderField: "User-Agent")
        request.setValue("GFNJWT \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(nvClientId, forHTTPHeaderField: "nv-client-id")
        request.setValue("NATIVE", forHTTPHeaderField: "nv-client-type")
        request.setValue(nvClientVersion, forHTTPHeaderField: "nv-client-version")
        request.setValue("NVIDIA-CLASSIC", forHTTPHeaderField: "nv-client-streamer")
        request.setValue("MACOS", forHTTPHeaderField: "nv-device-os")
        request.setValue("DESKTOP", forHTTPHeaderField: "nv-device-type")
        request.setValue("UNKNOWN", forHTTPHeaderField: "nv-device-make")
        request.setValue("UNKNOWN", forHTTPHeaderField: "nv-device-model")
        request.setValue("CHROME", forHTTPHeaderField: "nv-browser-type")
        request.setValue(OPNDeviceIdentity.stableCloudmatchDeviceId(), forHTTPHeaderField: "x-device-id")
        URLSession.shared.dataTask(with: request) { data, response, error in
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
            let requestStatus = json["requestStatus"] as? [String: Any]
            guard (requestStatus?["statusCode"] as? NSNumber)?.intValue == 1 else {
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
        let base = normalizedBaseURL(OPNStreamPreferences.loadSelectedStreamingBaseUrl())
        guard let encodedSessionId = sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), let url = URL(string: base + "v2/session/" + encodedSessionId) else {
            completion(false, "Invalid stop session URL")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(userAgent(), forHTTPHeaderField: "User-Agent")
        request.setValue("GFNJWT \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(nvClientId, forHTTPHeaderField: "nv-client-id")
        request.setValue("NATIVE", forHTTPHeaderField: "nv-client-type")
        request.setValue(nvClientVersion, forHTTPHeaderField: "nv-client-version")
        request.setValue("NVIDIA-CLASSIC", forHTTPHeaderField: "nv-client-streamer")
        request.setValue("MACOS", forHTTPHeaderField: "nv-device-os")
        request.setValue("DESKTOP", forHTTPHeaderField: "nv-device-type")
        request.setValue("UNKNOWN", forHTTPHeaderField: "nv-device-make")
        request.setValue("UNKNOWN", forHTTPHeaderField: "nv-device-model")
        request.setValue("CHROME", forHTTPHeaderField: "nv-browser-type")
        request.setValue(OPNDeviceIdentity.stableCloudmatchDeviceId(), forHTTPHeaderField: "x-device-id")
        let trace = OPNSentry.traceHTTPRequest(NSMutableURLRequest(url: url), name: "Cloudmatch stop session")
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                trace?.setStatus(false)
                trace?.finish()
                completion(false, error.localizedDescription)
                return
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                trace?.setStatus(false)
                trace?.finish()
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                completion(false, "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0): \(body)")
                return
            }
            trace?.setStatus(true)
            trace?.finish()
            completion(true, "")
        }.resume()
    }

    private static func activeSession(from dictionary: [String: Any], streamingBaseUrl: String) -> OPNActiveSessionObject? {
        let sessionId = string(dictionary["sessionId"])
        let status = int(dictionary["status"])
        let requestData = dictionary["sessionRequestData"] as? [String: Any]
        let appId = int(requestData?["appId"])
        var streamingHost = ""
        for item in dictionary["connectionInfo"] as? [[String: Any]] ?? [] {
            guard int(item["usage"]) == 14 else { continue }
            let ip = string(item["ip"])
            if isUsableEndpointHost(ip) {
                streamingHost = ip
                break
            }
            let resourcePath = string(item["resourcePath"])
            if let host = URL(string: resourcePath)?.host, !host.isEmpty {
                streamingHost = host
                break
            }
        }
        let controlInfo = dictionary["sessionControlInfo"] as? [String: Any]
        let controlHost = string(controlInfo?["ip"])
        let serverIp = controlHost.isEmpty ? streamingHost : controlHost
        guard !sessionId.isEmpty, !serverIp.isEmpty, reusableStatuses.contains(status) else { return nil }
        let signalingUrl = streamingHost.isEmpty ? "" : "wss://\(streamingHost):443/nvst/"
        return OPNActiveSessionObject(sessionId: sessionId, appId: appId, status: status, serverIp: serverIp, streamingBaseUrl: streamingBaseUrl, signalingUrl: signalingUrl)
    }

    private static let reusableStatuses: Set<Int> = [1, 2, 3, 6]

    private static func normalizedBaseURL(_ value: String) -> String {
        let raw = value.isEmpty ? OPNStreamPreferences.defaultStreamingBaseUrl : value
        var normalized = raw.hasPrefix("http://") || raw.hasPrefix("https://") ? raw : "https://\(raw)"
        if !normalized.hasSuffix("/") { normalized += "/" }
        return normalized
    }

    private static func isUsableEndpointHost(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !trimmed.contains("/")
    }

    private static func userAgent() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info["CFBundleVersion"] as? String ?? "0"
        return "OpenNOW/\(version).\(build)"
    }

    private static func string(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }

    private static func int(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }
}
