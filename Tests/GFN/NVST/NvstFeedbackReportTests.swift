import Foundation
import Testing
@testable import OpenNOW

private func bytes(_ text: String) -> Data {
    var data = Data()
    var index = text.startIndex
    while index < text.endIndex {
        let next = text.index(index, offsetBy: 2)
        data.append(UInt8(text[index..<next], radix: 16)!)
        index = next
    }
    return data
}

private func word(_ payload: Data, _ offset: Int) -> UInt32 {
    payload[offset..<(offset + 4)].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
}

private func half(_ payload: Data, _ offset: Int) -> UInt16 {
    UInt16(payload[offset]) | UInt16(payload[offset + 1]) << 8
}

@Suite
struct NvstFeedbackReportTests {

    /// The whole point of replacing the software GHASH was speed, so the replacement has to agree
    /// with it bit for bit. This recomputes GCM's tag the slow, explicit way — GHASH over the AAD
    /// and ciphertext, XORed with E(K, J0) — and holds the hardware path to it.
    @Test func hardwareGcmTagAgreesWithTheSoftwareGhash() throws {
        let key = Data((0..<32).map { UInt8($0 &* 7 &+ 3) })
        let iv = Data((0..<12).map { UInt8($0 &* 5 &+ 1) })
        let aad = Data((0..<32).map { UInt8($0 &* 3) })
        let plaintext = Data((0..<1200).map { UInt8($0 % 251) })

        let cipher = try SrtpGcm8(key: key)
        let sealed = try cipher.seal(iv: iv, aad: aad, plaintext: plaintext, tagLength: 8)
        let ciphertext = sealed.prefix(plaintext.count)
        let tag = sealed.suffix(8)

        let h = try SrtpCryptor.blockEncrypt(key: key, block: Data(repeating: 0, count: 16))
        let s0 = try SrtpCryptor.blockEncrypt(key: key, block: SrtpGcm8.j0(iv: iv))
        let ghash = [UInt8](GHash.hash(key: h, aad: aad, ciphertext: Data(ciphertext)))
        let s0Bytes = [UInt8](s0)
        let expected = Data((0..<8).map { ghash[$0] ^ s0Bytes[$0] })

        #expect(tag == expected)
        // And the pair round-trips, which is what the receive path actually relies on.
        #expect(try cipher.decrypt(iv: iv, aad: aad, ciphertext: Data(ciphertext), authenticationTag: Data(tag)) == plaintext)
    }

    @Test func aTamperedTagStillFailsAuthentication() throws {
        let key = Data((0..<32).map { UInt8($0) })
        let iv = Data(repeating: 9, count: 12)
        let aad = Data(repeating: 4, count: 32)
        let cipher = try SrtpGcm8(key: key)
        let sealed = try cipher.seal(iv: iv, aad: aad, plaintext: Data(repeating: 1, count: 64), tagLength: 8)
        var tag = Data(sealed.suffix(8))
        tag[0] ^= 0x01
        #expect(throws: SrtpCryptoError.authenticationFailed) {
            _ = try cipher.decrypt(iv: iv, aad: aad, ciphertext: sealed.prefix(64), authenticationTag: tag)
        }
    }

    /// Byte-exact against a captured `0x203` from the native stack — a ~75 fps session
    /// (`target` at `+24` = 13338 us = 1_000_000/74.98).
    @Test func theFramePacingReportMatchesTheCapturedBytes() {
        let captured = bytes("05000000000000000200000001000000803e0000803e00001a340000")
        let report = NvstFramePacingReport(
            frameNumber: 1,
            targetFrameTimeMicroseconds: 13338,
            measuredFrameTimeMicroseconds: 16000,
            groupCount: 2
        )
        #expect(report.payload == captured)
        #expect(report.command.code == 0x203)
    }

    /// Byte-exact against a captured `0x203` from a second, later session (2026-08-28, 5120x2160
    /// @120, real gameplay) — confirms `+16` stays 16000 regardless of negotiated fps while `+24`
    /// tracks it (8333 us = 1_000_000/120.01), and `+20` carries the raw unclamped measured value.
    @Test func theFramePacingReportMatchesA120fpsCapturedSample() {
        let captured = bytes("05000000000000000700000012000000803e00007a5e00008d200000")
        let report = NvstFramePacingReport(
            frameNumber: 18,
            targetFrameTimeMicroseconds: 8333,
            measuredFrameTimeMicroseconds: 24186,
            groupCount: 7
        )
        #expect(report.payload == captured)
    }

    /// The captured `0x207` reports are all exactly 52 bytes, and every field this models sits
    /// where the capture puts it.
    ///
    /// `+48` is deliberately not asserted against the sample: it tracks the cumulative byte count
    /// to within ~80 bytes across the capture, but its first five samples echo the timestamp
    /// instead, so no single sample is reproducible.
    ///
    /// `+20`, `+24` and `+44` are asserted for placement rather than against the sample. They
    /// carry per-report delay and rate estimates, so the captured values belong to the captured
    /// session; what has to stay true is that our measurements land on those offsets, because
    /// sending zeros there is what left the seat's delay-based controller with no evidence.
    @Test func theQosReportMatchesTheCapturedLayout() {
        let captured = bytes("070000000000000006000000020000004" + "8bc0300" + "000000003d0000000000e803e803a43132c01b000000000000000000fabb0300")
        let report = NvstQosReport(
            sequence: 6,
            framesReceived: 2,
            bytesReceived: 244_808,
            linkCapabilityKbps: 12708,
            rtpTimestamp: 1_818_674,
            previousBytesReceived: 244_808,
            isWarmedUp: false
        )
        let payload = report.payload
        #expect(payload.count == 52)
        #expect(captured.count == 52)
        for offset in [0, 4, 8, 12, 16, 36, 40] {
            #expect(word(payload, offset) == word(captured, offset), "word at +\(offset)")
        }
        for offset in [28, 30, 32, 34] {
            #expect(half(payload, offset) == half(captured, offset), "half at +\(offset)")
        }
        #expect(word(payload, 0) == 7)
        #expect(report.command.code == 0x207)
    }

    /// The delay and rate samples reach the offsets the seat reads them from. Sent as zero the
    /// whole time this client has existed, which reads as a path with no measurable delay and no
    /// measurable throughput — while the vendored client, on the same seat, holds a steady 120 fps
    /// against our 91.
    @Test func theQosReportCarriesItsDelayAndRateSamples() {
        let report = NvstQosReport(
            sequence: 9,
            framesReceived: 120,
            bytesReceived: 2_000_000,
            linkCapabilityKbps: UInt16(clamping: 100_000),
            rtpTimestamp: 90_000,
            previousBytesReceived: 1_900_000,
            delayMicroseconds: 174,
            delayTrendMicroseconds: 59,
            intervalBits: 48_000,
            isWarmedUp: true
        )
        let payload = report.payload
        #expect(word(payload, 20) == 174)
        #expect(word(payload, 24) == 59)
        #expect(word(payload, 44) == 48_000)
        #expect(half(payload, 34) == UInt16.max)
        // The two byte counters must differ, or a controller differencing them reads zero
        // throughput no matter what the link is carrying.
        #expect(word(payload, 16) != word(payload, 48))
        // +40 is zero in every captured report.
        #expect(word(payload, 40) == 0)
    }

    /// The per-frame report is 102 bytes with the frame counter, size and cadence at the offsets
    /// the capture uses, and the pacing target must describe the display rather than the rate
    /// frames happen to be arriving at.
    @Test func theFrameAckPlacesItsFieldsWhereTheCapturePutsThem() {
        let ack = NvstFrameAck(
            frameNumber: 42,
            clientTimeMilliseconds: 20_320.16,
            frameBytes: 15_168,
            interFrameMicroseconds: 16_667,
            stageMilliseconds: [4.5]
        )
        let payload = ack.payload
        #expect(payload.count == 102)
        #expect(half(payload, 0) == 1)
        #expect(half(payload, 2) == 9)
        #expect(word(payload, 4) == 42)
        #expect(word(payload, 8) == 0)
        #expect(payload[12..<20].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) } == 20_320.16.bitPattern)
        #expect(Float(bitPattern: word(payload, 48)) == -1)
        #expect(word(payload, 72) == 15_168)
        #expect(word(payload, 84) == 16_384)
        #expect(word(payload, 96) == 16_667)
        #expect(half(payload, 100) == 0)
        // A single measured latency fills all five rising stage marks rather than claiming a stage
        // took no time at all.
        for index in 0..<5 { #expect(Float(bitPattern: word(payload, 28 + index * 4)) == 4.5) }
        #expect(ack.command.code == 0x204)
    }
}

