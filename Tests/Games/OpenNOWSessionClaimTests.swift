//  Claiming and resuming an existing seat session, and the errors that can come back
//  instead. Split out of OpenNOWSessionManagerTests.swift.
//

import Testing
import Foundation
@testable import OpenNOW

@Test func sessionManagerPausedResumeSendsExplicitPutBeforePolling() async {
    await networkTestIsolationLock.withLock {
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
            return SessionManagerURLProtocol.response(json: sessionResponse(statusCode: 1, sessionStatus: count == 1 ? 5 : 2, controlHost: host))
        }
        if request.httpMethod == "PUT", path == "/v2/session/resume-session" {
            return SessionManagerURLProtocol.response(json: sessionResponse(statusCode: 1, sessionStatus: 6, controlHost: host))
        }
        return SessionManagerURLProtocol.response(json: sessionResponse(statusCode: 1, sessionStatus: 2, controlHost: host))
    }
    defer { SessionManagerURLProtocol.uninstall(host: host) }

    OPNSessionManager.shared.setAccessToken("token")
    OPNSessionManager.shared.setStreamingBaseUrl("https://\(host)")
    var settings = minimalSettings()
    settings["resolution"] = "7680x4320"

    let result = await withCheckedContinuation { continuation in
        OPNSessionManager.shared.claimSession(sessionId: "resume-session", serverIp: host, appId: "123", settings: settings, recoveryMode: false) { success, _, error in
            continuation.resume(returning: (success, error))
        }
    }

    let requests = SessionManagerURLProtocol.recordedRequests(host: host)
    let claimRequest = requests.first { $0.httpMethod == "PUT" }
    let claimPayload = SessionManagerURLProtocol.recordedJSONBodies(host: host).first { $0["action"] != nil }
    let claimRequestData = claimPayload?["sessionRequestData"] as? [String: Any]
    let claimMetadata = claimRequestData?["metaData"] as? [[String: String]] ?? []
    #expect(result.0 == true)
    #expect(requests.map(\.httpMethod) == ["GET", "PUT", "GET"])
    #expect(claimRequest?.value(forHTTPHeaderField: "nv-client-streamer") == "NVIDIA-CLASSIC")
    #expect(claimRequest?.value(forHTTPHeaderField: "nv-client-version") == GFNClientMetadata.appVersion)
    #expect(claimRequest?.value(forHTTPHeaderField: "nv-client-type") == "NATIVE")
    #expect(claimPayload?["action"] as? Int == 2)
    #expect(claimPayload?["data"] as? String == "RESUME")
    #expect(claimRequestData?["appId"] as? Int == 123)
    #expect(claimRequestData?["clientPlatformName"] as? String == "browser")
    #expect(claimRequestData?["clientIdentification"] as? String == "GFN-PC")
    #expect(claimRequestData?["accountLinked"] as? Bool == true)
    #expect(claimRequestData?["clientDisplayHdrCapabilities"] is NSNull)
    #expect(claimRequestData?["enablePersistingInGameSettings"] as? Bool == false)
    #expect(claimRequestData?["partnerCustomData"] as? String == "")
    #expect(claimRequestData?["userAge"] as? Int == 0)
    #expect(claimRequestData?["secureRTSPSupported"] as? Bool == false)
    #expect(claimRequestData?["transport"] == nil)
    let claimMonitorSettings = claimRequestData?["clientRequestMonitorSettings"] as? [[String: Any]] ?? []
    #expect(claimMonitorSettings.first?["widthInPixels"] as? Int == 7680)
    #expect(claimMonitorSettings.first?["heightInPixels"] as? Int == 4320)
    let claimPhysicalResolution = parsePhysicalResolutionMetadata(claimMetadata)
    #expect(claimPhysicalResolution?["horizontalPixels"] as? Int == 7680)
    #expect(claimPhysicalResolution?["verticalPixels"] as? Int == 4320)
    #expect(claimMetadata.contains { $0["key"] == "wssignaling" && $0["value"] == "1" })
    #expect(claimMetadata.contains { $0["key"] == "GSStreamerType" && $0["value"] == "WebRTC" })
    }
}

