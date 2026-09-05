import CoreMedia
import Foundation

/// Session-relative time, shared by the transport actor and the video pipeline that runs off it.
///
/// NVST timestamps are session-scale, not epoch-scale — a seat that sanity-checks them against its
/// own session time discards an epoch value — so both sides have to read the same origin.
public final class NvstSessionClock: @unchecked Sendable {
    let lock = NSLock()
    var startedAt: Date?

    public init() {}

    /// Starts the clock. Later calls are ignored, so the origin cannot drift mid-session.
    public func start(at date: Date = Date()) {
        lock.lock()
        if startedAt == nil { startedAt = date }
        lock.unlock()
    }

    public var startDate: Date? {
        lock.lock()
        defer { lock.unlock() }
        return startedAt
    }

    public func elapsedMicroseconds(now: Date = Date()) -> UInt64 {
        guard let start = startDate else { return 0 }
        return UInt64(max(0, now.timeIntervalSince(start)) * 1_000_000)
    }
}

/// Decode and acknowledge video, off the transport actor.
///
/// Every access unit used to be handed to the actor as its own `Task`, which put decode in the same
/// serial queue as QoS reports, keepalives and every input event. Actor execution is one job at a
/// time, so a burst of frames drained one behind another: each frame waited for all the work queued
/// ahead of it, and the wait compounded frame by frame (measured: 46 → 62 → 78 → 92 → 109 → 126 ms
/// across six consecutive frames) until the burst cleared and latency snapped back to ~1 ms. That
/// is the random 500–1000 ms spike, seen from the inside.
///
/// The video path has no reason to be on the actor: the decoder is its own lock-guarded object and
/// the bundle's channel writes are thread-safe. It runs here instead, on one serial queue of its
/// own, so a slow decode delays only the next frame — never input, feedback or keepalives — and
/// nothing else can delay a frame.
public final class NvstVideoPipeline: @unchecked Sendable {
    /// One frame's time through the client, in milliseconds.
    public struct StageTimings: Sendable, Equatable {
        /// Receive thread finished the access unit -> this pipeline started on it (queue backlog).
        public var hop = 0.0
        /// `VTDecompressionSessionDecodeFrame` submission, including any session rebuild.
        public var decode = 0.0
        /// The frame-ack (and pacing report) write onto the SCTP control channel.
        public var ack = 0.0

        public var total: Double { hop + decode + ack }

        mutating func raise(to other: StageTimings) {
            hop = max(hop, other.hop)
            decode = max(decode, other.decode)
            ack = max(ack, other.ack)
        }

        mutating func add(_ other: StageTimings) {
            hop += other.hop
            decode += other.decode
            ack += other.ack
        }
    }

    public struct Counters: Sendable {
        public var framesHandled: UInt64 = 0
        public var frameAcksSent = 0
        public var frameAckFailures = 0
        public var pacingReportsSent = 0
        public var pacingReportFailures = 0
        public var missingParameterSetFrames = 0
        public var slowFrames = 0
        /// Times the pipeline fell behind and skipped to a keyframe.
        public var latencyResyncs = 0
        /// Frames dropped while waiting for that keyframe.
        public var framesSkippedForLatency = 0
        /// Times the keyframe never arrived and decoding resumed with a broken reference chain
        /// rather than staying frozen.
        public var abandonedResyncs = 0
        public var lastDecodeLatencyMilliseconds = 0.0
        public var peak = StageTimings()
        public var total = StageTimings()
        /// Frames still awaiting decode output at each submit, by count. See the submit path.
        public var inFlightHistogram: [Int: Int] = [:]

        /// Peak names the worst stall; mean names whether the client keeps up at all.
        public var timingSummary: String {
            let frames = Double(max(1, framesHandled))
            let inFlight = inFlightHistogram.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
            return String(format: "peak[hop=%.1f decode=%.1f ack=%.1f] mean[hop=%.2f decode=%.2f ack=%.2f]ms inFlight=%@",
                          peak.hop, peak.decode, peak.ack,
                          total.hop / frames, total.decode / frames, total.ack / frames, inFlight)
        }
    }

