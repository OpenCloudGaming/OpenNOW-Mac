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

/// Invite signing, now that OpenNOW is both the signer and the verifier.
///
/// This replaced a suite about deriving the same HMAC key as the Node broker. That sharing was the
/// single largest source of "every join is rejected" - the two sides derived different keys from
/// identical configuration and nothing surfaced it - and it is gone along with the broker. What has
/// to hold is only that a session verifies its own tokens and refuses everyone else's.
@Suite struct RemoteCoOpInviteSigningTests {
    private func payload(code: String = "ABC234", expiresIn: TimeInterval = 600, now: Date = Date()) -> OPNRemoteCoOpInviteTokenPayload {
        OPNRemoteCoOpInviteTokenPayload(
            inviteID: UUID(),
            code: code,
            applicationID: "100",
            title: "Test",
            createdAt: now,
            expiresAt: now.addingTimeInterval(expiresIn),
            preferences: OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 1)
        )
    }

    @Test func aSessionVerifiesItsOwnInvites() throws {
        let signer = OPNRemoteCoOpInviteTokenSigner.perSession()
        let minted = payload()
        let verified = try signer.verify(try signer.token(for: minted))
        #expect(verified.inviteID == minted.inviteID)
        #expect(verified.code == minted.code)
    }

    /// Each session gets its own key, so a token minted by one app run is refused by the next. That
    /// is correct rather than a limitation: invites are per-session and the host that issued one is
    /// the only host that can honour it.
    @Test func adifferentSessionsTokenIsRefused() throws {
        let first = OPNRemoteCoOpInviteTokenSigner.perSession()
        let second = OPNRemoteCoOpInviteTokenSigner.perSession()
        let token = try first.token(for: payload())
        #expect(throws: (any Error).self) { _ = try second.verify(token) }
    }

    /// A tampered payload must not verify, which is the entire point of signing the invite.
    @Test func aTamperedTokenIsRefused() throws {
        let signer = OPNRemoteCoOpInviteTokenSigner.perSession()
        let token = try signer.token(for: payload())
        var parts = token.split(separator: ".").map(String.init)
        #expect(parts.count == 2)
        parts[1] = String(parts[1].reversed())
        #expect(throws: (any Error).self) { _ = try signer.verify(parts.joined(separator: ".")) }
        #expect(throws: (any Error).self) { _ = try signer.verify("not-a-token") }
    }

    @Test func anExpiredTokenIsRefused() throws {
        let signer = OPNRemoteCoOpInviteTokenSigner.perSession()
        let now = Date()
        let token = try signer.token(for: payload(expiresIn: 60, now: now))
        #expect(throws: (any Error).self) { _ = try signer.verify(token, now: now.addingTimeInterval(120)) }
    }
}

