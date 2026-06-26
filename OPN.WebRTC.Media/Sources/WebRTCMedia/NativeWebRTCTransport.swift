import AppKit
import CoreVideo
import Foundation
@preconcurrency import WebRTC

public final class NativeWebRTCTransport: NSObject, WebRTCStreamTransport, @unchecked Sendable {
    public var onEnded: (@MainActor @Sendable (_ message: String) -> Void)?
    public var onRecordingStatusChanged: (@MainActor @Sendable (_ status: WebRTCStreamRecordingStatus) -> Void)?
    public var onBroadcastStatusChanged: (@MainActor @Sendable (_ status: WebRTCLiveBroadcastStatus) -> Void)?

    private let session = OPNLibWebRTCStreamSession()
    private let recorder = WebRTCStreamRecorder()
    private let broadcaster = WebRTCLiveBroadcastSession()
    private weak var nativeView: NativeWebRTCStreamView?
    private let localIceLock = NSLock()
    private var localIceContinuation: AsyncStream<StreamIceCandidate>.Continuation?
    private var continuation: CheckedContinuation<StreamAnswer, Error>?
    private var statsTelemetryTask: Task<Void, Never>?
    private var isDisconnecting = false
    private var didEmitEnd = false

    public init(nativeView: NativeWebRTCStreamView) {
        self.nativeView = nativeView
        super.init()
        recorder.onStatusChanged = { [weak self] status in
            if status.isTerminal {
                self?.session.setEnhancedVideoFrameCaptureEnabled(false)
            }
            self?.onRecordingStatusChanged?(status)
        }
        broadcaster.onStatusChanged = { [weak self] status in
            if status.isTerminal {
                self?.session.setEnhancedVideoFrameCaptureEnabled(self?.recorder.wantsEnhancedVideo == true)
            }
            self?.onBroadcastStatusChanged?(status)
        }
    }

