//  Bringing the ICE/DTLS/SCTP bundle up and tearing it down, plus the feedback and control channels
//  it opens.
//

import Foundation
@preconcurrency import WebRTC

extension NvstWebRtcBundle {
    // MARK: - Bring-up

    /// The peer-connection configuration this bundle needs. Everything is known up front, so no
    /// STUN/TURN discovery: the only candidate that matters is the host one, and the peer is a
    /// literal address from SETUP.
    static func bundleConfiguration() -> RTCConfiguration {
        let configuration = RTCConfiguration()
        // Everything is known up front, so no STUN/TURN discovery: the only candidate that matters
        // is the host one, and the peer is a literal address from SETUP.
        configuration.iceServers = []
        configuration.sdpSemantics = .unifiedPlan
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require
        configuration.continualGatheringPolicy = .gatherOnce
        // The seat is not an ICE agent: it is Bifrost's `NattHolePunch::HandleStun`, a minimal
        // responder that answers a bare 76-byte USERNAME/MESSAGE-INTEGRITY/FINGERPRINT request and
        // ignores libwebrtc's 104-byte one (measured: 3076 answers to bare STUN, 1 to libwebrtc's).
        // So consent freshness can never be satisfied here, and libwebrtc's default 2.5 s timeouts
        // tear down a DTLS/SCTP association that is otherwise healthy — captured completing in
        // 111 ms and dying 363 ms later. Disabling the liveness policy keeps the association up;
        // the NAT mapping stays open because libwebrtc keeps sending its own checks regardless.
        // The seat sends 5 ms Opus frames at ~200 packets a second — twice the rate NetEq's
        // defaults are tuned for, and its own jitter-buffer settings in the seat's SDP
        // (`audio.jbConfig.initialThreshold:80`, `maxThreshold:200`) are counted in packets on that
        // same 5 ms grid. A 50-packet default buffer is only 250 ms at this rate, so it is raised to
        // match what the seat expects to be buffered.
        configuration.audioJitterBufferMaxPackets = 200
        configuration.audioJitterBufferFastAccelerate = true
        // Tried (2026-09-05): NetEq's delay-manager quantile through the
        // `WebRTC-Audio-NetEqDelayManagerConfig` field trial, to shorten the ~50 ms audio sat in
        // the jitter buffer on a 5 ms link. Four sessions: default 0.95 → 53 ms; 0.9 → 37 ms once,
        // 55 ms with 123 concealed samples the next time; 0.8 → 60 ms. Dwell moves 36–61 ms from
        // seat to seat on its own and the knob did not move it predictably, so it is not set. The
        // HUD's A/V row and the `audioJb=` log field remain the measurement.
        let neverExpires = 24 * 60 * 60 * 1000
        configuration.iceConnectionReceivingTimeout = Int32(neverExpires)
        configuration.iceUnwritableTimeout = NSNumber(value: neverExpires)
        configuration.iceInactiveTimeout = NSNumber(value: neverExpires)
        configuration.iceUnwritableMinChecks = NSNumber(value: Int32.max)
        return configuration
    }

    /// Creates the peer connection, applies the synthesized remote offer, answers, and returns the
    /// identity ANNOUNCE has to carry. ICE cannot succeed until ANNOUNCE lands, so this waits only
    /// for local gathering.
    ///
    /// Supplying `microphone` adds the mic send section to the synthesized offer and attaches the
    /// local sender before the answer is created: NVST has no renegotiation, so a mic m-line that
    /// is not in this first answer can never appear for this session.
    public func prepare(microphone: MicrophoneSetup? = nil) async throws -> Identity {
        guard let microphone else { return try await bringUp(includesMicrophone: false, microphone: nil) }
        do {
            return try await bringUp(includesMicrophone: true, microphone: microphone)
        } catch BundleError.microphoneNotArmed {
            logger?("NVST bundle rebuilding without the mic section: an answered mic m-line with no usable sender makes the seat withhold game audio")
            return try await bringUp(includesMicrophone: false, microphone: nil)
        }
    }

