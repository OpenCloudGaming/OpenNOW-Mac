import Foundation
import Testing
@testable import OpenNOW

private actor RecordingNativeNVSTSessionProvider: NativeNVSTSessionProvider, StreamSessionStartCancellable {
    private(set) var startCount = 0
    private(set) var finished: [(StreamSessionDescriptor, StreamEndReason)] = []
    private(set) var cancelCount = 0
    let allocation: NativeNVSTSessionAllocation

    init(allocation: NativeNVSTSessionAllocation = nativeAllocation()) {
        self.allocation = allocation
    }

    func startNativeNVSTSession(configuration: StreamLaunchConfiguration) async throws -> NativeNVSTSessionAllocation {
        startCount += 1
        return allocation
    }

    func finishSession(_ session: StreamSessionDescriptor, reason: StreamEndReason) async throws {
        finished.append((session, reason))
    }

    func cancelSessionStart() async {
        cancelCount += 1
    }
}

private actor RecordingNativeNVSTTransport: NativeNVSTTransport {
    enum Mode: Sendable {
        case prepareFailure
        case connectFailure
        case success
    }

    private(set) var prepareCount = 0
    private(set) var connectCount = 0
    private(set) var sentEvents: [UserInputEvent] = []
    private(set) var disconnectCount = 0
    private let mode: Mode

    init(mode: Mode) {
        self.mode = mode
    }

    func prepare() async throws -> NVSTNativeBridgeStatus {
        prepareCount += 1
        if case .prepareFailure = mode {
            throw NativeNVSTError.runtimeUnavailable("runtime missing")
        }
        let libraryURL = URL(fileURLWithPath: "/tmp/libBifrost2.dylib")
        return NVSTNativeBridgeStatus(libraryURL: libraryURL, bundledArtifactURLs: [libraryURL], resolvedSymbols: ["nvstCreateClient"], runtimeAvailable: true)
    }

    func connect(allocation: NativeNVSTSessionAllocation, mediaReceiver: any NativeNVSTMediaReceiver) async throws -> NativeNVSTTransportConnection {
        connectCount += 1
        if case .connectFailure = mode {
            throw NativeNVSTError.privateABIUnavailable("abi unavailable")
        }
        await mediaReceiver.receiveVideoFrame(NativeNVSTVideoFrame(streamID: 1, codec: .h264, timestamp: MediaTimestamp(nanoseconds: 1), durationNanoseconds: 16_666_667, width: 1920, height: 1080, isKeyFrame: true, payload: Data([1, 2, 3])))
        return NativeNVSTTransportConnection(session: allocation.session, runtimeStatus: try await prepare())
    }

    func send(_ event: UserInputEvent) async throws {
        sentEvents.append(event)
    }

    func disconnect() async {
        disconnectCount += 1
    }
}

@Test func nativeNVSTPathPrepareFailureDoesNotAllocateCloudSession() async throws {
    let provider = RecordingNativeNVSTSessionProvider()
    let transport = RecordingNativeNVSTTransport(mode: .prepareFailure)
    let path = NativeNVSTStreamingPath(sessionProvider: provider, transport: transport)

    do {
        _ = try await path.start(configuration: nativeConfiguration())
        Issue.record("Expected prepare failure")
    } catch let error as NativeNVSTError {
        #expect(error == .runtimeUnavailable("runtime missing"))
    }

    #expect(await provider.startCount == 0)
    #expect(await transport.prepareCount == 1)
}

@Test func nativeNVSTPathConnectFailureFinishesAllocatedSession() async throws {
    let provider = RecordingNativeNVSTSessionProvider()
    let transport = RecordingNativeNVSTTransport(mode: .connectFailure)
    let path = NativeNVSTStreamingPath(sessionProvider: provider, transport: transport)

    do {
        _ = try await path.start(configuration: nativeConfiguration())
        Issue.record("Expected connect failure")
    } catch let error as NativeNVSTError {
        #expect(error == .privateABIUnavailable("abi unavailable"))
    }

    #expect(await provider.startCount == 1)
    #expect(await provider.finished == [(nativeAllocation().session, .failed)])
    #expect(await transport.disconnectCount == 1)
}

