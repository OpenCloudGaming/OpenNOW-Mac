import Foundation

/// What the client contributes to ANNOUNCE: the ICE/DTLS bundle identity plus the ports of the
/// two sockets in the official cloud model (ICE/DTLS bundle + dedicated raw-SRTP Mjolnir video).
public struct NvstBundleReservation: Equatable, Sendable {
    public let bundlePort: UInt16
    public let mjolnirPort: UInt16
    /// Reserved only when audio is to arrive on its own socket rather than the bundle.
    public var audioPort: UInt16?
    public let localAddress: String?
    public let iceCredentials: NvstRtspIceCredentials?
    /// SHA-256 colon hex of the local DTLS certificate that owns the bundle socket.
    public let dtlsFingerprint: String?

    public init(bundlePort: UInt16,
                mjolnirPort: UInt16,
                audioPort: UInt16? = nil,
                localAddress: String? = nil,
                iceCredentials: NvstRtspIceCredentials? = nil,
                dtlsFingerprint: String? = nil) {
        self.bundlePort = bundlePort
        self.mjolnirPort = mjolnirPort
        self.audioPort = audioPort
        self.localAddress = localAddress
        self.iceCredentials = iceCredentials
        self.dtlsFingerprint = dtlsFingerprint
    }
}

/// Supplies the bundle/Mjolnir sockets before video SETUP so ANNOUNCE never races a rebind.
public protocol NvstBundleReserving: Sendable {
    func reserveBundle() async throws -> NvstBundleReservation

    /// Called after SETUP and before ANNOUNCE, once the negotiated remote identity is known. A
    /// bundle that needs the seat's fingerprint and ping-derived ufrag to come up (the real
    /// ICE/DTLS bundle does) reports its actual port and fingerprint here; returning nil keeps
    /// the values from `reserveBundle()`.
    func bundleIdentity(for handoff: NVSTVideoHandoff) async -> NvstBundleReservation?
}

public extension NvstBundleReserving {
    func bundleIdentity(for handoff: NVSTVideoHandoff) async -> NvstBundleReservation? { nil }
}

public enum NvstRtspNegotiationError: LocalizedError, Equatable, Sendable {
    case missingEndpoint
    case invalidEndpoint(String)
    case requestFailed(String, Int, String)
    case missingSessionHeader
    case missingVideoControl
    case missingAudioControl
    case missingControlStream
    case missingVideoPeer
    case missingIceCredentials
    case conflictingSrtpProfile(String, String)

    public var errorDescription: String? {
        switch self {
        case .missingEndpoint: "The session did not provide an rtsps:// NVST control endpoint."
        case .invalidEndpoint(let value): "Unparseable NVST control endpoint: \(value)"
        case .requestFailed(let method, let code, let text): "RTSP \(method) failed: \(code) \(text)"
        case .missingSessionHeader: "The DESCRIBE response carried no Session header."
        case .missingVideoControl: "DESCRIBE did not advertise a video media control URI."
        case .missingAudioControl: "DESCRIBE did not advertise an audio media control URI."
        case .missingControlStream: "DESCRIBE did not advertise the primary control/0 stream."
        case .missingVideoPeer: "SETUP returned no video peer (X-GS-ServerPort/source)."
        case .missingIceCredentials: "SETUP selected ping version 6 without the ICE credential set."
        case .conflictingSrtpProfile(let described, let setup): "DESCRIBE advertised \(described) but SETUP advertised \(setup)."
        }
    }
}

/// The negotiated NVST control session. Holding it keeps the seat's RTSP session alive; releasing
/// it TEARDOWNs and closes the control channel.
public struct NvstRtspSession: Sendable {
    public let endpoint: String
    public let sessionIdentifier: String
    public let handoff: NVSTVideoHandoff
    /// Remote ICE identity for the ICE/DTLS bundle (`pingPayload + 1`, or the ping string).
    public let remoteIceUsernameFragment: String?
    public let remoteDTLSFingerprint: String?
    public let hmacSeedPresent: Bool
    public let steps: [String]
    public let release: @Sendable (String) async -> Void
    /// Latest keepalive ping/pong round trip on the control connection, in milliseconds, or -1
    /// before the first pong. The WebSocket stays open for the whole session, so this is a live
    /// network-path measurement at the keepalive cadence.
    public let controlRoundTripMilliseconds: @Sendable () async -> Double
    /// Keepalive ping/pong counters for the diagnostic log.
    public let controlKeepAliveSummary: @Sendable () async -> String
}

