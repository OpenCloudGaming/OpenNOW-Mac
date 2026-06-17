import AppKit
import Foundation

public final class NativeWebRTCTransport: NSObject, WebRTCStreamTransport, @unchecked Sendable {
    private let session = OPNLibWebRTCStreamSession()
    private weak var nativeView: NSView?
    private var continuation: CheckedContinuation<StreamAnswer, Error>?

    public init(nativeView: NSView) {
        self.nativeView = nativeView
        super.init()
    }

    public func connect(offer: StreamOffer, mediaReceiver: any MediaFrameReceiver) async throws -> StreamAnswer {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            if let nativeView {
                session.setNativeWindow(Unmanaged.passUnretained(nativeView).toOpaque())
            }
            session.start(
                sessionInfo: offer.metadata["sessionInfoJSON"].flatMap(Self.dictionaryValue) ?? offer.metadata,
                offerSdp: offer.sdp,
                settings: offer.metadata["settings"].flatMap(Self.dictionaryValue) ?? [:],
                answerHandler: { [weak self] sdp, nvstSdp in
                    self?.resumeAnswer(StreamAnswer(sdp: sdp as String, metadata: ["nvstSdp": nvstSdp as String]))
                },
                localIceCandidateHandler: { _ in },
                stateHandler: { [weak self] connected, error in
                    guard !connected, !(error as String).isEmpty else { return }
                    self?.resumeError(NativeWebRTCTransportError.connectionFailed(error as String))
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

    public func disconnect() async {
        session.stop()
    }

    private func send(_ event: MouseEvent) {
        switch event {
        case .moved(_, let deltaX, let deltaY, _):
            session.sendMouseMove(dx: deltaX, dy: deltaY)
        case .button(_, let button, let isPressed, _):
            session.sendMouseButton(button: button.rawValue, down: isPressed)
        case .wheel(_, let delta, _):
            session.sendMouseWheel(delta: delta)
        }
    }

    private func send(_ state: GamepadState) {
        let buttons = UInt16(truncatingIfNeeded: state.buttons.rawValue)
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
            bitmap: 0xffff,
            timestampUs: state.timestamp.nanoseconds / 1_000
        )
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
        continuation.resume(returning: answer)
    }

    private func resumeError(_ error: Error) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(throwing: error)
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
