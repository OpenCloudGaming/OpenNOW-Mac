import Foundation
@preconcurrency import WebRTC

/// The NVST ICE/DTLS/SCTP bundle, driven by `WebRTC.framework`.
///
/// NVST has no WebRTC signaling: the seat's identity arrives through RTSP (DESCRIBE's DTLS
/// fingerprint and ICE password, SETUP's ping payload), and ours goes back in ANNOUNCE. So the
/// remote description is **synthesized** from those RTSP answers, and only the answer is real.
///
/// Facts this is built to match, captured from the official client (2026-08-23):
/// - the client is the DTLS **client**: it sends the ClientHello on the bundle socket ~37 ms
///   after the first STUN Binding Request, and the handshake completes ~11 ms later;
/// - the bundle authenticates with the **`ping+1`** remote ufrag while the video socket uses the
///   raw ping payload — one shared 4-character local ufrag serves both;
/// - the seat gates media on this handshake: without it the video relay is never armed.
///
/// `libBifrost2` embeds libwebrtc itself (`net/dcsctp`, `SctpTransport`, `a=sctp-port:5000`), so
/// this is the same stack the official client uses rather than an approximation of it.
public final class NvstWebRtcBundle: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate, @unchecked Sendable {
    public struct Identity: Equatable, Sendable {
        /// Port of the local host candidate, announced as `general.clientBundlePort`.
        public let bundlePort: UInt16
        public let localAddress: String?
        /// SHA-256 colon hex of the local DTLS certificate.
        public let dtlsFingerprint: String
        /// True when libwebrtc accepted the official 4/22 ICE credentials; false means it kept its
        /// own, which Bifrost's length checks are documented to reject.
        public let usesOfficialIceCredentials: Bool
    }

    public enum BundleError: LocalizedError, Equatable, Sendable {
        case factoryUnavailable
        case missingRemoteFingerprint
        case missingRemoteCredentials
        case answerFailed(String)
        case localDescriptionFailed(String)
        case noHostCandidate
        case missingLocalFingerprint

        public var errorDescription: String? {
            switch self {
            case .factoryUnavailable: "The NVST bundle could not create a WebRTC peer connection."
            case .missingRemoteFingerprint: "DESCRIBE did not advertise a remote DTLS fingerprint, so the bundle cannot be brought up."
            case .missingRemoteCredentials: "The NVST bundle needs the version-6 ICE credentials."
            case .answerFailed(let reason): "The NVST bundle could not create its answer: \(reason)"
            case .localDescriptionFailed(let reason): "The NVST bundle could not apply its answer: \(reason)"
            case .noHostCandidate: "The NVST bundle gathered no host candidate, so no port can be announced."
            case .missingLocalFingerprint: "The NVST bundle answer carried no local DTLS fingerprint."
            }
        }
    }

    /// The SCTP data channels the official client opens, in creation order. The seat assigns each
    /// label a **fixed** stream id and validates it: captured from `libBifrost2`'s own log,
    ///
    ///     id 0  control_channel_reliable
    ///     id 2  custom_message_on_sctp_private_reliable
    ///     id 4  custom_message_on_sctp_private_partially_reliable
    ///     id 6  control_channel_partially_reliable
    ///     id 8  control_channel_unreliable
    ///     id 10 input_channel_partially_reliable
    ///     id 12 cursor_channel
    ///     id 14 rtcp_on_sctp_private
    ///
    /// As DTLS client we are given the even ids in creation order, so creating the list in order
    /// reproduces that mapping exactly — no negotiated-id trick required.
    ///
    /// Opening `rtcp_on_sctp_private` across ids 0…14 squatted every one of those and the seat
    /// answered by resetting all streams and closing DTLS 114 ms after PLAY. Appending it to the
    /// six-channel list failed the same way for a narrower reason: it landed on id 12, which is
    /// the cursor channel's, under the wrong label.
    struct ChannelDefinition {
        let label: String
        /// `nil` is fully reliable; a lifetime marks partially-reliable; zero retransmits is
        /// unreliable.
        let maxPacketLifeTimeMilliseconds: Int32?
        let isUnreliable: Bool

        init(_ label: String, lifetime: Int32? = nil, unreliable: Bool = false) {
            self.label = label
            self.maxPacketLifeTimeMilliseconds = lifetime
            self.isUnreliable = unreliable
        }
    }