    /// A frame the client spent longer than this on is a stall, not jitter: at 120 fps the whole
    /// budget is 8.3 ms.
    public static let slowFrameMilliseconds = 50.0
    public static let maximumLoggedSlowFrames = 60
    /// Consecutive hard decode failures before the stream is called unrecoverable.
    public static let fatalDecodeFailureCount = 30
    /// Frames allowed to wait for decode before the pipeline is declared behind. Eight frames is
    /// 66 ms at 120 fps — past normal jitter, under anything a player would call lag.
    public static let maximumPendingFrames = 8
    /// Never resynchronise more often than this. A decoder that simply cannot keep up would
    /// otherwise sit above the threshold permanently and skip to a keyframe over and over, turning
    /// steady lag into a stutter loop — worse to play than the lag it was meant to remove.
    public static let minimumResyncInterval = 2.0
    /// Consecutive over-threshold frames before the pipeline is declared behind — about 250 ms at
    /// 120 fps.
    ///
    /// Queue depth alone is the wrong trigger: a burst of a dozen frames arrives normally, right
    /// after a keyframe, and drains in milliseconds. Acting on one such burst cost a measured
    /// session 1,937 failed decodes against 4,427 good ones, because the resync broke the reference
    /// chain for a transient that would have cleared itself. Only a backlog that persists is a
    /// pipeline that cannot keep up.
    public static let sustainedBacklogFrames = 30
    /// How long to keep skipping while waiting for the keyframe, re-asking as it goes. Resuming on
    /// a broken chain rejects every frame until the next keyframe arrives — at the seat's own
    /// keyframe cadence that can be many seconds — so this waits considerably longer than it did
    /// before giving up.
    public static let maximumKeyframeWait = 2.0
    /// How often to re-ask for the keyframe while waiting.
    public static let keyframeRetryInterval = 0.4

    let decoder: NvstVideoToolboxDecoder
    private let clock: NvstSessionClock
    private let frameTimeMicroseconds: UInt32
    /// The real display's vsync interval, in microseconds. Geronimo's own strings
    /// ("Pace server frames to match client vsync", `CVDisplayLinkGetActualOutputVideoRefreshPeriod`
    /// imports) show the seat's frame pacer targets whatever vsync interval the client reports —
    /// this was hardcoded to a hardware-agnostic 16000 before, meaning we told the seat to pace to
    /// ~62.5 Hz regardless of the client's real display.
    private let displayVsyncMicroseconds: UInt32
    let logger: (@Sendable (String) -> Void)?
    /// Hands the raw access unit to whatever else wants it (the media-session stream). Must not
    /// block: it is called on the decode queue.
    private let mediaSink: (@Sendable (NvstAccessUnit) -> Void)?
    private let onKeyframeNeeded: @Sendable () -> Void
    private let onFatalDecodeError: @Sendable (String) -> Void

    /// Below the receive loop's `.userInteractive` deliberately: decode falling a frame behind
    /// costs latency, while the receive loop falling behind costs packets.
    let queue = DispatchQueue(label: "com.opennow.nvst.decode", qos: .userInitiated)
    let lock = NSLock()
    /// The video receiver is armed at SETUP, before the ICE/DTLS bundle exists — the bundle needs
    /// SETUP's own ping payload — so the ack channel arrives later than this object does.
    var bundle: NvstWebRtcBundle?
    private var counters = Counters()
    private var loggedSlowFrames = 0
    private var frameAckNumber: UInt32 = 0
    private var lastFrameAckAt: Date?
    /// Throttle for `logFeedbackSample`.
    private var lastFeedbackLogAt: Date?
    /// Session-clock stamp of the previous frame ack, for the measured inter-frame interval.
    private var lastAckElapsedMicroseconds: UInt64?
    /// Frames handled since the last 0x203 report, for that report's `groupCount` — a real
    /// capture (2026-08-28) confirmed this is genuinely "frames since last report", not a fixed
    /// small constant.
    private var framesSincePacingReport = 0
    private var consecutiveDecodeFailures = 0
    private var isStopped = false
    /// Frames submitted but not yet processed. The queue's depth, in other words.
    private var pendingFrames = 0
    /// Decoder failures already seen by the async-failure check, so each is answered once.
    private var observedDecodeFailures: UInt64 = 0
    private var isAwaitingKeyframe = false
    private var awaitingKeyframeSince: UInt64?
    private var lastResyncAt: UInt64?
    private var lastKeyframeRequestAt: UInt64?
    /// Consecutive frames seen with the queue over the threshold.
    private var backlogStreak = 0

