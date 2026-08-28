import Foundation

/// NVST remote-input (RI) packet encoding.
///
/// Recovered from `RiClientBackend` in libBifrost2. An RI packet is
/// `[u32 big-endian length][u32 little-endian type][body]`, and the whole thing travels as the
/// payload of control command `0x206`. The mixed endianness is not a transcription slip: the
/// length is written byte-swapped (`bswapl`) while the type is a plain store, and the receive side
/// confirms it — `handleServerCommand`'s `0x206` branch compares the word at payload+4 against
/// small constants without swapping.
public enum NvstRemoteInput {
    /// The command that carries every RI packet.
    public static let commandCode: UInt16 = 0x206

    /// The keepalive the client writes to the reliable input channel every two seconds.
    public static let heartbeat = Data([2, 0, 0, 0])
    public static let heartbeatInterval: TimeInterval = 2

    /// The seat announces which remote-input protocol it speaks on the reliable input channel, and
    /// input is not accepted until it has. Two layouts are seen: a `0x020e` command whose payload
    /// carries the version, and a bare message whose first byte is `0x0e`.
    public static func protocolVersion(in bytes: Data) -> UInt16? {
        guard bytes.count >= 2 else { return nil }
        let first = UInt16(bytes[bytes.startIndex]) | UInt16(bytes[bytes.startIndex + 1]) << 8
        if first == 0x020e {
            // A real message is a full command: `[u16 code][u16 length][payload]`, so the version is
            // in the payload. Reading the third and fourth bytes returns the *length* instead —
            // upstream's four-byte test case omits the length field and hides that.
            let (commands, _) = NvstControlCommand.parse(Data(bytes))
            if let command = commands.first, command.code == 0x020e, command.payload.count >= 2 {
                let payload = [UInt8](command.payload.prefix(2))
                return UInt16(payload[0]) | UInt16(payload[1]) << 8
            }
            guard bytes.count >= 4 else { return 2 }
            return UInt16(bytes[bytes.startIndex + 2]) | UInt16(bytes[bytes.startIndex + 3]) << 8
        }
        return bytes[bytes.startIndex] == 0x0e ? first : nil
    }

    /// Packet types, as `Get*PacketId` returns them.
    public enum PacketType: UInt32, Equatable, Sendable {
        case envelope = 0x0e
        /// Relative pointer motion: `[i16 BE dx][i16 BE dy][u16 BE flags]`, selected when the
        /// builder's flag word is `0x10000` and the flags carry no `0x800` (absolute) bit.
        case keyDown = 3
        case keyUp = 4
        case absoluteMouseMove = 5
        case mouseMove = 7
        // Captured from the official client running the same gesture: a press encodes as 8 and the
        // matching release as 9. The flag pairs in the builder's jump table are (down, up), not
        // (up, down) as Win32's `MOUSEEVENTF_*` ordering suggests.
        case mouseButtonPress = 8
        case mouseButtonRelease = 9
        /// The wheel. Static RE read this as "a second motion form whose first word is zero and
        /// whose second is a scaled value"; the capture shows the scaled value is the notch count
        /// times Windows' `WHEEL_DELTA`, so it is the scroll wheel rather than a pointer move.
        case mouseWheel = 10
        case keyboard = 0x13
        case hidChange = 0x12
    }

    /// The button ordinal the wire uses. NVIDIA's flag bits follow Win32's left/right/middle
    /// order, but the byte written into the packet is left=1, middle=2, right=3 — so a client
    /// enum that orders them differently has to be remapped rather than passed through.
    public enum Button: UInt8, Equatable, Sendable {
        case left = 1
        case middle = 2
        case right = 3
        case extra1 = 4
        case extra2 = 5
    }

