//  The pieces added for the low-latency guest path: the binary input frame, the Opus SDP tuning, and
//  the typed-in host address that Bonjour cannot discover.
//

import Foundation
import Network
import Testing
@testable import OpenNOW

@Suite("Remote Co-Op latency tuning")
struct RemoteCoOpLatencyTuningTests {
    // MARK: - Binary input frame

    @Test("binary input frame round-trips every field")
    func binaryFrameRoundTrip() throws {
        let packet = OPNRemoteCoOpInputPacket(
            participantID: UUID(),
            sequenceNumber: 9_876_543_210,
            buttons: GamepadButtons(rawValue: 0xDEAD_BEEF),
            leftTrigger: 0.25,
            rightTrigger: 1,
            leftStickX: -1,
            leftStickY: 0.5,
            rightStickX: 0.125,
            rightStickY: -0.75,
            sentAtNanoseconds: 1_234_567_890_123
        )
        let frame = OPNRemoteCoOpInputBinaryCodec.encode(packet)
        #expect(frame.count == OPNRemoteCoOpInputBinaryCodec.frameByteCount)
        let decoded = try #require(OPNRemoteCoOpInputBinaryCodec.decode(frame))
        #expect(decoded == packet)
    }

    @Test("binary frame is never mistaken for JSON, and JSON is never mistaken for a frame")
    func binaryFrameDiscrimination() throws {
        let packet = OPNRemoteCoOpInputPacket(participantID: UUID(), sequenceNumber: 1)
        let json = try OPNRemoteCoOpWireCodec.encode(OPNRemoteCoOpWireMessage(kind: .guestInput, input: packet))
        #expect(OPNRemoteCoOpInputBinaryCodec.decode(Data(json.utf8)) == nil)
        #expect(!OPNRemoteCoOpInputBinaryCodec.looksLikeBinaryFrame(Data(json.utf8)))
        #expect(OPNRemoteCoOpInputBinaryCodec.looksLikeBinaryFrame(OPNRemoteCoOpInputBinaryCodec.encode(packet)))
        // A truncated frame must be rejected rather than decoded from whatever bytes arrived.
        #expect(OPNRemoteCoOpInputBinaryCodec.decode(OPNRemoteCoOpInputBinaryCodec.encode(packet).dropLast()) == nil)
    }

    /// `Data` from libwebrtc can be a slice of a larger receive buffer, where index 0 is not the first
    /// byte. Every offset in the decoder would be wrong by the slice's start if it subscripted the
    /// slice directly, and the values it produced would be plausible garbage rather than an error.
    @Test("a frame decodes correctly out of a slice whose indices do not start at zero")
    func binaryFrameDecodesFromSlice() throws {
        let packet = OPNRemoteCoOpInputPacket(
            participantID: UUID(),
            sequenceNumber: 42,
            buttons: GamepadButtons(rawValue: 0x1234),
            leftStickX: -0.5,
            rightStickY: 0.25
        )
        var padded = Data(repeating: 0xFF, count: 7)
        padded.append(OPNRemoteCoOpInputBinaryCodec.encode(packet))
        let slice = padded.dropFirst(7)
        #expect(slice.startIndex == 7)
        let decoded = try #require(OPNRemoteCoOpInputBinaryCodec.decode(slice))
        #expect(decoded == packet)
    }

    @Test("the host input decoder accepts both encodings from the same channel")
    func hostDecoderAcceptsBothEncodings() throws {
        let participantID = UUID()
        let packet = OPNRemoteCoOpInputPacket(participantID: participantID, sequenceNumber: 7, buttons: GamepadButtons(rawValue: 3), leftStickX: 0.5)

        let binary = OPNRemoteCoOpHostPeerInputDecoder.decodePackets(OPNRemoteCoOpInputBinaryCodec.encode(packet), expectedParticipantID: participantID)
        #expect(binary == [packet])

        let json = try OPNRemoteCoOpWireCodec.encode(OPNRemoteCoOpWireMessage(kind: .guestInput, participantID: participantID, input: packet))
        let decodedJSON = OPNRemoteCoOpHostPeerInputDecoder.decodePackets(json, expectedParticipantID: participantID)
        #expect(decodedJSON.map(\.sequenceNumber) == [7])
    }

