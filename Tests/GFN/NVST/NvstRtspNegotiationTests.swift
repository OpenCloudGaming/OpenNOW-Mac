import Foundation
import Testing
@testable import OpenNOW

/// The NVST control plane is classic RTSP tunnelled over a WebSocket on `:322`. These tests pin
/// the wire shapes we cannot re-derive at runtime: the Poco-shaped upgrade, the RTSP framing, the
/// DESCRIBE attribute dialect, the ANNOUNCE allowlist, and the ping-payload identity transforms.
@Suite struct NvstRtspWireFormatTests {
    @Test func upgradeRequestMatchesTheOfficialPocoShape() {
        let request = NvstWebSocketUpgrade.request(host: "seat.example.com", port: 322, secWebSocketKey: "dGhlIHNhbXBsZSBub25jZQ==", sessionID: " abc-123 ")
        let lines = request.components(separatedBy: "\r\n")
        #expect(lines[0] == "GET /rtsp HTTP/1.1")
        #expect(lines.contains("Host: seat.example.com:322"))
        #expect(lines.contains("Connection: Upgrade"))
        #expect(lines.contains("Upgrade: websocket"))
        #expect(lines.contains("Sec-WebSocket-Version: 13"))
        #expect(lines.contains("Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=="))
        // Bifrost presets Content-Length: 0 on the upgrade.
        #expect(lines.contains("Content-Length: 0"))
        #expect(lines.contains("x-nv-sessionid: abc-123"))
        #expect(request.hasSuffix("\r\n\r\n"))
    }

    @Test func upgradeAcceptMatchesTheRfc6455KnownAnswer() {
        // RFC 6455 §1.3 worked example.
        #expect(NvstWebSocketUpgrade.expectedAccept(for: "dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    @Test func upgradeResponseParsingSplitsHeadersAndLeftoverFrameBytes() {
        var buffer = Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: abc\r\n\r\n".utf8)
        buffer.append(contentsOf: [0x81, 0x02, 0x41, 0x42])
        let parsed = NvstWebSocketUpgrade.parseResponse(buffer)
        #expect(parsed?.statusCode == 101)
        #expect(parsed?.headers["sec-websocket-accept"] == "abc")
        #expect(parsed?.leftover == Data([0x81, 0x02, 0x41, 0x42]))
        // Incomplete header blocks must not parse.
        #expect(NvstWebSocketUpgrade.parseResponse(Data("HTTP/1.1 101 Switching".utf8)) == nil)
    }

    @Test func maskedClientFramesRoundTripThroughTheReader() throws {
        var reader = NvstWebSocketFrameReader()
        let short = Data("OPTIONS rtsps://host RTSP/1.0\r\n\r\n".utf8)
        let medium = Data(repeating: 0x41, count: 400)
        let frames = NvstWebSocketFrame.encodeText(short) + NvstWebSocketFrame.encodeText(medium)
        // Split mid-stream to exercise the incremental path.
        let firstHalf = frames.prefix(frames.count / 3)
        let secondHalf = frames.dropFirst(frames.count / 3)
        var messages = try reader.push(Data(firstHalf))
        messages += try reader.push(Data(secondHalf))
        #expect(messages == [short, medium])
    }

    @Test func encodedFrameSetsFinMaskAndExtendedLength() {
        let short = NvstWebSocketFrame.encodeText(Data(repeating: 0x20, count: 5))
        #expect(short[0] == 0x81)
        #expect(short[1] == 0x85)
        let medium = NvstWebSocketFrame.encodeText(Data(repeating: 0x20, count: 300))
        #expect(medium[1] == 0xfe)
        #expect(Int(medium[2]) << 8 | Int(medium[3]) == 300)
    }

    @Test func closeFrameSurfacesAsAnError() {
        var reader = NvstWebSocketFrameReader()
        #expect(throws: NvstWebSocketFrameError.closed) {
            _ = try reader.push(Data([0x88, 0x00]))
        }
    }

    @Test func requestBuilderEmitsCseqRequestIdAndPreservesEmptyHeaders() {
        let message = NvstRtspMessage.buildRequest(
            method: "SETUP",
            uri: "rtsps://host:322/streamid=video/0/0",
            headers: [("Session", "abc"), ("x-nv-ping", "6"), ("Transport", "")],
            cseq: 3
        )
        #expect(message.hasPrefix("SETUP rtsps://host:322/streamid=video/0/0 RTSP/1.0\r\n"))
        #expect(message.contains("CSeq: 3\r\n"))
        #expect(message.contains("Request-Id: 3\r\n"))
        // The official cloud SETUP sends a literally empty Transport header.
        #expect(message.contains("Transport: \r\n"))
        #expect(!message.contains("Content-Length"))
    }

    @Test func requestBuilderAddsContentLengthOnlyForBodies() {
        let message = NvstRtspMessage.buildRequest(method: "ANNOUNCE", uri: "rtsps://host:322", body: "v=0\r\n", cseq: 4)
        #expect(message.contains("Content-Length: 5\r\n"))
        #expect(message.hasSuffix("\r\n\r\nv=0\r\n"))
    }

    @Test func responseParsingHandlesBothLineEndingsAndLowercasesHeaders() throws {
        let response = try NvstRtspMessage.parseResponse("RTSP/1.0 200 OK\r\nSession: 1234;timeout=60\r\nContent-Length: 4\r\n\r\nv=0\n")
        #expect(response.statusCode == 200)
        #expect(response.statusText == "OK")
        #expect(response.header("SESSION") == "1234;timeout=60")
        #expect(response.body == "v=0\n")
    }

    @Test func responseExtractionWaitsForTheFullBody() throws {
        var buffer = Data("RTSP/1.0 200 OK\r\nContent-Length: 8\r\n\r\nv=0".utf8)
        #expect(try NvstRtspMessage.extractResponse(from: &buffer) == nil)
        buffer.append(Data("\r\ns=x".utf8))
        let response = try NvstRtspMessage.extractResponse(from: &buffer)
        #expect(response?.statusCode == 200)
        #expect(buffer.isEmpty)
    }

    @Test func responseExtractionRejectsGarbageStatusLines() {
        var buffer = Data("NOT-RTSP\r\n\r\n".utf8)
        #expect(throws: NvstRtspMessageError.self) {
            _ = try NvstRtspMessage.extractResponse(from: &buffer)
        }
    }

    /// A negative length used to make `headerByteLength + contentLength` go negative, and both
    /// `Data.prefix` and `Data.removeFirst` trap on that — one hostile response crashed the client.
    @Test func responseExtractionRejectsNegativeContentLength() {
        var buffer = Data("RTSP/1.0 200 OK\r\nContent-Length: -100000\r\n\r\nbody".utf8)
        #expect(throws: NvstRtspMessageError.invalidContentLength(-100_000)) {
            _ = try NvstRtspMessage.extractResponse(from: &buffer)
        }
    }

    @Test func responseExtractionRejectsAbsurdContentLength() {
        var buffer = Data("RTSP/1.0 200 OK\r\nContent-Length: 999999999\r\n\r\n".utf8)
        #expect(throws: NvstRtspMessageError.self) {
            _ = try NvstRtspMessage.extractResponse(from: &buffer)
        }
    }

    /// The ANNOUNCE body is logged line by line into sinks that outlive the session (a file in
    /// `~/Library/Logs`, the unified log, Sentry, the uploadable diagnostics bundle). The SRTP
    /// master key and the ICE passwords must never reach them; the key ID and ufrag are not secret.
    @Test func announceLogRedactionStripsKeyMaterialButKeepsIdentifiers() {
        #expect(NvstRtspSdp.redactedForLog("a=x-nv-runtime.encryptionKey:8F3A2B1C4D5E6F708192A3B4C5D6E7F8")
            == "a=x-nv-runtime.encryptionKey:[redacted-secret]")
        #expect(NvstRtspSdp.redactedForLog("a=x-nv-general.icePasswordV2:Xy9pQz1aBc2d")
            == "a=x-nv-general.icePasswordV2:[redacted-secret]")
        #expect(NvstRtspSdp.redactedForLog("a=x-nv-general.iceUsernamePwd:Xy9pQz1aBc2d")
            == "a=x-nv-general.iceUsernamePwd:[redacted-secret]")
        #expect(NvstRtspSdp.redactedForLog("a=x-nv-runtime.encryptionKeyId:42")
            == "a=x-nv-runtime.encryptionKeyId:42")
        #expect(NvstRtspSdp.redactedForLog("a=x-nv-general.iceUsernameFragment:abcd")
            == "a=x-nv-general.iceUsernameFragment:abcd")
        #expect(NvstRtspSdp.redactedForLog("a=x-nv-video[0].maxFPS:120")
            == "a=x-nv-video[0].maxFPS:120")
    }

    /// Every secret-bearing attribute the announce builder emits has to be covered by the redactor.
    @Test func everySecretAnnounceAttributeIsRedacted() {
        let key = "8F3A2B1C4D5E6F708192A3B4C5D6E7F8091A2B3C4D5E6F708192A3B4C5D6E7F8"
        let password = "IcePasswordValue123"
        // `officialCloudPath: false` so both the legacy `iceUsernamePwd` and `icePasswordV2` are
        // emitted — the legacy line is the one that only exists on this branch.
        let options = NvstRtspSdp.AnnounceOptions(
            resolution: "1920x1080",
            fps: 60,
            encryptionKey: .init(aesKeyHex: key, keyID: 7),
            iceCredentials: .init(usernameFragment: "ufragValue", password: password),
            officialCloudPath: false
        )
        let redacted = NvstRtspSdp.buildAnnounceSdp(options)
            .components(separatedBy: "\r\n")
            .map(NvstRtspSdp.redactedForLog)
            .joined(separator: "\n")
        #expect(!redacted.localizedCaseInsensitiveContains(key))
        #expect(!redacted.contains(password))
        #expect(redacted.contains("ufragValue"))
    }

    @Test func videoPeerComesFromTheSetupTransportHeader() {
        let peer = NvstRtspMessage.extractVideoPeer("unicast;X-GS-ClientPort=49000-49001;X-GS-ServerPort=48322;source=10.20.30.40")
        #expect(peer?.ip == "10.20.30.40")
        #expect(peer?.port == 48_322)
        #expect(NvstRtspMessage.extractVideoPeer("unicast;X-GS-ServerPort=48322") == nil)
        #expect(NvstRtspMessage.extractVideoPeer(nil) == nil)
    }
}

