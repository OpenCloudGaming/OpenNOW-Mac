import Foundation
import Testing
@testable import WebRTCMedia

private actor RecordingSessionProvider: StreamSessionProvider {
    private(set) var finished: [(StreamSessionDescriptor, StreamEndReason)] = []
    let offer: StreamOffer

    init(offer: StreamOffer) {
        self.offer = offer
    }

    func startSession(configuration: StreamLaunchConfiguration) async throws -> StreamOffer {
        offer
    }

    func finishSession(_ session: StreamSessionDescriptor, reason: StreamEndReason) async throws {
        finished.append((session, reason))
    }
}

private actor RecordingTransport: WebRTCStreamTransport {
    private(set) var connectedOffer: StreamOffer?
    private(set) var sentEvents: [UserInputEvent] = []
    private(set) var remoteCandidates: [StreamIceCandidate] = []
    private(set) var disconnected = false

    func connect(offer: StreamOffer, mediaReceiver: any MediaFrameReceiver) async throws -> StreamAnswer {
        connectedOffer = offer
        await mediaReceiver.receive(.audio(AudioFrame(
            trackID: "audio-main",
            timestamp: MediaTimestamp(nanoseconds: 1),
            durationNanoseconds: 20_000_000,
            sampleRate: 48_000,
            channelCount: 2,
            sampleFormat: .pcmInt16,
            payload: Data([1, 2])
        )))
        return StreamAnswer(sdp: "answer")
    }

    func addRemoteIceCandidate(_ candidate: StreamIceCandidate) async throws {
        remoteCandidates.append(candidate)
    }

    func send(_ event: UserInputEvent) async throws {
        sentEvents.append(event)
    }

    func disconnect() async {
        disconnected = true
    }
}

private actor ProgressRecorder {
    private(set) var values: [StreamProgress] = []

    func append(_ progress: StreamProgress) {
        values.append(progress)
    }
}

@Suite("WebRTCMediaSession")
struct WebRTCMediaSessionTests {
    @Test("routes video frames to media subscribers")
    func routesVideoFrames() async {
        let session = WebRTCMediaSession()
        let stream = await session.mediaFrames()
        let frame = VideoFrame(
            trackID: "video-main",
            timestamp: MediaTimestamp(nanoseconds: 42),
            durationNanoseconds: 16_666_667,
            dimensions: VideoDimensions(width: 1920, height: 1080),
            pixelFormat: .nv12,
            payload: Data([1, 2, 3])
        )

        await session.publish(.video(frame))
        var iterator = stream.makeAsyncIterator()
        let received = await iterator.next()

        #expect(received == .video(frame))
    }

    @Test("routes gamepad events to input subscribers")
    func routesGamepadEvents() async {
        let session = WebRTCMediaSession()
        let stream = await session.inputEvents()
        let state = GamepadState(
            deviceID: "controller-1",
            playerIndex: 0,
            buttons: [.south, .rightShoulder],
            leftTrigger: 0.25,
            rightTrigger: 1.2,
            leftStickX: -1.4,
            leftStickY: 0.5,
            rightStickX: 0.25,
            rightStickY: -0.75,
            timestamp: MediaTimestamp(nanoseconds: 100)
        )

        await session.publish(.gamepad(state))
        var iterator = stream.makeAsyncIterator()
        let received = await iterator.next()

        #expect(received == .gamepad(state))
        #expect(state.rightTrigger == 1)
        #expect(state.leftStickX == -1)
    }
}

@Suite("WebRTCStreamingPath")
struct WebRTCStreamingPathTests {
    @Test("maps mouse buttons to GFN protocol values")
    func mapsMouseButtonsToGFNProtocolValues() {
        #expect(NativeWebRTCTransport.gfnMouseButton(.left) == 1)
        #expect(NativeWebRTCTransport.gfnMouseButton(.middle) == 2)
        #expect(NativeWebRTCTransport.gfnMouseButton(.right) == 3)
        #expect(NativeWebRTCTransport.gfnMouseButton(.back) == 4)
        #expect(NativeWebRTCTransport.gfnMouseButton(.forward) == 5)
    }

