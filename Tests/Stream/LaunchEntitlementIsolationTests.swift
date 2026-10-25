import Foundation
import Testing
@testable import OpenNOW

@MainActor
private final class LaunchEntitlementPresenceStub: DiscordPresenceServing {
    var isEnabled = false
    private(set) var lastState = DiscordPresenceState.idle

    func update(_ state: DiscordPresenceState) { lastState = state }
}

@MainActor
@Suite struct LaunchEntitlementIsolationTests {
    @Test func eachAppOwnedLaunchKeepsItsMembershipThroughFinalPayloadResolution() throws {
        try withPreservedPreferences(["OpenNOW.Stream.DlssEntitlements", "OpenNOW.Stream.DlssOverrides", "OpenNOW.Stream.EntitledAudioChannelCount", "OpenNOW.Stream.EntitledInGameSettingsPersistence", "OpenNOW.Stream.PersistInGameSettings", OPNSessionReadyAction.modeKey]) {
            OPNSessionReadyAction.mode = .off
            let granted = OPNLaunchEntitlements(
                dlss: DlssEntitlements(superResolution: DlssCapability(isEntitled: true)),
                audioChannelCount: 8,
                isInGameSettingsPersistenceEntitled: true
            )
            let firstService = OPNGameService()
            let first = try makeOwnedSession(email: "launch-a@example.test", entitlements: granted, provider: "https://provider-a.nvidiagrid.net/", gameService: firstService)
            let second = try makeOwnedSession(email: "launch-b@example.test", entitlements: .none, provider: "https://provider-b.nvidiagrid.net/")
            defer {
                first.cancelStreamLaunch()
                second.cancelStreamLaunch()
                first.session.purgeTokens()
                second.session.purgeTokens()
            }
            let firstConfiguration = try #require(first.configuration)
            let secondConfiguration = try #require(second.configuration)
            #expect(firstConfiguration.launchEntitlements == granted)
            #expect(secondConfiguration.launchEntitlements == .none)
            #expect(firstConfiguration.metadata[OPNLaunchEntitlements.providerMetadataKey] == "https://provider-a.nvidiagrid.net/")
            #expect(secondConfiguration.resumesExistingSession)
            firstService.providerStreamingBaseUrl = "https://provider-changed.nvidiagrid.net/"
            #expect(first.configuration?.metadata[OPNLaunchEntitlements.providerMetadataKey] == "https://provider-a.nvidiagrid.net/")

            OPNStreamPreferences.clearDlssEntitlements()
            OPNStreamPreferences.saveEntitledAudioChannelCount(2)
            OPNStreamPreferences.saveEntitledInGameSettingsPersistence(false)
            OPNStreamPreferences.savePersistInGameSettings(true)
            let coordinator = OPNStreamSessionCoordinator()
            var firstSettings = coordinator.makeSettings(configuration: firstConfiguration)
            #expect(OPNLaunchEntitlements(settings: firstSettings) == granted)
            #expect(firstSettings["enablePersistingInGameSettings"] as? Bool == true)
            OPNStreamPreferences.saveDlssEntitlements(granted.dlss)
            OPNStreamPreferences.saveEntitledAudioChannelCount(8)
            OPNStreamPreferences.saveEntitledInGameSettingsPersistence(true)
            var secondSettings = coordinator.makeSettings(configuration: secondConfiguration)
            #expect(secondSettings["enablePersistingInGameSettings"] as? Bool == false)
            firstSettings["surroundMode"] = "7.1"
            secondSettings["surroundMode"] = "7.1"
            var overrides = DlssOverrides.useGameSettings
            overrides.superResolutionModel = 1
            overrides.superResolutionMode = DlssSuperResolutionMode.quality.rawValue
            firstSettings["dlssOverrides"] = overrides.storedDictionary
            secondSettings["dlssOverrides"] = overrides.storedDictionary
            try expectPayloadEntitlements(firstSettings: firstSettings, secondSettings: secondSettings)
        }
    }

    @Test func aLaunchWithoutAnAccountSnapshotCannotBorrowGlobalMembership() {
        withPreservedPreferences(["OpenNOW.Stream.DlssEntitlements", "OpenNOW.Stream.DlssOverrides"]) {
            OPNStreamPreferences.saveDlssEntitlements(DlssEntitlements(superResolution: DlssCapability(isEntitled: true)))
            var overrides = DlssOverrides.useGameSettings
            overrides.superResolutionModel = 1
            overrides.superResolutionMode = DlssSuperResolutionMode.quality.rawValue
            let settings: [String: Any] = ["dlssOverrides": overrides.storedDictionary]
            let features = OPNSessionManager().requestedStreamingFeatures(settings, hdrEnabled: false)
            #expect((features["dlssOverrides"] as? [String: Any])?["srMode"] as? Int == 0)
            #expect(OPNLaunchEntitlements(metadata: [OPNLaunchEntitlements.metadataKey: "not-json"]) == .none)
        }
    }

