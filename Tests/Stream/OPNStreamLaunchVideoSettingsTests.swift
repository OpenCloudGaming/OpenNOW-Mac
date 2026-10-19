import Foundation
import Testing
@testable import OpenNOW

/// Each renderer setting comes from its own profile field. The upscaling target is the resolved
/// height, not the option index that sits next to it in the profile — wiring the index is the
/// mistake this pins, and it would cap the drawable at "2K" while the HUD read "5K".
@Test func launchVideoSettingsTakeEachValueFromItsOwnProfileField() {
    var profile = OPNStreamPreferenceProfile()
    profile.upscalingMode = 3
    profile.upscalingSharpness = 14
    profile.upscalingDenoise = 2
    profile.upscalingTargetIndex = 2
    profile.upscalingTargetHeight = 2880
    profile.pillarboxFillModeIndex = OPNPillarboxFillMode.blurredMirror.rawValue
    profile.pillarboxFillDim = 40
    profile.presentationMode = OPNVideoPresentationMode.vrr.rawValue

    let settings = OPNStreamLaunchVideoSettings(profile: profile)

    #expect(settings.upscalingMode == 3)
    #expect(settings.upscalingSharpness == 14)
    #expect(settings.upscalingDenoise == 2)
    #expect(settings.upscalingTargetHeight == 2880)
    #expect(settings.pillarboxFillModeIndex == OPNPillarboxFillMode.blurredMirror.rawValue)
    #expect(settings.pillarboxFillDim == 40)
    #expect(settings.presentationMode == OPNVideoPresentationMode.vrr.rawValue)
}
