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

private actor CancellableSessionProvider: StreamSessionProvider, StreamSessionStartCancellable {
    private var startContinuation: CheckedContinuation<StreamOffer, Error>?
    private var waitingContinuation: CheckedContinuation<Void, Never>?
    private(set) var cancelCount = 0

    func startSession(configuration: StreamLaunchConfiguration) async throws -> StreamOffer {
        try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            waitingContinuation?.resume()
            waitingContinuation = nil
        }
    }

    func finishSession(_ session: StreamSessionDescriptor, reason: StreamEndReason) async throws {}

    func cancelSessionStart() async {
        cancelCount += 1
        startContinuation?.resume(throwing: CancellationError())
        startContinuation = nil
    }

    func waitUntilStarted() async {
        guard startContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            waitingContinuation = continuation
        }
    }
}

private actor RecordingTransport: WebRTCStreamTransport {
    private(set) var connectedOffer: StreamOffer?
    private(set) var sentEvents: [UserInputEvent] = []
    private(set) var remoteCandidates: [StreamIceCandidate] = []
    private(set) var disconnected = false
    private var localIceContinuation: AsyncStream<StreamIceCandidate>.Continuation?

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

    nonisolated func localIceCandidates() -> AsyncStream<StreamIceCandidate> {
        AsyncStream(bufferingPolicy: .bufferingNewest(120)) { continuation in
            Task { await self.setLocalIceContinuation(continuation) }
        }
    }

    func yieldLocalIceCandidate(_ candidate: StreamIceCandidate) {
        localIceContinuation?.yield(candidate)
    }

    func send(_ event: UserInputEvent) async throws {
        sentEvents.append(event)
    }

    func disconnect() async {
        disconnected = true
        localIceContinuation?.finish()
        localIceContinuation = nil
    }

    private func setLocalIceContinuation(_ continuation: AsyncStream<StreamIceCandidate>.Continuation) {
        localIceContinuation = continuation
    }
}

private actor RecordingSignaling: StreamSignalingChannel {
    private(set) var sentAnswer: StreamAnswer?
    private(set) var sentLocalCandidates: [StreamIceCandidate] = []
    private var remoteIceContinuation: AsyncStream<StreamIceCandidate>.Continuation?

    func sendAnswer(_ answer: StreamAnswer, for session: StreamSessionDescriptor) async throws {
        sentAnswer = answer
    }

    func sendLocalIceCandidate(_ candidate: StreamIceCandidate, for session: StreamSessionDescriptor) async throws {
        sentLocalCandidates.append(candidate)
    }

    nonisolated func remoteIceCandidates(for session: StreamSessionDescriptor) async throws -> AsyncStream<StreamIceCandidate> {
        AsyncStream(bufferingPolicy: .bufferingNewest(120)) { continuation in
            Task { await self.setRemoteIceContinuation(continuation) }
        }
    }

    func yieldRemoteIceCandidate(_ candidate: StreamIceCandidate) {
        remoteIceContinuation?.yield(candidate)
    }

    private func setRemoteIceContinuation(_ continuation: AsyncStream<StreamIceCandidate>.Continuation) {
        remoteIceContinuation = continuation
    }
}

private actor ProgressRecorder {
    private(set) var values: [StreamProgress] = []

    func append(_ progress: StreamProgress) {
        values.append(progress)
    }
}

private actor RecordingStatusRecorder {
    private(set) var values: [WebRTCStreamRecordingStatus] = []

    func append(_ status: WebRTCStreamRecordingStatus) {
        values.append(status)
    }

    func terminalStatus() -> WebRTCStreamRecordingStatus? {
        values.first { $0.isTerminal }
    }
}

@Suite("WebRTCMediaSession")
struct WebRTCMediaSessionTests {
    @Test("extracts numeric IPv4 addresses for direct ICE fallback")
    func extractsNumericIPv4Addresses() {
        #expect(extractPublicIp("66.22.138.138") == "66.22.138.138")
        #expect(extractPublicIp("66-22-138-138.cloudmatchbeta.nvidiagrid.net") == "66.22.138.138")
        #expect(extractPublicIp("https://66-22-138-138.cloudmatchbeta.nvidiagrid.net/nvst/sign_in") == "66.22.138.138")
        #expect(extractPublicIp("not-a-valid-local-host.invalid") == "")
    }

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

