import Foundation
import Testing
@testable import OpenNOW

/// NVST has no WebRTC signaling, so the seat's half of the bundle is synthesized from RTSP answers.
/// These tests pin that synthesis and the SDP surgery around it — the parts that decide whether the
/// seat ever arms its video relay.
@Suite struct NvstWebRtcBundleTests {
    @Test func theSynthesizedOfferCarriesTheSeatsRtspIdentity() {
        let offer = NvstWebRtcBundle.synthesizedRemoteOffer(
            remoteUsernameFragment: "58d3b48a47999",
            remotePassword: "seatPassword",
            remoteFingerprint: "AA:BB:CC",
            peerIP: "10.20.30.40",
            peerPort: 5004
        )
        let lines = offer.components(separatedBy: "\r\n")
        // An SCTP media section is required or the answer has nowhere to put data channels.
        #expect(lines.contains("m=application 9 UDP/DTLS/SCTP webrtc-datachannel"))
        #expect(lines.contains("a=sctp-port:5000"))
        // An audio section is equally required: ANNOUNCE tells the seat audio rides this bundle,
        // and a data-channel-only bundle made a live seat reset every SCTP stream and close DTLS
        // 114 ms after PLAY.
        // Payload type 63: what the seat actually sends bundle audio with, captured from the
        // native stack's bundle socket.
        // Audio is RED (pt 63) wrapping Opus (pt 111) by default — 63 is the wire type the seat
        // sends and WebRTC's own RED type; declaring the Opus payload as plain 63 mis-framed it.
        #expect(lines.contains("m=audio 9 UDP/TLS/RTP/SAVPF 63 111"))
        #expect(lines.contains("a=rtpmap:63 red/48000/2"))
        #expect(lines.contains("a=fmtp:63 111/111"))
        #expect(lines.contains("a=rtpmap:111 opus/48000/2"))
        // Offered sendonly by the seat, so our answer becomes recvonly.
        #expect(lines.contains("a=sendonly"))
        #expect(lines.contains("a=rtcp-mux"))
        // Both sections share one transport, so both mids are in the BUNDLE group.
        #expect(lines.contains("a=group:BUNDLE 0 1"))
        #expect(lines.contains("a=mid:0"))
        #expect(lines.contains("a=mid:1"))
        // The ICE and DTLS identity repeats per section, as a real offer does.
        #expect(lines.filter { $0 == "a=ice-ufrag:58d3b48a47999" }.count == 2)
        #expect(lines.filter { $0 == "a=fingerprint:sha-256 AA:BB:CC" }.count == 2)
        // The bundle authenticates with ping+1, which is what SETUP's payload resolves to.
        #expect(lines.contains("a=ice-ufrag:58d3b48a47999"))
        #expect(lines.contains("a=ice-pwd:seatPassword"))
        #expect(lines.contains("a=fingerprint:sha-256 AA:BB:CC"))
        // actpass on the remote side leaves us free to answer `active` and send the ClientHello,
        // which is the role the official client takes.
        #expect(lines.contains("a=setup:actpass"))
        // The peer address comes from SETUP's Transport header; there is no candidate exchange.
        #expect(lines.contains("a=candidate:1 1 udp 2122260223 10.20.30.40 5004 typ host"))

    }

    @Test func iceCredentialsAreForcedToTheOfficialLengths() {
        // libwebrtc offers no API for this and generates a 16-character ufrag, which Bifrost's
        // length checks are documented to reject.
        let answer = [
            "v=0",
            "m=application 9 UDP/DTLS/SCTP webrtc-datachannel",
            "a=ice-ufrag:qP0zVeryLongUfrag",
            "a=ice-pwd:aVeryLongGeneratedPasswordValue",
            "a=fingerprint:sha-256 11:22:33",
            "a=setup:active",
        ].joined(separator: "\r\n")
        let forced = NvstWebRtcBundle.replacingIceCredentials(in: answer, usernameFragment: "OyEL", password: String(repeating: "p", count: 22))
        let lines = forced.components(separatedBy: "\r\n")
        #expect(lines.contains("a=ice-ufrag:OyEL"))
        #expect(lines.contains("a=ice-pwd:\(String(repeating: "p", count: 22))"))
        // Nothing else may be touched: libwebrtc rejects a munged answer that changes more.
        #expect(lines.contains("a=fingerprint:sha-256 11:22:33"))
        #expect(lines.contains("a=setup:active"))
        #expect(lines.contains("m=application 9 UDP/DTLS/SCTP webrtc-datachannel"))
    }

