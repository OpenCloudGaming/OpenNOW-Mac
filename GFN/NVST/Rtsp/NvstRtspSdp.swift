import Foundation

/// NVST SDP: the DESCRIBE body the seat sends and the ANNOUNCE body the client must send back.
///
/// The NVST dialect prefixes every attribute with `x-nv-` (`a=x-nv-general.…`) and groups the
/// video/vqos attributes as `x-nv-video[0].…`. Values below are the minimal allowlist the seat
/// accepts; independently observed, and documented by OpenNOW's MIT
/// `opennow-stable/src/main/platforms/gfn/nvstRtsp/sdp.ts`.
public struct NvstRtspIceCredentials: Equatable, Sendable {
    public let usernameFragment: String
    public let password: String

    public init(usernameFragment: String, password: String) {
        self.usernameFragment = usernameFragment
        self.password = password
    }
}

public struct NvstRuntimeEncryptionKey: Equatable, Sendable {
    public let aesKeyHex: String
    public let keyID: UInt32

    public init(aesKeyHex: String, keyID: UInt32) {
        self.aesKeyHex = aesKeyHex
        self.keyID = keyID
    }
}

public enum NvstRtspSdp {
    /// Drops the `general.*` port/transport block the official client never sends.
    static var suppressesClientPortBlock: Bool {
        ProcessInfo.processInfo.environment["OPN_NVST_ANNOUNCE_OFFICIAL_GENERAL"] == "1"
    }

    // MARK: - DESCRIBE parsing

    /// Reads `a=x-nv-<name>:<value>` (also accepting the unprefixed `a=<name>:<value>` form).
    public static func attribute(_ sdp: String, _ name: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let value = NvstRtspMessage.firstCapture(in: sdp, pattern: "(?m)^a=(?:x-nv-)?\(escaped):([^\\r\\n]*)$")
        let trimmed = value?.trimmingCharacters(in: .whitespaces)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    /// Every `a=x-nv-<name>:<value>` in the seat's offer, in offer order.
    ///
    /// The seat states its own preferences in DESCRIBE (`videoSplitEncodeStripsPerFrame:64`,
    /// `pingIntervalAfterConnectionMs:100`, …). The official client merges those into its config
    /// before building the ANNOUNCE, so contradicting them with a hardcoded value is a bug: the
    /// answer has to agree with the offer on everything only the seat knows.
    public static func offeredAttributes(_ sdp: String) -> [(String, String)] {
        var result: [(String, String)] = []
        for rawLine in sdp.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("a=x-nv-") else { continue }
            let body = line.dropFirst("a=".count)
            guard let separator = body.firstIndex(of: ":") else { continue }
            let name = String(body[body.startIndex..<separator])
            let value = String(body[body.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !value.isEmpty else { continue }
            result.append((name, value))
        }
        return result
    }

    /// `a=control:` under the requested `m=<mediaType>` section.
    public static func mediaControl(_ sdp: String, mediaType: String) -> String? {
        var current: String?
        for rawLine in sdp.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("m=") {
                current = line.dropFirst(2).split(separator: " ").first.map { $0.lowercased() }
                continue
            }
            guard current == mediaType.lowercased(), line.hasPrefix("a=control:") else { continue }
            let control = line.dropFirst("a=control:".count).trimmingCharacters(in: .whitespaces)
            if !control.isEmpty, control != "*" { return control }
        }
        return nil
    }

    public static func allMediaControls(_ sdp: String) -> [String] {
        sdp.components(separatedBy: .newlines).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("a=control:") else { return nil }
            let control = line.dropFirst("a=control:".count).trimmingCharacters(in: .whitespaces)
            return control.isEmpty ? nil : control
        }
    }

    /// The primary `control/0` stream must be advertised or the seat is not NVST-capable.
    public static func primaryControlStream(_ controls: [String]) -> String? {
        controls.first { control in
            NvstRtspMessage.firstCapture(in: control, pattern: "(?:^|[=/])(control/0)(?:/|$)") != nil
        }
    }

    public static func hmacSeed(_ sdp: String) -> String? {
        NvstRtspMessage.firstCapture(in: sdp, pattern: "(?m)^k=HMAC:([0-9A-Fa-f]{64})\\s*$")
    }

