import Foundation
import Testing
@testable import OpenNOW

@Suite("Stream settings")
struct StreamSettingsTests {
    @Test("resolves CloudMatch controller settings without virtual HID advertisement")
    func resolvesCloudMatchControllerSettingsWithoutVirtualHIDAdvertisement() {
        let settings = StreamSettingsResolver.resolve(
            profile: StreamProfile(),
            capabilities: StreamDeviceCapabilities(connectedGamepadCount: 1)
        )

        #expect(settings.remoteControllersBitmap == 0x1)
        #expect(settings.supportedHidDevices == 0)
        #expect(settings.availableSupportedControllers.isEmpty)
        #expect(settings.upscalingMode == 0)
        #expect(settings.upscalingSharpness == 10)
    }

    @Test("preserves the Spatial upscaling tier instead of promoting it to MetalFX")
    func preservesSpatialUpscalingTier() {
        for preservedMode in [2, 3] {
            let settings = StreamSettingsResolver.resolve(
                profile: StreamProfile(upscalingMode: preservedMode),
                capabilities: StreamDeviceCapabilities()
            )

            #expect(settings.upscalingMode == preservedMode)
        }
    }

    @Test("coalesces legacy upscaling modes to MetalFX")
    func coalescesLegacyUpscalingModesToMetalFX() {
        for legacyMode in [1, 4] {
            let settings = StreamSettingsResolver.resolve(
                profile: StreamProfile(upscalingMode: legacyMode),
                capabilities: StreamDeviceCapabilities()
            )

            #expect(settings.upscalingMode == 3)
        }
    }

    @Test("auto codec prefers AV1 when bitrate is the binding constraint")
    func autoCodecPrefersAV1WhenBitrateIsTheBindingConstraint() {
        let capabilities = StreamDeviceCapabilities(
            h265HardwareDecodeSupported: true,
            av1HardwareDecodeSupported: true
        )
        let profile = StreamProfile(
            resolution: StreamResolution(width: 1920, height: 1080),
            fps: 60,
            codec: "auto",
            maxBitrateMbps: 25
        )

        #expect(StreamSettingsResolver.resolve(profile: profile, capabilities: capabilities).codec == "AV1")

        let withoutAV1 = StreamDeviceCapabilities(h265HardwareDecodeSupported: true)
        #expect(StreamSettingsResolver.resolve(profile: profile, capabilities: withoutAV1).codec != "AV1")
    }

    @Test("auto codec keeps H265 for HDR and for unconstrained bitrates")
    func autoCodecPreservesH265Quality() {
        let capabilities = StreamDeviceCapabilities(
            h265HardwareDecodeSupported: true,
            av1HardwareDecodeSupported: true,
            hdrDisplaySupported: true
        )
        let resolution = StreamResolution(width: 2560, height: 1440)

        let hdr = StreamProfile(resolution: resolution, fps: 60, codec: "auto", maxBitrateMbps: 20, enableHdr: true)
        #expect(StreamSettingsResolver.resolve(profile: hdr, capabilities: capabilities).codec == "H265")

        let unconstrained = StreamProfile(resolution: resolution, fps: 60, codec: "auto", maxBitrateMbps: 80)
        #expect(StreamSettingsResolver.resolve(profile: unconstrained, capabilities: capabilities).codec == "H265")
    }

    @Test("power saver resolves the launch frame rate before transport setup")
    func powerSaverResolvesLaunchFrameRateBeforeTransportSetup() {
        let settings = StreamSettingsResolver.resolve(
            profile: StreamProfile(fps: 120, enablePowerSaver: true),
            capabilities: StreamDeviceCapabilities(maxDisplayRefreshRate: 120)
        )

        #expect(settings.fps == 30)
    }

    @Test("preserves high resolution and bitrate")
    func preservesHighQualityProfile() {
        let settings = StreamSettingsResolver.resolve(
            profile: StreamProfile(
                resolution: StreamResolution(width: 2880, height: 1800),
                maxBitrateMbps: 50
            ),
            capabilities: StreamDeviceCapabilities()
        )

        #expect(settings.resolution == "2880x1800")
        #expect(settings.maxBitrateMbps == 50)
    }

    @Test("in-game settings persistence reaches the session payload")
    func inGameSettingsPersistenceReachesSessionPayload() {
        let settings = StreamSettingsResolver.resolve(
            profile: StreamProfile(enablePersistingInGameSettings: true),
            capabilities: StreamDeviceCapabilities()
        )

        #expect(settings.enablePersistingInGameSettings == true)
        #expect(settings.dictionary(gameLanguage: "en_US", accountLinked: true, selectedStore: "steam")["enablePersistingInGameSettings"] as? Bool == true)
    }

