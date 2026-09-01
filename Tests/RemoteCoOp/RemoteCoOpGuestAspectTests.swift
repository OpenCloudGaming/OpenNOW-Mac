//
//  RemoteCoOpGuestAspectTests.swift
//  OpenNOWTests
//
//  A preset is a ceiling on size, never a reshape.
//
//  `adaptOutputFormat` is not a bounding box: libwebrtc's VideoAdapter reads its dimensions as a
//  target aspect ratio and crops the frame to it before scaling. Handing it a preset's literal
//  dimensions therefore discards picture whenever the seat's shape differs from the preset's -
//  measured on hardware as a 2560x1080 ultrawide seat reaching a guest as 1920x1080, a quarter of the
//  width cut off rather than scaled.
//

import Foundation
import Testing
@testable import OpenNOW

@Suite struct RemoteCoOpGuestAspectTests {
    private func fitted(_ width: Int, _ height: Int, into preset: OPNRemoteCoOpQualityPreset) -> (width: Int, height: Int) {
        OPNRemoteCoOpHostVideoRelay.adaptedSize(
            sourceWidth: width,
            sourceHeight: height,
            maximumWidth: preset.width,
            maximumHeight: preset.height
        )
    }

    private func aspect(_ size: (width: Int, height: Int)) -> Double {
        Double(size.width) / Double(size.height)
    }

    /// The measured regression: a 21:9 seat inside a 16:9 preset. The box requested must stay 21:9,
    /// or the adapter crops to 16:9 and the guest loses the sides of the picture.
    @Test func anUltrawideSeatKeepsItsShapeInsideAWiderPreset() throws {
        let box = fitted(2560, 1080, into: .p2160f60)
        #expect(box == (width: 2560, height: 1080))
        #expect(abs(aspect(box) - 2560.0 / 1080.0) < 0.001)
        // 1920x1080 is what a 16:9 crop of this source produces, and is exactly what was observed.
        #expect(box.width != 1920)
    }

    /// The 5K case, where the preset genuinely does bind: it must scale, and only scale.
    @Test func aFiveKSeatScalesWithoutBeingReshaped() throws {
        let box = fitted(5120, 2160, into: .p2160f60)
        #expect(box == (width: 3840, height: 1620))
        #expect(abs(aspect(box) - 5120.0 / 2160.0) < 0.001)
        // 2880x1620 is the 16:9 crop of the correctly scaled frame - the other observed value.
        #expect(box.width != 2880)
    }

    /// The invariant behind both: whatever the preset, the requested box keeps the source's aspect
    /// ratio, so the adapter has nothing to crop.
    @Test func everyPresetPreservesTheSourceAspectRatio() throws {
        let sources = [(2560, 1080), (5120, 2160), (3840, 2160), (1920, 1080), (2560, 1440), (1280, 800)]
        for preset in OPNRemoteCoOpQualityPreset.allCases {
            for (width, height) in sources {
                let box = fitted(width, height, into: preset)
                let sourceAspect = Double(width) / Double(height)
                // Rounding to even dimensions moves the ratio slightly; a crop would move it a lot.
                #expect(abs(aspect(box) - sourceAspect) < 0.01,
                        "\(width)x\(height) into \(preset.label) became \(box.width)x\(box.height)")
            }
        }
    }

    /// A preset larger than the seat must not upscale: sending more pixels than exist spends the
    /// guest's bandwidth on nothing.
    @Test func aPresetLargerThanTheSeatNeverUpscales() throws {
        #expect(fitted(1280, 720, into: .p2160f60) == (width: 1280, height: 720))
        #expect(fitted(2560, 1080, into: .p1440f60) == (width: 2560, height: 1080))
    }

    /// A smaller preset still binds on the dimension that actually constrains it.
    @Test func aSmallerPresetBindsOnTheTighterDimension() throws {
        // 21:9 into a 720p box: width binds, height comes out well under the preset's 720.
        let box = fitted(2560, 1080, into: .p720f60)
        #expect(box.width == 1280)
        #expect(box.height == 540)
        #expect(box.height < OPNRemoteCoOpQualityPreset.p720f60.height)
    }

    /// I420 subsamples chroma by two, so an odd dimension is not representable.
    @Test func everyDimensionStaysEven() throws {
        for preset in OPNRemoteCoOpQualityPreset.allCases {
            let box = fitted(1999, 1113, into: preset)
            #expect(box.width.isMultiple(of: 2))
            #expect(box.height.isMultiple(of: 2))
        }
    }
}
