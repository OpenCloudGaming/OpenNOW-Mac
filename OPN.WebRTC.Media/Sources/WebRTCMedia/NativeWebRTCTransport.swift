import AppKit
import Foundation

public final class NativeWebRTCTransport: NSObject, WebRTCStreamTransport, @unchecked Sendable {
    public var onEnded: (@MainActor @Sendable (_ message: String) -> Void)?

    private let session = OPNLibWebRTCStreamSession()
    private weak var nativeView: NativeWebRTCStreamView?
    private var continuation: CheckedContinuation<StreamAnswer, Error>?
    private var statsTelemetryTask: Task<Void, Never>?
    private var isDisconnecting = false
    private var didEmitEnd = false

    public init(nativeView: NativeWebRTCStreamView) {
        self.nativeView = nativeView
        super.init()
    }

    public func connect(offer: StreamOffer, mediaReceiver: any MediaFrameReceiver) async throws -> StreamAnswer {
        WebRTCMediaTelemetry.capture("webrtc.transport.connect.start", level: .info, message: "Starting native WebRTC transport.", attributes: ["sessionId": offer.session.id, "applicationID": offer.session.applicationID])
        let nativeWindowAddress = await MainActor.run { nativeView.map { UInt(bitPattern: Unmanaged.passUnretained($0.nativeVideoView()).toOpaque()) } }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.isDisconnecting = false
            self.didEmitEnd = false
            session.setNativeWindow(nativeWindowAddress.map { UnsafeMutableRawPointer(bitPattern: $0) } ?? nil)
            session.start(
                sessionInfo: offer.metadata["sessionInfoJSON"].flatMap(Self.dictionaryValue) ?? offer.metadata,
                offerSdp: offer.sdp,
                settings: offer.metadata["settings"].flatMap(Self.dictionaryValue) ?? [:],
                answerHandler: { [weak self] sdp, nvstSdp in
                    self?.resumeAnswer(StreamAnswer(sdp: sdp as String, metadata: ["nvstSdp": nvstSdp as String]))
                },
                localIceCandidateHandler: { _ in },
                stateHandler: { [weak self] connected, error in
                    if connected {
                        WebRTCMediaTelemetry.capture("webrtc.transport.connected", level: .info, message: "Native WebRTC transport connected.", attributes: ["sessionId": offer.session.id])
                    }
                    guard !connected, !(error as String).isEmpty else { return }
                    self?.handleEnded(message: error as String)
                }
            )
        }
    }

    public func addRemoteIceCandidate(_ candidate: StreamIceCandidate) async throws {
        session.addRemoteIceCandidatePayload([
            "candidate": candidate.sdp,
            "sdpMid": candidate.sdpMid,
            "sdpMLineIndex": candidate.sdpMLineIndex,
        ])
    }

    public func send(_ event: UserInputEvent) async throws {
        sendNow(event)
    }

    public func sendNow(_ event: UserInputEvent) {
        switch event {
        case .keyboard(let keyboard):
            session.sendKey(keycode: keyboard.keyCode, scancode: keyboard.scanCode, modifiers: keyboard.modifiers.rawValue, down: keyboard.isPressed)
        case .mouse(let mouse):
            send(mouse)
        case .text(_, let value, _):
            session.sendUtf8Text(value)
        case .gamepad(let state):
            send(state)
        }
    }

    public func setMicrophoneEnabled(_ enabled: Bool) {
        session.setMicrophoneEnabled(enabled)
    }

    public func disconnect() async {
        WebRTCMediaTelemetry.capture("webrtc.transport.disconnect", level: .info, message: "Stopping native WebRTC transport.")
        isDisconnecting = true
        statsTelemetryTask?.cancel()
        statsTelemetryTask = nil
        session.stop()
    }

    public func latestStatsSnapshot() -> OPNStreamStatsSnapshot {
        session.latestStatsSnapshot()
    }

    public func statsSnapshots(intervalSeconds: Double = 1.0) -> AsyncStream<OPNStreamStatsSnapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { [session] continuation in
            let interval = max(0.25, intervalSeconds)
            let task = Task {
                while !Task.isCancelled {
                    continuation.yield(session.latestStatsSnapshot())
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func send(_ event: MouseEvent) {
        switch event {
        case .moved(_, let deltaX, let deltaY, _):
            session.sendMouseMove(dx: deltaX, dy: deltaY)
        case .button(_, let button, let isPressed, _):
            session.sendMouseButton(button: Self.gfnMouseButton(button), down: isPressed)
        case .wheel(_, let delta, _):
            session.sendMouseWheel(delta: delta)
        }
    }

    private func send(_ state: GamepadState) {
        let buttons = Self.gfnGamepadButtons(state.buttons)
        let bitmap = Self.gfnControllerBitmap(playerIndex: state.playerIndex)
        let leftTrigger = UInt8((state.leftTrigger * 255).rounded())
        let rightTrigger = UInt8((state.rightTrigger * 255).rounded())
        session.sendGamepadState(
            controllerId: UInt16(truncatingIfNeeded: state.playerIndex),
            buttons: buttons,
            leftTrigger: leftTrigger,
            rightTrigger: rightTrigger,
            leftStickX: Self.axisValue(state.leftStickX),
            leftStickY: Self.axisValue(state.leftStickY),
            rightStickX: Self.axisValue(state.rightStickX),
            rightStickY: Self.axisValue(state.rightStickY),
            connected: true,
            bitmap: bitmap,
            timestampUs: state.timestamp.nanoseconds / 1_000
        )
    }

    static func gfnMouseButton(_ button: MouseButton) -> UInt8 {
        switch button {
        case .left: 1
        case .middle: 2
        case .right: 3
        case .back: 4
        case .forward: 5
        }
    }

    static func gfnGamepadButtons(_ buttons: GamepadButtons) -> UInt16 {
        var value: UInt16 = 0
        if buttons.contains(.dpadUp) { value |= 0x0001 }
        if buttons.contains(.dpadDown) { value |= 0x0002 }
        if buttons.contains(.dpadLeft) { value |= 0x0004 }
        if buttons.contains(.dpadRight) { value |= 0x0008 }
        if buttons.contains(.start) { value |= 0x0010 }
        if buttons.contains(.select) { value |= 0x0020 }
        if buttons.contains(.leftStick) { value |= 0x0040 }
        if buttons.contains(.rightStick) { value |= 0x0080 }
        if buttons.contains(.leftShoulder) { value |= 0x0100 }
        if buttons.contains(.rightShoulder) { value |= 0x0200 }
        if buttons.contains(.south) { value |= 0x1000 }
        if buttons.contains(.east) { value |= 0x2000 }
        if buttons.contains(.west) { value |= 0x4000 }
        if buttons.contains(.north) { value |= 0x8000 }
        return value
    }

    static func gfnControllerBitmap(playerIndex: Int) -> UInt16 {
        let connectedCount = max(1, min(4, max(NativeWebRTCGamepadMonitor.connectedGamepadCount(), playerIndex + 1)))
        return (0..<connectedCount).reduce(UInt16(0)) { partial, index in
            partial | UInt16(1 << index) | UInt16(1 << (index + 8))
        }
    }

    private static func axisValue(_ value: Float) -> Int16 {
        Int16(max(Int(Int16.min), min(Int(Int16.max), Int((value * Float(Int16.max)).rounded()))))
    }

    private static func dictionaryValue(_ value: String) -> [String: Any]? {
        guard let data = value.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func resumeAnswer(_ answer: StreamAnswer) {
        guard let continuation else { return }
        self.continuation = nil
        WebRTCMediaTelemetry.capture("webrtc.transport.answer.created", level: .info, message: "Created local WebRTC answer.")
        startStatsTelemetry()
        continuation.resume(returning: answer)
    }

    private func resumeError(_ error: Error) {
        guard let continuation else { return }
        self.continuation = nil
        WebRTCMediaTelemetry.capture("webrtc.transport.error", level: .error, message: error.localizedDescription)
        statsTelemetryTask?.cancel()
        statsTelemetryTask = nil
        continuation.resume(throwing: error)
    }

    private func handleEnded(message: String) {
        if continuation != nil {
            resumeError(NativeWebRTCTransportError.connectionFailed(message))
            return
        }
        guard !isDisconnecting, !didEmitEnd else { return }
        didEmitEnd = true
        statsTelemetryTask?.cancel()
        statsTelemetryTask = nil
        WebRTCMediaTelemetry.capture("webrtc.transport.ended", level: .warning, message: message)
        Task { @MainActor [onEnded] in onEnded?(message) }
    }

    private func startStatsTelemetry() {
        statsTelemetryTask?.cancel()
        statsTelemetryTask = Task { [session] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                let stats = session.latestStatsSnapshot()
                guard stats.available else { continue }
                let attributes = ["codec": stats.codec, "resolution": stats.resolution]
                WebRTCMediaTelemetry.record("webrtc.media.latency_ms", kind: .gauge, value: stats.latencyMs, unit: "millisecond", attributes: attributes)
                WebRTCMediaTelemetry.record("webrtc.media.jitter_ms", kind: .gauge, value: stats.jitterMs, unit: "millisecond", attributes: attributes)
                WebRTCMediaTelemetry.record("webrtc.media.inbound_bitrate_mbps", kind: .gauge, value: stats.inboundBitrateMbps, unit: "megabit/second", attributes: attributes)
                WebRTCMediaTelemetry.record("webrtc.media.packet_loss_percent", kind: .gauge, value: stats.packetLossPercent, unit: "percent", attributes: attributes)
                WebRTCMediaTelemetry.record("webrtc.media.render_fps", kind: .gauge, value: stats.renderFps, attributes: attributes)
                WebRTCMediaTelemetry.record("webrtc.media.decode_time_ms", kind: .gauge, value: stats.decodeTimeMs, unit: "millisecond", attributes: attributes)
                WebRTCMediaTelemetry.record("webrtc.media.frame_interval_ms", kind: .gauge, value: stats.videoFrameIntervalMs, unit: "millisecond", attributes: attributes)
                WebRTCMediaTelemetry.record("webrtc.media.max_frame_interval_ms", kind: .gauge, value: stats.videoMaxFrameIntervalMs, unit: "millisecond", attributes: attributes)
            }
        }
    }
}

public enum NativeWebRTCTransportError: LocalizedError, Sendable {
    case connectionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let message):
            message
        }
    }
}