    /// One bring-up pass. `includesMicrophone` decides whether the synthesized offer carries the
    /// mid-2 section; when it does but the mic sender cannot be armed before the answer, the
    /// pass throws `microphoneNotArmed` and the caller rebuilds without the section — live
    /// sessions showed a 3-m-line answer with a dead mid-2 (even `inactive`, nothing sent)
    /// makes the seat withhold game audio, whatever the ANNOUNCE says.
    private func bringUp(includesMicrophone: Bool, microphone: MicrophoneSetup?) async throws -> Identity {
        guard let credentials = handoff.iceCredentials else { throw BundleError.missingRemoteCredentials }
        guard let remoteFingerprint = credentials.remoteDTLSFingerprint, !remoteFingerprint.isEmpty else {
            throw BundleError.missingRemoteFingerprint
        }

        startWebRtcLoggingIfRequested()
        let factory = makePeerConnectionFactory()
        let configuration = Self.bundleConfiguration()
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = factory.peerConnection(with: configuration, constraints: constraints, delegate: self) else {
            throw BundleError.factoryUnavailable
        }
        store(factory: factory, connection: connection)

        let offer = Self.synthesizedRemoteOffer(
            remoteUsernameFragment: credentials.remoteUsernameFragment,
            remotePassword: credentials.remotePassword,
            remoteFingerprint: remoteFingerprint,
            peerIP: handoff.videoPeerIP,
            peerPort: handoff.videoPeerPort,
            includesMicrophone: includesMicrophone
        )
        try await setRemoteDescription(connection, RTCSessionDescription(type: .offer, sdp: offer))

        // At least one data channel has to exist before the answer, or the answer carries no SCTP
        // section at all and the bundle has nothing to negotiate.
        _ = createFeedbackChannels(on: connection, minimum: 1)

        // The mic sender must exist before the answer is created, or the sendonly mid-2 section
        // the seat's recvonly mic m-line asks for never makes it into the answer.
        if let microphone {
            attachMicrophone(to: connection, factory: factory, setup: microphone)
            guard microphoneNegotiation.negotiated else {
                connection.close()
                throw BundleError.microphoneNotArmed
            }
        }

        let answer = try await createAnswer(connection, constraints: constraints)
        let (forced, usesOfficialCredentials) = try await applyLocalAnswer(
            answer,
            connection: connection,
            credentials: credentials
        )

        let candidates = try await waitForHostCandidates()
        let hosts = candidates.compactMap { Self.hostAddress(fromCandidateLine: $0.sdp) }
        logger?("NVST bundle gathered host candidates: \(hosts.map { "\($0.address):\($0.port)" }.joined(separator: ", "))")
        guard let host = Self.preferredHost(among: hosts, matching: preferredLocalAddress) else {
            throw BundleError.noHostCandidate
        }
        if host.address != preferredLocalAddress {
            logger?("NVST bundle announcing \(host.address):\(host.port), which is not the routed address \(preferredLocalAddress ?? "unknown")")
        }
        return try preparedIdentity(
            connection: connection,
            fallbackSdp: forced,
            host: host,
            usesOfficialCredentials: usesOfficialCredentials)
    }

    /// Forces the official ICE credentials into the created answer and sets it as the local
    /// description, munging in the deterministic mic sender SSRC first when the mic negotiated.
    /// Bifrost length-checks ICE credentials, so this forces the official 4/22 pair libwebrtc
    /// gives no API for; if it refuses the munged answer, this falls back to libwebrtc's own
    /// credentials and says so — the seat's behaviour then tells us whether that check is real.
    private func applyLocalAnswer(
        _ answer: RTCSessionDescription,
        connection: RTCPeerConnection,
        credentials: NVSTHandoffIceCredentials
    ) async throws -> (sdp: String, usesOfficialCredentials: Bool) {
        var forced = Self.replacingIceCredentials(
            in: answer.sdp,
            usernameFragment: credentials.localUsernameFragment,
            password: credentials.localPassword
        )
        if microphoneNegotiation.negotiated {
            // The seat binds the bundle mic by the vendor's deterministic SSRC; libwebrtc takes the
            // sender SSRC from the `a=ssrc` lines of the local description, so rewrite them here,
            // before `setLocalDescription` builds the send stream.
            let generated = Self.microphoneSenderSsrc(inSdp: forced)
            forced = Self.replacingMicrophoneSenderSsrc(in: forced, with: Self.nvstMicrophoneSenderSsrc)
            logger?("NVST bundle mic answer SSRC rewritten \(generated.map(String.init) ?? "none") -> \(Self.nvstMicrophoneSenderSsrc)")
        }
        var usesOfficialCredentials = true
        do {
            try await setLocalDescription(connection, RTCSessionDescription(type: .answer, sdp: forced))
        } catch {
            logger?("NVST bundle rejected the official ICE credentials (\(error.localizedDescription)); keeping the generated pair")
            usesOfficialCredentials = false
            try await setLocalDescription(connection, answer)
        }
        return (forced, usesOfficialCredentials)
    }

