//  What the view model concludes from the stream while it runs: decode history for Settings, the
//  periodic render log line, 16:9-title detection and the bitrate-starvation verdict.
//

import Foundation

extension NativeNVSTHostViewModel {

    /// Remembers this session's mean decode time for its stream shape, so Settings can say what
    /// frame rate the combination holds on this Mac. Short sessions are skipped inside the store.
    func recordDecodeMeasurementWhenLongEnough() {
        guard let snapshot = stats.latestNativeStats, snapshot.available, snapshot.decodeMilliseconds > 0, let connectedAt = nativeConnectedAt else { return }
        let key = OPNStreamPreferences.streamShapeKey(codec: snapshot.codec, resolution: snapshot.resolution, colorQuality: resolvedStreamSettings?.colorQuality ?? "")
        OPNStreamPreferences.recordDecodeMeasurement(key: key,
                                                     decodeMilliseconds: snapshot.decodeMilliseconds,
                                                     negotiatedFps: Int(snapshot.negotiatedFramesPerSecond),
                                                     sessionSeconds: Date().timeIntervalSince(connectedAt))
    }

    /// One line every ~10 samples: what the renderer did with the frames, so an unattended run
    /// can judge a presentation mode without the HUD. It leads with the presentation policy in
    /// effect — pacing mode, drawable pool, requested frame rate, source and drawable pixel format,
    /// drawable size — so a beta report can be read without a second source for the pool size.
    func logRenderDiagnosticsWhenDue() {
        guard let render = stats.latestRenderDiagnostics else { return }
        renderTraceCounter += 1
        guard renderTraceCounter % 10 == 1 else { return }
        let skipped = render.framesReceived > render.framesDrawn ? render.framesReceived - render.framesDrawn : 0
        OPNLog.info(.stream, String(format: "render mode=%@ drawables=%d fps=%d srcFmt=%@ drawable=%@ drawableSize=%@ tier=%@ received=%llu drawn=%llu skipped=%llu present=%.1fms max=%.1f jitter=%.2f interval=%.1f/%.1f audioJb=%.1fms",
                                        render.presentationMode, render.drawableCount, render.requestedFps,
                                        render.pixelFormat, render.outputFormat, render.drawableResolution,
                                        render.activeTier, render.framesReceived, render.framesDrawn, skipped,
                                        render.presentLatencyMs, render.presentLatencyMaxMs, render.presentJitterMs, render.frameIntervalMs, render.maxFrameIntervalMs,
                                        stats.latestNativeStats?.audioJitterBufferMilliseconds ?? -1))
    }

    func updateBitrateStarvation(_ snapshot: NativeNVSTPerformanceSnapshot, now: Date = Date()) {
        let starved = bitrateStarvation.update(snapshot, now: now)
        if starved != stats.isNativeBitrateStarved { stats.isNativeBitrateStarved = starved }
    }

    /// Names the verdict that no other reading can express: the video socket received no datagram at
    /// all, so every other plane reporting healthy is expected rather than contradictory.
    func reportVideoThatNeverArrived(_ failure: NativeNVSTStreamHealthFailure) {
        guard failure == .firstFrameTimedOut else { return }
        let snapshot = stats.latestNativeStats
        OPNLog.warning(.stream, "NVST video received no frames: no video datagram reached this Mac (inboundVideoDatagrams=\(snapshot?.inboundVideoDatagrams ?? 0), resolution=\(snapshot?.resolution ?? "-"), codec=\(snapshot?.codec ?? "-")). Audio and control use a separate socket and may still be alive. Check OpenNOW's incoming-connection firewall permission, any VPN or split-tunnel route, and whether another process holds the video UDP port.")
    }
}