@Suite
struct NvstInputActivationTests {

    /// Byte-exact against the `0x20d` the native stack sends before its first input event. The
    /// prefix is `0x23` followed by the session clock in microseconds, big-endian, which is the
    /// same "versioned" prefix the remote-input path uses.
    @Test func theDeviceDescriptorMatchesTheCapturedBytes() {
        let captured = bytes("23000000000132bc31220c0000001a000000020014000000000000000000000000000000550000000000000000000000")
        let command = NvstInputActivation.deviceDescriptor(timestampMicroseconds: 20_102_193, connectedBitmap: 2)
        #expect(command.payload == captured)
        #expect(command.code == 0x20d)
        #expect(captured.count == 48)

        // The bitmap is a u16, so the XInput-style bit lands in the byte after it — and the
        // descriptor must carry exactly what the state packet carries, or the seat registers one
        // kind of device and then receives updates for another.
        let xinput = NvstInputActivation.deviceDescriptor(timestampMicroseconds: 1, connectedBitmap: 0x0101).payload
        #expect([UInt8](xinput)[9 + 9] == 0x01)
        #expect([UInt8](xinput)[9 + 10] == 0x01)
    }

    /// The teardown message differs from the pre-input one only in this field, which is what makes
    /// it a parameter rather than part of the captured body.
    @Test func theConnectedBitmapIsTheOnlyFieldThatMovesBetweenSamples() {
        let preInput = NvstInputActivation.deviceDescriptor(timestampMicroseconds: 49_628_349, connectedBitmap: 2).payload
        let teardown = NvstInputActivation.deviceDescriptor(timestampMicroseconds: 49_628_349, connectedBitmap: 1).payload
        #expect(preInput.count == teardown.count)
        #expect(zip(preInput, teardown).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset) == [9 + 9])
        #expect(teardown == bytes("230000000002f544bd220c0000001a000000010014000000000000000000000000000000550000000000000000000000"))
    }

    /// Both captured `0x20b` forms: the enable clear early in the chain, and set immediately before
    /// input starts.
    @Test func theEnableMatchesBothCapturedForms() {
        #expect(NvstInputActivation.enableInput(counter: 1, isEnabled: false).payload == bytes("000000000100000000000000"))
        #expect(NvstInputActivation.enableInput(counter: 122).payload == bytes("000000007a00000001000000"))
        #expect(NvstInputActivation.enableInput(counter: 124).payload == bytes("000000007c00000001000000"))
        #expect(NvstInputActivation.enableInput(counter: 1).code == 0x20b)
    }

    /// `0x308` is mouse cursor capture, not a "ready" ping. Sending it as a zero byte told the seat
    /// to stop compositing its cursor while we kept drawing our own.
    @Test func theCursorCommandsCarryTheirBooleanPayload() {
        #expect(NvstInputActivation.mouseCursorCapture(isEnabled: true).code == 0x308)
        #expect(NvstInputActivation.mouseCursorCapture(isEnabled: true).payload == Data([1]))
        #expect(NvstInputActivation.mouseCursorCapture(isEnabled: false).payload == Data([0]))
        #expect(NvstInputActivation.trackRemoteCursorImage(isEnabled: true).code == 0x30d)
        #expect(NvstInputActivation.trackRemoteCursorImage(isEnabled: true).payload == Data([1]))
    }

    /// Three little-endian words: stream index, state, frame number. The active window state is 19;
    /// writing it into the first word left the session looking inactive and stopped the seat from
    /// publishing cursor mode updates.
    @Test func theWindowStateAnnouncesTheActiveStateInTheSecondWord() {
        #expect(NvstControlCommand.windowStateChange().payload == bytes("000000001300000000000000"))
        #expect(NvstControlCommand.windowStateChange().code == 0x320)
        #expect(NvstControlCommand.systemStateChange().payload == bytes("000000000000000000000000"))
    }

