import Foundation
import Testing
@testable import OpenNOW

/// The drawable-pool policy behind the beta for the A18 Pro Neo's fullscreen Direct/30: the two
/// refresh-driven modes keep a third drawable so the display-link loop is not waiting on a surface
/// the previous frame still holds, while the decode-driven `lowestLatency` keeps its two.
@Suite struct OPNVideoDrawablePolicyTests {
    @Test func refreshDrivenModesKeepThreeDrawables() {
        #expect(OPNVideoPresentationMode.balanced.drawableCount == 3)
        #expect(OPNVideoPresentationMode.smooth.drawableCount == 3)
    }

    @Test func lowestLatencyKeepsTwoDrawables() {
        #expect(OPNVideoPresentationMode.lowestLatency.drawableCount == 2)
    }

    @Test func vrrKeepsItsExistingThreeDrawables() {
        #expect(OPNVideoPresentationMode.vrr.drawableCount == 3)
    }

    @Test func everyPacingModeKeepsADoubleBufferedPoolAtLeast() {
        for mode in [OPNVideoPresentationMode.balanced, .smooth, .lowestLatency, .vrr] {
            #expect(mode.drawableCount >= 2)
        }
    }

    /// Construction is the only thing that configures the default pacing mode: the launch path
    /// re-selects `balanced` on a view that already is `balanced`, and `setPresentationMode` returns
    /// early for an unchanged mode. Both paths have to land on the policy's count.
    @Test(.disabled(if: CIWindowTestGate.isHostedRunner, Comment(rawValue: CIWindowTestGate.skipReason)))
    @MainActor func constructionAndAnUnchangedReselectionBothApplyThePolicy() throws {
        let view = OPNMetalVideoView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720), targetFps: 60)
        let layer = try #require(view.metalLayer)
        #expect(layer.maximumDrawableCount == OPNVideoPresentationMode.balanced.drawableCount)
        view.setPresentationMode(.balanced)
        #expect(layer.maximumDrawableCount == OPNVideoPresentationMode.balanced.drawableCount)
    }

    @Test(.disabled(if: CIWindowTestGate.isHostedRunner, Comment(rawValue: CIWindowTestGate.skipReason)))
    @MainActor func everyModeTransitionRestoresItsOwnPoolSize() throws {
        let view = OPNMetalVideoView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720), targetFps: 60)
        let layer = try #require(view.metalLayer)
        for mode in [OPNVideoPresentationMode.lowestLatency, .smooth, .balanced, .vrr, .balanced] {
            view.setPresentationMode(mode)
            #expect(layer.maximumDrawableCount == mode.drawableCount)
        }
    }
}
