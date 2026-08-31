//
//  RemoteCoOpNativeNVSTTests.swift
//  OpenNOW
//
//  The three seams that let Remote Co-Op host from the native NVST transport rather than the
//  WebRTC one: the multi-pad gamepad wire format, the pixel-buffer video relay, and the
//  float-PCM audio relay.
//
//  Each of these replaced something that only ever handled one case - one gamepad, one
//  already-libwebrtc-owned frame, one `AudioBufferList` - so the tests are written against the
//  case that did not exist before.
//

import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import Testing
@preconcurrency import WebRTC
@testable import OpenNOW

@Suite struct RemoteCoOpNativeNVSTGamepadWireTests {
    /// The 38-byte gamepad event sits at payload offset 16; both fields under test are u16s inside
    /// it. Mirrors the reader in `NvstFeedbackReportTests` so a change to the envelope shows up in
    /// both places rather than being silently absorbed here.
    private func event(_ packet: NvstGamepadPacket) -> [UInt8] {
        Array(packet.payload.dropFirst(16))
    }

    private func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    /// The single-pad session must encode exactly as it did before guests existed: index 0, the
    /// captured `0x0101` bitmap. Everything about Remote Co-Op is additive, so a solo stream that
    /// changed shape here would be a regression in the common path.
    @Test func aSoloSessionStillEncodesTheOriginalSinglePadState() {
        let bytes = event(NvstGamepadPacket(sequence: 1, timestampMicroseconds: 0, buttons: NvstGamepadPacket.Button.a))
        #expect(u16(bytes, NvstGamepadPacket.gamepadIdOffset) == 0)
        #expect(u16(bytes, NvstGamepadPacket.connectedBitmapOffset) == 0x0101)
    }

    /// A guest on player 2 is gamepad 1, and the bitmap must announce the host's pad as well: the
    /// descriptor is not additive, so a packet claiming only pad 1 tells the seat pad 0 went away.
    @Test func aGuestPadCarriesItsOwnIndexAndTheWholeConnectedSet() {
        let bitmap = NvstGamepadPacket.connectedBitmap(for: [0, 1])
        let bytes = event(NvstGamepadPacket(
            sequence: 4,
            timestampMicroseconds: 0,
            buttons: NvstGamepadPacket.Button.b,
            gamepadIndex: 1,
            connectedBitmap: bitmap
        ))
        #expect(u16(bytes, NvstGamepadPacket.gamepadIdOffset) == 1)
        #expect(u16(bytes, NvstGamepadPacket.connectedBitmapOffset) == 0x0303)
        #expect(u16(bytes, 12) == NvstGamepadPacket.Button.b)
    }

    /// The partially-reliable wrapper repeats the index at payload byte 10, one byte after the
    /// `0x26` tag. It used to be written from the same constant as the event's, so both moved
    /// together by accident; now they are two separate writes and can drift.
    @Test func theEnvelopeAndTheEventNameTheSamePad() {
        let payload = Array(NvstGamepadPacket(sequence: 2, timestampMicroseconds: 0, buttons: 0, gamepadIndex: 3).payload)
        #expect(payload[9] == GeronimoInputEnvelope.partiallyReliablePayloadTag)
        #expect(payload[10] == 3)
        #expect(u16(Array(payload.dropFirst(16)), NvstGamepadPacket.gamepadIdOffset) == 3)
    }

    /// `handleGamepadStateEvent` rejects any id >= 4 outright, so the index is masked rather than
    /// truncated into a neighbouring field.
    @Test func gamepadIndexesAreClampedToTheSeatsFourSlots() {
        #expect(NvstGamepadPacket(sequence: 1, timestampMicroseconds: 0, buttons: 0, gamepadIndex: 7).gamepadIndex == 3)
    }

