import Foundation

public enum NativeNVSTInputPayload: Equatable, Sendable {
    case event(Data)
    case text(Data)
}

public struct NativeNVSTEncodedInputEvent: Equatable, Sendable {
    public let event: UserInputEvent
    public let nativePayload: NativeNVSTInputPayload
    public let partiallyReliable: Bool

    public var payload: Data {
        switch nativePayload {
        case .event(let data), .text(let data): data
        }
    }

    public init(event: UserInputEvent, nativePayload: NativeNVSTInputPayload) {
        self.event = event
        self.nativePayload = nativePayload
        partiallyReliable = false
    }
}

public final class NativeNVSTInputEncoder: Sendable {
    private static let eventByteCount = 0x48
    private static let darwinKeyMap: [UInt32] = [
        0x0041, 0x0053, 0x0044, 0x0046, 0x0048, 0x0047, 0x005a, 0x0058,
        0x0043, 0x0056, 0x005e, 0x0042, 0x0051, 0x0057, 0x0045, 0x0052,
        0x0059, 0x0054, 0x0031, 0x0032, 0x0033, 0x0034, 0x0036, 0x0035,
        0x003d, 0x0039, 0x0037, 0x002d, 0x0038, 0x0030, 0x005d, 0x004f,
        0x0055, 0x005b, 0x0049, 0x0050, 0x0104, 0x004c, 0x004a, 0x0027,
        0x004b, 0x003b, 0x005c, 0x002c, 0x002f, 0x004e, 0x004d, 0x002e,
        0x0101, 0x0020, 0x00c0, 0x0103, 0x0105, 0x0100, 0x0312, 0x0311,
        0x0302, 0x0501, 0x0308, 0x0305, 0x0303, 0x0309, 0x0306, 0x0312,
        0x0410, 0x060c, 0x0000, 0x00d7, 0x0000, 0x060a, 0x0000, 0x0502,
        0x0000, 0x0000, 0x0000, 0x00f7, 0x0105, 0x0000, 0x060b, 0x0411,
        0x0412, 0x0000, 0x0600, 0x0601, 0x0602, 0x0603, 0x0604, 0x0605,
        0x0606, 0x0607, 0x0000, 0x0608, 0x0609, 0x005f, 0x0062, 0x0000,
        0x0404, 0x0405, 0x0406, 0x0402, 0x0407, 0x0408, 0x0061, 0x040a,
        0x0060, 0x0109, 0x040f, 0x0503, 0x0000, 0x0409, 0x0307, 0x040b,
        0x0000, 0x0108, 0x0106, 0x0200, 0x0206, 0x0107, 0x0403, 0x0201,
        0x0401, 0x0207, 0x0400, 0x0202, 0x0204, 0x0205, 0x0203, 0x0000,
    ]

    public init() {}

    public func encode(_ event: UserInputEvent) -> NativeNVSTEncodedInputEvent? {
        switch event {
        case .keyboard(let keyboard):
            return encodeKeyboard(keyboard, source: event)
        case .mouse(let mouse):
            return NativeNVSTEncodedInputEvent(event: event, nativePayload: .event(encodeMouse(mouse)))
        case .text(_, let value, _):
            let bytes = Data(value.utf8)
            guard !bytes.isEmpty, bytes.count <= Int(UInt16.max) else { return nil }
            return NativeNVSTEncodedInputEvent(event: event, nativePayload: .text(bytes))
        case .gamepad(let gamepad):
            return NativeNVSTEncodedInputEvent(event: event, nativePayload: .event(encodeGamepad(gamepad)))
        }
    }

    private func encodeKeyboard(_ keyboard: KeyboardEvent, source: UserInputEvent) -> NativeNVSTEncodedInputEvent? {
        if keyboard.keyCode == 57 {
            var bytes = Data(count: Self.eventByteCount)
            bytes.writeUInt32LE(15, at: 0)
            bytes.writeUInt32LE(keyboard.modifiers.contains(.capsLock) ? 2 : 1, at: 8)
            return NativeNVSTEncodedInputEvent(event: source, nativePayload: .event(bytes))
        }
        let keyIndex = Int(keyboard.keyCode)
        guard Self.darwinKeyMap.indices.contains(keyIndex) else { return nil }
        let nativeKey = Self.darwinKeyMap[keyIndex]
        guard nativeKey != 0 else { return nil }
        var bytes = Data(count: Self.eventByteCount)
        bytes.writeUInt32LE(1, at: 0)
        bytes.writeUInt32LE(nativeKey, at: 8)
        bytes.writeUInt16LE(nativeModifiers(keyboard), at: 0x0e)
        bytes.writeUInt32LE(keyboard.isPressed ? 2 : 1, at: 0x10)
        bytes.writeUInt64LE(keyboard.timestamp.nanoseconds / 1_000, at: 0x18)
        return NativeNVSTEncodedInputEvent(event: source, nativePayload: .event(bytes))
    }

    private func nativeModifiers(_ keyboard: KeyboardEvent) -> UInt16 {
        var result = keyboard.modifiers.rawValue & 0x000f
        switch keyboard.keyCode {
        case 60: result |= 0x0010
        case 62: result |= 0x0020
        case 61: result |= 0x0040
        case 54: result |= 0x0080
        default: break
        }
        return result
    }

