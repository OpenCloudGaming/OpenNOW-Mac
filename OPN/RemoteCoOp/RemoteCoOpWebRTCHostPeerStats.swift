//  What one guest's peer connection is actually achieving: the outbound sample loop and the pacing
//  telemetry derived from it.
//

import Foundation
@preconcurrency import WebRTC

extension OPNRemoteCoOpWebRTCHostPeer {
    func startSenderStatsPolling(peerConnection: RTCPeerConnection) {
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self, !self.closed else { return }
                await self.captureSenderStats(peerConnection: peerConnection)
            }
        }
        let previous = stateLock.withLock { () -> Task<Void, Never>? in
            let previous = senderStatsTask
            senderStatsTask = task
            return previous
        }
        previous?.cancel()
    }

    func captureSenderStats(peerConnection: RTCPeerConnection) async {
        // Read once: a retarget mid-sample would otherwise report a preset that disagrees with the
        // frame sizes on the same line.
        let preset = currentQualityPreset
        let source = stateLock.withLock { (width: lastSourceWidth, height: lastSourceHeight) }
        let report: RTCStatisticsReport = await withCheckedContinuation { continuation in
            peerConnection.statistics { continuation.resume(returning: $0) }
        }
        guard let outbound = report.statistics.values.first(where: { $0.type == "outbound-rtp" && ($0.values["kind"] as? String) == "video" }) else { return }

        let framesEncoded = (outbound.values["framesEncoded"] as? NSNumber)?.intValue ?? 0
        let framesSent = (outbound.values["framesSent"] as? NSNumber)?.intValue ?? 0
        let encodeTime = (outbound.values["totalEncodeTime"] as? NSNumber)?.doubleValue ?? 0
        let now = Date()

        // Rates over the interval, not since the session began: a lifetime average cannot show a
        // problem that started after the first few seconds.
        var encodedPerSecond = 0.0
        var msPerEncodedFrame = 0.0
        if let previous = previousSenderStats {
            let elapsed = now.timeIntervalSince(previous.timestamp)
            let deltaEncoded = framesEncoded - previous.framesEncoded
            if elapsed > 0 { encodedPerSecond = Double(deltaEncoded) / elapsed }
            if deltaEncoded > 0 { msPerEncodedFrame = ((encodeTime - previous.encodeTime) / Double(deltaEncoded)) * 1_000 }
        }
        previousSenderStats = (framesEncoded, framesSent, encodeTime, now)

        let limitation = (outbound.values["qualityLimitationReason"] as? String) ?? "unknown"
        let counts = stateLock.withLock { publishedRelayCounts }
        let forwarded = counts.forwarded
        let dropped = counts.dropped

        // Pacer queue time: how long a sent packet waited behind the bandwidth estimate. The
        // direct counterpart to the guest's jitter buffer - if this spikes while the guest's
        // buffer deepens, the sender's pacing is what the receiver learned to absorb.
        let sendDelay = (outbound.values["totalPacketSendDelay"] as? NSNumber)?.doubleValue ?? 0
        let packetsSent = (outbound.values["packetsSent"] as? NSNumber)?.intValue ?? 0
        var pacerMsPerPacket = -1.0
        if let previousSendDelay, let previousPacketsSent, packetsSent > previousPacketsSent {
            pacerMsPerPacket = ((sendDelay - previousSendDelay) / Double(packetsSent - previousPacketsSent)) * 1_000
        }
        previousSendDelay = sendDelay
        previousPacketsSent = packetsSent

        await callbacks.reportDelivery(OPNRemoteCoOpGuestDeliveryStats(
            frameWidth: (outbound.values["frameWidth"] as? NSNumber)?.intValue ?? 0,
            frameHeight: (outbound.values["frameHeight"] as? NSNumber)?.intValue ?? 0,
            encodedFramesPerSecond: encodedPerSecond,
            qualityLimitationReason: limitation,
            sourceWidth: source.width,
            sourceHeight: source.height,
            targetPreset: preset
        ))
        WebRTCMediaTelemetry.capture("webrtc.remote_coop.sender.video", level: .info, message: "Remote Co-Op outbound video.", attributes: [
            "participantID": participantID.uuidString,
            // "cpu" means the encoder is the constraint, "bandwidth" the network estimate, "none"
            // neither - in which case a low frame rate is the source's, not ours.
            "qualityLimitationReason": limitation,
            "encodedFps": String(format: "%.1f", encodedPerSecond),
            "encodeMsPerFrame": String(format: "%.1f", msPerEncodedFrame),
            "frameWidth": String((outbound.values["frameWidth"] as? NSNumber)?.intValue ?? 0),
            "frameHeight": String((outbound.values["frameHeight"] as? NSNumber)?.intValue ?? 0),
            "framesEncoded": String(framesEncoded),
            "framesSent": String(framesSent),
            // If `relayForwarded` tracks the preset rate but `encodedFps` is lower, the encoder is
            // dropping. If `relayForwarded` is itself low, the source is not producing more.
            "relayForwarded": String(forwarded),
            "relayDropped": String(dropped),
            "pacerMsPerPacket": String(format: "%.1f", pacerMsPerPacket),
            "preset": "\(preset.width)x\(preset.height)@\(preset.fps)"
        ])
    }

    func captureVideoPacingTelemetryIfNeeded() {
        guard videoRateLimiter.forwardedCount.isMultiple(of: 240), videoRateLimiter.droppedCount > 0 else { return }
        WebRTCMediaTelemetry.capture("webrtc.remote_coop.video.paced", level: .debug, message: "Remote Co-Op video rate limiter dropped frames above the preset rate.", attributes: [
            "participantID": participantID.uuidString,
            "deliveredFrames": String(videoRateLimiter.forwardedCount),
            "droppedFrames": String(videoRateLimiter.droppedCount),
            "fps": String(currentQualityPreset.fps),
            "latencyMode": latencyMode.rawValue
        ])
    }

    /// Carries the source's own capture timestamp through rather than re-stamping. See
    /// `forwardVideoFrame` for why that matters to the receiver's jitter buffer.
    ///
    /// The buffer goes through `.toI420()` for anything not already I420. Skipping that - passing
    /// NVST's `RTCCVPixelBuffer` straight to the encoder, on the theory that it is what the encoder
    /// wants natively and I420 was a wasted extra pass - was tried and measured as a real,
    /// reproducible bug: the guest's picture filled only the right half of the frame, a hard
    /// vertical seam at the exact midpoint, not the symmetric bars a scaling or CSS issue would
    /// produce. NVST's decoded buffers most likely carry a `bytesPerRow` padded wider than the true
    /// picture width - normal for VideoToolbox output, aligned for hardware access - and something
    /// in how the raw buffer reached the encoder read that padded stride as picture width instead of
    /// the buffer's own crop rectangle. `.toI420()` repacks into a tightly-packed buffer with no
    /// padding left to misread, which is what made this work before and is why it is back. The
    /// conversion cost this re-introduces is real; a genuine zero-copy fix needs to identify exactly
    /// which stage mishandles the stride, not just avoid the conversion that happened to hide it.

    func forwardVideoFrame(_ frame: OPNRemoteCoOpSharedVideoFrame) {
        guard !closed else { return }
        // Before the rate limit, so this stays current for a guest dropping most frames.
        let sourceChanged = stateLock.withLock { () -> Bool in
            let width = Int(frame.sourceFrame.width)
            let height = Int(frame.sourceFrame.height)
            defer {
                lastSourceWidth = width
                lastSourceHeight = height
            }
            return width != lastSourceWidth || height != lastSourceHeight
        }
        // The adapt box is derived from the source's shape, so a resolution change on the seat has to
        // re-request it. Without this the guest keeps the aspect of whatever arrived first.
        if sourceChanged, let source = stateLock.withLock({ videoSource }) {
            applyOutputFormat(to: source, preset: currentQualityPreset)
        }
        let arrivalNs = Int64(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds)
        // Rate limited before the conversion is requested: a 60 fps guest on a 120 fps source
        // converts nothing on half the frames.
        guard case .forward(let timestampNs) = videoRateLimiter.decide(sourceTimestampNs: frame.sourceFrame.timeStampNs, arrivalNs: arrivalNs) else { return }
        guard let capturer = stateLock.withLock({ videoCapturer }),
              let relayFrame = makeRelayVideoFrame(from: frame, timeStampNs: timestampNs) else { return }
        capturer.delegate?.capturer(capturer, didCapture: relayFrame)
        let counts = (forwarded: videoRateLimiter.forwardedCount, dropped: videoRateLimiter.droppedCount)
        stateLock.withLock { publishedRelayCounts = counts }
        captureVideoPacingTelemetryIfNeeded()
    }

    /// Reports what the *sender* is doing, because the guest's own numbers cannot distinguish the
    /// possible causes of a deep jitter buffer.
    ///
    /// A guest sees only that frames arrive irregularly. Whether that is the encoder falling behind,
    /// the source delivering fewer frames than the preset asks for, or this relay dropping them is
    /// only visible here. `qualityLimitationReason` is the decisive field: libwebrtc sets it to
    /// `cpu` when the encoder cannot keep up and `bandwidth` when the estimate is the constraint,
    /// which are opposite problems with opposite fixes.
    private func makeRelayVideoFrame(from frame: OPNRemoteCoOpSharedVideoFrame, timeStampNs: Int64) -> RTCVideoFrame? {
        let buffer = frame.i420Buffer()
        guard buffer.width > 0, buffer.height > 0 else { return nil }
        return RTCVideoFrame(buffer: buffer, rotation: frame.sourceFrame.rotation, timeStampNs: timeStampNs)
    }
}