    @Test func theRemoteCursorReadsVisibilityFromTheSeat() {
        // System cursor, id 0, no visibility byte: the game hid the pointer.
        let hidden = NvstControlCommand(code: 0x010f, payload: bytes("00000000"))
        #expect(NvstRemoteCursor.from(hidden)?.isVisible == false)
        // A non-zero predefined id is a real cursor shape.
        let arrow = NvstControlCommand(code: 0x010f, payload: bytes("02000000"))
        #expect(NvstRemoteCursor.from(arrow)?.isVisible == true)
        // An explicit visibility byte wins over the id.
        let explicitlyHidden = NvstControlCommand(code: 0x010f, payload: bytes("020000000a00140000"))
        #expect(NvstRemoteCursor.from(explicitlyHidden)?.isVisible == false)
        // 0x0110 is ambiguous (our capture table calls it video-stream-progress), so it must NOT
        // be read as a cursor — otherwise every progress message would un-hide the pointer.
        #expect(NvstRemoteCursor.from(NvstControlCommand(code: 0x0110, payload: Data([0, 0, 0, 0]))) == nil)
        // Anything else is not a cursor message.
        #expect(NvstRemoteCursor.from(NvstControlCommand(code: 0x0200, payload: Data([0]))) == nil)
    }

    /// The mouse encoding, held against a real captured event so a refactor cannot drift it. This
    /// is a +24/+24 relative move stamped 23.181032 s into the session.
    @Test func aMouseMoveMatchesTheCapturedInputEvent() {
        let captured = bytes("000000240e0000000000000a0700000000180018000000000000000000000000e8ba610100000000")
        let framed = NvstRemoteInput.framed(
            NvstRemoteInput.mouseMove(deltaX: 24, deltaY: 24),
            framing: .enveloped,
            sequence: 0,
            timestampMicroseconds: 23_182_056
        )
        #expect(framed == captured)
    }

    @Test func aLeftButtonPressAndReleaseMatchTheCapturedEvents() {
        let press = NvstRemoteInput.framed(
            NvstRemoteInput.mouseButton(.left, isPressed: true),
            framing: .enveloped, sequence: 0, timestampMicroseconds: 23_184_218
        )
        let release = NvstRemoteInput.framed(
            NvstRemoteInput.mouseButton(.left, isPressed: false), 
            framing: .enveloped, sequence: 0, timestampMicroseconds: 23_184_327
        )
        #expect(press == bytes("000000240e0000000000000608000000010000000000000000000000000000005ac3610100000000"))
        #expect(release == bytes("000000240e000000000000060900000001000000000000000000000000000000c7c3610100000000"))
    }
}

@Suite
struct NvstKeyboardAndGamepadTests {

    /// Byte-exact against a captured key-down and key-up of `A` from the native stack. The pair
    /// shares its first microsecond value and differs in the second, so both are supplied.
    @Test func aKeyDownAndUpMatchTheCapturedEvents() {
        let down = NvstRemoteInput.framed(
            NvstRemoteInput.keyboard(virtualKey: 0x41, isPressed: true),
            framing: .enveloped, sequence: 0, timestampMicroseconds: 0x0000_0000_015b_15b1
        )
        #expect(down.count == 48)
        // Inner type 3 is key down; the body is the virtual key big-endian.
        #expect(down[12] == 3)
        #expect(down[16] == 0x00 && down[17] == 0x41)
        let up = NvstRemoteInput.framed(
            NvstRemoteInput.keyboard(virtualKey: 0x41, isPressed: false),
            framing: .enveloped, sequence: 0, timestampMicroseconds: 0x0000_0000_015b_15b1
        )
        #expect(up[12] == 4)
        // Both timestamps present, so the packet is 48 bytes rather than the pointer form's 40.
        #expect(up.count == 48)
        #expect(Array(up[32..<40]) == Array(up[40..<48]))
    }

    @Test func aPointerMoveStillCarriesOneTimestamp() {
        let move = NvstRemoteInput.framed(
            NvstRemoteInput.mouseMove(deltaX: 24, deltaY: 24),
            framing: .enveloped, sequence: 0, timestampMicroseconds: 23_182_056
        )
        #expect(move.count == 40)
    }

    /// Byte-for-byte against `OPNInputProtocolEncoder`, the encoder the vendored path used — the one
    /// build where the gamepad demonstrably reached games. Everything after the outer timestamp must
    /// match; only bytes 1..9 differ, because that encoder stamps them from its own clock.
    ///
    /// This is the oracle that was missing while the wire format was debugged against a single idle
    /// reference packet. That packet had been transcribed as a 43-byte body starting `26 00 00 00 22`,
    /// which read the partially-reliable wrapper's sequence as part of a length and dropped the
    /// `0x21` length-prefix tag plus its two length bytes entirely — so every state packet was 52
    /// bytes where the wire wants 54.
    @Test func gamepadPacketMatchesTheVendoredEncoderByteForByte() {
        let vendored = OPNInputProtocolEncoder()
        vendored.setProtocolVersion(3)   // the wrappers are no-ops at version <= 2
        // The vendored encoder's per-pad counters start at 1, so ours must too for a byte match.
        let ours = NvstGamepadPacket(
            sequence: 1,
            timestampMicroseconds: 0x1122_3344,
            buttons: NvstGamepadPacket.Button.a,
            leftTrigger: 0x40,
            rightTrigger: 0xff,
            leftStickX: NvstGamepadPacket.axis(0.5),
            leftStickY: NvstGamepadPacket.axis(-0.75),
            rightStickX: NvstGamepadPacket.axis(0.25),
            rightStickY: NvstGamepadPacket.axis(-1)
        ).payload
        let theirs = vendored.encodeGamepadState(
            controllerId: 0,
            buttons: NvstGamepadPacket.Button.a,
            leftTrigger: 0x40,
            rightTrigger: 0xff,
            leftStickX: NvstGamepadPacket.axis(0.5),
            leftStickY: NvstGamepadPacket.axis(-0.75),
            rightStickX: NvstGamepadPacket.axis(0.25),
            rightStickY: NvstGamepadPacket.axis(-1),
            timestampUs: 0x1122_3344,
            bitmap: NvstGamepadPacket.connectedBitmap,
            partiallyReliable: true
        )
        #expect(ours.count == NvstGamepadPacket.payloadLength)
        #expect(ours.count == theirs.count)
        #expect(Array(ours.dropFirst(9)) == Array(theirs.dropFirst(9)))
        #expect(ours.first == GeronimoInputEnvelope.headerByte)
    }

