//  Session creation, claiming and the ad flow, plus the fixtures every session test shares.
//

import Testing
import Foundation
@testable import OpenNOW

/// What the release CloudMatch shape requires of the request body itself, as opposed to its
/// headers and URL.
func expectReleaseCloudMatchRequestBody(_ requestData: [String: Any], metadata: [[String: String]]) throws {
    let metadataKeys = Set(metadata.compactMap { $0["key"] })
    #expect(requestData["appId"] as? Int == 123)
    #expect(requestData["internalTitle"] as? String == "Test Game")
    #expect(requestData["clientPlatformName"] as? String == "browser")
    // HDR off (default) -> capabilities must be null to avoid GFN's HDR-pipeline downscale.
    #expect(requestData["clientDisplayHdrCapabilities"] is NSNull)
    #expect(requestData["networkTestSessionId"] as? String == "stale-session-id")
    #expect(requestData["accountLinked"] as? Bool == true)
    #expect(requestData["enablePersistingInGameSettings"] as? Bool == true)
    #expect(requestData["partnerCustomData"] as? String == "partner-data")
    #expect(requestData["userAge"] as? Int == 21)
    #expect(requestData["secureRTSPSupported"] as? Bool == false)
    #expect(requestData["transport"] == nil)
    let monitorSettings = try #require(requestData["clientRequestMonitorSettings"] as? [[String: Any]])
    let monitor = try #require(monitorSettings.first)
    #expect(monitor["monitorId"] as? Int == 0)
    #expect(monitor["positionX"] as? Int == 0)
    #expect(monitor["positionY"] as? Int == 0)
    #expect(monitor["widthInPixels"] as? Int == 7680)
    #expect(monitor["heightInPixels"] as? Int == 4320)
    let physicalResolution = try #require(parsePhysicalResolutionMetadata(metadata))
    #expect(physicalResolution["horizontalPixels"] as? Int == 7680)
    #expect(physicalResolution["verticalPixels"] as? Int == 4320)
    let streamingFeatures = try #require(requestData["requestedStreamingFeatures"] as? [String: Any])
    #expect(streamingFeatures["reflex"] as? Bool == true)
    #expect(streamingFeatures["cloudGsync"] as? Bool == true)
    #expect(streamingFeatures["profile"] as? Int == 4)
    #expect(streamingFeatures["fallbackToLogicalResolution"] as? Bool == true)
    #expect(streamingFeatures["mouseMovementFlags"] as? Int == 3)
    #expect(streamingFeatures["hudStreamingMode"] as? Int == 2)
    #expect(streamingFeatures["sdrColorSpace"] as? Int == 1)
    #expect(streamingFeatures["hdrColorSpace"] as? Int == 2)
    #expect(streamingFeatures["prefilterSharpness"] as? Int == 0)
    #expect(streamingFeatures["maxBitrateKbps"] as? Int == 50_000)
    #expect(metadataKeys.contains("store") == true)
    #expect(metadataKeys.contains("networkLatencyMs") == true)
    #expect(metadata.contains { $0["key"] == "wssignaling" && $0["value"] == "1" })
    #expect(metadata.contains { $0["key"] == "GSStreamerType" && $0["value"] == "WebRTC" })
}

