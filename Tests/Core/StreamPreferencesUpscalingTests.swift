import Foundation
import Testing
@testable import OpenNOW

@Suite(.serialized) struct StreamPreferencesUpscalingTests {
    private let preferenceDomain = "io.github.opencloudgaming.opennow"
    private let upscalingModeIndexKey = "OpenNOW.Stream.UpscalingModeIndex"
    private let upscalingSharpnessKey = "OpenNOW.Stream.UpscalingSharpness"
    private let upscalingDenoiseKey = "OpenNOW.Stream.UpscalingDenoise"
    private let gameProfilesKey = "OpenNOW.Stream.GameProfiles"

    @Test func exposesOnlyOffAndMetalFXUpscalingModes() {
        #expect(OPNStreamPreferences.upscalingModeOptions.map(\.label) == ["Off", "MetalFX"])
        #expect(OPNStreamPreferences.upscalingModeOptions.map(\.value) == [0, 3])
    }

    @Test func defaultsSixteenTenResolutionToNineteenTwentyByTwelveHundred() {
        withPreservedPreferences(["OpenNOW.Stream.AspectIndex", "OpenNOW.Stream.ResolutionIndex"]) {
            removePreferenceValue("OpenNOW.Stream.AspectIndex")
            removePreferenceValue("OpenNOW.Stream.ResolutionIndex")

            let profile = OPNStreamPreferences.loadProfile()

            #expect(OPNStreamPreferences.defaultResolutionIndex(forAspect: 1) == 3)
            #expect(profile.aspectIndex == 1)
            #expect(profile.resolutionIndex == 3)
            #expect(profile.resolution.width == 1920)
            #expect(profile.resolution.height == 1200)
        }
    }

    @Test func defaultsUpscalingOffWithClarityTen() {
        withPreservedPreferences([upscalingModeIndexKey, upscalingSharpnessKey]) {
            removePreferenceValue(upscalingModeIndexKey)
            removePreferenceValue(upscalingSharpnessKey)

            let profile = OPNStreamPreferences.loadProfile()

            #expect(profile.upscalingModeIndex == 0)
            #expect(profile.upscalingMode == 0)
            #expect(profile.upscalingModeOption.label == "Off")
            #expect(profile.upscalingSharpness == 10)
        }
    }

    @Test func mapsLegacyUpscalingIndicesToMetalFX() {
        withPreservedPreferences([upscalingModeIndexKey]) {
            for legacyIndex in 1...4 {
                OPNAppPreferenceStorage.standard.set(legacyIndex, forKey: upscalingModeIndexKey)

                let profile = OPNStreamPreferences.loadProfile()

                #expect(profile.upscalingModeIndex == 1)
                #expect(profile.upscalingMode == 3)
                #expect(profile.upscalingModeOption.label == "MetalFX")
            }
        }
    }

    @Test func mapsUnknownUpscalingIndicesToOff() {
        withPreservedPreferences([upscalingModeIndexKey]) {
            for invalidIndex in [-1, 5, 99] {
                OPNAppPreferenceStorage.standard.set(invalidIndex, forKey: upscalingModeIndexKey)

                let profile = OPNStreamPreferences.loadProfile()

                #expect(profile.upscalingModeIndex == 0)
                #expect(profile.upscalingMode == 0)
                #expect(profile.upscalingModeOption.label == "Off")
            }
        }
    }

    @Test func persistsRuntimeUpscalingSettingsToGlobalProfile() {
        withPreservedPreferences([upscalingModeIndexKey, upscalingSharpnessKey, upscalingDenoiseKey]) {
            removePreferenceValue(upscalingModeIndexKey)
            removePreferenceValue(upscalingSharpnessKey)
            removePreferenceValue(upscalingDenoiseKey)

            OPNStreamPreferences.saveUpscalingSettings(mode: 3, sharpness: 18, denoise: -2)

            let profile = OPNStreamPreferences.loadProfile()
            #expect(profile.upscalingModeIndex == 1)
            #expect(profile.upscalingMode == 3)
            #expect(profile.upscalingModeOption.label == "MetalFX")
            #expect(profile.upscalingSharpness == 15)
            #expect(profile.upscalingDenoise == 0)
        }
    }

    @Test func persistsRuntimeUpscalingSettingsToEnabledGameProfile() {
        withPreservedPreferences([upscalingModeIndexKey, upscalingSharpnessKey, upscalingDenoiseKey, gameProfilesKey]) {
            let appId = "12345"
            removePreferenceValue(upscalingModeIndexKey)
            removePreferenceValue(upscalingSharpnessKey)
            removePreferenceValue(upscalingDenoiseKey)
            removePreferenceValue(gameProfilesKey)
            var profile = OPNStreamPreferences.loadProfile()
            profile.upscalingModeIndex = 0
            profile.upscalingModeOption = OPNStreamPreferences.upscalingModeOptions[0]
            profile.upscalingMode = 0
            profile.upscalingSharpness = 4
            profile.upscalingDenoise = 5
            OPNStreamPreferences.saveProfile(forGame: appId, profile: profile)

            OPNStreamPreferences.saveUpscalingSettings(mode: 3, sharpness: 12, denoise: 7, forGame: appId)

            guard let gameProfile = OPNStreamPreferences.loadProfile(forGame: appId) else {
                Issue.record("Expected enabled game profile")
                return
            }
            let globalProfile = OPNStreamPreferences.loadProfile()
            #expect(gameProfile.upscalingModeIndex == 1)
            #expect(gameProfile.upscalingMode == 3)
            #expect(gameProfile.upscalingSharpness == 12)
            #expect(gameProfile.upscalingDenoise == 7)
            #expect(globalProfile.upscalingModeIndex == 0)
            #expect(globalProfile.upscalingSharpness == 10)
            #expect(globalProfile.upscalingDenoise == 0)
        }
    }

    private func withPreservedPreferences(_ keys: [String], _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let previousValues = keys.map { ($0, defaults.object(forKey: $0)) }
        let previousDomain = defaults.persistentDomain(forName: preferenceDomain)
        defer {
            for (key, value) in previousValues {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
            if let previousDomain {
                defaults.setPersistentDomain(previousDomain, forName: preferenceDomain)
            } else {
                defaults.removePersistentDomain(forName: preferenceDomain)
            }
            defaults.synchronize()
        }
        body()
    }

    private func removePreferenceValue(_ key: String) {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: key)
        var domain = defaults.persistentDomain(forName: preferenceDomain) ?? [:]
        domain.removeValue(forKey: key)
        defaults.setPersistentDomain(domain, forName: preferenceDomain)
        defaults.synchronize()
    }
}
