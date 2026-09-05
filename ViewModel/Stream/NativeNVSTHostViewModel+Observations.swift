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

    func updateBitrateStarvation(_ snapshot: NativeNVSTPerformanceSnapshot, now: Date = Date()) {
        let starved = bitrateStarvation.update(snapshot, now: now)
        if starved != nativeBitrateStarved { nativeBitrateStarved = starved }
    }
}