    @Test("a binary frame from another participant is dropped")
    func hostDecoderRejectsForeignBinaryFrame() {
        let packet = OPNRemoteCoOpInputPacket(participantID: UUID(), sequenceNumber: 1)
        let decoded = OPNRemoteCoOpHostPeerInputDecoder.decodePackets(OPNRemoteCoOpInputBinaryCodec.encode(packet), expectedParticipantID: UUID())
        #expect(decoded.isEmpty)
    }

    // MARK: - SDP tuning

    @Test("Opus fmtp is replaced and ptime is set")
    func sdpTuningReplacesExistingFmtp() {
        let sdp = [
            "v=0",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111",
            "a=rtpmap:111 opus/48000/2",
            "a=fmtp:111 minptime=10;useinbandfec=1",
            "a=ptime:20",
            "m=video 9 UDP/TLS/RTP/SAVPF 96",
            "a=rtpmap:96 H264/90000"
        ].joined(separator: "\r\n")
        let tuned = OPNRemoteCoOpSDPTuning.tunedForGameStreaming(sdp)
        #expect(tuned.contains("a=fmtp:111 \(OPNRemoteCoOpSDPTuning.opusParameters)"))
        #expect(tuned.contains("a=ptime:10"))
        #expect(!tuned.contains("a=ptime:20"))
        // Exactly one of each: a duplicated attribute in one media section is malformed.
        #expect(tuned.components(separatedBy: "a=fmtp:111").count == 2)
        #expect(tuned.components(separatedBy: "a=ptime:").count == 2)
        #expect(tuned.contains("a=rtpmap:96 H264/90000"))
        #expect(tuned.contains("\r\n"))
    }

    @Test("Opus fmtp is inserted when the offer omitted it")
    func sdpTuningInsertsMissingFmtp() {
        let sdp = ["m=audio 9 UDP/TLS/RTP/SAVPF 63 111", "a=rtpmap:111 opus/48000/2", "a=rtcp-fb:111 transport-cc"].joined(separator: "\r\n")
        let tuned = OPNRemoteCoOpSDPTuning.tunedForGameStreaming(sdp)
        #expect(tuned.contains("a=fmtp:111 stereo=1;sprop-stereo=1") || tuned.contains("stereo=1"))
        #expect(tuned.contains("a=ptime:10"))
        #expect(tuned.contains("a=rtcp-fb:111 transport-cc"))
    }

    @Test("a description with no Opus line passes through untouched")
    func sdpTuningPassesThroughWithoutOpus() {
        let sdp = "v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\na=rtpmap:96 H264/90000"
        #expect(OPNRemoteCoOpSDPTuning.tunedForGameStreaming(sdp) == sdp)
    }

    @Test("a video ptime line in another section is left alone")
    func sdpTuningLeavesOtherSectionsAlone() {
        let sdp = [
            "m=video 9 UDP/TLS/RTP/SAVPF 96",
            "a=rtpmap:96 H264/90000",
            "a=ptime:33",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111",
            "a=rtpmap:111 opus/48000/2"
        ].joined(separator: "\r\n")
        let tuned = OPNRemoteCoOpSDPTuning.tunedForGameStreaming(sdp)
        #expect(tuned.contains("a=ptime:33"))
        #expect(tuned.contains("a=ptime:10"))
    }

    // MARK: - Manual host address