    /// `1 << i | 1 << (i + 8)`: the low byte is "connected", the high byte is "XInput-style". The
    /// pair has to stay in step - registering as one kind and updating as another is what made the
    /// pad appear and vanish immediately.
    @Test func theConnectedBitmapMarksEveryPadAsXInputStyle() {
        #expect(NvstGamepadPacket.connectedBitmap(for: [0]) == 0x0101)
        #expect(NvstGamepadPacket.connectedBitmap(for: [0, 1]) == 0x0303)
        #expect(NvstGamepadPacket.connectedBitmap(for: [0, 1, 2, 3]) == 0x0F0F)
        #expect(NvstGamepadPacket.connectedBitmap(for: [2]) == 0x0404)
    }

    /// Out-of-range slots cannot be announced, and an empty set is the host-only default rather
    /// than zero: a zero bitmap announces no devices at all, which drops the host's own pad.
    @Test func theConnectedBitmapIgnoresImpossibleSlotsAndNeverAnnouncesNothing() {
        #expect(NvstGamepadPacket.connectedBitmap(for: [4, 9]) == NvstGamepadPacket.connectedBitmap)
        #expect(NvstGamepadPacket.connectedBitmap(for: []) == NvstGamepadPacket.connectedBitmap)
        #expect(NvstGamepadPacket.connectedBitmap(for: [1, 4]) == 0x0202)
    }

    /// The descriptor that registers the pads and the state packets that follow must carry the
    /// same bitmap, so both are derived from one function rather than two.
    @Test func theDeviceDescriptorAnnouncesTheSameSetAsTheStatePacket() {
        let bitmap = NvstGamepadPacket.connectedBitmap(for: [0, 2])
        let descriptor = Array(NvstInputActivation.deviceDescriptor(timestampMicroseconds: 1, connectedBitmap: bitmap).payload)
        // 1 header byte + 8 timestamp bytes, then the body the bitmap is written into.
        let body = Array(descriptor.dropFirst(9))
        let descriptorBitmap = UInt16(body[NvstInputActivation.descriptorIndexOffset]) |
            UInt16(body[NvstInputActivation.descriptorIndexOffset + 1]) << 8
        let stateBitmap = u16(event(NvstGamepadPacket(sequence: 1, timestampMicroseconds: 1, buttons: 0, gamepadIndex: 2, connectedBitmap: bitmap)),
                              NvstGamepadPacket.connectedBitmapOffset)
        #expect(descriptorBitmap == stateBitmap)
        #expect(descriptorBitmap == 0x0505)
    }

    /// `NativeWebRTCGamepadTopology` already built this value for the vendored path. The native
    /// transport derives its descriptor from the same topology, so the two must agree or a guest
    /// would be announced by one and not the other.
    @Test func theTopologyAndThePacketAgreeOnTheBitmap() {
        let topology = NativeWebRTCGamepadTopology(playerIndices: [0, 1])
        #expect(topology.registrationBitmap == NvstGamepadPacket.connectedBitmap(for: topology.playerIndices))
    }
}

@Suite struct RemoteCoOpNativeNVSTVideoRelayTests {
    private final class RecordingVideoSink: OPNRemoteCoOpHostVideoSink, @unchecked Sendable {
        let participantID = UUID()
        private let lock = NSLock()
        private var frames: [RTCVideoFrame] = []

        func renderVideoFrame(_ frame: RTCVideoFrame) {
            lock.lock()
            defer { lock.unlock() }
            frames.append(frame)
        }

        var captured: [RTCVideoFrame] {
            lock.lock()
            defer { lock.unlock() }
            return frames
        }
    }