@Suite struct NvstRtspSdpTests {
    /// Shaped like a real DESCRIBE body: NVST `x-nv-` attribute dialect plus SDP media sections.
    static let describeBody = """
    v=0
    o=- 0 0 IN IP4 0.0.0.0
    s=NVIDIA Streaming Server
    k=HMAC:0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF
    a=x-nv-general.dtlsFingerprintV2:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99
    a=x-nv-general.iceUserNameFragmentV2:sEaT
    a=x-nv-general.icePasswordV2:seatPasswordThatIsLong
    a=x-nv-general.pingVersion:6
    a=x-nv-general.disablePlay:0
    a=x-nv-general.nativeRtcOnBundlePort:1
    a=x-nv-general.serverTransport:1
    a=x-nv-srtpProfile:AEAD_AES_256_GCM
    m=video 5004
    a=control:streamid=video/0
    m=audio 5006
    a=control:streamid=audio/0
    m=application 0
    a=control:streamid=control/0
    """.replacingOccurrences(of: "\n", with: "\r\n")

    @Test func describeAttributesAreReadThroughTheXnvPrefix() {
        let body = Self.describeBody
        #expect(NvstRtspSdp.attribute(body, "general.pingVersion") == "6")
        #expect(NvstRtspSdp.attribute(body, "general.nativeRtcOnBundlePort") == "1")
        #expect(NvstRtspSdp.attribute(body, "general.disablePlay") == "0")
        #expect(NvstRtspSdp.attribute(body, "general.dtlsFingerprintV2")?.count == 95)
        #expect(NvstRtspSdp.attribute(body, "general.missingAttribute") == nil)
    }

    @Test func mediaControlsAreScopedToTheirMediaSection() {
        let body = Self.describeBody
        #expect(NvstRtspSdp.mediaControl(body, mediaType: "video") == "streamid=video/0")
        #expect(NvstRtspSdp.mediaControl(body, mediaType: "audio") == "streamid=audio/0")
        let controls = NvstRtspSdp.allMediaControls(body)
        #expect(controls == ["streamid=video/0", "streamid=audio/0", "streamid=control/0"])
        #expect(NvstRtspSdp.primaryControlStream(controls) == "streamid=control/0")
        #expect(NvstRtspSdp.primaryControlStream(["streamid=video/0"]) == nil)
    }

    @Test func hmacSeedAndIceCredentialsComeOutOfDescribe() {
        let body = Self.describeBody
        #expect(NvstRtspSdp.hmacSeed(body)?.count == 64)
        let ice = NvstRtspSdp.iceCredentials(body)
        #expect(ice?.usernameFragment == "sEaT")
        #expect(ice?.password == "seatPasswordThatIsLong")
    }

    @Test func advertisedSrtpProfileIsReadFromSdpAndHeaders() {
        #expect(NvstRtspSdp.advertisedSrtpProfile(sdp: Self.describeBody) == .aeadAes256Gcm)
        #expect(NvstRtspSdp.advertisedSrtpProfile(sdp: "a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:abc") == .aesCm128HmacSha1_80)
        // "supported"/"capabilities" attributes advertise what the seat *can* do, not the choice.
        #expect(NvstRtspSdp.advertisedSrtpProfile(sdp: "a=x-nv-srtpProfilesSupported:AEAD_AES_128_GCM") == nil)
        #expect(NvstRtspSdp.advertisedSrtpProfile(headers: ["transport": "unicast;srtp=AEAD_AES_128_GCM"]) == .aeadAes128Gcm)
        #expect(NvstRtspSdp.advertisedSrtpProfile(headers: ["session": "1234"]) == nil)
    }

    @Test func runtimeEncryptionKeyNormalizesTheSignedKeyIdToUnsigned() {
        let sdp = """
        a=x-nv-runtime.encryptionKey:00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff
        a=x-nv-runtime.encryptionKeyId:-1
        """
        let key = NvstRtspSdp.runtimeEncryptionKey(sdp)
        #expect(key?.aesKeyHex == "00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF")
        #expect(key?.keyID == UInt32.max)
        #expect(NvstRtspSdp.runtimeEncryptionKey("a=x-nv-runtime.encryptionKey:abcd") == nil)
    }