@Test func nativeNVSTPathStartsSendsInputAndStops() async throws {
    let provider = RecordingNativeNVSTSessionProvider()
    let transport = RecordingNativeNVSTTransport(mode: .success)
    let path = NativeNVSTStreamingPath(sessionProvider: provider, transport: transport)
    var progressSteps: [StreamLaunchStep] = []

    let session = try await path.start(configuration: nativeConfiguration()) { progress in
        if let step = StreamLaunchStep(rawValue: progress.currentStepIndex) {
            progressSteps.append(step)
        }
    }
    let input = UserInputEvent.keyboard(KeyboardEvent(deviceID: "keyboard", keyCode: 4, scanCode: 4, isPressed: true, timestamp: MediaTimestamp(nanoseconds: 1)))
    try await path.send(input)
    let report = try await path.stop(reason: .userRequested, message: "Stopped")

    #expect(session == nativeAllocation().session)
    #expect(progressSteps.contains(.checkNetworkRoute))
    #expect(progressSteps.contains(.allocateCloudSession))
    #expect(progressSteps.contains(.connected))
    #expect(await transport.sentEvents == [input])
    #expect(await provider.finished == [(nativeAllocation().session, .userRequested)])
    #expect(report.metadata["transport"] == "nvst")
}

@Test func nativeNVSTInputEncoderMapsKeyboardMouseTextAndGamepad() throws {
    let encoder = NativeNVSTInputEncoder(inputConfiguration: NVSTInputTransportConfiguration(partialReliableThresholdMs: 5, partiallyReliableGamepadMask: 1, partiallyReliableHIDMask: 1))
    let timestamp = MediaTimestamp(nanoseconds: 1)
    let events: [UserInputEvent] = [
        .keyboard(KeyboardEvent(deviceID: "keyboard", keyCode: 4, scanCode: 4, isPressed: true, timestamp: timestamp)),
        .mouse(.moved(deviceID: "mouse", deltaX: 1, deltaY: -1, timestamp: timestamp)),
        .text(deviceID: "keyboard", value: "hello", timestamp: timestamp),
        .gamepad(GamepadState(deviceID: "gamepad", playerIndex: 0, buttons: [.south], leftTrigger: 0.5, rightTrigger: 1, leftStickX: 1, leftStickY: -1, rightStickX: 0, rightStickY: 0, timestamp: timestamp)),
    ]

    let encoded = events.compactMap { encoder.encode($0) }

    #expect(encoded.count == events.count)
    #expect(encoded.allSatisfy { !$0.payload.isEmpty })
    #expect(encoded[0].partiallyReliable == false)
    #expect(encoded[1].partiallyReliable == true)
    #expect(encoded[2].partiallyReliable == false)
    #expect(encoded[3].partiallyReliable == true)
}

@Test func nativeNVSTSessionPayloadExtractsVerifiedStartFieldsWithoutLoggingToken() throws {
    let allocation = nativeAllocation(rawSessionJSON: """
    {
      "serverAddress": "rtsps://native.example.test:443",
      "tokenType": "JWT",
      "token": "private-session-token",
      "session": "native-session-key",
      "sessionRequestData": { "appId": 123 },
      "streamingProfile": { "streamingProfileGuid": "profile-guid" },
      "audioModeFormat": "stereo"
    }
    """)

    let payload = NativeNVSTSessionPayload(allocation: allocation)

    #expect(payload.effectiveServerAddress == "rtsps://native.example.test:443")
    #expect(payload.tokenType == "JWT")
    #expect(payload.hasToken == true)
    #expect(payload.appID == "123")
    #expect(payload.sessionIdentifier == "native-session-key")
    #expect(payload.streamingProfileGUID == "profile-guid")
    #expect(payload.audioModeFormat == "stereo")
    #expect(payload.missingStartFields.isEmpty)
    #expect(payload.telemetryAttributes.values.contains("private-session-token") == false)
}

@Test func nativeNVSTSessionPayloadReportsMissingPrivateStartFields() throws {
    let allocation = nativeAllocation(rawSessionJSON: "{}")

    let payload = NativeNVSTSessionPayload(allocation: allocation)

    #expect(payload.effectiveServerAddress == "server.example.test")
    #expect(payload.appID == "123")
    #expect(payload.sessionIdentifier == "native-session")
    #expect(payload.missingStartFields == ["tokenType", "token", "streamingProfile.streamingProfileGuid"])
}