public struct NvstRtspNegotiationInput: Sendable {
    public let sessionID: String
    public let rtspsEndpoints: [String]
    public let resolution: String?
    public let fps: Int?
    public let codec: String?
    /// Announced as `video[0].initialBitrateKbps` / `initialPeakBitrateKbps`.
    public let bitrateKbps: Int?
    /// The configured ceiling, announced as `vqos[0].bw.maximumBitrateKbps`.
    public let maximumBitrateKbps: Int?
    /// Server-side AI sharpen/denoise, announced as `x-nv-video[0].prefilterParams.*`. `mode` and
    /// `model` are captured, verified attribute names; `sharpness`/`denoise` map to the client's
    /// sliders but their wire key names (`sharpnessLevel`/`denoiseLevel`) are inferred from the
    /// same param family, not confirmed against a live capture the way the rest of this file is.
    public let prefilterMode: Int?
    public let prefilterSharpness: Int?
    public let prefilterDenoise: Int?
    public let prefilterModel: Int?
    public let timeout: Duration
    /// `general.rtcpOnSctp`. True routes RTCP feedback onto the bundle's
    /// `rtcp_on_sctp_private` data channel; false keeps it as SRTCP on the Mjolnir socket,
    /// which is the only option until the ICE/DTLS bundle is up.
    public let rtcpOnSctp: Bool
    /// Ignores the seat's `general.nativeRtcOnBundlePort` and negotiates the pre-bundle shape:
    /// SETUP with a real `X-GS-ClientPort`, ANNOUNCE with real `clientPorts.*`, and no
    /// `nativeRtcOnBundlePort`. The legacy path needs no DTLS at all, so it isolates "video needs
    /// the bundle" from "video needs something else".
    public let forcesLegacyPath: Bool
    /// The seat's one-way-delay rate controller stays on by default; its OWD evidence rides the
    /// `0x207` QoS reports this client sends. `OPN_NVST_OWD_CC=0` disables it.
    public let disablesOwdCongestionControl: Bool
    /// `OPN_NVST_ANNOUNCE_EXTENDED=1`: adds the official client's encoder tuning and timers.
    public let announcesExtendedSettings: Bool
    /// `OPN_NVST_ANNOUNCE_ECHO_OFFER=1`: lets the seat's offer override our announced values.
    public let echoesOfferedAttributes: Bool

    public init(sessionID: String,
                rtspsEndpoints: [String],
                resolution: String? = nil,
                fps: Int? = nil,
                codec: String? = nil,
                bitrateKbps: Int? = nil,
                maximumBitrateKbps: Int? = nil,
                prefilterMode: Int? = nil,
                prefilterSharpness: Int? = nil,
                prefilterDenoise: Int? = nil,
                prefilterModel: Int? = nil,
                timeout: Duration = .seconds(20),
                rtcpOnSctp: Bool = true,
                forcesLegacyPath: Bool = false,
                disablesOwdCongestionControl: Bool = true,
                announcesExtendedSettings: Bool = false,
                echoesOfferedAttributes: Bool = false) {
        self.disablesOwdCongestionControl = disablesOwdCongestionControl
        self.announcesExtendedSettings = announcesExtendedSettings
        self.echoesOfferedAttributes = echoesOfferedAttributes
        self.sessionID = sessionID
        self.rtspsEndpoints = rtspsEndpoints
        self.resolution = resolution
        self.bitrateKbps = bitrateKbps
        self.maximumBitrateKbps = maximumBitrateKbps
        self.prefilterMode = prefilterMode
        self.prefilterSharpness = prefilterSharpness
        self.prefilterDenoise = prefilterDenoise
        self.prefilterModel = prefilterModel
        self.fps = fps
        self.codec = codec
        self.timeout = timeout
        self.rtcpOnSctp = rtcpOnSctp
        self.forcesLegacyPath = forcesLegacyPath
    }
}