    @Test func theAnswersFingerprintAndRoleAreReadBackForAnnounce() {
        let answer = "v=0\r\na=fingerprint:sha-256 AA:BB:CC:DD\r\na=setup:active\r\n"
        #expect(NvstWebRtcBundle.fingerprint(inSdp: answer) == "AA:BB:CC:DD")
        // `active` is what makes libwebrtc send the ClientHello, matching the captured client.
        #expect(NvstWebRtcBundle.setupRole(inSdp: answer) == "active")
        #expect(NvstWebRtcBundle.fingerprint(inSdp: "v=0\r\n") == nil)
        #expect(NvstWebRtcBundle.setupRole(inSdp: "v=0\r\n") == nil)
    }

    @Test func theHostCandidateSuppliesTheAnnouncedBundlePort() {
        let candidate = "candidate:842163049 1 udp 1677729535 192.168.1.20 51628 typ host generation 0"
        let host = NvstWebRtcBundle.hostAddress(fromCandidateLine: candidate)
        #expect(host?.address == "192.168.1.20")
        #expect(host?.port == 51_628)
        // The `a=` prefixed form appears in SDP rather than in a trickled candidate.
        #expect(NvstWebRtcBundle.hostAddress(fromCandidateLine: "a=" + candidate)?.port == 51_628)
        #expect(NvstWebRtcBundle.hostAddress(fromCandidateLine: "candidate:1 1 udp 100") == nil)
    }

    @Test func theAnnouncedCandidateIsTheOneOnTheRoutedInterface() {
        // Live failure this guards: libwebrtc gathered on four Docker/VM bridges plus en0, the
        // first candidate to arrive was bridge100's, and announcing its port armed the seat's media
        // relay on a socket that never received anything — the association then failed.
        let hosts: [(address: String, port: UInt16)] = [
            ("192.168.138.20", 55_029),
            ("172.40.0.5", 57_469),
            ("192.168.1.20", 49_812),
        ]
        let chosen = NvstWebRtcBundle.preferredHost(among: hosts, matching: "192.168.1.20")
        #expect(chosen?.address == "192.168.1.20")
        #expect(chosen?.port == 49_812)
        // With no routed address known, the first candidate is still better than failing.
        #expect(NvstWebRtcBundle.preferredHost(among: hosts, matching: nil)?.port == 55_029)
        // A routed address that gathered no candidate falls back rather than throwing.
        #expect(NvstWebRtcBundle.preferredHost(among: hosts, matching: "10.9.9.9")?.port == 55_029)
        #expect(NvstWebRtcBundle.preferredHost(among: [], matching: "192.168.1.20") == nil)
    }