/// Regressions the Remote Co-Op gamepad work could cause for a host that has its own controllers.
///
/// `send` now drops state for a pad the seat was never told about, which is what stops a removed
/// guest being resurrected by their own queued input. That same gate can silently kill a *local*
/// controller if the announced set is ever narrower than reality, so these pin the paths that
/// decide what gets announced.
@Suite struct NativeNVSTLocalControllerTopologyTests {
    /// A host with two controllers plugged in at launch. `presentStream` publishes the topology as
    /// soon as the session connects, but input is negotiated separately and may not be ready - the
    /// announce throws and the caller swallows it. The requested set must survive that, or
    /// activation seeds pad 0 alone and player 2 is dead for the whole session with no further
    /// topology change to rescue it.
    @Test func aTopologyRequestedBeforeInputIsReadyIsStillRemembered() async {
        let transport = NvstBifrostFreeTransport()
        let topology = NativeWebRTCGamepadTopology(playerIndices: [0, 1])

        await #expect(throws: (any Error).self) {
            try await transport.updateGamepadTopology(topology)
        }
        #expect(await transport.connectedGamepadIndices == [0, 1])
        // Which is the bitmap activation will announce once input negotiates.
        #expect(NvstGamepadPacket.connectedBitmap(for: await transport.connectedGamepadIndices) == 0x0303)
    }

    /// Four local pads is the seat's maximum and must all be announced together.
    @Test func fourLocalControllersAreAllAnnounced() async {
        let transport = NvstBifrostFreeTransport()
        try? await transport.updateGamepadTopology(NativeWebRTCGamepadTopology(playerIndices: [0, 1, 2, 3]))
        #expect(await transport.connectedGamepadIndices == [0, 1, 2, 3])
        #expect(NvstGamepadPacket.connectedBitmap(for: await transport.connectedGamepadIndices) == 0x0F0F)
    }

    /// A Steam Controller reaches the seat through the same `GamepadState` path as a native pad, and
    /// `NativeWebRTCGamepadMonitor` puts its slot in the same topology
    /// (`Array(newControllerSlots.values) + Array(newSteamSlots.values)`). A Steam Controller on
    /// player 1 alongside a native pad on player 2 must therefore announce both.
    @Test func aSteamControllerSlotIsAnnouncedLikeAnyOtherPad() async {
        let transport = NvstBifrostFreeTransport()
        // What the monitor produces for one native pad in slot 0 and one Steam Controller in slot 1.
        try? await transport.updateGamepadTopology(NativeWebRTCGamepadTopology(playerIndices: [0, 1], hapticPlayerIndices: [0]))
        #expect(await transport.connectedGamepadIndices == [0, 1])
    }

    /// A host with no controller at all still leaves the seat believing in pad 0, because the
    /// activation descriptor announced it. Normalising an empty topology to pad 0 keeps the
    /// announced bitmap and the set that gates state packets in agreement.
    @Test func anEmptyTopologyKeepsPadZeroAnnounced() async {
        let transport = NvstBifrostFreeTransport()
        try? await transport.updateGamepadTopology(NativeWebRTCGamepadTopology(playerIndices: []))
        #expect(await transport.connectedGamepadIndices == [0])
        #expect(NvstGamepadPacket.connectedBitmap(for: await transport.connectedGamepadIndices) == 0x0101)
    }

    /// Unplugging a pad must release its sequence counter. The seat tracks the sequence per gamepad,
    /// so a slot reused by the next controller or guest would resume mid-stream and its first
    /// packets would look stale.
    @Test func droppingAPadReleasesItsSequenceCounter() async {
        let transport = NvstBifrostFreeTransport()
        try? await transport.updateGamepadTopology(NativeWebRTCGamepadTopology(playerIndices: [0, 1]))
        await transport.seedGamepadSequenceForTesting(pad: 1, sequence: 900)
        #expect(await transport.gamepadSequences[1] == 900)

        try? await transport.updateGamepadTopology(NativeWebRTCGamepadTopology(playerIndices: [0]))
        #expect(await transport.connectedGamepadIndices == [0])
        #expect(await transport.gamepadSequences[1] == nil)
    }

    /// The host's own pad keeps working while a guest holds player 2, which is the whole point of
    /// the union: the descriptor is not additive, so announcing only the guest would disconnect the
    /// host's controller.
    @Test func aGuestSlotDoesNotDisplaceTheHostsOwnPad() async {
        let transport = NvstBifrostFreeTransport()
        let hostOnly = NativeWebRTCGamepadTopology(playerIndices: [0])
        try? await transport.updateGamepadTopology(hostOnly)
        #expect(await transport.connectedGamepadIndices == [0])

        // What `mergedGamepadTopology` builds once a guest is approved into slot 1.
        let withGuest = NativeWebRTCGamepadTopology(playerIndices: hostOnly.playerIndices + [1])
        try? await transport.updateGamepadTopology(withGuest)
        #expect(await transport.connectedGamepadIndices == [0, 1])
    }
}

/// The rule that decides whether a guest's video relay forwards a frame.
///
/// Written against the failure it replaced: a pacer that delayed frames and re-stamped them, which
/// showed up as a 407 ms jitter buffer on a 4 ms LAN route. The properties that matter are that a
/// source running at the target rate loses nothing, that timestamps are carried through rather than
/// invented, and that a faster source is decimated rather than queued.
@Suite struct RemoteCoOpVideoRateLimiterTests {
    private let second: Int64 = 1_000_000_000

