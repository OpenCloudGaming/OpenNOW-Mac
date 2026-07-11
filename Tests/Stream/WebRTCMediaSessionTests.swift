import Foundation
import Testing
@testable import OpenNOW

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
    private var remoteEndContinuation: AsyncStream<String>.Continuation?

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

    nonisolated func remoteEndEvents(for session: StreamSessionDescriptor) async throws -> AsyncStream<String> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            Task { await self.setRemoteEndContinuation(continuation) }
        }
    }

    func yieldRemoteIceCandidate(_ candidate: StreamIceCandidate) {
        remoteIceContinuation?.yield(candidate)
    }

    func yieldRemoteEnd(_ message: String) {
        remoteEndContinuation?.yield(message)
    }

    private func setRemoteIceContinuation(_ continuation: AsyncStream<StreamIceCandidate>.Continuation) {
        remoteIceContinuation = continuation
    }

    private func setRemoteEndContinuation(_ continuation: AsyncStream<String>.Continuation) {
        remoteEndContinuation = continuation
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

    @Test("rewrites embedded SDP ICE candidates with media endpoint")
    func rewritesEmbeddedSdpIceCandidates() {
        let sdp = """
        v=0
        m=video 9 UDP/TLS/RTP/SAVPF 96
        a=candidate:1 1 udp 2130706431 10.0.0.1 47998 typ host generation 0 ufrag serverUfrag
        a=mid:0
        """

        let rewritten = rewriteEmbeddedIceCandidates(sdp, ip: "66.22.138.138", port: 49000)

        #expect(rewritten.contains("a=candidate:1 1 udp 2130706431 66.22.138.138 47998 typ host generation 0 ufrag serverUfrag"))
        #expect(iceUsernameFragment(fromCandidate: "candidate:1 1 udp 1 66.22.138.138 49000 typ host ufrag serverUfrag") == "serverUfrag")
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
        #expect(settings.upscalingSharpness == 10)
    }

    @Test("normalizes legacy upscaling modes to MetalFX")
    func normalizesLegacyUpscalingModesToMetalFX() {
        for legacyMode in 1...4 {
            let settings = WebRTCMediaStreamSettingsResolver.resolve(
                profile: WebRTCMediaStreamProfile(upscalingMode: legacyMode),
                capabilities: WebRTCMediaDeviceCapabilities()
            )

            #expect(settings.upscalingMode == 3)
        }
    }

    @Test("disables MetalFX upscaling for low latency mode")
    func disablesMetalFXUpscalingForLowLatencyMode() {
        let settings = WebRTCMediaStreamSettingsResolver.resolve(
            profile: WebRTCMediaStreamProfile(lowLatencyMode: true, upscalingMode: 3, upscalingSharpness: 12, upscalingDenoise: 7),
            capabilities: WebRTCMediaDeviceCapabilities()
        )

        #expect(settings.upscalingMode == 0)
        #expect(settings.upscalingSharpness == 12)
        #expect(settings.upscalingDenoise == 7)
    }

    @Test("uses competitive stream profile for low latency mode")
    func usesCompetitiveStreamProfileForLowLatencyMode() {
        let settings = WebRTCMediaStreamSettingsResolver.resolve(
            profile: WebRTCMediaStreamProfile(lowLatencyMode: true),
            capabilities: WebRTCMediaDeviceCapabilities()
        )
        let dictionary = settings.dictionary(gameLanguage: "en_US", accountLinked: true, selectedStore: "steam")

        #expect(settings.streamingQualityProfile == 2)
        #expect(dictionary["streamingQualityProfile"] as? Int == 2)
    }

    @Test("keeps balanced stream profile outside low latency mode")
    func keepsBalancedStreamProfileOutsideLowLatencyMode() {
        let settings = WebRTCMediaStreamSettingsResolver.resolve(
            profile: WebRTCMediaStreamProfile(lowLatencyMode: false),
            capabilities: WebRTCMediaDeviceCapabilities()
        )

        #expect(settings.streamingQualityProfile == 0)
    }

    @Test("caps high resolution and bitrate for low latency mode")
    func capsHighResolutionAndBitrateForLowLatencyMode() {
        let settings = WebRTCMediaStreamSettingsResolver.resolve(
            profile: WebRTCMediaStreamProfile(
                resolution: WebRTCMediaResolution(width: 2880, height: 1800),
                maxBitrateMbps: 50,
                lowLatencyMode: true
            ),
            capabilities: WebRTCMediaDeviceCapabilities()
        )

        #expect(settings.resolution == "1920x1200")
        #expect(settings.maxBitrateMbps == 25)
    }

    @Test("preserves high resolution and bitrate outside low latency mode")
    func preservesHighResolutionAndBitrateOutsideLowLatencyMode() {
        let settings = WebRTCMediaStreamSettingsResolver.resolve(
            profile: WebRTCMediaStreamProfile(
                resolution: WebRTCMediaResolution(width: 2880, height: 1800),
                maxBitrateMbps: 50,
                lowLatencyMode: false
            ),
            capabilities: WebRTCMediaDeviceCapabilities()
        )

        #expect(settings.resolution == "2880x1800")
        #expect(settings.maxBitrateMbps == 50)
    }

    @Test("carries display sleep prevention setting into resolved metadata")
    func carriesDisplaySleepPreventionSettingIntoResolvedMetadata() {
        let settings = WebRTCMediaStreamSettingsResolver.resolve(
            profile: WebRTCMediaStreamProfile(preventDisplaySleepWhileStreaming: false),
            capabilities: WebRTCMediaDeviceCapabilities()
        )
        let dictionary = settings.dictionary(gameLanguage: "en_US", accountLinked: true, selectedStore: "steam")

        #expect(!settings.preventDisplaySleepWhileStreaming)
        #expect(dictionary["preventDisplaySleepWhileStreaming"] as? Bool == false)
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
        let remoteCandidate = StreamIceCandidate(sdp: "candidate:remote ufrag remoteUfrag", sdpMid: "0", sdpMLineIndex: 0, usernameFragment: "remoteUfrag")

        _ = try await path.start(configuration: configuration)
        try await Task.sleep(for: .milliseconds(100))
        await signaling.yieldRemoteIceCandidate(remoteCandidate)
        try await Task.sleep(for: .milliseconds(100))

        #expect(await transport.remoteCandidates == [remoteCandidate])
        #expect(await signaling.sentAnswer?.sdp == "answer")
        #expect(await signaling.sentLocalCandidates.isEmpty)
    }

    @Test("does not forward remote end-of-candidates to transport")
    func doesNotForwardRemoteEndOfCandidates() async throws {
        let session = StreamSessionDescriptor(id: "session-ice-end", applicationID: "402", serverAddress: "server", title: "Game")
        let provider = RecordingSessionProvider(offer: StreamOffer(session: session, sdp: "offer"))
        let transport = RecordingTransport()
        let signaling = RecordingSignaling()
        let path = WebRTCStreamingPath(sessionProvider: provider, transport: transport, signaling: signaling)
        let configuration = StreamLaunchConfiguration(title: "Game", applicationID: "402", accessToken: "token", accountLinked: true, selectedStore: "steam")

        _ = try await path.start(configuration: configuration)
        try await Task.sleep(for: .milliseconds(100))
        await signaling.yieldRemoteIceCandidate(.endOfCandidates)
        try await Task.sleep(for: .milliseconds(100))

        #expect(await transport.remoteCandidates.isEmpty)
    }

    @Test("forwards local ICE candidates through signaling by default")
    func forwardsLocalIceCandidatesByDefault() async throws {
        let session = StreamSessionDescriptor(id: "session-local-ice", applicationID: "401", serverAddress: "server", title: "Game")
        let provider = RecordingSessionProvider(offer: StreamOffer(session: session, sdp: "offer"))
        let transport = RecordingTransport()
        let signaling = RecordingSignaling()
        let path = WebRTCStreamingPath(sessionProvider: provider, transport: transport, signaling: signaling)
        let configuration = StreamLaunchConfiguration(title: "Game", applicationID: "401", accessToken: "token", accountLinked: true, selectedStore: "steam")
        let localCandidate = StreamIceCandidate(sdp: "candidate:local", sdpMid: "0", sdpMLineIndex: 0, usernameFragment: "localUfrag")

        _ = try await path.start(configuration: configuration)
        try await Task.sleep(for: .milliseconds(100))
        await transport.yieldLocalIceCandidate(localCandidate)
        try await Task.sleep(for: .milliseconds(100))

        #expect(await signaling.sentLocalCandidates == [localCandidate])
    }

    @Test("remote end transitions active stream to ended")
    func remoteEndTransitionsActiveStreamToEnded() async throws {
        let session = StreamSessionDescriptor(id: "session-remote-end", applicationID: "403", serverAddress: "server", title: "Game")
        let provider = RecordingSessionProvider(offer: StreamOffer(session: session, sdp: "offer"))
        let transport = RecordingTransport()
        let signaling = RecordingSignaling()
        let path = WebRTCStreamingPath(sessionProvider: provider, transport: transport, signaling: signaling)
        let configuration = StreamLaunchConfiguration(title: "Game", applicationID: "403", accessToken: "token", accountLinked: true, selectedStore: "steam")

        _ = try await path.start(configuration: configuration)
        try await Task.sleep(for: .milliseconds(100))
        await signaling.yieldRemoteEnd("peerRemoved")
        try await Task.sleep(for: .milliseconds(100))

        if case .ended(let report) = await path.currentState() {
            #expect(report.reason == .remoteEnded)
            #expect(report.message == "peerRemoved")
        } else {
            Issue.record("Expected path to transition to ended after remote end")
        }
        #expect(await transport.disconnected)
        #expect(await provider.finished.map(\.1) == [.remoteEnded])
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

    @Test("disables unsupported vendor prefilter modes")
    func disablesUnsupportedVendorPrefilterModes() {
        let resolved = WebRTCMediaStreamSettingsResolver.resolve(
            profile: WebRTCMediaStreamProfile(prefilterMode: 2, prefilterSharpness: 7, prefilterDenoise: 4, prefilterModel: 3),
            capabilities: WebRTCMediaDeviceCapabilities(),
            cloudVariables: WebRTCMediaCloudVariables(fetched: true, supportedPrefilterModes: [0, 1])
        )

        #expect(resolved.prefilterMode == 0)
        #expect(resolved.prefilterSharpness == 0)
        #expect(resolved.prefilterDenoise == 0)
        #expect(resolved.prefilterModel == 0)
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