    @Test("host addresses parse in every accepted form")
    func manualAddressParsing() throws {
        let defaultPort = OPNRemoteCoOpNativeGuestServer.defaultPort
        let cases: [(String, String, UInt16)] = [
            ("100.101.102.103", "100.101.102.103", defaultPort),
            ("100.101.102.103:41000", "100.101.102.103", 41_000),
            ("my-mac.tail1234.ts.net", "my-mac.tail1234.ts.net", defaultPort),
            ("[fd7a:115c::1]", "fd7a:115c::1", defaultPort),
            ("[fd7a:115c::1]:41000", "fd7a:115c::1", 41_000),
            // Unbracketed IPv6 cannot carry a port, so it is taken whole.
            ("fd7a:115c::1", "fd7a:115c::1", defaultPort)
        ]
        for (input, expectedHost, expectedPort) in cases {
            let parsed = try #require(OPNRemoteCoOpNativeDiscoveredHost.parseHostAndPort(input), "\(input) should parse")
            #expect(parsed.host == expectedHost, "\(input) host")
            #expect(parsed.port == expectedPort, "\(input) port")
        }
    }

    @Test("a manual host becomes a connectable endpoint")
    func manualAddressBuildsEndpoint() throws {
        let host = try #require(OPNRemoteCoOpNativeDiscoveredHost(address: " 100.101.102.103:41000 "))
        guard case .hostPort(let endpointHost, let port) = host.endpoint else {
            Issue.record("expected a hostPort endpoint, got \(host.endpoint)")
            return
        }
        #expect(port.rawValue == 41_000)
        #expect("\(endpointHost)".contains("100.101.102.103"))
        // The default port is implied rather than shown, so the label stays readable.
        let defaultPortHost = try #require(OPNRemoteCoOpNativeDiscoveredHost(address: "my-mac"))
        #expect(defaultPortHost.name == "my-mac")
    }

    @Test("addresses that cannot be connected to are refused")
    func manualAddressRejectsGarbage() {
        #expect(OPNRemoteCoOpNativeDiscoveredHost(address: "") == nil)
        #expect(OPNRemoteCoOpNativeDiscoveredHost(address: "   ") == nil)
        #expect(OPNRemoteCoOpNativeDiscoveredHost(address: "host:0") == nil)
        #expect(OPNRemoteCoOpNativeDiscoveredHost(address: "host:notaport") == nil)
        #expect(OPNRemoteCoOpNativeDiscoveredHost(address: ":41000") == nil)
        #expect(OPNRemoteCoOpNativeDiscoveredHost(address: "[fd7a::1") == nil)
    }

    // MARK: - Guest input loss redundancy

    /// One entry per call, so a whole tick sequence can be asserted as a shape rather than as a run of
    /// individual expectations. `#expect` cannot call a mutating member inline.
    private func redundancyDecisions(_ calls: [(changed: Bool, fromTimer: Bool, atNanoseconds: UInt64)]) -> [Bool] {
        var policy = OPNRemoteCoOpGuestInputRedundancyPolicy()
        return calls.map { policy.shouldSend(isChanged: $0.changed, allowRedundantSend: $0.fromTimer, nowNanoseconds: $0.atNanoseconds) }
    }

    @Test("a change sends immediately, then repeats twice on following ticks, then goes quiet")
    func redundancyRepeatsAfterChange() {
        let decisions = redundancyDecisions([
            (true, false, 0),
            // The two ticks after the change resend the same state, so one lost packet cannot stick.
            (false, true, 5_000_000),
            (false, true, 10_000_000),
            // Then quiet, until the keepalive is due.
            (false, true, 15_000_000),
            (false, true, 20_000_000)
        ])
        #expect(decisions == [true, true, true, false, false])
    }

    @Test("the HID callback never resends, only the safety timer does")
    func redundancyIsTimerOnly() {
        // A pad reporting at 1000 Hz with a still stick would otherwise triple its own packet rate.
        var calls: [(changed: Bool, fromTimer: Bool, atNanoseconds: UInt64)] = [(true, false, 0)]
        for tick in 1...5 { calls.append((false, false, UInt64(tick) * 1_000_000)) }
        #expect(redundancyDecisions(calls) == [true, false, false, false, false, false])
    }