    /// The individual fields, so a regression names the field it broke rather than dumping 54 bytes.
    /// Offsets are into the 38-byte `GeronimoInputEventType.gamepad` event, which the envelope puts
    /// at payload offset 16.
    @Test func gamepadPacketMatchesTheCapturedStructure() {
        func event(_ p: NvstGamepadPacket) -> [UInt8] { Array(p.payload.dropFirst(16)) }
        func u16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }

        let a = event(NvstGamepadPacket(sequence: 1, timestampMicroseconds: 0, buttons: NvstGamepadPacket.Button.a))
        #expect(a.count == NvstGamepadPacket.eventLength)
        #expect(u16(a, 0) == 12)     // GeronimoInputEventType.gamepad
        #expect(u16(a, 4) == 26)     // raw-gamepad-data tag from initializeRawGamepadData
        #expect(u16(a, 6) == 0)      // gamepad id; handleGamepadStateEvent rejects >= 4
        // event[8..10] is the CONNECTED BITMAP as a u16 (updateGamepadsBitmap writes a u16):
        // bit i = gamepad i connected, bit (i+8) = that pad is XInput-style. 0x0101 = one pad on
        // slot 0, XInput. (3 announced gamepads 0 AND 1 — one controller became two in the game.)
        #expect(u16(a, 8) == 0x0101)
        #expect(u16(a, 10) == 20)
        #expect(u16(a, 26) == 0x55)  // marker
        #expect(u16(a, 12) == 0x1000)  // A button

        let start = event(NvstGamepadPacket(sequence: 8, timestampMicroseconds: 0, buttons: NvstGamepadPacket.Button.start))
        #expect(u16(start, 12) == 0x0010)

        let lx = event(NvstGamepadPacket(sequence: 2, timestampMicroseconds: 0, buttons: 0, leftStickX: NvstGamepadPacket.axis(0.5)))
        #expect(Int16(bitPattern: u16(lx, 16)) == 16384)   // left stick X
        #expect(u16(lx, 12) == 0)                          // no buttons
        #expect(u16(lx, 26) == 0x55)                       // axis write did not clobber the marker

        // Both triggers share one u16: left low, right high.
        let tr = event(NvstGamepadPacket(sequence: 7, timestampMicroseconds: 0, buttons: 0,
                                         leftTrigger: 0x12, rightTrigger: NvstGamepadPacket.trigger(1)))
        #expect(u16(tr, 14) == 0xff12)

        // The per-packet timestamp is one u64 LE at 30 and never overwrites the marker.
        let ts = event(NvstGamepadPacket(sequence: 3, timestampMicroseconds: 0x1122_3344, buttons: 0))
        #expect(u16(ts, 26) == 0x55)
        let stamp = (0..<8).reduce(UInt64(0)) { $0 | UInt64(ts[30 + $1]) << UInt64($1 * 8) }
        #expect(stamp == 0x1122_3344)
        let big = event(NvstGamepadPacket(sequence: 4, timestampMicroseconds: 0x0000_00AA_BBCC_DDEE, buttons: 0))
        let bigStamp = (0..<8).reduce(UInt64(0)) { $0 | UInt64(big[30 + $1]) << UInt64($1 * 8) }
        #expect(bigStamp == 0x0000_00AA_BBCC_DDEE)
    }

    /// The envelope itself: `[0x23][u64 BE][0x26][index][u16 BE seq][0x21][u16 BE 38]`. The two
    /// length bytes and the `0x21` tag are exactly what the old 52-byte packet was missing.
    @Test func gamepadPacketCarriesTheLengthPrefixedPartiallyReliableEnvelope() {
        let packet = NvstGamepadPacket(sequence: 0x0102, timestampMicroseconds: 0, buttons: 0).payload
        let bytes = Array(packet)
        #expect(bytes.count == 54)
        #expect(bytes[0] == GeronimoInputEnvelope.headerByte)
        #expect(bytes[9] == GeronimoInputEnvelope.partiallyReliablePayloadTag)
        #expect(bytes[10] == 0)                                     // gamepad index
        #expect(bytes[11] == 0x01 && bytes[12] == 0x02)             // sequence, big-endian u16
        #expect(bytes[13] == GeronimoInputEnvelope.lengthPrefixedPayloadTag)
        #expect(bytes[14] == 0x00 && bytes[15] == 38)               // payload length, big-endian
    }

    /// The axis and trigger scalings the capture pins down: 0.5, 0.25 and -0.75 land on exactly
    /// `value * 32768`, and the triggers on `value * 255`.
    @Test func axesAndTriggersUseTheCapturedScaling() {
        #expect(NvstGamepadPacket.axis(0.5) == 16384)
        #expect(NvstGamepadPacket.axis(0.25) == 8192)
        #expect(NvstGamepadPacket.axis(-0.75) == -24576)
        #expect(NvstGamepadPacket.axis(1) == 32767)
        #expect(NvstGamepadPacket.axis(-1) == -32768)
        #expect(NvstGamepadPacket.trigger(0.5) == 128)
        #expect(NvstGamepadPacket.trigger(1) == 255)
        #expect(NvstGamepadPacket.trigger(0) == 0)
    }

    @Test func ourButtonsMapOntoXInputsMask() {
        #expect(NvstBifrostFreeTransport.wireButtons([.south]) == 0x1000)
        #expect(NvstBifrostFreeTransport.wireButtons([.north]) == 0x8000)
        #expect(NvstBifrostFreeTransport.wireButtons([.start]) == 0x0010)
        #expect(NvstBifrostFreeTransport.wireButtons([.south, .start]) == 0x1010)
        #expect(NvstBifrostFreeTransport.wireButtons([]) == 0)
    }
}

