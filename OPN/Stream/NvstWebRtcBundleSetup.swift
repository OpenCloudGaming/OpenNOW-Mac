//
//  NvstWebRtcBundleSetup.swift
//  OpenNOW
//
//  Bringing the ICE/DTLS/SCTP bundle up and tearing it down, plus the feedback and control
//  channels it opens. Split out of NvstWebRtcBundle.swift.
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
    public func prepare() async throws -> Identity {
        guard let credentials = handoff.iceCredentials else { throw BundleError.missingRemoteCredentials }
        guard let remoteFingerprint = credentials.remoteDTLSFingerprint, !remoteFingerprint.isEmpty else {
            throw BundleError.missingRemoteFingerprint
        }

        startWebRtcLoggingIfRequested()
        let factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil)
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
            peerPort: handoff.videoPeerPort
        )
        try await setRemoteDescription(connection, RTCSessionDescription(type: .offer, sdp: offer))

        // At least one data channel has to exist before the answer, or the answer carries no SCTP
        // section at all and the bundle has nothing to negotiate.
        _ = createFeedbackChannels(on: connection, minimum: 1)

        let answer = try await createAnswer(connection, constraints: constraints)
        // Bifrost length-checks ICE credentials, so force the official 4/22 pair libwebrtc gives no
        // API for. If it refuses the munged answer, fall back to its own credentials and say so —
        // the seat's behaviour then tells us whether that check is real.
        let forced = Self.replacingIceCredentials(
            in: answer.sdp,
            usernameFragment: credentials.localUsernameFragment,
            password: credentials.localPassword
        )
        var usesOfficialCredentials = true
        do {
            try await setLocalDescription(connection, RTCSessionDescription(type: .answer, sdp: forced))
        } catch {
            logger?("NVST bundle rejected the official ICE credentials (\(error.localizedDescription)); keeping the generated pair")
            usesOfficialCredentials = false
            try await setLocalDescription(connection, answer)
        }

        let candidates = try await waitForHostCandidates()
        let hosts = candidates.compactMap { Self.hostAddress(fromCandidateLine: $0.sdp) }
        logger?("NVST bundle gathered host candidates: \(hosts.map { "\($0.address):\($0.port)" }.joined(separator: ", "))")
        guard let host = Self.preferredHost(among: hosts, matching: preferredLocalAddress) else {
            throw BundleError.noHostCandidate
        }
        if host.address != preferredLocalAddress {
            logger?("NVST bundle announcing \(host.address):\(host.port), which is not the routed address \(preferredLocalAddress ?? "unknown")")
        }
        let localDescription = connection.localDescription?.sdp ?? forced
        guard let fingerprint = Self.fingerprint(inSdp: localDescription) else {
            throw BundleError.missingLocalFingerprint
        }
        logger?("NVST bundle prepared (port=\(host.port), localAddress=\(host.address), fingerprintBytes=\(fingerprint.count), officialIce=\(usesOfficialCredentials), setup=\(Self.setupRole(inSdp: localDescription) ?? "absent"))")
        return Identity(
            bundlePort: host.port,
            localAddress: host.address,
            dtlsFingerprint: fingerprint,
            usesOfficialIceCredentials: usesOfficialCredentials
        )
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
            lock.lock()
            statisticsRequestInFlight = false
            if let sample { lastRoundTripMilliseconds = sample }
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
        negotiatedInputProtocolVersion = nil
        openCustomChannels = [:]
        peerConnection = nil
        factory = nil
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
        return "ice=\(iceStateDescription) channels=\(createdChannels.count) feedbackOpen=\(openFeedbackChannel?.readyState == .open) inboundBytes=\(inboundFeedbackBytes) inbound=[\(perLabel)] sendFailures=\(feedbackSendFailures) controlOut=\(controlMessagesSent) controlFailed=\(controlSendFailures) inputOut=\(inputMessagesSent) inputFailed=\(inputSendFailures)"
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
