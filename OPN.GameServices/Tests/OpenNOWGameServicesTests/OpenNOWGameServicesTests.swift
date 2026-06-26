import Testing
import Foundation
import WebRTCMedia
@testable import OpenNOWGameServices

@Test func launchAppIdRejectsZeroAndInvalidValues() {
    #expect(OPNLaunchAppId.resolve("0") == nil)
    #expect(OPNLaunchAppId.resolve(" 0 ") == nil)
    #expect(OPNLaunchAppId.resolve("") == nil)
    #expect(OPNLaunchAppId.resolve("GFN-PC") == nil)
    #expect(OPNLaunchAppId.resolve("123")?.stringValue == "123")
    #expect(OPNLaunchAppId.resolve("123")?.intValue == 123)
}

@Test func streamCoordinatorRejectsZeroApplicationIdBeforeNetworkWork() async {
    let coordinator = OpenNOWStreamSessionCoordinator()
    let configuration = StreamLaunchConfiguration(
        title: "Invalid Launch",
        applicationID: "0",
        accessToken: "token",
        accountLinked: true,
        selectedStore: "Steam"
    )

    do {
        _ = try await coordinator.startSession(configuration: configuration)
        Issue.record("Expected coordinator to reject appId 0 before session allocation")
    } catch let error as OpenNOWStreamSessionError {
        #expect(error.errorDescription == "This game does not include a launchable GeForce NOW app id.")
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}

@Test func sessionManagerRejectsZeroBeforeTokenValidation() async {
    let result = await withCheckedContinuation { continuation in
        OPNSessionManager.shared.createSession(appId: "0", internalTitle: "Invalid Launch", settings: [:]) { success, _, error in
            continuation.resume(returning: (success, error))
        }
    }

    #expect(result.0 == false)
    #expect(result.1 == "This game does not include a launchable GeForce NOW app id.")
}

@Test func sessionManagerRejectsZeroClaimBeforeTokenValidation() async {
    let result = await withCheckedContinuation { continuation in
        OPNSessionManager.shared.claimSession(sessionId: "session", serverIp: "server", appId: "0", settings: [:], recoveryMode: false) { success, _, error in
            continuation.resume(returning: (success, error))
        }
    }

    #expect(result.0 == false)
    #expect(result.1 == "This game does not include a launchable GeForce NOW app id.")
}

@Test func activeSessionParserPreservesControlAndSignalingHosts() {
    let descriptor = OPNActiveSessionParser.descriptor(from: [
        "sessionId": "session-1",
        "status": 2,
        "gpuType": "L40",
        "sessionRequestData": ["appId": 123],
        "sessionControlInfo": ["ip": "control.example.test"],
        "connectionInfo": [[
            "usage": 14,
            "ip": "signaling.example.test",
            "port": 443,
            "resourcePath": "/nvst/",
        ]],
    ], streamingBaseUrl: "https://cloudmatch.example.test/")

    #expect(descriptor?.sessionId == "session-1")
    #expect(descriptor?.appId == 123)
    #expect(descriptor?.resumeServer == "control.example.test")
    #expect(descriptor?.signalingUrl == "wss://signaling.example.test:443/nvst/")
}

@Test func activeSessionParserKeepsZeroAppIdSessionForTermination() {
    let descriptor = OPNActiveSessionParser.descriptor(from: [
        "sessionId": "session-1",
        "status": 2,
        "sessionRequestData": ["appId": 0],
        "sessionControlInfo": ["ip": "control.example.test"],
    ], streamingBaseUrl: "https://cloudmatch.example.test/")

    #expect(descriptor?.sessionId == "session-1")
    #expect(descriptor?.appId == 0)
    #expect(descriptor?.resumeServer == "control.example.test")
}

@Test func activeSessionParserRejectsInitializingSessionForResume() {
    let descriptor = OPNActiveSessionParser.descriptor(from: [
        "sessionId": "session-1",
        "status": 1,
        "sessionRequestData": ["appId": 123],
        "sessionControlInfo": ["ip": "control.example.test"],
    ], streamingBaseUrl: "https://cloudmatch.example.test/")

    #expect(descriptor == nil)
}

@Test(.serialized) func activeSessionServiceFiltersMarkedUnresumableSession() async {
    let host = "active-session-filter.example.test"
    let sessionId = "filtered-session"
    OPNActiveSessionService.clearUnresumableSessions()
    OPNActiveSessionService.markSessionUnresumable(sessionId)
    SessionManagerURLProtocol.install(host: host) { request in
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/v2/session")
        return SessionManagerURLProtocol.response(json: activeSessionsResponse(sessionId: sessionId, sessionStatus: 2, controlHost: host))
    }
    defer {
        OPNActiveSessionService.clearUnresumableSessions()
        SessionManagerURLProtocol.uninstall(host: host)
    }

    let result = await withCheckedContinuation { continuation in
        OPNActiveSessionService.fetchActiveSessions(accessToken: "token", streamingBaseUrl: "https://\(host)") { success, sessions, error in
            continuation.resume(returning: (success, sessions.count, error))
        }
    }

    #expect(result.0 == true)
    #expect(result.1 == 0)
    #expect(result.2.isEmpty)
}

@Test func sessionManagerReadyResumeAttachesFromValidation() async {
    let host = "resume-ready.example.test"
    SessionManagerURLProtocol.install(host: host) { _ in
        SessionManagerURLProtocol.response(json: sessionResponse(statusCode: 1, sessionStatus: 2, controlHost: host))
    }
    defer { SessionManagerURLProtocol.uninstall(host: host) }

    OPNSessionManager.shared.setAccessToken("token")
    OPNSessionManager.shared.setStreamingBaseUrl("https://\(host)")

    let result = await withCheckedContinuation { continuation in
        OPNSessionManager.shared.claimSession(sessionId: "resume-session", serverIp: host, appId: "123", settings: minimalSettings(), recoveryMode: false) { success, info, error in
            continuation.resume(returning: (success, info["sessionId"] as? String ?? "", info["serverIp"] as? String ?? "", info["signalingUrl"] as? String ?? "", error))
        }
    }

    let requests = SessionManagerURLProtocol.recordedRequests(host: host)
    #expect(result.0 == true)
    #expect(result.1 == "resume-session")
    #expect(result.2 == host)
    #expect(result.3 == "wss://signaling.example.test:443/nvst/")
    #expect(result.4.isEmpty)
    #expect(requests.map(\.httpMethod) == ["GET"])
}

@Test func sessionManagerPausedResumeSendsExplicitPutBeforePolling() async {
    let host = "resume-success.example.test"
    let lock = NSLock()
    nonisolated(unsafe) var getCount = 0
    SessionManagerURLProtocol.install(host: host) { request in
        let path = request.url?.path ?? ""
        if request.httpMethod == "GET", path == "/v2/session/resume-session" {
            lock.lock()
            getCount += 1
            let count = getCount
            lock.unlock()
            return SessionManagerURLProtocol.response(json: sessionResponse(statusCode: 1, sessionStatus: count == 1 ? 6 : 2, controlHost: host))
        }
        if request.httpMethod == "PUT", path == "/v2/session/resume-session" {
            return SessionManagerURLProtocol.response(json: sessionResponse(statusCode: 1, sessionStatus: 6, controlHost: host))
        }
        return SessionManagerURLProtocol.response(json: sessionResponse(statusCode: 1, sessionStatus: 2, controlHost: host))
    }
    defer { SessionManagerURLProtocol.uninstall(host: host) }

    OPNSessionManager.shared.setAccessToken("token")
    OPNSessionManager.shared.setStreamingBaseUrl("https://\(host)")

    let result = await withCheckedContinuation { continuation in
        OPNSessionManager.shared.claimSession(sessionId: "resume-session", serverIp: host, appId: "123", settings: minimalSettings(), recoveryMode: false) { success, _, error in
            continuation.resume(returning: (success, error))
        }
    }

    let requests = SessionManagerURLProtocol.recordedRequests(host: host)
    let claimPayload = SessionManagerURLProtocol.recordedJSONBodies(host: host).first { $0["action"] != nil }
    let claimRequestData = claimPayload?["sessionRequestData"] as? [String: Any]
    #expect(result.0 == true)
    #expect(requests.map(\.httpMethod) == ["GET", "PUT", "GET"])
    #expect(claimPayload?["action"] as? Int == 2)
    #expect(claimPayload?["data"] as? String == "RESUME")
    #expect(claimRequestData?["appId"] as? Int == 123)
    #expect(claimRequestData?["clientIdentification"] as? String == "GFN-PC")
}

@Test func sessionManagerSessionNotPausedFallsBackToPolling() async {
    let host = "resume-not-paused.example.test"
    let lock = NSLock()
    nonisolated(unsafe) var getCount = 0
    SessionManagerURLProtocol.install(host: host) { request in
        let path = request.url?.path ?? ""
        if request.httpMethod == "GET", path == "/v2/session/resume-session" {
            lock.lock()
            getCount += 1
            let count = getCount
            lock.unlock()
            return SessionManagerURLProtocol.response(json: sessionResponse(statusCode: 1, sessionStatus: count == 1 ? 6 : 2, controlHost: host))
        }
        return SessionManagerURLProtocol.response(json: [
            "requestStatus": [
                "statusCode": 34,
                "statusDescription": "SESSION_NOT_PAUSED",
            ],
        ])
    }
    defer { SessionManagerURLProtocol.uninstall(host: host) }

    OPNSessionManager.shared.setAccessToken("token")
    OPNSessionManager.shared.setStreamingBaseUrl("https://\(host)")

    let result = await withCheckedContinuation { continuation in
        OPNSessionManager.shared.claimSession(sessionId: "resume-session", serverIp: host, appId: "123", settings: minimalSettings(), recoveryMode: false) { success, _, error in
            continuation.resume(returning: (success, error))
        }
    }

    let requests = SessionManagerURLProtocol.recordedRequests(host: host)
    #expect(result.0 == true)
    #expect(result.1.isEmpty)
    #expect(requests.map(\.httpMethod) == ["GET", "PUT", "GET"])
}

@Test(.serialized) func sessionManagerStaleInternalClaimErrorFailsWithoutPollingFallback() async {
    let host = "resume-stale-internal.example.test"
    UserDefaults.standard.set("resume-session", forKey: "OpenNOW.Stream.ActiveSessionId")
    SessionManagerURLProtocol.install(host: host) { request in
        let path = request.url?.path ?? ""
        if request.httpMethod == "GET", path == "/v2/session/resume-session" {
            return SessionManagerURLProtocol.response(json: sessionResponse(statusCode: 1, sessionStatus: 6, controlHost: host))
        }
        return SessionManagerURLProtocol.response(json: staleSessionResponse(), status: 400)
    }
    defer {
        UserDefaults.standard.removeObject(forKey: "OpenNOW.Stream.ActiveSessionId")
        OPNActiveSessionService.clearUnresumableSessions()
        SessionManagerURLProtocol.uninstall(host: host)
    }

    OPNSessionManager.shared.setAccessToken("token")
    OPNSessionManager.shared.setStreamingBaseUrl("https://\(host)")

    let result = await withCheckedContinuation { continuation in
        OPNSessionManager.shared.claimSession(sessionId: "resume-session", serverIp: host, appId: "123", settings: minimalSettings(), recoveryMode: false) { success, _, error in
            continuation.resume(returning: (success, error))
        }
    }

    let requests = SessionManagerURLProtocol.recordedRequests(host: host)
    #expect(result.0 == false)
    #expect(result.1 == "This GeForce NOW session is no longer resumable. End it and launch again.")
    #expect(UserDefaults.standard.string(forKey: "OpenNOW.Stream.ActiveSessionId") == nil)
    #expect(OPNActiveSessionService.isSessionUnresumable("resume-session"))
    #expect(requests.map(\.httpMethod) == ["GET", "PUT"])
}

@Test(.serialized) func sessionManagerSessionNotActiveClaimErrorMarksUnresumable() async {
    let host = "resume-not-active.example.test"
    let sessionId = "not-active-session"
    OPNActiveSessionService.clearUnresumableSessions()
    SessionManagerURLProtocol.install(host: host) { request in
        let path = request.url?.path ?? ""
        if request.httpMethod == "GET", path == "/v2/session/\(sessionId)" {
            return SessionManagerURLProtocol.response(json: sessionResponse(sessionId: sessionId, statusCode: 1, sessionStatus: 6, controlHost: host))
        }
        return SessionManagerURLProtocol.response(json: [
            "requestStatus": [
                "statusCode": 7,
                "statusDescription": "SESSION_NOT_ACTIVE",
            ],
        ], status: 400)
    }
    defer {
        OPNActiveSessionService.clearUnresumableSessions()
        SessionManagerURLProtocol.uninstall(host: host)
    }

    OPNSessionManager.shared.setAccessToken("token")
    OPNSessionManager.shared.setStreamingBaseUrl("https://\(host)")

    let result = await withCheckedContinuation { continuation in
        OPNSessionManager.shared.claimSession(sessionId: sessionId, serverIp: host, appId: "123", settings: minimalSettings(), recoveryMode: false) { success, _, error in
            continuation.resume(returning: (success, error))
        }
    }

    let requests = SessionManagerURLProtocol.recordedRequests(host: host)
    #expect(result.0 == false)
    #expect(result.1 == "This GeForce NOW session is no longer resumable. End it and launch again.")
    #expect(OPNActiveSessionService.isSessionUnresumable(sessionId))
    #expect(requests.map(\.httpMethod) == ["GET", "PUT"])
}

@Test(.serialized) func sessionManagerStaleInternalCreateErrorReturnsActionableMessage() async {
    let host = "create-stale-internal.example.test"
    SessionManagerURLProtocol.install(host: host) { request in
        #expect(request.httpMethod == "POST")
        return SessionManagerURLProtocol.response(json: staleSessionResponse(includeSessionId: false), status: 400)
    }
    defer { SessionManagerURLProtocol.uninstall(host: host) }

    let manager = OPNSessionManager()
    manager.setAccessToken("token")
    manager.setStreamingBaseUrl("https://\(host)")

    let result = await withCheckedContinuation { continuation in
        manager.createSession(appId: "123", internalTitle: "Test Game", settings: minimalSettings()) { success, _, error in
            continuation.resume(returning: (success, error))
        }
    }

    #expect(result.0 == false)
    #expect(result.1 == "This GeForce NOW session is no longer resumable. End it and launch again.")
}

@Test(.serialized) func sessionManagerStaleInternalCreateErrorStopsAndRetriesOnce() async {
    let host = "create-stale-retry.example.test"
    let staleHost = "create-stale-control.example.test"
    let lock = NSLock()
    nonisolated(unsafe) var postCount = 0
    SessionManagerURLProtocol.install(host: host) { request in
        #expect(request.httpMethod == "POST")
        lock.lock()
        postCount += 1
        let count = postCount
        lock.unlock()
        if count == 1 {
            return SessionManagerURLProtocol.response(json: staleSessionResponse(controlHost: staleHost), status: 400)
        }
        return SessionManagerURLProtocol.response(json: sessionResponse(sessionId: "new-session", statusCode: 1, sessionStatus: 2, controlHost: host))
    }
    SessionManagerURLProtocol.install(host: staleHost) { request in
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/v2/session/resume-session")
        return SessionManagerURLProtocol.response(json: ["requestStatus": ["statusCode": 1, "statusDescription": "SUCCESS"]])
    }
    defer {
        OPNActiveSessionService.clearUnresumableSessions()
        SessionManagerURLProtocol.uninstall(host: host)
        SessionManagerURLProtocol.uninstall(host: staleHost)
    }

    let manager = OPNSessionManager()
    manager.setAccessToken("token")
    manager.setStreamingBaseUrl("https://\(host)")

    let result = await withCheckedContinuation { continuation in
        manager.createSession(appId: "123", internalTitle: "Test Game", settings: minimalSettings()) { success, info, error in
            continuation.resume(returning: (success, info["sessionId"] as? String ?? "", error))
        }
    }

    let requests = SessionManagerURLProtocol.recordedRequests(host: host)
    #expect(result.0 == true)
    #expect(result.1 == "new-session")
    #expect(result.2.isEmpty)
    #expect(OPNActiveSessionService.isSessionUnresumable("resume-session"))
    #expect(requests.map(\.httpMethod) == ["POST", "POST"])
    #expect(SessionManagerURLProtocol.recordedRequests(host: staleHost).map(\.httpMethod) == ["DELETE"])
}

@Test func sessionManagerDoesNotSelectZeroAppIdSessionLimitEntry() {
    let selected = OPNSessionManager.shared.selectSessionLimitReuseEntry([[
        "sessionId": "stale-session",
        "appId": 0,
        "status": 2,
        "serverIp": "control.example.test",
    ]], requestedAppId: 123)

    #expect(selected == nil)
}

private func minimalSettings() -> [String: Any] {
    [
        "resolution": "1920x1080",
        "fps": 60,
        "codec": "h264",
        "colorQuality": "standard",
        "maxBitrateMbps": 50,
        "selectedStore": "Steam",
        "accountLinked": true,
        "gameLanguage": "en_US",
        "keyboardLayout": "us",
    ]
}

private func sessionResponse(sessionId: String = "resume-session", statusCode: Int, sessionStatus: Int, controlHost: String = "control.example.test") -> [String: Any] {
    [
        "requestStatus": [
            "statusCode": statusCode,
            "statusDescription": statusCode == 1 ? "SUCCESS" : "ERROR",
        ],
        "session": [
            "sessionId": sessionId,
            "status": sessionStatus,
            "gpuType": "L40",
            "sessionRequestData": ["appId": 123],
            "sessionControlInfo": ["ip": controlHost],
            "connectionInfo": [[
                "usage": 14,
                "ip": "signaling.example.test",
                "port": 443,
                "resourcePath": "/nvst/",
            ]],
            "monitorSettings": [[
                "widthInPixels": 1920,
                "heightInPixels": 1080,
                "framesPerSecond": 60,
                "dpi": 96,
            ]],
        ],
    ]
}

private func staleSessionResponse(includeSessionId: Bool = true, controlHost: String = "") -> [String: Any] {
    var session: [String: Any] = [
        "status": 4,
        "sessionRequestData": ["appId": 0],
    ]
    if includeSessionId {
        session["sessionId"] = "resume-session"
    }
    if !controlHost.isEmpty {
        session["sessionControlInfo"] = ["ip": controlHost]
    }
    return [
        "requestStatus": [
            "statusCode": 4,
            "statusDescription": "INTERNAL_ERROR_STATUS 8A8C0000",
        ],
        "session": session,
    ]
}

private func activeSessionsResponse(sessionId: String = "resume-session", sessionStatus: Int, controlHost: String = "control.example.test") -> [String: Any] {
    [
        "requestStatus": [
            "statusCode": 1,
            "statusDescription": "SUCCESS",
        ],
        "sessions": [[
            "sessionId": sessionId,
            "status": sessionStatus,
            "gpuType": "L40",
            "sessionRequestData": ["appId": 123],
            "sessionControlInfo": ["ip": controlHost],
            "connectionInfo": [[
                "usage": 14,
                "ip": "signaling.example.test",
                "port": 443,
                "resourcePath": "/nvst/",
            ]],
        ]],
    ]
}

private final class SessionManagerURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var requestsByHost: [String: [URLRequest]] = [:]
    nonisolated(unsafe) private static var bodiesByHost: [String: [Data]] = [:]
    nonisolated(unsafe) private static var installed = false

    static func install(host: String, handler: @escaping Handler) {
        lock.withLock {
            handlers[host] = handler
            requestsByHost[host] = []
            bodiesByHost[host] = []
            if !installed {
                URLProtocol.registerClass(Self.self)
                installed = true
            }
        }
    }

    static func uninstall(host: String) {
        lock.withLock {
            handlers[host] = nil
            requestsByHost[host] = nil
            bodiesByHost[host] = nil
            if handlers.isEmpty, installed {
                URLProtocol.unregisterClass(Self.self)
                installed = false
            }
        }
    }

    static func recordedRequests(host: String) -> [URLRequest] {
        lock.withLock { requestsByHost[host] ?? [] }
    }

    static func recordedJSONBodies(host: String) -> [[String: Any]] {
        lock.withLock { bodiesByHost[host] ?? [] }
            .compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    static func response(json: [String: Any], status: Int = 200) -> (Int, Data) {
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        return (status, data)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return lock.withLock { handlers[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let host = request.url?.host, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body = Self.bodyData(from: request)
        let handler = Self.lock.withLock { () -> Handler? in
            Self.requestsByHost[host, default: []].append(request)
            if let body { Self.bodiesByHost[host, default: []].append(body) }
            return Self.handlers[host]
        }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = handler(request)
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count < 0 { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }
}