    private func pixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &buffer)
        #expect(status == kCVReturnSuccess)
        return try #require(buffer)
    }

    /// A 21:9 native session scaled into the 16:9 720p guest preset must letterbox by height, not
    /// squash: the scale is chosen so the whole frame fits, and both dimensions stay even because
    /// I420 subsamples chroma by two.
    @Test func fiveKFramesAreScaledIntoTheGuestPresetWithoutDistortion() {
        let adapted = OPNRemoteCoOpHostVideoRelay.adaptedSize(sourceWidth: 5120, sourceHeight: 2160, maximumWidth: 1280, maximumHeight: 720)
        #expect(adapted.width == 1280)
        #expect(adapted.height == 540)
        #expect(adapted.width % 2 == 0)
        #expect(adapted.height % 2 == 0)
        // 21:9 in, 21:9 out.
        #expect(abs(Double(adapted.width) / Double(adapted.height) - 5120.0 / 2160.0) < 0.01)
    }

    /// A source already smaller than the preset is passed through. Upscaling here would cost the
    /// encoder real work for no added detail.
    @Test func framesSmallerThanThePresetAreNotUpscaled() {
        let adapted = OPNRemoteCoOpHostVideoRelay.adaptedSize(sourceWidth: 960, sourceHeight: 540, maximumWidth: 1920, maximumHeight: 1080)
        #expect(adapted.width == 960)
        #expect(adapted.height == 540)
    }

    /// No preferred size means no scaling, which is what a relay that was never told a preset does.
    @Test func anUnconfiguredRelayDoesNotScale() {
        let adapted = OPNRemoteCoOpHostVideoRelay.adaptedSize(sourceWidth: 3840, sourceHeight: 2160, maximumWidth: 0, maximumHeight: 0)
        #expect(adapted.width == 3840)
        #expect(adapted.height == 2160)
    }

    /// The decode thread calls this for every frame of every session, guest or not. It has to cost
    /// nothing when nobody is connected - no wrap, no scale, no allocation.
    @Test func aDecodedFrameIsDroppedWhenNoGuestIsConnected() throws {
        let relay = OPNRemoteCoOpHostVideoRelay()
        relay.setPreferredOutputSize(width: 1280, height: 720)
        relay.renderPixelBuffer(try pixelBuffer(width: 1920, height: 1080), presentationTime: .zero)
        #expect(relay.activeSinkCount() == 0)
    }

    /// The whole point of the native path: a `CVPixelBuffer` straight off the VideoToolbox decoder
    /// reaches a guest as an `RTCVideoFrame` at the preset's size.
    @Test func aDecodedFrameReachesAConnectedGuestAtThePresetSize() throws {
        let relay = OPNRemoteCoOpHostVideoRelay()
        relay.setPreferredOutputSize(width: 1280, height: 720)
        let sink = RecordingVideoSink()
        relay.upsert(sink)
        relay.renderPixelBuffer(try pixelBuffer(width: 3840, height: 2160), presentationTime: CMTime(value: 1, timescale: 60))
        let frame = try #require(sink.captured.first)
        #expect(frame.width == 1280)
        #expect(frame.height == 720)
        // The capture clock, not the session clock: presentation time restarts at zero on recovery
        // and libwebrtc requires a monotonic stamp.
        #expect(frame.timeStampNs > 0)
    }

    /// Removing a guest must stop the frames, not merely stop the peer reading them.
    @Test func removingAGuestStopsTheFrames() throws {
        let relay = OPNRemoteCoOpHostVideoRelay()
        let sink = RecordingVideoSink()
        relay.upsert(sink)
        relay.remove(participantID: sink.participantID)
        relay.renderPixelBuffer(try pixelBuffer(width: 640, height: 360), presentationTime: .zero)
        #expect(sink.captured.isEmpty)
    }
}

@Suite struct RemoteCoOpNativeNVSTAudioRelayTests {
    private final class RecordingAudioSink: OPNRemoteCoOpHostAudioSink, @unchecked Sendable {
        let participantID = UUID()
        private let lock = NSLock()
        private var frames: [OPNRemoteCoOpHostAudioFrame] = []

        func renderAudioFrame(_ frame: OPNRemoteCoOpHostAudioFrame) {
            lock.lock()
            defer { lock.unlock() }
            frames.append(frame)
        }