@Test func sessionManagerCreateUsesReleaseCloudMatchShape() async throws {
    try await networkTestIsolationLock.withLock {
    let host = "create-release-shape.example.test"
    SessionManagerURLProtocol.install(host: host) { request in
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v2/session")
        return SessionManagerURLProtocol.response(json: sessionResponse(statusCode: 1, sessionStatus: 2, controlHost: host))
    }
    defer { SessionManagerURLProtocol.uninstall(host: host) }

    let manager = OPNSessionManager()
    manager.setAccessToken("token")
    manager.setStreamingBaseUrl("https://\(host)")
    var settings = minimalSettings()
    settings["networkTestSessionId"] = "stale-session-id"
    settings["enablePersistingInGameSettings"] = true
    settings["partnerCustomData"] = "partner-data"
    settings["userAge"] = 21
    settings["streamingQualityProfile"] = 4
    settings["enableCloudGsync"] = true
    settings["fallbackToLogicalResolution"] = true
    settings["mouseMovementFlags"] = 3
    settings["hudStreamingMode"] = 2
    settings["sdrColorSpace"] = 1
    settings["hdrColorSpace"] = 2
    settings["resolution"] = "7680x4320"

    let (createSucceeded, _, createError) = await manager.createSession(appId: "123", internalTitle: "Test Game", settings: settings)
    let result = (createSucceeded, createError)

    let request = try #require(SessionManagerURLProtocol.recordedRequests(host: host).first)
    let payload = try #require(SessionManagerURLProtocol.recordedJSONBodies(host: host).first)
    let requestData = try #require(payload["sessionRequestData"] as? [String: Any])
    let metadata = try #require(requestData["metaData"] as? [[String: String]])

    #expect(result.0 == true)
    #expect(result.1.isEmpty)
    #expect(request.url?.query?.contains("keyboardLayout=us") == true)
    // WebRTC sessions use browser identity; NVST native sessions identify as Windows GFN-PC client.
    #expect(request.value(forHTTPHeaderField: "nv-client-streamer") == "NVIDIA-CLASSIC")
    #expect(request.value(forHTTPHeaderField: "nv-client-version") == GFNClientMetadata.appVersion)
    #expect(request.value(forHTTPHeaderField: "nv-client-type") == "NATIVE")
    #expect(request.value(forHTTPHeaderField: "Origin") == "https://play.geforcenow.com")
    #expect(request.value(forHTTPHeaderField: "Referer") == "https://play.geforcenow.com/")
        // Fork sends the native GFN-PC identity (device make UNKNOWN) on both transports:
        // a browser identity makes GeForce NOW cap the server desktop at web-client resolution.
        #expect(request.value(forHTTPHeaderField: "nv-device-make") == "UNKNOWN")
    try expectReleaseCloudMatchRequestBody(requestData, metadata: metadata)
    }
}

@Test func sessionManagerCreateSerializesExplicitTransportPolicy() async throws {
    try await networkTestIsolationLock.withLock {
    let host = "create-explicit-transport.example.test"
    SessionManagerURLProtocol.install(host: host) { request in
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v2/session")
        return SessionManagerURLProtocol.response(json: sessionResponse(statusCode: 1, sessionStatus: 2, controlHost: host))
    }
    defer { SessionManagerURLProtocol.uninstall(host: host) }

    let manager = OPNSessionManager()
    manager.setAccessToken("token")
    manager.setStreamingBaseUrl("https://\(host)")
    var settings = minimalSettings()
    settings["transportPolicy"] = 1
    settings["relayProtocol"] = 2
    settings["relayLocation"] = 1

    let (createSucceeded, _, createError) = await manager.createSession(appId: "123", internalTitle: "Test Game", settings: settings)
    let result = (createSucceeded, createError)

    let payload = try #require(SessionManagerURLProtocol.recordedJSONBodies(host: host).first)
    let requestData = try #require(payload["sessionRequestData"] as? [String: Any])
    let transport = try #require(requestData["transport"] as? [String: Any])

    #expect(result.0 == true)
    #expect(result.1.isEmpty)
    #expect(transport["policy"] as? Int == 1)
    #expect(transport["relayProtocol"] as? Int == 2)
    #expect(transport["relayLocation"] as? Int == 1)
    }
}