    /// DESCRIBE ICE credentials: V1 (`iceUsernameFragment`/`iceUsernamePwd`) or V2.
    public static func iceCredentials(_ sdp: String) -> NvstRtspIceCredentials? {
        let ufrag = attribute(sdp, "general.iceUsernameFragment")
            ?? NvstRtspMessage.firstCapture(in: sdp, pattern: "(?m)^a=ice-ufrag:([^\\r\\n]+)$")?.trimmingCharacters(in: .whitespaces)
            ?? attribute(sdp, "general.iceUserNameFragmentV2")
        let password = attribute(sdp, "general.iceUsernamePwd")
            ?? NvstRtspMessage.firstCapture(in: sdp, pattern: "(?m)^a=ice-pwd:([^\\r\\n]+)$")?.trimmingCharacters(in: .whitespaces)
            ?? attribute(sdp, "general.icePasswordV2")
        guard let ufrag, !ufrag.isEmpty, let password, !password.isEmpty else { return nil }
        return NvstRtspIceCredentials(usernameFragment: ufrag, password: password)
    }

    /// `runtime.encryptionKey` + `runtime.encryptionKeyId`. The seat writes the id as a signed
    /// i32; the salt derivation uses its unsigned form.
    public static func runtimeEncryptionKey(_ sdp: String) -> NvstRuntimeEncryptionKey? {
        guard let key = NvstRtspMessage.firstCapture(in: sdp, pattern: "(?m)^a=x-nv-runtime\\.encryptionKey:([0-9A-Fa-f]{64})\\s*$"),
              let idText = NvstRtspMessage.firstCapture(in: sdp, pattern: "(?m)^a=x-nv-runtime\\.encryptionKeyId:(-?[0-9]+)\\s*$"),
              let signed = Int64(idText) else { return nil }
        let unsigned = signed < 0 ? UInt32(truncatingIfNeeded: signed) : UInt32(truncatingIfNeeded: signed)
        return NvstRuntimeEncryptionKey(aesKeyHex: key.uppercased(), keyID: unsigned)
    }

    // MARK: - Key material

    /// libsrtp master salt = the unsigned key id rendered as a 12-byte big-endian hex string.
    public static func srtpSaltHex(keyID: UInt32) -> String {
        String(format: "%024X", keyID)
    }

    /// libsrtp master key||salt (AES-256 key + 12-byte salt = 88 hex chars).
    public static func packMasterKeySalt(aesKeyHex: String, keyID: UInt32) throws -> String {
        let key = aesKeyHex.trimmingCharacters(in: .whitespaces).uppercased()
        guard key.count == 64, key.allSatisfy({ $0.isHexDigit }) else {
            throw NVSTVideoHandoffError.invalidHex("runtime.encryptionKey")
        }
        return key + srtpSaltHex(keyID: keyID)
    }

    /// Official Bifrost always client-generates `runtime.encryptionKey` for ANNOUNCE; the
    /// video SRTP socket is keyed by this runtime key, never by DTLS-SRTP.
    public static func generateClientEncryptionKey() -> NvstRuntimeEncryptionKey {
        var key = Data(capacity: 32)
        for _ in 0..<32 { key.append(UInt8.random(in: 0...255)) }
        let hex = key.map { String(format: "%02X", $0) }.joined()
        return NvstRuntimeEncryptionKey(aesKeyHex: hex, keyID: UInt32.random(in: 0...UInt32.max))
    }

    /// Official `GenerateIceCredentials()`: 4-char ufrag + 22-char password over the base64
    /// alphabet. Bifrost length-checks reject the 16-char ufrag stock WebRTC stacks emit.
    public static func generateIceCredentials() -> NvstRtspIceCredentials {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/")
        func encode(_ length: Int) -> String {
            String((0..<length).map { _ in alphabet[Int(UInt8.random(in: 0...255)) & 0x3f] })
        }
        return NvstRtspIceCredentials(usernameFragment: encode(4), password: encode(22))
    }

    // MARK: - SRTP profile advertisement

    private static let knownProfiles: [String] = [
        "AEAD_AES_128_GCM",
        "AEAD_AES_256_GCM",
        "AES_CM_128_HMAC_SHA1_32",
        "AES_CM_128_HMAC_SHA1_80",
        "AES_CM_256_HMAC_SHA1_32",
        "AES_CM_256_HMAC_SHA1_80",
    ]