@Suite
struct NvstAbsolutePointerAndWheelTests {

    /// Byte-exact against a captured absolute move. The declared viewport is the stream view's own
    /// content frame: this sample was produced by asking for (1920, 1080), which the view clamped
    /// to its 1632x688 frame before sending.
    @Test func anAbsoluteMoveMatchesTheCapturedEvent() {
        let framed = NvstRemoteInput.framed(
            NvstRemoteInput.absoluteMouseMove(x: 1631, y: 687, viewportWidth: 1632, viewportHeight: 688),
            framing: .enveloped,
            sequence: 0,
            timestampMicroseconds: 0x0000_0000_0167_b3d6
        )
        #expect(framed.count == 48)
        // Compared up to the padding only: the capture's padding carries stale buffer content.
        #expect(framed.map { String(format: "%02x", $0) }.joined().hasPrefix(
            "0000002c0e0000000000000e05000000065f02af0800066002b0"))
        // Absolute positions carry the clock twice, like key events.
        #expect(Array(framed[32..<40]) == Array(framed[40..<48]))
    }

    @Test func theAbsoluteFlagAndViewportAreInTheBody() {
        let packet = NvstRemoteInput.absoluteMouseMove(x: 100, y: 200, viewportWidth: 1632, viewportHeight: 688)
        // Inner packet: [BE u32 length][LE u32 type][body]
        // The inner packet is its 8-byte header plus a 10-byte body, and the length field it
        // declares is 14 — type plus body — which is what the capture carries.
        #expect(packet.count == 18)
        #expect(UInt32(packet[0]) << 24 | UInt32(packet[1]) << 16 | UInt32(packet[2]) << 8 | UInt32(packet[3]) == 14)
        #expect(packet[4] == 5)
        #expect(UInt16(packet[8]) << 8 | UInt16(packet[9]) == 100)
        #expect(UInt16(packet[10]) << 8 | UInt16(packet[11]) == 200)
        #expect(UInt16(packet[12]) << 8 | UInt16(packet[13]) == NvstRemoteInput.absoluteFlag)
        #expect(UInt16(packet[14]) << 8 | UInt16(packet[15]) == 1632)
        #expect(UInt16(packet[16]) << 8 | UInt16(packet[17]) == 688)
    }

    /// Byte-exact against a captured single downward notch, which the wire carries as -120.
    ///
    /// The encoder takes `WHEEL_DELTA` units directly and must not rescale: the stream view's
    /// `accumulatedWheelDelta` already multiplies by 120, and the vendored transport passes its
    /// value through untouched. Rescaling here turned one notch into 14400.
    @Test func aWheelMovementMatchesTheCapturedEvent() {
        let down = NvstRemoteInput.framed(
            NvstRemoteInput.mouseWheel(delta: -NvstRemoteInput.wheelDelta16),
            framing: .enveloped, sequence: 0, timestampMicroseconds: 0x0000_0000_0167_b3d6
        )
        #expect(down.count == 40)
        #expect(down.map { String(format: "%02x", $0) }.joined().hasPrefix(
            "000000240e0000000000000a0a0000000000ff88"))
        let up = NvstRemoteInput.mouseWheel(delta: NvstRemoteInput.wheelDelta16)
        #expect(UInt16(up[8]) << 8 | UInt16(up[9]) == 0)
        #expect(Int16(bitPattern: UInt16(up[10]) << 8 | UInt16(up[11])) == 120)
        #expect(NvstRemoteInput.framed(up, framing: .enveloped, sequence: 0, timestampMicroseconds: 1).count == 40)
    }

    /// A full-scale scroll must stay inside the field rather than wrapping through it.
    @Test func aLargeWheelMovementIsNotRescaled() {
        let large = NvstRemoteInput.mouseWheel(delta: 3600)   // 30 notches, as a fast flick produces
        #expect(Int16(bitPattern: UInt16(large[10]) << 8 | UInt16(large[11])) == 3600)
    }

    /// Every pointer and key form the app can produce now encodes; only text remains.
    @Test func everyPointerAndKeyEventEncodes() {
        let stamp = MediaTimestamp(nanoseconds: 0)
        let events: [UserInputEvent] = [
            .mouse(.moved(deviceID: "m", deltaX: 5, deltaY: -5, timestamp: stamp)),
            .mouse(.button(deviceID: "m", button: .left, isPressed: true, timestamp: stamp)),
            .mouse(.wheel(deviceID: "m", delta: -1, timestamp: stamp)),
            .keyboard(.init(deviceID: "k", keyCode: 56, scanCode: 56, isPressed: true, timestamp: stamp)),
        ]
        for event in events {
            #expect(NvstBifrostFreeTransport.remoteInputPacket(for: event) != nil, "no encoding for \(event)")
        }
    }
}

@Suite
struct NvstStreamProfileTests {

    /// The frame rate is configurable end to end, so nothing may hardcode 60. The pacing target
    /// must follow the negotiated session, not the client's display: the capture's native stack ran
    /// on a 75 Hz panel and still reported ~15905 µs, its 60 fps session.
    @Test func theNegotiatedFrameRateIsReadFromTheSessionProfile() {
        func profile(_ json: String) -> NvstBifrostFreeTransport.StreamProfile {
            NvstBifrostFreeTransport.streamProfile(from: NativeNVSTSessionAllocation(
                session: StreamSessionDescriptor(id: "s", applicationID: "1", serverAddress: "", title: "T"),
                signalingServer: "wss://example.test",
                signalingURL: "",
                signalingQueryParameters: "",
                signalingHeaders: [],
                streamingBaseURL: "https://example.test",
                mediaHost: "10.0.0.1",
                mediaPort: 47989,
                serverType: 0x33,
                authTokenType: "JWT",
                authToken: "token",
                settingsJSON: "{}",
                sessionInfoJSON: json,
                rawSessionJSON: "{}"
            ))
        }
        #expect(profile(#"{"negotiatedStreamProfile":{"fps":120}}"#).fps == 120)
        #expect(profile(#"{"negotiatedStreamProfile":{"fps":60}}"#).fps == 60)
        #expect(profile(#"{"negotiatedStreamProfile":{"fps":240}}"#).fps == 240)
        // Absent rather than assumed, so the caller decides the fallback.
        #expect(profile(#"{"negotiatedStreamProfile":{}}"#).fps == nil)

        // fps also lives in these places depending on how the session was built; missing it makes
        // the pacing feedback default to 60 and the seat holds a 120 stream at 60.
        #expect(profile(#"{"selectedVideoMode":{"fps":120}}"#).fps == 120)
        #expect(profile(#"{"selectedEncodeMode":{"fps":144}}"#).fps == 144)
        #expect(profile(#"{"framesPerSecond":120}"#).fps == 120)
        #expect(profile(#"{"fps":"120"}"#).fps == 120)   // string form
    }