    /// Frames a body as an RI packet.
    static func packet(type: PacketType, body: Data) -> Data {
        var data = Data(capacity: 8 + body.count)
        let length = UInt32(4 + body.count)
        data.append(UInt8(truncatingIfNeeded: length >> 24))
        data.append(UInt8(truncatingIfNeeded: length >> 16))
        data.append(UInt8(truncatingIfNeeded: length >> 8))
        data.append(UInt8(truncatingIfNeeded: length))
        let type = type.rawValue
        data.append(UInt8(truncatingIfNeeded: type))
        data.append(UInt8(truncatingIfNeeded: type >> 8))
        data.append(UInt8(truncatingIfNeeded: type >> 16))
        data.append(UInt8(truncatingIfNeeded: type >> 24))
        data.append(body)
        return data
    }

    /// How a packet is framed before it goes on a data channel. Which one the seat expects is not
    /// yet established, so each is selectable rather than assumed.
    public enum Framing: String, CaseIterable, Sendable {
        /// The packet exactly as `PreparePacket` leaves it.
        case plain
        /// `PreparePacket` plus the partially-reliable per-type sequence: a big-endian 16-bit
        /// counter appended by `handlePrSequenceNumber`.
        case sequenced
        /// `SendPacketV3`: a `0x23` marker and a big-endian 64-bit microsecond timestamp in front.
        case versioned
        /// `SendPacket`'s timestamp envelope: an outer type `0x0e` packet whose body is the inner
        /// packet zero-padded to an 8-byte slot boundary, then a 64-bit microsecond timestamp.
        /// The envelope's timestamp is little-endian, unlike `versioned`'s — the library stores one
        /// with `movq` and the other with `bswapq`.
        case enveloped
    }

    static func carriesPairedTimestamps(_ inner: Data) -> Bool {
        guard inner.count >= 8 else { return false }
        let type = UInt32(inner[4]) | UInt32(inner[5]) << 8 | UInt32(inner[6]) << 16 | UInt32(inner[7]) << 24
        return [PacketType.keyDown, .keyUp, .absoluteMouseMove].contains { type == UInt32($0.rawValue) }
    }

    /// The padded length the envelope gives an inner packet of `innerLength` bytes.
    /// The envelope holds its inner packet in a fixed 24-byte slot, zero-padded — a 14-byte
    /// pointer packet and a 22-byte key packet both occupy 24 — after which the microsecond
    /// timestamps follow. That is what makes a pointer event 40 bytes and a key event 48.
    static let envelopeInnerSlotBytes = 24

    static func envelopePaddedLength(innerLength: Int) -> Int {
        max(envelopeInnerSlotBytes, 8 * ((innerLength + 7) / 8))
    }

    /// Applies a framing to an encoded packet.
    public static func framed(_ packet: Data, framing: Framing, sequence: UInt16, timestampMicroseconds: UInt64) -> Data {
        switch framing {
        case .plain:
            return packet
        case .sequenced:
            var data = packet
            data.append(UInt8(truncatingIfNeeded: sequence >> 8))
            data.append(UInt8(truncatingIfNeeded: sequence))
            return data
        case .versioned:
            var data = Data([0x23])
            for shift in stride(from: 56, through: 0, by: -8) {
                data.append(UInt8(truncatingIfNeeded: timestampMicroseconds >> UInt64(shift)))
            }
            data.append(packet)
            return data
        case .enveloped:
            var body = packet
            body.append(Data(repeating: 0, count: envelopePaddedLength(innerLength: packet.count) - packet.count))
            // Key events carry the microsecond clock twice — the capture's press and release of one
            // key share the first value and differ in the second by about 100 µs, so the pair reads
            // as a batch time and an event time. Pointer events carry it once.
            for _ in 0..<(carriesPairedTimestamps(packet) ? 2 : 1) {
                for shift in stride(from: 0, through: 56, by: 8) {
                    body.append(UInt8(truncatingIfNeeded: timestampMicroseconds >> UInt64(shift)))
                }
            }
            return self.packet(type: .envelope, body: body)
        }
    }