    private static func findProfile(_ value: String) -> NVSTSrtpProfile? {
        let upper = value.uppercased()
        for token in upper.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).inverted) {
            guard knownProfiles.contains(token) else { continue }
            return NVSTSrtpProfile.parse(token)
        }
        return nil
    }

    public static func advertisedSrtpProfile(sdp: String) -> NVSTSrtpProfile? {
        for rawLine in sdp.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if NvstRtspMessage.firstCapture(in: line, pattern: "^(a=crypto:[0-9]+)\\s+") != nil {
                if let profile = findProfile(line) { return profile }
                continue
            }
            guard let colon = line.firstIndex(of: ":"), line.hasPrefix("a=") else { continue }
            let name = String(line[line.index(line.startIndex, offsetBy: 2)..<colon])
            guard matchesProfileAttribute(name) else { continue }
            if let profile = findProfile(String(line[line.index(after: colon)...])) { return profile }
        }
        return nil
    }

    public static func advertisedSrtpProfile(headers: [String: String]) -> NVSTSrtpProfile? {
        for (name, value) in headers {
            guard name.lowercased() == "transport" || matchesProfileAttribute(name) else { continue }
            if let profile = findProfile(value) { return profile }
        }
        return nil
    }

    private static func matchesProfileAttribute(_ name: String) -> Bool {
        let lower = name.lowercased()
        guard lower.contains("srtp") || lower.contains("crypto") else { return false }
        guard lower.contains("profile") || lower.contains("suite") else { return false }
        return !(lower.contains("supported") || lower.contains("capabilit"))
    }

    // MARK: - ANNOUNCE

    public struct AnnounceOptions: Sendable {
        public var resolution: String?
        public var fps: Int?
        public var encryptionKey: NvstRuntimeEncryptionKey?
        public var iceCredentials: NvstRtspIceCredentials?
        public var videoPort: UInt16
        public var clientBundlePort: UInt16?
        /// The port the seat should send Opus audio to when audio is not riding the bundle. Set
        /// together with `carriesAudioOnBundle == false`.
        public var clientAudioPort: UInt16?
        /// Legacy path only: the client port video actually arrives on (the Mjolnir socket).
        public var clientVideoPort: UInt16?
        public var localAddress: String?
        public var dtlsFingerprint: String?
        /// Official cloud path (`general.nativeRtcOnBundlePort:1`): every legacy `clientPorts.*`
        /// is announced as 0 and the ICE/DTLS bundle port carries control/audio.
        public var officialCloudPath: Bool
        public var rtcpOnSctp: Bool
        /// What the bundle actually carries. These must match the media sections the bundle's
        /// answer really offers: announcing audio on the bundle and then presenting a
        /// data-channel-only answer makes the seat reset every SCTP stream and close DTLS.
        public var carriesAudioOnBundle: Bool
        public var carriesMicrophoneOnBundle: Bool
        public var carriesDataChannelOnBundle: Bool
        /// The seat's own `a=x-nv-*` offer, echoed back so the answer never contradicts it.
        public var offeredAttributes: [(String, String)]
        /// Drives `maxCodecProfile`/`maxCodecLevel`; the seat cannot init an encoder without them.
        public var codec: NVSTVideoCodec?
        public var bitrateKbps: Int?
        /// The user's configured ceiling. The captured base announces 100000, which is NVIDIA's own
        /// default rather than anything this client chose, so a configured cap has to replace it or
        /// the setting does nothing on this path.
        public var maximumBitrateKbps: Int?
        /// Adds the official client's encoder tuning and timer block. Opt-in: a larger ANNOUNCE has
        /// been observed to make the seat close DTLS immediately, so it is isolated from the
        /// encoder identity that a stream actually needs.
        /// `OPN_NVST_OWD_CC=1` restores the seat's one-way-delay controller.
        public var disablesOwdCongestionControl: Bool
        public var announcesExtendedSettings: Bool
        /// Lets the seat's DESCRIBE offer override our value for keys we already send.
        public var echoesOfferedAttributes: Bool

        public init(resolution: String? = nil,
                    fps: Int? = nil,
                    encryptionKey: NvstRuntimeEncryptionKey? = nil,
                    iceCredentials: NvstRtspIceCredentials? = nil,
                    videoPort: UInt16 = 0,
                    clientBundlePort: UInt16? = nil,
                    clientVideoPort: UInt16? = nil,
                    clientAudioPort: UInt16? = nil,
                    localAddress: String? = nil,
                    dtlsFingerprint: String? = nil,
                    officialCloudPath: Bool = true,
                    rtcpOnSctp: Bool = true,
                    carriesAudioOnBundle: Bool = true,
                    carriesMicrophoneOnBundle: Bool = false,
                    carriesDataChannelOnBundle: Bool = true,
                    offeredAttributes: [(String, String)] = [],
                    codec: NVSTVideoCodec? = nil,
                    bitrateKbps: Int? = nil,
                    maximumBitrateKbps: Int? = nil,
                    disablesOwdCongestionControl: Bool = true,
                    announcesExtendedSettings: Bool = false,
                    echoesOfferedAttributes: Bool = false) {
            self.disablesOwdCongestionControl = disablesOwdCongestionControl
            self.announcesExtendedSettings = announcesExtendedSettings
            self.echoesOfferedAttributes = echoesOfferedAttributes
            self.offeredAttributes = offeredAttributes
            self.codec = codec
            self.bitrateKbps = bitrateKbps
            self.maximumBitrateKbps = maximumBitrateKbps
            self.resolution = resolution
            self.fps = fps
            self.encryptionKey = encryptionKey
            self.iceCredentials = iceCredentials
            self.videoPort = videoPort
            self.clientBundlePort = clientBundlePort
            self.clientVideoPort = clientVideoPort
            self.localAddress = localAddress
            self.dtlsFingerprint = dtlsFingerprint
            self.officialCloudPath = officialCloudPath
            self.rtcpOnSctp = rtcpOnSctp
            self.clientAudioPort = clientAudioPort
            self.carriesAudioOnBundle = carriesAudioOnBundle
            self.carriesMicrophoneOnBundle = carriesMicrophoneOnBundle
            self.carriesDataChannelOnBundle = carriesDataChannelOnBundle
        }
    }



    /// Encoder tuning and timers copied from the official client's resolved config. Useful to
    /// match it exactly, but none of it is needed to start a stream, so it stays opt-in until a
    /// live run shows the seat tolerates it.
    private static let videoExtendedAllowlist: [(String, String)] = [
        ("mtuPacketSizeControl", "1"),
        ("rtpNackMaxRetries", "3"),
        ("rtpNackVersion", "2"),
        ("encoderPreset", "5"),
        ("encoderCscMode", "2"),
        ("encoderHdrCscMode", "4"),
        ("encoderFeatureSetting", "47"),
        ("encoderLtrFeatureSetting", "2"),
        ("encoderMultiRefFeatureSetting", "2"),
        ("encoderMultiPass", "0"),
        ("initialQp", "35"),
        ("minQp", "14"),
        ("lowQpBitrateKbps", "5000"),
        ("keyFrameScale", "4"),
        ("maxNumReferenceFrames", "0"),
        ("numTemporalLayers", "0"),
        ("refPicInvalidation", "1"),
        ("streamRecoveryType", "2"),
        ("fullFrameAssembly", "1"),
        ("transferProtocol", "1"),
        ("dejitterBufferLengthMs", "52"),
        ("pingBackIntervalMs", "3000"),
        ("pingBackTimeoutMs", "10000"),
        ("sendFirstFrameTimeoutMs", "50000"),
        ("sendFrameTimeoutMs", "7000"),
        ("timeoutLengthMs", "8000"),
    ]






    private static let generalExtendedAllowlist: [(String, String)] = [
        ("customMessageOnCC", "1"),
        ("maxQosMessagesSize", "1071"),
        ("transitSelectionSettings.enableDynamicTransitSelection", "1"),
        ("transitSelectionSettings.selectionEnforcementMethod", "1"),
    ]


    public static func buildAnnounceSdp(_ options: AnnounceOptions) -> String {
        let (width, height) = parseResolution(options.resolution)

        var lines: [String] = [
            "v=0",
            // The official macOS handshake origin username is "unknown".
            "o=unknown 0 14 IN IPv4 127.0.0.1",
            "s=NVIDIA Streaming Client",
        ]

        // Attributes are written through an ordered store so the three layers can overwrite each
        // other in a defined order: our defaults, then the seat's own offer (it knows its encoder
        // better than we do), then the values only the client can know.
        var attributeOrder: [String] = []
        var attributeValues: [String: String] = [:]
        func set(_ name: String, _ value: String) {
            if attributeValues.updateValue(value, forKey: name) == nil { attributeOrder.append(name) }
        }

        func push(_ prefix: String, indexed: Bool, _ values: [(String, String)]) {
            for (key, value) in values {
                set("x-nv-\(prefix)\(indexed ? "[0]" : "").\(key)", value)
            }
        }

        // Base: what the official client actually announces, captured from its own RTSPS
        // WebSocket. Hand-curating this meant guessing which of ~160 attributes mattered.
        for (name, value) in NvstCapturedAnnounce.attributes where !isClientOwned(name) {
            set(name, value)
        }

        // Nothing hand-curated on top of the capture. Overriding it was how we ended up announcing
        // `videoSplitEncodeStripsPerFrame:3` where the official client sends 64 — a different
        // slice packetisation, and a frame rate to match. The extended block stays opt-in.
        if options.announcesExtendedSettings {
            push("video", indexed: true, videoExtendedAllowlist)
            push("general", indexed: false, generalExtendedAllowlist)
        }

        // The captured baseline packs a frame's packets into five groups across 1 ms. At 60 fps
        // that is a fifth of the frame interval; at 120 it is an eighth, and the result is a dense
        // UDP burst followed by a long gap — which is what a receive buffer overflows on and what
        // our own per-wake histogram showed thousands of times. Spread a high-refresh frame across
        // less than half its 8.33 ms interval instead. This changes packet timing only: not the
        // encode rate, not the display rate. Matches OpenNOW's native streamer, which made the same
        // change for the same reason.
        if let fps = options.fps, fps >= 100 {
            set("x-nv-packetPacing.maxDelayUs", "4000")
        }

        // The seat's offer is authoritative about the settings we already send, and about its own
        // `general.*` block. It is not an invitation to echo everything it mentions: the offer
        // enumerates every stream index the seat could ever use, and answering with thousands of
        // attributes for streams that do not exist made the seat drop DTLS immediately. So the echo
        // is an intersection — the seat's value wins for keys we would otherwise hardcode — never a
        // union. Transport choice and credentials stay ours.
        if options.echoesOfferedAttributes {
            let known = Set(attributeOrder)
            for (name, value) in options.offeredAttributes where !isClientOwned(name) {
                guard known.contains(name) else { continue }
                set(name, value)
            }
        }

        // Client-only knowledge, applied last so neither our defaults nor the offer can override it.
        set("x-nv-video[0].clientViewportWd", String(width))
        set("x-nv-video[0].clientViewportHt", String(height))
        // The seat's DESCRIBE is a 720p60 BASELINE (captured live: it offers clientViewport 1280x720
        // and video[0].maxFPS:60 even for a session we provisioned at 5120x2160@120). The client's
        // announce overrides that baseline — and we were overriding only the viewport (720->5K) while
        // leaving maxFPS at the baseline 60, so the encoder ran at 5K but CAPPED FRAME RATE AT 60.
        // The earlier "official announces no maxFPS" note came from a 720p60 capture, where 60 already
        // equalled the baseline so no override was needed; a 120 session must lift it. Set maxFPS and
        // the vendor's measured high-refresh DFC/GFC floor. This exact combination sustained 120 FPS
        // in repeated hardware runs; raising the floor to the ceiling made the client contradict the
        // server's dynamic frame controller without improving the negotiated limit.
        if let fps = options.fps, fps > 0 {
            set("x-nv-video[0].maxFPS", String(fps))
            if fps > 60 {
                set("x-nv-vqos[0].dfc.minTargetFps", "100")
                set("x-nv-vqos[0].gfc.minTargetFps", "100")
                // A real plaintext capture of the official client's own ANNOUNCE (2026-08-28, SSL
                // tap) shows it overrides these too — the seat's DESCRIBE default is
                // `dfcAlgoVersion:1`, and the captured client explicitly asks for version 2. This
                // codebase only ever sent `minTargetFps`, leaving the seat on its default algorithm
                // and every other DFC tuning value the captured client overrides.
                set("x-nv-vqos[0].dfc.enable", "1")
                set("x-nv-vqos[0].dfc.adjustResAndFps", "0")
                set("x-nv-vqos[0].dfc.dfcAlgoVersion", "2")
                set("x-nv-vqos[0].dfc.decodeFpsAdjPercent", "85")
                set("x-nv-vqos[0].dfc.qpMinUpperLimit", "39")
                set("x-nv-vqos[0].dfc.qpMaxResThresholdAdj", "6")
                set("x-nv-vqos[0].dfc.targetDownCooldownMs", "250")
                // Not overridden here: the separate `resControl.dfc` namespace, whose defaults step
                // the target frame rate down in 5% increments (`receiverFpsDecreasePercent:5`,
                // `useClientFpsPerf:1`). Disabling it was tested (2026-08-28) — the attributes were
                // accepted on the wire and changed nothing — and the official client leaves it
                // alone too, so we match it and leave it alone.
            }
        }
        // The captured official client also always sends this. "Cloud G-Sync" — the seat's own
        // session response separately carries `finalizedStreamingFeatures.cloudGsync`, but that
        // reflects account/GPU-tier eligibility, not confirmation this client asked for it. Never
        // sent before; worth a direct test given the gameFps evidence (a captured official
        // session's game engine itself rendered at ~120fps, matching the stream target, not the
        // 155-160fps this repro's own sessions render at) that this may be the seat's real lever
        // for keeping the source itself paced to the client instead of decode having to catch up
        // to a faster one.
        set("x-nv-video[0].cloudGsync", "1")
        // Re-tried and removed again (2026-08-28): announcing avoidDuplicateGameFrames:0 changed
        // nothing live — static scenes still read 44-61 fps — the seat silently drops attributes
        // its DESCRIBE never offered. The static-scene dip is the seat not encoding unchanged
        // frames, and no announce knob we can reach turns that off.
        // The installed native client's cursor policy. Without these the seat accepts the cursor
        // channel but never publishes local cursor shapes, so the client cannot tell when the game
        // shows or hides its pointer and is stuck with the seat's composited one.
        set("x-nv-runtime.mouseCursorCapture", "3")
        set("x-nv-runtime.mimicRemoteCursor", "0")
        if let codec = options.codec {
            // Which bitstream to encode is still ours: the capture is an HEVC session.
            set("x-nv-vqos[0].bitStreamFormat", bitStreamFormat(codec))
        }
        // The seat's rate control is one-way-delay based (the vendor default). Its OWD samples ride
        // in the client's `0x0207` QoS reports (the rtpTimestamp at +36), which we now send at
        // 18 Hz — so the delay controller has its evidence and this defaults ON. The loss-based
        // fallback parks the encoder at a floor (48 packets/s vs the official client's 401), so it
        // is only reachable via OPN_NVST_OWD_CC=0.
        if options.disablesOwdCongestionControl {
            set("x-nv-bwe.useOwdCongestionControl", "0")
        }
        if let bitrateKbps = options.bitrateKbps, bitrateKbps > 0 {
            set("x-nv-video[0].initialBitrateKbps", String(bitrateKbps))
            set("x-nv-video[0].initialPeakBitrateKbps", String(bitrateKbps))
        }
        if let maximumBitrateKbps = options.maximumBitrateKbps, maximumBitrateKbps > 0 {
            set("x-nv-vqos[0].bw.maximumBitrateKbps", String(maximumBitrateKbps))
            // The ceiling alone is not enough. OpenNOW's native NVST client announces these three
            // alongside it and documents why: "bitrate remains adaptive while dynamic
            // resolution/framerate stay disabled. Omitting these fields leaves the server near its
            // low default rate even when the UI ceiling is much higher." The two IIR factors are the
            // rate controller's smoothing constants; without them its adaptation stays near the
            // floor instead of climbing to the announced maximum.
            set("x-nv-vqos[0].bw.minimumBitrateKbps", "1000")
            set("x-nv-vqos[0].drc.bitrateIirFilterFactor", "128")
            set("x-nv-vqos[0].resControl.bitrateIirFilterFactor", "128")
            // Gradual Rate Control: the mechanism that lets the seat come DOWN from the announced
            // ceiling when our receiver reports loss. Without it the encoder holds the opening bid
            // regardless of feedback, which is what a 5K120 session at a 100 Mbps ceiling looks
            // like from here — measured 1% wire loss, 265 reference recoveries and 655 bad-data
            // frames in 65 s, with the seat re-sending keyframes into the same congestion.
            // `7` enables all H.264/H.265 modes, matching OpenNOW's native Linux client (which
            // moved off `0` for exactly this reason) and the key exists verbatim in libBifrost2.
            // DRC stays off, so resolution and frame rate remain predictable — only bitrate moves.
            set("x-nv-vqos[0].grc.enable", "7")
        }
        // Corrected 2026-08-28: the claim that the vendor sends 16666/16684 here was based on an
        // earlier, incomplete capture. A full byte-exact capture of the real client's own ANNOUNCE
        // (unmasked from an SSL tap, ~8.2 KB SDP body — see docs/NVST/
        // NativeNVST120FPSInvestigation.md Phase 18/19) shows it sends ONLY `minTargetFrameTimeUs`.
        // It never sends `targetFrameTimeUs`/`maxTargetFrameTimeUs` at all. Sending a hardcoded
        // 16666/16684 (~60 fps) here silently caps the PID controller's own range to ~60-126 fps
        // regardless of what `maxFPS` requests — invisible at 120 fps, where 126 fps happens to be
        // just above it, but a live 240 fps session hit exactly this: capped at ~120 fps despite a
        // correct `maxFPS:240` announce. `minTargetFrameTimeUs` alone is real, vendor-verified, and
        // constant across every negotiated fps this investigation captured (120 and ~75).
        set("x-nv-video[0].framePacing.pid.minTargetFrameTimeUs", "7936")

        for name in attributeOrder {
            lines.append("a=\(name):\(attributeValues[name] ?? "")")
        }
        lines.append("a=x-nv-runtime.videoSrtp:1")
        if let key = options.encryptionKey {
            lines.append("a=x-nv-runtime.encryptionKey:\(key.aesKeyHex.uppercased())")
            lines.append("a=x-nv-runtime.encryptionKeyId:\(key.keyID)")
        }
        if let ice = options.iceCredentials {
            if !options.officialCloudPath {
                lines.append("a=x-nv-general.iceUsernameFragment:\(ice.usernameFragment)")
                lines.append("a=x-nv-general.iceUsernamePwd:\(ice.password)")
            }
            lines.append("a=x-nv-general.iceUserNameFragmentV2:\(ice.usernameFragment)")
            lines.append("a=x-nv-general.icePasswordV2:\(ice.password)")
        }
        if let localAddress = options.localAddress {
            lines.append("a=x-nv-general.clientPorts.localAddress:\(localAddress)")
        }
        // The captured official ANNOUNCE carries none of this block — no `clientPorts.*`, no
        // `clientBundlePort`, no `nativeRtcOnBundlePort`, no `rtc*OnNativeBundle`, no
        // `enableUnifiedSocket` — and its session receives audio on the bundle port regardless.
        // Ours announces `clientPorts.audio:0`, and the seat's DESCRIBE comes back with
        // `m=audio 0`, i.e. audio rejected. Suppressing the block is how that is tested.
        if options.officialCloudPath, !Self.suppressesClientPortBlock {
            for name in ["video", "audio", "mic", "control", "bundle", "session"] {
                // Audio is announced as 0 only while the bundle carries it. On its own socket the
                // seat has to be told where to send it, since there is no SETUP for audio.
                if name == "audio", let audioPort = options.clientAudioPort, !options.carriesAudioOnBundle {
                    lines.append("a=x-nv-general.clientPorts.audio:\(audioPort)")
                    continue
                }
                lines.append("a=x-nv-general.clientPorts.\(name):0")
            }
        } else if !options.officialCloudPath, let videoPort = options.clientVideoPort ?? options.clientBundlePort {
            lines.append("a=x-nv-general.clientPorts.video:\(videoPort)")
        }
        if let bundlePort = options.clientBundlePort, !Self.suppressesClientPortBlock {
            lines.append("a=x-nv-general.clientBundlePort:\(bundlePort)")
        }
        if options.officialCloudPath, !Self.suppressesClientPortBlock {
            lines.append("a=x-nv-general.nativeRtcOnBundlePort:1")
            // Video stays on the dedicated raw-SRTP Mjolnir socket; audio/mic/data ride the bundle.
            // Video always stays on the dedicated raw-SRTP Mjolnir socket.
            lines.append("a=x-nv-general.rtcVideoOnNativeBundle:0")
            lines.append("a=x-nv-general.rtcAudioOnNativeBundle:\(options.carriesAudioOnBundle ? "1" : "0")")
            lines.append("a=x-nv-general.rtcMicOnNativeBundle:\(options.carriesMicrophoneOnBundle ? "1" : "0")")
            lines.append("a=x-nv-general.rtcDataChannelOnNativeBundle:\(options.carriesDataChannelOnBundle ? "1" : "0")")
            lines.append("a=x-nv-general.enableUnifiedSocket:0")
        }
        // Only when explicitly asked for. The captured official ANNOUNCE does not carry this at
        // all: announcing `rtcpOnSctp:1` tells the seat to expect receiver reports on an SCTP
        // channel the seat never opens for us, so it gets none and its congestion control backs the
        // bitrate and frame rate down. Feedback goes on the Mjolnir socket's SRTCP instead.
        if options.rtcpOnSctp {
            lines.append("a=x-nv-general.rtcpOnSctp:1")
        }
        if let fingerprint = options.dtlsFingerprint {
            if !options.officialCloudPath {
                lines.append("a=x-nv-general.dtlsFingerprint:\(fingerprint)")
            }
            lines.append("a=x-nv-general.dtlsFingerprintV2:\(fingerprint)")
        }
        // NVST `x-nv-general.*` alone does not arm inbound UDP: the official ANNOUNCE also
        // carries a WebRTC-shaped ICE/DTLS answer with a host candidate.
        if let ice = options.iceCredentials {
            lines.append("a=ice-options:trickle")
            lines.append("a=ice-ufrag:\(ice.usernameFragment)")
            lines.append("a=ice-pwd:\(ice.password)")
        }
        if let fingerprint = options.dtlsFingerprint {
            lines.append("a=fingerprint:sha-256 \(fingerprint)")
            lines.append("a=setup:actpass")
        }
        if let address = options.localAddress, let port = options.clientBundlePort, port > 0 {
            lines.append("a=candidate:1 1 udp 2122260223 \(address) \(port) typ host")
        }
        lines.append("t=0 0")
        // The live capture announces the server's video port, not SDP's "0 = unused".
        lines.append("m=video \(options.videoPort)")
        if options.iceCredentials != nil || options.dtlsFingerprint != nil {
            lines.append("c=IN IP4 0.0.0.0")
        }
        lines.append("i=DeviceString, DeviceName")
        lines.append("")
        return lines.joined(separator: "\r\n")
    }

    /// Attributes the client decides, so an echoed offer must not overwrite them.
    static func isClientOwned(_ name: String) -> Bool {
        let clientOwned: Set<String> = [
            "x-nv-general.nativeRtcOnBundlePort",
            "x-nv-general.rtcVideoOnNativeBundle",
            "x-nv-general.rtcAudioOnNativeBundle",
            "x-nv-general.rtcMicOnNativeBundle",
            "x-nv-general.rtcDataChannelOnNativeBundle",
            "x-nv-general.enableUnifiedSocket",
            "x-nv-general.rtcpOnSctp",
            "x-nv-general.iceUsernameFragment",
            "x-nv-general.iceUsernamePwd",
            "x-nv-general.iceUserNameFragmentV2",
            "x-nv-general.icePasswordV2",
            "x-nv-general.dtlsFingerprint",
            "x-nv-general.dtlsFingerprintV2",
            "x-nv-general.clientBundlePort",
            "x-nv-runtime.videoSrtp",
            "x-nv-runtime.encryptionKey",
            "x-nv-runtime.encryptionKeyId",
        ]
        if clientOwned.contains(name) { return true }
        return name.hasPrefix("x-nv-general.clientPorts.")
    }

    /// `vqos[0].bitStreamFormat`. Only HEVC is measured (the official client resolves 1 for an
    /// HEVC session); H.264 and AV1 follow the codec order either side of it.
    static func bitStreamFormat(_ codec: NVSTVideoCodec) -> String {
        switch codec {
        case .h264: "0"
        case .hevc: "1"
        case .av1: "2"
        }
    }

    /// `maxCodecProfile` / `maxCodecLevel` as the official client resolves them.
    static func codecProfileAndLevel(_ codec: NVSTVideoCodec) -> (String, String) {
        // The captured client reports profile 3 / level 61 across codecs; `maxH264*` carries the
        // same pair, so the seat reads one shape whichever codec the session negotiated.
        switch codec {
        case .h264, .hevc, .av1: ("3", "61")
        }
    }

    static func parseResolution(_ resolution: String?) -> (Int, Int) {
        guard let text = resolution?.trimmingCharacters(in: .whitespaces),
              let width = NvstRtspMessage.firstCapture(in: text, pattern: "^([0-9]+)\\s*[xX]\\s*[0-9]+$").flatMap(Int.init),
              let height = NvstRtspMessage.firstCapture(in: text, pattern: "^[0-9]+\\s*[xX]\\s*([0-9]+)$").flatMap(Int.init) else {
            return (1920, 1080)
        }
        return (width, height)
    }
}