    /// `config.maxRetransmitTime = 300` for the partially-reliable channels, per the same log.
    ///
    /// Eight channels, matching OpenNOW's native streamer profile. This list read "exactly six, and
    /// no feedback channel — that channel is the seat's to open" until a session showed the seat
    /// never opens it: `feedbackOpen=false reportsSent=0`, so our receiver reports had nowhere to
    /// go and the seat's congestion control had no evidence to act on.
    static let officialChannels: [ChannelDefinition] = [
        ChannelDefinition("control_channel_reliable"),
        ChannelDefinition("custom_message_on_sctp_private_reliable"),
        ChannelDefinition("custom_message_on_sctp_private_partially_reliable", lifetime: 300),
        ChannelDefinition("control_channel_partially_reliable", lifetime: 300),
        ChannelDefinition("control_channel_unreliable", unreliable: true),
        ChannelDefinition("input_channel_partially_reliable", lifetime: 300),
        // The last two come from OpenNOW's native streamer, whose profile is eight channels with
        // fixed stream ids: cursor on 12, RTCP on 14. Ours stopped at six, and the earlier attempt
        // to open the feedback channel appended it as the SEVENTH — landing it on id 12, the
        // cursor channel's id, with the wrong label. That mismatch is what made the seat reset
        // every stream and drop DTLS, and it was read at the time as "the seat refuses a feedback
        // channel". Creating the cursor channel first puts RTCP back on 14 where it belongs.
        //
        // Why it matters beyond tidiness: with no feedback channel the seat's congestion control
        // never hears our receiver reports (`feedbackOpen=false reportsSent=0` in every session so
        // far), so it has no evidence to reduce its output when we are losing packets.
        ChannelDefinition("cursor_channel"),
        ChannelDefinition(NvstFeedbackSender.channelLabel),
    ]

    /// Official feedback channel label. `rtcp1` is refused by the seat.
    public static let feedbackChannelLabel = NvstFeedbackSender.channelLabel

    /// `OPN_NVST_FEEDBACK=0` opens the channels but never writes to them, isolating "the seat
    /// dislikes our reports" from "the seat dislikes the channel".
    public static var sendsFeedback: Bool {
        ProcessInfo.processInfo.environment["OPN_NVST_FEEDBACK"] != "0"
    }

    /// `OPN_NVST_WEBRTC_LOG=1` forwards libwebrtc's own ICE/DTLS/SCTP logging into our log, which is
    /// the only way to see *why* an association drops rather than just that it did.
    private static var forwardsWebRtcLogging: Bool {
        ProcessInfo.processInfo.environment["OPN_NVST_WEBRTC_LOG"] == "1"
    }

    private static let interestingLogFragments = ["ice", "dtls", "sctp", "candidate", "consent", "transport", "srtp", "stun"]