    /// One entry per submitted unit awaiting its asynchronous decode completion, in submission
    /// order — VideoToolbox's own serial guarantee for this session means completions arrive in
    /// the same order, so a plain FIFO is enough to match a completion back to its unit without
    /// carrying an explicit ID through the decoder.
    private struct PendingCompletion {
        let unit: NvstAccessUnit
        let hopMilliseconds: Double
        let startedAt: UInt64
    }
    private var pendingCompletions: [PendingCompletion] = []
    /// Frame index of the newest keyframe handed to `submit`, so frames still queued ahead of it can
    /// be recognised as superseded while a resync is pending.
    private var latestSubmittedKeyframeIndex: UInt32?

    /// While a resync waits for a keyframe, a non-keyframe is dropped only when a newer keyframe is
    /// already queued behind it — it would be decoded and then replaced before anyone saw it.
    static func dropsStaleFrame(frameIndex: UInt32, latestSubmittedKeyframeIndex: UInt32?) -> Bool {
        guard let keyframe = latestSubmittedKeyframeIndex else { return false }
        return keyframe > frameIndex
    }

    public init(decoder: NvstVideoToolboxDecoder,
                clock: NvstSessionClock,
                frameTimeMicroseconds: UInt32,
                displayVsyncMicroseconds: UInt32,
                logger: (@Sendable (String) -> Void)?,
                mediaSink: (@Sendable (NvstAccessUnit) -> Void)?,
                onKeyframeNeeded: @escaping @Sendable () -> Void,
                onFatalDecodeError: @escaping @Sendable (String) -> Void) {
        self.decoder = decoder
        self.clock = clock
        self.frameTimeMicroseconds = frameTimeMicroseconds
        self.displayVsyncMicroseconds = displayVsyncMicroseconds
        self.logger = logger
        self.mediaSink = mediaSink
        self.onKeyframeNeeded = onKeyframeNeeded
        self.onFatalDecodeError = onFatalDecodeError
        // The ack used to fire right after `decoder.decode(unit)` returned — which is only the
        // synchronous submission accepted by VideoToolbox, not the frame actually finishing
        // decode. That answered the seat's frame pacer before the frame the pacer was asking
        // about even existed. This ties the ack to the real asynchronous completion instead.
        decoder.onDecodeCompleted = { [weak self] success in self?.handleDecodeCompleted(success: success) }
    }

    /// Hands over the channel the frame acks go out on, once the bundle is up.
    public func attach(bundle: NvstWebRtcBundle?) {
        lock.lock()
        self.bundle = bundle
        lock.unlock()
    }

    public var snapshot: Counters {
        lock.lock()
        defer { lock.unlock() }
        return counters
    }

    /// Called on the receive thread. Stamps the handover so queue backlog stays measurable, then
    /// gets off that thread immediately: draining the media socket must never wait for a decode.
    public func submit(_ unit: NvstAccessUnit) {
        let enqueued = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        pendingFrames += 1
        if unit.isKeyframe { latestSubmittedKeyframeIndex = unit.frameIndex }
        lock.unlock()
        queue.async { [weak self] in self?.process(unit, enqueuedAt: enqueued) }
    }

    public func stop() {
        lock.lock()
        isStopped = true
        lock.unlock()
    }

