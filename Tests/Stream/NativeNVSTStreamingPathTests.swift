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

private func nativeConfiguration() -> StreamLaunchConfiguration {
    StreamLaunchConfiguration(title: "Native Test", applicationID: "123", accessToken: "token", accountLinked: true, selectedStore: "Steam")
}

private func nativeAllocation(rawSessionJSON: String = "{\"sessionId\":\"native-session\"}") -> NativeNVSTSessionAllocation {
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
        settingsJSON: "{\"transportMode\":\"nvst\"}",
        sessionInfoJSON: "{\"sessionId\":\"native-session\"}",
        rawSessionJSON: rawSessionJSON
    )
}