    @Test func srtpSaltIsTheUnsignedKeyIdAsTwelveBigEndianBytes() throws {
        #expect(NvstRtspSdp.srtpSaltHex(keyID: 0) == "000000000000000000000000")
        #expect(NvstRtspSdp.srtpSaltHex(keyID: 0x1234_5678) == "000000000000000012345678")
        #expect(NvstRtspSdp.srtpSaltHex(keyID: UInt32.max) == "0000000000000000FFFFFFFF")
        let packed = try NvstRtspSdp.packMasterKeySalt(aesKeyHex: String(repeating: "ab", count: 32), keyID: 7)
        #expect(packed.count == 88)
        #expect(packed.hasSuffix("000000000000000000000007"))
        #expect(throws: NVSTVideoHandoffError.self) {
            _ = try NvstRtspSdp.packMasterKeySalt(aesKeyHex: "abcd", keyID: 7)
        }
    }

    @Test func generatedCredentialsMatchTheOfficialLengths() {
        // Bifrost length-checks reject the 16-char ufrag a stock WebRTC stack emits.
        let alphabet = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/")
        for _ in 0..<32 {
            let credentials = NvstRtspSdp.generateIceCredentials()
            #expect(credentials.usernameFragment.count == 4)
            #expect(credentials.password.count == 22)
            #expect(credentials.usernameFragment.allSatisfy(alphabet.contains))
            #expect(credentials.password.allSatisfy(alphabet.contains))
        }
        let key = NvstRtspSdp.generateClientEncryptionKey()
        #expect(key.aesKeyHex.count == 64)
        #expect(key.aesKeyHex.allSatisfy { $0.isHexDigit && !$0.isLowercase })
    }

    /// The seat states its encoder preferences in DESCRIBE; contradicting them with a hardcoded
    /// default is what produced `FRAME_GRAB_FAILED`.
    @Test func theAnnounceEchoesTheSeatsOfferedAttributes() {
        let offered = NvstRtspSdp.offeredAttributes(Self.describeBody)
        #expect(!offered.isEmpty)
        // The seat's value wins wherever we would otherwise send a default of our own.
        let contested = ("x-nv-video[0].videoSplitEncodeStripsPerFrame", "7")
        let body = NvstRtspSdp.buildAnnounceSdp(.init(offeredAttributes: offered + [contested],
                                                     echoesOfferedAttributes: true))
        #expect(body.contains("a=\(contested.0):\(contested.1)"))
        // Keys we never send are not echoed either: the answer stays the size of the official
        // client's, and only its own values are open to the seat's preference.
        #expect(!body.contains("a=x-nv-general.useNewIceInfo"))
    }

    /// Transport choice and credentials are the client's, so an echoed offer must not restore the
    /// cloud-path flags on a legacy negotiation.
    /// The seat's offer enumerates every stream index it could ever use. Echoing all of it made
    /// the seat drop DTLS at once, so the echo is an intersection, not a union.
    @Test func theAnnounceDoesNotEchoAttributesItNeverSends() {
        let offered = [("x-nv-video[0].chromaFormat", "1"),
                       ("x-nv-vqos[5].turboMode", "1"),
                       ("x-nv-general.someKeyWeNeverSend", "1"),
                       ("x-nv-general.customMessageOnCC", "1")]
        let body = NvstRtspSdp.buildAnnounceSdp(.init(offeredAttributes: offered,
                                                     announcesExtendedSettings: true,
                                                     echoesOfferedAttributes: true))
        #expect(body.contains("a=x-nv-video[0].chromaFormat:1"))
        #expect(body.contains("a=x-nv-general.customMessageOnCC:1"))
        // The rule that stopped the 4112-attribute explosion is the intersection: a key we do not
        // already announce is never introduced by the offer. Stream indices are not the test —
        // the captured official ANNOUNCE does carry video[1…5] and vqos[1…5].
        #expect(!body.contains("a=x-nv-general.someKeyWeNeverSend"))
        #expect(!body.contains("a=x-nv-vqos[5].turboMode"))
        // The official ANNOUNCE is 161 attributes; anything near four thousand is a bug.
        #expect(body.components(separatedBy: "a=x-nv-").count - 1 < 250)
    }

    @Test func theAnnounceNeverEchoesClientOwnedAttributes() {
        let offered = [("x-nv-general.nativeRtcOnBundlePort", "1"),
                       ("x-nv-general.clientPorts.video", "49999"),
                       ("x-nv-video[0].chromaFormat", "1")]
        let body = NvstRtspSdp.buildAnnounceSdp(.init(officialCloudPath: false,
                                                     offeredAttributes: offered,
                                                     echoesOfferedAttributes: true))
        #expect(!body.contains("a=x-nv-general.nativeRtcOnBundlePort:1"))
        #expect(!body.contains("a=x-nv-general.clientPorts.video:49999"))
        #expect(body.contains("a=x-nv-video[0].chromaFormat:1"))
    }

    /// The baseline answer is the one that reached `OPEN_ACK`; the tuning block is opt-in so a
    /// larger ANNOUNCE can never creep back in unnoticed.
    @Test func theBaselineAnnounceStaysSmallAndTheTuningBlockIsOptIn() {
        func attributeCount(_ body: String) -> Int { body.components(separatedBy: "a=x-nv-").count - 1 }
        let baseline = NvstRtspSdp.buildAnnounceSdp(.init())
        let extended = NvstRtspSdp.buildAnnounceSdp(.init(announcesExtendedSettings: true))
        #expect(attributeCount(baseline) < attributeCount(extended))
        #expect(!baseline.contains("a=x-nv-video[0].transferProtocol:"))
        #expect(extended.contains("a=x-nv-video[0].transferProtocol:1"))
        // The baseline is the captured official set, so it carries what that carries — and not the
        // keys we once invented. `maxCodecProfile` and `rateControlMode` were added to fix
        // `VIDEO_ENCODER_INIT_FAILED`; the official client announces neither, and the actual fix
        // was naming the bitstream format.
        #expect(!baseline.contains("a=x-nv-video[0].maxCodecProfile:"))
        #expect(!baseline.contains("a=x-nv-video[0].rateControlMode:"))
        #expect(baseline.contains("a=x-nv-video[0].videoSplitEncodeStripsPerFrame:64"))
    }

    /// The seat encodes whatever `bitStreamFormat` names. Omitting it left it defaulting to a
    /// codec that cannot carry the mode, and it answered `VIDEO_ENCODER_INIT_FAILED`.
    @Test func theAnnounceNamesTheBitstreamFormatForTheNegotiatedCodec() {
        let hevc = NvstRtspSdp.buildAnnounceSdp(.init(codec: .hevc))
        #expect(hevc.contains("a=x-nv-vqos[0].bitStreamFormat:1"))
        #expect(NvstRtspSdp.buildAnnounceSdp(.init(codec: .h264)).contains("a=x-nv-vqos[0].bitStreamFormat:0"))
        #expect(NvstRtspSdp.buildAnnounceSdp(.init(codec: .av1)).contains("a=x-nv-vqos[0].bitStreamFormat:2"))
        // One line per attribute, so the default never survives alongside the negotiated value.
        #expect(hevc.components(separatedBy: "a=x-nv-vqos[0].bitStreamFormat:").count == 2)
    }

    /// The official client's own ANNOUNCE — captured verbatim from its RTSPS WebSocket — carries
    /// exactly two `ri.` attributes. The rest of what appears under `ri.` in its logs is resolved
    /// config it never announces, and announcing `ri.protocol` contradicts the version the seat
    /// negotiates on the control channel.
    /// The captured official ANNOUNCE carries no `rtcpOnSctp`. Announcing it points the seat's
    /// feedback at an SCTP channel the seat never opens for us, so it receives no receiver reports
    /// and its congestion control reduces bitrate and frame rate.
    /// The seat's one-way-delay rate control is fed by `0x0207` QoS reports we do not send, and a
    /// delay controller with no samples parks at a floor: 48 packets/s against the official
    /// client's 401 on the same title, measured.
    @Test func theAnnounceAsksForLossBasedRateControlUntilQosFeedbackExists() {
        #expect(NvstRtspSdp.buildAnnounceSdp(.init()).contains("a=x-nv-bwe.useOwdCongestionControl:0"))
        // And the seat's own preference is restorable for comparison.
        #expect(NvstRtspSdp.buildAnnounceSdp(.init(disablesOwdCongestionControl: false))
            .contains("a=x-nv-bwe.useOwdCongestionControl:1"))
    }

    @Test func theAnnounceDoesNotClaimRtcpOverSctpByDefault() {
        #expect(!NvstRtspSdp.buildAnnounceSdp(.init(rtcpOnSctp: false)).contains("a=x-nv-general.rtcpOnSctp"))
        // Still expressible for a session that really does open the channel.
        #expect(NvstRtspSdp.buildAnnounceSdp(.init(rtcpOnSctp: true)).contains("a=x-nv-general.rtcpOnSctp:1"))
    }

    @Test func theAnnounceCarriesOnlyTheTwoRemoteInputAttributesTheOfficialClientSends() {
        let body = NvstRtspSdp.buildAnnounceSdp(.init())
        #expect(body.contains("a=x-nv-ri.hidDeviceMask:4"))
        #expect(body.contains("a=x-nv-ri.partialReliableThresholdMs:300"))
        let announced = body.components(separatedBy: "\r\n").filter { $0.hasPrefix("a=x-nv-ri.") }
        #expect(announced.count == 2)
        #expect(!body.contains("a=x-nv-ri.protocol:"))
    }

    @Test func theAnnounceCarriesTheEncoderProfileAndBitrate() {
        let body = NvstRtspSdp.buildAnnounceSdp(.init(resolution: "5120x2160",
                                                     fps: 120,
                                                     codec: .hevc,
                                                     bitrateKbps: 75_000))
        // No codec profile/level (the seat takes those from the negotiated profile), but frame rate
        // IS ours: the seat's DESCRIBE baseline caps maxFPS at 60, and the announce overrides only
        // what it states, so a 120 session must announce maxFPS or the encoder stays capped at 60.
        #expect(!body.contains("a=x-nv-video[0].maxCodecProfile:"))
        #expect(body.contains("a=x-nv-video[0].maxFPS:120"))
        #expect(body.contains("a=x-nv-vqos[0].dfc.minTargetFps:100"))
        #expect(body.contains("a=x-nv-vqos[0].gfc.minTargetFps:100"))
        #expect(body.contains("a=x-nv-video[0].clientViewportWd:5120"))
        #expect(body.contains("a=x-nv-video[0].clientViewportHt:2160"))
        #expect(body.contains("a=x-nv-vqos[0].bitStreamFormat:1"))
        #expect(body.contains("a=x-nv-video[0].framePacing.pid.minTargetFrameTimeUs:7936"))
        #expect(!body.contains("a=x-nv-video[0].framePacing.pid.targetFrameTimeUs:"))
        #expect(!body.contains("a=x-nv-video[0].framePacing.pid.maxTargetFrameTimeUs:"))
        #expect(!body.contains("a=x-nv-vqos[0].avoidDuplicateGameFrames:"))
        #expect(!body.contains("a=x-nv-vqos[0].avoidDuplicateNonReflexGameFrames:"))
    }

    @Test func unsetPrefilterLeavesTheCapturedBaselineInPlace() {
        let body = NvstRtspSdp.buildAnnounceSdp(.init())
        #expect(body.contains("a=x-nv-video[0].prefilterParams.prefilterMode:2"))
        #expect(body.contains("a=x-nv-video[0].prefilterParams.prefilterModel:4"))
    }

    @Test func chosenPrefilterOverridesTheCapturedBaselineOnIndexZero() {
        let body = NvstRtspSdp.buildAnnounceSdp(.init(prefilterMode: 3,
                                                     prefilterSharpness: 8,
                                                     prefilterDenoise: 2,
                                                     prefilterModel: 4))
        #expect(body.contains("a=x-nv-video[0].prefilterParams.prefilterMode:3"))
        #expect(body.contains("a=x-nv-video[0].prefilterParams.prefilterModel:4"))
        #expect(body.contains("a=x-nv-video[0].prefilterParams.sharpnessLevel:8"))
        #expect(body.contains("a=x-nv-video[0].prefilterParams.denoiseLevel:2"))
        // Only index 0 is actually decoded/displayed; the captured baseline's other indices are
        // left alone, matching every other client-known override in this file (viewport, maxFPS).
        #expect(body.contains("a=x-nv-video[1].prefilterParams.prefilterMode:2"))
    }

    @Test func prefilterOffZeroesSharpnessAndDenoiseInsteadOfLeavingTheCapturedLevels() {
        let body = NvstRtspSdp.buildAnnounceSdp(.init(prefilterMode: 0))
        #expect(body.contains("a=x-nv-video[0].prefilterParams.prefilterMode:0"))
        #expect(body.contains("a=x-nv-video[0].prefilterParams.sharpnessLevel:0"))
        #expect(body.contains("a=x-nv-video[0].prefilterParams.denoiseLevel:0"))
        // Off does not touch prefilterModel: there is nothing to zero, and the captured default is
        // harmless when the mode itself is off.
        #expect(body.contains("a=x-nv-video[0].prefilterParams.prefilterModel:4"))
    }

    /// The official client pings its RTSPS WebSocket every couple of seconds for the life of the
    /// session — captured from its own `SSL_write`. Nothing else travels on that connection after
    /// PLAY, so an idle one is how the seat sees a client that has gone away.
    @Test func theWebSocketPingIsAMaskedClientFrame() {
        let ping = NvstWebSocketFrame.encodePing()
        #expect(ping.count == 6)                 // 2-byte header + 4-byte mask, empty payload
        #expect(ping[0] == 0x89)                 // FIN + opcode 9
        #expect(ping[1] == 0x80)                 // masked, zero length
        // Text frames keep their own opcode.
        #expect(NvstWebSocketFrame.encodeText(Data("x".utf8))[0] == 0x81)
        #expect(NvstRtspConnection.keepAliveInterval == 2)
    }

    @Test func announceCarriesTheAllowlistResolutionAndCloudFlags() {
        let options = NvstRtspSdp.AnnounceOptions(
            resolution: "3840x2160",
            fps: 120,
            encryptionKey: NvstRuntimeEncryptionKey(aesKeyHex: String(repeating: "0a", count: 32), keyID: 42),
            iceCredentials: NvstRtspIceCredentials(usernameFragment: "abcd", password: String(repeating: "p", count: 22)),
            videoPort: 48_322,
            clientBundlePort: 49_005,
            localAddress: "192.168.1.20",
            dtlsFingerprint: "AA:BB",
            officialCloudPath: true,
            rtcpOnSctp: true
        )
        let sdp = NvstRtspSdp.buildAnnounceSdp(options)
        let lines = sdp.components(separatedBy: "\r\n")
        #expect(lines[0] == "v=0")
        // The official macOS handshake origin username is "unknown", not "android".
        #expect(lines[1] == "o=unknown 0 14 IN IPv4 127.0.0.1")
        #expect(lines.contains("a=x-nv-video[0].clientViewportWd:3840"))
        #expect(lines.contains("a=x-nv-video[0].clientViewportHt:2160"))
        // Frame rate IS announced (the seat's DESCRIBE baseline caps maxFPS at 60; a 120 session
        // must lift it), while the pacing FLOOR stays the captured 7936 us rather than being derived
        // from the fps.
        #expect(lines.contains("a=x-nv-video[0].maxFPS:120"))
        #expect(lines.contains("a=x-nv-video[0].framePacing.pid.minTargetFrameTimeUs:7936"))
        #expect(!lines.contains("a=x-nv-video[0].framePacing.pid.targetFrameTimeUs:16666"))
        #expect(!lines.contains("a=x-nv-video[0].framePacing.pid.maxTargetFrameTimeUs:16684"))
        #expect(lines.contains("a=x-nv-runtime.videoSrtp:1"))
        #expect(lines.contains("a=x-nv-runtime.encryptionKeyId:42"))
        #expect(lines.contains("a=x-nv-runtime.encryptionKey:\(String(repeating: "0A", count: 32))"))
        // Official cloud path: every legacy client port is announced as 0, and the bundle port
        // is advertised separately.
        #expect(lines.contains("a=x-nv-general.clientPorts.video:0"))
        #expect(lines.contains("a=x-nv-general.clientPorts.bundle:0"))
        #expect(lines.contains("a=x-nv-general.clientBundlePort:49005"))
        #expect(lines.contains("a=x-nv-general.nativeRtcOnBundlePort:1"))
        #expect(lines.contains("a=x-nv-general.rtcVideoOnNativeBundle:0"))
        // These must describe what the bundle's answer really offers. A live seat reset every SCTP
        // stream and closed DTLS when we announced audio on a data-channel-only bundle.
        // Audio rides the bundle, and the bundle's answer really offers an audio section.
        #expect(lines.contains("a=x-nv-general.rtcAudioOnNativeBundle:1"))
        // The microphone does not: there is no send section for it yet.
        #expect(lines.contains("a=x-nv-general.rtcMicOnNativeBundle:0"))
        #expect(lines.contains("a=x-nv-general.rtcDataChannelOnNativeBundle:1"))
        // RTCP-over-SCTP must be advertised or the seat stops sending video.
        #expect(lines.contains("a=x-nv-general.rtcpOnSctp:1"))
        // V2 only on the official path; the Nvsc V1 ICE/DTLS attributes are skipped.
        #expect(lines.contains("a=x-nv-general.iceUserNameFragmentV2:abcd"))
        #expect(!lines.contains("a=x-nv-general.iceUsernameFragment:abcd"))
        #expect(lines.contains("a=x-nv-general.dtlsFingerprintV2:AA:BB"))
        #expect(!lines.contains("a=x-nv-general.dtlsFingerprint:AA:BB"))
        // The WebRTC-shaped answer is what actually arms inbound UDP.
        #expect(lines.contains("a=ice-ufrag:abcd"))
        #expect(lines.contains("a=fingerprint:sha-256 AA:BB"))
        #expect(lines.contains("a=setup:actpass"))
        #expect(lines.contains("a=candidate:1 1 udp 2122260223 192.168.1.20 49005 typ host"))
        #expect(lines.contains("m=video 48322"))
        #expect(lines.contains("c=IN IP4 0.0.0.0"))
        #expect(lines.contains("i=DeviceString, DeviceName"))
    }

    @Test func announceFallsBackToTheLegacyPortShapeOffTheCloudPath() {
        let options = NvstRtspSdp.AnnounceOptions(
            iceCredentials: NvstRtspIceCredentials(usernameFragment: "abcd", password: "pw"),
            clientBundlePort: 49_100,
            dtlsFingerprint: "AA:BB",
            officialCloudPath: false
        )
        let lines = NvstRtspSdp.buildAnnounceSdp(options).components(separatedBy: "\r\n")
        #expect(lines.contains("a=x-nv-general.clientPorts.video:49100"))
        #expect(lines.contains("a=x-nv-general.iceUsernameFragment:abcd"))
        #expect(lines.contains("a=x-nv-general.dtlsFingerprint:AA:BB"))
        #expect(!lines.contains("a=x-nv-general.nativeRtcOnBundlePort:1"))
        // Default 1080p when the launch profile has no resolution; frame rate stays the seat's.
        #expect(lines.contains("a=x-nv-video[0].clientViewportWd:1920"))
        #expect(!lines.contains("a=x-nv-video[0].maxFPS:60"))
    }
}