    private func process(_ unit: NvstAccessUnit, enqueuedAt: UInt64) {
        let gate = evaluateLatencyGate()
        guard !gate.stopped else { return }

        if gate.skipping {
            if unit.isKeyframe {
                lock.lock()
                isAwaitingKeyframe = false
                awaitingKeyframeSince = nil
                lock.unlock()
                logger?("NVST decode resynchronised on a keyframe")
            } else {
                // Waiting for the keyframe used to mean dropping every frame until it came: a frozen
                // picture for as long as the seat took — 169 frames, 1.4 s, on a 1440p launcher
                // transition (2026-09-05). Now the backlog keeps decoding, late but moving, and only
                // frames the queue already holds a newer keyframe behind are dropped: those can never
                // be shown, the keyframe supersedes them. The freeze becomes a latency jump.
                lock.lock()
                let stale = Self.dropsStaleFrame(frameIndex: unit.frameIndex, latestSubmittedKeyframeIndex: latestSubmittedKeyframeIndex)
                if stale { counters.framesSkippedForLatency += 1 }
                lock.unlock()
                if stale { return }
            }
        }

        // VideoToolbox rejects a frame with a broken reference chain in its asynchronous output
        // handler, not by throwing out of `decode` — the live -12909 bursts never touched the
        // catch below. The failure is visible here one frame later, which at stream rate is
        // milliseconds; ask for the keyframe the chain needs, at the retry cadence.
        let asyncFailures = decoder.failedFrameCount
        if asyncFailures > observedDecodeFailures {
            observedDecodeFailures = asyncFailures
            requestKeyframeThrottled()
        }

        let started = DispatchTime.now().uptimeNanoseconds
        var timings = StageTimings()
        timings.hop = Self.milliseconds(from: enqueuedAt, to: started)
        mediaSink?(unit)

        do {
            // How many earlier submissions VideoToolbox still has not answered when this one goes
            // in. A decoder that holds each frame until the next arrives shows 1 here on nearly
            // every frame; one that returns frames as they finish shows 0.
            lock.lock()
            counters.inFlightHistogram[pendingCompletions.count, default: 0] += 1
            lock.unlock()
            try decoder.decode(unit)
            consecutiveDecodeFailures = 0
            // Decode is asynchronous from here — VideoToolbox has only accepted the submission.
            // `handleDecodeCompleted` fires the ack once the frame is actually decoded (or
            // failed), in the same order these are pushed.
            lock.lock()
            pendingCompletions.append(PendingCompletion(unit: unit, hopMilliseconds: timings.hop, startedAt: started))
            lock.unlock()
        } catch NvstVideoToolboxDecoder.DecoderError.missingParameterSets {
            // Normal until the seat answers with a keyframe; nudge it. Silently counting these was
            // hiding a stalled stream: with no feedback channel the nudge never left the client.
            lock.lock()
            counters.missingParameterSetFrames += 1
            lock.unlock()
            onKeyframeNeeded()
            return
        } catch {
            consecutiveDecodeFailures += 1
            logger?("NVST decode error: \(error.localizedDescription)")
            // A bad-data rejection means the reference chain is broken, and every following frame
            // fails the same way until a keyframe arrives — nothing else on this path asks for
            // one. Waiting for the fatal threshold cost a measured ~141 consecutive rejected
            // frames (~1.2 s at 120 fps) per loss event, each of them also unacknowledged, which
            // reads to the seat's frame pacer as a client that stopped consuming.
            requestKeyframeThrottled()
            if consecutiveDecodeFailures >= Self.fatalDecodeFailureCount {
                consecutiveDecodeFailures = 0
                onFatalDecodeError(error.localizedDescription)
            }
            return
        }
    }