    public func connect(offer: StreamOffer, mediaReceiver: any MediaFrameReceiver) async throws -> StreamAnswer {
        WebRTCMediaTelemetry.capture("webrtc.transport.connect.start", level: .info, message: "Starting native WebRTC transport.", attributes: ["sessionId": offer.session.id, "applicationID": offer.session.applicationID])
        let nativeWindowAddress = await MainActor.run { nativeView.map { UInt(bitPattern: Unmanaged.passUnretained($0.nativeVideoView()).toOpaque()) } }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.isDisconnecting = false
            self.didEmitEnd = false
            self.session.onVideoFrame = { [weak self] framePointer in
                guard let framePointer else { return }
                let frame = Unmanaged<RTCVideoFrame>.fromOpaque(framePointer).takeUnretainedValue()
                self?.recorder.appendVideoFrame(frame)
                self?.broadcaster.appendVideoFrame(frame)
            }
            self.session.onEnhancedVideoFrame = { [weak self] pixelBufferPointer in
                guard let pixelBufferPointer else { return }
                let pixelBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(pixelBufferPointer).takeUnretainedValue()
                self?.recorder.appendEnhancedPixelBuffer(pixelBuffer)
                self?.broadcaster.appendEnhancedPixelBuffer(pixelBuffer)
            }
            self.session.onGameAudioFrame = { [weak self] audioBufferList, frameCount, sampleRate, channels in
                self?.recorder.appendGameAudio(audioBufferList: audioBufferList, frameCount: frameCount, sampleRate: sampleRate, channels: channels)
                self?.broadcaster.appendGameAudio(audioBufferList: audioBufferList, frameCount: frameCount, sampleRate: sampleRate, channels: channels)
            }
            self.session.onMicrophoneAudioFrame = { [weak self] audioBufferList, frameCount, sampleRate, channels in
                self?.broadcaster.appendMicrophoneAudio(audioBufferList: audioBufferList, frameCount: frameCount, sampleRate: sampleRate, channels: channels)
            }
            session.setNativeWindow(nativeWindowAddress.map { UnsafeMutableRawPointer(bitPattern: $0) } ?? nil)
            session.start(
                sessionInfo: offer.metadata["sessionInfoJSON"].flatMap(Self.dictionaryValue) ?? offer.metadata,
                offerSdp: offer.sdp,
                settings: offer.metadata["settings"].flatMap(Self.dictionaryValue) ?? [:],
                answerHandler: { [weak self] sdp, nvstSdp in
                    self?.resumeAnswer(StreamAnswer(sdp: sdp as String, metadata: ["nvstSdp": nvstSdp as String]))
                },
                localIceCandidateHandler: { [weak self] payload in
                    self?.handleLocalIceCandidate(payload as NSDictionary)
                },
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

    public func localIceCandidates() -> AsyncStream<StreamIceCandidate> {
        AsyncStream(bufferingPolicy: .bufferingNewest(120)) { continuation in
            localIceLock.withLock { localIceContinuation = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.localIceLock.withLock { self?.localIceContinuation = nil }
            }
        }
    }

    public func send(_ event: UserInputEvent) async throws {
        sendNow(event)
    }

    public func sendNow(_ event: UserInputEvent) {
        switch event {
        case .keyboard(let keyboard):
            let codes = Self.keyboardCodes(forMacKeyCode: keyboard.keyCode)
            session.sendKey(keycode: codes.keyCode, scancode: codes.scanCode, modifiers: keyboard.modifiers.rawValue, down: keyboard.isPressed)
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

    public func setLocalVideoEnhancement(mode: Int, sharpness: Int, denoise: Int, targetHeight: Int) {
        session.setLocalVideoEnhancement(mode: mode, sharpness: sharpness, denoise: denoise, targetHeight: targetHeight)
    }

    public func startRecording(configuration: WebRTCStreamRecordingConfiguration) {
        session.setEnhancedVideoFrameCaptureEnabled(configuration.enhancedVideoEnabled || broadcaster.wantsEnhancedVideo)
        recorder.start(configuration: configuration)
    }

    public func stopRecording() {
        recorder.stop()
        session.setEnhancedVideoFrameCaptureEnabled(broadcaster.wantsEnhancedVideo)
    }

    public func startBroadcast(configuration: WebRTCLiveBroadcastConfiguration) {
        session.setEnhancedVideoFrameCaptureEnabled(configuration.enhancedVideoEnabled || recorder.wantsEnhancedVideo)
        broadcaster.start(configuration: configuration)
    }

    public func stopBroadcast() {
        broadcaster.stop()
        session.setEnhancedVideoFrameCaptureEnabled(recorder.wantsEnhancedVideo)
    }

    public func disconnect() async {
        WebRTCMediaTelemetry.capture("webrtc.transport.disconnect", level: .info, message: "Stopping native WebRTC transport.")
        isDisconnecting = true
        statsTelemetryTask?.cancel()
        statsTelemetryTask = nil
        let pendingContinuation = continuation
        continuation = nil
        recorder.stop()
        broadcaster.stop()
        session.setEnhancedVideoFrameCaptureEnabled(false)
        localIceLock.withLock {
            localIceContinuation?.finish()
            localIceContinuation = nil
        }
        session.stop()
        pendingContinuation?.resume(throwing: CancellationError())
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

    private static func stringValue(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSString { return value as String }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }

    private static func intValue(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }

    private static func keyboardCodes(forMacKeyCode macKeyCode: UInt16) -> (keyCode: UInt16, scanCode: UInt16) {
        keyboardCodeMap[macKeyCode] ?? (macKeyCode, macKeyCode)
    }

    private static let keyboardCodeMap: [UInt16: (keyCode: UInt16, scanCode: UInt16)] = [
        0: (65, 0x1e),
        1: (83, 0x1f),
        2: (68, 0x20),
        3: (70, 0x21),
        4: (72, 0x23),
        5: (71, 0x22),
        6: (90, 0x2c),
        7: (88, 0x2d),
        8: (67, 0x2e),
        9: (86, 0x2f),
        10: (192, 0x29),
        11: (66, 0x30),
        12: (81, 0x10),
        13: (87, 0x11),
        14: (69, 0x12),
        15: (82, 0x13),
        16: (89, 0x15),
        17: (84, 0x14),
        18: (49, 0x02),
        19: (50, 0x03),
        20: (51, 0x04),
        21: (52, 0x05),
        22: (54, 0x07),
        23: (53, 0x06),
        24: (187, 0x0d),
        25: (57, 0x0a),
        26: (55, 0x08),
        27: (189, 0x0c),
        28: (56, 0x09),
        29: (48, 0x0b),
        30: (221, 0x1b),
        31: (79, 0x18),
        32: (85, 0x16),
        33: (219, 0x1a),
        34: (73, 0x17),
        35: (80, 0x19),
        36: (13, 0x1c),
        37: (76, 0x26),
        38: (74, 0x24),
        39: (222, 0x28),
        40: (75, 0x25),
        41: (186, 0x27),
        42: (220, 0x2b),
        43: (188, 0x33),
        44: (191, 0x35),
        45: (78, 0x31),
        46: (77, 0x32),
        47: (190, 0x34),
        48: (9, 0x0f),
        49: (32, 0x39),
        50: (192, 0x29),
        51: (8, 0x0e),
        53: (27, 0x01),
        65: (110, 0x53),
        67: (106, 0x37),
        69: (107, 0x4e),
        71: (12, 0x45),
        75: (111, 0x35),
        76: (13, 0x1c),
        78: (109, 0x4a),
        81: (187, 0x0d),
        82: (96, 0x52),
        83: (97, 0x4f),
        84: (98, 0x50),
        85: (99, 0x51),
        86: (100, 0x4b),
        87: (101, 0x4c),
        88: (102, 0x4d),
        89: (103, 0x47),
        91: (104, 0x48),
        92: (105, 0x49),
        96: (116, 0x3f),
        97: (117, 0x40),
        98: (118, 0x41),
        99: (114, 0x3d),
        100: (119, 0x42),
        101: (120, 0x43),
        103: (122, 0x44),
        105: (124, 0x64),
        106: (127, 0x6a),
        107: (145, 0x46),
        109: (121, 0x44),
        111: (123, 0x58),
        114: (45, 0x52),
        115: (36, 0x47),
        116: (33, 0x49),
        117: (46, 0x53),
        118: (115, 0x3e),
        119: (35, 0x4f),
        120: (113, 0x3c),
        121: (34, 0x51),
        122: (112, 0x3b),
        123: (37, 0x4b),
        124: (39, 0x4d),
        125: (40, 0x50),
        126: (38, 0x48)
    ]

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

    private func handleLocalIceCandidate(_ payload: NSDictionary) {
        let candidate = Self.stringValue(payload["candidate"])
        guard !candidate.isEmpty else { return }
        let iceCandidate = StreamIceCandidate(
            sdp: candidate,
            sdpMid: Self.stringValue(payload["sdpMid"]),
            sdpMLineIndex: Self.intValue(payload["sdpMLineIndex"])
        )
        _ = localIceLock.withLock { localIceContinuation?.yield(iceCandidate) }
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
