import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

/// NVST transport with **no NVIDIA libraries**: OpenNOW's own RTSP control plane, raw-SRTP
/// Mjolnir video receiver, and VideoToolbox decode.
///
/// Pipeline, in the order the official client establishes it:
/// 1. RTSPS-over-WSS control channel to the seat's `:322` endpoint (OPTIONS → DESCRIBE → SETUP).
/// 2. The video handoff is *derived* from those answers — it never arrives through signaling —
///    including the SRTP master key, which this client generates and ANNOUNCEs itself.
/// 3. The raw-SRTP Mjolnir socket starts receiving before ANNOUNCE (Bifrost arms
///    `MjolnirVideoReceiver` first), then ANNOUNCE, then PLAY.
/// 4. Access units decode through VideoToolbox and are published as `NativeNVSTVideoFrame`s and
///    decoded `CVPixelBuffer`s.
///
/// Input, audio and the RTCP feedback plane ride the ICE/DTLS bundle's SCTP data channels, which
/// this transport brings up through `NvstWebRtcBundle` when the seat negotiates the official
/// cloud path; the bare Mjolnir socket keeps carrying video and its own SRTCP reports on the
/// legacy shape. Microphone capture is the remaining scope limit: its configuration is accepted
/// (the host applies it before `start`, so throwing there would kill every launch) but enabling
/// capture is not implemented.
/// This is the only transport. `OPN_NVST_BIFROST_FREE` and the
/// `OPNNVSTBifrostFreeTransportEnabled` default selected it back when the vendored NVIDIA
/// frameworks still shipped alongside it; `vendor/gfn-runtime/` is gone, so there is nothing left to
/// select between and no fallback to hide a failure behind.
public actor NvstBifrostFreeTransport: NativeNVSTTransport {
    /// `OPN_NVST_LEGACY_ANNOUNCE=1` negotiates the pre-bundle shape even when the seat advertises
    /// the official cloud path. The legacy path needs no DTLS, so it separates "the seat gates
    /// media on the bundle" from "the seat gates media on something else".
    public static var forcesLegacyPath: Bool {
        ProcessInfo.processInfo.environment["OPN_NVST_LEGACY_ANNOUNCE"] == "1"
    }

    /// `OPN_NVST_WEBRTC_BUNDLE=0` skips libwebrtc entirely and keeps the bare-STUN puncher on the
    /// bundle socket.
    ///
    /// Measured against the seat: the official client's bundle STUN is 76 bytes with exactly
    /// USERNAME + MESSAGE-INTEGRITY + FINGERPRINT, and our bare-STUN probe drew 3076 answers.
    /// libwebrtc sends 104 bytes (adding PRIORITY, ICE-CONTROLLED and goog attributes) and drew
    /// exactly one, because the seat is Bifrost's minimal `NattHolePunch::HandleStun`, not an ICE
    /// agent. This switch isolates whether media is gated on DTLS at all, or only on a live punch.
    public static var usesWebRtcBundle: Bool {
        ProcessInfo.processInfo.environment["OPN_NVST_WEBRTC_BUNDLE"] != "0"
    }

    /// Decoded frames for the renderer. Set before `connect`.
    public typealias PixelBufferSink = @Sendable (CVPixelBuffer, CMTime, Bool) -> Void

    let pixelBufferSink: PixelBufferSink?
    let logger: (@Sendable (String) -> Void)?
    private let controlTimeout: Duration
    var reserver: NvstLocalBundleReserver?
    var session: NvstRtspSession?
    var receiver: NvstMjolnirReceiver?
    var bundleProbe: NvstBundleIceProbe?
    var bundle: NvstWebRtcBundle?
    var feedbackSender: NvstFeedbackSender?
    var decoder: NvstVideoToolboxDecoder?
    /// Decode + frame acknowledgement, deliberately off this actor. See `NvstVideoPipeline`.
    var videoPipeline: NvstVideoPipeline?
    /// The session-relative time base both this actor and the video pipeline stamp with.
    let clock = NvstSessionClock()
    /// Ordered hand-off of raw access units to the media-session seam, and the single task that
    /// drains it.
    var mediaFrameContinuation: AsyncStream<NativeNVSTVideoFrame>.Continuation?
    var mediaForwardingTask: Task<Void, Never>?
    private var connection: NativeNVSTTransportConnection?
    var terminationContinuation: AsyncStream<NativeNVSTTransportTermination>.Continuation?
    private var terminationStream: AsyncStream<NativeNVSTTransportTermination>?
    var lastHandoff: NVSTVideoHandoff?
    private var heartbeatTask: Task<Void, Never>?
    var controlKeepAliveTask: Task<Void, Never>?
    var qosFeedbackTask: Task<Void, Never>?
    var qosSequence: UInt32 = 0
    var lastQosBytesReceived: UInt64 = 0
    var lastQosDelayMicroseconds: UInt32 = 0
    /// A 60 Hz display's frame interval, which is what the captured client reports.
    static let targetFrameTimeMicroseconds: UInt32 = 16000

    /// The client's own display cadence, which is what the pacer's target must describe. The
    /// capture pins it down: the native stack's per-frame field never leaves 15577...16809 µs and
    /// its pacing error never exceeds the 16000 µs target, in a session whose frames arrive every
    /// 16.6 ms. Reporting the *observed* arrival interval instead — which is what this first did —
    /// is a self-fulfilling lock: at 8 frames per second it tells the pacer the client can only
    /// take a frame every 125 ms, so the pacer has no reason to ever send more.
    /// The frame interval the pacer is told to aim for: the **session's** frame rate, not the
    /// client display's.
    ///
    /// An earlier version derived this from the display refresh, which the capture refutes: the
    /// native stack was running on a `1920x1080@75` panel and still reported ~15905 µs, which is
    /// 62.9 fps — its 60 fps session, not its 75 Hz screen. Reading the display would have told a
    /// 120 Hz Mac's seat to pace a 60 fps stream at 8333 µs.
    var sessionFrameTimeMicroseconds: UInt32 {
        guard let fps = negotiatedFps, fps > 0 else { return Self.targetFrameTimeMicroseconds }
        return UInt32(1_000_000 / fps)
    }
    var audioReceiver: NvstAudioReceiver?
    var remoteAudioTrackCount = 0
    /// The frame rate the seat agreed to, read out of the allocation's negotiated profile. The
    /// profile is configurable end to end — the session request carries `framesPerSecond` — so
    /// nothing here may assume 60.
    private var negotiatedFps: Int?
    /// Human server name from the CloudMatch allocation ("np-tyo-01" style), for the stats HUD.
    var sessionServerLocation: String?
    /// The seat's latest `0x0101` statistics: the HUD's GAME FPS and MS come from here.
    var latestSeatStats: NvstSeatStats?
    private var seatStatsReceived = 0

    /// Stores the seat's statistics message and logs a calibration sample once a second — the
    /// meaning of two of its fields is still being pinned against live sessions.
    func recordSeatStats(_ stats: NvstSeatStats) {
        latestSeatStats = stats
        seatStatsReceived += 1
        if seatStatsReceived <= 5 || seatStatsReceived % 60 == 0 {
            logger?("NVST \(stats.summary) n=\(seatStatsReceived)")
        }
    }
    var textCharactersTyped = 0
    var textBytesDropped = 0
    var gamepadSequence: UInt16 = 0
    var didRegisterGamepad = false
    var gamepadPacketsSent = 0
    var gamepadSendFailures = 0
    var didActivateInput = false
    var qosReportsSent = 0
    var qosReportFailures = 0
    var rtpStatsReportsSent = 0
    var controlStatsReportsSent = 0
    var lastRtpStatsFrame: UInt64 = 0
    var controlStatsLastSentAt: Date?
    var lastIdrRequestAt: Date?
    var idrRequestsSent = 0
    var lastInvalidationAt: Date?
    var pendingInvalidationFirst: UInt32?
    var pendingInvalidationLast: UInt32?
    var invalidationsSent = 0
    var inputEventsSent = 0
    var inputSequence: UInt16 = 0
    var didAnnounceClientState = false
    /// Set once the bundle comes up; owned by the shared clock so the off-actor video pipeline
    /// stamps its acks from the same origin.
    var sessionStartedAt: Date? { clock.startDate }
    /// Set the moment teardown begins, so a late channel-open callback cannot restart a feedback
    /// loop teardown has just cancelled.
    var isTornDown = false

    /// The frame rate the user configured, passed in from the view that already holds it reliably.
    /// The allocation JSON is re-parsed as a fallback, but that has proven fragile — when its fps
    /// field is missing or nested unexpectedly the pacing defaults to 60 and a 120 stream is held
    /// there. The configured value is authoritative.
    private let configuredFps: Int?
    /// The user's configured bitrate ceiling in kbps, authoritative over the JSON parse for the
    /// same reason as fps — a missing/nested field defaulted the announced cap and the stream
    /// parked low.
    let configuredMaxBitrateKbps: Int?
    /// The user's prefilter (server-side AI sharpen/denoise) selection. There is no session-JSON
    /// fallback for these the way there is for fps/bitrate — the seat never echoes a negotiated
    /// prefilter back — so the app's own configured value is the only source.
    private let configuredPrefilterMode: Int?
    private let configuredPrefilterSharpness: Int?
    private let configuredPrefilterDenoise: Int?
    private let configuredPrefilterModel: Int?

    public init(pixelBufferSink: PixelBufferSink? = nil,
                configuredFps: Int? = nil,
                configuredMaxBitrateKbps: Int? = nil,
                configuredPrefilterMode: Int? = nil,
                configuredPrefilterSharpness: Int? = nil,
                configuredPrefilterDenoise: Int? = nil,
                configuredPrefilterModel: Int? = nil,
                logger: (@Sendable (String) -> Void)? = nil,
                controlTimeout: Duration = .seconds(20)) {
        self.pixelBufferSink = pixelBufferSink
        self.configuredFps = configuredFps
        self.configuredMaxBitrateKbps = configuredMaxBitrateKbps
        self.configuredPrefilterMode = configuredPrefilterMode
        self.configuredPrefilterSharpness = configuredPrefilterSharpness
        self.configuredPrefilterDenoise = configuredPrefilterDenoise
        self.configuredPrefilterModel = configuredPrefilterModel
        self.logger = logger
        self.controlTimeout = controlTimeout
    }

    // MARK: - Lifecycle

    public func prepare() async throws -> NVSTNativeBridgeStatus {
        // There is no native library to probe: that is the whole point of this transport.
        NVSTNativeBridgeStatus(
            libraryURL: Bundle.main.bundleURL,
            bundledArtifactURLs: [],
            resolvedSymbols: [],
            runtimeAvailable: true
        )
    }

    public func connect(allocation: NativeNVSTSessionAllocation, mediaReceiver: any NativeNVSTMediaReceiver) async throws -> NativeNVSTTransportConnection {
        guard connection == nil else { throw NativeNVSTError.alreadyRunning }

        let endpoints = NvstRtspEndpoints.collect(
            rawSessionJSON: allocation.rawSessionJSON,
            fallbackHost: Self.host(from: allocation.signalingServer)
        )
        guard !endpoints.isEmpty else {
            throw NativeNVSTError.transportFailed("This session provided no RTSPS control endpoint, so NVST cannot be negotiated.")
        }
        sessionServerLocation = Self.sessionServerLocation(for: allocation)
        let profile = Self.resolvedStreamProfile(allocation: allocation,
                                                 configuredFps: configuredFps,
                                                 configuredMaxBitrateKbps: configuredMaxBitrateKbps)
        negotiatedFps = profile.fps
        negotiatedResolution = profile.resolution
        negotiatedCodec = profile.codec
        // Says exactly what we parsed and what we will pace to, so a "stuck at 60" report separates
        // "we failed to read the fps" (fps=nil, pacing 16667) from "the seat dropped it" (fps=120,
        // pacing 8333, stream still 60 — the seat's own dynamic fps control under 5K load).
        logger?("NVST profile fps=\(profile.fps.map(String.init) ?? "nil") resolution=\(profile.resolution ?? "nil")"
                + " codec=\(profile.codec ?? "nil") pacingTargetUs=\(sessionFrameTimeMicroseconds) maxKbps=\(profile.maximumBitrateKbps.map(String.init) ?? "nil") initKbps=\(profile.bitrateKbps.map(String.init) ?? "nil")")

        let stream = AsyncStream<NativeNVSTTransportTermination>.makeStream()
        terminationStream = stream.stream
        terminationContinuation = stream.continuation

        let reserver = NvstLocalBundleReserver(bundleProvider: { [weak self] handoff in
            await self?.bringUpBundle(handoff: handoff)
        })
        self.reserver = reserver
        let logger = self.logger
        let negotiator = NvstRtspNegotiator(reserver: reserver, logger: logger)
        let input = negotiationInput(sessionID: allocation.session.id, endpoints: endpoints, profile: profile)

        let negotiated: NvstRtspSession
        do {
            negotiated = try await negotiator.negotiate(
                input,
                onVideoReady: { [weak self] handoff in
                    try await self?.startVideo(handoff: handoff, mediaReceiver: mediaReceiver)
                }
            )
        } catch {
            await teardown(reason: "negotiation failed")
            throw NativeNVSTError.transportFailed(error.localizedDescription)
        }
        session = negotiated
        logger?("NVST Bifrost-free session established (steps: \(negotiated.steps.joined(separator: " → ")))")

        startHeartbeat()
        let status = try await prepare()
        let established = NativeNVSTTransportConnection(session: allocation.session, runtimeStatus: status)
        connection = established
        return established
    }

    /// What the RTSP negotiator is asked for: the resolved profile plus the client-side switches.
    func negotiationInput(sessionID: String, endpoints: [String], profile: StreamProfile) -> NvstRtspNegotiationInput {
        NvstRtspNegotiationInput(
            sessionID: sessionID,
            rtspsEndpoints: endpoints,
            resolution: profile.resolution,
            fps: profile.fps,
            codec: profile.codec,
            bitrateKbps: profile.bitrateKbps,
            maximumBitrateKbps: profile.maximumBitrateKbps,
            prefilterMode: configuredPrefilterMode,
            prefilterSharpness: configuredPrefilterSharpness,
            prefilterDenoise: configuredPrefilterDenoise,
            prefilterModel: configuredPrefilterModel,
            timeout: controlTimeout,
            // The negotiator raises this to 1 when the bundle comes up; false is the fallback that
            // keeps feedback as SRTCP on the Mjolnir socket.
            rtcpOnSctp: false,
            forcesLegacyPath: Self.forcesLegacyPath,
            disablesOwdCongestionControl: !Self.usesOwdCongestionControl,
            announcesExtendedSettings: Self.announcesExtendedSettings,
            echoesOfferedAttributes: Self.echoesOfferedAttributes
        )
    }

    /// Receive/decode counters are otherwise only reported in the end-of-stream report, which is
    /// useless while diagnosing a live run: this separates "no packets arrive" from "packets do
    /// not authenticate" from "frames assemble but do not decode", every two seconds.
    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                await self.logCounters()
            }
        }
    }

    private func logCounters() async {
        guard let receiver else { return }
        let stats = receiver.stats
        // Session peak tracker, so a manual test (play a 120 title into gameplay for ~30s) yields a
        // self-verdicting line instead of forcing a grep of the raw per-interval arrays. Peak
        // interval fps = Δframes / Δmedia-seconds between counter dumps; peak throughput = the
        // largest per-second bucket the receiver recorded. The verdict answers the standing goal
        // (>60fps and bitrate ramping above the ~24Mbps initial park) directly.
        let mediaNow = Double(stats.lastRtpTimestamp &- (stats.firstRtpTimestamp ?? 0)) / Double(NvstVideoToolboxDecoder.clockRate)
        let dFrames = stats.framesEmitted &- lastSummaryFrames
        let dMedia = mediaNow - lastSummaryMediaSeconds
        if dMedia > 0.25, dFrames > 0 {
            let intervalFps = Double(dFrames) / dMedia
            if intervalFps.isFinite, intervalFps > peakIntervalFps { peakIntervalFps = intervalFps }
        }
        lastSummaryFrames = stats.framesEmitted
        lastSummaryMediaSeconds = mediaNow
        if let maxBucket = stats.frameBytesPerSecond.max() {
            let mbps = Double(maxBucket) * 8 / 1_000_000
            if mbps > peakIntervalMbps { peakIntervalMbps = mbps }
        }
        logger?(String(format: "NVST SESSION SUMMARY peakStreamFps=%.1f peakStreamMbps=%.1f negFps=%@ | verdict fps%@60 bitrate%@24Mbps (fps cap lifted via announce maxFPS; bitrate bounded by initialBitrateKbps since the seat never ramps up — low-complexity scenes read low, that is content not a cap)",
                       peakIntervalFps, peakIntervalMbps,
                       negotiatedFps.map(String.init) ?? "nil",
                       peakIntervalFps > 60.5 ? ">" : "<=",
                       peakIntervalMbps > 24 ? ">" : "<="))
        if let audioReceiver { logger?("NVST audio socket \(audioReceiver.diagnosticSummary)") }
        let audio = await bundle?.audioReception()
        logger?("NVST audio tracks=\(bundle?.remoteAudioTrackCount ?? 0) pktIn=\(audio?.packets ?? 0) bytesIn=\(audio?.bytes ?? 0)"
                + " samples=\(audio?.samples ?? 0) concealed=\(audio?.concealed ?? 0) discarded=\(audio?.discarded ?? 0)")
        let video = videoPipeline?.snapshot ?? NvstVideoPipeline.Counters()
        logger?("NVST counters auth=\(stats.authenticatedPackets) fec=\(stats.fecPackets) dropped=\(stats.droppedPackets) rtpLoss=\(stats.finalizedLossPackets) frames=\(stats.framesEmitted) keyframes=\(stats.keyframesEmitted) recoveries=\(stats.recoveries) sofFlagged=\(stats.startOfFrameFlagged) sofOk=\(stats.startOfFrameAccepted) abandoned=\(stats.abandonedFrames) rrFail=\(stats.receiverReportFailures)\(stats.lastReceiverReportFailure.map { " rrErr=\($0)" } ?? "") multiBlock=\(stats.multiBlockPackets) maxBlock=\(stats.highestFecLastBlock) decoded=\(decoder?.decodedFrameCount ?? 0) decodeFailed=\(decoder?.failedFrameCount ?? 0) decodeErr=\(decoder?.failureStatusSummary ?? "-") noParamSets=\(video.missingParameterSetFrames) idrOut=\(idrRequestsSent) invalidOut=\(invalidationsSent) inputOut=\(inputEventsSent) padOut=\(gamepadPacketsSent) padFail=\(gamepadSendFailures) padReg=\(didRegisterGamepad) textTyped=\(textCharactersTyped) textDroppedBytes=\(textBytesDropped) inputReady=\(bundle?.isInputReady == true) rrOut=\(stats.receiverReportsSent) frac=\(stats.lastFractionLost) lost=\(stats.lastCumulativeLost) jitter=\(stats.lastJitter) seqSpan=\(stats.sequenceSpan) negFps=\(negotiatedFps.map(String.init) ?? "nil") mediaSeconds=\(String(format: "%.2f", Double(stats.lastRtpTimestamp &- (stats.firstRtpTimestamp ?? 0)) / Double(NvstVideoToolboxDecoder.clockRate))) fidxChanges=\(stats.frameIndexChanges) maxFrame=\(stats.maxFrameBytesPerSecond.map { String($0) }.joined(separator: ",")) bytesPerSec=\(stats.frameBytesPerSecond.map { String($0 / 1000) }.joined(separator: ",")) fpsPerSec=\(stats.framesPerSecond.map(String.init).joined(separator: ",")) paceOut=\(video.pacingReportsSent) paceFail=\(video.pacingReportFailures) ackOut=\(video.frameAcksSent) ackFail=\(video.frameAckFailures) qosOut=\(qosReportsSent) qosFail=\(qosReportFailures) rtpStatsOut=\(rtpStatsReportsSent) ccStatsOut=\(controlStatsReportsSent) ssrc=\(stats.boundSSRC.map { String(format: "0x%08x", $0) } ?? "-")")
        // Which pipeline stage a latency spike lives in. `peak*` are per-stage session maxima, so a
        // single 500 ms stall is still visible after the average has recovered.
        logger?(String(format: "NVST frame stages slow=%d frames=%llu resyncs=%d skipped=%d abandoned=%d lastLatency=%.1fms inputSendTotal=%.0fms inputSendPeak=%.1fms",
                       video.slowFrames, video.framesHandled, video.latencyResyncs,
                       video.framesSkippedForLatency, video.abandonedResyncs,
                       video.lastDecodeLatencyMilliseconds,
                       inputSendTotalMs, inputSendPeakMs)
                + " \(video.timingSummary)"
                + " decoderSessions=\(decoder?.sessionCreationCount ?? 0)"
                + " hwDecode=\(decoder?.isHardwareAccelerated == true)"
                + " decode\(decoder?.stageTimingSummary ?? "-")")
        await logHudCounters(receiver: receiver, stats: stats)
    }

    /// The HUD's own numbers, so a headless run can verify them without the overlay: RTT comes from
    /// the bundle's ICE candidate pair and the resolution from the decoded surface.
    func logHudCounters(receiver: NvstMjolnirReceiver, stats: NvstReceiverStats) async {
        // The HUD's own numbers, so a headless run can verify them without the overlay: RTT comes
        // from the bundle's ICE candidate pair and the resolution from the decoded surface.
        bundle?.refreshTransportStatistics()
        let keepAlive = await session?.controlKeepAliveSummary() ?? ""
        logger?(String(format: "NVST hud rtt=%.1fms mjolnirRtt=%.1fms ctrl[%@] jitter=%.1fms decodedRes=%@ negotiatedRes=%@ gameFps=%.1f",
                       bundle?.roundTripMilliseconds ?? -1,
                       receiver.roundTripMilliseconds,
                       keepAlive,
                       Double(stats.lastJitter) * 1000 / Double(NvstVideoToolboxDecoder.clockRate),
                       decoder?.decodedResolution ?? "-",
                       negotiatedResolution ?? "-",
                       latestSeatStats?.gameFramesPerSecond ?? -1))
        // Datagram-class counts answer the prior question: is anything arriving at all?
        logger?("NVST mjolnir \(receiver.inbound.summary) rcvbuf=\(receiver.receiveBufferBytes)"
                + " perPacket[\(receiver.processStageTimings.summary(packets: stats.authenticatedPackets + stats.droppedPackets))]"
                + " \(receiver.fecFindings.summary)"
                + " nacks=\(receiver.nackSummary.requests)/\(receiver.nackSummary.packets)pkt")
        if let bundle {
            logger?("NVST bundle \(bundle.diagnosticSummary) reportsSent=\(feedbackSender?.sentReportCount ?? 0)")
        }
        if let bundleProbe {
            logger?("NVST probe \(bundleProbe.snapshot.summary)")
        }
        if let sender = feedbackSender, let ssrc = receiver.stats.boundSSRC {
            sender.updateMediaSSRC(ssrc)
            sender.updateMediaState(highestExtendedSequence: receiver.stats.highestSequence,
                                    cumulativeLost: receiver.stats.lastCumulativeLost,
                                    fractionLost: receiver.stats.lastFractionLost,
                                    interarrivalJitter: receiver.stats.lastJitter)
        }
    }

    public func disconnect() async {
        await teardown(reason: "disconnect")
    }

    public func resetForRecovery() async {
        await teardown(reason: "recovery")
    }

    public func terminalEvents() async -> AsyncStream<NativeNVSTTransportTermination> {
        terminationStream ?? AsyncStream { $0.finish() }
    }

    public func diagnosticMetadata() async -> [String: String] {
        let stats = receiver?.stats
        return [
            "transport": "nvst-bifrost-free",
            "nvidiaLibraries": "none",
            "rtspSession": session?.sessionIdentifier ?? "-",
            "rtspSteps": session?.steps.joined(separator: ",") ?? "-",
            "videoPeer": lastHandoff.map { "\($0.videoPeerIP):\($0.videoPeerPort)" } ?? "-",
            "mjolnirPort": lastHandoff.flatMap { $0.mjolnirUDPPort.map(String.init) } ?? "-",
            "srtpProfile": lastHandoff?.srtpProfile.rawValue ?? "-",
            "codec": lastHandoff?.codec.rawValue ?? "-",
            "authenticatedPackets": String(stats?.authenticatedPackets ?? 0),
            "fecPackets": String(stats?.fecPackets ?? 0),
            "droppedPackets": String(stats?.droppedPackets ?? 0),
            "framesAssembled": String(stats?.framesEmitted ?? 0),
            "keyframes": String(stats?.keyframesEmitted ?? 0),
            "recoveries": String(stats?.recoveries ?? 0),
            "framesDecoded": String(decoder?.decodedFrameCount ?? 0),
            "framesFailed": String(decoder?.failedFrameCount ?? 0),
            "mjolnirInbound": receiver?.inbound.summary ?? "-",
            "bundle": bundle?.diagnosticSummary ?? "-",
            "bundleProbe": bundleProbe?.snapshot.summary ?? "-",
        ]
    }

    // Cursors for the periodic performance snapshot, kept next to the rest of the actor's
    // state; the code that reads them lives in NvstBifrostFreeInput.swift.
    var inputSendTotalMs = 0.0
    var inputSendPeakMs = 0.0
    var lastSnapshotAt: Date?
    var lastSnapshotFrames: UInt64 = 0
    var lastSnapshotBytes: UInt64 = 0
    var lastSnapshotPackets: UInt64 = 0
    var lastSnapshotLost: UInt64 = 0
    private var peakIntervalFps: Double = 0
    private var peakIntervalMbps: Double = 0
    private var lastSummaryFrames: UInt64 = 0
    private var lastSummaryMediaSeconds: Double = 0
    var negotiatedResolution: String?
    var negotiatedCodec: String?

    // `internal(set)` rather than `private(set)`: the type's own extensions in the neighbouring
    // files write these, and the public contract is unchanged — nothing outside the module can.
    /// Whether the game currently wants a pointer drawn. Nil until the seat says.
    public internal(set) var remoteCursorVisible: Bool?
    var didDisableCursorCapture = false
    /// Raised when the game shows or hides its pointer, so the client can match it and avoid
    /// drawing a second one (or leaving one floating during mouselook).
    public internal(set) var onRemoteCursorVisibilityChanged: (@MainActor @Sendable (Bool) -> Void)?

    /// The stream profile this session negotiates with, after the app's configured overrides.
    static func resolvedStreamProfile(allocation: NativeNVSTSessionAllocation,
                                              configuredFps: Int?,
                                              configuredMaxBitrateKbps: Int?) -> StreamProfile {
        var profile = Self.streamProfile(from: allocation)
        // The configured fps wins: the app knows it directly, while the JSON parse is a fallback.
        if let configuredFps, configuredFps > 0 { profile.fps = configuredFps }
        if let configuredMaxBitrateKbps, configuredMaxBitrateKbps > 0 {
            profile.maximumBitrateKbps = configuredMaxBitrateKbps
            // The INITIAL rate — not the ceiling — is what actually bounds throughput, because the
            // seat's congestion control never ramps up on this path: the stream settles at ~65% of
            // initialBitrateKbps (the announced relaxMaxBitrate.customAvgBitrateThresholdPercent:65)
            // no matter how high the ceiling is. Measured at 5120x2160@120 under a saturating
            // all-intra load (~120 keyframes/s — a harsher demand than real
            // gameplay):
            //   initial 25000 -> 16.2 Mbps, clean
            //   initial 40000 -> 29.2 Mbps, dropped=0 lost=0 decodeFailed=0, 120 fps held
            //   initial 60000 -> 32.9 Mbps but dropped=11911 lost=23966 (floods the link)
            // So the initial rate has to BE the target, not a cautious opening bid. An earlier
            // 40000 clamp here was calibrated before the SRTP receive path was fixed, and it is
            // exactly what pinned real sessions at ~26 Mbps (0.65 x 40000) no matter what ceiling
            // the user picked. The loss that motivated the clamp was ours — a 129 us/packet decrypt
            // saturating one core at ~3200 packets/s — and at 4.1 us/packet the receive path has
            // ~2500 Mbps of headroom, measuring 0.05% loss at initial 100000 under the all-intra
            // load and none at all under normal content. Ask for what the user configured.
            profile.bitrateKbps = min(configuredMaxBitrateKbps, Self.maximumInitialBitrateKbps)
        }
        // DIAGNOSTIC (OPN_NVST_INITIAL_KBPS): the measured stream plateaus at 65% of
        // initialBitrateKbps (16.2 Mbps for the 25000 default — exactly the announced
        // relaxMaxBitrate.customAvgBitrateThresholdPercent:65) and never ramps toward the ceiling,
        // so the initial rate — not the max — is what actually bounds throughput. This override
        // exists to measure how the plateau tracks it.
        if let override = ProcessInfo.processInfo.environment["OPN_NVST_INITIAL_KBPS"].flatMap(Int.init),
           override > 0 {
            profile.bitrateKbps = override
        }
        return profile
    }

    // MARK: - Teardown

    func teardown(reason: String) async {
        isTornDown = true
        heartbeatTask?.cancel()
        heartbeatTask = nil
        controlKeepAliveTask?.cancel()
        controlKeepAliveTask = nil
        qosFeedbackTask?.cancel()
        qosFeedbackTask = nil
        audioReceiver?.stop()
        audioReceiver = nil
        await logCounters()
        feedbackSender?.stop()
        feedbackSender = nil
        // The media receivers and pipeline stop before the bundle closes, so in-flight frame acks
        // and feedback packets do not fail-and-log against a closing control channel.
        receiver?.stop()
        receiver = nil
        // Stops before the decoder is invalidated: an in-flight access unit must not reach a
        // torn-down session.
        videoPipeline?.stop()
        videoPipeline = nil
        bundle?.close()
        bundle = nil
        bundleProbe?.stop()
        bundleProbe = nil
        mediaFrameContinuation?.finish()
        mediaFrameContinuation = nil
        mediaForwardingTask?.cancel()
        mediaForwardingTask = nil
        decoder?.invalidate()
        decoder = nil
        if let session {
            await session.release(reason)
        }
        session = nil
        reserver?.release()
        reserver = nil
        connection = nil
        terminationContinuation?.finish()
        terminationContinuation = nil
        terminationStream = nil
    }

}