    @Test func automaticRegionSelectionUsesTheLaunchingProviderUnlessTheReaderChoseARegion() {
        withPreservedPreferences(["OpenNOW.Stream.RegionUrl"]) {
            OPNStreamPreferences.saveSelectedRegionUrl("")
            #expect(OPNStreamPreferences.loadSelectedStreamingBaseUrl(providerStreamingBaseURL: "https://provider-a.nvidiagrid.net/") == "https://provider-a.nvidiagrid.net/")
            #expect(OPNStreamPreferences.loadSelectedStreamingBaseUrl(providerStreamingBaseURL: "https://provider-b.nvidiagrid.net/") == "https://provider-b.nvidiagrid.net/")
            OPNStreamPreferences.saveSelectedRegionUrl("https://chosen-region.nvidiagrid.net/")
            #expect(OPNStreamPreferences.loadSelectedStreamingBaseUrl(providerStreamingBaseURL: "https://provider-a.nvidiagrid.net/") == "https://chosen-region.nvidiagrid.net/")
            #expect(OPNStreamPreferences.loadSelectedStreamingBaseUrl(providerStreamingBaseURL: "https://provider-b.nvidiagrid.net/") == "https://chosen-region.nvidiagrid.net/")
        }
    }

    private func expectPayloadEntitlements(firstSettings: [String: Any], secondSettings: [String: Any]) throws {
        let coordinator = OPNStreamSessionCoordinator()
        var cloudVariables = OPNStreamCloudVariables()
        cloudVariables.entitledAudioChannelCount = 2
        let firstCloudSettings = coordinator.settingsByApplyingCloudVariables(firstSettings, variables: cloudVariables)
        cloudVariables.entitledAudioChannelCount = 8
        let secondCloudSettings = coordinator.settingsByApplyingCloudVariables(secondSettings, variables: cloudVariables)
        let manager = OPNSessionManager()
        var capabilities = OPNStreamDeviceCapabilities()
        capabilities.audioOutputChannelCount = 8
        let firstPayloadSettings = manager.settingsByApplyingCloudVariables(firstCloudSettings, capabilities: capabilities)
        let secondPayloadSettings = manager.settingsByApplyingCloudVariables(secondCloudSettings, capabilities: capabilities)
        let appID = try #require(OPNLaunchAppId.resolve("123"))
        let firstPayload = manager.sessionRequestData(launchAppId: appID, internalTitle: "Game A", settings: firstPayloadSettings, capabilities: capabilities, hdrEnabled: false, deviceId: "device-a", selectedStore: "STEAM")
        let secondPayload = manager.sessionRequestData(launchAppId: appID, internalTitle: "Game B", settings: secondPayloadSettings, capabilities: capabilities, hdrEnabled: false, deviceId: "device-b", selectedStore: "STEAM")
        #expect(firstPayload["requestedAudioFormat"] as? Int == 3)
        #expect(secondPayload["requestedAudioFormat"] as? Int == 1)
        #expect(firstPayload["enablePersistingInGameSettings"] as? Bool == true)
        #expect(secondPayload["enablePersistingInGameSettings"] as? Bool == false)
        #expect(firstPayload[OPNLaunchEntitlements.settingsKey] == nil)
        let firstFeatures = try #require(firstPayload["requestedStreamingFeatures"] as? [String: Any])
        let secondFeatures = try #require(secondPayload["requestedStreamingFeatures"] as? [String: Any])
        #expect((firstFeatures["dlssOverrides"] as? [String: Any])?["srMode"] as? Int == DlssSuperResolutionMode.quality.rawValue)
        #expect((secondFeatures["dlssOverrides"] as? [String: Any])?["srMode"] as? Int == 0)
    }

    private func makeOwnedSession(email: String, entitlements: OPNLaunchEntitlements, provider: String, gameService: OPNGameService = OPNGameService()) throws -> OPNGameSession {
        let account = makeLoginAccountForTesting(email: email, userId: email)
        let session = makeLoginSessionForTesting(accountEmail: email, userId: email)
        let registry = OPNGameSessionRegistry()
        let owned = try #require(registry.begin(
            account: account,
            session: session,
            gameService: gameService,
            launchBridge: OPNGameLaunchBridge(gameService: gameService),
            discordPresence: LaunchEntitlementPresenceStub(),
            streamProfile: OPNStreamPreferenceProfile(),
            launchEntitlements: entitlements,
            providerStreamingBaseURL: provider,
            results: OPNGameSessionResultStore()
        ))
        owned.beginResume(title: "Game", applicationID: "123", sessionID: "resume-\(email)", server: "seat.nvidiagrid.net", game: nil)
        return owned
    }
}
