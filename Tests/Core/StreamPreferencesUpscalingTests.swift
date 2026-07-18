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
        withPreservedPreferences(["OpenNOW.Stream.AspectIndex", "OpenNOW.Stream.ResolutionIndex", "OpenNOW.Stream.StreamingQualityProfileIndex"]) {
            removePreferenceValue("OpenNOW.Stream.AspectIndex")
            removePreferenceValue("OpenNOW.Stream.ResolutionIndex")
            removePreferenceValue("OpenNOW.Stream.StreamingQualityProfileIndex")

            let profile = OPNStreamPreferences.loadProfile()

            #expect(OPNStreamPreferences.defaultResolutionIndex(forAspect: 1) == 3)
            #expect(profile.aspectIndex == 1)
            #expect(profile.resolutionIndex == 3)
            #expect(profile.resolution.width == 1920)
            #expect(profile.resolution.height == 1200)
        }
    }

    @Test func launchProfileKeepsSelectedResolutionWhenStaleGameProfileExists() {
        withPreservedPreferences(["OpenNOW.Stream.AspectIndex", "OpenNOW.Stream.ResolutionIndex", gameProfilesKey]) {
            removePreferenceValue("OpenNOW.Stream.AspectIndex")
            removePreferenceValue("OpenNOW.Stream.ResolutionIndex")
            removePreferenceValue(gameProfilesKey)
            OPNStreamPreferences.saveAspectIndex(1)
            OPNStreamPreferences.saveResolutionIndex(5)

            let appId = "stale-resolution-game"
            var gameProfile = OPNStreamPreferences.loadProfile()
            gameProfile.resolutionIndex = 0
            gameProfile.resolution = OPNStreamPreferences.resolutionOptions(forAspect: 1)[0]
            gameProfile.upscalingModeIndex = 1
            gameProfile.upscalingMode = 3
            gameProfile.upscalingModeOption = OPNStreamPreferences.upscalingModeOptions[1]
            gameProfile.upscalingSharpness = 14
            OPNStreamPreferences.saveProfile(forGame: appId, profile: gameProfile)

            let launchProfile = OPNStreamPreferences.launchProfile(forGame: appId, capabilities: OPNStreamDeviceCapabilities())

            #expect(launchProfile.resolution.width == 2880)
            #expect(launchProfile.resolution.height == 1800)
            #expect(launchProfile.upscalingMode == 3)
            #expect(launchProfile.upscalingSharpness == 14)
        }
    }

    @Test func qualityProfilesApplyAndLockPresetStreamingValues() {
        withPreservedPreferences(streamingProfileKeys) {
            OPNStreamPreferences.restoreStreamingProfileDefaults()

            OPNStreamPreferences.saveStreamingQualityProfileIndex(3)

            var profile = OPNStreamPreferences.loadProfile()
            #expect(profile.streamingQualityProfileIndex == 3)
            #expect(profile.streamingQualityProfileOption.label == "Data Saver")
            #expect(!profile.allowsStreamingCustomization)
            #expect(profile.aspectIndex == 1)
            #expect(profile.resolution.width == 1280)
            #expect(profile.resolution.height == 800)
            #expect(profile.fps == 30)
            #expect(profile.maxBitrateMbps == 15)
            #expect(profile.enablePowerSaver)

            OPNStreamPreferences.saveResolutionIndex(5)
            OPNStreamPreferences.saveFpsIndex(2)
            profile = OPNStreamPreferences.loadProfile()
            #expect(profile.resolution.width == 1280)
            #expect(profile.resolution.height == 800)
            #expect(profile.fps == 30)

            OPNStreamPreferences.saveStreamingQualityProfileIndex(0)
            profile = OPNStreamPreferences.loadProfile()
            #expect(profile.streamingQualityProfileIndex == 0)
            #expect(profile.allowsStreamingCustomization)
        }
    }

    @Test func streamTransportSelectionSurvivesQualityProfileChanges() {
        withPreservedPreferences(streamingProfileKeys) {
            OPNStreamPreferences.restoreStreamingProfileDefaults()

            OPNStreamPreferences.saveTransportModeIndex(1)
            OPNStreamPreferences.saveStreamingQualityProfileIndex(3)

            var profile = OPNStreamPreferences.loadProfile()
            #expect(profile.streamingQualityProfileIndex == 3)
            #expect(profile.transportMode.value == "nvst")
            #expect(profile.transportMode.label == "Native/NVST")

            OPNStreamPreferences.saveStreamingQualityProfileIndex(4)
            profile = OPNStreamPreferences.loadProfile()
            #expect(profile.streamingQualityProfileIndex == 4)
            #expect(profile.transportMode.value == "nvst")
        }
    }

    @Test func cinematicQualityProfileAppliesHighQualityPreset() {
        withPreservedPreferences(streamingProfileKeys) {
            OPNStreamPreferences.restoreStreamingProfileDefaults()

            OPNStreamPreferences.saveStreamingQualityProfileIndex(4)

            let profile = OPNStreamPreferences.loadProfile()
            #expect(profile.streamingQualityProfileIndex == 4)
            #expect(profile.streamingQualityProfileOption.label == "Cinematic")
            #expect(profile.resolution.width == 2880)
            #expect(profile.resolution.height == 1800)
            #expect(profile.fps == 60)
            #expect(profile.codec.value == "auto")
            #expect(profile.maxBitrateMbps == 75)
            #expect(profile.colorQuality.value == "10bit_420")
            #expect(profile.enableHdr)
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

    private var streamingProfileKeys: [String] {
        [
            "OpenNOW.Stream.AspectIndex",
            "OpenNOW.Stream.ResolutionIndex",
            "OpenNOW.Stream.FpsIndex",
            "OpenNOW.Stream.CodecIndex",
            "OpenNOW.Stream.BitrateIndex",
            "OpenNOW.Stream.ColorQualityIndex",
            "OpenNOW.Stream.TransportModeIndex",
            "OpenNOW.Stream.StreamingQualityProfileIndex",
            "OpenNOW.Stream.CloudGsyncEnabled",
            "OpenNOW.Stream.FallbackToLogicalResolution",
            "OpenNOW.Stream.HudStreamingModeIndex",
            "OpenNOW.Stream.SDRColorSpaceIndex",
            "OpenNOW.Stream.HDRColorSpaceIndex",
            "OpenNOW.Stream.L4SEnabled",
            "OpenNOW.Stream.HDREnabled",
            "OpenNOW.Stream.PowerSaverEnabled",
        ]
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
