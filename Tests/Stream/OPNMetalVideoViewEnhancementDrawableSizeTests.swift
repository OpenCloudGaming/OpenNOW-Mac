import Foundation
import Testing
@testable import OpenNOW

@Suite struct OPNMetalVideoViewEnhancementDrawableSizeTests {
    @Test func windowSmallerThanTargetIsUnaffected() {
        let size = OPNMetalVideoView.enhancementDrawableSize(
            boundsSize: CGSize(width: 960, height: 540),
            scale: 2,
            targetHeight: 2880
        )
        #expect(size.width == 1920)
        #expect(size.height == 1080)
    }

    @Test func windowLargerThanTargetIsCappedPreservingAspect() {
        let size = OPNMetalVideoView.enhancementDrawableSize(
            boundsSize: CGSize(width: 2000, height: 1000),
            scale: 1,
            targetHeight: 500
        )
        #expect(size.width == 1000)
        #expect(size.height == 500)
    }

    @Test func capAppliesAfterBackingScale() {
        let size = OPNMetalVideoView.enhancementDrawableSize(
            boundsSize: CGSize(width: 1000, height: 500),
            scale: 3,
            targetHeight: 1000
        )
        #expect(size.width == 2000)
        #expect(size.height == 1000)
    }

    @Test func nonPositiveTargetHeightClampsToOnePixel() {
        let size = OPNMetalVideoView.enhancementDrawableSize(
            boundsSize: CGSize(width: 1000, height: 500),
            scale: 1,
            targetHeight: 0
        )
        #expect(size.height == 1)
        #expect(size.width == 2)
    }
}