        var captured: [OPNRemoteCoOpHostAudioFrame] {
            lock.lock()
            defer { lock.unlock() }
            return frames
        }
    }

    private func samples(_ frame: OPNRemoteCoOpHostAudioFrame) -> [Int16] {
        frame.samples.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }

    /// The Bifrost-free audio socket decodes Opus itself and never touches libwebrtc's audio
    /// device, so this float path is the *only* way a guest hears anything on a native session.
    @Test func floatSamplesFromTheNativeSocketReachAGuest() throws {
        let relay = OPNRemoteCoOpHostAudioRelay()
        let sink = RecordingAudioSink()
        relay.upsert(sink)
        relay.renderAudioSamples([0, 0.5, -0.5, 1], sampleRate: 48_000, channels: 2)
        let frame = try #require(sink.captured.first)
        #expect(frame.frameCount == 2)
        #expect(frame.sampleRate == 48_000)
        #expect(frame.channels == 2)
        let converted = samples(frame)
        #expect(converted.count == 4)
        #expect(converted[0] == 0)
        #expect(converted[1] == 16_384)
        #expect(converted[2] == -16_384)
        #expect(converted[3] == 32_767)
    }

    /// Opus can decode slightly past full scale. Scaling that without clamping wraps the sign bit,
    /// which is an audible click rather than quiet distortion.
    @Test func samplesPastFullScaleClampInsteadOfWrapping() throws {
        let relay = OPNRemoteCoOpHostAudioRelay()
        let sink = RecordingAudioSink()
        relay.upsert(sink)
        relay.renderAudioSamples([1.4, -1.4], sampleRate: 48_000, channels: 2)
        let converted = samples(try #require(sink.captured.first))
        #expect(converted[0] == 32_767)
        #expect(converted[1] == -32_767)
    }

    /// A mono source is duplicated across both channels: the guest's peer is configured for stereo
    /// and would otherwise read the second sample of each pair as the next frame's left channel.
    @Test func monoAudioIsUpmixedToStereo() throws {
        let relay = OPNRemoteCoOpHostAudioRelay()
        let sink = RecordingAudioSink()
        relay.upsert(sink)
        relay.renderAudioSamples([0.5, -0.5], sampleRate: 48_000, channels: 1)
        let frame = try #require(sink.captured.first)
        #expect(frame.frameCount == 2)
        let converted = samples(frame)
        #expect(converted == [16_384, 16_384, -16_384, -16_384])
    }

    /// Called from the audio receive queue on every packet of every session. Silent and free when
    /// no guest is listening.
    @Test func floatSamplesAreDroppedWhenNoGuestIsConnected() {
        let relay = OPNRemoteCoOpHostAudioRelay()
        relay.renderAudioSamples([0.5, 0.5], sampleRate: 48_000, channels: 2)
        #expect(relay.activeSinkCount() == 0)
    }

    /// A source that is not already at 48 kHz is resampled, because the guest's audio device is
    /// fixed at the Remote Co-Op frame rate.
    @Test func audioIsResampledToTheGuestSampleRate() throws {
        let relay = OPNRemoteCoOpHostAudioRelay()
        let sink = RecordingAudioSink()
        relay.upsert(sink)
        relay.renderAudioSamples(Array(repeating: 0.25, count: 480), sampleRate: 24_000, channels: 2)
        let frame = try #require(sink.captured.first)
        #expect(frame.sampleRate == 48_000)
        // 240 stereo frames at 24 kHz is 10 ms, which is 480 frames at 48 kHz.
        #expect(frame.frameCount == 480)
    }
}

/// The host signs invites and the broker verifies them, so the two have to derive the same HMAC key
/// from the same configured string. They did not: the broker keys with the string's UTF-8 bytes
/// (Node's `createHmac("sha256", string)`) while the host base64url-decoded it first. Identical
/// configuration produced different digests, so every host registration and every guest join was
/// rejected as an invalid signature.
@Suite struct RemoteCoOpInviteSignatureParityTests {
    /// Generated with the broker's own primitive, so this pins our derivation against Node rather
    /// than against a restatement of the Swift code:
    ///
    ///     createHmac("sha256", "dGVzdC1zZWNyZXQtMzI").update(Buffer.from('{"a":1}')).digest("base64url")
    ///
    /// The secret is deliberately a valid base64url string - the shape `run-servers.mjs` generates
    /// with `randomBytes(32).toString("base64url")` - because that is exactly the input for which
    /// the two derivations differ while looking correctly configured.
    private static let brokerSecret = "dGVzdC1zZWNyZXQtMzI"
    private static let brokerPayload = "{\"a\":1}"
    private static let brokerSignature = "hBdHCaXZwQvqpwNQRl2CD9cXgdV2bH2X5zG6O3Q5XJM"
    /// What the host used to compute for the same inputs, kept as the negative case so a silent
    /// revert to decoding the secret is caught rather than merely changing a digest.
    private static let decodedKeySignature = "215sDRH0p0elce7Sc3QA5vYwjcQal6OCkUAaCAgf4Mg"

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    @Test func theHostKeysInvitesTheSameWayTheBrokerVerifiesThem() {
        let key = OPNRemoteCoOpInviteSecretStore.key(for: Self.brokerSecret)
        let signature = HMAC<SHA256>.authenticationCode(for: Data(Self.brokerPayload.utf8), using: SymmetricKey(data: key))
        #expect(base64URL(Data(signature)) == Self.brokerSignature)
        #expect(base64URL(Data(signature)) != Self.decodedKeySignature)
    }