@Suite struct NvstRtspEndpointTests {
    @Test func theTaggedControlPortOutranksTaggedMediaPorts() {
        // A real seat tags BOTH its :322 control endpoint and its :48322 media endpoint with
        // appLevelProtocol 6, so the control port has to win on port number.
        let connections: [[String: Any]] = [
            ["usage": 14, "appLevelProtocol": 6, "port": 48_322, "ip": "seat.example.com"],
            ["usage": 14, "appLevelProtocol": 6, "port": 322, "ip": "seat.example.com"],
        ]
        #expect(NvstRtspEndpoints.collect(connections: connections, fallbackHost: "seat.example.com") == [
            "rtsps://seat.example.com:322",
            "rtsps://seat.example.com:48322",
        ])
    }

    @Test func anUntaggedControlPortAndTheAssumedDefaultAreBothCandidates() {
        // Our own captures showed the :322 control service under a usage code other than 16, and
        // some seats do not advertise it at all — so both cases must still yield a candidate.
        let connections: [[String: Any]] = [
            ["usage": 14, "port": 322, "ip": "media.example.com"],
            ["usage": 14, "port": 443, "resourcePath": "/nvst/"],
        ]
        let endpoints = NvstRtspEndpoints.collect(connections: connections, fallbackHost: "seat.example.com")
        #expect(endpoints == ["rtsps://media.example.com:322", "rtsps://seat.example.com:322"])
        // A tagged endpoint always outranks the untagged and assumed ones.
        let tagged: [[String: Any]] = [
            ["usage": 14, "port": 322, "ip": "media.example.com"],
            ["usage": 16, "port": 322, "ip": "control.example.com"],
        ]
        #expect(NvstRtspEndpoints.collect(connections: tagged, fallbackHost: "seat.example.com").first == "rtsps://control.example.com:322")
        // Placeholder hosts fall back to the session host rather than becoming 0.0.0.0.
        #expect(NvstRtspEndpoints.collect(connections: [["usage": 16, "port": 322, "ip": "0.0.0.0"]], fallbackHost: "seat.example.com")
            == ["rtsps://seat.example.com:322"])
        // With no host at all there is nothing to try.
        #expect(NvstRtspEndpoints.collect(connections: [["usage": 14, "port": 443]], fallbackHost: nil).isEmpty)
    }

    @Test func candidatesArePreferenceOrderedAndDeduplicated() {
        let candidates = NvstRtspEndpoints.candidates([" rtsps://a:322 ", "https://ignored", "rtsps://a:322", "rtsp://b:8554"])
        #expect(candidates == ["rtsps://a:322", "rtsp://b:8554"])
    }

    @Test func rtspsEndpointsComeFromUsageSixteenOrProtocolSix() {
        let connections: [[String: Any]] = [
            ["usage": 14, "port": 443, "resourcePath": "/nvst/"],
            ["usage": 16, "port": 322, "resourcePath": ""],
            ["usage": 10, "port": 443, "appLevelProtocol": 6],
            ["usage": 2, "port": 48322, "resourcePath": "rtsps://explicit.example.com:322"],
        ]
        let endpoints = NvstRtspEndpoints.collect(connections: connections, fallbackHost: "seat.example.com")
        // Tagged-and-on-:322 first, then the explicit rtsps:// resourcePath, and a tagged
        // endpoint on another port last.
        #expect(endpoints == [
            "rtsps://seat.example.com:322",
            "rtsps://explicit.example.com:322",
            "rtsps://seat.example.com:443",
        ])
        #expect(NvstRtspEndpoints.collect(connections: connections, fallbackHost: nil) == ["rtsps://explicit.example.com:322"])
    }

    @Test func rtspsEndpointsAreReadOutOfTheRawSessionJson() {
        let json = """
        {"connectionInfo":[{"usage":16,"port":322},{"usage":14,"port":443}]}
        """
        #expect(NvstRtspEndpoints.collect(rawSessionJSON: json, fallbackHost: "seat") == ["rtsps://seat:322"])
        #expect(NvstRtspEndpoints.collect(rawSessionJSON: "not json", fallbackHost: "seat").isEmpty)
    }

    @Test func endpointParsingDefaultsToTheNvstControlPort() {
        #expect(NvstRtspEndpoints.parse(endpoint: "rtsps://seat.example.com:322") == NvstRtspEndpoints.Target(host: "seat.example.com", port: 322))
        #expect(NvstRtspEndpoints.parse(endpoint: "rtsps://seat.example.com")?.port == 322)
        #expect(NvstRtspEndpoints.parse(endpoint: "rtsp://seat.example.com:8554")?.port == 8554)
        #expect(NvstRtspEndpoints.parse(endpoint: "garbage") == nil)
        #expect(NvstRtspEndpoints.selectPrimary(["", "https://x", "rtsps://a:322", "rtsps://b:322"]) == "rtsps://a:322")
        #expect(NvstRtspEndpoints.selectPrimary(["https://x"]) == nil)
    }

    @Test func setupUriCandidatesPreferTheBareControlToken() {
        // A live seat accepted OPTIONS and DESCRIBE, then answered 400 to an absolute SETUP URI:
        // the official form is the bare control token DESCRIBE advertised.
        let candidates = NvstRtspEndpoints.videoSetupURICandidates(
            control: "streamid=video/0",
            base: "rtsps://seat.example.com:322",
            officialCloudPath: true
        )
        #expect(candidates == [
            "streamid=video/0/0",
            "streamid=video/0",
            "rtsps://seat.example.com:322/streamid=video/0/0",
            "rtsps://seat.example.com:322/streamid=video/0",
        ])
        // Off the cloud path there is no substream transform.
        #expect(NvstRtspEndpoints.videoSetupURICandidates(control: "streamid=video/0", base: "rtsps://seat:322", officialCloudPath: false)
            == ["streamid=video/0", "rtsps://seat:322/streamid=video/0"])
        // An already-absolute control resolves to itself and is not duplicated.
        #expect(NvstRtspEndpoints.videoSetupURICandidates(control: "rtsps://other:322/x", base: "rtsps://seat:322", officialCloudPath: true)
            == ["rtsps://other:322/x"])
    }

    @Test func officialSetupAddressesTheSubstreamOfTheVideoControl() {
        #expect(NvstRtspEndpoints.officialVideoSetupControl("streamid=video/0") == "streamid=video/0/0")
        #expect(NvstRtspEndpoints.officialVideoSetupControl("streamid=video/0/0") == "streamid=video/0/0")
        #expect(NvstRtspEndpoints.officialVideoSetupControl("streamid=audio/0") == "streamid=audio/0")
    }

    @Test func controlUrisResolveAgainstTheRtspBase() {
        #expect(NvstRtspEndpoints.resolveControlURI(base: "rtsps://seat:322", control: "streamid=video/0") == "rtsps://seat:322/streamid=video/0")
        #expect(NvstRtspEndpoints.resolveControlURI(base: "rtsps://seat:322/", control: "/streamid=video/0") == "rtsps://seat:322/streamid=video/0")
        #expect(NvstRtspEndpoints.resolveControlURI(base: "rtsps://seat:322", control: "rtsps://other:322/x") == "rtsps://other:322/x")
    }

    @Test func pingUfragIncrementsAsAFixedWidthLowercaseHexString() {
        // Official bundle ICE remote ufrag is the SETUP ping payload + 1.
        #expect(NvstRtspEndpoints.incrementPingUfrag("998") == "999")
        #expect(NvstRtspEndpoints.incrementPingUfrag("99f") == "9a0")
        #expect(NvstRtspEndpoints.incrementPingUfrag("99F") == "9a0")
        #expect(NvstRtspEndpoints.incrementPingUfrag("fff") == "1000")
        // Wider than 64 bits must still increment.
        #expect(NvstRtspEndpoints.incrementPingUfrag(String(repeating: "0", count: 40)) == String(repeating: "0", count: 39) + "1")
        #expect(NvstRtspEndpoints.incrementPingUfrag("PING") == nil)
        #expect(NvstRtspEndpoints.incrementPingUfrag("") == nil)
    }

    @Test func remoteUfragPrefersTheSetupPingIdentityOverDescribe() {
        #expect(NvstRtspEndpoints.resolveIceRemoteUfrag(pingPayload: "998", describeUfrag: "sEaT", pingVersion: 6) == "999")
        // "Old server only supports PING": the ping string itself is the identity.
        #expect(NvstRtspEndpoints.resolveIceRemoteUfrag(pingPayload: "PING", describeUfrag: "sEaT", pingVersion: 6) == "PING")
        #expect(NvstRtspEndpoints.resolveIceRemoteUfrag(pingPayload: nil, describeUfrag: "sEaT", pingVersion: nil) == "sEaT")
        // A non-hex, non-PING payload on a legacy seat falls back to DESCRIBE.
        #expect(NvstRtspEndpoints.resolveIceRemoteUfrag(pingPayload: "zz", describeUfrag: "sEaT", pingVersion: nil) == "sEaT")
    }
}