    private let handoff: NVSTVideoHandoff
    /// The routed NIC address. libwebrtc gathers on every interface — including Docker/VM bridges
    /// that cannot reach the seat — and ANNOUNCE can carry only one port, so the candidate on this
    /// address is the one that must be announced.
    private let preferredLocalAddress: String?
    private let logger: (@Sendable (String) -> Void)?
    private let lock = NSLock()
    private var lastRoundTripMilliseconds = -1.0
    private var statisticsRequestInFlight = false
    private var didDescribeStatistics = false
    private var factory: RTCPeerConnectionFactory?
    private var peerConnection: RTCPeerConnection?
    private var createdChannels: [RTCDataChannel] = []
    private var openFeedbackChannel: RTCDataChannel?
    private var openControlChannel: RTCDataChannel?
    private var openInputChannel: RTCDataChannel?
    private var openReliableInputChannel: RTCDataChannel?
    private var openPartiallyReliableControlChannel: RTCDataChannel?
    private var remoteAudioTracks: [RTCAudioTrack] = []
    /// Guarded by `lock`: written on libwebrtc's delegate thread, read from the transport's actor.
    private var trackedRemoteAudioCount = 0
    public var remoteAudioTrackCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return trackedRemoteAudioCount
    }
    private var negotiatedInputProtocolVersion: UInt16?
    private var openCustomChannels: [String: RTCDataChannel] = [:]
    private var inputMessagesSent = 0
    private var inputSendFailures = 0
    private var controlSendFailures = 0
    private var controlMessagesSent = 0
    private var hostCandidateContinuation: CheckedContinuation<[RTCIceCandidate], Error>?
    private var hostCandidates: [RTCIceCandidate] = []
    private var gatheringComplete = false
    private var inboundFeedbackBytes = 0
    private var feedbackSendFailures = 0
    private var inboundMessagesByLabel: [String: Int] = [:]
    private var loggedInboundMessages = 0
    private var iceStateDescription = "new"
    private var callbackLogger: RTCCallbackLogger?
    private var forwardedLogLines = 0

    /// Fires when a `rtcp_on_sctp_private` channel opens, so the feedback sender can start.
    public var onFeedbackChannelOpen: (@Sendable () -> Void)?

    /// Fires when the seat announces its remote-input protocol version.
    public var onInputProtocolNegotiated: (@Sendable (UInt16) -> Void)?

    /// Fires when `control_channel_reliable` opens. The seat starts its 10 s client-timeout the
    /// moment the association is up, so the keepalive has to begin here rather than when video
    /// arrives.
    public var onControlChannelOpen: (@Sendable () -> Void)?

    public init(handoff: NVSTVideoHandoff,
                preferredLocalAddress: String? = NvstRoutedIPv4.discover(),
                logger: (@Sendable (String) -> Void)? = nil) {
        self.handoff = handoff
        self.preferredLocalAddress = preferredLocalAddress
        self.logger = logger
        super.init()
    }

    // MARK: - Bring-up

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
    private func startWebRtcLoggingIfRequested() {
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

    private func store(factory: RTCPeerConnectionFactory, connection: RTCPeerConnection) {
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
        guard let channel, channel.readyState == .open else {
            lock.withLock { controlSendFailures += 1 }
            return false
        }
        let sent = channel.sendData(RTCDataBuffer(data: command.encoded, isBinary: true))
        lock.withLock {
            if sent { controlMessagesSent += 1 } else { controlSendFailures += 1 }
        }
        return sent
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
        guard let channel, channel.readyState == .open else { return false }
        return channel.sendData(RTCDataBuffer(data: command.encoded, isBinary: true))
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

    /// The 4-byte keepalive the client sends on the reliable input channel every two seconds.
    public func sendInputHeartbeat() -> Bool {
        lock.lock()
        let channel = openReliableInputChannel
        lock.unlock()
        guard let channel, channel.readyState == .open else { return false }
        return channel.sendData(RTCDataBuffer(data: NvstRemoteInput.heartbeat, isBinary: true))
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
    private func createFeedbackChannels(on connection: RTCPeerConnection, minimum: Int = 0) -> Int {
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

    // MARK: - SDP

    /// The seat's side of the bundle, assembled from RTSP answers. `a=setup:actpass` leaves us free
    /// to answer `active`, which is what makes libwebrtc send the ClientHello — the role the
    /// official client uses.
    /// The seat's side of the bundle, assembled from RTSP answers.
    ///
    /// Two media sections, both required:
    /// - `m=audio` because ANNOUNCE tells the seat audio rides this bundle, and the official
    ///   client's bundle really does receive it (1543 inbound RTP packets in the reference
    ///   capture). A data-channel-only bundle makes the seat reset every SCTP stream and close
    ///   DTLS 114 ms after PLAY, having nowhere to put the audio it was promised.
    /// - `m=application` for `rtcp_on_sctp_private`.
    ///
    /// `a=setup:actpass` leaves us free to answer `active`, which is what makes libwebrtc send the
    /// ClientHello — the role the official client takes.
    static func synthesizedRemoteOffer(remoteUsernameFragment: String,
                                       remotePassword: String,
                                       remoteFingerprint: String,
                                       peerIP: String,
                                       peerPort: UInt16) -> String {
        let transport = [
            "c=IN IP4 0.0.0.0",
            "a=ice-ufrag:\(remoteUsernameFragment)",
            "a=ice-pwd:\(remotePassword)",
            "a=ice-options:trickle",
            "a=fingerprint:sha-256 \(remoteFingerprint)",
            "a=setup:actpass",
        ]
        var lines = [
            "v=0",
            "o=- 0 2 IN IP4 127.0.0.1",
            "s=-",
            "t=0 0",
            "a=group:BUNDLE 0 1",
            "a=msid-semantic: WMS",
            // Offered as sendonly by the seat, so our answer is recvonly.
            "m=audio 9 UDP/TLS/RTP/SAVPF \(Self.audioPayloadFormatLine)",
        ]
        lines += transport
        lines += [
            "a=mid:0",
            "a=rtcp-mux",
            "a=sendonly",
        ]
        lines += Self.audioCodecLines
        lines += [
            "a=ptime:5",
            "a=maxptime:20",
            "a=candidate:1 1 udp 2122260223 \(peerIP) \(peerPort) typ host",
            "m=application 9 UDP/DTLS/SCTP webrtc-datachannel",
        ]
        lines += transport
        lines += [
            "a=mid:1",
            "a=sctp-port:5000",
            "a=max-message-size:262144",
            "",
        ]
        return lines.joined(separator: "\r\n")
    }

    /// The wire carries bundle audio on payload type **63** — captured from the native stack's
    /// bundle socket (pt=63, ssrc=0x00000001, no extension, ~188 bytes at 200/s, against pt=101 for
    /// video on its own socket). libwebrtc demultiplexes on the payload type, so the offer must
    /// name it or every audio packet is discarded before it can be counted.
    ///
    /// 63 is WebRTC's own default type for **RED** (RFC 2198) wrapping Opus, and the seat uses the
    /// standard WebRTC audio offer, so RED is the format. An earlier reading called it plain Opus,
    /// but that was on a *silent* stream: RED's redundant copies (discarded > received) and the
    /// absence of content (audioLevel ~0) look identical to a decode that produced nothing. On real
    /// audio, declaring RED payloads as plain Opus mis-frames them and yields garbage — which is the
    /// symptom reported from a live session.
    static let redPayloadType = 63
    static let opusPayloadType = 111

    /// Lets the audio format be flipped by ear on a real session, since a silent capture cannot
    /// tell RED from plain Opus. Defaults to RED, the grounded hypothesis; `OPN_NVST_AUDIO_RED=0`
    /// or the `OPNNVSTAudioRED` default forces plain Opus for an A/B comparison.
    static var usesRedAudio: Bool {
        if ProcessInfo.processInfo.environment["OPN_NVST_AUDIO_RED"] == "0" { return false }
        if UserDefaults.standard.object(forKey: "OPNNVSTAudioRED") != nil {
            return UserDefaults.standard.bool(forKey: "OPNNVSTAudioRED")
        }
        return true
    }

    static var audioPayloadFormatLine: String {
        usesRedAudio ? "\(redPayloadType) \(opusPayloadType)" : "\(opusPayloadType)"
    }

    /// 48 kHz stereo Opus in 5 ms frames. libwebrtc decodes Opus as mono unless `stereo=1` is
    /// negotiated. Under RED, pt 63 carries generations of the pt-111 Opus payload.
    static var audioCodecLines: [String] {
        var lines: [String] = []
        if usesRedAudio {
            lines.append("a=rtpmap:\(redPayloadType) red/48000/2")
            lines.append("a=fmtp:\(redPayloadType) \(opusPayloadType)/\(opusPayloadType)")
        }
        lines.append("a=rtpmap:\(opusPayloadType) opus/48000/2")
        lines.append("a=fmtp:\(opusPayloadType) minptime=5;stereo=1;sprop-stereo=1;useinbandfec=1")
        return lines
    }

    static func replacingIceCredentials(in sdp: String, usernameFragment: String, password: String) -> String {
        sdp.components(separatedBy: "\r\n").map { line in
            if line.hasPrefix("a=ice-ufrag:") { return "a=ice-ufrag:\(usernameFragment)" }
            if line.hasPrefix("a=ice-pwd:") { return "a=ice-pwd:\(password)" }
            return line
        }.joined(separator: "\r\n")
    }

    static func fingerprint(inSdp sdp: String) -> String? {
        for line in sdp.components(separatedBy: .newlines) where line.hasPrefix("a=fingerprint:") {
            let parts = line.dropFirst("a=fingerprint:".count).split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            return String(parts[1]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static func setupRole(inSdp sdp: String) -> String? {
        for line in sdp.components(separatedBy: .newlines) where line.hasPrefix("a=setup:") {
            return String(line.dropFirst("a=setup:".count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// `candidate:… udp <priority> <address> <port> typ host` → the address and port to announce.
    static func hostAddress(fromCandidateLine line: String) -> (address: String, port: UInt16)? {
        var text = line
        if text.hasPrefix("a=") { text.removeFirst(2) }
        if text.hasPrefix("candidate:") { text.removeFirst("candidate:".count) }
        let fields = text.split(separator: " ").map(String.init)
        guard fields.count >= 6, let port = UInt16(fields[5]) else { return nil }
        return (fields[4], port)
    }

    // MARK: - Async bridges

    private func setRemoteDescription(_ connection: RTCPeerConnection, _ description: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setRemoteDescription(description) { error in
                if let error {
                    continuation.resume(throwing: BundleError.answerFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func createAnswer(_ connection: RTCPeerConnection, constraints: RTCMediaConstraints) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            connection.answer(for: constraints) { description, error in
                if let description {
                    continuation.resume(returning: description)
                } else {
                    continuation.resume(throwing: BundleError.answerFailed(error?.localizedDescription ?? "no answer"))
                }
            }
        }
    }

    private func setLocalDescription(_ connection: RTCPeerConnection, _ description: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setLocalDescription(description) { error in
                if let error {
                    continuation.resume(throwing: BundleError.localDescriptionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Waits for gathering to finish rather than taking the first candidate: the first one to
    /// arrive is frequently a bridge interface, and announcing its port arms the seat's media relay
    /// on a socket that never receives anything.
    private func waitForHostCandidates() async throws -> [RTCIceCandidate] {
        if let ready = lock.withLock({ gatheringComplete ? hostCandidates : nil }), !ready.isEmpty {
            return ready
        }
        return try await withThrowingTaskGroup(of: [RTCIceCandidate].self) { group in
            group.addTask { [weak self] in
                guard let self else { throw BundleError.noHostCandidate }
                return try await withCheckedThrowingContinuation { continuation in
                    lock.lock()
                    if gatheringComplete, !hostCandidates.isEmpty {
                        let ready = hostCandidates
                        lock.unlock()
                        continuation.resume(returning: ready)
                        return
                    }
                    hostCandidateContinuation = continuation
                    lock.unlock()
                }
            }
            group.addTask { [weak self] in
                // Gathering on a machine with many interfaces still settles in well under a second;
                // this only bounds a stack that never reports completion.
                try await Task.sleep(for: .seconds(2))
                self?.finishHostCandidateWait()
                throw BundleError.noHostCandidate
            }
            let candidates = try await group.next()!
            group.cancelAll()
            return candidates
        }
    }

    /// Resumes the wait with whatever has been gathered so far.
    private func finishHostCandidateWait() {
        lock.lock()
        let waiting = hostCandidateContinuation
        hostCandidateContinuation = nil
        let gathered = hostCandidates
        lock.unlock()
        guard let waiting else { return }
        if gathered.isEmpty {
            waiting.resume(throwing: BundleError.noHostCandidate)
        } else {
            waiting.resume(returning: gathered)
        }
    }

    /// The candidate on the routed interface, falling back to the first gathered one.
    static func preferredHost(among hosts: [(address: String, port: UInt16)],
                              matching preferredAddress: String?) -> (address: String, port: UInt16)? {
        if let preferredAddress, let match = hosts.first(where: { $0.address == preferredAddress }) {
            return match
        }
        return hosts.first
    }

    // MARK: - RTCPeerConnectionDelegate

    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        guard candidate.sdp.contains("typ host"), candidate.sdp.lowercased().contains(" udp ") else { return }
        lock.withLock { hostCandidates.append(candidate) }
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        lock.lock()
        iceStateDescription = String(newState.rawValue)
        lock.unlock()
        logger?("NVST bundle ICE state \(newState.rawValue)")
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        dataChannel.delegate = self
        logger?("NVST bundle inbound data channel '\(dataChannel.label)' id=\(dataChannel.channelId)")
        adopt(dataChannel)
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    /// The seat's audio arrives as an SRTP stream muxed on the bundle port — the native stack's
    /// own socket tap shows ~200 packets a second there against a single `SETUP streamid=video/0/0`,
    /// so audio is negotiated by the bundle's SDP rather than by its own RTSP stream.
    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        logger?("NVST bundle remote stream '\(stream.streamId)' audio=\(stream.audioTracks.count) video=\(stream.videoTracks.count)")
        for track in stream.audioTracks {
            track.isEnabled = true
            // Both under the lock: this runs on libwebrtc's delegate thread while the transport
            // reads the count from its own actor.
            lock.lock()
            remoteAudioTracks.append(track)
            trackedRemoteAudioCount += 1
            lock.unlock()
            logger?("NVST bundle remote audio track '\(track.trackId)' enabled")
        }
        onRemoteAudio?(stream.audioTracks.count)
    }
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        guard newState == .complete else { return }
        lock.withLock { gatheringComplete = true }
        finishHostCandidateWait()
    }
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    // MARK: - RTCDataChannelDelegate

    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        logger?("NVST bundle channel '\(dataChannel.label)' id=\(dataChannel.channelId) state=\(dataChannel.readyState.rawValue)")
        adopt(dataChannel)
    }

    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let shouldLog: Bool = lock.withLock {
            inboundFeedbackBytes += buffer.data.count
            inboundMessagesByLabel[dataChannel.label, default: 0] += 1
            guard loggedInboundMessages < Self.maxLoggedInboundMessages else { return false }
            loggedInboundMessages += 1
            return true
        }
        // Cursor notifications and seat statistics keep arriving for the whole session, long past
        // the logging budget, so they are parsed before the log gate below — returning early here
        // used to drop them.
        let (parsedCommands, _) = NvstControlCommand.parse(buffer.data)
        for command in parsedCommands {
            if let stats = NvstSeatStats.from(command) {
                onSeatStats?(stats)
                continue
            }
            guard let cursor = NvstRemoteCursor.from(command) else {
                describeCursorCommandIfUnparsed(command)
                continue
            }
            // The visibility byte's position is inferred, not captured, so the raw payload is
            // logged next to the decision it produced. "Pointer shows or hides at the wrong time"
            // cannot be told from "the seat said something we misread" without both halves.
            describeCursorCommand(command, decision: cursor.isVisible)
            onRemoteCursor?(cursor)
        }

        guard shouldLog else { return }
        // The seat opens a conversation on `control_channel_reliable` and resets it when we never
        // answer, so what it sends is the next thing we have to understand. NVST command packets
        // start with a 16-bit code (`Command: 0x0206` and friends in Bifrost's own stats), so the
        // leading bytes identify the command.
        // The seat announces the remote-input protocol version, and input stays gated until it
        // arrives. It has been arriving on the control channel since the first capture.
        if let version = NvstRemoteInput.protocolVersion(in: buffer.data) {
            let isNew: Bool = lock.withLock {
                guard negotiatedInputProtocolVersion == nil else { return false }
                negotiatedInputProtocolVersion = version
                return true
            }
            if isNew {
                logger?("NVST bundle input protocol version \(version) from '\(dataChannel.label)'")
                onInputProtocolNegotiated?(version)
            }
        }
        let (commands, trailing) = NvstControlCommand.parse(buffer.data)
        let decoded = commands.map(\.summary).joined(separator: " | ")
        // The seat's remote-input messages are JSON, and their schema is what the client has to
        // answer in kind, so log the text rather than a truncated hex prefix.
        for command in commands where command.isTextual {
            logger?("NVST bundle inbound text \(String(format: "0x%04x", command.code)): \(command.text(limit: 600))")
        }
        // The seat's QoS and frame-pacing messages are the only place it states its own rate
        // decision, and a 32-byte prefix cuts them off mid-record, so those two log in full.
        let hexLimit = commands.contains { $0.code == 0x0101 || $0.code == 0x0111 } ? buffer.data.count : 32
        let hex = [UInt8](buffer.data.prefix(hexLimit)).map { String(format: "%02x", $0) }.joined()
        var line = "NVST bundle inbound '\(dataChannel.label)' id=\(dataChannel.channelId)"
        line += " bytes=\(buffer.data.count) binary=\(buffer.isBinary) cmds=[\(decoded)]"
        if !trailing.isEmpty { line += " unparsed=\(trailing.count)" }
        line += " hex=\(hex)"
        logger?(line)
        for command in commands where command.terminationReason != nil {
            logger?("NVST bundle seat terminated the session: \(command.summary)")
        }
    }

    /// Enough to characterise the control conversation without flooding the log.
    static let maxLoggedInboundMessages = 40

    /// The first channel to actually open with the feedback label is the one the seat accepted; the
    /// rest of the burst is redundant.
    private func adopt(_ dataChannel: RTCDataChannel) {
        adoptControl(dataChannel)
        adoptInput(dataChannel)
        adoptCustom(dataChannel)
        adoptPartiallyReliableControl(dataChannel)
        // Match on "rtcp" rather than the exact label: the channel arrives from the seat, and its
        // name is the seat's to choose.
        guard dataChannel.label.lowercased().contains("rtcp"), dataChannel.readyState == .open else { return }
        lock.lock()
        let alreadyOpen = openFeedbackChannel != nil
        if !alreadyOpen { openFeedbackChannel = dataChannel }
        lock.unlock()
        guard !alreadyOpen else { return }
        logger?("NVST bundle feedback channel open id=\(dataChannel.channelId)")
        onFeedbackChannelOpen?()
    }

    private func adoptPartiallyReliableControl(_ dataChannel: RTCDataChannel) {
        guard dataChannel.label == "control_channel_partially_reliable", dataChannel.readyState == .open else { return }
        lock.lock()
        let isNew = openPartiallyReliableControlChannel == nil
        if isNew { openPartiallyReliableControlChannel = dataChannel }
        lock.unlock()
        guard isNew else { return }
        logger?("NVST bundle partially-reliable control channel open id=\(dataChannel.channelId)")
        onPartiallyReliableControlOpen?()
    }

    private func currentPeerConnection() -> RTCPeerConnection? {
        lock.lock()
        defer { lock.unlock() }
        return peerConnection
    }

    /// Fires when the seat's audio track lands.
    /// The seat's cursor shape/mode notifications, once `trackRemoteCursorImage` is enabled.
    /// Logs one line per *change* in what the seat says about the pointer, with the bytes it said
    /// it in. Unchanged repeats are counted rather than logged: the seat repeats the same
    /// notification many times a second.
    private func describeCursorCommand(_ command: NvstControlCommand, decision: Bool) {
        let hex = command.payload.prefix(16).map { String(format: "%02x", $0) }.joined()
        let key = "\(command.code)/\(hex)/\(decision)"
        let shouldLog: Bool = lock.withLock {
            cursorNotificationCount += 1
            guard key != lastCursorNotification else { return false }
            lastCursorNotification = key
            return true
        }
        guard shouldLog else { return }
        logger?(String(format: "NVST cursor notify code=0x%04x len=%d visible=%@ payload=%@ seen=%d",
                       command.code, command.payload.count, decision ? "y" : "n", hex, cursorNotificationCount))
    }

    /// A cursor-shaped command the parse refused. `0x0110` is the standing ambiguity — OpenNOW
    /// calls it a bitmap cursor, our own capture-derived table calls it video-stream-progress — and
    /// this is what tells us which, from a session where the pointer misbehaved.
    private func describeCursorCommandIfUnparsed(_ command: NvstControlCommand) {
        guard command.code == NvstRemoteCursor.bitmapCursorCode else { return }
        let hex = command.payload.prefix(16).map { String(format: "%02x", $0) }.joined()
        let shouldLog: Bool = lock.withLock {
            guard hex != lastUnparsedCursorPayload else { return false }
            lastUnparsedCursorPayload = hex
            return true
        }
        guard shouldLog else { return }
        logger?(String(format: "NVST cursor unparsed code=0x%04x len=%d payload=%@",
                       command.code, command.payload.count, hex))
    }

    private var lastCursorNotification: String?
    private var lastUnparsedCursorPayload: String?
    private var cursorNotificationCount = 0

    public var onRemoteCursor: (@Sendable (NvstRemoteCursor) -> Void)?
    /// The seat's periodic `0x0101` statistics: game render rate and its latency estimate.
    public var onSeatStats: (@Sendable (NvstSeatStats) -> Void)?

    public var onRemoteAudio: (@Sendable (Int) -> Void)?

    /// Inbound audio counters straight from libwebrtc, which is the only view of whether the seat
    /// is sending audio at all: the track object exists as soon as the SDP negotiates it, so its
    /// presence proves nothing on its own.
    /// Receiving a packet and decoding it are different things: a payload the decoder rejects still
    /// counts as received, so the sample and concealment counters are what say audio is actually
    /// being produced.
    public struct AudioReception: Sendable {
        public var packets: UInt64 = 0
        public var bytes: UInt64 = 0
        public var samples: UInt64 = 0
        public var concealed: UInt64 = 0
        public var discarded: UInt64 = 0
    }

    public func audioReception() async -> AudioReception? {
        guard let connection = currentPeerConnection() else { return nil }
        // `statistics` answers through a callback, and a continuation that is never resumed hangs
        // its caller for good — `logCounters` is awaited by teardown, so that would be a stream that
        // never tears down. `close()` nils the connection, which covers the ordinary path; this
        // covers the race where it closed after the read above.
        guard connection.signalingState != .closed else { return nil }
        let report = await withCheckedContinuation { continuation in
            connection.statistics { continuation.resume(returning: $0) }
        }
        var reception = AudioReception()
        var sawAudio = false
        for (_, statistics) in report.statistics
        where statistics.type == "inbound-rtp" && (statistics.values["kind"] as? String) == "audio" {
            sawAudio = true
            func number(_ key: String) -> UInt64 { (statistics.values[key] as? NSNumber)?.uint64Value ?? 0 }
            reception.packets += number("packetsReceived")
            reception.bytes += number("bytesReceived")
            reception.samples += number("totalSamplesReceived")
            reception.concealed += number("concealedSamples")
            reception.discarded += number("packetsDiscarded")
        }
        return sawAudio ? reception : nil
    }

    public func audioReceiveStatistics() async -> (packets: UInt64, bytes: UInt64)? {
        guard let connection = currentPeerConnection() else { return nil }
        let report = await withCheckedContinuation { continuation in
            connection.statistics { continuation.resume(returning: $0) }
        }
        var packets: UInt64 = 0
        var bytes: UInt64 = 0
        for (_, statistics) in report.statistics
        where statistics.type == "inbound-rtp" && (statistics.values["kind"] as? String) == "audio" {
            packets += (statistics.values["packetsReceived"] as? NSNumber)?.uint64Value ?? 0
            bytes += (statistics.values["bytesReceived"] as? NSNumber)?.uint64Value ?? 0
        }
        return (packets, bytes)
    }

    /// Fires when `control_channel_partially_reliable` opens, so QoS feedback can start.
    public var onPartiallyReliableControlOpen: (@Sendable () -> Void)?

    private func adoptCustom(_ dataChannel: RTCDataChannel) {
        guard dataChannel.label.hasPrefix("custom_message_on_sctp_private"), dataChannel.readyState == .open else { return }
        lock.lock()
        let isNew = openCustomChannels[dataChannel.label] == nil
        if isNew { openCustomChannels[dataChannel.label] = dataChannel }
        lock.unlock()
        guard isNew else { return }
        logger?("NVST bundle custom channel open '\(dataChannel.label)' id=\(dataChannel.channelId)")
    }

    /// The input plane. Partially reliable, because a stale mouse delta is worse than a lost one.
    private func adoptInput(_ dataChannel: RTCDataChannel) {
        guard dataChannel.readyState == .open else { return }
        let isReliable = dataChannel.label == "input_channel_v1"
        guard isReliable || dataChannel.label == "input_channel_partially_reliable" else { return }
        lock.lock()
        let alreadyOpen = isReliable ? openReliableInputChannel != nil : openInputChannel != nil
        if !alreadyOpen {
            if isReliable { openReliableInputChannel = dataChannel } else { openInputChannel = dataChannel }
        }
        lock.unlock()
        guard !alreadyOpen else { return }
        logger?("NVST bundle input channel open '\(dataChannel.label)' id=\(dataChannel.channelId)")
    }

    /// `control_channel_reliable` is where the seat's client-timeout is measured, so its opening is
    /// what starts the keepalive.
    private func adoptControl(_ dataChannel: RTCDataChannel) {
        guard dataChannel.label == "control_channel_reliable", dataChannel.readyState == .open else { return }
        lock.lock()
        let alreadyOpen = openControlChannel != nil
        if !alreadyOpen { openControlChannel = dataChannel }
        lock.unlock()
        guard !alreadyOpen else { return }
        logger?("NVST bundle control channel open id=\(dataChannel.channelId)")
        onControlChannelOpen?()
    }
}