@Test func sessionManagerNVSTPausedResumeSendsNVSTClaimShape() async {
    await networkTestIsolationLock.withLock {
    let host = "resume-nvst-success.example.test"
    let lock = NSLock()
    nonisolated(unsafe) var getCount = 0
    SessionManagerURLProtocol.install(host: host) { request in
        if request.httpMethod == "GET" {
            lock.lock()
            getCount += 1
            let count = getCount
            lock.unlock()
            // Post-hand-over the seat publishes its RTSPS control endpoint; the claim poll waits
            // for that before reporting the session ready on NVST.
            return SessionManagerURLProtocol.response(json: sessionResponse(statusCode: 1, sessionStatus: count == 1 ? 5 : 2, controlHost: host, advertisesNvstControlEndpoint: count > 1))
        }
        return SessionManagerURLProtocol.response(json: sessionResponse(statusCode: 1, sessionStatus: 6, controlHost: host))
    }
    defer { SessionManagerURLProtocol.uninstall(host: host) }

    OPNSessionManager.shared.setAccessToken("token")
    OPNSessionManager.shared.setStreamingBaseUrl("https://\(host)")
    var settings = minimalSettings()
    settings["transportMode"] = "nvst"

    let result = await withCheckedContinuation { continuation in
        OPNSessionManager.shared.claimSession(sessionId: "resume-session", serverIp: host, appId: "123", settings: settings, recoveryMode: false) { success, _, error in
            continuation.resume(returning: (success, error))
        }
    }

    let claimPayload = SessionManagerURLProtocol.recordedJSONBodies(host: host).first { $0["action"] != nil }
    let claimRequest = SessionManagerURLProtocol.recordedRequests(host: host).first { $0.httpMethod == "PUT" }
    let claimRequestData = claimPayload?["sessionRequestData"] as? [String: Any]
    let claimMetadata = claimRequestData?["metaData"] as? [[String: String]] ?? []
    #expect(result.0 == true)
    #expect(claimRequest?.value(forHTTPHeaderField: "nv-client-streamer") == "NVIDIA-CLASSIC")
    #expect(claimRequest?.value(forHTTPHeaderField: "nv-client-version") == GFNClientMetadata.appVersion)
    #expect(claimRequest?.value(forHTTPHeaderField: "nv-client-type") == "NATIVE")
    #expect(claimRequestData?["clientPlatformName"] as? String == "windows")
    #expect(claimRequestData?["secureRTSPSupported"] as? Bool == true)
    #expect(claimRequestData?["transport"] == nil)
    #expect(claimMetadata.contains { $0["key"] == "wssignaling" && $0["value"] == "1" })
    #expect(!claimMetadata.contains { $0["key"] == "GSStreamerType" })
    }
}