@Test func nativeNVSTSessionPayloadUsesAllocationAuthWithoutLoggingToken() throws {
    let allocation = nativeAllocation(rawSessionJSON: "{}", authTokenType: "JWT_GFN", authToken: "private-access-token")

    let payload = NativeNVSTSessionPayload(allocation: allocation)

    #expect(payload.tokenType == "JWT_GFN")
    #expect(payload.hasToken)
    #expect(payload.missingStartFields == ["streamingProfile.streamingProfileGuid"])
    #expect(payload.telemetryAttributes.values.contains("private-access-token") == false)
}

@Test func nativeNVSTGeronimoStartFailureMessageDoesNotExposePrivateABI() {
    let message = NativeNVSTBifrostTransport.geronimoStartFailureMessage

    #expect(message.contains("Nsk::") == false)
    #expect(message.contains("0x80f10005") == false)
    #expect(message.contains("WebRTC") == false)
    #expect(message.contains("diagnostics"))
}

@Test func nativeNVSTLaunchPayloadModelsVerifiedGeForceNOWStartFields() throws {
    let profileJSON = try NativeNVSTBifrostTransport.streamingProfileJSON(
        rawSessionJSON: """
        {
          "streamingProfile": { "streamingProfileGuid": "profile-guid", "resolution": "1920x1080", "fps": 60, "codec": "H264", "audioMode": "surround51" }
        }
        """,
        sessionInfoJSON: "{}"
    )
    let allocation = nativeAllocation(rawSessionJSON: """
    {
      "serverAddress": "control.example.test",
      "serverType": 52,
      "tokenType": "9",
      "token": "private-session-token",
      "networkSessionId": "network-session",
      "audioModeFormat": "surround51",
      "zoneName": "US-WEST",
      "userAge": 18,
      "summaryStatsEnabled": true,
      "sessionRequestData": {
        "appId": 123,
        "appName": "Game",
        "appLaunchMode": 2,
        "deviceHashId": "device-id",
        "gameShortName": "game",
        "maxLocalPlayers": 4,
        "advancedLatencyOptimization": true,
        "frameLossWarningTimeout": 500,
        "frameLossErrorTimeout": 30000,
        "supportedControls": ["KeyboardMouse", "Gamepad"],
        "contentRating": [{"system": "ESRB", "rating": "T"}],
        "spanData": { "traceparent": "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01" }
      }
    }
    """)

    let payload = NativeNVSTLaunchPayload(allocation: allocation, streamingProfileJSON: profileJSON, clientAppVersion: "2.0.87.131")

    try payload.validate()
    #expect(payload.prepare.address == "control.example.test")
    #expect(payload.prepare.tokenType == "9")
    #expect(payload.prepare.hasToken)
    #expect(payload.prepare.traceParent == "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01")
    #expect(payload.start.serverType == 52)
    #expect(payload.start.appId == 123)
    #expect(payload.start.networkSessionId == "network-session")
    #expect(payload.start.audioModeFormat == "surround51")
    #expect(payload.start.supportedControlsCount == 2)
    #expect(payload.start.contentRatingCount == 1)
    #expect(payload.telemetryAttributes.values.contains("private-session-token") == false)
}

@Test func nativeNVSTLaunchPayloadUsesAllocationAuthWhenSessionOmitsTokenFields() throws {
    let profileJSON = try NativeNVSTBifrostTransport.streamingProfileJSON(
        rawSessionJSON: """
        {
          "streamingProfile": { "streamingProfileGuid": "profile-guid", "resolution": "1920x1080", "fps": 60, "codec": "H264" }
        }
        """,
        sessionInfoJSON: "{}"
    )
    let allocation = nativeAllocation(
        rawSessionJSON: """
        {
          "serverAddress": "control.example.test",
          "networkSessionId": "network-session",
          "sessionRequestData": { "appId": 123, "deviceHashId": "device-id" },
          "audioModeFormat": "stereo"
        }
        """,
        authTokenType: "JWT_GFN",
        authToken: "private-access-token"
    )

    let payload = NativeNVSTLaunchPayload(allocation: allocation, streamingProfileJSON: profileJSON, clientAppVersion: "2.0.87.131")

    try payload.validate()
    #expect(payload.prepare.tokenType == "JWT_GFN")
    #expect(payload.prepare.hasToken)
    #expect(payload.telemetryAttributes.values.contains("private-access-token") == false)
}

