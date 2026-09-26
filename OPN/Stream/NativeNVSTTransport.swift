//  The transport contract the streaming path drives, split out of `NativeNVSTStreamingPath` itself,
//  which is at its file-length budget. Every capability past the session lifecycle has a default.
public protocol NativeNVSTTransport: Sendable {
    func prepare() async throws -> NVSTNativeBridgeStatus
    func connect(allocation: NativeNVSTSessionAllocation, mediaReceiver: any NativeNVSTMediaReceiver) async throws -> NativeNVSTTransportConnection
    func send(_ event: UserInputEvent) async throws
    func sendAbsoluteMouseMove(_ event: NativeNVSTAbsoluteMouseEvent) async throws
    func setMicrophoneEnabled(_ enabled: Bool) async throws
    func setMicrophoneConfiguration(_ configuration: NativeNVSTMicrophoneConfiguration) async throws
    /// Swaps the microphone this session captures from, mid-stream. Only the capture unit is rebuilt:
    /// the seat's microphone contract was fixed at ANNOUNCE. Throws `notRunning` without a session.
    func setMicrophoneDevice(_ uid: String) async throws
    /// Whether the seat can carry microphone capture, and why not when it cannot. Asked when the HUD
    /// is opened, since the answer depends on the seat's DESCRIBE offer.
    func microphoneAvailability() async -> NativeNVSTMicrophoneAvailability
    /// The live capture level, 0...1. Driven from the CoreAudio render thread, so a receiver hops to
    /// its own queue and must never block.
    func setMicrophoneLevelHandler(_ handler: (@MainActor @Sendable (Double) -> Void)?) async
    /// The saved microphone went away and capture fell back to the system default. Carries the copy
    /// the HUD shows; the saved UID is deliberately not rewritten.
    func setMicrophoneFallbackHandler(_ handler: (@MainActor @Sendable (String) -> Void)?) async
    /// The set of input devices changed, so the picker's rows are stale — a microphone plugged in
    /// mid-stream has to become selectable without the HUD being closed and reopened.
    func setMicrophoneDeviceListHandler(_ handler: (@MainActor @Sendable () -> Void)?) async
    func setLocalAudioPlaybackMuted(_ muted: Bool) async throws
    func togglePerformanceOverlay() async throws
    func performanceSnapshot() async -> NativeNVSTPerformanceSnapshot?
    func setMaximumBitrateKbps(_ bitrateKbps: UInt32) async throws
    func setDynamicStreamingMode(_ mode: NativeNVSTDynamicStreamingMode) async throws
    func setL4SEnabled(_ enabled: Bool) async throws
    /// Applies the client-facing half of a VSync change to a running session. The seat-facing
    /// half was fixed at ANNOUNCE; see `NvstVsyncMode`. Throws `notRunning` without a session.
    func setVsyncMode(_ mode: NvstVsyncMode) async throws
    func updateGamepadTopology(_ topology: StreamGamepadTopology) async throws
    func startRecording(configuration: StreamRecordingConfiguration) async
    func stopRecording() async
    func setRecordingStatusHandler(_ handler: (@MainActor @Sendable (StreamRecordingStatus) -> Void)?) async
    /// Starts keeping a rolling window of the stream. Returns false when there is no session to
    /// buffer, so the caller never shows a window that will never fill.
    func startReplayBuffer(configuration: StreamReplayBufferConfiguration) async -> Bool
    func stopReplayBuffer() async
    func saveReplayClip() async
    func setReplayBufferStateHandler(_ handler: (@MainActor @Sendable (StreamReplayBufferState) -> Void)?) async
    /// Renders the next decoded frame to an image. Nil when no frame arrives before the capture
    /// times out, which is the honest answer for a paused or stalled stream.
    func takeScreenshot() async -> StreamScreenshotImage?
    func pause() async throws
    func disconnect() async
    func resetForRecovery() async
    func terminalEvents() async -> AsyncStream<NativeNVSTTransportTermination>
    func diagnosticMetadata() async -> [String: String]
}

public extension NativeNVSTTransport {
    func sendAbsoluteMouseMove(_ event: NativeNVSTAbsoluteMouseEvent) async throws {
        throw NativeNVSTError.notRunning
    }

    func performanceSnapshot() async -> NativeNVSTPerformanceSnapshot? {
        nil
    }

    func setMaximumBitrateKbps(_ bitrateKbps: UInt32) async throws { throw NativeNVSTError.notRunning }
    func setDynamicStreamingMode(_ mode: NativeNVSTDynamicStreamingMode) async throws { throw NativeNVSTError.notRunning }
    func setL4SEnabled(_ enabled: Bool) async throws { throw NativeNVSTError.notRunning }
    func setVsyncMode(_ mode: NvstVsyncMode) async throws { throw NativeNVSTError.notRunning }
    func updateGamepadTopology(_ topology: StreamGamepadTopology) async throws { throw NativeNVSTError.notRunning }
    func setMicrophoneConfiguration(_ configuration: NativeNVSTMicrophoneConfiguration) async throws {}
    func setMicrophoneDevice(_ uid: String) async throws { throw NativeNVSTError.notRunning }
    func microphoneAvailability() async -> NativeNVSTMicrophoneAvailability { .available }
    func setMicrophoneLevelHandler(_ handler: (@MainActor @Sendable (Double) -> Void)?) async {}
    func setMicrophoneFallbackHandler(_ handler: (@MainActor @Sendable (String) -> Void)?) async {}
    func setMicrophoneDeviceListHandler(_ handler: (@MainActor @Sendable () -> Void)?) async {}
    func setLocalAudioPlaybackMuted(_ muted: Bool) async throws { throw NativeNVSTError.notRunning }

    /// Recording is optional for a transport. The status handler is the only channel the UI
    /// listens on, so a transport that never installs one simply leaves the HUD at `.idle`.
    func startRecording(configuration: StreamRecordingConfiguration) async {}
    func stopRecording() async {}
    func setRecordingStatusHandler(_ handler: (@MainActor @Sendable (StreamRecordingStatus) -> Void)?) async {}

    /// Instant Replay is optional for the same reason, but a transport that cannot buffer says so
    /// rather than accepting the request and never emitting a state.
    func startReplayBuffer(configuration: StreamReplayBufferConfiguration) async -> Bool { false }
    func stopReplayBuffer() async {}
    func saveReplayClip() async {}
    func setReplayBufferStateHandler(_ handler: (@MainActor @Sendable (StreamReplayBufferState) -> Void)?) async {}

    func pause() async throws {
        throw NativeNVSTError.notRunning
    }

    func terminalEvents() async -> AsyncStream<NativeNVSTTransportTermination> {
        AsyncStream { $0.finish() }
    }

    func resetForRecovery() async { await disconnect() }
    func diagnosticMetadata() async -> [String: String] { [:] }
}
