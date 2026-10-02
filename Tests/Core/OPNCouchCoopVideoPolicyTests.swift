import Foundation
import Testing
@testable import OpenNOW

@Suite struct OPNCouchCoopVideoPolicyTests {
    private func tile(_ layout: OPNCouchCoopLayout, area: CGRect, scale: Double = 2, instance: Int = 1) -> OPNCouchCoopTile {
        OPNCouchCoopTile.make(layout: layout, instance: instance, area: area, backingScale: scale)
    }

    private var storedProfile: OPNStreamPreferenceProfile {
        var profile = OPNStreamPreferenceProfile()
        profile.aspectIndex = 0
        profile.aspect = OPNStreamPreferences.aspectOptions[0]
        profile.resolutionIndex = 2
        profile.resolution = OPNStreamPreferences.resolutionOptions(forAspect: 0)[2]
        return profile
    }

    @Test func noTileLeavesTheProfileAlone() {
        #expect(OPNCouchCoopVideoPolicy.apply(to: storedProfile, tile: nil) == storedProfile)
    }

    @Test func sideBySideAndManualLeaveTheProfileAlone() {
        let area = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        #expect(OPNCouchCoopVideoPolicy.apply(to: storedProfile, tile: tile(.sideBySide, area: area)) == storedProfile)
        #expect(OPNCouchCoopVideoPolicy.apply(to: storedProfile, tile: tile(.manual, area: area)) == storedProfile)
    }

    @Test func topAndBottomPicksTheLargestFittingThirtyTwoByNinePreset() {
        let wide = OPNCouchCoopVideoPolicy.apply(to: storedProfile, tile: tile(.topAndBottom, area: CGRect(x: 0, y: 0, width: 2560, height: 1440)))
        #expect(wide.aspect.label == "32:9")
        #expect(wide.aspectIndex == 3)
        #expect(wide.resolution == OPNStreamResolutionOption(width: 5120, height: 1440))
        #expect(wide.resolutionIndex == 1)

        let hd = OPNCouchCoopVideoPolicy.apply(to: storedProfile, tile: tile(.topAndBottom, area: CGRect(x: 0, y: 0, width: 1920, height: 1080)))
        #expect(hd.resolution == OPNStreamResolutionOption(width: 3840, height: 1080))
        #expect(hd.resolutionIndex == 0)
    }

    @Test func aTileSmallerThanEveryPresetFallsBackToTheSmallest() {
        let small = OPNCouchCoopVideoPolicy.apply(to: storedProfile, tile: tile(.topAndBottom, area: CGRect(x: 0, y: 0, width: 1728, height: 1117)))
        #expect(small.resolution == OPNStreamResolutionOption(width: 3840, height: 1080))
        #expect(small.aspectRatio == 32.0 / 9.0)
    }

    @Test func theFillOnlyTouchesResolutionAndAspect() {
        var profile = storedProfile
        profile.fps = 120
        let filled = OPNCouchCoopVideoPolicy.apply(to: profile, tile: tile(.topAndBottom, area: CGRect(x: 0, y: 0, width: 1920, height: 1080)))
        #expect(filled.fps == 120)
        #expect(filled.codec == profile.codec)
        #expect(filled.bitrate == profile.bitrate)
    }

    @Test func noEightByNineResolutionExists() {
        #expect(!OPNStreamPreferences.aspectOptions.contains { $0.widthRatio == 8 && $0.heightRatio == 9 })
    }

    @Test func launchProfileAppliesTheLockedTileAndIgnoresItWhenAbsent() {
        let capabilities = OPNStreamDeviceCapabilities()
        let baseline = OPNStreamPreferences.launchProfile(forGame: "policy-test", capabilities: capabilities)
        let tiled = OPNStreamPreferences.launchProfile(
            forGame: "policy-test",
            capabilities: capabilities,
            coopTile: tile(.topAndBottom, area: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        )
        #expect(tiled.aspect.label == "32:9")
        #expect(OPNStreamPreferences.launchProfile(forGame: "policy-test", capabilities: capabilities) == baseline)
    }
}