    private func encodeMouse(_ mouse: MouseEvent) -> Data {
        var bytes = Data(count: Self.eventByteCount)
        bytes.writeUInt32LE(2, at: 0)
        switch mouse {
        case .moved(_, let deltaX, let deltaY, let timestamp):
            bytes.writeInt32LE(1, at: 8)
            bytes.writeInt32LE(Int32(deltaX), at: 0x10)
            bytes.writeInt32LE(Int32(deltaY), at: 0x14)
            bytes.writeUInt64LE(timestamp.nanoseconds / 1_000, at: 0x28)
        case .button(_, let button, let isPressed, let timestamp):
            bytes.writeInt32LE(3, at: 8)
            bytes.writeUInt32LE(nativeMouseButton(button), at: 0x18)
            bytes[0x1c] = isPressed ? 2 : 1
            bytes.writeUInt64LE(timestamp.nanoseconds / 1_000, at: 0x28)
        case .wheel(_, let delta, let timestamp):
            bytes.writeInt32LE(2, at: 8)
            bytes.writeInt16LE(wheelDetents(delta), at: 0x24)
            bytes.writeUInt64LE(timestamp.nanoseconds / 1_000, at: 0x28)
        }
        return bytes
    }

    private func nativeMouseButton(_ button: MouseButton) -> UInt32 {
        switch button {
        case .left: 1
        case .right: 3
        case .middle: 2
        case .back: 4
        case .forward: 5
        }
    }

    private func wheelDetents(_ delta: Int16) -> Int16 {
        let value = Int32(delta)
        if value > 0 { return Int16(clamping: (value + 119) / 120) }
        if value < 0 { return Int16(clamping: (value - 119) / 120) }
        return 0
    }

    private func encodeGamepad(_ gamepad: GamepadState) -> Data {
        var bytes = Data(count: Self.eventByteCount)
        bytes.writeUInt32LE(18, at: 0)
        func setControl(_ index: Int, _ value: Int16) {
            bytes.writeInt16LE(value, at: 8 + index * 2)
        }
        let buttons = gamepad.buttons
        setControl(1, buttons.contains(.start) ? 1 : 0)
        setControl(2, buttons.contains(.select) ? 1 : 0)
        setControl(4, buttons.contains(.west) ? 1 : 0)
        setControl(5, buttons.contains(.north) ? 1 : 0)
        setControl(7, buttons.contains(.south) ? 1 : 0)
        setControl(8, buttons.contains(.east) ? 1 : 0)
        setControl(10, buttons.contains(.leftStick) ? 1 : 0)
        setControl(11, buttons.contains(.rightStick) ? 1 : 0)
        setControl(12, buttons.contains(.leftShoulder) ? 1 : 0)
        setControl(13, buttons.contains(.rightShoulder) ? 1 : 0)
        setControl(14, dpadAxis(negative: buttons.contains(.dpadLeft), positive: buttons.contains(.dpadRight)))
        setControl(15, dpadAxis(negative: buttons.contains(.dpadUp), positive: buttons.contains(.dpadDown)))
        setControl(16, stick(gamepad.leftStickX))
        setControl(17, stick(-gamepad.leftStickY))
        setControl(18, stick(gamepad.rightStickX))
        setControl(19, stick(-gamepad.rightStickY))
        bytes.writeUInt16LE(trigger(gamepad.leftTrigger), at: 8 + 20 * 2)
        bytes.writeUInt16LE(trigger(gamepad.rightTrigger), at: 8 + 21 * 2)
        bytes[0x3e] = UInt8(clamping: gamepad.playerIndex)
        bytes.writeUInt64LE(gamepad.timestamp.nanoseconds / 1_000, at: 0x40)
        return bytes
    }

    private func dpadAxis(negative: Bool, positive: Bool) -> Int16 {
        if negative == positive { return 0 }
        return negative ? Int16.min : Int16.max
    }

    private func stick(_ value: Float) -> Int16 {
        let clamped = min(1, max(-1, value))
        let scale = clamped < 0 ? Float(32_768) : Float(32_767)
        return Int16(clamping: Int((clamped * scale).rounded(.toNearestOrAwayFromZero)))
    }

    private func trigger(_ value: Float) -> UInt16 {
        UInt16(clamping: Int((min(1, max(0, value)) * 65_535).rounded(.toNearestOrAwayFromZero)))
    }
}

private extension Data {
    mutating func writeUInt16LE(_ value: UInt16, at offset: Int) {
        self[offset] = UInt8(value & 0xff)
        self[offset + 1] = UInt8((value >> 8) & 0xff)
    }

    mutating func writeInt16LE(_ value: Int16, at offset: Int) {
        writeUInt16LE(UInt16(bitPattern: value), at: offset)
    }

    mutating func writeUInt32LE(_ value: UInt32, at offset: Int) {
        self[offset] = UInt8(value & 0xff)
        self[offset + 1] = UInt8((value >> 8) & 0xff)
        self[offset + 2] = UInt8((value >> 16) & 0xff)
        self[offset + 3] = UInt8((value >> 24) & 0xff)
    }

    mutating func writeInt32LE(_ value: Int32, at offset: Int) {
        writeUInt32LE(UInt32(bitPattern: value), at: offset)
    }

    mutating func writeUInt64LE(_ value: UInt64, at offset: Int) {
        for index in 0..<8 {
            self[offset + index] = UInt8((value >> UInt64(index * 8)) & 0xff)
        }
    }
}