    /// Whether this frame should be decoded at all.
    ///
    /// A backlog never drains on its own: the queue is served at best as fast as frames arrive, so
    /// whatever latency it accumulates is permanent, and a 736 ms mean with an 8.5 s peak was
    /// measured on a saturated 5K120 session. Skipping to the next keyframe trades a brief glitch
    /// for bounded latency — and since skipped frames break the decoder's reference chain anyway,
    /// resuming anywhere else would show corruption instead.
    private func evaluateLatencyGate() -> (stopped: Bool, skipping: Bool) {
        lock.lock()
        let stopped = isStopped
        pendingFrames -= 1
        let backlog = pendingFrames
        var skipping = isAwaitingKeyframe
        let now = DispatchTime.now().uptimeNanoseconds
        // A burst is not a backlog: only count frames that arrive with the queue already deep, and
        // reset the streak the moment it drains.
        backlogStreak = backlog > Self.maximumPendingFrames ? backlogStreak + 1 : 0
        var retryKeyframe = false
        if skipping, Self.seconds(from: awaitingKeyframeSince ?? now, to: now) > Self.maximumKeyframeWait {
            // The keyframe never came. Decode what we have rather than keep the picture frozen —
            // every frame will be rejected until one arrives, so this is the lesser evil, not a
            // good outcome.
            skipping = false
            isAwaitingKeyframe = false
            awaitingKeyframeSince = nil
            counters.abandonedResyncs += 1
        } else if skipping, Self.seconds(from: lastKeyframeRequestAt ?? now, to: now) >= Self.keyframeRetryInterval {
            lastKeyframeRequestAt = now
            retryKeyframe = true
        }
        let sinceLastResync = lastResyncAt.map { Self.seconds(from: $0, to: now) } ?? .infinity
        if !skipping, backlogStreak >= Self.sustainedBacklogFrames, sinceLastResync >= Self.minimumResyncInterval {
            skipping = true
            isAwaitingKeyframe = true
            awaitingKeyframeSince = now
            lastKeyframeRequestAt = now
            lastResyncAt = now
            backlogStreak = 0
            counters.latencyResyncs += 1
            lock.unlock()
            logger?("NVST decode has been \(backlog) frames behind for \(Self.sustainedBacklogFrames) frames; skipping to the next keyframe")
            onKeyframeNeeded()
            lock.lock()
        }
        lock.unlock()
        // Outside the lock: the retry reaches back into the transport.
        if retryKeyframe { onKeyframeNeeded() }
        return (stopped, skipping)
    }

    /// Matches one asynchronous decode completion to the unit it was for (FIFO order — see
    /// `pendingCompletions`), sends the ack only on success, and never blocks the decode thread
    /// this runs on: sending happens via the bundle's own thread-safe channel writer.
    private func handleDecodeCompleted(success: Bool) {
        lock.lock()
        guard !pendingCompletions.isEmpty else { lock.unlock(); return }
        let entry = pendingCompletions.removeFirst()
        lock.unlock()
        guard success else { return }
        let decodedAt = DispatchTime.now().uptimeNanoseconds
        var timings = StageTimings()
        timings.hop = entry.hopMilliseconds
        timings.decode = Self.milliseconds(from: entry.startedAt, to: decodedAt)
        sendFrameAck(unit: entry.unit, decodedAt: decodedAt, timings: &timings)
        record(timings, frameNumber: frameAckNumber, unit: entry.unit)
    }

