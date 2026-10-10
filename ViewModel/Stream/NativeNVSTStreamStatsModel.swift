//  The stream's live telemetry: written once a second by the stats poll, read only by the stats
//  overlay and the HUD's NETWORK panel. `@Observable` so a tick invalidates just those two.

import Foundation
import Observation

@MainActor
@Observable
final class NativeNVSTStreamStatsModel {
    var latestNativeStats: NativeNVSTPerformanceSnapshot?
    var latestRenderDiagnostics: OPNVideoRenderDiagnosticsSnapshot?
    /// True once low inbound bitrate and a short frame rate have persisted together.
    var isNativeBitrateStarved = false
    /// The seat's GPU as the official client names it, resolved once per distinct `gpuType`.
    var nativeRigName = ""
    /// The seat's raw GPU identifier (`5080h / B40`), kept as the HUD row's detail.
    var nativeRigRawName = ""

    /// Forgets what the ended session taught us about itself; the next session starts blank.
    func reset() {
        latestNativeStats = nil
        latestRenderDiagnostics = nil
        isNativeBitrateStarved = false
        nativeRigName = ""
        nativeRigRawName = ""
    }
}