    /// A 60 fps source into a 60 fps preset must forward every frame.
    ///
    /// The pacer this replaced set its next deadline *after* the I420 conversion had run, so each
    /// cycle slipped by the conversion cost. The slip accumulated until two source frames fell into
    /// one delivery window and one was dropped - a drop rate of roughly work-per-frame over the
    /// frame interval, plus up to a full frame of queuing delay on every frame.
    @Test func aSourceAtTheTargetRateLosesNothing() {
        var limiter = OPNRemoteCoOpVideoRateLimiter(targetFps: 60)
        let interval = second / 60
        for index in 0..<120 {
            let timestamp = Int64(index) * interval + interval
            #expect(limiter.decide(sourceTimestampNs: timestamp, arrivalNs: timestamp) == .forward(timeStampNs: timestamp))
        }
        #expect(limiter.forwardedCount == 120)
        #expect(limiter.droppedCount == 0)
    }

    /// Real sources jitter either side of the nominal interval. Without headroom on the minimum gap
    /// every marginally-early frame is rejected, halving the delivered rate.
    @Test func ordinarySourceJitterDoesNotCauseDrops() {
        var limiter = OPNRemoteCoOpVideoRateLimiter(targetFps: 60)
        let interval = second / 60
        var timestamp: Int64 = interval
        // Alternately 6% early and 6% late, which is well inside what a 60 Hz capture produces.
        for index in 0..<100 {
            timestamp += index.isMultiple(of: 2) ? interval * 94 / 100 : interval * 106 / 100
            #expect(limiter.decide(sourceTimestampNs: timestamp, arrivalNs: timestamp) == .forward(timeStampNs: timestamp))
        }
        #expect(limiter.droppedCount == 0)
    }

    /// A 120 fps source into a 60 fps preset is halved, and the halving happens here rather than
    /// after an I420 conversion has already been paid for.
    @Test func aFasterSourceIsDecimatedToTheTarget() {
        var limiter = OPNRemoteCoOpVideoRateLimiter(targetFps: 60)
        let interval = second / 120
        var forwarded = 0
        for index in 1...120 {
            if case .forward = limiter.decide(sourceTimestampNs: Int64(index) * interval, arrivalNs: Int64(index) * interval) {
                forwarded += 1
            }
        }
        // Half of 120, within one frame of scheduling phase.
        #expect(abs(forwarded - 60) <= 1)
        #expect(limiter.droppedCount > 0)
    }

    /// A slower source is never held back: every frame goes straight out.
    @Test func aSlowerSourceIsForwardedUntouched() {
        var limiter = OPNRemoteCoOpVideoRateLimiter(targetFps: 60)
        let interval = second / 30
        for index in 1...30 {
            let timestamp = Int64(index) * interval
            #expect(limiter.decide(sourceTimestampNs: timestamp, arrivalNs: timestamp) == .forward(timeStampNs: timestamp))
        }
        #expect(limiter.droppedCount == 0)
    }

    /// The source's own capture time is what goes on the wire. Re-stamping is what made a smooth
    /// source look like a jittery network to the receiver.
    @Test func theSourceTimestampIsCarriedThrough() {
        var limiter = OPNRemoteCoOpVideoRateLimiter(targetFps: 30)
        let sourceTimestamp: Int64 = 987_654_321
        #expect(limiter.decide(sourceTimestampNs: sourceTimestamp, arrivalNs: 111) == .forward(timeStampNs: sourceTimestamp))
        #expect(limiter.lastForwardedTimestampNs == sourceTimestamp)
    }

    /// libwebrtc rejects a frame whose capture time did not advance, so a repeated or backwards
    /// source timestamp falls back to the arrival clock rather than being forwarded as-is.
    @Test func nonMonotonicSourceTimestampsFallBackToArrival() {
        var limiter = OPNRemoteCoOpVideoRateLimiter(targetFps: 30)
        let first = second
        #expect(limiter.decide(sourceTimestampNs: first, arrivalNs: first) == .forward(timeStampNs: first))

        // Same timestamp again, arriving a full interval later.
        let arrival = first + second / 30
        guard case .forward(let repeated) = limiter.decide(sourceTimestampNs: first, arrivalNs: arrival) else {
            Issue.record("a frame a full interval later must still be forwarded")
            return
        }
        #expect(repeated > first)

        // Backwards timestamp, likewise.
        let laterArrival = arrival + second / 30
        guard case .forward(let recovered) = limiter.decide(sourceTimestampNs: 1, arrivalNs: laterArrival) else {
            Issue.record("a backwards timestamp must not stall the stream")
            return
        }
        #expect(recovered > repeated)
    }

