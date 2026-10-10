//  The stream's live telemetry, split out of `NativeNVSTHostViewModel`.
//
//  These readings are written once a second by the stats poll and read by exactly two views: the
//  floating stats overlay and the unified HUD's NETWORK panel. Held as `@Published` on the host
//  model they were not local to those two: every assignment fired the host's `objectWillChange`,
//  which re-evaluated the whole stream surface - and the 563-line stats overlay with it - once a
//  second, whether or not a reading had changed.
//
//  The codebase already made this move once, for the same reason: `OPNApp.swift:10-14` splits
//  `OPNMenuBarStatusItemModel` out of the stream-cadence session model because observing it there
//  re-evaluated the whole scene graph once a second. This is that pattern applied to the stream.
//
//  A value in here is read through `Observation`, so only the body that reads it is invalidated.
//  Nothing here is written at any other cadence, and nothing here is read outside the two panels
//  above plus the poll's own bookkeeping (`NativeNVSTHostViewModel+Observations.swift`).
//

import Foundation
import Observation

/// The seat's one-second sample, the renderer's view of the same second, and the two verdicts drawn
/// from them.
@MainActor
@Observable
final class NativeNVSTStreamStatsModel {
    /// The seat's last `performanceSnapshot()`.
    var latestNativeStats: NativeNVSTPerformanceSnapshot?
    /// The renderer's view of the same second: surface format, drawable format, EDR, drawn/received.
    var latestRenderDiagnostics: OPNVideoRenderDiagnosticsSnapshot?
    /// True once the inbound bitrate has been low AND the stream frame rate has been falling short
    /// of the negotiated rate for a sustained period. See `NativeNVSTBitrateStarvationTracker`.
    var nativeBitrateStarved = false
    /// The seat's GPU as the official client names it, resolved once per distinct `gpuType`.
    var nativeRigName = ""
    /// The seat's raw GPU identifier (`5080h / B40`), kept as the HUD row's detail.
    var nativeRigRawName = ""

    /// Forgets what the ended session taught us about itself; the next session starts blank.
    func reset() {
        latestNativeStats = nil
        latestRenderDiagnostics = nil
        nativeBitrateStarved = false
        nativeRigName = ""
        nativeRigRawName = ""
    }
}