/// Drives the classic NVST handshake — OPTIONS → DESCRIBE → SETUP → ANNOUNCE → PLAY — and turns
/// its answers into the `NVSTVideoHandoff` the Bifrost-free receiver consumes.
///
/// The handoff is *not* delivered by signaling: the client derives it here, and even generates
/// the video SRTP master key itself (`runtime.encryptionKey` in ANNOUNCE). Independently
/// observed; OpenNOW's MIT `opennow-stable/.../nvstRtsp/probe.ts` documents the same flow.
public struct NvstRtspNegotiator: Sendable {
    /// Video SETUP is ready: the Mjolnir raw-SRTP receiver should start reading now, before
    /// ANNOUNCE, exactly as official Bifrost arms `MjolnirVideoReceiver` first.
    public typealias VideoReadyHandler = @Sendable (NVSTVideoHandoff) async throws -> Void
    /// ANNOUNCE accepted: bring up ICE/DTLS on the bundle before PLAY.
    public typealias AnnounceReadyHandler = @Sendable (NVSTVideoHandoff) async throws -> Void

    private let reserver: any NvstBundleReserving
    private let logger: (@Sendable (String) -> Void)?
    private let connectionFactory: @Sendable (NvstRtspEndpoints.Target, Duration, (@Sendable (String) -> Void)?) -> any NvstRtspControlChannel

    public init(reserver: any NvstBundleReserving,
                logger: (@Sendable (String) -> Void)? = nil,
                connectionFactory: @escaping @Sendable (NvstRtspEndpoints.Target, Duration, (@Sendable (String) -> Void)?) -> any NvstRtspControlChannel = { target, timeout, logger in
                    NvstRtspConnection(target: target, timeout: timeout, logger: logger)
                }) {
        self.reserver = reserver
        self.logger = logger
        self.connectionFactory = connectionFactory
    }

    /// Walks the advertised control endpoints until one completes the handshake. A seat can
    /// advertise an endpoint it does not serve, and the last candidate is usually the assumed
    /// `:322` default, so a single failure must not end the attempt.
    public func negotiate(_ input: NvstRtspNegotiationInput,
                          onVideoReady: VideoReadyHandler? = nil,
                          onAnnounceReady: AnnounceReadyHandler? = nil) async throws -> NvstRtspSession {
        let candidates = NvstRtspEndpoints.candidates(input.rtspsEndpoints)
        guard !candidates.isEmpty else { throw NvstRtspNegotiationError.missingEndpoint }
        var bestError: Error = NvstRtspNegotiationError.missingEndpoint
        var bestProgress = -1
        for endpoint in candidates {
            do {
                return try await negotiate(endpoint: endpoint, input: input, onVideoReady: onVideoReady, onAnnounceReady: onAnnounceReady)
            } catch {
                logger?("NVST control endpoint \(endpoint) failed: \(error.localizedDescription)")
                // Report the candidate that got furthest, not the last one tried: a media port
                // failing OPTIONS says nothing, while the control port failing SETUP is the story.
                let progress = Self.progress(of: error)
                if progress > bestProgress {
                    bestProgress = progress
                    bestError = error
                }
            }
        }
        throw bestError
    }