    /// Every preset the UI offers has to produce a sane floor.
    @Test func everyGuestPresetProducesAUsableInterval() {
        for preset in OPNRemoteCoOpQualityPreset.allCases {
            let limiter = OPNRemoteCoOpVideoRateLimiter(targetFps: preset.fps)
            #expect(limiter.minimumFrameIntervalNs > 0)
            // Never above the nominal interval, or a source at the target rate would lose frames.
            #expect(limiter.minimumFrameIntervalNs < Int64(1_000_000_000 / preset.fps))
        }
    }

    /// A zero or negative frame rate must not divide by zero.
    @Test func aDegenerateFrameRateIsClamped() {
        #expect(OPNRemoteCoOpVideoRateLimiter(targetFps: 0).targetFps == 1)
        #expect(OPNRemoteCoOpVideoRateLimiter(targetFps: -5).targetFps == 1)
    }
}

/// Reconnect: a guest whose socket drops keeps their slot for a grace period and resumes on return.
///
/// Before this, a dropped socket removed the participant immediately - so a Wi-Fi roam cost the
/// guest their approval and their player slot, and the guest page had no retry at all.
@Suite struct RemoteCoOpReconnectTests {
    private func approvedHost() async throws -> (OPNRemoteCoOpHostSession, OPNRemoteCoOpInvite, UUID) {
        let signer = OPNRemoteCoOpInviteTokenSigner(secret: Data(repeating: 3, count: 32))
        let preferences = OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 2)
        let host = OPNRemoteCoOpHostSession(preferences: preferences, inviteSigner: signer)
        let invite = try await host.startInvite(lifetimeSeconds: 3_600)
        let participantID = UUID()
        _ = try await host.registerGuest(displayName: "Guest", inviteToken: invite.token, participantID: participantID)
        _ = try await host.approveParticipant(participantID)
        return (host, invite, participantID)
    }

    /// The slot stays reserved, so a second guest cannot take it while the first is reconnecting.
    @Test func aDroppedGuestKeepsItsSlotDuringTheGracePeriod() async throws {
        let (host, _, participantID) = try await approvedHost()
        _ = await host.noteGuestDisconnected(participantID)

        let snapshot = await host.snapshot()
        let participant = try #require(snapshot.participants.first { $0.id == participantID })
        #expect(participant.connectionState == .disconnected)
        #expect(participant.playerIndex == 1)
        // Input is off while they are away, but the slot is theirs.
        #expect(!participant.inputEnabled)
    }

    /// Whatever the guest was holding when the connection dropped must be released immediately,
    /// even though the slot is held - otherwise a button stays pressed for the whole grace period.
    @Test func droppingAGuestReleasesTheirHeldButtons() async throws {
        let (host, _, participantID) = try await approvedHost()
        let events = await host.noteGuestDisconnected(participantID)

        #expect(events.count == 1)
        guard case .gamepad(let state) = events.first else {
            Issue.record("expected a neutral gamepad state")
            return
        }
        #expect(state.playerIndex == 1)
        #expect(state.buttons.isEmpty)
        #expect(state.leftTrigger == 0)
        #expect(state.leftStickX == 0)
    }

    /// Rejoining with the same participant ID resumes play. The guest page reuses its ID across a
    /// reconnect precisely so approval does not have to be granted again.
    @Test func aReturningGuestResumesWithoutReapproval() async throws {
        let (host, invite, participantID) = try await approvedHost()
        _ = await host.noteGuestDisconnected(participantID)

        let restored = try await host.registerGuest(displayName: "Guest", inviteToken: invite.token, participantID: participantID)
        #expect(restored.connectionState == .connected)
        #expect(restored.inputEnabled)
        #expect(restored.playerIndex == 1)
    }

    /// A guest who dropped before ever being approved comes back still waiting, not silently
    /// promoted into a slot they were never given.
    @Test func anUnapprovedGuestReturnsStillWaiting() async throws {
        let signer = OPNRemoteCoOpInviteTokenSigner(secret: Data(repeating: 4, count: 32))
        let host = OPNRemoteCoOpHostSession(
            preferences: OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 1),
            inviteSigner: signer
        )
        let invite = try await host.startInvite(lifetimeSeconds: 3_600)
        let participantID = UUID()
        _ = try await host.registerGuest(displayName: "Guest", inviteToken: invite.token, participantID: participantID)
        _ = await host.noteGuestDisconnected(participantID)

        let restored = try await host.registerGuest(displayName: "Guest", inviteToken: invite.token, participantID: participantID)
        #expect(restored.connectionState == .waitingForApproval)
        #expect(!restored.inputEnabled)
        #expect(restored.playerIndex == nil)
    }

    /// Once the grace period lapses the slot is released, so a guest who actually left does not hold
    /// a player slot for the rest of the session.
    @Test func aSlotIsReleasedOnceTheGracePeriodLapses() async throws {
        let (host, _, participantID) = try await approvedHost()
        let disconnectedAt = Date()
        _ = await host.noteGuestDisconnected(participantID, now: disconnectedAt)

        let stillInGrace = await host.expireDisconnectedParticipants(now: disconnectedAt.addingTimeInterval(OPNRemoteCoOpHostSession.disconnectGraceSeconds - 1))
        #expect(stillInGrace.isEmpty)

        let expired = await host.expireDisconnectedParticipants(now: disconnectedAt.addingTimeInterval(OPNRemoteCoOpHostSession.disconnectGraceSeconds + 1))
        #expect(expired.map(\.id) == [participantID])
        #expect(await host.snapshot().participants.isEmpty)
    }

    /// A connected guest is never swept, however long the session runs.
    @Test func aConnectedGuestIsNeverExpired() async throws {
        let (host, _, participantID) = try await approvedHost()
        let expired = await host.expireDisconnectedParticipants(now: Date().addingTimeInterval(86_400))
        #expect(expired.isEmpty)
        #expect(await host.snapshot().participants.first?.id == participantID)
    }

    /// The reserved-slot limit still counts a guest who is away, so their slot cannot be double
    /// booked while they are reconnecting.
    @Test func aHeldSlotStillCountsAgainstTheReservedLimit() async throws {
        let signer = OPNRemoteCoOpInviteTokenSigner(secret: Data(repeating: 5, count: 32))
        let host = OPNRemoteCoOpHostSession(
            preferences: OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 1),
            inviteSigner: signer
        )
        let invite = try await host.startInvite(lifetimeSeconds: 3_600)
        let first = UUID()
        _ = try await host.registerGuest(displayName: "First", inviteToken: invite.token, participantID: first)
        _ = try await host.approveParticipant(first)
        _ = await host.noteGuestDisconnected(first)

        await #expect(throws: OPNRemoteCoOpHostSessionError.noAvailablePlayerSlots) {
            _ = try await host.registerGuest(displayName: "Second", inviteToken: invite.token, participantID: UUID())
        }
    }
}

