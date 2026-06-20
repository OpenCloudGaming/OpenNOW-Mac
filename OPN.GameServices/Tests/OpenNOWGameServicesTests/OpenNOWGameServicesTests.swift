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

@Test func sessionManagerReadyResumeSendsExplicitPutBeforePolling() async {
    let host = "resume-success.example.test"
    SessionManagerURLProtocol.install(host: host) { request in
        let path = request.url?.path ?? ""
        if request.httpMethod == "GET", path == "/v2/session/resume-session" {
            return SessionManagerURLProtocol.response(json: sessionResponse(statusCode: 1, sessionStatus: 2, controlHost: host))
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
    #expect(claimPayload?["data"] as? String == "RESUME")
    #expect(claimRequestData?["appId"] as? Int == 123)
}

@Test func sessionManagerSessionNotPausedFailsWithoutPollingFallback() async {
    let host = "resume-not-paused.example.test"
    SessionManagerURLProtocol.install(host: host) { request in
        let path = request.url?.path ?? ""
        if request.httpMethod == "GET", path == "/v2/session/resume-session" {
            return SessionManagerURLProtocol.response(json: sessionResponse(statusCode: 1, sessionStatus: 2, controlHost: host))
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
    #expect(result.0 == false)
    #expect(result.1 == "Session is not paused and cannot be resumed.")
    #expect(requests.map(\.httpMethod) == ["GET", "PUT"])
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

private func sessionResponse(statusCode: Int, sessionStatus: Int, controlHost: String = "control.example.test") -> [String: Any] {
    [
        "requestStatus": [
            "statusCode": statusCode,
            "statusDescription": statusCode == 1 ? "SUCCESS" : "ERROR",
        ],
        "session": [
            "sessionId": "resume-session",
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