@Test func nativeNVSTLaunchPayloadRejectsMissingVerifiedStartFields() throws {
    let payload = NativeNVSTLaunchPayload(allocation: nativeAllocation(rawSessionJSON: "{}"), streamingProfileJSON: "{}", clientAppVersion: "OpenNOW")

    #expect(payload.missingFields.contains("tokenType"))
    #expect(payload.missingFields.contains("token"))
    #expect(payload.missingFields.contains("streamingProfile"))
}

@Test func nativeNVSTGeronimoSessionJSONPromotesCloudSessionFields() throws {
    let streamingProfileJSON = try NativeNVSTBifrostTransport.streamingProfileJSON(
        rawSessionJSON: """
        {
          "streamingProfile": { "streamingProfileGuid": "profile-guid", "resolution": "1920x1080", "fps": 60, "codec": "H264" }
        }
        """,
        sessionInfoJSON: "{}"
    )
    let sessionJSON = try NativeNVSTBifrostTransport.geronimoSessionJSON(
        allocation: nativeAllocation(rawSessionJSON: """
        {
          "sessionId": "native-session",
          "status": 2,
          "gpuType": "L40",
          "sessionRequestData": { "appId": 123, "appLaunchMode": 3, "deviceHashId": "device" },
          "sessionControlInfo": { "ip": "control.example.test", "port": 443 },
          "connectionInfo": [
            { "usage": 14, "ip": "signaling.example.test", "port": 443, "resourcePath": "/nvst/" },
            { "usage": 2, "ip": "video.example.test", "port": 47998, "resourcePath": "" },
            { "usage": 17, "ip": "bundle.example.test", "port": 47998, "resourcePath": "" }
          ],
          "monitorSettings": [
            { "widthInPixels": 1920, "heightInPixels": 1080, "framesPerSecond": 60, "dpi": 96 }
          ],
          "finalizedStreamingFeatures": { "bitDepth": 8, "reflex": false }
        }
        """),
        streamingProfileJSON: streamingProfileJSON
    )
    let object = try #require(JSONSerialization.jsonObject(with: Data(sessionJSON.utf8)) as? [String: Any])
    let streamingProfile = try #require(object["streamingProfile"] as? [String: Any])
    let monitorSettings = try #require(object["monitorSettings"] as? [[String: Any]])
    let connectionInfo = try #require(object["connectionInfo"] as? [[String: Any]])
    let features = try #require(object["finalizedStreamingFeatures"] as? [String: Any])

    #expect(object["sessionId"] as? String == "native-session")
    #expect(object["appId"] as? Int == 123)
    #expect(object["appLaunchMode"] as? Int == 2)
    #expect(object["zoneAddress"] as? String == "control.example.test")
    #expect(object["zoneName"] as? String == "CONTROL")
    #expect(streamingProfile["streamingProfileGuid"] as? String == "profile-guid")
    #expect(streamingProfile["resolution"] as? String == "1920x1080")
    #expect(streamingProfile["fps"] as? Int == 60)
    #expect(monitorSettings.count == 1)
    #expect(monitorSettings[0]["widthInPixels"] as? Int == 1920)
    #expect(connectionInfo.count == 2)
    #expect(connectionInfo.contains { $0["usage"] as? Int == 17 } == false)
    #expect(connectionInfo.allSatisfy { $0["protocol"] as? Int == 2 })
    #expect(features["bitDepth"] as? Int == 8)
}

