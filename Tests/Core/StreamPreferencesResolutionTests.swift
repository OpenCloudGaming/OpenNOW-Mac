import Foundation
import Testing
@testable import OpenNOW

/// The 16:9 list is both what Settings renders and what a stored index resolves against, so the
/// 5K entry has to be appended: every earlier index keeps the resolution it always meant.
@Suite(.serialized) struct StreamPreferencesResolutionTests {
    private let aspectKey = "OpenNOW.Stream.AspectIndex"
    private let resolutionKey = "OpenNOW.Stream.ResolutionIndex"
    private let qualityProfileKey = "OpenNOW.Stream.StreamingQualityProfileIndex"
    private let gameProfilesKey = "OpenNOW.Stream.GameProfiles"

    @Test func thePickerOffersFiveKForSixteenNine() {
        let resolutions = OPNStreamPreferences.resolutionOptions(forAspect: 0)

        #expect(resolutions.map(\.value) == [
            "1280x720", "1600x900", "1920x1080", "2560x1440", "3840x2160", "5120x2880",
        ])
        #expect(resolutions.last?.label == "5120 x 2880")
    }

    @Test func everySelectionStoredBeforeFiveKKeepsItsResolution() {
        withPreservedPreferences([aspectKey, resolutionKey, qualityProfileKey, gameProfilesKey]) {
            removePreferenceValue(qualityProfileKey)
            removePreferenceValue(gameProfilesKey)
            OPNStreamPreferences.saveAspectIndex(0)

            let resolutionsBeforeFiveK = ["1280x720", "1600x900", "1920x1080", "2560x1440", "3840x2160"]
            for (index, resolution) in resolutionsBeforeFiveK.enumerated() {
                // Straight to storage: this is the index a build without the 5K entry left behind.
                OPNAppPreferenceStorage.standard.set(index, forKey: resolutionKey)
                #expect(OPNStreamPreferences.loadProfile().resolution.value == resolution)
            }
        }
    }

    @Test func theFiveKSelectionSurvivesAPreferenceReload() {
        withPreservedPreferences([aspectKey, resolutionKey, qualityProfileKey, gameProfilesKey]) {
            removePreferenceValue(qualityProfileKey)
            removePreferenceValue(gameProfilesKey)
            OPNStreamPreferences.saveAspectIndex(0)

            OPNStreamPreferences.saveResolutionIndex(5)

            let reloaded = OPNStreamPreferences.loadProfile()
            #expect(reloaded.resolutionIndex == 5)
            #expect(reloaded.resolution.width == 5120)
            #expect(reloaded.resolution.height == 2880)
        }
    }

    @Test func theFiveKSelectionReachesTheSessionRequest() throws {
        try withPreservedPreferences([aspectKey, resolutionKey, qualityProfileKey, gameProfilesKey]) {
            removePreferenceValue(qualityProfileKey)
            removePreferenceValue(gameProfilesKey)
            OPNStreamPreferences.saveAspectIndex(0)
            OPNStreamPreferences.saveResolutionIndex(5)

            let launchProfile = OPNStreamPreferences.launchProfile(forGame: "12345", capabilities: OPNStreamDeviceCapabilities())
            #expect(launchProfile.resolution.width == 5120)
            #expect(launchProfile.resolution.height == 2880)

            let settings = StreamSettingsResolver.resolve(
                profile: streamProfile(from: launchProfile),
                capabilities: StreamDeviceCapabilities()
            ).dictionary(gameLanguage: "en_US", accountLinked: true, selectedStore: "Steam")
            #expect(settings["resolution"] as? String == "5120x2880")

            let request = OPNSessionManager().sessionRequestData(
                launchAppId: try #require(OPNLaunchAppId.resolve("12345")),
                internalTitle: "Five K Game",
                settings: settings,
                capabilities: OPNStreamDeviceCapabilities(),
                hdrEnabled: false,
                deviceId: "test-device",
                selectedStore: "Steam"
            )
            let monitor = try #require((request["clientRequestMonitorSettings"] as? [[String: Any]])?.first)
            #expect(monitor["widthInPixels"] as? Int == 5120)
            #expect(monitor["heightInPixels"] as? Int == 2880)
        }
    }

    /// A per-game profile resolves the same stored index, so the 5K entry has to reach it too.
    @Test func theFiveKSelectionSurvivesInAPerGameProfile() throws {
        try withPreservedPreferences([aspectKey, resolutionKey, qualityProfileKey, gameProfilesKey]) {
            removePreferenceValue(qualityProfileKey)
            removePreferenceValue(gameProfilesKey)
            OPNStreamPreferences.saveAspectIndex(0)

            let appId = "five-k-game-profile"
            var gameProfile = OPNStreamPreferences.loadProfile()
            gameProfile.resolutionIndex = 5
            gameProfile.resolution = OPNStreamPreferences.resolutionOptions(forAspect: 0)[5]
            OPNStreamPreferences.saveProfile(forGame: appId, profile: gameProfile)

            let reloaded = try #require(OPNStreamPreferences.loadProfile(forGame: appId))
            #expect(reloaded.resolutionIndex == 5)
            #expect(reloaded.resolution.value == "5120x2880")
        }
    }

    @Test func otherAspectRatiosKeepTheirResolutions() {
        #expect(OPNStreamPreferences.resolutionOptions(forAspect: 1).map(\.value) == [
            "1280x800", "1440x900", "1680x1050", "1920x1200", "2560x1600", "2880x1800", "3456x2160",
        ])
        #expect(OPNStreamPreferences.resolutionOptions(forAspect: 2).map(\.value) == [
            "2560x1080", "3440x1440", "3840x1600", "5120x2160",
        ])
        #expect(OPNStreamPreferences.resolutionOptions(forAspect: 3).map(\.value) == ["3840x1080", "5120x1440"])
        #expect(OPNStreamPreferences.resolutionOptions(forAspect: 9).map(\.value)
            == OPNStreamPreferences.resolutionOptions(forAspect: 1).map(\.value))
    }

    @Test func everyAspectKeepsItsDefaultSelection() {
        #expect(OPNStreamPreferences.defaultResolutionIndex(forAspect: 0) == 2)
        #expect(OPNStreamPreferences.defaultResolutionIndex(forAspect: 1) == 3)
        #expect(OPNStreamPreferences.defaultResolutionIndex(forAspect: 2) == 0)
        #expect(OPNStreamPreferences.defaultResolutionIndex(forAspect: 3) == 0)
    }
}