@Suite struct NvstFeedbackChannelTests {
    @Test func feedbackChannelUsesTheOfficialPrivateLabel() {
        // `rtcp1` is refused: the seat resets a DCEP open whose label it does not recognise.
        #expect(NvstFeedbackSender.channelLabel == "rtcp_on_sctp_private")
        #expect(NvstFeedbackSender.streamIdentifierCandidates == 8)
    }

    @Test func cadenceEmitsPlainReceiverReportsAndPliOnRequest() {
        let sender = NvstFeedbackSender(interval: 3600)
        sender.configure(channelWriter: { _ in }, senderSSRC: 0x4f4e_4f57, mediaSSRC: 0x1234)
        sender.updateMediaState(highestExtendedSequence: 500, cumulativeLost: 3)
        let plain = sender.nextPayloads()
        #expect(plain.count == 1)
        // Plain RTCP RR: DTLS already encrypts the SCTP association, so there is no SRTCP trailer.
        #expect(plain[0].count == 32)
        #expect(plain[0][1] == NvstRtcp.receiverReportPayloadType)

        sender.requestKeyframe()
        let withPli = sender.nextPayloads()
        #expect(withPli.count == 2)
        #expect(withPli[1].count == 12)
        #expect(withPli[1][1] == NvstRtcp.payloadSpecificFeedbackPayloadType)
        // The request is one-shot.
        #expect(sender.nextPayloads().count == 1)
    }