@Test func nativeNVSTGeronimoSessionJSONGeneratesStableOpenNOWProfileGuidWhenCloudSessionOmitsOne() throws {
    let streamingProfileJSON = try NativeNVSTBifrostTransport.streamingProfileJSON(
        rawSessionJSON: "{}",
        sessionInfoJSON: "{}",
        settingsJSON: """
        {
          "resolution": "1920x1080",
          "fps": 60,
          "codec": "H264",
          "audioModeFormat": "stereo"
        }
        """
    )
    let allocation = nativeAllocation(rawSessionJSON: """
    {
      "sessionId": "native-session",
      "sessionRequestData": { "appId": 123 },
      "sessionControlInfo": { "ip": "control.example.test" }
    }
    """, settingsJSON: """
    {
      "transportMode": "nvst",
      "codec": "H264",
      "audioModeFormat": "stereo"
    }
    """)
    let firstSessionJSON = try NativeNVSTBifrostTransport.geronimoSessionJSON(allocation: allocation, streamingProfileJSON: streamingProfileJSON)
    let secondSessionJSON = try NativeNVSTBifrostTransport.geronimoSessionJSON(allocation: allocation, streamingProfileJSON: streamingProfileJSON)
    let firstObject = try #require(JSONSerialization.jsonObject(with: Data(firstSessionJSON.utf8)) as? [String: Any])
    let secondObject = try #require(JSONSerialization.jsonObject(with: Data(secondSessionJSON.utf8)) as? [String: Any])
    let firstStreamingProfile = try #require(firstObject["streamingProfile"] as? [String: Any])
    let secondStreamingProfile = try #require(secondObject["streamingProfile"] as? [String: Any])
    let generatedGuid = try #require(firstStreamingProfile["streamingProfileGuid"] as? String)

    #expect(UUID(uuidString: generatedGuid) != nil)
    #expect(secondStreamingProfile["streamingProfileGuid"] as? String == generatedGuid)
    #expect(firstStreamingProfile["resolution"] as? String == "1920x1080")
    #expect(firstStreamingProfile["fps"] as? Int == 60)
    #expect(firstStreamingProfile["codec"] as? String == "H264")
    #expect(firstStreamingProfile["audioMode"] as? String == "stereo")
}

@Test func nativeNVSTGeronimoSessionJSONGeneratesMissingMonitorSettings() throws {
    let streamingProfileJSON = try NativeNVSTBifrostTransport.streamingProfileJSON(
        rawSessionJSON: """
        {
          "streamingProfile": { "streamingProfileGuid": "profile-guid", "resolution": "2560x1440", "fps": 120, "codec": "H264" }
        }
        """,
        sessionInfoJSON: "{}"
    )
    let sessionJSON = try NativeNVSTBifrostTransport.geronimoSessionJSON(
        allocation: nativeAllocation(rawSessionJSON: """
        {
          "sessionId": "native-session",
          "sessionRequestData": { "appId": 123 },
          "sessionControlInfo": { "ip": "control.example.test" }
        }
        """),
        streamingProfileJSON: streamingProfileJSON
    )
    let object = try #require(JSONSerialization.jsonObject(with: Data(sessionJSON.utf8)) as? [String: Any])
    let monitorSettings = try #require(object["monitorSettings"] as? [[String: Any]])

    #expect(monitorSettings.count == 1)
    #expect(monitorSettings[0]["widthInPixels"] as? Int == 2560)
    #expect(monitorSettings[0]["heightInPixels"] as? Int == 1440)
    #expect(monitorSettings[0]["framesPerSecond"] as? Int == 120)
}

@Test func nativeNVSTBifrostTransportUsesRawStreamingProfileWhenPresent() throws {
    let profileJSON = try NativeNVSTBifrostTransport.streamingProfileJSON(
        rawSessionJSON: """
        {
          "streamingProfile": { "streamingProfileGuid": "profile-guid", "fps": 60 },
          "negotiatedStreamProfile": { "fps": 30 }
        }
        """,
        sessionInfoJSON: "{}",
        settingsJSON: "{\"resolution\":\"1920x1080\",\"codec\":\"H264\"}"
    )
    let profile = try #require(JSONSerialization.jsonObject(with: Data(profileJSON.utf8)) as? [String: Any])
    let selectedVideoMode = try #require(profile["selectedVideoMode"] as? [String: Any])
    let selectedEncodeMode = try #require(profile["selectedEncodeMode"] as? [String: Any])
    let selectedFeatures = try #require(profile["selectedFeatures"] as? [String: Any])

    #expect(selectedVideoMode["width"] as? Int == 1920)
    #expect(selectedVideoMode["height"] as? Int == 1080)
    #expect(selectedVideoMode["fps"] as? Int == 60)
    #expect(selectedVideoMode["scaleFactor"] as? Int == 1)
    #expect(selectedEncodeMode["width"] as? Int == 1920)
    #expect(selectedEncodeMode["height"] as? Int == 1080)
    #expect(selectedEncodeMode["fps"] as? Int == 60)
    #expect(selectedFeatures["audioChannelCount"] as? Int == 2)
    #expect(selectedFeatures.keys.contains("prefilterParams"))
    #expect(selectedFeatures.keys.contains("hudStreamingParams"))
}