    /// Acknowledges one decoded frame to the seat's frame pacer. `video[0].framePacing.mode:1`
    /// with `framePacing.feedbackMode:1` puts the seat in the pacer that follows the client's own
    /// cadence, and the capture shows the native stack answering every single frame with command
    /// `0x204` — 1790 of them for 1789 frames. Answering none is what held the seat at 8.7 frames
    /// per second against the native stack's 60.05 on the same title: the pacer had no cadence to
    /// open up against.
    private func sendFrameAck(unit: NvstAccessUnit, decodedAt: UInt64, timings: inout StageTimings) {
        let now = Date()
        let nowMicroseconds = clock.elapsedMicroseconds(now: now)
        // The ack bookkeeping moves under the same lock as the channel reference: decode
        // completion callbacks are not guaranteed to arrive serialized, and the frame number and
        // inter-frame baseline are a read-modify-write pair that must not interleave.
        lock.lock()
        let channel = bundle
        frameAckNumber += 1
        lastFrameAckAt = now
        let measuredInterFrame = lastAckElapsedMicroseconds.map { UInt32(clamping: nowMicroseconds &- $0) }
            ?? frameTimeMicroseconds
        lastAckElapsedMicroseconds = nowMicroseconds
        lock.unlock()
        guard let bundle = channel else { return }
        // The capture documents this field as the MEASURED interval since the previous frame —
        // the pacer's view of the cadence the client actually sustains (15905 µs on a 60 fps
        // session, not the nominal 16667). Sending the constant target here claimed a perfect
        // cadence every frame; the matched A/B (vendored 120 vs ours ~108–112, same game, same
        // scene, same bitrate) says the pacer does not open up for that.
        //
        // Tried (2026-08-28): updating this reference every other ack instead of every ack, to
        // match a ~2x-at-120fps shape observed in a captured official-client session. No effect on
        // stream fps in testing, and it makes this diagnostic value less accurate for its own
        // purpose (a real per-ack interval), so reverted to the direct measurement.
        // What we can actually measure: how long this frame spent between leaving the reassembler
        // and finishing decode. The capture's five marks are a rising series from one frame origin,
        // so a single measured latency repeated across them is the honest reading of it.
        let latencyMilliseconds = Float(timings.hop + timings.decode)
        let ack = NvstFrameAck(
            frameNumber: frameAckNumber,
            // Session-relative, not epoch. Only the delta matters to the pacer, and the remote-input
            // path already showed this seat rejecting an epoch-scale timestamp where it expected a
            // session one; the capture's own value is ~20000, which is session scale.
            clientTimeMilliseconds: Double(clock.elapsedMicroseconds(now: now)) / 1000,
            frameBytes: UInt32(truncatingIfNeeded: unit.bytes.count),
            interFrameMicroseconds: measuredInterFrame,
            stageMilliseconds: [latencyMilliseconds],
            auxiliaryMilliseconds: [latencyMilliseconds, latencyMilliseconds, 0, 0, 0, 0]
        )
        // The pacer's target interval rides on 0x203, roughly every 6-8 frames as the capture does.
        var pacingSent = 0
        var pacingFailed = 0
        framesSincePacingReport += 1
        if frameAckNumber % NvstFramePacingReport.framesPerReport == 1 {
            // A real plaintext capture of the official client (2026-08-28, see
            // `NvstFramePacingReport`'s doc) settled this: the client sends its RAW measured frame
            // time here, unclamped — it can and does exceed the target — and the target itself is
            // the session's real negotiated frame interval, not a fixed value. Both of those were
            // wrong here before: this used to clamp to at most `target` and hardcode a ~75 fps
            // constant regardless of what was negotiated.
            // Tried (2026-09-05): sending the decoded-frame interval here instead of hop+decode, on
            // the reading that the vendor's ~15.9 ms on a 60 fps session is a cadence, not a
            // latency. Cyberpunk benchmark at 3840x2160, cap 150, same seat class: stream 85–107 fps
            // and 31–71 Mbps with either value (84–107 and 31–67 the run before). The seat's
            // frame controller is not steering off this field; the plateau is seat-side.
            let clientMicroseconds = Int((timings.hop + timings.decode) * 1000)
            let pacing = NvstFramePacingReport(
                frameNumber: frameAckNumber,
                targetFrameTimeMicroseconds: frameTimeMicroseconds,
                measuredFrameTimeMicroseconds: UInt32(clamping: clientMicroseconds),
                displayVsyncMicroseconds: displayVsyncMicroseconds,
                groupCount: UInt32(clamping: framesSincePacingReport)
            )
            framesSincePacingReport = 0
            if bundle.sendPartiallyReliableControl(pacing.command) { pacingSent = 1 } else { pacingFailed = 1 }
            logFeedbackSample(interFrame: measuredInterFrame, measuredFrameTimeMicroseconds: clientMicroseconds,
                              clientMicroseconds: clientMicroseconds, hopMs: timings.hop, decodeMs: timings.decode)
        }
        let acked = bundle.sendPartiallyReliableControl(ack.command)
        timings.ack = Self.milliseconds(from: decodedAt, to: DispatchTime.now().uptimeNanoseconds)

        lock.lock()
        counters.pacingReportsSent += pacingSent
        counters.pacingReportFailures += pacingFailed
        if acked { counters.frameAcksSent += 1 } else { counters.frameAckFailures += 1 }
        let firstFailure = !acked && counters.frameAckFailures == 1
        counters.lastDecodeLatencyMilliseconds = Double(latencyMilliseconds)
        lock.unlock()
        if firstFailure { logger?("NVST frame ack write failed") }
    }

