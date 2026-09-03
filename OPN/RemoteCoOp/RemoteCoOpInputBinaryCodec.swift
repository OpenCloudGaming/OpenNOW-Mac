//  A 62-byte frame for guest gamepad packets, which arrive at the pad's HID report rate - up to
//  ~1000/second - where JSON costs an encoder allocation, ~330 bytes and a UUID string parse each.
//  Session control stays JSON.
//
//  Both encodings share the channel; the host picks by first byte. JSON always starts with `{`, so a
//  magic byte outside printable ASCII can never collide. Browser guests are unaffected.
//

import Foundation

public enum OPNRemoteCoOpInputBinaryCodec {
    /// Outside printable ASCII, so a JSON message can never start with it.
    static let magic: UInt8 = 0xA7
    static let version: UInt8 = 1
    /// magic + version + UUID(16) + sequence(8) + buttons(4) + 6 floats(24) + sentAt(8)
    public static let frameByteCount = 1 + 1 + 16 + 8 + 4 + 24 + 8

    public static func looksLikeBinaryFrame(_ data: Data) -> Bool {
        data.count == frameByteCount && data.first == magic
    }

    public static func encode(_ packet: OPNRemoteCoOpInputPacket) -> Data {
        var data = Data(capacity: frameByteCount)
        data.append(magic)
        data.append(version)
        withUnsafeBytes(of: packet.participantID.uuid) { data.append(contentsOf: $0) }
        appendLittleEndian(packet.sequenceNumber, to: &data)
        appendLittleEndian(packet.buttons.rawValue, to: &data)
        for value in [packet.leftTrigger, packet.rightTrigger, packet.leftStickX, packet.leftStickY, packet.rightStickX, packet.rightStickY] {
            appendLittleEndian(value.bitPattern, to: &data)
        }
        appendLittleEndian(packet.sentAtNanoseconds, to: &data)
        return data
    }

    public static func decode(_ data: Data) -> OPNRemoteCoOpInputPacket? {
        guard looksLikeBinaryFrame(data) else { return nil }
        // Copied, not subscripted: libwebrtc hands over a slice whose startIndex is not zero.
        let bytes = [UInt8](data)
        guard bytes[1] == version else { return nil }
        var offset = 2
        let uuidBytes = uuid_t(bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3],
                               bytes[offset + 4], bytes[offset + 5], bytes[offset + 6], bytes[offset + 7],
                               bytes[offset + 8], bytes[offset + 9], bytes[offset + 10], bytes[offset + 11],
                               bytes[offset + 12], bytes[offset + 13], bytes[offset + 14], bytes[offset + 15])
        offset += 16
        let sequenceNumber = readLittleEndian(UInt64.self, from: bytes, at: &offset)
        let buttons = GamepadButtons(rawValue: readLittleEndian(UInt32.self, from: bytes, at: &offset))
        var axes: [Float] = []
        axes.reserveCapacity(6)
        for _ in 0..<6 {
            axes.append(Float(bitPattern: readLittleEndian(UInt32.self, from: bytes, at: &offset)))
        }
        let sentAtNanoseconds = readLittleEndian(UInt64.self, from: bytes, at: &offset)
        return OPNRemoteCoOpInputPacket(
            participantID: UUID(uuid: uuidBytes),
            sequenceNumber: sequenceNumber,
            buttons: buttons,
            leftTrigger: axes[0],
            rightTrigger: axes[1],
            leftStickX: axes[2],
            leftStickY: axes[3],
            rightStickX: axes[4],
            rightStickY: axes[5],
            sentAtNanoseconds: sentAtNanoseconds
        )
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func readLittleEndian<T: FixedWidthInteger>(_ type: T.Type, from bytes: [UInt8], at offset: inout Int) -> T {
        var value: T = 0
        for index in 0..<MemoryLayout<T>.size {
            value |= T(bytes[offset + index]) << (8 * index)
        }
        offset += MemoryLayout<T>.size
        return value
    }
}
