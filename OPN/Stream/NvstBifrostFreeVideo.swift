//
//  NvstBifrostFreeVideo.swift
//  OpenNOW
//
//  Bringing the video plane up: the Mjolnir receiver, the ICE/DTLS bundle, the decoder and the
//  feedback the seat's rate controller runs on. Split out of NvstBifrostFreeTransport.swift.
//

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

extension NvstBifrostFreeTransport {
    // MARK: - Video

    func startVideo(handoff: NVSTVideoHandoff, mediaReceiver: any NativeNVSTMediaReceiver) async throws {
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
        // The recorder is fed here rather than from the renderer, so a recording keeps its frames
        // when the surface is hidden, and so nothing on the decode thread has to reach the main
        // actor. It costs one uncontended lock per frame while idle.
        let recorder = self.recorder
        // Remote Co-Op guests are fed from the same tap and for the same reasons. The relay is a
        // no-op until a guest is connected, so a solo session pays one uncontended lock per frame.
        let coOpVideoRelay = self.remoteCoOpVideoRelay
        decoder.onPixelBuffer = { pixelBuffer, presentationTime, isKeyframe in
            recorder.appendNativePixelBuffer(pixelBuffer)
            coOpVideoRelay.renderPixelBuffer(pixelBuffer, presentationTime: presentationTime)
            sink?(pixelBuffer, presentationTime, isKeyframe)
        }
        self.decoder = decoder
        lastHandoff = handoff

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
        let pipeline = makeVideoPipeline(handoff: handoff, decoder: decoder, receiver: receiver, mediaContinuation: mediaContinuation)
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

    /// Builds the decode pipeline. Decode runs off this actor: sharing the actor with QoS,
    /// keepalives and input made every frame queue behind whatever else was pending, and the wait
    /// compounded across a burst — see `NvstVideoPipeline` for the measurements.
    /// `receiver` is passed in rather than read off `self`: this runs before `self.receiver` is
    /// assigned, and a capture list evaluates eagerly, so capturing the property would bind a
    /// permanently nil weak reference and silence every keyframe request the pipeline makes.
    private func makeVideoPipeline(handoff: NVSTVideoHandoff,
                                   decoder: NvstVideoToolboxDecoder,
                                   receiver: NvstMjolnirReceiver,
                                   mediaContinuation: AsyncStream<NativeNVSTVideoFrame>.Continuation) -> NvstVideoPipeline {
        // Decode runs off this actor. Sharing the actor with QoS, keepalives and input made every
        // frame queue behind whatever else was pending, and the wait compounded across a burst —
        // see `NvstVideoPipeline` for the measurements.
        // Experiment F: Geronimo's own strings ("Pace server frames to match client vsync") show
        // the seat paces its own frame generation to whatever vsync interval the client reports —
        // this used to go out as a hardcoded 16000 us (~62.5 Hz) regardless of the real display.
        let displayRefreshRate = OPNStreamPreferences.loadDeviceCapabilities().maxDisplayRefreshRate
        let displayVsyncMicroseconds = displayRefreshRate > 0 ? UInt32(1_000_000 / displayRefreshRate) : 16000
        return NvstVideoPipeline(
            decoder: decoder,
            clock: clock,
            frameTimeMicroseconds: sessionFrameTimeMicroseconds,
            displayVsyncMicroseconds: displayVsyncMicroseconds,
            logger: logger,
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
    }

    /// Brings up the ICE/DTLS/SCTP bundle. The seat arms its video relay only after this DTLS
    /// handshake completes, so this is what turns the Mjolnir socket from silent to streaming.
    ///
    /// On failure the STUN-only probe takes over: it cannot unlock media, but it keeps the NAT
    /// mapping alive and reports what the seat sends back.
    /// The mic send section decision at bundle bring-up. The host applies the microphone
    /// configuration before `start`, so it is already stored by this point. Four gates stand in
    /// front of the section: capture requested and the seat's DESCRIBE offer. A suppressed shape
    /// logs why.
    private func resolvedMicrophoneSetup(microphoneOfferedOnBundle: Bool) -> NvstWebRtcBundle.MicrophoneSetup? {
        let logger = self.logger
        guard let configuration = microphoneConfiguration, configuration.captureRequested else { return nil }
        if !microphoneOfferedOnBundle {
            logger?("NVST seat did not offer bundle microphone carriage; the mic stays on its (not yet recovered) legacy transport")
            return nil
        }
        return NvstWebRtcBundle.MicrophoneSetup(volume: configuration.volume,
                                                initiallyEnabled: configuration.initiallyEnabled)
    }

    func bringUpBundle(handoff: NVSTVideoHandoff, microphoneOfferedOnBundle: Bool) async -> NvstBundleReservation? {
        let logger = self.logger
        self.microphoneOfferedOnBundle = microphoneOfferedOnBundle
        guard Self.usesWebRtcBundle else {
            logger?("NVST bundle disabled; punching the bundle socket with bare STUN only")
            startBundleProbe(handoff: handoff)
            scheduleVideoHolePunch()
            return nil
        }
        let microphoneSetup = resolvedMicrophoneSetup(microphoneOfferedOnBundle: microphoneOfferedOnBundle)
        let bundle = NvstWebRtcBundle(handoff: handoff, logger: logger)
        let sender = NvstFeedbackSender()
        do {
            let identity = try await bundle.prepare(microphone: microphoneSetup)
            scheduleVideoHolePunch()
            sender.configure(
                channelWriter: { payload in _ = bundle.sendFeedback(payload) },
                // "ONOW" — a stable sender SSRC, as the official client uses a fixed one.
                senderSSRC: 0x4f4e_4f57,
                mediaSSRC: 0
            )
            // RR values straight from the receiver on each emit, so the seat's congestion
            // controller sees real loss and jitter rather than the flat zeros of an
            // updateMediaState snapshot that only refreshes on the log cadence.
            sender.setReportProvider { [weak receiver] in receiver?.receiverReportBlock() }
            clock.start()
            installBundleHandlers(bundle, sender: sender, logger: logger)
            self.bundle = bundle
            let microphone = bundle.microphoneNegotiation
            microphoneNegotiated = microphone.negotiated
            microphoneSenderSsrc = microphone.senderSsrc
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
                dtlsFingerprint: identity.dtlsFingerprint,
                microphoneNegotiated: microphoneNegotiated,
                microphoneSenderSsrc: microphoneSenderSsrc
            )
        } catch {
            logger?("NVST bundle bring-up failed: \(error.localizedDescription); falling back to the STUN-only probe")
            bundle.close()
            startBundleProbe(handoff: handoff)
            scheduleVideoHolePunch()
            return nil
        }
    }

    /// Wires the bundle's channel callbacks back into the transport actor.
    private func installBundleHandlers(_ bundle: NvstWebRtcBundle,
                                       sender: NvstFeedbackSender,
                                       logger: (@Sendable (String) -> Void)?) {
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
        // Straight to the recorder, no actor hop: this runs on the CoreAudio render thread, where
        // waiting on anything is a priority inversion. The recorder copies and returns.
        let recorder = self.recorder
        let coOpAudioRelay = self.remoteCoOpAudioRelay
        bundle.onGameAudioFrame = { audioBufferList, frameCount, sampleRate, channels in
            recorder.appendGameAudio(audioBufferList: audioBufferList, frameCount: frameCount, sampleRate: sampleRate, channels: channels)
            coOpAudioRelay.renderAudioFrame(audioBufferList: audioBufferList, frameCount: frameCount, sampleRate: sampleRate, channels: channels)
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
    }

    /// Official punches the video socket ~1 s after the bundle is up, never before.
    func scheduleVideoHolePunch() {
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
    func startControlKeepAlive() {
        guard !isTornDown, controlKeepAliveTask == nil else { return }
        logger?("NVST control keepalive started (\(Int(NvstControlCommand.pingBackIntervalSeconds))s)")
        controlKeepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sendControlKeepAlive()
                try? await Task.sleep(for: .seconds(NvstControlCommand.pingBackIntervalSeconds))
            }
        }
    }

    func noteRemoteAudio(trackCount: Int) {
        remoteAudioTrackCount = trackCount
    }

    /// The seat runs one-way-delay rate control (`bwe.useOwdCongestionControl:1`) and asks for
    /// feedback no less often than `vqos[0].bw.txRxLag.minFeedbackTxDeltaMs:200`. Without any QoS
    /// report its controller has no evidence the path is healthy and holds the encoder far below
    /// what the link carries: 53 packets per second measured against the official client's 401 on
    /// the same title. The captured client sends command `0x207` on
    /// `control_channel_partially_reliable` at about 18 Hz.
    func startQosFeedback() {
        guard !isTornDown, qosFeedbackTask == nil else { return }
        logger?("NVST QoS feedback started (\(String(format: "%.0f", 1 / NvstQosReport.interval))/s)")
        qosFeedbackTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sendQosReport()
                await self.sendRtpStatsIfNeeded()
                await self.sendControlChannelStatsIfNeeded()
                try? await Task.sleep(for: .seconds(NvstQosReport.interval))
            }
        }
    }

    func sendQosReport() {
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

    /// The client's RTP receive statistics (`0x208`) with its NACK statistics companion
    /// (`0x20a`), sent together every `NvstRtpStatsReport.frameInterval` emitted frames — the
    /// frame-gated cadence of the official `sendRtpStats` builder. The fields carry what this
    /// pipeline actually measures; the NACK report is all zeros because this client does not
    /// send NACKs, exactly the payload the official client sends before its receiver exists.
    func sendRtpStatsIfNeeded() {
        guard let bundle, let receiver else { return }
        let stats = receiver.stats
        let frame = stats.framesEmitted
        guard frame >= lastRtpStatsFrame + NvstRtpStatsReport.frameInterval else { return }
        lastRtpStatsFrame = frame
        let frameNumber = UInt32(truncatingIfNeeded: frame)
        let report = NvstRtpStatsReport(
            frameNumber: frameNumber,
            totalReceivedPackets: stats.authenticatedPackets,
            outOfOrderPackets: UInt32(clamping: stats.outOfOrderPackets),
            dropEvents: UInt32(clamping: stats.recoveries),
            latePackets: UInt32(clamping: stats.latePackets),
            droppedPackets: UInt32(clamping: stats.droppedPackets),
            recoveredPackets: UInt32(clamping: stats.recoveredPackets),
            maxDropBurstLength: stats.maxLossBurst,
            maxWaitingQueueDepth: stats.maxReorderDepth,
            duplicatePackets: UInt32(clamping: stats.duplicatePackets),
            // Zero until the bundle carries the mic send section; the sample is refreshed by the
            // transport heartbeat's `refreshTransportStatistics`.
            micChatSentDataBytes: bundle.microphoneSentBytes)
        let nackStats = NvstRtpNackStatsReport(frameNumber: frameNumber)
        if bundle.sendPartiallyReliableControl(report.command),
           bundle.sendPartiallyReliableControl(nackStats.command) {
            rtpStatsReportsSent += 1
        }
    }

    /// Control-channel statistics (`0x313`) on the interval our own announce declares, sent by
    /// stream 0 only — the official client transmits no control-channel stats from any other
    /// stream. The timestamp is session-elapsed microseconds, the closest honest analog to the
    /// official library's steady-clock-epoch microseconds.
    func sendControlChannelStatsIfNeeded() {
        guard let bundle, sessionStartedAt != nil else { return }
        let now = Date()
        if let last = controlStatsLastSentAt,
           now.timeIntervalSince(last) < NvstControlChannelStatsReport.transmitInterval { return }
        let counters = bundle.controlChannelStats
        let report = NvstControlChannelStatsReport(
            timestampMicroseconds: sessionElapsedMicroseconds(),
            totalMessagesSent: counters.totalSent,
            totalMessagesFailed: counters.totalFailed,
            totalBytesSent: counters.totalBytes,
            commands: counters.commands)
        guard bundle.sendPartiallyReliableControl(report.command) else { return }
        controlStatsLastSentAt = now
        controlStatsReportsSent += 1
    }

    /// The seat's cursor notifications: the first one means it is publishing cursor state, so its
    /// composited pointer is no longer needed and capture is turned back off. Leaving both on is
    /// the double-cursor bug — the seat's pointer baked into the video underneath our own.
    /// `mimicRemoteCursor` stays enabled, so notifications keep coming after capture stops.
    func handleRemoteCursor(_ cursor: NvstRemoteCursor) {
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


    /// Assigning the property directly from the main actor is a data race on this actor's state —
    /// the compiler flags it, and it is exactly the kind of cross-actor write that works until it
    /// races. Callers hand the handler over through the actor instead.
    public func setRemoteCursorVisibilityHandler(_ handler: (@MainActor @Sendable (Bool) -> Void)?) {
        onRemoteCursorVisibilityChanged = handler
    }

    /// Microseconds since this session started, as the remote-input timestamps are expressed.
    func sessionElapsedMicroseconds() -> UInt64 {
        guard let start = sessionStartedAt else { return 0 }
        return UInt64(max(0, Date().timeIntervalSince(start)) * 1_000_000)
    }

    /// The session's server name from the CloudMatch allocation, mirroring how
    /// `NativeNVSTLaunchPayload` resolves it: `serverLocation` at the session or request level,
    /// then `zoneName`. CloudMatch omits all three on this path, so the zone the session was
    /// allocated in is the practical answer: the streaming base URL is the region endpoint.
    /// Reported as "np-tyo-01 (Japan)" — the seat's own name plus the human region `serverInfo`
    /// gave it, dropping the parenthetical when the two are the same string.
    static func sessionServerLocation(for allocation: NativeNVSTSessionAllocation) -> String? {
        let server = sessionServerLocation(fromRawSessionJSON: allocation.rawSessionJSON)
            ?? endpointLabel(forStreamingBaseURL: allocation.streamingBaseURL)
        let region = regionName(forStreamingBaseURL: allocation.streamingBaseURL)
        switch (server, region) {
        case let (server?, region?):
            return server.caseInsensitiveCompare(region) == .orderedSame ? server : "\(server) (\(region))"
        case let (server?, nil): return server
        case let (nil, region?): return region
        case (nil, nil): return nil
        }
    }

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

    /// The human region name behind the seat this session landed on — "Japan" for "np-tyo-01",
    /// which the endpoint hostname alone cannot say (the region hostname is a DNS alias of it).
    static func regionName(forStreamingBaseURL baseURL: String) -> String? {
        let name = OPNStreamPreferences.regionName(forStreamingBaseUrl: baseURL)
        return name.isEmpty ? nil : name
    }

    /// The endpoint's own subdomain label ("np-tyo-01"), which is the seat name the vendored client
    /// showed. An address that is a bare IP has no name to give.
    static func endpointLabel(forStreamingBaseURL baseURL: String) -> String? {
        guard let host = endpointHost(baseURL) else { return nil }
        let label = String(host.split(separator: ".").first ?? "")
        guard !label.isEmpty, label.contains(where: { $0.isLetter }) else { return nil }
        return label
    }

    static func endpointHost(_ baseURL: String) -> String? {
        guard let host = URLComponents(string: baseURL)?.host ?? host(from: baseURL), !host.isEmpty else { return nil }
        return host
    }

    /// Tells the seat which frame the decoder could not use, so its encoder stops referencing it.
    /// Throttled: a broken reference chain rejects every following frame, and one range covers them.
    func invalidateFrame(_ frameIndex: UInt32) {
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
    func requestKeyframeOverControlChannel() {
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
    func announceClientState() {
        guard let bundle, !didAnnounceClientState else { return }
        didAnnounceClientState = true
        let window = bundle.sendControl(.windowStateChange())
        let system = bundle.sendControl(.systemStateChange())
        logger?("NVST client state announced (window=\(window) system=\(system))")
    }

    func inputDidNegotiate(_ version: UInt16) {
        // No input heartbeat: the captured official client sends none. Upstream's transport does,
        // but that is its own design rather than something the seat asks for.
        logger?("NVST input negotiated at protocol version \(version); ready=\(bundle?.isInputReady == true)")
        activateInput()
    }

    /// Sends the device descriptor and enable that the native stack puts between the seat's
    /// handshake and its first input event. Our remote-input packets already match the native
    /// stack's byte for byte and the seat ignored them, so this pair is the remaining difference.
    func activateInput() {
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
        // Activation announces whatever is connected now, which at connect time is the host alone.
        // Remote Co-Op guests join mid-session and re-announce the widened bitmap through
        // `updateGamepadTopology`; that later `0x20d` carries the same descriptor field as this
        // one, so it widens the existing device set rather than registering a second one.
        // Pad 0 is what the captured client announces here and what `connectedBitmap(for:)` falls
        // back to; seeding the set with it keeps the announced bitmap and the set that gates state
        // packets in agreement from the first frame.
        if connectedGamepadIndices.isEmpty { connectedGamepadIndices = [0] }
        let activationBitmap = NvstGamepadPacket.connectedBitmap(for: connectedGamepadIndices)
        sent.append("descriptor=\(bundle.sendControl(NvstInputActivation.deviceDescriptor(timestampMicroseconds: sessionElapsedMicroseconds(), connectedBitmap: activationBitmap)))")
        // The pad is registered now, so the lazy pre-first-input descriptor must not fire as well:
        // the official client sends exactly one 0x20d per session, and a second one at a *different*
        // index is what created the phantom pad.
        registeredGamepadBitmap = activationBitmap
        // Cursor capture ON for startup so the seat composites a pointer immediately, plus remote
        // cursor tracking so it publishes shape/mode notifications. Once a notification arrives the
        // capture is turned back off (see `handleRemoteCursorNotification`) and the pointer becomes
        // ours to draw — the seat keeps publishing because tracking stays on.
        sent.append("cursorCapture=\(bundle.sendControl(NvstInputActivation.mouseCursorCapture(isEnabled: true)))")
        sent.append("cursorTrack=\(bundle.sendControl(NvstInputActivation.mimicRemoteCursor(isEnabled: true)))")
        sent.append("window=\(bundle.sendControl(.windowStateChange()))")
        sent.append("system=\(bundle.sendControl(.systemStateChange()))")
        sent.append("enableOn=\(bundle.sendControl(NvstInputActivation.enableInput(counter: UInt32((videoPipeline?.snapshot.frameAcksSent ?? 0) + 1))))")
        logger?("NVST input activation sent (\(sent.joined(separator: " ")))")
    }

    func sendControlKeepAlive() {
        guard let bundle else { return }
        // The official payload is a per-stream 32-bit value, and zero is what the client sends
        // before a stream object exists; the frame index is the same shape once video flows.
        let value = receiver?.stats.framesEmitted ?? 0
        let sent = bundle.sendControl(.pingBackAck(streamValue: UInt32(truncatingIfNeeded: value)))
        if !sent { logger?("NVST control keepalive write failed") }
    }

    func beginVideoHolePunch() {
        guard Self.punchesVideoSocket else {
            logger?("NVST video socket hole punch suppressed (OPN_NVST_VIDEO_PUNCH=0)")
            return
        }
        receiver?.beginHolePunch()
        logger?("NVST video socket hole punch started")
    }

    /// Once the feedback channel is live the Mjolnir socket stops sending its own SRTCP: the seat
    /// expects reports on one plane, not two.
    func adoptFeedbackSender(_ sender: NvstFeedbackSender) {
        guard let receiver else { return }
        if let ssrc = receiver.stats.boundSSRC { sender.updateMediaSSRC(ssrc) }
    }

    /// STUN-only ICE keepalive on the bundle socket, used when the real bundle cannot come up.
    func startBundleProbe(handoff: NVSTVideoHandoff) {
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
    func reportFatalDecodeError(_ message: String) {
        terminationContinuation?.yield(.transportFailed(NativeNVSTTransportFailure(
            message: "Native NVST could not decode video: \(message)",
            recoveryClassification: .permanent
        )))
    }
}