@Test func sessionManagerCreateUsesNVSTCloudMatchShape() async throws {
    try await networkTestIsolationLock.withLock {
    let host = "create-nvst-shape.example.test"
    SessionManagerURLProtocol.install(host: host) { request in
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v2/session")
        return SessionManagerURLProtocol.response(json: sessionResponse(statusCode: 1, sessionStatus: 2, controlHost: host))
    }
    defer { SessionManagerURLProtocol.uninstall(host: host) }

    let manager = OPNSessionManager()
    manager.setAccessToken("token")
    manager.setStreamingBaseUrl("https://\(host)")
    var settings = minimalSettings()
    settings["transportMode"] = "nvst"

    let (createSucceeded, _, createError) = await manager.createSession(appId: "123", internalTitle: "Test Game", settings: settings)
    let result = (createSucceeded, createError)

    let request = try #require(SessionManagerURLProtocol.recordedRequests(host: host).first)
    let payload = try #require(SessionManagerURLProtocol.recordedJSONBodies(host: host).first)
    let requestData = try #require(payload["sessionRequestData"] as? [String: Any])
    let metadata = try #require(requestData["metaData"] as? [[String: String]])

    #expect(result.0 == true)
    #expect(result.1.isEmpty)
    #expect(request.value(forHTTPHeaderField: "nv-client-streamer") == "NVIDIA-CLASSIC")
    #expect(request.value(forHTTPHeaderField: "nv-client-version") == GFNClientMetadata.appVersion)
    #expect(request.value(forHTTPHeaderField: "nv-client-type") == "NATIVE")
    #expect(requestData["clientPlatformName"] as? String == "windows")
    #expect(requestData["secureRTSPSupported"] as? Bool == true)
    #expect(requestData["transport"] == nil)
    #expect(metadata.contains { $0["key"] == "wssignaling" && $0["value"] == "1" })
    #expect(!metadata.contains { $0["key"] == "GSStreamerType" })
    }
}

@Test func sessionManagerPreservesRawSessionJSONForNativeNVST() async throws {
    try await networkTestIsolationLock.withLock {
    let host = "raw-session-preserve.example.test"
    SessionManagerURLProtocol.install(host: host) { request in
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v2/session")
        return SessionManagerURLProtocol.response(json: sessionResponse(statusCode: 1, sessionStatus: 2, controlHost: host, extraSession: [
            "tokenType": "JWT",
            "token": "session-token",
            "serverAddress": "rtsps://raw-session.example.test:443",
            "streamingProfile": ["streamingProfileGuid": "profile-guid"],
        ]))
    }
    defer { SessionManagerURLProtocol.uninstall(host: host) }

    let manager = OPNSessionManager()
    manager.setAccessToken("token")
    manager.setStreamingBaseUrl("https://\(host)")
    var settings = minimalSettings()
    settings["transportMode"] = "nvst"

    let (createSucceeded, createInfo, createError) = await manager.createSession(appId: "123", internalTitle: "Test Game", settings: settings)
    let result = (createSucceeded, createInfo["rawSessionJSON"] as? String, createError)

    let rawSessionJSON = try #require(result.1)
    let rawSessionData = try #require(rawSessionJSON.data(using: .utf8))
    let rawSession = try #require(JSONSerialization.jsonObject(with: rawSessionData) as? [String: Any])
    let streamingProfile = try #require(rawSession["streamingProfile"] as? [String: Any])

    #expect(result.0 == true)
    #expect(result.2.isEmpty)
    #expect(rawSession["tokenType"] as? String == "JWT")
    #expect(rawSession["token"] as? String == "session-token")
    #expect(rawSession["serverAddress"] as? String == "rtsps://raw-session.example.test:443")
    #expect(streamingProfile["streamingProfileGuid"] as? String == "profile-guid")
    }
}

@Test func sessionManagerUsesBundleConnectionWhenVideoConnectionIsAbsent() async {
    await networkTestIsolationLock.withLock {
    let host = "bundle-media.example.test"
    SessionManagerURLProtocol.install(host: host) { request in
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/v2/session/resume-session")
        return SessionManagerURLProtocol.response(json: [
            "requestStatus": ["statusCode": 1, "statusDescription": "SUCCESS"],
            "session": [
                "sessionId": "resume-session",
                "status": 2,
                "sessionRequestData": ["appId": 123],
                "sessionControlInfo": ["ip": host],
                "connectionInfo": [
                    ["usage": 14, "ip": "signaling.example.test", "port": 443, "resourcePath": "/nvst/"],
                    ["usage": 17, "ip": "bundle.example.test", "port": 47998, "resourcePath": ""],
                ],
            ],
        ])
    }
    defer { SessionManagerURLProtocol.uninstall(host: host) }

    let manager = OPNSessionManager()
    manager.setAccessToken("token")
    manager.setStreamingBaseUrl("https://\(host)")

    let (pollSucceeded, pollInfo, pollError) = await manager.pollSession(sessionId: "resume-session", serverIp: host)
    let pollMedia = pollInfo["mediaConnectionInfo"] as? [String: Any] ?? [:]
    let result = (pollSucceeded, pollMedia["ip"] as? String ?? "", pollMedia["port"] as? Int ?? 0, pollError)

    #expect(result.0 == true)
    #expect(result.3.isEmpty)
    #expect(result.1 == "bundle.example.test")
    #expect(result.2 == 47998)
    }
}