    /// The key is the secret's bytes, whatever the string happens to look like. A secret that is not
    /// base64 at all used to decode to nothing and silently fall back to a random per-launch key.
    @Test func aSecretThatIsNotBase64IsStillAUsableKey() {
        #expect(OPNRemoteCoOpInviteSecretStore.key(for: "not base64 at all!") == Data("not base64 at all!".utf8))
    }

    /// A signer built from a configured secret must round-trip its own tokens, which is what the
    /// host does when a guest presents the token back to it.
    @Test func aConfiguredSignerVerifiesItsOwnInvites() throws {
        let signer = OPNRemoteCoOpInviteTokenSigner(secret: OPNRemoteCoOpInviteSecretStore.key(for: Self.brokerSecret))
        let now = Date()
        let payload = OPNRemoteCoOpInviteTokenPayload(
            inviteID: UUID(),
            code: "ABC234",
            applicationID: "100",
            title: "Test",
            createdAt: now,
            expiresAt: now.addingTimeInterval(600),
            preferences: OPNRemoteCoOpPreferences(isAlphaOptedIn: true, isEnabled: true, reservedGuestSlots: 1)
        )
        let token = try signer.token(for: payload)
        let verified = try signer.verify(token, now: now)
        #expect(verified.inviteID == payload.inviteID)
        #expect(verified.code == payload.code)
    }

    /// Two different secrets must not verify each other's tokens - the property the whole scheme
    /// rests on, and the one a "key derived from a random fallback" quietly broke.
    @Test func aSignerRejectsTokensMintedWithADifferentSecret() throws {
        let mint = OPNRemoteCoOpInviteTokenSigner(secret: OPNRemoteCoOpInviteSecretStore.key(for: "secret-one"))
        let check = OPNRemoteCoOpInviteTokenSigner(secret: OPNRemoteCoOpInviteSecretStore.key(for: "secret-two"))
        let now = Date()
        let token = try mint.token(for: OPNRemoteCoOpInviteTokenPayload(
            inviteID: UUID(),
            code: "ABC234",
            applicationID: "100",
            title: "Test",
            createdAt: now,
            expiresAt: now.addingTimeInterval(600),
            preferences: OPNRemoteCoOpPreferences()
        ))
        #expect(throws: (any Error).self) { _ = try check.verify(token, now: now) }
    }
}