    @Test("carries display sleep prevention setting into resolved metadata")
    func carriesDisplaySleepPreventionSettingIntoResolvedMetadata() {
        let settings = StreamSettingsResolver.resolve(
            profile: StreamProfile(preventDisplaySleepWhileStreaming: false),
            capabilities: StreamDeviceCapabilities()
        )
        let dictionary = settings.dictionary(gameLanguage: "en_US", accountLinked: true, selectedStore: "steam")

        #expect(!settings.preventDisplaySleepWhileStreaming)
        #expect(dictionary["preventDisplaySleepWhileStreaming"] as? Bool == false)
    }

    @Test("big picture mode asks the seat for the gamepad-friendly launcher")
    func bigPictureModeAsksTheSeatForTheGamepadFriendlyLauncher() {
        let off = StreamSettingsResolver.resolve(
            profile: StreamProfile(),
            capabilities: StreamDeviceCapabilities()
        )
        #expect(off.appLaunchMode == 1)

        let on = StreamSettingsResolver.resolve(
            profile: StreamProfile(steamBigPictureMode: true),
            capabilities: StreamDeviceCapabilities()
        )
        let dictionary = on.dictionary(gameLanguage: "en_US", accountLinked: true, selectedStore: "steam")

        #expect(on.appLaunchMode == 2)
        #expect(dictionary["appLaunchMode"] as? Int == 2)
        #expect(streamProfile(from: dictionary).steamBigPictureMode)
    }

    @Test("reflex follows the profile toggle only when the seat allows it")
    func reflexFollowsTheProfileToggleOnlyWhenTheSeatAllowsIt() {
        let allowed = StreamCloudVariables(allowReflex: true)
        let blocked = StreamCloudVariables(allowReflex: false)
        let capabilities = StreamDeviceCapabilities()

        let on = StreamSettingsResolver.resolve(
            profile: StreamProfile(),
            capabilities: capabilities,
            cloudVariables: allowed
        )
        let off = StreamSettingsResolver.resolve(
            profile: StreamProfile(enableReflex: false),
            capabilities: capabilities,
            cloudVariables: allowed
        )
        let seatBlocked = StreamSettingsResolver.resolve(
            profile: StreamProfile(),
            capabilities: capabilities,
            cloudVariables: blocked
        )
        let offDictionary = off.dictionary(gameLanguage: "en_US", accountLinked: true, selectedStore: "steam")

        #expect(on.enableReflex)
        #expect(!off.enableReflex)
        #expect(!seatBlocked.enableReflex, "the seat entitlement gates the profile toggle")
        #expect(offDictionary["enableReflex"] as? Bool == false)
        #expect(!streamProfile(from: offDictionary).enableReflex)
    }

    @Test("keeps H265 ten bit color when available")
    func keepsH265TenBitColorWhenAvailable() {
        let settings = StreamSettingsResolver.resolve(
            profile: StreamProfile(codec: "H265", colorQuality: "10bit_420"),
            capabilities: StreamDeviceCapabilities(h265HardwareDecodeSupported: true)
        )

        #expect(settings.codec == "H265")
        #expect(settings.colorQuality == "10bit_420")
    }

    @Test("keeps AV1 ten bit color when available")
    func keepsAV1TenBitColorWhenAvailable() {
        let settings = StreamSettingsResolver.resolve(
            profile: StreamProfile(codec: "AV1", colorQuality: "10bit_420"),
            capabilities: StreamDeviceCapabilities(av1HardwareDecodeSupported: true)
        )

        #expect(settings.codec == "AV1")
        #expect(settings.colorQuality == "10bit_420")
    }

    @Test("disables unsupported vendor prefilter modes")
    func disablesUnsupportedVendorPrefilterModes() {
        let resolved = StreamSettingsResolver.resolve(
            profile: StreamProfile(prefilterMode: 2, prefilterSharpness: 7, prefilterDenoise: 4, prefilterModel: 3),
            capabilities: StreamDeviceCapabilities(),
            cloudVariables: StreamCloudVariables(fetched: true, supportedPrefilterModes: [0, 1])
        )

        #expect(resolved.prefilterMode == 0)
        #expect(resolved.prefilterSharpness == 0)
        #expect(resolved.prefilterDenoise == 0)
        #expect(resolved.prefilterModel == 0)
    }
}