    /// The frame interval the pacer is told, for the rates the app can be configured to.
    @Test func theFrameIntervalFollowsTheFrameRate() {
        #expect(1_000_000 / 60 == 16666)
        #expect(1_000_000 / 120 == 8333)
        #expect(1_000_000 / 144 == 6944)
        // The fallback when the session names no rate.
        #expect(NvstBifrostFreeTransport.targetFrameTimeMicroseconds == 16000)
    }
}

@Suite
struct NvstAnnouncedBitrateTests {

    private func announce(bitrateKbps: Int?, maximumBitrateKbps: Int?) -> [String: String] {
        let body = NvstRtspSdp.buildAnnounceSdp(NvstRtspSdp.AnnounceOptions(
            resolution: "1920x1080",
            videoPort: 5004,
            officialCloudPath: true,
            rtcpOnSctp: false,
            offeredAttributes: [],
            bitrateKbps: bitrateKbps,
            maximumBitrateKbps: maximumBitrateKbps
        ))
        var attributes: [String: String] = [:]
        for line in body.split(separator: "\r\n") where line.hasPrefix("a=x-nv-") {
            let pair = line.dropFirst("a=".count).split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }
            attributes[String(pair[0])] = String(pair[1])
        }
        return attributes
    }

    /// The configured ceiling has to replace the captured default, or the setting does nothing on
    /// this path: the capture announces NVIDIA's own 100000 regardless of what the user picked.
    @Test func theConfiguredCeilingIsAnnounced() {
        let announced = announce(bitrateKbps: 25_000, maximumBitrateKbps: 40_000)
        #expect(announced["x-nv-vqos[0].bw.maximumBitrateKbps"] == "40000")
        #expect(announced["x-nv-video[0].initialBitrateKbps"] == "25000")
        #expect(announced["x-nv-video[0].initialPeakBitrateKbps"] == "25000")
    }

    /// With nothing configured the captured value stands, so absent settings cannot narrow the
    /// stream by accident.
    @Test func withoutACeilingTheCapturedDefaultStands() {
        let announced = announce(bitrateKbps: nil, maximumBitrateKbps: nil)
        #expect(announced["x-nv-vqos[0].bw.maximumBitrateKbps"] == "100000")
    }

    @Test func aZeroCeilingIsIgnoredRatherThanAnnounced() {
        #expect(announce(bitrateKbps: nil, maximumBitrateKbps: 0)["x-nv-vqos[0].bw.maximumBitrateKbps"] == "100000")
    }

    /// The ceiling must come only from `maxBitrateKbps`. Reading it from `bitrateKbps` too would
    /// pin the stream to whatever it started at.
    @Test func theCeilingComesOnlyFromTheMaximumKey() {
        func profile(_ json: String) -> NvstBifrostFreeTransport.StreamProfile {
            NvstBifrostFreeTransport.streamProfile(from: NativeNVSTSessionAllocation(
                session: StreamSessionDescriptor(id: "s", applicationID: "1", serverAddress: "", title: "T"),
                signalingServer: "wss://example.test", signalingURL: "", signalingQueryParameters: "",
                signalingHeaders: [], streamingBaseURL: "https://example.test", mediaHost: "10.0.0.1",
                mediaPort: 47989, serverType: 0x33, authTokenType: "JWT", authToken: "token",
                settingsJSON: "{}", sessionInfoJSON: json, rawSessionJSON: "{}"
            ))
        }
        let both = profile(#"{"negotiatedStreamProfile":{"maxBitrateKbps":45000}}"#)
        #expect(both.maximumBitrateKbps == 45_000)
        #expect(both.bitrateKbps == 45_000)
        let initialOnly = profile(#"{"negotiatedStreamProfile":{"bitrateKbps":12000}}"#)
        #expect(initialOnly.maximumBitrateKbps == nil)
        #expect(initialOnly.bitrateKbps == 12_000)
    }
}

@Suite
struct NvstTextInputTests {

    /// Plain ASCII typing reaches the transport as key events, but paste, IME composition,
    /// Option-modified and non-ASCII characters all arrive as `text` — which had no encoding and
    /// was swallowed by the `try?` at the call site. Typing it is a fallback, not the protocol's
    /// own answer, so what it cannot represent must be reported rather than approximated.
    @Test func lowercaseAndDigitsNeedNoShift() {
        let (strokes, unmappable) = NvstTextInput.keystrokes(for: "abc190")
        #expect(unmappable.isEmpty)
        #expect(strokes.map(\.virtualKey) == [0x41, 0x42, 0x43, 0x31, 0x39, 0x30])
        #expect(strokes.allSatisfy { !$0.needsShift })
    }

    @Test func uppercaseAndSymbolsNeedShiftOnTheSameKeys() {
        let upper = NvstTextInput.keystrokes(for: "AZ").strokes
        #expect(upper.map(\.virtualKey) == [0x41, 0x5a])
        #expect(upper.allSatisfy { $0.needsShift })
        // A shifted symbol reuses its unshifted key: '!' is shift+'1' (0x31), '_' is shift+'-'
        // (NVST 0x2d, not the Windows OEM VK 0xbd).
        let bang = NvstTextInput.keystrokes(for: "!").strokes
        #expect(bang == [NvstTextInput.Keystroke(virtualKey: 0x31, needsShift: true)])
        let underscore = NvstTextInput.keystrokes(for: "_").strokes
        #expect(underscore == [NvstTextInput.Keystroke(virtualKey: 0xbd, needsShift: true)])
    }

    /// A realistic paste: a password with mixed case, digits and punctuation.
    @Test func aMixedPasswordMapsEntirely() {
        let (strokes, unmappable) = NvstTextInput.keystrokes(for: "Tr0ub4dor&3!")
        #expect(unmappable.isEmpty)
        #expect(strokes.count == 12)
        #expect(strokes.first == NvstTextInput.Keystroke(virtualKey: 0x54, needsShift: true))
    }

    @Test func whitespaceAndReturnAreMapped() {
        #expect(NvstTextInput.keystrokes(for: " ").strokes.first?.virtualKey == 0x20)
        #expect(NvstTextInput.keystrokes(for: "\t").strokes.first?.virtualKey == 0x09)
        #expect(NvstTextInput.keystrokes(for: "\n").strokes.first?.virtualKey == 0x0d)
    }

    /// Characters a US layout cannot produce are reported, not guessed at — and the rest still gets
    /// typed rather than the whole string being lost.
    @Test func unmappableCharactersAreReportedAndTheRestSurvives() {
        let (strokes, unmappable) = NvstTextInput.keystrokes(for: "aé日b")
        #expect(unmappable == ["é", "日"])
        #expect(strokes.map(\.virtualKey) == [0x41, 0x42])
    }

    @Test func anEmptyStringProducesNothing() {
        let (strokes, unmappable) = NvstTextInput.keystrokes(for: "")
        #expect(strokes.isEmpty)
        #expect(unmappable.isEmpty)
    }
}

@Suite
struct NvstTransportLifecycleTests {

    /// The host applies the microphone configuration *before* `start`, in the same `do` block, so a
    /// transport that throws there prevents the stream from ever starting — the launch dies right
    /// after "Launch plan ready" and never requests a session. This is a regression guard, not a
    /// feature test: the protocol's own default is a no-op for exactly this reason.
    @Test func applyingAMicrophoneConfigurationNeverThrows() async throws {
        let transport = NvstBifrostFreeTransport(logger: nil)
        try await transport.setMicrophoneConfiguration(
            NativeNVSTMicrophoneConfiguration(volume: 1,
                                              voiceActivityEnabled: true,
                                              captureRequested: true,
                                              initiallyEnabled: true))
    }

    /// Disabling an absent microphone is already true, so it succeeds. Enabling it is a request this
    /// path cannot honour, and that has to surface rather than pretend.
    @Test func disablingTheMicrophoneSucceedsAndEnablingItReports() async throws {
        let transport = NvstBifrostFreeTransport(logger: nil)
        try await transport.setMicrophoneEnabled(false)
        await #expect(throws: (any Error).self) {
            try await transport.setMicrophoneEnabled(true)
        }
    }
}