/// A session the validation poll already reports as connectable still gets the RESUME hand-over:
/// its endpoints are only usable once the seat has been told who is connecting now, otherwise its
/// RTSPS control channel answers the WebSocket upgrade with HTTP 501. The seat rejects the
/// hand-over for an unpaused session with SESSION_NOT_PAUSED, which the claim polls through.
@Test func sessionManagerReadySessionStillSendsResumeClaim() async {
    await networkTestIsolationLock.withLock {
    let host = "resume-not-paused.example.test"
    SessionManagerURLProtocol.install(host: host) { request in
        if request.httpMethod == "GET" {
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
        OPNSessionManager.shared.claimSession(sessionId: "resume-session", serverIp: host, appId: "123", settings: minimalSettings(), recoveryMode: false) { success, info, error in
            continuation.resume(returning: (success, info["isResume"] as? Bool ?? false, error))
        }
    }

    let requests = SessionManagerURLProtocol.recordedRequests(host: host)
    #expect(result.0 == true)
    #expect(result.1 == true)
    #expect(result.2.isEmpty)
    #expect(requests.map(\.httpMethod) == ["GET", "PUT", "GET"])
    }
}

@Test func sessionManagerSessionNotPausedRacePollsConnectableSession() async {
    await networkTestIsolationLock.withLock {
    let host = "resume-not-paused-race.example.test"
    let lock = NSLock()
    nonisolated(unsafe) var getCount = 0
    SessionManagerURLProtocol.install(host: host) { request in
        if request.httpMethod == "GET" {
            lock.lock()
            getCount += 1
            let count = getCount
            lock.unlock()
            return SessionManagerURLProtocol.response(json: sessionResponse(statusCode: 1, sessionStatus: count == 1 ? 5 : 2, controlHost: host))
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
        OPNSessionManager.shared.claimSession(sessionId: "resume-session", serverIp: host, appId: "123", settings: minimalSettings(), recoveryMode: false) { success, info, error in
            continuation.resume(returning: (success, info["isResume"] as? Bool ?? false, error))
        }
    }

    let requests = SessionManagerURLProtocol.recordedRequests(host: host)
    #expect(result.0 == true)
    #expect(result.1 == true)
    #expect(result.2.isEmpty)
    #expect(requests.map(\.httpMethod) == ["GET", "PUT", "GET"])
    }
}

@Test func sessionManagerStaleInternalClaimErrorFailsWithoutPollingFallback() async {
    await networkTestIsolationLock.withLock {
    let host = "resume-stale-internal.example.test"
    UserDefaults.standard.set("resume-session", forKey: "OpenNOW.Stream.ActiveSessionId")
    SessionManagerURLProtocol.install(host: host) { request in
        let path = request.url?.path ?? ""
        if request.httpMethod == "GET", path == "/v2/session/resume-session" {
            return SessionManagerURLProtocol.response(json: sessionResponse(statusCode: 1, sessionStatus: 5, controlHost: host))
        }
        return SessionManagerURLProtocol.response(json: staleSessionResponse(), status: 400)
    }
    defer {
        UserDefaults.standard.removeObject(forKey: "OpenNOW.Stream.ActiveSessionId")
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
    #expect(requests.map(\.httpMethod) == ["GET", "PUT"])
    }
}

@Test func sessionManagerStaleInternalCreateErrorReturnsActionableMessage() async {
    await networkTestIsolationLock.withLock {
    let host = "create-stale-internal.example.test"
    SessionManagerURLProtocol.install(host: host) { request in
        #expect(request.httpMethod == "POST")
        return SessionManagerURLProtocol.response(json: staleSessionResponse(), status: 400)
    }
    defer { SessionManagerURLProtocol.uninstall(host: host) }

    let manager = OPNSessionManager()
    manager.setAccessToken("token")
    manager.setStreamingBaseUrl("https://\(host)")
    let (createSucceeded, _, createError) = await manager.createSession(appId: "123", internalTitle: "Test Game", settings: minimalSettings())
    let result = (createSucceeded, createError)

    #expect(result.0 == false)
    #expect(result.1 == "This GeForce NOW session is no longer resumable. End it and launch again.")
    }
}

@Test func sessionManagerLimitedModeCreateErrorReturnsActionableMessage() async {
    await networkTestIsolationLock.withLock {
    let host = "create-limited-mode.example.test"
    SessionManagerURLProtocol.install(host: host) { request in
        #expect(request.httpMethod == "POST")
        return SessionManagerURLProtocol.response(json: limitedModeSessionResponse(), status: 500)
    }
    defer { SessionManagerURLProtocol.uninstall(host: host) }

    let manager = OPNSessionManager()
    manager.setAccessToken("token")
    manager.setStreamingBaseUrl("https://\(host)")
    let (createSucceeded, _, createError) = await manager.createSession(appId: "123", internalTitle: "Test Game", settings: minimalSettings())
    let result = (createSucceeded, createError)

    #expect(result.0 == false)
    #expect(result.1 == "GeForce NOW says this game is out of limited playtime. Add playtime or try another game.")
    }
}

@Test func sessionManagerSessionLimitReturnsActiveSessionForUserDecision() async {
    await networkTestIsolationLock.withLock {
    let host = "create-session-limit.example.test"
    SessionManagerURLProtocol.install(host: host) { request in
        #expect(request.httpMethod == "POST")
        return SessionManagerURLProtocol.response(json: [
            "requestStatus": [
                "statusCode": 11,
                "statusDescription": "NVB_R_SESSION_LIMIT_REACHED",
            ],
            "otherUserSessions": [[
                "sessionId": "active-session",
                "status": 5,
                "sessionRequestData": ["appId": 456],
                "sessionControlInfo": ["ip": host],
            ]],
        ], status: 400)
    }
    defer { SessionManagerURLProtocol.uninstall(host: host) }

    let manager = OPNSessionManager()
    manager.setAccessToken("token")
    manager.setStreamingBaseUrl("https://\(host)")
    let (createSucceeded, createInfo, createError) = await manager.createSession(appId: "123", internalTitle: "Test Game", settings: minimalSettings())
    let result = (
        createSucceeded,
        createInfo["isSessionLimitConflict"] as? Bool ?? false,
        createInfo["sessionId"] as? String ?? "",
        createInfo["appId"] as? Int ?? 0,
        createInfo["serverIp"] as? String ?? "",
        createInfo["isResumable"] as? Bool ?? false,
        createError
    )

    #expect(result.0 == false)
    #expect(result.1)
    #expect(result.2 == "active-session")
    #expect(result.3 == 456)
    #expect(result.4 == host)
    #expect(result.5)
    #expect(result.6.contains("Resume it or end it"))
    #expect(SessionManagerURLProtocol.recordedRequests(host: host).map(\.httpMethod) == ["POST"])
    }
}

@Test func sessionManagerSessionLimitDoesNotOfferResumeForInitializingSession() async {
    await networkTestIsolationLock.withLock {
    let host = "create-initializing-session-limit.example.test"
    SessionManagerURLProtocol.install(host: host) { request in
        #expect(request.httpMethod == "POST")
        return SessionManagerURLProtocol.response(json: [
            "requestStatus": [
                "statusCode": 11,
                "statusDescription": "NVB_R_SESSION_LIMIT_REACHED",
            ],
            "otherUserSessions": [[
                "sessionId": "initializing-session",
                "status": 1,
                "sessionRequestData": ["appId": 456],
                "sessionControlInfo": ["ip": host],
            ]],
        ], status: 400)
    }
    defer { SessionManagerURLProtocol.uninstall(host: host) }

    let manager = OPNSessionManager()
    manager.setAccessToken("token")
    manager.setStreamingBaseUrl("https://\(host)")
    let (createSucceeded, createInfo, createError) = await manager.createSession(appId: "123", internalTitle: "Test Game", settings: minimalSettings())
    let result = (
        createSucceeded,
        createInfo["isSessionLimitConflict"] as? Bool ?? false,
        createInfo["isResumable"] as? Bool ?? false,
        createError
    )

    #expect(result.0 == false)
    #expect(result.1)
    #expect(!result.2)
    #expect(!result.3.contains("Resume"))
    #expect(result.3.contains("End it"))
    }
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

@Test func sessionManagerPrefersMatchingResumableSessionLimitEntry() {
    let selected = OPNSessionManager.shared.selectSessionLimitReuseEntry([
        ["sessionId": "other-ready", "appId": 456, "status": 2, "serverIp": "other.example.test"],
        ["sessionId": "matching-paused", "appId": 123, "status": 5, "serverIp": "matching.example.test"],
    ], requestedAppId: 123)

    #expect(selected?["sessionId"] as? String == "matching-paused")
}

@Test func sessionAdStateParsesNestedProgressAds() throws {
    let parsed = OPNSessionJSONParser.parseSessionAdState(from: [
        "sessionProgress": [
            "isAdsRequired": true,
            "sessionAds": [[
                "adId": "nested-ad",
                "adState": 1,
                "adMediaFiles": [[
                    "mediaFileUrl": "https://ads.example.test/video.mp4",
                    "encodingProfile": "mp4deinterlaced720p",
                ]],
                "clickThroughUrl": "https://ads.example.test/click",
                "adLengthInSeconds": 15,
                "title": "Sponsor",
            ]],
        ],
    ])

    let ad = try #require(parsed.sessionAds.first)
    #expect(parsed.isAdsRequired)
    #expect(parsed.sessionAdsRequired)
    #expect(!parsed.serverSentEmptyAds)
    #expect(ad.adId == "nested-ad")
    #expect(ad.mediaUrl == "https://ads.example.test/video.mp4")
    #expect(ad.durationMs == 15_000)
}

@Test func sessionAdStateParsesVendorAdsAlias() throws {
    let parsed = OPNSessionJSONParser.parseSessionAdState(from: [
        "sessionAdsRequired": true,
        "ads": [[
            "adId": "vendor-ad",
            "adState": 1,
            "adMediaFiles": [[
                "mediaFileUrl": "https://ads.example.test/hls.m3u8",
                "encodingProfile": "hlsadaptive",
            ]],
        ]],
    ])

    let ad = try #require(parsed.sessionAds.first)
    #expect(parsed.isAdsRequired)
    #expect(ad.adId == "vendor-ad")
    #expect(ad.mediaUrl == "https://ads.example.test/hls.m3u8")
}

@Test func sessionManagerKeepsNestedAdsAcrossEmptyRequiredPolls() async {
    await networkTestIsolationLock.withLock {
        let host = "nested-ads.example.test"
        let lock = NSLock()
        nonisolated(unsafe) var pollCount = 0
        SessionManagerURLProtocol.install(host: host) { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/v2/session/resume-session")
            lock.withLock { pollCount += 1 }
            if lock.withLock({ pollCount }) == 1 {
                return SessionManagerURLProtocol.response(json: sessionResponse(statusCode: 1, sessionStatus: 1, controlHost: host, extraSession: [
                    "sessionProgress": [
                        "isAdsRequired": true,
                        "sessionAds": [[
                            "adId": "nested-ad",
                            "adState": 1,
                            "mediaUrl": "https://ads.example.test/video.mp4",
                            "adLengthInSeconds": 15,
                        ]],
                    ],
                ]))
            }
            return SessionManagerURLProtocol.response(json: sessionResponse(statusCode: 1, sessionStatus: 1, controlHost: host, extraSession: [
                "sessionProgress": [
                    "isAdsRequired": true,
                ],
            ]))
        }
        defer { SessionManagerURLProtocol.uninstall(host: host) }

        let manager = OPNSessionManager()
        manager.setAccessToken("token")
        manager.setStreamingBaseUrl("https://\(host)")

        let pollAd: ((Bool, [String: Any], String)) -> (Bool, String, String, String) = { result in
            let (success, info, error) = result
            let adState = info["adState"] as? [String: Any]
            let ad = (adState?["sessionAds"] as? [[String: Any]])?.first
            return (success, ad?["adId"] as? String ?? "", ad?["mediaUrl"] as? String ?? "", error)
        }
        let first = pollAd(await manager.pollSession(sessionId: "resume-session", serverIp: host))
        let second = pollAd(await manager.pollSession(sessionId: "resume-session", serverIp: host))

        #expect(first.0)
        #expect(first.3.isEmpty)
        #expect(first.1 == "nested-ad")
        #expect(second.0)
        #expect(second.3.isEmpty)
        #expect(second.2 == "https://ads.example.test/video.mp4")
    }
}