    @Test("an unchanging state repeats on the keepalive interval and no faster")
    func redundancyKeepalive() {
        let keepalive = OPNRemoteCoOpGuestInputRedundancyPolicy.keepaliveNanoseconds
        let decisions = redundancyDecisions([
            (true, false, 0),
            // Burn the post-change burst.
            (false, true, 5_000_000),
            (false, true, 10_000_000),
            (false, true, 10_000_000 + keepalive - 1),
            (false, true, 10_000_000 + keepalive),
            // The clock restarts from the keepalive, not from the original change.
            (false, true, 10_000_000 + keepalive + 1)
        ])
        #expect(decisions == [true, true, true, false, true, false])
    }

    @Test("a change during a burst restarts it rather than sending the superseded state")
    func redundancyChangeRestartsBurst() {
        let decisions = redundancyDecisions([
            (true, false, 0),
            (false, true, 5_000_000),
            // New state arrives with one repeat of the old one still owed. That repeat must not go out
            // - it describes a state the guest has already left - and the new state gets a full burst.
            (true, false, 6_000_000),
            (false, true, 11_000_000),
            (false, true, 16_000_000),
            (false, true, 21_000_000)
        ])
        #expect(decisions == [true, true, true, true, true, false])
    }

    @Test("a clock reading that goes backwards does not fire a keepalive every tick")
    func redundancyToleratesBackwardsClock() {
        let decisions = redundancyDecisions([
            (true, false, 1_000_000_000),
            (false, true, 1_005_000_000),
            (false, true, 1_010_000_000),
            // Unsigned subtraction on a stale reading would underflow to an enormous elapsed time and
            // report the keepalive as due on every tick.
            (false, true, 900_000_000),
            (false, true, 800_000_000)
        ])
        #expect(decisions == [true, true, true, false, false])
    }

    // MARK: - Tailnet address detection

    @Test("the CGNAT range Tailscale allocates from is recognised, and neighbouring ranges are not")
    func carrierGradeNATRange() {
        for address in ["100.64.0.1", "100.127.255.254", "100.101.102.103", "100.90.1.1"] {
            #expect(OPNRemoteCoOpLocalAddress.isCarrierGradeNAT(address), "\(address) is in 100.64.0.0/10")
        }
        for address in ["100.63.255.255", "100.128.0.1", "192.168.1.10", "10.0.0.1", "100.64", "", "100.abc.1.1"] {
            #expect(!OPNRemoteCoOpLocalAddress.isCarrierGradeNAT(address), "\(address) is not in 100.64.0.0/10")
        }
    }

    // MARK: - Quality presets

    @Test("every preset is internally consistent")
    func qualityPresetsAreConsistent() {
        for preset in OPNRemoteCoOpQualityPreset.allCases {
            #expect(preset.width > 0 && preset.height > 0 && preset.fps > 0, "\(preset) geometry")
            #expect(preset.width.isMultiple(of: 2) && preset.height.isMultiple(of: 2), "\(preset) must be I420-safe")
            // Low latency trades bitrate for responsiveness, never the other way around.
            #expect(preset.videoMaxBitrateBps(for: .lowLatency) <= preset.videoMaxBitrateBps(for: .quality), "\(preset) low-latency cap")
            for mode in OPNRemoteCoOpLatencyMode.allCases {
                let floor = preset.videoMinBitrateBps(for: mode) ?? 0
                #expect(floor > 0, "\(preset) \(mode) needs a floor so the estimator does not ramp")
                #expect(floor <= preset.videoMaxBitrateBps(for: mode), "\(preset) \(mode) floor above cap")
            }
        }
    }

    /// `allCases` order is what the Settings picker indexes into, and a stored preference is a raw
    /// string rather than an index - so reordering is safe for preferences but visible to users.
    /// Resolution first, frame rate second: 1080p120 is a heavier stream than 1440p60 but belongs
    /// next to 1080p60 in a list someone is reading.
    @Test("presets are listed by resolution, then frame rate")
    func qualityPresetsAreOrdered() {
        let order = OPNRemoteCoOpQualityPreset.allCases.map { $0.height * 1_000 + $0.fps }
        #expect(order == order.sorted())
        #expect(OPNRemoteCoOpQualityPreset.allCases.first == .p720f30)
        #expect(OPNRemoteCoOpQualityPreset.allCases.last == .p2160f60)
    }
}
