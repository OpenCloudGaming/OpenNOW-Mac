import Foundation

public struct NativeNVSTEncodedInputEvent: Equatable, Sendable {
    public let event: UserInputEvent
    public let payload: Data
    public let partiallyReliable: Bool

    public init(event: UserInputEvent, payload: Data, partiallyReliable: Bool) {
        self.event = event
        self.payload = payload
        self.partiallyReliable = partiallyReliable
    }
}

public final class NativeNVSTInputEncoder: @unchecked Sendable {
    private let lock = NSLock()
    private let encoder = OPNInputProtocolEncoder()
    private var inputConfiguration: NVSTInputTransportConfiguration

    public init(inputConfiguration: NVSTInputTransportConfiguration = .fallback, protocolVersion: UInt16 = 2) {
        self.inputConfiguration = inputConfiguration
        encoder.setProtocolVersion(protocolVersion)
    }

    public func configure(_ configuration: NVSTInputTransportConfiguration) {
        lock.withLock { inputConfiguration = configuration }
    }

    public func setProtocolVersion(_ version: UInt16) {
        lock.withLock { encoder.setProtocolVersion(version) }
    }

    public func encode(_ event: UserInputEvent) -> NativeNVSTEncodedInputEvent? {
        lock.withLock {
            let timestamp = OPNInputProtocolEncoder.timestampUs()
            switch event {
            case .keyboard(let keyboard):
                let payload = encoder.encodeKey(keycode: keyboard.keyCode, scancode: keyboard.scanCode, modifiers: keyboard.modifiers.rawValue, timestampUs: timestamp, down: keyboard.isPressed)
                return NativeNVSTEncodedInputEvent(event: event, payload: payload, partiallyReliable: false)
            case .mouse(let mouse):
                return encodeMouse(mouse, source: event, timestampUs: timestamp)
            case .text(_, let value, _):
                let payload = encoder.encodeUtf8Text(value)
                guard !payload.isEmpty else { return nil }
                return NativeNVSTEncodedInputEvent(event: event, payload: payload, partiallyReliable: false)
            case .gamepad(let gamepad):
                return encodeGamepad(gamepad, source: event, timestampUs: timestamp)
            }
        }
    }

    private func encodeMouse(_ mouse: MouseEvent, source: UserInputEvent, timestampUs: UInt64) -> NativeNVSTEncodedInputEvent {
        switch mouse {
        case .moved(_, let deltaX, let deltaY, _):
            let partiallyReliable = inputConfiguration.partialReliableEnabled && inputConfiguration.partiallyReliableHIDMask != 0
            return NativeNVSTEncodedInputEvent(event: source, payload: encoder.encodeMouseMove(dx: deltaX, dy: deltaY, timestampUs: timestampUs), partiallyReliable: partiallyReliable)
        case .button(_, let button, let isPressed, _):
            return NativeNVSTEncodedInputEvent(event: source, payload: encoder.encodeMouseButton(button: button.rawValue, timestampUs: timestampUs, down: isPressed), partiallyReliable: false)
        case .wheel(_, let delta, _):
            return NativeNVSTEncodedInputEvent(event: source, payload: encoder.encodeMouseWheel(delta: delta, timestampUs: timestampUs), partiallyReliable: false)
        }
    }

    private func encodeGamepad(_ gamepad: GamepadState, source: UserInputEvent, timestampUs: UInt64) -> NativeNVSTEncodedInputEvent {
        let controllerId = UInt16(truncatingIfNeeded: gamepad.playerIndex)
        let partiallyReliable = shouldSendGamepadPartiallyReliable(controllerId: controllerId)
        let payload = encoder.encodeGamepadState(
            controllerId: controllerId,
            buttons: UInt16(truncatingIfNeeded: gamepad.buttons.rawValue),
            leftTrigger: UInt8((gamepad.leftTrigger * 255).rounded()),
            rightTrigger: UInt8((gamepad.rightTrigger * 255).rounded()),
            leftStickX: scaledStick(gamepad.leftStickX),
            leftStickY: scaledStick(gamepad.leftStickY),
            rightStickX: scaledStick(gamepad.rightStickX),
            rightStickY: scaledStick(gamepad.rightStickY),
            timestampUs: timestampUs,
            bitmap: 0,
            partiallyReliable: partiallyReliable
        )
        return NativeNVSTEncodedInputEvent(event: source, payload: payload, partiallyReliable: partiallyReliable)
    }

    private func shouldSendGamepadPartiallyReliable(controllerId: UInt16) -> Bool {
        let index = min(Int(controllerId & 0x03), 31)
        return inputConfiguration.partialReliableEnabled && (inputConfiguration.partiallyReliableGamepadMask & UInt32(1 << index)) != 0
    }

    private func scaledStick(_ value: Float) -> Int16 {
        let scaled = max(-1, min(1, value)) * Float(Int16.max)
        return Int16(scaled.rounded())
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