    /// A key transition: `[BE u16 virtual key][BE u16 modifiers]` then padding, 14-byte body.
    ///
    /// Both fields confirmed from a capture of the vendored client: 'A' is VK 0x41, left shift is
    /// VK 0x00A0, and the modifier half is the low nibble of `KeyboardModifiers` (shift 0x01,
    /// control 0x02, option 0x04, command 0x08). The modifier field is why capitals worked as a
    /// *chord shortcut* (the shift key registered) but never produced capital letters — the letter
    /// packet has to carry the shift bit, not just be preceded by a shift-key event.
    public static func keyboard(virtualKey: UInt16, modifiers: UInt16 = 0, isPressed: Bool) -> Data {
        var body = Data()
        body.append(UInt8(truncatingIfNeeded: virtualKey >> 8))
        body.append(UInt8(truncatingIfNeeded: virtualKey))
        body.append(UInt8(truncatingIfNeeded: modifiers >> 8))
        body.append(UInt8(truncatingIfNeeded: modifiers))
        body.append(Data(repeating: 0, count: 10))
        return packet(type: isPressed ? .keyDown : .keyUp, body: body)
    }

    /// An absolute pointer position, in the coordinate space the client declares alongside it.
    /// Captured from the native stack: inner type 5, with the position, the `0x0800` absolute flag
    /// and the viewport the position is measured in. Sending (1920, 1080) produced (1631, 687) with
    /// a declared viewport of 1632x688, which is the stream view's own content frame — so these are
    /// view coordinates, not stream-resolution ones.
    public static func absoluteMouseMove(x: UInt16,
                                         y: UInt16,
                                         viewportWidth: UInt16,
                                         viewportHeight: UInt16) -> Data {
        var body = Data()
        // Five fields, an inner length of 10. What follows them in the capture (`0080 0000 ...`) is
        // the envelope's padding, and it is not zeroed there — the vendored library reuses one
        // buffer, so its button packets show leftover viewport bytes in the same region.
        for word in [x, y, absoluteFlag, viewportWidth, viewportHeight] {
            body.append(UInt8(truncatingIfNeeded: word >> 8))
            body.append(UInt8(truncatingIfNeeded: word))
        }
        return packet(type: .absoluteMouseMove, body: body)
    }

    /// The flag that marks a pointer position as absolute.
    public static let absoluteFlag: UInt16 = 0x0800

    /// Windows' `WHEEL_DELTA`: one notch.
    public static let wheelDelta = 120
    public static let wheelDelta16: Int16 = 120

    /// A wheel movement, in `WHEEL_DELTA` units — 120 per notch, which is what the wire carries
    /// (one downward notch was captured as -120).
    ///
    /// The value is **not** rescaled here. `MouseEvent.wheel.delta` already arrives in those units:
    /// the stream view's `accumulatedWheelDelta` multiplies by 120 on both of its branches, and the
    /// vendored transport passes the value straight to `sendMouseWheel`. Multiplying again turned
    /// one notch into 14400 and saturated a signed 16-bit field after two of them.
    public static func mouseWheel(delta: Int16) -> Data {
        var body = Data([0, 0])
        body.append(UInt8(truncatingIfNeeded: UInt16(bitPattern: delta) >> 8))
        body.append(UInt8(truncatingIfNeeded: UInt16(bitPattern: delta)))
        body.append(Data([0, 0]))
        return packet(type: .mouseWheel, body: body)
    }

    /// A relative pointer move: `[i16 BE dx][i16 BE dy][u16 BE flags]`. The `0x800` flag would
    /// make it absolute, so a relative move leaves the flags at zero.
    public static func mouseMove(deltaX: Int16, deltaY: Int16, flags: UInt16 = 0) -> Data {
        var body = Data()
        for word in [UInt16(bitPattern: deltaX), UInt16(bitPattern: deltaY), flags] {
            body.append(UInt8(truncatingIfNeeded: word >> 8))
            body.append(UInt8(truncatingIfNeeded: word))
        }
        return packet(type: .mouseMove, body: body)
    }

    /// A button transition. The second body byte is the high half of the builder's 16-bit
    /// argument, which is zero for a plain click.
    public static func mouseButton(_ button: Button, isPressed: Bool) -> Data {
        packet(type: isPressed ? .mouseButtonPress : .mouseButtonRelease,
               body: Data([button.rawValue, 0]))
    }
}
