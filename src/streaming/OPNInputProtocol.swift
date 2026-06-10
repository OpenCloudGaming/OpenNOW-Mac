import Foundation

@objcMembers
@objc(OPNInputProtocolEncoder)
final class OPNInputProtocolEncoder: NSObject {
    private enum EventType {
        static let heartbeat: UInt32 = 2
        static let keyDown: UInt32 = 3
        static let keyUp: UInt32 = 4
        static let mouseRelative: UInt32 = 7
        static let mouseButtonDown: UInt32 = 8
        static let mouseButtonUp: UInt32 = 9
        static let mouseWheel: UInt32 = 10
        static let gamepad: UInt32 = 12
        static let utf8Text: UInt32 = 23
    }

    private var protocolVersion: UInt16 = 2
    private var gamepadSequences: [UInt16] = [1, 1, 1, 1]
    private static let start = DispatchTime.now().uptimeNanoseconds

    func setProtocolVersion(_ version: UInt16) {
        protocolVersion = version == 0 ? 2 : version
    }

    func encodeHeartbeat() -> Data {
        var bytes = Data(count: 4)
        bytes.writeUInt32LE(EventType.heartbeat, at: 0)
        return bytes
    }

    func encodeKey(keycode: UInt16, scancode: UInt16, modifiers: UInt16, timestampUs: UInt64, down: Bool) -> Data {
        var bytes = Data(count: 18)
        bytes.writeUInt32LE(down ? EventType.keyDown : EventType.keyUp, at: 0)
        bytes.writeUInt16BE(keycode, at: 4)
        bytes.writeUInt16BE(modifiers, at: 6)
        bytes.writeUInt16BE(scancode, at: 8)
        bytes.writeUInt64BE(timestampUs, at: 10)
        return wrapSingleEvent(bytes)
    }

    func encodeMouseMove(dx: Int16, dy: Int16, timestampUs: UInt64) -> Data {
        if protocolVersion <= 2 {
            var bytes = Data(count: 22)
            bytes.writeUInt32LE(EventType.mouseRelative, at: 0)
            bytes.writeInt16BE(dx, at: 4)
            bytes.writeInt16BE(dy, at: 6)
            bytes.writeUInt64BE(timestampUs, at: 14)
            return bytes
        }

        var bytes = Data(count: 34)
        bytes[0] = 0x23
        bytes.writeUInt64BE(Self.timestampUs(), at: 1)
        bytes[9] = 0x21
        bytes.writeUInt16BE(22, at: 10)
        bytes.writeUInt32LE(EventType.mouseRelative, at: 12)
        bytes.writeInt16BE(dx, at: 16)
        bytes.writeInt16BE(dy, at: 18)
        bytes.writeUInt64BE(timestampUs, at: 26)
        return bytes
    }

    func encodeMouseButton(button: UInt8, timestampUs: UInt64, down: Bool) -> Data {
        var bytes = Data(count: 18)
        bytes.writeUInt32LE(down ? EventType.mouseButtonDown : EventType.mouseButtonUp, at: 0)
        bytes[4] = button
        bytes.writeUInt64BE(timestampUs, at: 10)
        return wrapSingleEvent(bytes)
    }

    func encodeMouseWheel(delta: Int16, timestampUs: UInt64) -> Data {
        var bytes = Data(count: 22)
        bytes.writeUInt32LE(EventType.mouseWheel, at: 0)
        bytes.writeInt16BE(delta, at: 6)
        bytes.writeUInt64BE(timestampUs, at: 14)
        return wrapSingleEvent(bytes)
    }

    func encodeUtf8Text(_ text: String) -> Data {
        guard let textData = text.data(using: .utf8), !textData.isEmpty else { return Data() }
        var bytes = Data(count: 8)
        bytes.writeUInt32LE(EventType.utf8Text, at: 0)
        bytes.writeUInt32LE(UInt32(textData.count), at: 4)
        bytes.append(textData)
        return wrapSingleEvent(bytes)
    }

