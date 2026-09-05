//  What the view model concludes from the stream while it runs: decode history for Settings, the
//  periodic render log line, 16:9-title detection and the bitrate-starvation verdict. Split from
//  NativeNVSTHostViewModel+Controls.swift for size.
//

import Foundation

extension NativeNVSTHostViewModel {

    /// Remembers this session's mean decode time for its stream shape, so Settings can say what
    /// frame rate the combination holds on this Mac. Short sessions are skipped inside the store.
    func recordDecodeMeasurementIfLongEnough() {
        guard let stats = latestNativeStats, stats.available, stats.decodeMilliseconds > 0, let connectedAt = nativeConnectedAt else { return }
        let key = OPNStreamPreferences.streamShapeKey(codec: stats.codec, resolution: stats.resolution, colorQuality: resolvedStreamSettings?.colorQuality ?? "")
        OPNStreamPreferences.recordDecodeMeasurement(key: key,
                                                     decodeMilliseconds: stats.decodeMilliseconds,
                                                     negotiatedFps: Int(stats.negotiatedFramesPerSecond),
                                                     sessionSeconds: Date().timeIntervalSince(connectedAt))
    }

    /// One line every ~10 samples: what the renderer did with the frames, so an unattended run
    /// can judge a presentation mode without the HUD.
    func logRenderDiagnosticsIfDue() {
        guard let render = latestRenderDiagnostics else { return }
        renderTraceCounter += 1
        guard renderTraceCounter % 10 == 1 else { return }
        let skipped = render.framesReceived > render.framesDrawn ? render.framesReceived - render.framesDrawn : 0
        OpenNOWLog.info(.stream, String(format: "render mode=%@ tier=%@ received=%llu drawn=%llu skipped=%llu present=%.1fms max=%.1f jitter=%.2f interval=%.1f/%.1f audioJb=%.1fms",
                                        render.presentationMode, render.activeTier, render.framesReceived, render.framesDrawn, skipped,
                                        render.presentLatencyMs, render.presentLatencyMaxMs, render.presentJitterMs, render.frameIntervalMs, render.maxFrameIntervalMs,
                                        latestNativeStats?.audioJitterBufferMilliseconds ?? -1))
    }

    /// Feeds the pillarbox detector's content span to the 16:9 tracker and records its verdict
    /// both ways: a 16:9 title is remembered so the next launch requests the narrower resolution,
    /// and a title that turns out native (after an intro that was not) is forgotten again.
    func updateSixteenNineDetection(_ snapshot: NativeNVSTPerformanceSnapshot) {
        // Once the launch has already requested the 16:9 resolution there are no bars to find:
        // the frame is 16:9 by construction. Judging it would call the title "native" after thirty
        // samples and forget it, and the next launch would be back at 5K rediscovering the bars —
        // which is exactly what happened to Streets of Rage 4 on 2026-09-05.
        guard !resolutionOverriddenForSixteenNine else { return }
        guard let render = latestRenderDiagnostics else { return }
        let parts = snapshot.resolution.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return }
        let change = sixteenNineTracker.observe(contentLeft: render.contentLeft, contentRight: render.contentRight, frameWidth: parts[0], frameHeight: parts[1])
        // One trace line every ~10 samples: what the detector sees, so a verdict that never comes
        // can be told apart from a detector that never measured.
        sixteenNineTraceCounter += 1
        if sixteenNineTraceCounter % 10 == 1 {
            OpenNOWLog.info(.stream, String(format: "16:9 tracker content=[%.3f, %.3f] frame=%@ bars=%d/%d verdict=%@", render.contentLeft, render.contentRight, snapshot.resolution, sixteenNineTracker.barSamples, sixteenNineTracker.totalSamples, sixteenNineTracker.verdict.map { $0 ? "16:9" : "native" } ?? "-"))
        }
        guard let change else { return }
        sixteenNineTitleDetected = change
        // A 16:9 verdict is remembered the moment it is reached, so a session that ends abruptly
        // still learns. A native verdict is only *shown* here and persisted at session end from the
        // whole tally: launchers and Steam screens are full-frame, so thirty early samples said
        // "native" and cleared Streets of Rage 4 before the game had appeared (2026-09-05).
        if change {
            OPNStreamPreferences.rememberTitleStreamsSixteenNineContent(configuration.applicationID, true)
        }
        OpenNOWLog.info(.stream, "16:9 title verdict \(change ? "16:9" : "native") in a \(snapshot.resolution) frame (bars \(sixteenNineTracker.barSamples)/\(sixteenNineTracker.totalSamples))\(change ? "; remembered" : "; persisted at session end") for \(configuration.applicationID)")
        WebRTCMediaTelemetry.capture("nvst.video.sixteen_nine_title", level: .info, message: "16:9 title verdict.", attributes: ["applicationID": configuration.applicationID, "resolution": snapshot.resolution, "verdict": change ? "16:9" : "native"])
    }

    /// At session end: a whole-session native majority forgets a remembered 16:9 title. Sixty
    /// samples at least, so a short session that never left the launcher decides nothing.
    func persistSixteenNineVerdictAtSessionEnd() {
        guard !resolutionOverriddenForSixteenNine, sixteenNineTracker.totalSamples >= 60, sixteenNineTracker.verdict == false else { return }
        OPNStreamPreferences.rememberTitleStreamsSixteenNineContent(configuration.applicationID, false)
        OpenNOWLog.info(.stream, "16:9 title verdict native over the session (bars \(sixteenNineTracker.barSamples)/\(sixteenNineTracker.totalSamples)); forgotten for \(configuration.applicationID)")
    }

    func updateBitrateStarvation(_ snapshot: NativeNVSTPerformanceSnapshot, now: Date = Date()) {
        let starved = bitrateStarvation.update(snapshot, now: now)
        if starved != nativeBitrateStarved { nativeBitrateStarved = starved }
    }
}