    /// Reads what the answer actually negotiated — the fingerprint ANNOUNCE carries, a per-m-line
    /// summary that proves each section's direction, and the mic sender SSRC — and packages the
    /// identity ANNOUNCE has to carry.
    func preparedIdentity(connection: RTCPeerConnection,
                          fallbackSdp: String,
                          host: (address: String, port: UInt16),
                          usesOfficialCredentials: Bool) throws -> Identity {
        let localDescription = connection.localDescription?.sdp ?? fallbackSdp
        guard let fingerprint = Self.fingerprint(inSdp: localDescription) else {
            throw BundleError.missingLocalFingerprint
        }
        logger?("NVST bundle answer media: \(Self.mediaLineSummary(inSdp: localDescription))")
        readMicrophoneSenderSsrc(inSdp: localDescription)
        if let sender = lock.withLock({ microphoneSender }) {
            let encodings = sender.parameters.encodings
            logger?("NVST bundle mic sender post-answer: encodings=\(encodings.count) ssrc=\(encodings.first?.ssrc.map(String.init) ?? "none")")
        }
        if microphoneNegotiation.negotiated {
            // Both readbacks must agree on the deterministic SSRC: the local description libwebrtc
            // kept, and the encoding the sender reports now that negotiation populated it. A mic
            // stream under any other SSRC makes the seat withhold game audio, and so does a
            // 3-m-line answer with a dead mid 2 — so the whole bundle is rebuilt without the mic
            // section rather than retracting the flag on this connection.
            let announced = microphoneNegotiation.senderSsrc
            let encodingSsrc = lock.withLock { microphoneSender }?.parameters.encodings.first?.ssrc?.uint32Value
            guard announced == Self.nvstMicrophoneSenderSsrc, encodingSsrc == Self.nvstMicrophoneSenderSsrc else {
                logger?("NVST bundle mic SSRC readback answer=\(announced.map(String.init) ?? "none") encoding=\(encodingSsrc.map(String.init) ?? "none"), expected \(Self.nvstMicrophoneSenderSsrc); rebuilding without the mic section")
                lock.withLock { microphoneNegotiated = false }
                connection.close()
                throw BundleError.microphoneNotArmed
            }
        }
        let microphoneState = microphoneNegotiation
        logger?("NVST bundle prepared (port=\(host.port), localAddress=\(host.address), fingerprintBytes=\(fingerprint.count), officialIce=\(usesOfficialCredentials), setup=\(Self.setupRole(inSdp: localDescription) ?? "absent"), microphone=\(microphoneState.negotiated), micSsrc=\(microphoneState.senderSsrc.map(String.init) ?? "pending"))")
        return Identity(
            bundlePort: host.port,
            localAddress: host.address,
            dtlsFingerprint: fingerprint,
            usesOfficialIceCredentials: usesOfficialCredentials
        )
    }