@Test func nativeNVSTBifrostTransportFallsBackToSessionInfoNegotiatedProfile() throws {
    let profileJSON = try NativeNVSTBifrostTransport.streamingProfileJSON(
        rawSessionJSON: """
        {
          "sessionId": "native-session",
          "status": 2
        }
        """,
        sessionInfoJSON: """
        {
          "negotiatedStreamProfile": {
            "resolution": "1920x1080",
            "fps": 60,
            "codec": "h264",
            "colorQuality": "SDR"
          }
        }
        """
    )
    let profile = try #require(JSONSerialization.jsonObject(with: Data(profileJSON.utf8)) as? [String: Any])
    let selectedVideoMode = try #require(profile["selectedVideoMode"] as? [String: Any])
    let selectedEncodeMode = try #require(profile["selectedEncodeMode"] as? [String: Any])
    let selectedFeatures = try #require(profile["selectedFeatures"] as? [String: Any])

    #expect(selectedVideoMode["width"] as? Int == 1920)
    #expect(selectedVideoMode["height"] as? Int == 1080)
    #expect(selectedVideoMode["fps"] as? Int == 60)
    #expect(selectedEncodeMode["fps"] as? Int == 60)
    #expect(selectedFeatures["hdr"] as? Bool == false)
    #expect(selectedFeatures["bitDepth"] as? Int == 8)
}

@Test func nativeNVSTBifrostTransportCompletesInvalidProfileFieldsFromSettings() throws {
    let profileJSON = try NativeNVSTBifrostTransport.streamingProfileJSON(
        rawSessionJSON: """
        {
          "streamingProfile": {
            "streamingProfileGuid": "profile-guid",
            "resolution": "",
            "fps": 0,
            "codec": "",
            "colorQuality": "8bit_420"
          }
        }
        """,
        sessionInfoJSON: "{}",
        settingsJSON: """
        {
          "resolution": "2560x1440",
          "fps": 120,
          "codec": "auto"
        }
        """
    )
    let profile = try #require(JSONSerialization.jsonObject(with: Data(profileJSON.utf8)) as? [String: Any])
    let selectedVideoMode = try #require(profile["selectedVideoMode"] as? [String: Any])
    let selectedEncodeMode = try #require(profile["selectedEncodeMode"] as? [String: Any])
    let selectedFeatures = try #require(profile["selectedFeatures"] as? [String: Any])

    #expect(selectedVideoMode["width"] as? Int == 2560)
    #expect(selectedVideoMode["height"] as? Int == 1440)
    #expect(selectedVideoMode["fps"] as? Int == 120)
    #expect(selectedEncodeMode["width"] as? Int == 2560)
    #expect(selectedEncodeMode["height"] as? Int == 1440)
    #expect(selectedEncodeMode["fps"] as? Int == 120)
    #expect(selectedFeatures["bitDepth"] as? Int == 8)
}

private func nativeConfiguration() -> StreamLaunchConfiguration {
    StreamLaunchConfiguration(title: "Native Test", applicationID: "123", accessToken: "token", accountLinked: true, selectedStore: "Steam")
}

private func nativeAllocation(rawSessionJSON: String = "{\"sessionId\":\"native-session\"}", authTokenType: String = "", authToken: String = "", settingsJSON: String = "{\"transportMode\":\"nvst\"}") -> NativeNVSTSessionAllocation {
    let session = StreamSessionDescriptor(id: "native-session", applicationID: "123", serverAddress: "server.example.test", title: "Native Test", metadata: ["transport": "nvst"])
    return NativeNVSTSessionAllocation(
        session: session,
        signalingServer: "server.example.test:443",
        signalingURL: "wss://server.example.test/nvst/",
        signalingQueryParameters: "token=abc",
        signalingHeaders: ["x-nv-sessionid.native-session"],
        streamingBaseURL: "https://stream.example.test/",
        mediaHost: "media.example.test",
        mediaPort: 47998,
        authTokenType: authTokenType,
        authToken: authToken,
        settingsJSON: settingsJSON,
        sessionInfoJSON: "{\"sessionId\":\"native-session\"}",
        rawSessionJSON: rawSessionJSON
    )
}