    @Test("maps gamepad buttons to GFN protocol values")
    func mapsGamepadButtonsToGFNProtocolValues() {
        let buttons: GamepadButtons = [.south, .east, .west, .north, .leftShoulder, .rightShoulder, .select, .start, .leftStick, .rightStick, .dpadUp, .dpadDown, .dpadLeft, .dpadRight]

        #expect(NativeWebRTCTransport.gfnGamepadButtons(buttons) == 0xf3ff)
        #expect(NativeWebRTCTransport.gfnControllerBitmap(playerIndex: 0) & 0x0101 == 0x0101)
    }

    @Test("starts stream through provider and transport")
    func startsStream() async throws {
        let session = StreamSessionDescriptor(id: "session-1", applicationID: "100", serverAddress: "server", title: "Game")
        let offer = StreamOffer(session: session, sdp: "offer")
        let provider = RecordingSessionProvider(offer: offer)
        let transport = RecordingTransport()
        let path = WebRTCStreamingPath(sessionProvider: provider, transport: transport)
        let configuration = StreamLaunchConfiguration(title: "Game", applicationID: "100", accessToken: "token", accountLinked: true, selectedStore: "steam")
        let progressRecorder = ProgressRecorder()

        let mediaStream = await path.mediaFrames()
        let started = try await path.start(configuration: configuration) { progress in
            await progressRecorder.append(progress)
        }
        var iterator = mediaStream.makeAsyncIterator()
        let firstFrame = await iterator.next()
        let progressValues = await progressRecorder.values

        #expect(started == session)
        #expect(await transport.connectedOffer == offer)
        #expect(progressValues.map(\.currentStepIndex) == [0, 1, 2, 3, 4])
        #expect(progressValues.last?.isReady == true)
        #expect(firstFrame?.kind == .audio)
    }

    @Test("carries offer metadata into running session")
    func carriesOfferMetadataIntoRunningSession() async throws {
        let session = StreamSessionDescriptor(id: "session-settings", applicationID: "300", serverAddress: "server", title: "Game", metadata: ["accessToken": "token"])
        let settings = "{\"directMouseInput\":false,\"suppressInputWhenInactive\":true,\"microphoneMode\":\"push-to-talk\"}"
        let offer = StreamOffer(session: session, sdp: "offer", metadata: ["settings": settings])
        let provider = RecordingSessionProvider(offer: offer)
        let transport = RecordingTransport()
        let path = WebRTCStreamingPath(sessionProvider: provider, transport: transport)
        let configuration = StreamLaunchConfiguration(title: "Game", applicationID: "300", accessToken: "token", accountLinked: true, selectedStore: "steam")

        let started = try await path.start(configuration: configuration)

        #expect(started.metadata["accessToken"] == "token")
        #expect(started.metadata["settings"] == settings)
    }

    @Test("forwards input events and stops active session")
    func forwardsInputAndStops() async throws {
        let session = StreamSessionDescriptor(id: "session-2", applicationID: "200", serverAddress: "server", title: "Game")
        let provider = RecordingSessionProvider(offer: StreamOffer(session: session, sdp: "offer"))
        let transport = RecordingTransport()
        let path = WebRTCStreamingPath(sessionProvider: provider, transport: transport)
        let configuration = StreamLaunchConfiguration(title: "Game", applicationID: "200", accessToken: "token", accountLinked: true, selectedStore: "steam")
        let event = UserInputEvent.keyboard(KeyboardEvent(deviceID: "keyboard", keyCode: 10, scanCode: 20, isPressed: true, timestamp: MediaTimestamp(nanoseconds: 10)))

        _ = try await path.start(configuration: configuration)
        try await path.send(event)
        let report = try await path.stop(reason: .userRequested, message: "Stopped")

        #expect(await transport.sentEvents == [event])
        #expect(await transport.disconnected == true)
        let finished = await provider.finished
        #expect(finished.count == 1)
        #expect(finished.first?.0 == session)
        #expect(finished.first?.1 == .userRequested)
        #expect(report.success == true)
        #expect(report.message == "Stopped")
    }
}