    /// Creates the local mic source and track and attaches them to the transceiver the
    /// synthesized offer's recvonly mic m-line already reserved at mid 2 when it was applied as
    /// the remote description. Attaching to *that* transceiver is what makes the answer sendonly
    /// with the sender SSRC ANNOUNCE advertises; `connection.add` instead creates an orphan
    /// transceiver that cannot appear in this first answer, and mid 2 is answered `inactive` —
    /// which is exactly the shape a live seat then refused to arm any media for (no video, no
    /// audio, `tx=0`). `streamIds: ["mic"]` matches the msid the seat's own SDP history
    /// recognizes. A failed attach leaves `microphoneNegotiated` false, which keeps ANNOUNCE at
    /// `rtcMicOnNativeBundle:0` — the flag always describes the answer that really exists.
    func attachMicrophone(to connection: RTCPeerConnection, factory: RTCPeerConnectionFactory, setup: MicrophoneSetup) {
        // The synthesized offer carries the mic m-line at mid 2 whenever this runs; two audio
        // transceivers (downlink + mic) is the shape that makes a fallback unambiguous — grabbing
        // the only audio transceiver would corrupt the game-audio downlink instead.
        let audioTransceivers = connection.transceivers.filter { $0.mediaType == .audio }
        guard let transceiver = connection.transceivers.first(where: { $0.mid == "2" })
            ?? (audioTransceivers.count >= 2 ? audioTransceivers.last : nil) else {
            logger?("NVST bundle found no microphone transceiver; the session will run without mic")
            return
        }
        let source = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        source.volume = setup.volume
        let track = factory.audioTrack(with: source, trackId: "opennow-nvst-microphone")
        track.isEnabled = setup.initiallyEnabled
        transceiver.sender.track = track
        transceiver.sender.streamIds = ["mic"]
        // The SSRC is forced later, by rewriting the answer's `a=ssrc` lines before
        // `setLocalDescription` (`replacingMicrophoneSenderSsrc`); `preparedIdentity` then reads
        // it back and rebuilds without the mic section if libwebrtc kept its own value.
        // Void-returning ObjC signature: no Swift `throws` conversion, the error comes back
        // through the pointer. The sendonly answer only needs the attached track, so a refused
        // direction update is logged, not fatal.
        var directionError: NSError?
        transceiver.setDirection(.sendOnly, error: &directionError)
        if let directionError {
            logger?("NVST bundle microphone transceiver kept its negotiated direction: \(directionError.localizedDescription)")
        }
        lock.withLock {
            microphoneSource = source
            microphoneTrack = track
            microphoneSender = transceiver.sender
            microphoneNegotiated = true
            microphoneCaptureEnabled = setup.initiallyEnabled
        }
    }

    /// NVST seats bind the bundle mic by SSRC, and the vendor's own transport uses the
    /// deterministic SSRC 1 (`WebRtcTransport::GetSenderBySsrc(1)` in libBifrost2); live seats
    /// withheld game audio under every mic stream sent with any other SSRC. libwebrtc assigns
    /// sender SSRCs itself and `setParameters` refuses to change them (a transceiver sender has
    /// no encodings before negotiation, and a seeded encoding is rejected), so the value is
    /// forced through the one seam libwebrtc honours: the `a=ssrc` lines of the local answer,
    /// rewritten before `setLocalDescription`. `preparedIdentity` reads it back from both the
    /// kept local description and the sender's encoding; if either disagrees, the mic section
    /// stays out of the session.
    static let nvstMicrophoneSenderSsrc: UInt32 = 1

