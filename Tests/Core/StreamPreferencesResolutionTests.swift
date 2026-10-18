import Foundation
import Testing
@testable import OpenNOW

/// The 16:9 list is both what Settings renders and what a stored index resolves against, so a new
/// entry has to be appended: an index that predates it must keep resolving to the resolution it
/// already meant.
@Suite(.serialized) struct StreamPreferencesResolutionTests {
    private let preferenceDomain = "io.github.opencloudgaming.opennow"
    private let aspectKey = "OpenNOW.Stream.AspectIndex"
    private let resolutionKey = "OpenNOW.Stream.ResolutionIndex"
    private let qualityProfileKey = "OpenNOW.Stream.StreamingQualityProfileIndex"
    private let gameProfilesKey = "OpenNOW.Stream.GameProfiles"

    @Test func sixteenNineEndsWithFiveKAfterFourK() {
        #expect(OPNStreamPreferences.resolutionOptions(forAspect: 0).map(\.value) == [
            "1280x720", "1600x900", "1920x1080", "2560x1440", "3840x2160", "5120x2880",
        ])
        #expect(OPNStreamPreferences.resolutionOptions(forAspect: 0).last?.label == "5120 x 2880")
    }

    @Test func appendingFiveKLeavesEveryEarlierIndexOnItsOwnResolution() {
        let options = OPNStreamPreferences.resolutionOptions(forAspect: 0)

        #expect(options[0].value == "1280x720")
        #expect(options[1].value == "1600x900")
        #expect(options[2].value == "1920x1080")
        #expect(options[3].value == "2560x1440")
        #expect(options[4].value == "3840x2160")
        #expect(options[5].value == "5120x2880")
        // The default sits at 1080p and must not move with the appended entry.
        #expect(OPNStreamPreferences.defaultResolutionIndex(forAspect: 0) == 2)
    }

    @Test func otherAspectRatiosAndTheDefaultFallbackAreUnchanged() {
        #expect(OPNStreamPreferences.resolutionOptions(forAspect: 1).map(\.value) == [
            "1280x800", "1440x900", "1680x1050", "1920x1200", "2560x1600", "2880x1800", "3456x2160",
        ])
        #expect(OPNStreamPreferences.resolutionOptions(forAspect: 2).map(\.value) == [
            "2560x1080", "3440x1440", "3840x1600", "5120x2160",
        ])
        #expect(OPNStreamPreferences.resolutionOptions(forAspect: 3).map(\.value) == ["3840x1080", "5120x1440"])
        #expect(OPNStreamPreferences.resolutionOptions(forAspect: 9).map(\.value)
            == OPNStreamPreferences.resolutionOptions(forAspect: 1).map(\.value))
        #expect(OPNStreamPreferences.defaultResolutionIndex(forAspect: 1) == 3)
        #expect(OPNStreamPreferences.defaultResolutionIndex(forAspect: 2) == 0)
        #expect(OPNStreamPreferences.defaultResolutionIndex(forAspect: 3) == 0)
    }

    @Test func fiveKSelectionSurvivesReloadWhileEarlierStoredIndicesKeepTheirResolution() {
        withPreservedPreferences([aspectKey, resolutionKey, qualityProfileKey, gameProfilesKey]) {
            removePreferenceValue(qualityProfileKey)
            removePreferenceValue(gameProfilesKey)

            OPNStreamPreferences.saveAspectIndex(0)
            OPNStreamPreferences.saveResolutionIndex(5)
            #expect(OPNStreamPreferences.loadProfile().resolution.value == "5120x2880")

            // A profile written before the option existed keeps index 4 on 4K rather than sliding
            // onto the appended entry.
            OPNAppPreferenceStorage.standard.set(4, forKey: resolutionKey)
            #expect(OPNStreamPreferences.loadProfile().resolution.value == "3840x2160")

            OPNAppPreferenceStorage.standard.set(5, forKey: resolutionKey)
            let reloaded = OPNStreamPreferences.loadProfile()
            #expect(reloaded.resolutionIndex == 5)
            #expect(reloaded.resolution.width == 5120)
            #expect(reloaded.resolution.height == 2880)
        }
    }

    @Test func fiveKSelectionReachesTheLaunchProfileAndSessionRequest() throws {
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

    /// A per-game profile is a second writer of the same index, so the 5K entry has to be in the
    /// list a game profile resolves against too.
    @Test func perGameFiveKSelectionSurvivesReload() throws {
        try withPreservedPreferences([aspectKey, resolutionKey, qualityProfileKey, gameProfilesKey]) {
            removePreferenceValue(qualityProfileKey)
            removePreferenceValue(gameProfilesKey)
            OPNStreamPreferences.saveAspectIndex(0)

            let appId = "five-k-game-profile"
            var gameProfile = OPNStreamPreferences.loadProfile()
            gameProfile.resolutionIndex = 5
            gameProfile.resolution = OPNStreamPreferences.resolutionOptions(forAspect: 0)[5]
            OPNStreamPreferences.saveProfile(forGame: appId, profile: gameProfile)

            let loaded = try #require(OPNStreamPreferences.loadProfile(forGame: appId))
            #expect(loaded.resolutionIndex == 5)
            #expect(loaded.resolution.value == "5120x2880")
        }
    }

    private func withPreservedPreferences(_ keys: [String], _ body: () throws -> Void) rethrows {
        try withExclusivePreferenceDomain {
            let defaults = UserDefaults.standard
            let previousValues = keys.map { ($0, defaults.object(forKey: $0)) }
            let previousDomain = defaults.persistentDomain(forName: preferenceDomain)
            let previousGlobalDomain = defaults.persistentDomain(forName: UserDefaults.globalDomain)
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
                if let previousGlobalDomain {
                    defaults.setPersistentDomain(previousGlobalDomain, forName: UserDefaults.globalDomain)
                } else {
                    defaults.removePersistentDomain(forName: UserDefaults.globalDomain)
                }
                defaults.synchronize()
            }
            try body()
        }
    }

    private func removePreferenceValue(_ key: String) {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: key)
        var domain = defaults.persistentDomain(forName: preferenceDomain) ?? [:]
        domain.removeValue(forKey: key)
        defaults.setPersistentDomain(domain, forName: preferenceDomain)
        var globalDomain = defaults.persistentDomain(forName: UserDefaults.globalDomain) ?? [:]
        globalDomain.removeValue(forKey: key)
        defaults.setPersistentDomain(globalDomain, forName: UserDefaults.globalDomain)
        defaults.synchronize()
    }
}
