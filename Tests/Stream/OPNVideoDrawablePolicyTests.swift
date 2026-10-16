import Foundation
import Testing
@testable import OpenNOW

/// The drawable-pool policy behind the beta for the A18 Pro Neo's fullscreen Direct/30.
@Suite struct OPNVideoDrawablePolicyTests {
    @Test func balancedPacingKeepsThreeDrawables() {
        #expect(OPNVideoPresentationMode.balanced.drawableCount == 3)
    }

    @Test func smoothPacingKeepsThreeDrawables() {
        #expect(OPNVideoPresentationMode.smooth.drawableCount == 3)
    }

    @Test func lowestLatencyPacingKeepsTwoDrawables() {
        #expect(OPNVideoPresentationMode.lowestLatency.drawableCount == 2)
    }

    @Test func vrrPacingKeepsThreeDrawables() {
        #expect(OPNVideoPresentationMode.vrr.drawableCount == 3)
    }

    @Test(.disabled(if: CIWindowTestGate.isHostedRunner, Comment(rawValue: CIWindowTestGate.skipReason)))
    @MainActor func aFreshViewStartsWithThePoolItsDefaultPacingModeAsksFor() throws {
        let view = OPNMetalVideoView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720), targetFps: 60)
        let layer = try #require(view.metalLayer)
        #expect(layer.maximumDrawableCount == OPNVideoPresentationMode.balanced.drawableCount)
    }

    @Test(.disabled(if: CIWindowTestGate.isHostedRunner, Comment(rawValue: CIWindowTestGate.skipReason)))
    @MainActor func reselectingTheActivePacingModeStillAppliesItsPool() throws {
        let view = OPNMetalVideoView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720), targetFps: 60)
        let layer = try #require(view.metalLayer)
        layer.maximumDrawableCount = OPNVideoPresentationMode.lowestLatency.drawableCount
        view.setPresentationMode(.balanced)
        #expect(layer.maximumDrawableCount == OPNVideoPresentationMode.balanced.drawableCount)
    }

    @Test(.disabled(if: CIWindowTestGate.isHostedRunner, Comment(rawValue: CIWindowTestGate.skipReason)))
    @MainActor func eachPacingModeTransitionAppliesItsOwnPool() throws {
        let view = OPNMetalVideoView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720), targetFps: 60)
        let layer = try #require(view.metalLayer)
        for mode in [OPNVideoPresentationMode.lowestLatency, .smooth, .balanced, .vrr, .balanced] {
            view.setPresentationMode(mode)
            #expect(layer.maximumDrawableCount == mode.drawableCount)
        }
    }
}