    func encodeGamepadState(controllerId: UInt16,
                            buttons: UInt16,
                            leftTrigger: UInt8,
                            rightTrigger: UInt8,
                            leftStickX: Int16,
                            leftStickY: Int16,
                            rightStickX: Int16,
                            rightStickY: Int16,
                            timestampUs: UInt64,
                            bitmap: UInt16,
                            partiallyReliable: Bool) -> Data {
        var bytes = Data(count: 38)
        bytes.writeUInt32LE(EventType.gamepad, at: 0)
        bytes.writeUInt16LE(26, at: 4)
        bytes.writeUInt16LE(controllerId & 0x03, at: 6)
        bytes.writeUInt16LE(bitmap, at: 8)
        bytes.writeUInt16LE(20, at: 10)
        bytes.writeUInt16LE(buttons, at: 12)
        bytes.writeUInt16LE(UInt16(leftTrigger) | (UInt16(rightTrigger) << 8), at: 14)
        bytes.writeInt16LE(leftStickX, at: 16)
        bytes.writeInt16LE(leftStickY, at: 18)
        bytes.writeInt16LE(rightStickX, at: 20)
        bytes.writeInt16LE(rightStickY, at: 22)
        bytes.writeUInt16LE(85, at: 26)
        bytes.writeUInt64LE(timestampUs, at: 30)
        if partiallyReliable {
            let index = UInt8(controllerId & 0x03)
            return wrapGamepadPartiallyReliable(bytes, gamepadIndex: index, sequenceNumber: nextGamepadSequence(index))
        }
        return wrapGamepadReliable(bytes)
    }

    class func timestampUs() -> UInt64 {
        (DispatchTime.now().uptimeNanoseconds - start) / 1_000
    }

    private func wrapSingleEvent(_ payload: Data) -> Data {
        guard protocolVersion > 2 else { return payload }
        var wrapped = Data(count: 10)
        wrapped[0] = 0x23
        wrapped.writeUInt64BE(Self.timestampUs(), at: 1)
        wrapped[9] = 0x22
        wrapped.append(payload)
        return wrapped
    }

    private func wrapGamepadReliable(_ payload: Data) -> Data {
        guard protocolVersion > 2 else { return payload }
        var wrapped = Data(count: 12)
        wrapped[0] = 0x23
        wrapped.writeUInt64BE(Self.timestampUs(), at: 1)
        wrapped[9] = 0x21
        wrapped.writeUInt16BE(UInt16(payload.count), at: 10)
        wrapped.append(payload)
        return wrapped
    }

    private func wrapGamepadPartiallyReliable(_ payload: Data, gamepadIndex: UInt8, sequenceNumber: UInt16) -> Data {
        guard protocolVersion > 2 else { return payload }
        var wrapped = Data(count: 16)
        wrapped[0] = 0x23
        wrapped.writeUInt64BE(Self.timestampUs(), at: 1)
        wrapped[9] = 0x26
        wrapped[10] = gamepadIndex
        wrapped.writeUInt16BE(sequenceNumber, at: 11)
        wrapped[13] = 0x21
        wrapped.writeUInt16BE(UInt16(payload.count), at: 14)
        wrapped.append(payload)
        return wrapped
    }

    private func nextGamepadSequence(_ gamepadIndex: UInt8) -> UInt16 {
        let index = Int(gamepadIndex % 4)
        let current = gamepadSequences[index]
        gamepadSequences[index] = current &+ 1
        return current
    }
}

private extension Data {
    mutating func writeUInt16BE(_ value: UInt16, at offset: Int) {
        self[offset] = UInt8((value >> 8) & 0xff)
        self[offset + 1] = UInt8(value & 0xff)
    }

    mutating func writeUInt16LE(_ value: UInt16, at offset: Int) {
        self[offset] = UInt8(value & 0xff)
        self[offset + 1] = UInt8((value >> 8) & 0xff)
    }

    mutating func writeInt16BE(_ value: Int16, at offset: Int) {
        writeUInt16BE(UInt16(bitPattern: value), at: offset)
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

    mutating func writeUInt64BE(_ value: UInt64, at offset: Int) {
        for index in 0..<8 {
            self[offset + index] = UInt8((value >> UInt64((7 - index) * 8)) & 0xff)
        }
    }

    mutating func writeUInt64LE(_ value: UInt64, at offset: Int) {
        for index in 0..<8 {
            self[offset + index] = UInt8((value >> UInt64(index * 8)) & 0xff)
        }
    }
}