    @Test func noReportIsEmittedUntilAMediaSsrcIsKnown() {
        // A Receiver Report about SSRC 0 describes a stream that does not exist. A live seat reset
        // the SCTP stream and closed the whole DTLS association shortly after our first report, so
        // reports wait for a bound SSRC.
        let sender = NvstFeedbackSender(interval: 3600)
        final class Sink: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func record() { lock.lock(); count += 1; lock.unlock() }
            var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        }
        let sink = Sink()
        sender.configure(channelWriter: { _ in sink.record() }, senderSSRC: 0x4f4e_4f57, mediaSSRC: 0)
        sender.emitForTesting()
        #expect(sink.value == 0)
        sender.updateMediaSSRC(0x1234_5678)
        sender.emitForTesting()
        #expect(sink.value == 1)
    }

    @Test func mediaSsrcIsLearnedFromTheFirstAuthenticatedPacket() {
        let sender = NvstFeedbackSender(interval: 3600)
        sender.configure(channelWriter: { _ in }, senderSSRC: 1, mediaSSRC: 0)
        sender.updateMediaSSRC(0xdead_beef)
        let report = sender.nextPayloads()[0]
        let ssrc = (UInt32(report[8]) << 24) | (UInt32(report[9]) << 16) | (UInt32(report[10]) << 8) | UInt32(report[11])
        #expect(ssrc == 0xdead_beef)
    }
}

/// A recorded seat: answers the handshake in order and records exactly what the client sent.
private actor RecordedSeat: NvstRtspControlChannel {
    struct SentRequest: Sendable {
        let method: String
        let uri: String
        let headers: [(String, String)]
        let body: String

        func header(_ name: String) -> String? {
            headers.first { $0.0.lowercased() == name.lowercased() }?.1
        }
    }

    private let responses: [String: NvstRtspResponse]
    /// When set, only this SETUP request-URI is accepted; every other form gets the canned
    /// rejection, which is how the live seat behaved.
    private let acceptedSetupURI: String?
    private let acceptedSetupResponse: NvstRtspResponse?
    private(set) var sent: [SentRequest] = []
    private(set) var connected = false
    private(set) var closed = false

    init(responses: [String: NvstRtspResponse],
         acceptedSetupURI: String? = nil,
         acceptedSetupResponse: NvstRtspResponse? = nil) {
        self.responses = responses
        self.acceptedSetupURI = acceptedSetupURI
        self.acceptedSetupResponse = acceptedSetupResponse
    }

    func connect(sessionID: String?) async throws { connected = true }

    func request(method: String, uri: String, headers: [(String, String)], body: String) async throws -> NvstRtspResponse {
        sent.append(SentRequest(method: method, uri: uri, headers: headers, body: body))
        if method == "SETUP", let acceptedSetupURI, let acceptedSetupResponse, uri == acceptedSetupURI {
            return acceptedSetupResponse
        }
        guard let response = responses[method] else {
            return NvstRtspResponse(statusCode: 500, statusText: "No recorded response", headers: [:], body: "")
        }
        return response
    }

    func close() async { closed = true }

    func requests(_ method: String) -> [SentRequest] { sent.filter { $0.method == method } }
}

private struct StubReserver: NvstBundleReserving {
    let reservation: NvstBundleReservation
    /// Stands in for the real ICE/DTLS bundle, which can only come up after SETUP.
    let lateIdentity: NvstBundleReservation?

    init(reservation: NvstBundleReservation, lateIdentity: NvstBundleReservation? = nil) {
        self.reservation = reservation
        self.lateIdentity = lateIdentity
    }

    func reserveBundle() async throws -> NvstBundleReservation { reservation }
    func bundleIdentity(for handoff: NVSTVideoHandoff) async -> NvstBundleReservation? { lateIdentity }
}

@Suite struct NvstRtspNegotiatorTests {
    private static let reservation = NvstBundleReservation(
        bundlePort: 49_005,
        mjolnirPort: 49_006,
        localAddress: "192.168.1.20",
        iceCredentials: NvstRtspIceCredentials(usernameFragment: "abcd", password: String(repeating: "p", count: 22)),
        dtlsFingerprint: "AA:BB:CC:DD"
    )

    private static func seat(describeBody: String = NvstRtspSdpTests.describeBody,
                             setupHeaders: [String: String] = [
                                "session": "S123",
                                "transport": "unicast;X-GS-ServerPort=48322;source=10.20.30.40",
                                "x-nv-ping": "6",
                                "x-nv-ping-payload": "0998",
                             ]) -> RecordedSeat {
        RecordedSeat(responses: [
            "OPTIONS": NvstRtspResponse(statusCode: 200, statusText: "OK", headers: ["x-gs-version": "14.2"], body: ""),
            "DESCRIBE": NvstRtspResponse(statusCode: 200, statusText: "OK", headers: ["session": "S123;timeout=60"], body: describeBody),
            "SETUP": NvstRtspResponse(statusCode: 200, statusText: "OK", headers: setupHeaders, body: ""),
            "ANNOUNCE": NvstRtspResponse(statusCode: 200, statusText: "OK", headers: [:], body: ""),
            "PLAY": NvstRtspResponse(statusCode: 200, statusText: "OK", headers: [:], body: ""),
            "TEARDOWN": NvstRtspResponse(statusCode: 200, statusText: "OK", headers: [:], body: ""),
        ])
    }