    @Test("stopping recording before first video frame fails without crashing")
    func stoppingRecordingBeforeFirstFrameFailsWithoutCrashing() async throws {
        let recorder = WebRTCStreamRecorder()
        let statuses = RecordingStatusRecorder()
        recorder.onStatusChanged = { status in
            Task { await statuses.append(status) }
        }

        recorder.start(configuration: WebRTCStreamRecordingConfiguration(
            title: "Crash Regression",
            applicationID: "100",
            width: 1280,
            height: 720,
            fps: 60,
            videoBitrateMbps: 8,
            audioBitrateKbps: 128,
            enhancedVideoEnabled: false
        ))
        try await Task.sleep(for: .milliseconds(100))
        recorder.stop()

        var terminalStatus: WebRTCStreamRecordingStatus?
        for _ in 0..<20 {
            terminalStatus = await statuses.terminalStatus()
            if terminalStatus != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(terminalStatus == .failed("Recording stopped before any video frames were captured."))
    }
}

@Suite("WebRTCStreamingPath")
struct WebRTCStreamingPathTests {
    @Test("resolves CloudMatch controller settings without virtual HID advertisement")
    func resolvesCloudMatchControllerSettingsWithoutVirtualHIDAdvertisement() {
        let settings = WebRTCMediaStreamSettingsResolver.resolve(
            profile: WebRTCMediaStreamProfile(),
            capabilities: WebRTCMediaDeviceCapabilities(connectedGamepadCount: 1)
        )

        #expect(settings.remoteControllersBitmap == 0x1)
        #expect(settings.supportedHidDevices == 0)
        #expect(settings.availableSupportedControllers.isEmpty)
        #expect(settings.upscalingMode == 0)
    }

    @Test("keeps H265 for native WebRTC")
    func keepsH265ForNativeWebRTC() {
        let settings = WebRTCMediaStreamSettingsResolver.resolve(
            profile: WebRTCMediaStreamProfile(codec: "H265", colorQuality: "10bit_420"),
            capabilities: WebRTCMediaDeviceCapabilities(h265HardwareDecodeSupported: true),
            libWebRTCAvailable: true
        )

        #expect(settings.codec == "H265")
        #expect(settings.colorQuality == "10bit_420")
    }

    @Test("keeps AV1 ten bit color when available")
    func keepsAV1TenBitColorWhenAvailable() {
        let settings = WebRTCMediaStreamSettingsResolver.resolve(
            profile: WebRTCMediaStreamProfile(codec: "AV1", colorQuality: "10bit_420"),
            capabilities: WebRTCMediaDeviceCapabilities(av1HardwareDecodeSupported: true),
            libWebRTCAvailable: true
        )

        #expect(settings.codec == "AV1")
        #expect(settings.colorQuality == "10bit_420")
    }

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

    @Test("cancels in-flight stream startup")
    func cancelsInFlightStreamStartup() async throws {
        let provider = CancellableSessionProvider()
        let transport = RecordingTransport()
        let path = WebRTCStreamingPath(sessionProvider: provider, transport: transport)
        let configuration = StreamLaunchConfiguration(title: "Game", applicationID: "500", accessToken: "token", accountLinked: true, selectedStore: "steam")

        let task = Task { try await path.start(configuration: configuration) }
        await provider.waitUntilStarted()
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected stream startup cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(await provider.cancelCount == 1)
        #expect(await transport.disconnected == true)
    }

    @Test("forwards remote ICE candidates through signaling")
    func forwardsRemoteIceCandidates() async throws {
        let session = StreamSessionDescriptor(id: "session-ice", applicationID: "400", serverAddress: "server", title: "Game")
        let provider = RecordingSessionProvider(offer: StreamOffer(session: session, sdp: "offer"))
        let transport = RecordingTransport()
        let signaling = RecordingSignaling()
        let path = WebRTCStreamingPath(sessionProvider: provider, transport: transport, signaling: signaling)
        let configuration = StreamLaunchConfiguration(title: "Game", applicationID: "400", accessToken: "token", accountLinked: true, selectedStore: "steam")
        let remoteCandidate = StreamIceCandidate(sdp: "candidate:remote", sdpMid: "0", sdpMLineIndex: 0)

        _ = try await path.start(configuration: configuration)
        try await Task.sleep(for: .milliseconds(100))
        await signaling.yieldRemoteIceCandidate(remoteCandidate)
        try await Task.sleep(for: .milliseconds(100))

        #expect(await transport.remoteCandidates == [remoteCandidate])
        #expect(await signaling.sentAnswer?.sdp == "answer")
        #expect(await signaling.sentLocalCandidates.isEmpty)
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