    private func negotiate(endpoint: String,
                           input: NvstRtspNegotiationInput,
                           onVideoReady: VideoReadyHandler?,
                           onAnnounceReady: AnnounceReadyHandler?) async throws -> NvstRtspSession {
        guard let target = NvstRtspEndpoints.parse(endpoint: endpoint) else {
            throw NvstRtspNegotiationError.invalidEndpoint(endpoint)
        }

        var steps: [String] = []
        let connection = connectionFactory(target, input.timeout, logger)
        do {
            try await connection.connect(sessionID: input.sessionID)
            steps.append("wss-open")

            let requestURI = target.requestURI
            var common: [(String, String)] = [("X-GS-Version", "14.2"), ("Host", "\(target.host):\(target.port)")]
            let trimmedSessionID = input.sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedSessionID.isEmpty {
                common.append(("x-nv-sessionid", trimmedSessionID))
            }

            let options = try await connection.request(method: "OPTIONS", uri: requestURI, headers: common)
            try expectOK("OPTIONS", options)
            steps.append("options")

            // The seat keys the modern ping/HMAC media context off `x-nv-abtesting`; omitting it
            // is treated as a legacy client.
            let describe = try await connection.request(
                method: "DESCRIBE",
                uri: requestURI,
                headers: common + [("Accept", "application/sdp"), ("x-nv-abtesting", "2")]
            )
            try expectOK("DESCRIBE", describe)
            steps.append("describe")
            guard var sessionIdentifier = describe.header("session")?.split(separator: ";").first.map({ String($0).trimmingCharacters(in: .whitespaces) }),
                  !sessionIdentifier.isEmpty else {
                throw NvstRtspNegotiationError.missingSessionHeader
            }

            let body = describe.body
            guard let videoControl = NvstRtspSdp.mediaControl(body, mediaType: "video") else {
                throw NvstRtspNegotiationError.missingVideoControl
            }
            guard NvstRtspSdp.mediaControl(body, mediaType: "audio") != nil else {
                throw NvstRtspNegotiationError.missingAudioControl
            }
            let controls = NvstRtspSdp.allMediaControls(body)
            guard NvstRtspSdp.primaryControlStream(controls) != nil else {
                throw NvstRtspNegotiationError.missingControlStream
            }

            let hmacSeed = NvstRtspSdp.hmacSeed(body)
            // The seat answers DESCRIBE with its whole resolved configuration — thousands of
            // attributes naming every rate-control, pacing and dynamic-fps decision it made for
            // this session. It is the only place the seat states its own settings, so it is worth
            // keeping when a run needs explaining.
            let describedIce = NvstRtspSdp.iceCredentials(body)
            let describedProfile = NvstRtspSdp.advertisedSrtpProfile(sdp: body)
            let describedKey = NvstRtspSdp.runtimeEncryptionKey(body)
            let remoteFingerprint = NvstRtspSdp.attribute(body, "general.dtlsFingerprintV2")
                ?? NvstRtspSdp.attribute(body, "general.dtlsFingerprint")
            let describedPingVersion = NvstRtspSdp.attribute(body, "general.pingVersion")
            let disablePlay = NvstRtspSdp.attribute(body, "general.disablePlay")
            let advertisesCloudPath = NvstRtspSdp.attribute(body, "general.nativeRtcOnBundlePort") == "1"
            let officialCloudPath = advertisesCloudPath && !input.forcesLegacyPath

            // Official Bifrost ALWAYS client-generates `runtime.encryptionKey` and sends it in
            // ANNOUNCE, even when a DTLS fingerprint is present: the video SRTP socket is keyed
            // by this runtime key, not by DTLS-SRTP. Skipping it means the seat never keys video.
            let encryptionKey = describedKey ?? NvstRtspSdp.generateClientEncryptionKey()
            logger?("NVST DESCRIBE ok (session=\(sessionIdentifier), videoControl=\(videoControl), hmac=\(hmacSeed != nil), describedKey=\(describedKey != nil), official=\(officialCloudPath)\(advertisesCloudPath && input.forcesLegacyPath ? " (cloud path advertised, legacy forced)" : ""), pingVersion=\(describedPingVersion ?? "absent"), remoteFingerprintBytes=\(remoteFingerprint?.count ?? 0))")

            let reservation = try await reserver.reserveBundle()
            let videoSetupCandidates = NvstRtspEndpoints.videoSetupURICandidates(
                control: videoControl,
                base: requestURI,
                officialCloudPath: officialCloudPath
            )

            // The seat only returns a hex `X-Nv-Ping-Payload` (the modern NATT/ICE identity) when
            // SETUP advertises the ping version; otherwise it falls back to the literal "PING"
            // keepalive and never arms the media relay to answer STUN.
            let baseSetupHeaders = common + [("Session", sessionIdentifier), ("x-nv-ping", describedPingVersion ?? "6")]
            let legacyTransport = "unicast;X-GS-ClientPort=\(reservation.mjolnirPort)-\(Int(reservation.mjolnirPort) + 1)"
            // Transport forms to try, in order. The official cloud path sends a literally empty
            // Transport; the legacy form is the fallback so one run separates "wrong request-URI"
            // from "wrong Transport".
            let transportForms: [String] = officialCloudPath ? ["", legacyTransport] : [legacyTransport, ""]
            // Walk the request-URI forms (then the Transport forms) until one is accepted: a live
            // seat answered 400 to a resolved absolute URI while accepting OPTIONS and DESCRIBE on
            // the same connection, and the accepted form is advertised nowhere.
            var setup: NvstRtspResponse?
            var videoSetupURI = videoSetupCandidates[0]
            var acceptedTransport = transportForms[0]
            var lastRejection = "none"
            outer: for transport in transportForms {
                for candidate in videoSetupCandidates {
                    let response = try await connection.request(
                        method: "SETUP",
                        uri: candidate,
                        headers: baseSetupHeaders + [("Transport", transport)]
                    )
                    if response.statusCode == 200 {
                        setup = response
                        videoSetupURI = candidate
                        acceptedTransport = transport
                        break outer
                    }
                    let detail = response.body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)
                    lastRejection = "\(response.statusCode) \(response.statusText)"
                    logger?("NVST SETUP rejected uri=\(candidate) transport=\(transport.isEmpty ? "<empty>" : transport) status=\(lastRejection)\(detail.isEmpty ? "" : " body=\(detail)")")
                }
            }
            guard let setup else {
                throw NvstRtspNegotiationError.requestFailed(
                    "SETUP",
                    400,
                    "last=\(lastRejection); tried \(videoSetupCandidates.count) request-URI forms x \(transportForms.count) Transport forms"
                )
            }
            steps.append("setup-video")

            // Audio has no SETUP in any capture of the official client — it takes audio on the
            // bundle instead — and the DESCRIBE offers `m=audio 0`, a port of zero, which means the
            // stream is inactive. Asking for it explicitly is the only route to receiving audio on
            // a socket we own: announcing `clientPorts.audio` alone made the seat stop sending
            // audio on the bundle without sending any to us. Strictly opt-in, and a refusal is
            // logged rather than fatal, because the working configuration does not need it.
            var audioPeerPort: UInt16?
            if let audioPort = reservation.audioPort {
                var audioAccepted = false
                for candidate in NvstRtspEndpoints.videoSetupURICandidates(
                    control: "streamid=audio/0", base: requestURI, officialCloudPath: officialCloudPath
                ) {
                    let response = try await connection.request(
                        method: "SETUP",
                        uri: candidate,
                        headers: baseSetupHeaders
                            + [("Transport", "unicast;X-GS-ClientPort=\(audioPort)-\(audioPort + 1)")]
                    )
                    let transport = response.header("transport") ?? ""
                    logger?("NVST audio SETUP uri=\(candidate) status=\(response.statusCode) transport=\(transport.isEmpty ? "<empty>" : transport)")
                    if response.statusCode == 200 {
                        audioAccepted = true
                        // The seat names the port it will send audio from, and the NAT mapping has
                        // to be opened towards that port rather than the video one.
                        audioPeerPort = NvstRtspMessage.extractVideoPeer(transport)?.port
                        steps.append("setup-audio")
                        break
                    }
                }
                if !audioAccepted { logger?("NVST audio SETUP was refused; audio has no socket of its own") }
            }
            if let refreshed = setup.header("session")?.split(separator: ";").first.map({ String($0).trimmingCharacters(in: .whitespaces) }), !refreshed.isEmpty {
                sessionIdentifier = refreshed
            }

            let setupProfile = NvstRtspSdp.advertisedSrtpProfile(headers: setup.headers)
            if let describedProfile, let setupProfile, describedProfile != setupProfile {
                throw NvstRtspNegotiationError.conflictingSrtpProfile(describedProfile.rawValue, setupProfile.rawValue)
            }
            let srtpProfile = setupProfile ?? describedProfile ?? .aeadAes256Gcm8
            guard let videoPeer = NvstRtspMessage.extractVideoPeer(setup.header("transport")) else {
                throw NvstRtspNegotiationError.missingVideoPeer
            }
            let pingPayload = setup.header("x-nv-ping-payload")
            let pingVersion = setup.header("x-nv-ping").flatMap(Int.init)
            if pingVersion == 6, describedIce == nil || pingPayload == nil {
                throw NvstRtspNegotiationError.missingIceCredentials
            }

            let remoteUfrag = NvstRtspEndpoints.resolveIceRemoteUfrag(
                pingPayload: pingPayload,
                describeUfrag: describedIce?.usernameFragment,
                pingVersion: pingVersion
            )
            let localIce = reservation.iceCredentials ?? (describedIce != nil ? NvstRtspSdp.generateIceCredentials() : nil)
            let iceCredentials: NVSTHandoffIceCredentials? = {
                guard let localIce, let remoteUfrag, let remotePassword = describedIce?.password else { return nil }
                return NVSTHandoffIceCredentials(
                    localUsernameFragment: localIce.usernameFragment,
                    localPassword: localIce.password,
                    remoteUsernameFragment: remoteUfrag,
                    remotePassword: remotePassword,
                    remoteDTLSFingerprint: remoteFingerprint
                )
            }()

            var handoff = NVSTVideoHandoff(
                clientUDPPort: reservation.mjolnirPort,
                videoPeerIP: videoPeer.ip,
                videoPeerPort: videoPeer.port,
                srtpProfile: srtpProfile,
                srtpAESKey: try NVSTVideoHandoffParser.decodeFixedHex(encryptionKey.aesKeyHex, field: "runtime.encryptionKey", expectedLength: srtpProfile.masterKeyLength),
                srtpSalt: try NVSTVideoHandoffParser.decodeFixedHex(NvstRtspSdp.srtpSaltHex(keyID: encryptionKey.keyID), field: "srtpSaltHex", expectedLength: srtpProfile.masterSaltLength),
                codec: NVSTVideoCodec.parse(input.codec ?? "H264") ?? .h264,
                rtpPayloadType: 96,
                rtpSSRC: 0,
                reorderWindowPackets: 32,
                maxAccessUnitBytes: 2 * 1024 * 1024,
                // The handshake needs far longer than the 5 s media idle default.
                timeoutMilliseconds: 60_000,
                pingVersion: pingVersion.map { UInt8(clamping: $0) },
                pingPayload: pingPayload ?? "PING",
                mjolnirUDPPort: reservation.mjolnirPort,
                iceCredentials: iceCredentials
            )
            handoff.audioPeerPort = audioPeerPort
            logger?("NVST SETUP ok uri=\(videoSetupURI) (official=\(officialCloudPath), bundlePort=\(reservation.bundlePort), mjolnirPort=\(reservation.mjolnirPort), peer=\(videoPeer.ip):\(videoPeer.port), srtpProfile=\(srtpProfile.rawValue), pingVersion=\(pingVersion.map(String.init) ?? "legacy"), pingPayloadBytes=\(pingPayload?.utf8.count ?? 0), iceRemote=\(remoteUfrag ?? "absent"), transport=\(acceptedTransport.isEmpty ? "<empty>" : acceptedTransport), responseHeaders=\(setup.headers.keys.sorted().joined(separator: ",")))")

            if let onVideoReady {
                try await onVideoReady(handoff)
                steps.append("native-receive-armed")
            }

            // The bundle can only be brought up now: it needs SETUP's ping payload for the remote
            // ufrag and DESCRIBE's fingerprint. Its real port and fingerprint go into ANNOUNCE.
            let bundleIdentity = await reserver.bundleIdentity(for: handoff)
            let announcedBundlePort = bundleIdentity?.bundlePort ?? reservation.bundlePort
            let announcedFingerprint = bundleIdentity?.dtlsFingerprint ?? reservation.dtlsFingerprint
            let announcedLocalAddress = bundleIdentity?.localAddress ?? reservation.localAddress
            if bundleIdentity != nil {
                logger?("NVST bundle identity ready for ANNOUNCE (port=\(announcedBundlePort), fingerprintBytes=\(announcedFingerprint?.count ?? 0))")
            }

            let announceOptions = NvstRtspSdp.AnnounceOptions(
                resolution: input.resolution,
                fps: input.fps,
                prefilterMode: input.prefilterMode,
                prefilterSharpness: input.prefilterSharpness,
                prefilterDenoise: input.prefilterDenoise,
                prefilterModel: input.prefilterModel,
                encryptionKey: encryptionKey,
                iceCredentials: localIce,
                videoPort: videoPeer.port,
                clientBundlePort: officialCloudPath ? announcedBundlePort : nil,
                // Legacy path: video arrives on the socket SETUP advertised, not the bundle.
                clientVideoPort: officialCloudPath ? nil : reservation.mjolnirPort,
                clientAudioPort: reservation.audioPort,
                localAddress: announcedLocalAddress ?? NvstRoutedIPv4.discover(),
                dtlsFingerprint: announcedFingerprint,
                officialCloudPath: officialCloudPath,
                // The bundle opens `rtcp_on_sctp_private` and carries RR/PLI once it is up; with no
                // bundle the feedback plane stays on the Mjolnir socket's SRTCP instead.
                // The official client announces nothing here, and claiming RTCP-over-SCTP without
                // a feedback channel starves the seat of receiver reports.
                rtcpOnSctp: input.rtcpOnSctp,
                // Audio leaves the bundle exactly when a socket has been reserved for it.
                carriesAudioOnBundle: reservation.audioPort == nil,
                // The seat states its own encoder preferences in DESCRIBE; the answer echoes them
                // rather than contradicting them with a hardcoded default.
                offeredAttributes: NvstRtspSdp.offeredAttributes(body),
                codec: NVSTVideoCodec.parse(input.codec ?? "H264"),
                bitrateKbps: input.bitrateKbps,
                maximumBitrateKbps: input.maximumBitrateKbps,
                disablesOwdCongestionControl: input.disablesOwdCongestionControl,
                announcesExtendedSettings: input.announcesExtendedSettings,
                echoesOfferedAttributes: input.echoesOfferedAttributes
            )
            let announceBody = NvstRtspSdp.buildAnnounceSdp(announceOptions)
            // The ANNOUNCE is the one message whose content we cannot check from the seat's reply:
            // it answers 200 to bodies it then cannot act on. Logging it lets the whole attribute
            // set be diffed against the official client's capture without spending a live run.
            let announceLines = announceBody.components(separatedBy: "\r\n").filter { !$0.isEmpty }
            logger?("NVST ANNOUNCE sdp lines=\(announceLines.count)")
            for line in announceLines { logger?("NVST ANNOUNCE sdp \(NvstRtspSdp.redactedForLog(line))") }
            let announce = try await connection.request(
                method: "ANNOUNCE",
                uri: officialCloudPath ? requestURI : "/",
                headers: common + [("Session", sessionIdentifier), ("Content-Type", "application/sdp")],
                body: announceBody
            )
            try expectOK("ANNOUNCE", announce)
            steps.append("announce")
            // Report what ANNOUNCE actually carried, not the pre-bundle placeholders.
            logger?("NVST ANNOUNCE ok (bundlePort=\(announcedBundlePort), localIce=\(localIce != nil), dtlsFingerprintBytes=\(announcedFingerprint?.count ?? 0), rtcpOnSctp=\(announceOptions.rtcpOnSctp ? 1 : 0))")

            if let onAnnounceReady {
                try await onAnnounceReady(handoff)
                steps.append("native-announce-armed")
            }

            if disablePlay == "0" {
                let play = try? await connection.request(method: "PLAY", uri: officialCloudPath ? requestURI : "/", headers: common + [("Session", sessionIdentifier)])
                switch play?.statusCode {
                case 200:
                    steps.append("play")
                case 455:
                    // Bifrost ANNOUNCE-only seats answer 455; media already flows.
                    steps.append("play-455")
                case .some(let code):
                    steps.append("play-failed-\(code)")
                case nil:
                    steps.append("play-timeout")
                }
            } else {
                steps.append("play-skipped")
            }

            // The control connection stays up for the whole session, and the official client pings
            // it every couple of seconds. Start that now that the handshake is done.
            await connection.startKeepAlive()

            let releaseIdentifier = sessionIdentifier
            let releaseURI = requestURI
            let releaseHeaders = common
            let capturedSteps = steps
            return NvstRtspSession(
                endpoint: endpoint,
                sessionIdentifier: sessionIdentifier,
                handoff: handoff,
                remoteIceUsernameFragment: remoteUfrag,
                remoteDTLSFingerprint: remoteFingerprint,
                hmacSeedPresent: hmacSeed != nil,
                steps: capturedSteps,
                release: { reason in
                    _ = try? await connection.request(method: "TEARDOWN", uri: releaseURI, headers: releaseHeaders + [("Session", releaseIdentifier)])
                    await connection.close()
                    logger?("NVST RTSPS control session released (\(reason))")
                },
                controlRoundTripMilliseconds: { await connection.measuredRoundTripMilliseconds() },
                controlKeepAliveSummary: { await connection.keepAliveSummary() }
            )
        } catch {
            await connection.close()
            throw error
        }
    }

    /// How far through the handshake an error got, so the most informative failure survives.
    private static func progress(of error: Error) -> Int {
        guard let negotiation = error as? NvstRtspNegotiationError else { return 0 }
        switch negotiation {
        case .missingEndpoint, .invalidEndpoint: return 0
        case .requestFailed(let method, _, _):
            switch method.uppercased() {
            case "OPTIONS": return 1
            case "DESCRIBE": return 2
            case "SETUP": return 5
            case "ANNOUNCE": return 7
            default: return 8
            }
        case .missingSessionHeader: return 3
        case .missingVideoControl, .missingAudioControl, .missingControlStream: return 4
        case .missingVideoPeer, .missingIceCredentials, .conflictingSrtpProfile: return 6
        }
    }

    private func expectOK(_ method: String, _ response: NvstRtspResponse) throws {
        guard response.statusCode == 200 else {
            throw NvstRtspNegotiationError.requestFailed(method, response.statusCode, response.statusText)
        }
    }
}