    private static func negotiator(_ seat: RecordedSeat,
                                   reservation: NvstBundleReservation = Self.reservation) -> NvstRtspNegotiator {
        NvstRtspNegotiator(
            reserver: StubReserver(reservation: reservation),
            connectionFactory: { _, _, _ in seat }
        )
    }

    private static let input = NvstRtspNegotiationInput(
        sessionID: "session-1",
        rtspsEndpoints: ["rtsps://seat.example.com:322"],
        resolution: "2560x1440",
        fps: 60,
        codec: "HEVC"
    )

    @Test func handshakeRunsOptionsDescribeSetupAnnouncePlayInOrder() async throws {
        let seat = Self.seat()
        let session = try await Self.negotiator(seat).negotiate(Self.input)
        #expect(await seat.sent.map(\.method) == ["OPTIONS", "DESCRIBE", "SETUP", "ANNOUNCE", "PLAY"])
        #expect(session.steps == ["wss-open", "options", "describe", "setup-video", "announce", "play"])
        #expect(session.sessionIdentifier == "S123")
        #expect(session.hmacSeedPresent)
    }

    @Test func describeCarriesTheAbTestingHeaderTheSeatKeysPingOff() async throws {
        let seat = Self.seat()
        _ = try await Self.negotiator(seat).negotiate(Self.input)
        let describe = await seat.requests("DESCRIBE").first
        #expect(describe?.header("x-nv-abtesting") == "2")
        #expect(describe?.header("Accept") == "application/sdp")
        #expect(describe?.header("X-GS-Version") == "14.2")
        #expect(describe?.header("x-nv-sessionid") == "session-1")
    }

    @Test func setupRetriesTheOtherRequestUriFormsUntilOneIsAccepted() async throws {
        // Mirrors the observed seat: OPTIONS/DESCRIBE fine, then 400 for every form but one.
        let seat = RecordedSeat(
            responses: [
                "OPTIONS": NvstRtspResponse(statusCode: 200, statusText: "OK", headers: [:], body: ""),
                "DESCRIBE": NvstRtspResponse(statusCode: 200, statusText: "OK", headers: ["session": "S1"], body: NvstRtspSdpTests.describeBody),
                "SETUP": NvstRtspResponse(statusCode: 400, statusText: "OK", headers: [:], body: ""),
                "ANNOUNCE": NvstRtspResponse(statusCode: 200, statusText: "OK", headers: [:], body: ""),
                "PLAY": NvstRtspResponse(statusCode: 200, statusText: "OK", headers: [:], body: ""),
            ],
            acceptedSetupURI: "streamid=video/0",
            acceptedSetupResponse: NvstRtspResponse(statusCode: 200, statusText: "OK", headers: [
                "transport": "unicast;X-GS-ServerPort=48322;source=10.20.30.40",
                "x-nv-ping": "6",
                "x-nv-ping-payload": "0998",
            ], body: "")
        )
        let session = try await Self.negotiator(seat).negotiate(Self.input)
        #expect(session.handoff.videoPeerPort == 48_322)
        // The first form is tried first and rejected, the second accepted.
        #expect(await seat.requests("SETUP").map(\.uri) == ["streamid=video/0/0", "streamid=video/0"])
    }