    @Test func theOfficialChannelSetMapsLabelsOntoTheStreamIdsTheSeatReserves() {
        // Captured from libBifrost2's own log: the seat assigns each label a fixed stream id and
        // validates it. As DTLS client we are handed the even ids in creation order, so the order
        // of this list *is* the id mapping — index 0 lands on sid 0, index 7 on sid 14.
        //
        // This list read six labels until 2026-08-26, and asserted that the feedback channel was
        // the seat's to open, because adding it made the seat reset every stream and close DTLS.
        // That reading was wrong: appended to six channels it landed on sid 12, which is the cursor
        // channel's id, under the wrong label. OpenNOW's native streamer profiles eight channels
        // with cursor on 12 and RTCP on 14, and creating both in order opens them cleanly — a live
        // session reports `channels=8 feedbackOpen=true reportsSent=280`, where every session
        // before it reported `feedbackOpen=false reportsSent=0`.
        let expected = [
            "control_channel_reliable",
            "custom_message_on_sctp_private_reliable",
            "custom_message_on_sctp_private_partially_reliable",
            "control_channel_partially_reliable",
            "control_channel_unreliable",
            "input_channel_partially_reliable",
            "cursor_channel",
            "rtcp_on_sctp_private",
        ]
        #expect(NvstWebRtcBundle.officialChannels.map(\.label) == expected)
        // The feedback channel is last, so it lands on sid 14 where the seat expects it. Without it
        // our receiver reports have nowhere to go and the seat's congestion control cannot see the
        // loss we are reporting.
        #expect(NvstWebRtcBundle.officialChannels.last?.label == NvstWebRtcBundle.feedbackChannelLabel)
        #expect(NvstWebRtcBundle.officialChannels.firstIndex { $0.label == "cursor_channel" } == 6)
        #expect(NvstWebRtcBundle.feedbackChannelLabel == "rtcp_on_sctp_private")

        // Reliability matches the captured config: 300 ms lifetime for the partially-reliable
        // channels, zero retransmits for the unreliable one, fully reliable otherwise.
        let byLabel = Dictionary(uniqueKeysWithValues: NvstWebRtcBundle.officialChannels.map { ($0.label, $0) })
        #expect(byLabel["control_channel_partially_reliable"]?.maxPacketLifeTimeMilliseconds == 300)
        #expect(byLabel["input_channel_partially_reliable"]?.maxPacketLifeTimeMilliseconds == 300)
        #expect(byLabel["custom_message_on_sctp_private_partially_reliable"]?.maxPacketLifeTimeMilliseconds == 300)
        #expect(byLabel["control_channel_unreliable"]?.isUnreliable == true)
        #expect(byLabel["control_channel_reliable"]?.maxPacketLifeTimeMilliseconds == nil)
        #expect(byLabel["rtcp_on_sctp_private"]?.maxPacketLifeTimeMilliseconds == nil)
        #expect(byLabel["rtcp_on_sctp_private"]?.isUnreliable == false)
    }

    @Test func theBundleRefusesToStartWithoutTheSeatsIdentity() async {
        func handoff(fingerprint: String?, credentials: Bool) -> NVSTVideoHandoff {
            NVSTVideoHandoff(
                clientUDPPort: 0, videoPeerIP: "10.20.30.40", videoPeerPort: 5004,
                srtpProfile: .aeadAes256Gcm8,
                srtpAESKey: Data(repeating: 0xab, count: 32), srtpSalt: Data(repeating: 0x9e, count: 12),
                codec: .h264, rtpPayloadType: 96, rtpSSRC: 0,
                reorderWindowPackets: 32, maxAccessUnitBytes: 1024, timeoutMilliseconds: 5000,
                pingVersion: 6, pingPayload: "58d3b48a47998", mjolnirUDPPort: 0,
                iceCredentials: credentials
                    ? NVSTHandoffIceCredentials(
                        localUsernameFragment: "OyEL", localPassword: String(repeating: "p", count: 22),
                        remoteUsernameFragment: "58d3b48a47999", remotePassword: "seatPassword",
                        remoteDTLSFingerprint: fingerprint)
                    : nil
            )
        }
        await #expect(throws: NvstWebRtcBundle.BundleError.missingRemoteCredentials) {
            _ = try await NvstWebRtcBundle(handoff: handoff(fingerprint: "AA", credentials: false), preferredLocalAddress: nil).prepare()
        }
        await #expect(throws: NvstWebRtcBundle.BundleError.missingRemoteFingerprint) {
            _ = try await NvstWebRtcBundle(handoff: handoff(fingerprint: nil, credentials: true), preferredLocalAddress: nil).prepare()
        }
    }
}