    /// Throttled to ~1/s: what we actually sent in 0x204/0x203, next to what it implies about
    /// cadence and where the time went. Correlating this against the periodic `NVST counters`
    /// received-fps series is how a guess about seat pacer behavior gets checked against reality
    /// instead of staying a guess — this is what a vendor capture would otherwise be needed for.
    private func logFeedbackSample(interFrame: UInt32, measuredFrameTimeMicroseconds: Int,
                                   clientMicroseconds: Int, hopMs: Double, decodeMs: Double) {
        // A reported overrun is the rare, interesting case — that is the client sending the seat
        // a measured time past its target, exactly the signal this whole investigation is about —
        // so it always logs immediately. Keeping up only needs a heartbeat.
        let isOverrun = measuredFrameTimeMicroseconds > Int(frameTimeMicroseconds)
        lock.lock()
        let now = Date()
        let shouldLog = isOverrun || lastFeedbackLogAt == nil || now.timeIntervalSince(lastFeedbackLogAt!) >= 1.0
        if shouldLog { lastFeedbackLogAt = now }
        lock.unlock()
        guard shouldLog, let logger else { return }
        let impliedFps = interFrame > 0 ? 1_000_000.0 / Double(interFrame) : 0
        logger(String(format: "NVST feedback%@ ack#=%u interFrameUs=%u impliedFps=%.1f measuredUs=%d"
                       + " clientUs=%d targetUs=%u hop=%.2fms decode=%.2fms",
                       isOverrun ? " OVERRUN" : "", frameAckNumber, interFrame, impliedFps, measuredFrameTimeMicroseconds,
                       clientMicroseconds, frameTimeMicroseconds, hopMs, decodeMs))
    }

    /// One keyframe repairs the whole run of a broken chain, so requests ride the retry cadence
    /// rather than firing per failed frame.
    private func requestKeyframeThrottled() {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let sinceLastRequest = lastKeyframeRequestAt.map { Self.seconds(from: $0, to: now) } ?? .infinity
        let shouldRequest = sinceLastRequest >= Self.keyframeRetryInterval
        if shouldRequest { lastKeyframeRequestAt = now }
        lock.unlock()
        if shouldRequest { onKeyframeNeeded() }
    }

    private func record(_ timings: StageTimings, frameNumber: UInt32, unit: NvstAccessUnit) {
        lock.lock()
        counters.framesHandled &+= 1
        counters.peak.raise(to: timings)
        counters.total.add(timings)
        let isSlow = timings.total >= Self.slowFrameMilliseconds
        if isSlow { counters.slowFrames += 1 }
        let shouldLog = isSlow && loggedSlowFrames < Self.maximumLoggedSlowFrames
        if shouldLog { loggedSlowFrames += 1 }
        lock.unlock()
        guard shouldLog else { return }
        logger?(String(format: "NVST SLOW FRAME #%u total=%.1fms hop=%.1f decode=%.1f ack=%.1f bytes=%d key=%@",
                       frameNumber, timings.total, timings.hop, timings.decode, timings.ack,
                       unit.bytes.count, unit.isKeyframe ? "y" : "n"))
    }

    private static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        end > start ? Double(end - start) / 1_000_000 : 0
    }

    private static func seconds(from start: UInt64, to end: UInt64) -> Double {
        end > start ? Double(end - start) / 1_000_000_000 : 0
    }
}