    @Test func setupFailingEveryFormReportsTheFormsItTried() async throws {
        let seat = Self.seat(setupHeaders: [:])
        let allRejected = RecordedSeat(responses: [
            "OPTIONS": NvstRtspResponse(statusCode: 200, statusText: "OK", headers: [:], body: ""),
            "DESCRIBE": NvstRtspResponse(statusCode: 200, statusText: "OK", headers: ["session": "S1"], body: NvstRtspSdpTests.describeBody),
            "SETUP": NvstRtspResponse(statusCode: 400, statusText: "OK", headers: [:], body: ""),
        ])
        _ = seat
        await #expect(throws: NvstRtspNegotiationError.self) {
            _ = try await Self.negotiator(allRejected).negotiate(Self.input)
        }
        // Four request-URI forms across both Transport forms are attempted before giving up.
        #expect(await allRejected.requests("SETUP").count == 8)
        let transports = await allRejected.requests("SETUP").map { $0.header("Transport") ?? "" }
        // The official empty Transport is tried first, the legacy client-port form second.
        #expect(transports.prefix(4).allSatisfy { $0.isEmpty })
        #expect(transports.suffix(4).allSatisfy { $0.contains("X-GS-ClientPort=") })
    }

    @Test func officialCloudSetupSendsAnEmptyTransportAndTheAdvertisedPingVersion() async throws {
        let seat = Self.seat()
        _ = try await Self.negotiator(seat).negotiate(Self.input)
        let setup = await seat.requests("SETUP").first
        // Official cloud SETUPs video only, with an empty Transport, at the `/0` substream —
        // addressed by the bare control token, not a resolved absolute URI.
        #expect(setup?.uri == "streamid=video/0/0")
        #expect(setup?.header("Transport") == "")
        #expect(setup?.header("x-nv-ping") == "6")
        #expect(setup?.header("Session") == "S123")
    }

    @Test func handoffIsDerivedFromSetupAndTheClientGeneratedRuntimeKey() async throws {
        let seat = Self.seat()
        let session = try await Self.negotiator(seat).negotiate(Self.input)
        let handoff = session.handoff
        #expect(handoff.videoPeerIP == "10.20.30.40")
        #expect(handoff.videoPeerPort == 48_322)
        // Video arrives on the dedicated Mjolnir socket, not the ICE/DTLS bundle socket.
        #expect(handoff.clientUDPPort == 49_006)
        #expect(handoff.mjolnirUDPPort == 49_006)
        // DESCRIBE advertised AEAD_AES_256_GCM explicitly, so the 16-byte tag wins over the
        // legacy GCM-8 default.
        #expect(handoff.srtpProfile == .aeadAes256Gcm)
        #expect(handoff.srtpAESKey.count == 32)
        #expect(handoff.srtpSalt.count == 12)
        #expect(handoff.codec == .hevc)
        #expect(handoff.pingVersion == 6)
        #expect(handoff.pingPayload == "0998")
        // The handshake needs far longer than the 5 s media idle default.
        #expect(handoff.timeoutMilliseconds == 60_000)
        // Remote ICE identity is the ping payload + 1; the password comes from DESCRIBE.
        #expect(handoff.iceCredentials?.remoteUsernameFragment == "0999")
        #expect(handoff.iceCredentials?.remotePassword == "seatPasswordThatIsLong")
        #expect(handoff.iceCredentials?.localUsernameFragment == "abcd")
        #expect(handoff.iceCredentials?.remoteDTLSFingerprint?.count == 95)
        #expect(session.remoteIceUsernameFragment == "0999")
    }

    @Test func aLateBundleIdentityOverridesTheAnnouncedPortAndFingerprint() async throws {
        // The real bundle needs SETUP's ping payload and DESCRIBE's fingerprint before it can bind,
        // so its port and fingerprint only exist after SETUP — and ANNOUNCE must carry those.
        let seat = Self.seat()
        let late = NvstBundleReservation(
            bundlePort: 61_000,
            mjolnirPort: 49_006,
            localAddress: "10.0.0.7",
            iceCredentials: NvstRtspIceCredentials(usernameFragment: "OyEL", password: String(repeating: "p", count: 22)),
            dtlsFingerprint: "99:88:77"
        )
        let negotiator = NvstRtspNegotiator(
            reserver: StubReserver(reservation: Self.reservation, lateIdentity: late),
            connectionFactory: { _, _, _ in seat }
        )
        _ = try await negotiator.negotiate(Self.input)
        let body = await seat.requests("ANNOUNCE").first?.body ?? ""
        #expect(body.contains("a=x-nv-general.clientBundlePort:61000"))
        #expect(body.contains("a=x-nv-general.dtlsFingerprintV2:99:88:77"))
        #expect(body.contains("a=fingerprint:sha-256 99:88:77"))
        #expect(body.contains("a=candidate:1 1 udp 2122260223 10.0.0.7 61000 typ host"))
        // A live bundle means the feedback plane moves onto its SCTP channel.
        #expect(body.contains("a=x-nv-general.rtcpOnSctp:1"))
        // The reserved placeholder port must not leak into ANNOUNCE.
        #expect(!body.contains("a=x-nv-general.clientBundlePort:49005"))
    }

    @Test func announceReportsTheBundleIdentityAndRtcpOverSctp() async throws {
        let seat = Self.seat()
        _ = try await Self.negotiator(seat).negotiate(Self.input)
        let announce = await seat.requests("ANNOUNCE").first
        #expect(announce?.header("Content-Type") == "application/sdp")
        let body = announce?.body ?? ""
        #expect(body.contains("a=x-nv-general.clientBundlePort:49005"))
        #expect(body.contains("a=x-nv-general.rtcpOnSctp:1"))
        #expect(body.contains("a=x-nv-general.dtlsFingerprintV2:AA:BB:CC:DD"))
        #expect(body.contains("a=x-nv-general.iceUserNameFragmentV2:abcd"))
        #expect(body.contains("a=x-nv-runtime.encryptionKey:"))
        #expect(body.contains("a=x-nv-runtime.videoSrtp:1"))
        #expect(body.contains("a=x-nv-video[0].clientViewportWd:2560"))
        #expect(body.contains("m=video 48322"))
        #expect(body.contains("a=candidate:1 1 udp 2122260223 192.168.1.20 49005 typ host"))
    }

    @Test func theReceiverIsArmedBeforeAnnounceAndTheBundleAfterIt() async throws {
        let seat = Self.seat()
        let order = OrderRecorder()
        _ = try await Self.negotiator(seat).negotiate(
            Self.input,
            onVideoReady: { _ in await order.record("video-ready") },
            onAnnounceReady: { _ in await order.record("announce-ready") }
        )
        // Official Bifrost arms MjolnirVideoReceiver before ANNOUNCE, then WebRtcTransport after.
        #expect(await order.events == ["video-ready", "announce-ready"])
        let methods = await seat.sent.map(\.method)
        #expect(methods == ["OPTIONS", "DESCRIBE", "SETUP", "ANNOUNCE", "PLAY"])
    }

    @Test func releaseTearsDownAndClosesTheControlChannel() async throws {
        let seat = Self.seat()
        let session = try await Self.negotiator(seat).negotiate(Self.input)
        await session.release("test complete")
        #expect(await seat.requests("TEARDOWN").first?.header("Session") == "S123")
        #expect(await seat.closed)
    }

    @Test func forcingTheLegacyPathIgnoresTheAdvertisedCloudPath() async throws {
        let seat = Self.seat()
        let input = NvstRtspNegotiationInput(
            sessionID: "session-1",
            rtspsEndpoints: ["rtsps://seat.example.com:322"],
            resolution: "1920x1080",
            fps: 60,
            codec: "H264",
            rtcpOnSctp: false,
            forcesLegacyPath: true
        )
        _ = try await Self.negotiator(seat).negotiate(input)
        // Legacy SETUP advertises a real client port instead of the empty Transport, and does not
        // address the `/0` substream.
        let setup = await seat.requests("SETUP").first
        #expect(setup?.uri == "streamid=video/0")
        #expect(setup?.header("Transport")?.contains("X-GS-ClientPort=49006-49007") == true)
        // ANNOUNCE announces the socket video actually arrives on and drops the cloud flags.
        let body = await seat.requests("ANNOUNCE").first?.body ?? ""
        #expect(body.contains("a=x-nv-general.clientPorts.video:49006"))
        #expect(!body.contains("a=x-nv-general.nativeRtcOnBundlePort:1"))
        #expect(!body.contains("a=x-nv-general.clientBundlePort:"))
        // Absent rather than 0: the captured official ANNOUNCE carries no `rtcpOnSctp` at all, and
        // claiming it without a feedback channel starves the seat of receiver reports.
        #expect(!body.contains("a=x-nv-general.rtcpOnSctp"))
        // The Nvsc V1 ICE/DTLS attributes come back on the legacy path.
        #expect(body.contains("a=x-nv-general.iceUsernameFragment:abcd"))
    }

    @Test func playIsSkippedWhenDescribeDisabledIt() async throws {
        let body = NvstRtspSdpTests.describeBody.replacingOccurrences(of: "a=x-nv-general.disablePlay:0", with: "a=x-nv-general.disablePlay:1")
        let seat = Self.seat(describeBody: body)
        let session = try await Self.negotiator(seat).negotiate(Self.input)
        #expect(session.steps.contains("play-skipped"))
        #expect(await !seat.sent.map(\.method).contains("PLAY"))
    }

    @Test func announceOnlySeatsAnsweringFourFiveFiveStillYieldASession() async throws {
        let seat = RecordedSeat(responses: [
            "OPTIONS": NvstRtspResponse(statusCode: 200, statusText: "OK", headers: [:], body: ""),
            "DESCRIBE": NvstRtspResponse(statusCode: 200, statusText: "OK", headers: ["session": "S9"], body: NvstRtspSdpTests.describeBody),
            "SETUP": NvstRtspResponse(statusCode: 200, statusText: "OK", headers: [
                "transport": "unicast;X-GS-ServerPort=48322;source=10.20.30.40",
                "x-nv-ping": "6",
                "x-nv-ping-payload": "0998",
            ], body: ""),
            "ANNOUNCE": NvstRtspResponse(statusCode: 200, statusText: "OK", headers: [:], body: ""),
            "PLAY": NvstRtspResponse(statusCode: 455, statusText: "Method Not Valid In This State", headers: [:], body: ""),
        ])
        let session = try await Self.negotiator(seat).negotiate(Self.input)
        #expect(session.steps.contains("play-455"))
    }

    @Test func pingVersionSixWithoutCredentialsFailsClosed() async throws {
        let body = NvstRtspSdpTests.describeBody
            .replacingOccurrences(of: "a=x-nv-general.iceUserNameFragmentV2:sEaT\r\n", with: "")
            .replacingOccurrences(of: "a=x-nv-general.icePasswordV2:seatPasswordThatIsLong\r\n", with: "")
        let seat = Self.seat(describeBody: body)
        await #expect(throws: NvstRtspNegotiationError.missingIceCredentials) {
            _ = try await Self.negotiator(seat).negotiate(Self.input)
        }
        #expect(await seat.closed)
    }

    @Test func aSetupWithoutAVideoPeerFailsClosed() async throws {
        let seat = Self.seat(setupHeaders: ["x-nv-ping": "1"])
        await #expect(throws: NvstRtspNegotiationError.missingVideoPeer) {
            _ = try await Self.negotiator(seat).negotiate(Self.input)
        }
    }

    @Test func conflictingSrtpProfilesBetweenDescribeAndSetupFailClosed() async throws {
        let seat = Self.seat(setupHeaders: [
            "transport": "unicast;X-GS-ServerPort=48322;source=10.20.30.40;srtpProfile=AES_CM_128_HMAC_SHA1_80",
            "x-nv-ping": "6",
            "x-nv-ping-payload": "0998",
        ])
        await #expect(throws: NvstRtspNegotiationError.conflictingSrtpProfile("AEAD_AES_256_GCM", "AES_CM_128_HMAC_SHA1_80")) {
            _ = try await Self.negotiator(seat).negotiate(Self.input)
        }
    }

    @Test func aDescribeWithoutTheControlStreamIsNotAnNvstSeat() async throws {
        let body = NvstRtspSdpTests.describeBody.replacingOccurrences(of: "a=control:streamid=control/0", with: "a=control:streamid=other/0")
        let seat = Self.seat(describeBody: body)
        await #expect(throws: NvstRtspNegotiationError.missingControlStream) {
            _ = try await Self.negotiator(seat).negotiate(Self.input)
        }
    }

    @Test func aSessionWithoutRtspsEndpointsCannotNegotiate() async throws {
        let seat = Self.seat()
        await #expect(throws: NvstRtspNegotiationError.missingEndpoint) {
            _ = try await Self.negotiator(seat).negotiate(
                NvstRtspNegotiationInput(sessionID: "s", rtspsEndpoints: [])
            )
        }
    }

    @Test func aNonTwoHundredDescribeSurfacesTheStatus() async throws {
        let seat = RecordedSeat(responses: [
            "OPTIONS": NvstRtspResponse(statusCode: 200, statusText: "OK", headers: [:], body: ""),
            "DESCRIBE": NvstRtspResponse(statusCode: 401, statusText: "Unauthorized", headers: [:], body: ""),
        ])
        await #expect(throws: NvstRtspNegotiationError.requestFailed("DESCRIBE", 401, "Unauthorized")) {
            _ = try await Self.negotiator(seat).negotiate(Self.input)
        }
    }
}

private actor OrderRecorder {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}