@Test func sessionProgressParsesSessionLimitTimerData() {
    let parsed = OPNSessionJSONParser.parseSessionProgress(from: [
        "message": [
            "messageType": "SESSION_LENGTH_TIMER",
            "timerData": [
                "beforeEventMS": 1_794_000,
                "presentDurationMS": 30_000,
                "timerType": 0,
            ],
        ],
    ])

    #expect(parsed.remainingSessionLimitSeconds == 1794)
}

@Test func streamSessionLimitUpdateParsesVendorClientMessage() throws {
    let data = try JSONSerialization.data(withJSONObject: [
        "event": "STREAMING_CLIENT_MESSAGE",
        "message": [
            "messageType": "SESSION_LENGTH_TIMER",
            "timerData": [
                "beforeEventMS": 1_200_000,
                "presentDurationMS": 30_000,
                "timerType": "SmallMarquee",
            ],
        ],
    ])

    let update = try #require(StreamSessionLimitUpdate.parse(from: data))
    #expect(update.remainingSeconds == 1200)
    #expect(update.presentDurationSeconds == 30)
    #expect(update.timerType == "SmallMarquee")

    let paidSessionData = try JSONSerialization.data(withJSONObject: [
        "messageType": "SESSION_LENGTH_TIMER",
        "timerData": ["beforeEventMS": 14_400_000],
    ])
    #expect(StreamSessionLimitUpdate.parse(from: paidSessionData)?.remainingSeconds == 14_400)

    let maintenanceData = try JSONSerialization.data(withJSONObject: [
        "message": [
            "messageType": "ZONE_MAINTENANCE_TIMER",
            "timerData": ["beforeEventMS": 900_000],
        ],
    ])
    #expect(StreamSessionLimitUpdate.parse(from: maintenanceData) == nil)
}

@Test func membershipRequiredBadgeOnlyShowsForFreeTierAccount() {
    let game = OPNCatalogGameObject()
    game.membershipTierLabel = "Ultimate"

    #expect(OPNCatalogGameObject.isFreeMembershipTier("Free"))
    #expect(!OPNCatalogGameObject.isFreeMembershipTier("Priority"))
    #expect(game.freeAccountAccessBadgeLabel(isFreeTierAccount: true) == "Membership Required")
    #expect(game.freeAccountAccessBadgeLabel(isFreeTierAccount: false) == nil)
}

@Test func sessionManagerCarriesRemainingSessionLimitSeconds() async {
    await networkTestIsolationLock.withLock {
    let host = "session-limit-timer.example.test"
    SessionManagerURLProtocol.install(host: host) { request in
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/v2/session/resume-session")
        return SessionManagerURLProtocol.response(json: sessionResponse(statusCode: 1, sessionStatus: 2, controlHost: host, extraSession: [
            "sessionProgress": [
                "timeRemaining": 7200,
            ],
        ]))
    }
    defer { SessionManagerURLProtocol.uninstall(host: host) }

    let manager = OPNSessionManager()
    manager.setAccessToken("token")
    manager.setStreamingBaseUrl("https://\(host)")

    let (pollSucceeded, pollInfo, pollError) = await manager.pollSession(sessionId: "resume-session", serverIp: host)
    let result = (pollSucceeded, pollInfo["remainingSessionLimitSeconds"] as? Int ?? 0, pollError)

    #expect(result.0 == true)
    #expect(result.1 == 7200)
    #expect(result.2.isEmpty)
    }
}
