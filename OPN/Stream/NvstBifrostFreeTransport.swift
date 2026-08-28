import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

/// NVST transport with **no NVIDIA libraries**: MacForce Now's own RTSP control plane, raw-SRTP
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
/// Scope limit worth stating plainly: input, audio and microphone ride the ICE/DTLS bundle's SCTP
/// data channels, which this transport does not bring up yet. Until it does, the feedback plane
/// stays on the Mjolnir socket's SRTCP (`general.rtcpOnSctp:0`) and input calls fail loudly rather
/// than silently dropping events.
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

    private let pixelBufferSink: PixelBufferSink?
    private let logger: (@Sendable (String) -> Void)?
    private let controlTimeout: Duration
    private var reserver: NvstLocalBundleReserver?
    private var session: NvstRtspSession?
    private var receiver: NvstMjolnirReceiver?
    private var bundleProbe: NvstBundleIceProbe?
    private var bundle: NvstWebRtcBundle?
    private var feedbackSender: NvstFeedbackSender?
    private var decoder: NvstVideoToolboxDecoder?
    /// Decode + frame acknowledgement, deliberately off this actor. See `NvstVideoPipeline`.
    private var videoPipeline: NvstVideoPipeline?
    /// The session-relative time base both this actor and the video pipeline stamp with.
    private let clock = NvstSessionClock()
    /// Ordered hand-off of raw access units to the media-session seam, and the single task that
    /// drains it.
    private var mediaFrameContinuation: AsyncStream<NativeNVSTVideoFrame>.Continuation?
    private var mediaForwardingTask: Task<Void, Never>?
    private var connection: NativeNVSTTransportConnection?
    private var terminationContinuation: AsyncStream<NativeNVSTTransportTermination>.Continuation?
    private var terminationStream: AsyncStream<NativeNVSTTransportTermination>?
    private var lastHandoff: NVSTVideoHandoff?
    private var heartbeatTask: Task<Void, Never>?
    private var controlKeepAliveTask: Task<Void, Never>?
    private var qosFeedbackTask: Task<Void, Never>?
    private var qosSequence: UInt32 = 0
    private var lastQosBytesReceived: UInt64 = 0
    private var lastQosDelayMicroseconds: UInt32 = 0
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
    private var sessionFrameTimeMicroseconds: UInt32 {
        guard let fps = negotiatedFps, fps > 0 else { return Self.targetFrameTimeMicroseconds }
        return UInt32(1_000_000 / fps)
    }
    private var audioReceiver: NvstAudioReceiver?
    private var remoteAudioTrackCount = 0
    /// The frame rate the seat agreed to, read out of the allocation's negotiated profile. The
    /// profile is configurable end to end — the session request carries `framesPerSecond` — so
    /// nothing here may assume 60.
    private var negotiatedFps: Int?
    /// Human server name from the CloudMatch allocation ("np-tyo-01" style), for the stats HUD.
    private var sessionServerLocation: String?
    /// The seat's latest `0x0101` statistics: the HUD's GAME FPS and MS come from here.
    private var latestSeatStats: NvstSeatStats?
    private var seatStatsReceived = 0

    /// Stores the seat's statistics message and logs a calibration sample once a second — the
    /// meaning of two of its fields is still being pinned against live sessions.
    private func recordSeatStats(_ stats: NvstSeatStats) {
        latestSeatStats = stats
        seatStatsReceived += 1
        if seatStatsReceived <= 5 || seatStatsReceived % 60 == 0 {
            logger?("NVST \(stats.summary) n=\(seatStatsReceived)")
        }
    }
    private(set) var textCharactersTyped = 0
    private(set) var textCharactersDropped = 0
    private var gamepadSequence: UInt16 = 0
    private var didRegisterGamepad = false
    private(set) var gamepadPacketsSent = 0
    private(set) var gamepadSendFailures = 0
    private var didActivateInput = false
    private(set) var qosReportsSent = 0
    private(set) var qosReportFailures = 0
    private var lastIdrRequestAt: Date?
    private var idrRequestsSent = 0
    private var lastInvalidationAt: Date?
    private var pendingInvalidationFirst: UInt32?
    private var pendingInvalidationLast: UInt32?
    private var invalidationsSent = 0
    private var inputEventsSent = 0
    private var inputSequence: UInt16 = 0
    private var didAnnounceClientState = false
    /// Set once the bundle comes up; owned by the shared clock so the off-actor video pipeline
    /// stamps its acks from the same origin.
    private var sessionStartedAt: Date? { clock.startDate }
    private var inputHeartbeatTask: Task<Void, Never>?
    private var inputHeartbeatsSent = 0

    /// The frame rate the user configured, passed in from the view that already holds it reliably.
    /// The allocation JSON is re-parsed as a fallback, but that has proven fragile — when its fps
    /// field is missing or nested unexpectedly the pacing defaults to 60 and a 120 stream is held
    /// there. The configured value is authoritative.
    private let configuredFps: Int?
    /// The user's configured bitrate ceiling in kbps, authoritative over the JSON parse for the
    /// same reason as fps — a missing/nested field defaulted the announced cap and the stream
    /// parked low.
    private let configuredMaxBitrateKbps: Int?

    public init(pixelBufferSink: PixelBufferSink? = nil,
                configuredFps: Int? = nil,
                configuredMaxBitrateKbps: Int? = nil,
                logger: (@Sendable (String) -> Void)? = nil,
                controlTimeout: Duration = .seconds(20)) {
        self.pixelBufferSink = pixelBufferSink
        self.configuredFps = configuredFps
        self.configuredMaxBitrateKbps = configuredMaxBitrateKbps
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
        sessionServerLocation = Self.sessionServerLocation(fromRawSessionJSON: allocation.rawSessionJSON)
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
        let input = NvstRtspNegotiationInput(
            sessionID: allocation.session.id,
            rtspsEndpoints: endpoints,
            resolution: profile.resolution,
            fps: profile.fps,
            codec: profile.codec,
            bitrateKbps: profile.bitrateKbps,
            maximumBitrateKbps: profile.maximumBitrateKbps,
            timeout: controlTimeout,
            // The negotiator raises this to 1 when the bundle comes up; false is the fallback that
            // keeps feedback as SRTCP on the Mjolnir socket.
            rtcpOnSctp: false,
            forcesLegacyPath: Self.forcesLegacyPath,
            disablesOwdCongestionControl: !Self.usesOwdCongestionControl,
            announcesExtendedSettings: Self.announcesExtendedSettings,
            echoesOfferedAttributes: Self.echoesOfferedAttributes
        )

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
        logger?("NVST counters auth=\(stats.authenticatedPackets) fec=\(stats.fecPackets) dropped=\(stats.droppedPackets) rtpLoss=\(stats.finalizedLossPackets) frames=\(stats.framesEmitted) keyframes=\(stats.keyframesEmitted) recoveries=\(stats.recoveries) sofFlagged=\(stats.startOfFrameFlagged) sofOk=\(stats.startOfFrameAccepted) abandoned=\(stats.abandonedFrames) rrFail=\(stats.receiverReportFailures)\(stats.lastReceiverReportFailure.map { " rrErr=\($0)" } ?? "") multiBlock=\(stats.multiBlockPackets) maxBlock=\(stats.highestFecLastBlock) decoded=\(decoder?.decodedFrameCount ?? 0) decodeFailed=\(decoder?.failedFrameCount ?? 0) decodeErr=\(decoder?.failureStatusSummary ?? "-") noParamSets=\(video.missingParameterSetFrames) idrOut=\(idrRequestsSent) invalidOut=\(invalidationsSent) inputOut=\(inputEventsSent) padOut=\(gamepadPacketsSent) padFail=\(gamepadSendFailures) padReg=\(didRegisterGamepad) textTyped=\(textCharactersTyped) textDropped=\(textCharactersDropped) inputHb=\(inputHeartbeatsSent) inputReady=\(bundle?.isInputReady == true) rrOut=\(stats.receiverReportsSent) frac=\(stats.lastFractionLost) lost=\(stats.lastCumulativeLost) jitter=\(stats.lastJitter) seqSpan=\(stats.sequenceSpan) negFps=\(negotiatedFps.map(String.init) ?? "nil") mediaSeconds=\(String(format: "%.2f", Double(stats.lastRtpTimestamp &- (stats.firstRtpTimestamp ?? 0)) / Double(NvstVideoToolboxDecoder.clockRate))) fidxChanges=\(stats.frameIndexChanges) maxFrame=\(stats.maxFrameBytesPerSecond.map { String($0) }.joined(separator: ",")) bytesPerSec=\(stats.frameBytesPerSecond.map { String($0 / 1000) }.joined(separator: ",")) fpsPerSec=\(stats.framesPerSecond.map(String.init).joined(separator: ",")) paceOut=\(video.pacingReportsSent) paceFail=\(video.pacingReportFailures) ackOut=\(video.frameAcksSent) ackFail=\(video.frameAckFailures) qosOut=\(qosReportsSent) qosFail=\(qosReportFailures) ssrc=\(stats.boundSSRC.map { String(format: "0x%08x", $0) } ?? "-")")
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
            sender.updateMediaState(highestExtendedSequence: receiver.stats.highestSequence, cumulativeLost: 0)
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

    // MARK: - Video

    private func startVideo(handoff: NVSTVideoHandoff, mediaReceiver: any NativeNVSTMediaReceiver) async throws {
        let videoLogger = self.logger
        let decoder = try NvstVideoToolboxDecoder(codec: handoff.codec)
        decoder.onDecodeFailure = { [weak self] frameIndex, message in
            videoLogger?("NVST \(message)")
            guard frameIndex != 0 else { return }
            // Naming the unusable frame is the recovery the seat is configured for; a bare IDR
            // request has not produced a keyframe in any run.
            Task { await self?.invalidateFrame(frameIndex) }
        }
        let sink = pixelBufferSink
        decoder.onPixelBuffer = { pixelBuffer, presentationTime, isKeyframe in
            sink?(pixelBuffer, presentationTime, isKeyframe)
        }
        self.decoder = decoder
        lastHandoff = handoff
        startAudioReceiver(handoff: handoff)

        // The negotiation already bound and punched this socket; adopt the descriptor rather than
        // rebinding the port, which would lose the seat's NAT mapping.
        let descriptor = reserver?.takeMjolnirDescriptor() ?? -1
        let receiver = try NvstMjolnirReceiver(
            handoff: handoff,
            // SRTCP on this socket is the fallback plane; when the SCTP channel opens the seat gets
            // plain RTCP there instead. Both are harmless, and only one will be believed.
            sendsReceiverReports: true,
            existingDescriptor: descriptor
        )
        let logger = self.logger
        // The media-session seam is fed through one ordered hand-off rather than a task per frame:
        // `yield` is synchronous and ordered, and a single consumer awaits the receiver, so frames
        // cannot arrive out of order and the decode queue never waits on an actor.
        // Four frames, not the stream default of 120: at 5K an access unit is ~90 KB, so a buffer
        // that deep is ~10 MB held on the chance a consumer is slow.
        let (mediaFrames, mediaContinuation) = AsyncStream<NativeNVSTVideoFrame>.makeStream(
            bufferingPolicy: .bufferingNewest(4))
        mediaForwardingTask?.cancel()
        mediaForwardingTask = Task.detached(priority: .utility) {
            for await frame in mediaFrames {
                if Task.isCancelled { return }
                await mediaReceiver.receiveVideoFrame(frame)
            }
        }
        mediaFrameContinuation = mediaContinuation
        // Decode runs off this actor. Sharing the actor with QoS, keepalives and input made every
        // frame queue behind whatever else was pending, and the wait compounded across a burst —
        // see `NvstVideoPipeline` for the measurements.
        // Experiment F: Geronimo's own strings ("Pace server frames to match client vsync") show
        // the seat paces its own frame generation to whatever vsync interval the client reports —
        // this used to go out as a hardcoded 16000 us (~62.5 Hz) regardless of the real display.
        let displayRefreshRate = OPNStreamPreferences.loadDeviceCapabilities().maxDisplayRefreshRate
        let displayVsyncMicroseconds = displayRefreshRate > 0 ? UInt32(1_000_000 / displayRefreshRate) : 16000
        let pipeline = NvstVideoPipeline(
            decoder: decoder,
            clock: clock,
            frameTimeMicroseconds: sessionFrameTimeMicroseconds,
            displayVsyncMicroseconds: displayVsyncMicroseconds,
            logger: videoLogger,
            // Nothing on this transport consumes `videoFrames()` — we own the decoder — but the
            // seam stays fed, off the frame's own critical path.
            mediaSink: { unit in
                mediaContinuation.yield(NativeNVSTVideoFrame(
                    streamID: handoff.rtpSSRC,
                    codec: Self.mediaCodec(handoff.codec),
                    // The 90 kHz RTP clock converted to the shared nanosecond media timestamp.
                    timestamp: MediaTimestamp(nanoseconds: UInt64(unit.rtpTimestamp) * 1_000_000_000 / UInt64(NvstVideoToolboxDecoder.clockRate)),
                    durationNanoseconds: 0,
                    width: 0,
                    height: 0,
                    isKeyFrame: unit.isKeyframe,
                    payload: unit.bytes
                ))
            },
            onKeyframeNeeded: { [weak self, weak receiver] in
                receiver?.requestKeyframe()
                Task { await self?.requestKeyframeOverControlChannel() }
            },
            onFatalDecodeError: { [weak self] message in
                Task { await self?.reportFatalDecodeError(message) }
            }
        )
        videoPipeline = pipeline
        receiver.onAccessUnit = { [weak pipeline] unit in pipeline?.submit(unit) }
        receiver.onRecoveryNeeded = { [weak self, weak receiver] in
            // Reached only for gaps too wide to repair by retransmission; the receiver NACKs the
            // rest itself. A broken reference chain then only recovers with a fresh keyframe.
            receiver?.requestKeyframe()
            // The seat never opens `rtcp_on_sctp_private`, so a PLI has nowhere to go; the control
            // channel's IDR request is the only path that reaches the encoder.
            Task { await self?.requestKeyframeOverControlChannel() }
        }
        receiver.onDiagnostic = { message in logger?("NVST \(message)") }
        // FEC-repair and control packets legitimately carry no picture; do not log each one (it
        // floods the console). Real losses show up in the periodic counters line instead.
        receiver.onDrop = { _ in }
        try receiver.start()
        self.receiver = receiver
        logger?("NVST Mjolnir receiver armed on port \(handoff.mjolnirUDPPort ?? handoff.clientUDPPort) for peer \(handoff.videoPeerIP):\(handoff.videoPeerPort)")
    }

    /// Brings up the ICE/DTLS/SCTP bundle. The seat arms its video relay only after this DTLS
    /// handshake completes, so this is what turns the Mjolnir socket from silent to streaming.
    ///
    /// On failure the STUN-only probe takes over: it cannot unlock media, but it keeps the NAT
    /// mapping alive and reports what the seat sends back.
    private func bringUpBundle(handoff: NVSTVideoHandoff) async -> NvstBundleReservation? {
        let logger = self.logger
        guard Self.usesWebRtcBundle else {
            logger?("NVST bundle disabled; punching the bundle socket with bare STUN only")
            startBundleProbe(handoff: handoff)
            scheduleVideoHolePunch()
            return nil
        }
        let bundle = NvstWebRtcBundle(handoff: handoff, logger: logger)
        let sender = NvstFeedbackSender()
        do {
            let identity = try await bundle.prepare()
            scheduleVideoHolePunch()
            sender.configure(
                channelWriter: { payload in _ = bundle.sendFeedback(payload) },
                // "ONOW" — a stable sender SSRC, as the official client uses a fixed one.
                senderSSRC: 0x4f4e_4f57,
                mediaSSRC: 0
            )
            clock.start()
            bundle.onInputProtocolNegotiated = { [weak self] version in
                Task { await self?.inputDidNegotiate(version) }
            }
            bundle.onRemoteCursor = { [weak self] cursor in
                Task { await self?.handleRemoteCursor(cursor) }
            }
            bundle.onSeatStats = { [weak self] stats in
                Task { await self?.recordSeatStats(stats) }
            }
            bundle.onRemoteAudio = { [weak self] count in
                logger?("NVST bundle seat offered \(count) audio track(s)")
                Task { await self?.noteRemoteAudio(trackCount: count) }
            }
            bundle.onPartiallyReliableControlOpen = { [weak self] in
                Task { await self?.startQosFeedback() }
            }
            bundle.onControlChannelOpen = { [weak self] in
                Task {
                    await self?.startControlKeepAlive()
                    await self?.announceClientState()
                }
            }
            bundle.onFeedbackChannelOpen = { [weak self] in
                logger?("NVST feedback channel open; starting receiver reports")
                sender.start()
                Task {
                    await self?.adoptFeedbackSender(sender)
                    // The captured client punches the video socket only once the bundle is up.
                    await self?.beginVideoHolePunch()
                }
            }
            self.bundle = bundle
            // The video receiver was armed at SETUP, before this channel existed; hand it over now
            // so frame acks can go out.
            videoPipeline?.attach(bundle: bundle)
            self.feedbackSender = sender
            if !identity.usesOfficialIceCredentials {
                logger?("NVST bundle is announcing libwebrtc's own ICE credentials; Bifrost length checks may reject them")
            }
            return NvstBundleReservation(
                bundlePort: identity.bundlePort,
                mjolnirPort: handoff.mjolnirUDPPort ?? handoff.clientUDPPort,
                localAddress: identity.localAddress,
                iceCredentials: handoff.iceCredentials.map {
                    NvstRtspIceCredentials(usernameFragment: $0.localUsernameFragment, password: $0.localPassword)
                },
                dtlsFingerprint: identity.dtlsFingerprint
            )
        } catch {
            logger?("NVST bundle bring-up failed: \(error.localizedDescription); falling back to the STUN-only probe")
            bundle.close()
            startBundleProbe(handoff: handoff)
            scheduleVideoHolePunch()
            return nil
        }
    }

    /// Official punches the video socket ~1 s after the bundle is up, never before.
    private func scheduleVideoHolePunch() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await self?.beginVideoHolePunch()
        }
    }

    /// `OPN_NVST_VIDEO_PUNCH=0` keeps the video socket silent. The seat has been closing the
    /// ICE/DTLS bundle shortly after the first video punch, and suppressing the punch is the only
    /// way to tell a coincidence from a cause.
    /// The ANNOUNCE attribute set is the one thing the seat accepts with a 200 and then acts on
    /// differently, so both expansions stay switchable from a single run's environment.
    static var announcesExtendedSettings: Bool { ProcessInfo.processInfo.environment["OPN_NVST_ANNOUNCE_EXTENDED"] == "1" }
    /// The seat's one-way-delay rate control (`bwe.useOwdCongestionControl:1`, the vendor default).
    /// Its OWD signal is the `rtpTimestamp` the 0x0207 QoS report carries (+36), which the seat
    /// differences against its own send position for `bw.txRxLag`; we now send that report at 18 Hz,
    /// so the delay controller has its evidence. Loss-based control (the old default) is documented
    /// to park the encoder at a floor (48 pkt/s vs the official client's 401). Default ON to match
    /// the vendor and let the L4S/OWD bitrate ramp run; set OPN_NVST_OWD_CC=0 to fall back if a live
    /// session shows the OWD controller oscillating. Verified safe over a 95 s autopilot run
    /// (negFps=120, 0 decode failures, no stall); the ramp ceiling itself needs dynamic gameplay to
    /// measure (static menus encode ~401 B/frame and cannot exercise it).
    static var usesOwdCongestionControl: Bool { ProcessInfo.processInfo.environment["OPN_NVST_OWD_CC"] != "0" }
    static var echoesOfferedAttributes: Bool { ProcessInfo.processInfo.environment["OPN_NVST_ANNOUNCE_ECHO_OFFER"] == "1" }

    static var punchesVideoSocket: Bool { ProcessInfo.processInfo.environment["OPN_NVST_VIDEO_PUNCH"] != "0" }

    /// The seat measures a 10 s client timeout on `control_channel_reliable` and ends the session
    /// with `NVST_NETERR_CLIENT_TIMED_OUT` when nothing arrives. The official client answers with
    /// command `0x200` every 3 s; the first one goes out immediately, because the seat's timer is
    /// already running by the time the association is up.
    private func startControlKeepAlive() {
        guard controlKeepAliveTask == nil else { return }
        logger?("NVST control keepalive started (\(Int(NvstControlCommand.pingBackIntervalSeconds))s)")
        controlKeepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sendControlKeepAlive()
                try? await Task.sleep(for: .seconds(NvstControlCommand.pingBackIntervalSeconds))
            }
        }
    }

    /// Brings up audio on a socket we own, when one was reserved for it. libwebrtc's own path stays
    /// as the fallback: it delivers audio but NetEq discards most of a clean stream.
    private func startAudioReceiver(handoff: NVSTVideoHandoff) {
        guard NvstLocalBundleReserver.receivesAudioOnOwnSocket, audioReceiver == nil else { return }
        let descriptor = reserver?.takeAudioDescriptor() ?? -1
        guard descriptor >= 0 else {
            logger?("NVST audio socket was not reserved; audio stays on the bundle")
            return
        }
        do {
            let receiver = try NvstAudioReceiver(existingDescriptor: descriptor)
            receiver.onDiagnostic = { [weak self] message in self?.logger?(message) }
            // The audio stream's own SETUP names the port the seat sends audio from; punching the
            // video port instead reached nothing at all.
            let peerPort = handoff.audioPeerPort ?? handoff.videoPeerPort
            receiver.start(peerIP: handoff.videoPeerIP, peerPort: peerPort, handoff: handoff)
            audioReceiver = receiver
            logger?("NVST audio receiver armed on port \(receiver.localPort) toward \(handoff.videoPeerIP):\(peerPort)\(handoff.audioPeerPort == nil ? " (no audio SETUP port; using the video peer)" : "")")
        } catch {
            logger?("NVST audio receiver failed: \(error.localizedDescription)")
        }
    }

    private func noteRemoteAudio(trackCount: Int) {
        remoteAudioTrackCount = trackCount
    }

    /// The seat runs one-way-delay rate control (`bwe.useOwdCongestionControl:1`) and asks for
    /// feedback no less often than `vqos[0].bw.txRxLag.minFeedbackTxDeltaMs:200`. Without any QoS
    /// report its controller has no evidence the path is healthy and holds the encoder far below
    /// what the link carries: 53 packets per second measured against the official client's 401 on
    /// the same title. The captured client sends command `0x207` on
    /// `control_channel_partially_reliable` at about 18 Hz.
    private func startQosFeedback() {
        guard qosFeedbackTask == nil else { return }
        logger?("NVST QoS feedback started (\(String(format: "%.0f", 1 / NvstQosReport.interval))/s)")
        qosFeedbackTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sendQosReport()
                try? await Task.sleep(for: .seconds(NvstQosReport.interval))
            }
        }
    }

    private func sendQosReport() {
        guard let bundle, let receiver else { return }
        let counters = receiver.feedbackCounters
        let bytes = UInt32(truncatingIfNeeded: counters.bytesReceived)
        let now = Date()

        qosSequence += 1
        // Report a link capability at least as high as the configured ceiling (clamped to the
        // field's UInt16 range) so the seat's rate controller ramps toward it. The captured default
        // (12708) was a low-bandwidth session and pins the seat there.
        //
        // Note: with a 100000 kbps configured ceiling this saturates the UInt16 field at 65535,
        // while the official client's own reports on this same seat carry 26570. Sending the
        // vendor's value was tested (2026-08-28) and changed nothing measurable, so the existing
        // ramp-toward-the-ceiling behaviour stands.
        let capabilityKbps = UInt16(clamping: max(Int(NvstQosReport.defaultLinkCapabilityKbps),
                                                  configuredMaxBitrateKbps ?? 0))
        // Interarrival jitter is measured on the seat's own 90 kHz media clock; the report wants
        // microseconds.
        let jitterMicroseconds = UInt32(clamping: Int(Double(receiver.stats.lastJitter) * 1_000_000
            / Double(NvstVideoToolboxDecoder.clockRate)))
        // How far the delay sample moved since the last report — the trend an OWD controller acts
        // on, and small by construction, which is the shape the capture shows at `+24`.
        let delayTrend = jitterMicroseconds >= lastQosDelayMicroseconds
            ? jitterMicroseconds - lastQosDelayMicroseconds
            : lastQosDelayMicroseconds - jitterMicroseconds
        lastQosDelayMicroseconds = jitterMicroseconds
        // Bits carried since the previous report, not a cumulative count.
        let deltaBytes = counters.bytesReceived >= lastQosBytesReceived
            ? counters.bytesReceived - lastQosBytesReceived
            : 0
        let previousBytes = UInt32(truncatingIfNeeded: lastQosBytesReceived)
        lastQosBytesReceived = counters.bytesReceived

        let report = NvstQosReport(
            sequence: qosSequence,
            framesReceived: UInt32(truncatingIfNeeded: counters.framesEmitted),
            bytesReceived: bytes,
            linkCapabilityKbps: capabilityKbps,
            rtpTimestamp: counters.lastRtpTimestamp,
            // Was passing `bytes` here, so the two fields were identical and any controller
            // differencing them measured a flat zero throughput.
            previousBytesReceived: previousBytes,
            delayMicroseconds: jitterMicroseconds,
            delayTrendMicroseconds: delayTrend,
            intervalBits: UInt32(clamping: deltaBytes * 8),
            isWarmedUp: sessionStartedAt.map { now.timeIntervalSince($0) >= NvstQosReport.warmUpSeconds } ?? false
        )

        if bundle.sendPartiallyReliableControl(report.command) {
            qosReportsSent += 1
        } else {
            qosReportFailures += 1
            if qosReportFailures == 1 { logger?("NVST QoS report write failed") }
        }
    }

    /// The seat's cursor notifications: the first one means it is publishing cursor state, so its
    /// composited pointer is no longer needed and capture is turned back off. Leaving both on is
    /// the double-cursor bug — the seat's pointer baked into the video underneath our own.
    /// `trackRemoteCursorImage` stays enabled, so notifications keep coming after capture stops.
    private func handleRemoteCursor(_ cursor: NvstRemoteCursor) {
        if !didDisableCursorCapture, let bundle {
            didDisableCursorCapture = true
            let sent = bundle.sendControl(NvstInputActivation.mouseCursorCapture(isEnabled: false))
            logger?("NVST seat cursor notifications started; server-composited cursor disabled sent=\(sent)")
        }
        guard cursor.isVisible != remoteCursorVisible else { return }
        let previous = remoteCursorVisible
        remoteCursorVisible = cursor.isVisible
        // Timestamped, because the complaint is about *when* the pointer appears: this line next to
        // the seat's own notification line says whether we followed the seat or invented it.
        logger?(String(format: "NVST remote cursor %@ -> %@ at %.3fs",
                       previous.map { $0 ? "visible" : "hidden" } ?? "unknown",
                       cursor.isVisible ? "visible" : "hidden",
                       Double(clock.elapsedMicroseconds()) / 1_000_000))
        if let notify = onRemoteCursorVisibilityChanged {
            let isVisible = cursor.isVisible
            Task { @MainActor in notify(isVisible) }
        }
    }

    /// Whether the game currently wants a pointer drawn. Nil until the seat says.
    public private(set) var remoteCursorVisible: Bool?
    private var didDisableCursorCapture = false
    /// Raised when the game shows or hides its pointer, so the client can match it and avoid
    /// drawing a second one (or leaving one floating during mouselook).
    public private(set) var onRemoteCursorVisibilityChanged: (@MainActor @Sendable (Bool) -> Void)?

    /// Assigning the property directly from the main actor is a data race on this actor's state —
    /// the compiler flags it, and it is exactly the kind of cross-actor write that works until it
    /// races. Callers hand the handler over through the actor instead.
    public func setRemoteCursorVisibilityHandler(_ handler: (@MainActor @Sendable (Bool) -> Void)?) {
        onRemoteCursorVisibilityChanged = handler
    }

    /// Microseconds since this session started, as the remote-input timestamps are expressed.
    private func sessionElapsedMicroseconds() -> UInt64 {
        guard let start = sessionStartedAt else { return 0 }
        return UInt64(max(0, Date().timeIntervalSince(start)) * 1_000_000)
    }

    /// The session's server name from the CloudMatch allocation, mirroring how
    /// `NativeNVSTLaunchPayload` resolves it: `serverLocation` at the session or request level,
    /// then `zoneName`.
    static func sessionServerLocation(fromRawSessionJSON json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let rawSession = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let requestData = rawSession["sessionRequestData"] as? [String: Any] ?? [:]
        for value in [rawSession["serverLocation"], requestData["serverLocation"], rawSession["zoneName"]] {
            if let text = value as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                return text
            }
        }
        return nil
    }

    /// Tells the seat which frame the decoder could not use, so its encoder stops referencing it.
    /// Throttled: a broken reference chain rejects every following frame, and one range covers them.
    private func invalidateFrame(_ frameIndex: UInt32) {
        guard let bundle else { return }
        let now = Date()
        if let last = lastInvalidationAt, now.timeIntervalSince(last) < Self.idrRequestInterval {
            pendingInvalidationLast = max(pendingInvalidationLast ?? frameIndex, frameIndex)
            return
        }
        let first = UInt64(pendingInvalidationFirst ?? frameIndex)
        let last = UInt64(max(pendingInvalidationLast ?? frameIndex, frameIndex))
        lastInvalidationAt = now
        pendingInvalidationFirst = nil
        pendingInvalidationLast = nil
        guard bundle.sendControl(.frameInvalidationRange(first: first, last: last)) else {
            logger?("NVST frame invalidation write failed")
            return
        }
        invalidationsSent += 1
    }

    /// Asks the seat's encoder for a fresh keyframe, at most a few times a second: a decode failure
    /// can repeat for every frame in a broken reference chain, and one IDR fixes the whole run of
    /// them.
    private func requestKeyframeOverControlChannel() {
        guard let bundle else { return }
        let now = Date()
        if let last = lastIdrRequestAt, now.timeIntervalSince(last) < Self.idrRequestInterval { return }
        lastIdrRequestAt = now
        guard bundle.sendControl(.idrRequest()) else {
            logger?("NVST IDR request write failed")
            return
        }
        idrRequestsSent += 1
    }

    /// Upper bound on `initialBitrateKbps`. Matches the ceiling OpenNOW's native client clamps its
    /// own bitrate to, and exists only so a nonsense configured value cannot ask the seat for an
    /// absurd rate — normal ceilings (including 100 Mbps) pass through untouched.
    static let maximumInitialBitrateKbps = 150_000

    static let idrRequestInterval: TimeInterval = 0.5


    /// The official client reports its window and system state once, shortly after PLAY, with
    /// zeros. Nothing else in our session tells the seat the client is present and in focus, and a
    /// seat that gates remote input on focus would ignore every packet until it hears this.
    private func announceClientState() {
        guard let bundle, !didAnnounceClientState else { return }
        didAnnounceClientState = true
        let window = bundle.sendControl(.windowStateChange())
        let system = bundle.sendControl(.systemStateChange())
        logger?("NVST client state announced (window=\(window) system=\(system))")
    }

    private func inputDidNegotiate(_ version: UInt16) {
        // No input heartbeat: the captured official client sends none. Upstream's transport does,
        // but that is its own design rather than something the seat asks for.
        logger?("NVST input negotiated at protocol version \(version); ready=\(bundle?.isInputReady == true)")
        activateInput()
    }

    /// Sends the device descriptor and enable that the native stack puts between the seat's
    /// handshake and its first input event. Our remote-input packets already match the native
    /// stack's byte for byte and the seat ignored them, so this pair is the remaining difference.
    private func activateInput() {
        guard let bundle, !didActivateInput else { return }
        didActivateInput = true
        guard ProcessInfo.processInfo.environment["OPN_NVST_RI_NO_ACTIVATION"] != "1" else {
            logger?("NVST input activation skipped by request")
            return
        }
        // The native stack's order, which is not the same as sending the same messages in any
        // order: the enable goes out clear first, the descriptor and ready follow, then the window
        // and system state, and the enable is only set afterwards. The seat answers the tail of
        // this chain with gamepad-handling and cursor-info.
        var sent: [String] = []
        sent.append("enableOff=\(bundle.sendControl(NvstInputActivation.enableInput(counter: 1, isEnabled: false)))")
        // ONE device, one index. The official client sends a single `0x20d` whose descriptor index
        // (body[9]) equals the device index its state packets carry (body[13]) — captured: both 1.
        // We used to send this one at index 2 and then a second at index 3 for the gamepad, so the
        // seat registered TWO devices: the game showed two XInput pads and listened to the first
        // while our input drove the second, which reads as "the controller does nothing". Announcing
        // the gamepad's own index here collapses them back to a single pad.
        sent.append("descriptor=\(bundle.sendControl(NvstInputActivation.deviceDescriptor(timestampMicroseconds: sessionElapsedMicroseconds(), connectedBitmap: NvstGamepadPacket.connectedBitmap)))")
        // The pad is registered now, so the lazy pre-first-input descriptor must not fire as well:
        // the official client sends exactly one 0x20d per session, and a second one is what created
        // the phantom pad.
        didRegisterGamepad = true
        // Cursor capture ON for startup so the seat composites a pointer immediately, plus remote
        // cursor tracking so it publishes shape/mode notifications. Once a notification arrives the
        // capture is turned back off (see `handleRemoteCursorNotification`) and the pointer becomes
        // ours to draw — the seat keeps publishing because tracking stays on.
        sent.append("cursorCapture=\(bundle.sendControl(NvstInputActivation.mouseCursorCapture(isEnabled: true)))")
        sent.append("cursorTrack=\(bundle.sendControl(NvstInputActivation.trackRemoteCursorImage(isEnabled: true)))")
        sent.append("window=\(bundle.sendControl(.windowStateChange()))")
        sent.append("system=\(bundle.sendControl(.systemStateChange()))")
        sent.append("enableOn=\(bundle.sendControl(NvstInputActivation.enableInput(counter: UInt32((videoPipeline?.snapshot.frameAcksSent ?? 0) + 1))))")
        logger?("NVST input activation sent (\(sent.joined(separator: " ")))")
    }

    /// The reliable input channel wants a 4-byte keepalive every two seconds; upstream's transport
    /// sends the same bytes on the same cadence.
    private func startInputHeartbeat() {
        guard inputHeartbeatTask == nil else { return }
        logger?("NVST input heartbeat started")
        inputHeartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sendInputHeartbeat()
                try? await Task.sleep(for: .seconds(NvstRemoteInput.heartbeatInterval))
            }
        }
    }

    private func sendInputHeartbeat() {
        guard let bundle, bundle.sendInputHeartbeat() else { return }
        inputHeartbeatsSent += 1
    }

    private func sendControlKeepAlive() {
        guard let bundle else { return }
        // The official payload is a per-stream 32-bit value, and zero is what the client sends
        // before a stream object exists; the frame index is the same shape once video flows.
        let value = receiver?.stats.framesEmitted ?? 0
        let sent = bundle.sendControl(.pingBackAck(streamValue: UInt32(truncatingIfNeeded: value)))
        if !sent { logger?("NVST control keepalive write failed") }
    }

    private func beginVideoHolePunch() {
        guard Self.punchesVideoSocket else {
            logger?("NVST video socket hole punch suppressed (OPN_NVST_VIDEO_PUNCH=0)")
            return
        }
        receiver?.beginHolePunch()
        logger?("NVST video socket hole punch started")
    }

    /// Once the feedback channel is live the Mjolnir socket stops sending its own SRTCP: the seat
    /// expects reports on one plane, not two.
    private func adoptFeedbackSender(_ sender: NvstFeedbackSender) {
        guard let receiver else { return }
        if let ssrc = receiver.stats.boundSSRC { sender.updateMediaSSRC(ssrc) }
    }

    /// STUN-only ICE keepalive on the bundle socket, used when the real bundle cannot come up.
    private func startBundleProbe(handoff: NVSTVideoHandoff) {
        guard let descriptor = reserver?.takeBundleDescriptor(), descriptor >= 0 else {
            logger?("NVST bundle probe skipped: no reserved socket")
            return
        }
        do {
            let probe = try NvstBundleIceProbe(handoff: handoff, descriptor: descriptor, logger: logger)
            probe.start()
            bundleProbe = probe
            logger?("NVST bundle ICE probe started (STUN only, no DTLS)")
        } catch {
            close(descriptor)
            logger?("NVST bundle probe unavailable: \(error.localizedDescription)")
        }
    }

    /// The decode pipeline gave up: 30 consecutive hard failures is a stream that will not
    /// recover on its own.
    private func reportFatalDecodeError(_ message: String) {
        terminationContinuation?.yield(.transportFailed(NativeNVSTTransportFailure(
            message: "Native NVST could not decode video: \(message)",
            recoveryClassification: .permanent
        )))
    }

    // MARK: - Unsupported until the ICE/DTLS bundle lands

    public func send(_ event: UserInputEvent) async throws {
        guard let bundle, bundle.isInputReady else {
            throw NativeNVSTError.transportFailed("NVST input is not negotiated yet (channels open: \(bundle?.isInputChannelOpen == true), protocol: \(bundle?.inputProtocolVersion.map(String.init) ?? "none")).")
        }
        // Gamepad state is its own command on the input channel, not an envelope on the control
        // channel, so it never reaches the remote-input packet builder.
        if case .gamepad(let state) = event {
            // The seat drops gamepad state for a device it was never told about. The vendored path
            // registers the pad with a 0x20d device descriptor (index 3) before its first input —
            // exactly what `handleGamepadChangedEvent` does — so send that once here.
            if !didRegisterGamepad {
                didRegisterGamepad = true
                let registered = bundle.sendControl(NvstInputActivation.deviceDescriptor(
                    timestampMicroseconds: sessionElapsedMicroseconds(),
                    connectedBitmap: NvstGamepadPacket.connectedBitmap))
                logger?("NVST gamepad registration descriptor sent=\(registered) inputReady=\(bundle.isInputReady) inputChannelOpen=\(bundle.isInputChannelOpen)")
            }
            gamepadSequence &+= 1
            // Resting analog sticks are not exactly centred (~2% drift, seen jittering every poll).
            // A real XInput pad drifts too and the game applies XINPUT_*_THUMB_DEADZONE; this title
            // does not, so the drift reads as a held direction and the jitter floods on-change
            // sends. Apply the standard radial deadzone here instead.
            let (lx, ly) = Self.deadzoned(state.leftStickX, state.leftStickY, Self.leftStickDeadzone)
            let (rx, ry) = Self.deadzoned(state.rightStickX, state.rightStickY, Self.rightStickDeadzone)
            let packet = NvstGamepadPacket(
                sequence: gamepadSequence,
                timestampMicroseconds: sessionElapsedMicroseconds(),
                buttons: Self.wireButtons(state.buttons),
                leftTrigger: NvstGamepadPacket.trigger(state.leftTrigger),
                rightTrigger: NvstGamepadPacket.trigger(state.rightTrigger),
                leftStickX: NvstGamepadPacket.axis(lx),
                leftStickY: NvstGamepadPacket.axis(ly),
                rightStickX: NvstGamepadPacket.axis(rx),
                rightStickY: NvstGamepadPacket.axis(ry)
            )
            // Gamepad state goes on the input channel (SCTP stream 10), matching the vendored
            // client's captured traffic. Both channels were tried while the packet itself was
            // malformed and both were dead, which proved nothing about the channel; sid 10 is what
            // the official client uses, so that is what we send.
            let padSendStart = DispatchTime.now().uptimeNanoseconds
            let delivered = bundle.sendInput(packet.command.encoded)
            noteInputSend(from: padSendStart)
            if delivered { gamepadPacketsSent += 1 } else { gamepadSendFailures += 1 }
            guard delivered else {
                throw NativeNVSTError.transportFailed("The NVST input channel rejected the gamepad state.")
            }
            inputEventsSent += 1
            return
        }
        // Text has no recovered encoding, so it is typed instead. The stream view sends it for IME
        // composition, Option-modified and non-ASCII characters, and for paste — which would
        // otherwise vanish into the `try?` at the call site.
        if case .text(_, let value, _) = event {
            try sendAsKeystrokes(value)
            return
        }
        guard let packet = Self.remoteInputPacket(for: event) else {
            // Keyboard, text and gamepad encodings are not recovered yet; failing loudly beats
            // sending a packet whose shape is a guess.
            throw NativeNVSTError.transportFailed("No NVST remote-input encoding for \(event) yet.")
        }
        inputSequence &+= 1
        // Microseconds since the session began, not since the epoch. The captured client sends
        // ~25.9 s into a 26 s session; an epoch timestamp is ~1.7e15 and a seat that sanity-checks
        // it against session time discards the packet.
        let framed = NvstRemoteInput.framed(packet,
                                            framing: .enveloped,
                                            sequence: inputSequence,
                                            timestampMicroseconds: sessionElapsedMicroseconds())
        let command = NvstControlCommand(code: NvstRemoteInput.commandCode, payload: framed)
        let sendStart = DispatchTime.now().uptimeNanoseconds
        let accepted = bundle.sendControl(command)
        noteInputSend(from: sendStart)
        guard accepted else {
            throw NativeNVSTError.transportFailed("The NVST control channel rejected the input event.")
        }
        inputEventsSent += 1
    }

    /// Every input write is a blocking proxy call into libwebrtc's network thread, made while this
    /// actor is held — so a slow one delays every video frame queued behind it. Tracked to tell
    /// that apart from a decode stall.
    private func noteInputSend(from start: UInt64) {
        let end = DispatchTime.now().uptimeNanoseconds
        let milliseconds = end > start ? Double(end - start) / 1_000_000 : 0
        inputSendTotalMs += milliseconds
        if milliseconds > inputSendPeakMs { inputSendPeakMs = milliseconds }
    }

    private(set) var inputSendTotalMs = 0.0
    private(set) var inputSendPeakMs = 0.0

    /// The channel and framing the seat honours, now settled by measurement rather than by
    /// walking candidates: remote input goes out as command `0x206`, envelope-framed, on
    /// `control_channel_reliable` (SCTP stream 0). Our packets are byte-identical to the native
    /// stack's, and the seat's reaction to them is too — see `NvstInputActivationTests`.
    ///
    /// The set of candidate channel/framing combinations this used to walk is gone: rotating
    /// between them sent half of every session's events to a channel the seat ignores, which is
    /// part of why input looked broken for so long.
    enum InputDestination: String, CaseIterable {
        case control
    }

    /// These exist on the vendored transports and are called at runtime — the host applies a
    /// maximum-bitrate change through `setMaximumBitrateKbps`, and the stream view pushes controller
    /// topology through `updateGamepadTopology`. Without them the protocol's default throws
    /// `notRunning`, which reads as "no session" and sent me looking in the wrong place once
    /// already with `sendAbsoluteMouseMove`. They still fail, but they now say why.
    public func setMaximumBitrateKbps(_ bitrateKbps: UInt32) async throws {
        throw NativeNVSTError.transportFailed(
            "Changing the maximum bitrate mid-session is not implemented on the Bifrost-free path; "
            + "the announced cap comes from the negotiated session profile.")
    }

    /// Feeds both the on-screen overlay and `NativeNVSTStreamHealthMonitor` from the receive path's
    /// own counters.
    ///
    /// This was nil for a while: returning a snapshot arms the monitor, and the monitor then checks
    /// `nativeNVSTRendererSurfaceReady`, which used to be tied to the vendored NVST Metal view this
    /// path never attaches — so it tore down a healthy stream. That readiness signal now reports
    /// our own renderer, so the snapshot is safe to return, and without it the overlay shows only
    /// dashes.
    ///
    /// `streamFramesPerSecond` is the rate over the last poll interval, not the session average:
    /// the monitor uses it for stall detection, and an average would mask a real stall late in a
    /// long session.
    public func performanceSnapshot() async -> NativeNVSTPerformanceSnapshot? {
        guard let receiver, let started = sessionStartedAt else { return nil }
        let counters = receiver.feedbackCounters
        let now = Date()
        let elapsed = max(0.001, now.timeIntervalSince(started))

        let interval = lastSnapshotAt.map { max(0.001, now.timeIntervalSince($0)) } ?? elapsed
        let framesSinceLast = counters.framesEmitted &- lastSnapshotFrames
        let bytesSinceLast = counters.bytesReceived &- lastSnapshotBytes
        let instantFps = Double(framesSinceLast) / interval
        let instantMbps = Double(bytesSinceLast) * 8 / interval / 1_000_000
        lastSnapshotAt = now
        lastSnapshotFrames = counters.framesEmitted
        lastSnapshotBytes = counters.bytesReceived

        if firstRtpTimestampSeen == 0 { firstRtpTimestampSeen = counters.lastRtpTimestamp }

        // Loss over the interval, computed the way the WebRTC path computes it, so the two HUDs
        // report the same quantity rather than one percent and one running count.
        let stats = receiver.stats
        let packetsNow = stats.authenticatedPackets
        let lostNow = UInt64(stats.lastCumulativeLost)
        let packetsDelta = packetsNow >= lastSnapshotPackets ? packetsNow - lastSnapshotPackets : 0
        let lostDelta = lostNow >= lastSnapshotLost ? lostNow - lastSnapshotLost : 0
        lastSnapshotPackets = packetsNow
        lastSnapshotLost = lostNow
        let lossPercent = packetsDelta + lostDelta > 0
            ? Double(lostDelta) * 100 / Double(packetsDelta + lostDelta)
            : 0

        // The seat's round trip, from libwebrtc's own ICE candidate pair — the same source the
        // WebRTC transport's HUD reads. Requested here rather than on a timer of its own: the HUD
        // polls this method about once a second, which is the rate the sample is wanted at.
        bundle?.refreshTransportStatistics()
        let roundTrip = bundle?.roundTripMilliseconds ?? -1
        let video = videoPipeline?.snapshot
        let decodeMilliseconds = (video?.framesHandled ?? 0) > 0
            ? (video?.total.decode ?? 0) / Double(video?.framesHandled ?? 1)
            : -1

        // The seat's own 0x0101 statistics carry the game render rate — the number the vendored
        // client showed and this path had hardcoded to "--". (Its float at +40 looked like a
        // latency at first and is NOT one: live calibration showed it drifting 98→393 ms while
        // the path sat at single-digit RTT. It stays in the calibration log only.)
        let seatStats = latestSeatStats
        // ICE candidate-pair RTT stays the preferred latency source, but this seat never answers
        // libwebrtc's connectivity checks, so it is normally -1 here. Fallbacks, most direct
        // first: the Mjolnir socket's own STUN round trip on the media path (measured only if the
        // seat answers, which it may not — it acts as a STUN client, not a server), then the
        // control connection's WebSocket ping/pong, which the seat answers mandatorily.
        var mjolnirRoundTrip = receiver.roundTripMilliseconds
        if mjolnirRoundTrip < 0, let session {
            mjolnirRoundTrip = await session.controlRoundTripMilliseconds()
        }
        return NativeNVSTPerformanceSnapshot(
            available: counters.framesEmitted > 0,
            gameFramesPerSecond: seatStats?.gameFramesPerSecond ?? -1,
            streamFramesPerSecond: instantFps,
            // Network round trip, not client decode cost — the decode number has its own field.
            latencyMilliseconds: roundTrip >= 0 ? roundTrip : mjolnirRoundTrip,
            jitterMilliseconds: Double(stats.lastJitter) * 1000 / Double(NvstVideoToolboxDecoder.clockRate),
            frameLoss: stats.abandonedFrames,
            totalFrameLoss: stats.abandonedFrames + UInt64(video?.missingParameterSetFrames ?? 0),
            packetLoss: UInt64(stats.lastCumulativeLost),
            totalPacketLoss: stats.droppedPackets,
            packetLossPercent: lossPercent,
            decodeMilliseconds: decodeMilliseconds,
            bitrateMegabitsPerSecond: instantMbps,
            bandwidthUtilizationPercent: 0,
            // What the decoder actually produced, falling back to the negotiated string until the
            // first frame lands. A seat that ignored the requested geometry shows up here.
            resolution: decoder?.decodedResolution ?? negotiatedResolution ?? "",
            codec: negotiatedCodec ?? lastHandoff.map { String(describing: $0.codec) } ?? "",
            // The CloudMatch session's human server name ("np-tyo-01" style), the way the vendored
            // transport reported it; the video peer IP is only the fallback for a session that
            // carries no name.
            serverLocation: sessionServerLocation ?? lastHandoff?.videoPeerIP ?? ""
        )
    }
    private var lastSnapshotAt: Date?
    private var lastSnapshotFrames: UInt64 = 0
    private var lastSnapshotBytes: UInt64 = 0
    private var lastSnapshotPackets: UInt64 = 0
    private var lastSnapshotLost: UInt64 = 0
    // Session-peak tracker for the NVST SESSION SUMMARY line (see logCounters).
    private var peakIntervalFps: Double = 0
    private var peakIntervalMbps: Double = 0
    private var lastSummaryFrames: UInt64 = 0
    private var lastSummaryMediaSeconds: Double = 0
    private var firstRtpTimestampSeen: UInt32 = 0
    private var negotiatedResolution: String?
    private var negotiatedCodec: String?

    public func setDynamicStreamingMode(_ mode: NativeNVSTDynamicStreamingMode) async throws {
        throw NativeNVSTError.transportFailed("Dynamic streaming mode is not implemented on the Bifrost-free path.")
    }

    public func setL4SEnabled(_ enabled: Bool) async throws {
        throw NativeNVSTError.transportFailed("L4S toggling is not implemented on the Bifrost-free path.")
    }

    public func updateGamepadTopology(_ topology: NativeWebRTCGamepadTopology) async throws {
        throw NativeNVSTError.transportFailed("Gamepad topology updates are not implemented on the Bifrost-free path.")
    }

    /// Accepts the configuration and does nothing with it, which is what the protocol's own default
    /// did. Throwing here broke every stream: the host applies the microphone configuration
    /// *before* `start`, in the same `do` block, so a thrown error meant `start` was never reached
    /// and no session was ever requested — a launch that died right after "Launch plan ready".
    ///
    /// There is nothing to configure on a path with no microphone, so this is genuinely satisfied
    /// rather than silently swallowed. Actually *enabling* capture is what fails, below.
    public func setMicrophoneConfiguration(_ configuration: NativeNVSTMicrophoneConfiguration) async throws {}

    public func pause() async throws {
        throw NativeNVSTError.transportFailed("Pause is not implemented on the Bifrost-free path.")
    }

    /// Types `text` as key presses, holding shift only around the characters that need it.
    private func sendAsKeystrokes(_ text: String) throws {
        guard let bundle, bundle.isInputReady else {
            throw NativeNVSTError.transportFailed("NVST input is not negotiated yet.")
        }
        let (strokes, unmappable) = NvstTextInput.keystrokes(for: text)
        guard !strokes.isEmpty else {
            throw NativeNVSTError.transportFailed(
                "No NVST encoding for text \"\(text.prefix(16))\": none of it maps to a US-layout key.")
        }
        if !unmappable.isEmpty {
            textCharactersDropped += unmappable.count
            logger?("NVST text dropped \(unmappable.count) unmappable character(s); typing the rest")
        }

        // Shift travels in the packet's modifier field, not as a separate key press — the same
        // field that makes physical held-shift capitalize. A shifted glyph is one packet with the
        // shift bit set.
        func send(virtualKey: UInt16, modifiers: UInt16, isPressed: Bool) throws {
            let packet = NvstRemoteInput.keyboard(virtualKey: virtualKey, modifiers: modifiers, isPressed: isPressed)
            inputSequence &+= 1
            let framed = NvstRemoteInput.framed(packet,
                                                framing: .enveloped,
                                                sequence: inputSequence,
                                                timestampMicroseconds: sessionElapsedMicroseconds())
            guard bundle.sendControl(NvstControlCommand(code: NvstRemoteInput.commandCode, payload: framed)) else {
                throw NativeNVSTError.transportFailed("The NVST control channel rejected a typed key.")
            }
            inputEventsSent += 1
        }

        for stroke in strokes {
            let modifiers: UInt16 = stroke.needsShift ? UInt16(KeyboardModifiers.shift.rawValue) : 0
            try send(virtualKey: stroke.virtualKey, modifiers: modifiers, isPressed: true)
            try send(virtualKey: stroke.virtualKey, modifiers: modifiers, isPressed: false)
        }
        textCharactersTyped += strokes.count
    }

    /// The absolute cursor position. This never arrives as a `UserInputEvent` — the stream view
    /// routes it through its own call — and the protocol default for it throws, so before this
    /// existed every pointer move in absolute cursor mode was silently dropped while clicks still
    /// went out, landing wherever the remote cursor happened to be.
    public func sendAbsoluteMouseMove(_ event: NativeNVSTAbsoluteMouseEvent) async throws {
        guard let bundle, bundle.isInputReady else {
            throw NativeNVSTError.transportFailed("NVST input is not negotiated yet.")
        }
        let packet = NvstRemoteInput.absoluteMouseMove(
            x: UInt16(clamping: event.x),
            y: UInt16(clamping: event.y),
            viewportWidth: UInt16(clamping: event.viewportWidth),
            viewportHeight: UInt16(clamping: event.viewportHeight)
        )
        inputSequence &+= 1
        let framed = NvstRemoteInput.framed(packet,
                                            framing: .enveloped,
                                            sequence: inputSequence,
                                            timestampMicroseconds: sessionElapsedMicroseconds())
        guard bundle.sendControl(NvstControlCommand(code: NvstRemoteInput.commandCode, payload: framed)) else {
            throw NativeNVSTError.transportFailed("The NVST control channel rejected the absolute pointer move.")
        }
        inputEventsSent += 1
    }

    /// Our button set as XInput's mask, which is what the wire carries.
    /// Inner radial deadzone as a fraction of full scale. This SC2 stick's resting drift spikes to
    /// ~8% on Y, so 8% leaked a phantom "up"; the pad reaches full ±1.0, so XInput's own standard
    /// deadzones (7849/32767 left, 8689/32767 right) fit and are what games are calibrated for.
    static let leftStickDeadzone: Float = 0.2395
    static let rightStickDeadzone: Float = 0.2651

    /// A radial deadzone: inside `deadzone` the stick reads centred; outside, the remaining range is
    /// rescaled to the full 0...1 so the edge still reaches the extremes.
    static func deadzoned(_ x: Float, _ y: Float, _ deadzone: Float) -> (Float, Float) {
        let magnitude = (x * x + y * y).squareRoot()
        guard magnitude > deadzone else { return (0, 0) }
        let scale = ((magnitude - deadzone) / (1 - deadzone)) / magnitude
        return (x * scale, y * scale)
    }

    static func wireButtons(_ buttons: GamepadButtons) -> UInt16 {
        var mask: UInt16 = 0
        let mapping: [(GamepadButtons, UInt16)] = [
            (.south, NvstGamepadPacket.Button.a),
            (.east, NvstGamepadPacket.Button.b),
            (.west, NvstGamepadPacket.Button.x),
            (.north, NvstGamepadPacket.Button.y),
            (.leftShoulder, NvstGamepadPacket.Button.leftShoulder),
            (.rightShoulder, NvstGamepadPacket.Button.rightShoulder),
            (.select, NvstGamepadPacket.Button.back),
            (.start, NvstGamepadPacket.Button.start),
            (.dpadUp, NvstGamepadPacket.Button.dPadUp),
            (.dpadDown, NvstGamepadPacket.Button.dPadDown),
            (.dpadLeft, NvstGamepadPacket.Button.dPadLeft),
            (.dpadRight, NvstGamepadPacket.Button.dPadRight),
            (.leftStick, NvstGamepadPacket.Button.leftThumb),
            (.rightStick, NvstGamepadPacket.Button.rightThumb),
            // Guide/Xbox/PS. Was dropped entirely, so the button did nothing in games that use it.
            // On the Steam Controller `.mode` is also the chord key for the client-side grip and
            // guide-cursor combos; those are consumed before this point, and anything that reaches
            // here is a plain Guide press the seat should see.
            (.mode, NvstGamepadPacket.Button.guide),
        ]
        for (ours, theirs) in mapping where buttons.contains(ours) { mask |= theirs }
        return mask
    }

    /// Translates the app's input model into an RI packet. Returns nil for events whose encoding
    /// has not been recovered.
    static func remoteInputPacket(for event: UserInputEvent) -> Data? {
        switch event {
        case .mouse(.moved(_, let deltaX, let deltaY, _)):
            NvstRemoteInput.mouseMove(deltaX: deltaX, deltaY: deltaY)
        case .mouse(.button(_, let button, let isPressed, _)):
            NvstRemoteInput.mouseButton(Self.wireButton(button), isPressed: isPressed)
        case .keyboard(let event):
            NvstRemoteInput.keyboard(
                virtualKey: NativeWebRTCTransport.keyboardCodes(forMacKeyCode: event.keyCode).keyCode,
                modifiers: event.modifiers.rawValue & 0x000f,
                isPressed: event.isPressed
            )
        case .mouse(.wheel(_, let delta, _)):
            NvstRemoteInput.mouseWheel(delta: delta)
        case .text, .gamepad:
            nil
        }
    }

    /// The app orders mouse buttons right=2/middle=3; the wire orders them middle=2/right=3.
    static func wireButton(_ button: MouseButton) -> NvstRemoteInput.Button {
        switch button {
        case .left: .left
        case .right: .right
        case .middle: .middle
        case .back: .extra1
        case .forward: .extra2
        }
    }

    /// Turning the microphone *off* is already true, so it succeeds; turning it on is a request this
    /// path cannot honour and has to be reported.
    public func setMicrophoneEnabled(_ enabled: Bool) async throws {
        guard enabled else { return }
        throw NativeNVSTError.transportFailed(
            "Microphone capture is not implemented on the Bifrost-free path yet.")
    }

    public func togglePerformanceOverlay() async throws {
        throw NativeNVSTError.notRunning
    }

    // MARK: - Teardown

    private func teardown(reason: String) async {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        controlKeepAliveTask?.cancel()
        controlKeepAliveTask = nil
        qosFeedbackTask?.cancel()
        qosFeedbackTask = nil
        audioReceiver?.stop()
        audioReceiver = nil
        inputHeartbeatTask?.cancel()
        inputHeartbeatTask = nil
        await logCounters()
        feedbackSender?.stop()
        feedbackSender = nil
        bundle?.close()
        bundle = nil
        bundleProbe?.stop()
        bundleProbe = nil
        receiver?.stop()
        receiver = nil
        // Stops before the decoder is invalidated: an in-flight access unit must not reach a
        // torn-down session.
        videoPipeline?.stop()
        videoPipeline = nil
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

    // MARK: - Allocation plumbing

    struct StreamProfile: Equatable, Sendable {
        var resolution: String?
        var fps: Int?
        var codec: String?
        var bitrateKbps: Int?
        /// The user's ceiling specifically. `bitrateKbps` accepts either key and drives the initial
        /// and peak rates; this one only ever comes from `maxBitrateKbps`, because announcing a cap
        /// that was really an initial rate would clamp the stream to its starting point.
        var maximumBitrateKbps: Int?
    }

    /// Reads the negotiated profile out of the allocation's session JSON so ANNOUNCE advertises
    /// what the seat already agreed to.
    static func streamProfile(from allocation: NativeNVSTSessionAllocation) -> StreamProfile {
        var profile = StreamProfile()
        for json in [allocation.sessionInfoJSON, allocation.settingsJSON, allocation.rawSessionJSON] {
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let negotiated = object["negotiatedStreamProfile"] as? [String: Any] ?? object
            if profile.resolution == nil, let resolution = negotiated["resolution"] as? String, !resolution.isEmpty {
                profile.resolution = resolution
            }
            // fps can live at the top level or inside `selectedVideoMode`/`selectedEncodeMode`,
            // and as a number or a string — the same places `NVSTCoreTransport` reads it. Missing it
            // is not cosmetic: the pacing feedback then defaults to 60 fps, and the seat's delay
            // controller holds the stream there even when 120 was negotiated.
            if profile.fps == nil {
                let candidates: [Any?] = [
                    negotiated["fps"], object["fps"],
                    (negotiated["selectedVideoMode"] as? [String: Any])?["fps"],
                    (object["selectedVideoMode"] as? [String: Any])?["fps"],
                    (negotiated["selectedEncodeMode"] as? [String: Any])?["fps"],
                    (object["selectedEncodeMode"] as? [String: Any])?["fps"],
                    negotiated["framesPerSecond"], object["framesPerSecond"],
                ]
                for candidate in candidates {
                    let value = (candidate as? NSNumber)?.intValue ?? (candidate as? String).flatMap(Int.init)
                    if let value, value > 0 { profile.fps = value; break }
                }
            }
            if profile.codec == nil, let codec = negotiated["codec"] as? String, !codec.isEmpty {
                profile.codec = codec
            }
            if profile.maximumBitrateKbps == nil,
               let cap = (negotiated["maxBitrateKbps"] as? NSNumber)?.intValue, cap > 0 {
                profile.maximumBitrateKbps = cap
            }
            if profile.bitrateKbps == nil {
                for key in ["maxBitrateKbps", "bitrateKbps"] {
                    guard let kbps = (negotiated[key] as? NSNumber)?.intValue, kbps > 0 else { continue }
                    profile.bitrateKbps = kbps
                    break
                }
            }
        }
        return profile
    }

    /// `host:port` or bare host → host.
    static func host(from signalingServer: String) -> String? {
        let trimmed = signalingServer.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.split(separator: ":").first.map(String.init)
    }

    static func mediaCodec(_ codec: NVSTVideoCodec) -> NativeNVSTVideoCodec {
        switch codec {
        case .h264: .h264
        case .hevc: .h265
        case .av1: .av1
        }
    }
}