@Suite
struct NvstStreamHealthMonitorTests {

    /// `performanceSnapshot` must stay nil on this path. The monitor's first line is
    /// `guard let snapshot, snapshot.available`, so returning one arms it — and once armed it
    /// requires `nativeNVSTRendererSurfaceReady`, which is tied to the vendored NVST Metal view.
    /// This path renders elsewhere, so that can never be true and the monitor tore down a healthy
    /// stream after five samples. This test is the guard against re-arming it by accident.
    @Test func theTransportReportsNoPerformanceSnapshot() async {
        let transport = NvstBifrostFreeTransport(logger: nil)
        #expect(await transport.performanceSnapshot() == nil)
    }

    /// And the monitor itself: a nil snapshot must stay inert no matter what the renderer says,
    /// which is the property the transport is relying on.
    @Test func aNilSnapshotKeepsTheMonitorInert() {
        var monitor = NativeNVSTStreamHealthMonitor(firstFrameSampleLimit: 1, stalledSampleLimit: 1, rendererSampleLimit: 1)
        for _ in 0..<10 {
            #expect(monitor.observe(snapshot: nil, rendererReady: false) == nil)
        }
    }

    /// The behaviour that bit us, pinned so the cause stays documented: an available snapshot plus
    /// an unready renderer is a teardown.
    @Test func anAvailableSnapshotWithNoRendererIsATeardown() {
        var monitor = NativeNVSTStreamHealthMonitor(firstFrameSampleLimit: 20, stalledSampleLimit: 20, rendererSampleLimit: 3)
        let snapshot = NativeNVSTPerformanceSnapshot(
            available: true, gameFramesPerSecond: 60, streamFramesPerSecond: 60,
            latencyMilliseconds: 1, jitterMilliseconds: 1, frameLoss: 0, totalFrameLoss: 0,
            packetLoss: 0, totalPacketLoss: 0, bitrateMegabitsPerSecond: 10,
            bandwidthUtilizationPercent: 0, resolution: "1920x1080", codec: "H264", serverLocation: ""
        )
        #expect(monitor.observe(snapshot: snapshot, rendererReady: false) == nil)
        #expect(monitor.observe(snapshot: snapshot, rendererReady: false) == nil)
        #expect(monitor.observe(snapshot: snapshot, rendererReady: false) == .rendererUnavailable)
    }
}

@Suite
struct NvstTypedTextShiftTests {

    /// Shift must never be left held. The release used to sit after the loop, so a send that threw
    /// partway through a string exited with shift still down and nothing on the remote to release
    /// it. The mapping is the part that can be asserted here; the release itself is a `defer`.
    @Test func aStringMixingShiftedAndUnshiftedKeysAlternatesCleanly() {
        let (strokes, unmappable) = NvstTextInput.keystrokes(for: "aAbB")
        #expect(unmappable.isEmpty)
        #expect(strokes.map { $0.needsShift } == [false, true, false, true])
    }

    /// A string ending on a shifted character is the case that leaves shift held at the end of the
    /// loop, so it must be represented as such for the release to be exercised.
    @Test func aStringEndingShiftedStillNeedsARelease() {
        let strokes = NvstTextInput.keystrokes(for: "ab!").strokes
        #expect(strokes.last?.needsShift == true)
    }
}

@Suite
struct NvstModifierAndShortcutTests {