    /// One entry per m-line: kind, mid, direction and the ssrc values it names. The answer is
    /// never transported to the seat, so this summary in the diagnostic log is the only proof of
    /// what libwebrtc actually negotiated for each section — in particular that the mic m-line
    /// came back sendonly with the sender SSRC ANNOUNCE advertises.
    static func mediaLineSummary(inSdp sdp: String) -> String {
        struct Entry {
            var media = ""
            var mid = "-"
            var direction = "-"
            var ssrcs: [String] = []
        }
        var entries: [Entry] = []
        for raw in sdp.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("m=") {
                entries.append(Entry(media: line))
                continue
            }
            guard !entries.isEmpty else { continue }
            if line.hasPrefix("a=mid:") {
                entries[entries.count - 1].mid = String(line.dropFirst("a=mid:".count))
            } else if line == "a=sendonly" || line == "a=recvonly" || line == "a=sendrecv" || line == "a=inactive" {
                entries[entries.count - 1].direction = String(line.dropFirst(2))
            } else if line.hasPrefix("a=ssrc:") {
                let rest = line.dropFirst("a=ssrc:".count)
                let ssrc = String(rest.split(separator: " ", maxSplits: 1).first ?? rest)
                if !entries[entries.count - 1].ssrcs.contains(ssrc) {
                    entries[entries.count - 1].ssrcs.append(ssrc)
                }
            }
        }
        return entries.enumerated()
            .map { index, entry in
                "[\(index) \(entry.media) mid=\(entry.mid) dir=\(entry.direction) ssrcs=\(entry.ssrcs.isEmpty ? "-" : entry.ssrcs.joined(separator: "+"))]"
            }
            .joined(separator: " ")
    }

    /// libwebrtc assigns the sender SSRC when the transceiver is created; ANNOUNCE advertises it
    /// (`x-nv-mic.micSsrcConfig.senderSsrc`) because NVST has no SDP transport to the seat. The
    /// `RTCRtpSender` wrapper exposes no `ssrc`, so it is read from the answer, scoped to the
    /// mid-2 send section (the downlink section can carry ssrc lines too). A missing SSRC means
    /// the announce omits the attribute rather than names the wrong one.
    func readMicrophoneSenderSsrc(inSdp sdp: String) {
        lock.lock()
        let negotiated = microphoneNegotiated
        lock.unlock()
        guard negotiated, let ssrc = Self.microphoneSenderSsrc(inSdp: sdp), ssrc != 0 else { return }
        lock.withLock { microphoneSenderSsrc = ssrc }
    }

    /// libwebrtc's logging is enormous, so only transport-relevant lines are forwarded and the
    /// total is capped — enough to explain a dropped association without flooding the log.
    func startWebRtcLoggingIfRequested() {
        guard Self.forwardsWebRtcLogging, callbackLogger == nil else { return }
        let logger = self.logger
        let sink = RTCCallbackLogger()
        sink.severity = .info
        sink.start { [weak self] message in
            guard let self else { return }
            let lowered = message.lowercased()
            guard Self.interestingLogFragments.contains(where: lowered.contains) else { return }
            let allowed: Bool = lock.withLock {
                guard forwardedLogLines < 4000 else { return false }
                forwardedLogLines += 1
                return true
            }
            guard allowed else { return }
            logger?("webrtc: " + message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        lock.withLock { callbackLogger = sink }
        logger?("NVST bundle forwarding libwebrtc transport logging")
    }

    /// Round-trip time to the seat, in milliseconds, or -1 before the first sample.
    ///
    /// This is the same measurement the WebRTC transport's HUD shows — libwebrtc's own ICE
    /// candidate-pair RTT — so the two transports' latency numbers mean the same thing. Media rides
    /// its own raw-SRTP socket rather than this association, but both go to the same seat, so the
    /// bundle's RTT is the honest reading of the path.
    public var roundTripMilliseconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return lastRoundTripMilliseconds
    }

    /// Asks libwebrtc for a fresh statistics report. Returns immediately; the sample lands in
    /// `roundTripMilliseconds` when the report arrives.
    public func refreshTransportStatistics() {
        lock.lock()
        let connection = peerConnection
        let inFlight = statisticsRequestInFlight
        if !inFlight { statisticsRequestInFlight = true }
        lock.unlock()
        guard let connection, !inFlight else { return }
        connection.statistics { [weak self] report in
            guard let self else { return }
            let sample = Self.roundTripMilliseconds(in: report)
            let micBytes = Self.outboundAudioSentBytes(in: report)
            let micSeatPackets = Self.remoteInboundAudioPacketsReceived(in: report)
            let micCodec = Self.outboundAudioCodec(in: report)
            lock.lock()
            statisticsRequestInFlight = false
            if let sample { lastRoundTripMilliseconds = sample }
            if let micBytes { microphoneSentDataBytes = micBytes }
            if let micSeatPackets { microphoneSeatReportedPackets = micSeatPackets }
            if let micCodec { microphoneOutboundCodec = micCodec }
            let shouldDescribe = sample == nil && !didDescribeStatistics
            if shouldDescribe { didDescribeStatistics = true }
            lock.unlock()
            // The seat is Bifrost's minimal STUN responder rather than an ICE agent, so a missing
            // RTT is a real possibility rather than a bug on our side. Say once what the report
            // actually contains, so the difference is visible instead of guessed at.
            guard shouldDescribe else { return }
            let pairs = report.statistics.values.filter { $0.type == "candidate-pair" }
            let described = pairs.prefix(3).map { pair in
                pair.values.keys.sorted().map { "\($0)=\(pair.values[$0] ?? "" as NSObject)" }.joined(separator: " ")
            }
            logger?("NVST bundle no ICE round trip yet; types=[\(Set(report.statistics.values.map(\.type)).sorted().joined(separator: ","))] pairs=\(pairs.count) \(described.joined(separator: " | "))")
        }
    }

    /// The nominated candidate pair's RTT, in milliseconds. `currentRoundTripTime` is seconds and
    /// is absent until the pair has completed a check, which is why this is optional rather than 0.
    static func roundTripMilliseconds(in report: RTCStatisticsReport) -> Double? {
        for statistic in report.statistics.values where statistic.type == "candidate-pair" {
            let nominated = statistic.values["nominated"] as? NSNumber
            let state = statistic.values["state"] as? String
            guard nominated == nil || nominated?.boolValue == true else { continue }
            guard state == nil || state == "succeeded" else { continue }
            let roundTrip = (statistic.values["currentRoundTripTime"] as? NSNumber)
                ?? (statistic.values["roundTripTime"] as? NSNumber)
            if let roundTrip { return roundTrip.doubleValue * 1000 }
        }
        return nil
    }

    /// Bytes libwebrtc has sent on the audio outbound RTP stream — the mic sender is the only
    /// audio sender a bundle ever has, so this is the mic chat upload counter the `0x208` report
    /// wants. `nil` while no audio sender exists, so an un-negotiated mic keeps reporting zero.
    static func outboundAudioSentBytes(in report: RTCStatisticsReport) -> UInt64? {
        for statistic in report.statistics.values where statistic.type == "outbound-rtp" {
            let kind = (statistic.values["kind"] as? String) ?? (statistic.values["mediaType"] as? String)
            guard kind == "audio" else { continue }
            if let bytes = statistic.values["bytesSent"] as? NSNumber { return bytes.uint64Value }
            return 0
        }
        return nil
    }

    /// The codec libwebrtc reports on the audio outbound stream, as `mimeType:payloadType`, so a
    /// RED-wrapped mic reads `audio/red:63` and plain Opus `audio/opus:111`.
    static func outboundAudioCodec(in report: RTCStatisticsReport) -> String? {
        for statistic in report.statistics.values where statistic.type == "outbound-rtp" {
            let kind = (statistic.values["kind"] as? String) ?? (statistic.values["mediaType"] as? String)
            guard kind == "audio", let codecId = statistic.values["codecId"] as? String,
                  let codec = report.statistics[codecId] else { continue }
            let mime = (codec.values["mimeType"] as? String) ?? "?"
            let payloadType = (codec.values["payloadType"] as? NSNumber).map { String($0.intValue) } ?? "?"
            return "\(mime):\(payloadType)"
        }
        return nil
    }

    /// What the seat's RTCP says about the mic stream: `remote-inbound-rtp` only exists once the
    /// remote sends Receiver Reports for one of our send streams, so its `packetsReceived` counts
    /// RTP packets the seat itself reports receiving. A mic with climbing `tx` but a zero here is
    /// a stream the seat never bound a receive pipeline to.
    static func remoteInboundAudioPacketsReceived(in report: RTCStatisticsReport) -> UInt64? {
        for statistic in report.statistics.values where statistic.type == "remote-inbound-rtp" {
            let kind = (statistic.values["kind"] as? String) ?? (statistic.values["mediaType"] as? String)
            guard kind == "audio" else { continue }
            if let packets = statistic.values["packetsReceived"] as? NSNumber { return packets.uint64Value }
            return 0
        }
        return nil
    }

    /// Builds the factory with our own audio device rather than libwebrtc's default: its playout
    /// callback is the only point where decoded game audio is visible to us, and that is what a
    /// recording needs. It is the same device the WebRTC transport already ships, but it follows
    /// the default output device itself here — nothing on this path drives
    /// `handleDefaultDeviceChange()`.
    ///
    /// With no default output device there is nothing to bind to and playout would never start, so
    /// libwebrtc's own device takes over: audio still plays, recordings are silent.
    private func makePeerConnectionFactory() -> RTCPeerConnectionFactory {
        let audioDevice = OPNCoreAudioRTCDevice(owner: self, monitorsDefaultDeviceChanges: true)
        guard audioDevice.hasUsableOutputDevice else {
            logger?("NVST bundle found no default output device; using libwebrtc's audio device (recording will have no audio)")
            return RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil)
        }
        self.audioDevice = audioDevice
        return RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil, audioDevice: audioDevice)
    }

    func store(factory: RTCPeerConnectionFactory, connection: RTCPeerConnection) {
        lock.withLock {
            self.factory = factory
            self.peerConnection = connection
        }
    }

    public func close() {
        lock.lock()
        let channels = createdChannels
        let connection = peerConnection
        createdChannels = []
        openFeedbackChannel = nil
        openControlChannel = nil
        openInputChannel = nil
        openReliableInputChannel = nil
        openPartiallyReliableControlChannel = nil
        remoteAudioTracks.removeAll()
        microphoneSource = nil
        microphoneTrack = nil
        microphoneSender = nil
        microphoneNegotiated = false
        microphoneSenderSsrc = nil
        microphoneCaptureEnabled = false
        microphoneSentDataBytes = 0
        microphoneSeatReportedPackets = 0
        microphoneOutboundCodec = nil
        negotiatedInputProtocolVersion = nil
        openCustomChannels = [:]
        peerConnection = nil
        factory = nil
        // Released with the factory so the CoreAudio units are torn down when the session ends,
        // not whenever the bundle happens to be deallocated.
        audioDevice = nil
        let waiting = hostCandidateContinuation
        hostCandidateContinuation = nil
        let sink = callbackLogger
        callbackLogger = nil
        lock.unlock()
        waiting?.resume(throwing: BundleError.noHostCandidate)
        channels.forEach { $0.close() }
        connection?.close()
        sink?.stop()
    }

    /// Writes one plain RTCP payload to the feedback channel. Plain, because DTLS already encrypts
    /// the SCTP association.
    public func sendFeedback(_ payload: Data) -> Bool {
        lock.lock()
        let channel = openFeedbackChannel
        lock.unlock()
        guard Self.sendsFeedback else { return false }
        guard let channel, channel.readyState == .open else {
            // A closed association still accepts writes silently at the sender, which hides the
            // real failure behind a rising report count.
            lock.withLock { feedbackSendFailures += 1 }
            return false
        }
        let sent = channel.sendData(RTCDataBuffer(data: payload, isBinary: true))
        if !sent { lock.withLock { feedbackSendFailures += 1 } }
        return sent
    }

    /// Writes one NVST command packet to `control_channel_reliable`.
    public func sendControl(_ command: NvstControlCommand) -> Bool {
        lock.lock()
        let channel = openControlChannel
        lock.unlock()
        guard let encoded = try? command.encoded else {
            lock.withLock {
                controlSendFailures += 1
                recordControlAttempt(code: command.code.rawValue,
                                     bytes: UInt64(command.payload.count + NvstControlCommand.headerLength),
                                     sent: false)
            }
            return false
        }
        guard let channel, channel.readyState == .open else {
            lock.withLock {
                controlSendFailures += 1
                recordControlAttempt(code: command.code.rawValue, bytes: UInt64(encoded.count), sent: false)
            }
            return false
        }
        let sent = channel.sendData(RTCDataBuffer(data: encoded, isBinary: true))
        lock.withLock {
            if sent { controlMessagesSent += 1 } else { controlSendFailures += 1 }
            recordControlAttempt(code: command.code.rawValue, bytes: UInt64(encoded.count), sent: sent)
        }
        return sent
    }

    /// Call with `lock` held.
    func recordControlAttempt(code: UInt16, bytes: UInt64, sent: Bool) {
        var counters = controlCommandStats[code] ?? ControlCommandCounters()
        if sent { counters.messagesSent += 1 } else { counters.messagesFailed += 1 }
        counters.aggregatedBytes += bytes
        controlCommandStats[code] = counters
    }

    /// The control-channel counters as the `0x313` report wants them: totals plus one record per
    /// command, in ascending code order.
    public var controlChannelStats: (totalSent: UInt32, totalFailed: UInt32, totalBytes: UInt64,
                                     commands: [NvstControlChannelCommandStats]) {
        lock.withLock {
            let commands = controlCommandStats
                .sorted { $0.key < $1.key }
                .map { NvstControlChannelCommandStats(commandCode: $0.key,
                                                      messagesSent: UInt32(clamping: $0.value.messagesSent),
                                                      messagesFailed: UInt32(clamping: $0.value.messagesFailed),
                                                      aggregatedBytes: $0.value.aggregatedBytes) }
            return (UInt32(clamping: controlMessagesSent),
                    UInt32(clamping: controlSendFailures),
                    commands.reduce(0) { $0 + $1.aggregatedBytes },
                    commands)
        }
    }

    /// Writes one remote-input packet to `input_channel_partially_reliable`. The channel is one of
    /// the six the official client opens, so it is already live; only the payload encoding is
    /// outstanding.
    public func sendInput(_ payload: Data) -> Bool {
        lock.lock()
        let channel = openInputChannel
        lock.unlock()
        guard let channel, channel.readyState == .open else {
            lock.withLock { inputSendFailures += 1 }
            return false
        }
        let sent = channel.sendData(RTCDataBuffer(data: payload, isBinary: true))
        lock.withLock {
            if sent { inputMessagesSent += 1 } else { inputSendFailures += 1 }
        }
        return sent
    }

    /// Writes to one of the `custom_message_on_sctp_private_*` channels. The seat advertises
    /// `general.customMessageOnCC:1` and the library has a `sendCustomMessage` path, but nothing
    /// has ever been written to these.
    public func sendCustomMessage(_ payload: Data, partiallyReliable: Bool) -> Bool {
        let label = partiallyReliable
            ? "custom_message_on_sctp_private_partially_reliable"
            : "custom_message_on_sctp_private_reliable"
        lock.lock()
        let channel = openCustomChannels[label]
        lock.unlock()
        guard let channel, channel.readyState == .open else { return false }
        return channel.sendData(RTCDataBuffer(data: payload, isBinary: true))
    }

    /// Writes to `control_channel_partially_reliable`, which is where the captured official client
    /// sends its QoS reports (SCTP stream 6).
    public func sendPartiallyReliableControl(_ command: NvstControlCommand) -> Bool {
        lock.lock()
        let channel = openPartiallyReliableControlChannel
        lock.unlock()
        guard let channel, channel.readyState == .open, let encoded = try? command.encoded else { return false }
        return channel.sendData(RTCDataBuffer(data: encoded, isBinary: true))
    }

    public var isInputChannelOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return openInputChannel?.readyState == .open
    }

    /// Input is accepted once the control channel — which is where the official client actually
    /// sends remote input — is open and the seat has announced its protocol version.
    public var isInputReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return openControlChannel?.readyState == .open && negotiatedInputProtocolVersion != nil
    }

    public var inputProtocolVersion: UInt16? {
        lock.lock()
        defer { lock.unlock() }
        return negotiatedInputProtocolVersion
    }

    /// Writes to `input_channel_v1`, the reliable input channel.
    public func sendReliableInput(_ payload: Data) -> Bool {
        lock.lock()
        let channel = openReliableInputChannel
        lock.unlock()
        guard let channel, channel.readyState == .open else {
            lock.withLock { inputSendFailures += 1 }
            return false
        }
        let sent = channel.sendData(RTCDataBuffer(data: payload, isBinary: true))
        lock.withLock { if sent { inputMessagesSent += 1 } else { inputSendFailures += 1 } }
        return sent
    }

    public var isControlChannelOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return openControlChannel?.readyState == .open
    }

    public var isFeedbackChannelOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return openFeedbackChannel?.readyState == .open
    }

    public var diagnosticSummary: String {
        lock.lock()
        defer { lock.unlock() }
        let perLabel = inboundMessagesByLabel.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        let microphone = microphoneNegotiated
            ? "on(ssrc=\(microphoneSenderSsrc.map(String.init) ?? "?"),gate=\(microphoneCaptureEnabled),tx=\(microphoneSentDataBytes),rr=\(microphoneSeatReportedPackets),codec=\(microphoneOutboundCodec ?? "?"),rec=\(audioDevice?.isRecording == true),track=\(microphoneTrack?.isEnabled == true))"
            : "off"
        return "ice=\(iceStateDescription) channels=\(createdChannels.count) feedbackOpen=\(openFeedbackChannel?.readyState == .open) inboundBytes=\(inboundFeedbackBytes) inbound=[\(perLabel)] sendFailures=\(feedbackSendFailures) controlOut=\(controlMessagesSent) controlFailed=\(controlSendFailures) inputOut=\(inputMessagesSent) inputFailed=\(inputSendFailures) mic=\(microphone)"
    }

    /// Creates the official channel set in order so each label lands on the stream id the seat
    /// expects, with the feedback channel last.
    func createFeedbackChannels(on connection: RTCPeerConnection, minimum: Int = 0) -> Int {
        var created: [RTCDataChannel] = []
        for definition in Self.officialChannels {
            let configuration = RTCDataChannelConfiguration()
            configuration.isOrdered = true
            configuration.isNegotiated = false
            if definition.isUnreliable {
                configuration.maxRetransmits = 0
            } else if let lifetime = definition.maxPacketLifeTimeMilliseconds {
                configuration.maxPacketLifeTime = lifetime
            }
            guard let channel = connection.dataChannel(forLabel: definition.label, configuration: configuration) else { continue }
            channel.delegate = self
            created.append(channel)
        }
        lock.withLock { createdChannels.append(contentsOf: created) }
        logger?("NVST bundle created \(created.count) channels: " + created.map { "\($0.channelId):\($0.label)" }.joined(separator: ", "))
        return created.count
    }
}