/// The capture timestamp the relay puts on a native NVST frame.
///
/// libwebrtc's receiver infers network jitter by comparing capture timestamps against arrival times,
/// so this value has to describe when the seat captured the frame, not when it reached the relay.
/// Stamping with the wall clock folded every hop in between into the capture clock and the receiver
/// grew its jitter buffer to absorb it - 287 ms on a 4 ms LAN route.
@Suite struct RemoteCoOpRelayTimestampTests {
    private func pixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &buffer)
        #expect(status == kCVReturnSuccess)
        return try #require(buffer)
    }

    private final class CapturingBufferSink: OPNRemoteCoOpHostVideoSink, @unchecked Sendable {
        let participantID = UUID()
        private let lock = NSLock()
        private var buffers: [any RTCVideoFrameBuffer] = []

        func renderVideoFrame(_ frame: RTCVideoFrame) {
            lock.lock()
            defer { lock.unlock() }
            buffers.append(frame.buffer)
        }

        var capturedBuffers: [any RTCVideoFrameBuffer] {
            lock.lock()
            defer { lock.unlock() }
            return buffers
        }
    }

    private final class CapturingSink: OPNRemoteCoOpHostVideoSink, @unchecked Sendable {
        let participantID = UUID()
        private let lock = NSLock()
        private var stamps: [Int64] = []

        func renderVideoFrame(_ frame: RTCVideoFrame) {
            lock.lock()
            defer { lock.unlock() }
            stamps.append(frame.timeStampNs)
        }

        var captured: [Int64] {
            lock.lock()
            defer { lock.unlock() }
            return stamps
        }
    }

    /// The seat's RTP-derived presentation time reaches the guest unchanged, in nanoseconds.
    @Test func theDecodersPresentationTimeIsCarriedThrough() throws {
        let relay = OPNRemoteCoOpHostVideoRelay()
        let sink = CapturingSink()
        relay.upsert(sink)

        // What NvstVideoToolboxDecoder produces: an RTP timestamp at the 90 kHz video clock rate.
        let rtpTimestamp: Int64 = 3_600_000
        let presentation = CMTime(value: CMTimeValue(rtpTimestamp), timescale: 90_000)
        relay.renderPixelBuffer(try pixelBuffer(), presentationTime: presentation)

        let stamp = try #require(sink.captured.first)
        // 3_600_000 / 90_000 = 40 seconds into the session.
        #expect(stamp == 40_000_000_000)
    }

    /// A regularly paced source must produce regularly paced stamps, because that regularity is what
    /// keeps the receiver's jitter estimate - and the rate limiter's decimation - honest.
    @Test func aSteadySourceProducesEvenlySpacedStamps() throws {
        let relay = OPNRemoteCoOpHostVideoRelay()
        let sink = CapturingSink()
        relay.upsert(sink)

        // 60 fps at the 90 kHz clock is 1500 ticks per frame.
        for frame in 1...5 {
            let presentation = CMTime(value: CMTimeValue(frame * 1_500), timescale: 90_000)
            relay.renderPixelBuffer(try pixelBuffer(), presentationTime: presentation)
        }

        let stamps = sink.captured
        #expect(stamps.count == 5)
        let deltas = zip(stamps.dropFirst(), stamps).map { $0 - $1 }
        // One frame interval apart, with no contribution from when each call happened to run. The
        // tolerance is for the 90 kHz-to-nanosecond conversion rounding, which makes consecutive
        // deltas alternate by a single nanosecond - irrelevant next to the milliseconds of scheduling
        // jitter this change exists to keep out of the timestamps.
        #expect(deltas.allSatisfy { abs($0 - 16_666_666) <= 1 })
    }

    /// The relay hands over the decoder's own `CVPixelBuffer`, not a converted copy.
    ///
    /// That buffer type is what libwebrtc's macOS H264 encoder consumes natively, and it carries the
    /// adapted size so scaling still happens inside the encoder's pass. Converting to I420 in the
    /// relay first burned a full frame conversion per guest on a serial queue and forced the encoder
    /// to convert back.
    @Test func theDecodersPixelBufferIsHandedOverWithoutConversion() throws {
        let relay = OPNRemoteCoOpHostVideoRelay()
        relay.setPreferredOutputSize(width: 1280, height: 720)
        let sink = CapturingBufferSink()
        relay.upsert(sink)

        // A source larger than the preset, so the adaptation is actually exercised.
        var source: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 1_920, 1_080, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &source) == kCVReturnSuccess)
        relay.renderPixelBuffer(try #require(source), presentationTime: CMTime(value: 1_500, timescale: 90_000))

        let buffer = try #require(sink.capturedBuffers.first)
        // Still the decoder's own buffer type, not an I420 copy made by the relay.
        let pixelBuffer = try #require(buffer as? RTCCVPixelBuffer)
        // The adapted size rides on the buffer, so the encoder scales in its own pass...
        #expect(pixelBuffer.width == 1_280)
        #expect(pixelBuffer.height == 720)
        // ...while the underlying pixels are untouched at source resolution.
        #expect(CVPixelBufferGetWidth(pixelBuffer.pixelBuffer) == 1_920)
        #expect(CVPixelBufferGetHeight(pixelBuffer.pixelBuffer) == 1_080)
    }

    /// An invalid presentation time must not stamp a frame with garbage. The session's first frames
    /// and an RTP wrap are both handled downstream by the rate limiter's monotonic guard.
    @Test func anInvalidPresentationTimeFallsBackToTheArrivalClock() throws {
        let relay = OPNRemoteCoOpHostVideoRelay()
        let sink = CapturingSink()
        relay.upsert(sink)

        relay.renderPixelBuffer(try pixelBuffer(), presentationTime: .invalid)
        let stamp = try #require(sink.captured.first)
        #expect(stamp > 0)
    }
}