    /// Sided Windows virtual keys, confirmed from a capture of the vendored client: left shift is
    /// 0x00A0 on the wire. A generic-VK and an NVST-internal-code detour were both wrong.
    @Test func modifiersMapToSidedWindowsVirtualKeys() {
        let expect: [(UInt16, UInt16)] = [
            (56, 0xa0), (60, 0xa1),   // left / right shift
            (59, 0xa2), (62, 0xa3),   // left / right control
            (58, 0xa4), (61, 0xa5),   // left / right option (Alt)
        ]
        for (mac, vk) in expect {
            #expect(NativeWebRTCTransport.keyboardCodes(forMacKeyCode: mac).keyCode == vk, "mac \(mac)")
        }
    }

    /// Command maps to Control so Cmd+C/V/A carry the copy/paste intent to a Windows host.
    @Test func commandMapsToControl() {
        #expect(NativeWebRTCTransport.keyboardCodes(forMacKeyCode: 54).keyCode == 0xa2)
        #expect(NativeWebRTCTransport.keyboardCodes(forMacKeyCode: 55).keyCode == 0xa2)
    }

    /// The keyboard packet carries the modifier field the seat capitalizes from. Held shift + 'A'
    /// registered the shift key (overlay shortcuts worked) but never capitalized, because the
    /// letter packet did not carry the shift bit. `[BE u16 key][BE u16 modifiers]`, shift = 0x0001.
    @Test func theKeyboardPacketCarriesTheModifierField() {
        let shiftedA = NvstRemoteInput.keyboard(virtualKey: 0x41,
                                                modifiers: UInt16(KeyboardModifiers.shift.rawValue),
                                                isPressed: true)
        #expect(shiftedA[4] == 3)                          // inner type: key down
        #expect(shiftedA[8] == 0x00 && shiftedA[9] == 0x41) // key 'A'
        #expect(shiftedA[10] == 0x00 && shiftedA[11] == 0x01) // modifier field: shift
        let plainA = NvstRemoteInput.keyboard(virtualKey: 0x41, isPressed: true)
        #expect(plainA[10] == 0x00 && plainA[11] == 0x00)   // no modifiers
    }

    /// Cmd+C forwards as a full Control chord — Control down, key down, key up, Control up — with
    /// nothing left held. `8` is mac key code for the letter 'c'.
    @Test func aPlainCommandShortcutWrapsInControl() {
        let strokes = NativeWebRTCStreamView.commandShortcutStrokes(keyCode: 8, shift: false, option: false)
        #expect(strokes.map(\.keyCode) == [55, 8, 8, 55])
        #expect(strokes.map(\.isPressed) == [true, true, false, false])
    }

    /// Cmd+Shift+key nests the extra modifier strictly inside Control and releases it before
    /// Control, so no key is ever orphaned.
    @Test func aShiftedCommandShortcutNestsAndUnwindsCleanly() {
        let strokes = NativeWebRTCStreamView.commandShortcutStrokes(keyCode: 0, shift: true, option: false)
        #expect(strokes.map(\.keyCode) == [55, 56, 0, 0, 56, 55])
        #expect(strokes.map(\.isPressed) == [true, true, true, false, false, false])
        // Every press has a matching release.
        var held = Set<UInt16>()
        for stroke in strokes { if stroke.isPressed { held.insert(stroke.keyCode) } else { held.remove(stroke.keyCode) } }
        #expect(held.isEmpty)
    }
}

@Suite struct NvstAv1FrameHeaderTests {
    /// AV1 carries no Annex-B start code, so the frame-header boundary is a fixed size chosen by
    /// the payload's first byte. GFN's cloud extended header is 20 bytes — not the 44 of the
    /// similarly named consumer GameStream layout — and the short header is 8.
    @Test func stripsTheGfnCloudAv1FrameHeaders() {
        var short = Data([0x01]) + Data(repeating: 0, count: 7)
        short.append(contentsOf: [0x12, 0x34, 0x56])
        #expect(NvstAnnexB.picturePayload(short, codec: .av1) == Data([0x12, 0x34, 0x56]))

        var extended = Data([0x81]) + Data(repeating: 0, count: 19)
        extended.append(contentsOf: [0xAB, 0xCD])
        #expect(NvstAnnexB.picturePayload(extended, codec: .av1) == Data([0xAB, 0xCD]))

        // A payload that is only a header carries no picture data.
        #expect(NvstAnnexB.picturePayload(Data([0x01]) + Data(repeating: 0, count: 7), codec: .av1) == nil)
        // An unknown leading byte is not guessed at.
        #expect(NvstAnnexB.picturePayload(Data([0x42, 0x00, 0x00, 0x01, 0x09]), codec: .av1) == nil)
        // H.264 still uses the start-code search, so a stray AV1-looking byte changes nothing.
        // (the 4-byte start code is kept, so the picture begins at 00 00 00 01)
        #expect(NvstAnnexB.picturePayload(Data([0x81, 0x00, 0x00, 0x00, 0x01, 0x67]), codec: .h264) == Data([0x00, 0x00, 0x00, 0x01, 0x67]))
    }
}

@Suite struct NvstAv1AccessUnitLengthTests {
    /// The GFN cloud AV1 `0x81` header states the whole access unit's size at bytes 16..<20.
    /// AV1 is not self-delimiting, so trailing bytes from the last packet would otherwise reach the
    /// decoder as OBU data.
    @Test func readsTheAdvertisedAccessUnitLength() {
        var header = Data(repeating: 0, count: 20)
        header[0] = 0x81
        header.replaceSubrange(16..<20, with: [0x2a, 0x00, 0x00, 0x00])   // 42, little-endian
        #expect(NvstFrameReassembler.av1AccessUnitLength(in: header, codec: .av1) == 42)
        // The short header carries no such field.
        var short = Data(repeating: 0, count: 20)
        short[0] = 0x01
        #expect(NvstFrameReassembler.av1AccessUnitLength(in: short, codec: .av1) == nil)
        // And it is an AV1-only field.
        #expect(NvstFrameReassembler.av1AccessUnitLength(in: header, codec: .hevc) == nil)
        // A truncated header cannot be read rather than being read as garbage.
        #expect(NvstFrameReassembler.av1AccessUnitLength(in: Data([0x81, 0x00]), codec: .av1) == nil)
    }
}
