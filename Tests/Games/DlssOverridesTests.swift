//  The cloud DLSS override object, its normalization, and the membership policy that decides what
//  may actually be requested.

import Foundation
import Testing
@testable import OpenNOW

@Suite struct DlssOverridesTests {
    // MARK: - Normalization

    @Test func defaultsLeaveEveryFeatureToTheGame() {
        #expect(DlssOverrides(stored: nil).normalized() == DlssOverrides.useGameSettings)
        #expect(DlssOverrides(stored: [:]).normalized() == DlssOverrides.useGameSettings)
        #expect(DlssOverrides.useGameSettings.isUsingGameSettings)
    }

    @Test func fixedSuperResolutionModesCarryTheOfficialInputResolution() {
        for (mode, scale) in [(0, 100), (1, 50), (2, 58), (3, 67), (4, 33), (5, 100)] {
            var overrides = DlssOverrides.useGameSettings
            overrides.superResolutionModel = 1
            overrides.superResolutionMode = mode
            overrides.superResolutionScale = 90
            let normalized = overrides.normalized()
            #expect(normalized.superResolutionMode == mode)
            #expect(normalized.superResolutionScale == scale, "mode \(mode)")
        }
    }

    @Test func customSuperResolutionScaleIsClampedAndDefaultsTo75() {
        var overrides = DlssOverrides.useGameSettings
        overrides.superResolutionModel = 1
        overrides.superResolutionMode = DlssSuperResolutionMode.custom.rawValue
        overrides.superResolutionScale = 12
        #expect(overrides.normalized().superResolutionScale == 33)
        overrides.superResolutionScale = 140
        #expect(overrides.normalized().superResolutionScale == 100)
        overrides.superResolutionScale = 64
        #expect(overrides.normalized().superResolutionScale == 64)
    }

    @Test func aModelLeftToTheGameLeavesItsModeToTheGame() {
        let normalized = DlssOverrides(
            superResolutionMode: 2,
            superResolutionModel: 0,
            superResolutionScale: 58,
            rayReconstructionModel: 0,
            frameGenerationMode: 1,
            frameGenerationModel: 0,
            frameGenerationMultiplier: 4
        ).normalized()
        #expect(normalized == DlssOverrides.useGameSettings)
    }

    @Test func multiplierExistsOnlyForDynamicFrameGeneration() {
        let dynamic = DlssOverrides(
            superResolutionMode: 0,
            superResolutionModel: 0,
            superResolutionScale: 100,
            rayReconstructionModel: 0,
            frameGenerationMode: 1,
            frameGenerationModel: 1,
            frameGenerationMultiplier: 4
        )
        #expect(dynamic.sessionRequestDictionary["fgMultiplier"] as? Int == 4)

        var invalid = dynamic
        invalid.frameGenerationMultiplier = 2
        #expect(invalid.normalized().frameGenerationMultiplier == 3)

        var fixed = dynamic
        fixed.frameGenerationMode = 2
        #expect(fixed.normalized().frameGenerationMode == 0)
        #expect(fixed.normalized().frameGenerationMultiplier == 0)
        #expect(fixed.sessionRequestDictionary["fgMultiplier"] == nil)
    }

    @Test func unknownEnumValuesFallBackToTheGame() {
        let normalized = DlssOverrides(stored: [
            "srModel": 15,
            "srMode": 7,
            "rrModel": 8,
            "fgModel": 4,
            "fgMode": "1",
            "srScale": "58",
        ]).normalized()
        #expect(normalized == DlssOverrides.useGameSettings)
    }

    @Test func theScreenshotConfigurationReachesTheWire() {
        let overrides = DlssOverrides(stored: [
            "srMode": 2,
            "srModel": 1,
            "srScale": 10,
            "rrModel": 1,
            "fgMode": 1,
            "fgModel": 1,
            "fgMultiplier": 3,
        ]).normalized()
        let wire = overrides.sessionRequestDictionary
        #expect(wire["srMode"] as? Int == 2)
        #expect(wire["srModel"] as? Int == 1)
        #expect(wire["srScale"] as? Int == 58)
        #expect(wire["rrModel"] as? Int == 1)
        #expect(wire["fgMode"] as? Int == 1)
        #expect(wire["fgModel"] as? Int == 1)
        #expect(wire["fgMultiplier"] as? Int == 3)
    }

    @Test func modelPresetsUseThePublishedLetters() {
        #expect(DlssModelPreset.label(for: 0) == "In-game")
        #expect(DlssModelPreset.label(for: 1) == "Recommended")
        #expect(DlssModelPreset.superResolutionModels.map(DlssModelPreset.label(for:)) == [
            "In-game", "Recommended", "Preset A", "Preset B", "Preset C", "Preset D", "Preset E", "Preset F",
            "Preset J", "Preset K", "Preset L", "Preset M",
        ])
        #expect(DlssModelPreset.rayReconstructionModels.map(DlssModelPreset.label(for:)) == ["In-game", "Recommended", "Preset D", "Preset F"])
        #expect(DlssModelPreset.frameGenerationModels.map(DlssModelPreset.label(for:)) == ["In-game", "Recommended", "Preset A", "Preset B"])
    }

    @Test func nextSessionRequestDescribesTheRequestNotAnActivation() {
        var overrides = DlssOverrides.useGameSettings
        overrides.superResolutionModel = 1
        overrides.superResolutionMode = DlssSuperResolutionMode.quality.rawValue
        overrides.frameGenerationModel = 1
        overrides.frameGenerationMode = DlssFrameGenerationMode.dynamic.rawValue
        overrides.frameGenerationMultiplier = 4
        overrides.rayReconstructionModel = 1
        let summary = overrides.nextSessionRequestSummary
        #expect(summary == "SR Quality 67%  ·  FG Dynamic up to 4×  ·  RR Recommended")
        #expect(!summary.lowercased().contains("active"))
        #expect(!summary.lowercased().contains("enabled"))
    }

    // MARK: - Entitlements

    @Test func entitlementsFollowTheOfficialFeatureAndUpsellReaders() {
        let entitlements = DlssEntitlements.parse(
            features: [
                ["key": "SUPPORTED_DLSS_OVERRIDE_SR", "textValue": "true"],
                ["key": "SUPPORTED_DLSS_OVERRIDE_FG", "textValue": "[\"DYNAMIC\"]"],
                ["key": "SUPPORTED_DLSS_OVERRIDE_RR", "textValue": "false"],
                ["key": "SUPPORTED_DLSS_FG_MULTIPLIERS", "textValue": "[{\"value\":\"3X\",\"isEntitled\":true},{\"value\":\"4X\",\"isEntitled\":true},{\"value\":\"5X\",\"isEntitled\":false}]"],
            ],
            upsells: [
                ["key": "SUPPORT_DLSS_OVERRIDE_RR", "booleanValue": true],
                ["key": "SUPPORT_DLSS_OVERRIDE_FG", "booleanValue": false],
            ]
        )
        #expect(entitlements.superResolution == DlssCapability(isEntitled: true, isUpsell: false))
        #expect(entitlements.frameGeneration == DlssCapability(isEntitled: true, isUpsell: false))
        #expect(entitlements.rayReconstruction == DlssCapability(isEntitled: false, isUpsell: true))
        #expect(entitlements.frameGenerationMultipliers == [3, 4])
        #expect(entitlements.highestAllowedFrameGenerationMultiplier == 4)
        #expect(entitlements.supportsDynamicFrameGeneration)
        #expect(entitlements.upsellFeatureLabels == ["Ray Reconstruction"])
    }

    @Test func multiplierSetValuesAndMissingFeaturesAreRead() {
        let fromSet = DlssEntitlements.parse(
            features: [["key": "SUPPORTED_DLSS_FG_MULTIPLIERS", "setValue": ["3X", "4X", "5X", "6X"]]],
            upsells: []
        )
        #expect(fromSet.frameGenerationMultipliers == [3, 4, 5, 6])
        #expect(fromSet.superResolution == DlssCapability())
        #expect(fromSet.hasAnyEntitlement == false)
        #expect(fromSet.supportsDynamicFrameGeneration == false)

        let fromBoolean = DlssEntitlements.parse(
            features: [["key": "SUPPORTED_DLSS_FG_MULTIPLIERS", "textValue": "true"]],
            upsells: []
        )
        #expect(fromBoolean.frameGenerationMultipliers == [3, 4, 5, 6])

        #expect(DlssEntitlements.parse(features: [], upsells: []).frameGenerationMultipliers.isEmpty)
        #expect(DlssEntitlements.parse(subscription: nil) == .none)
    }

    @Test func aSubscriptionPayloadWithNestedFeaturesIsRead() {
        let entitlements = DlssEntitlements.parse(subscription: [
            "features": ["features": [["key": "SUPPORTED_DLSS_OVERRIDE_SR", "value": "1"]]],
            "upsells": [["key": "SUPPORT_DLSS_OVERRIDE_FG", "booleanValue": true]],
        ])
        #expect(entitlements.superResolution.isEntitled)
        #expect(entitlements.frameGeneration.isUpsell)
        #expect(!entitlements.frameGeneration.isEntitled)
    }

    // MARK: - Access policy

    @Test func unentitledOverridesAreNotRequested() {
        let stored = DlssOverrides(
            superResolutionMode: DlssSuperResolutionMode.quality.rawValue,
            superResolutionModel: 1,
            superResolutionScale: 67,
            rayReconstructionModel: 1,
            frameGenerationMode: DlssFrameGenerationMode.dynamic.rawValue,
            frameGenerationModel: 1,
            frameGenerationMultiplier: 6
        )
        let entitlements = DlssEntitlements(
            superResolution: DlssCapability(isEntitled: true, isUpsell: false),
            frameGeneration: DlssCapability(isEntitled: false, isUpsell: true),
            rayReconstruction: DlssCapability(isEntitled: false, isUpsell: true),
            frameGenerationMultipliers: [3, 4]
        )
        let effective = stored.applyingAccess(entitlements)
        #expect(effective.superResolutionMode == DlssSuperResolutionMode.quality.rawValue)
        #expect(effective.superResolutionScale == 67)
        #expect(effective.frameGenerationMode == 0)
        #expect(effective.frameGenerationModel == 0)
        #expect(effective.rayReconstructionModel == 0)
        #expect(effective.sessionRequestDictionary["fgMultiplier"] == nil)
        // The saved preference itself is untouched: only the request is filtered.
        #expect(stored.frameGenerationMultiplier == 6)
        #expect(stored.rayReconstructionModel == 1)
    }

    @Test func anUnentitledMultiplierFallsBackToTheLowestIncludedOne() {
        var stored = DlssOverrides.useGameSettings
        stored.frameGenerationModel = 1
        stored.frameGenerationMode = DlssFrameGenerationMode.dynamic.rawValue
        stored.frameGenerationMultiplier = 6
        let entitlements = DlssEntitlements(
            frameGeneration: DlssCapability(isEntitled: true, isUpsell: false),
            frameGenerationMultipliers: [3, 4]
        )
        #expect(stored.applyingAccess(entitlements).frameGenerationMultiplier == 3)

        let dynamicWithoutMultipliers = DlssEntitlements(frameGeneration: DlssCapability(isEntitled: true, isUpsell: false))
        #expect(stored.applyingAccess(dynamicWithoutMultipliers).frameGenerationMode == 0)
    }

    @Test func anUnknownMembershipIsNeverTreatedAsAnEntitledOne() {
        let stored = DlssOverrides(
            superResolutionMode: DlssSuperResolutionMode.dlaa.rawValue,
            superResolutionModel: 1,
            superResolutionScale: 100,
            rayReconstructionModel: 1,
            frameGenerationMode: 1,
            frameGenerationModel: 1,
            frameGenerationMultiplier: 4
        )
        #expect(stored.applyingAccess(.none) == DlssOverrides.useGameSettings)
        #expect(DlssEntitlements.none.hasAnyEntitlement == false)
        #expect(DlssMembershipState.loading.entitlements == .none)
        #expect(DlssMembershipState.unavailable.entitlements == .none)
        #expect(DlssMembershipState.signedOut.entitlements == .none)
    }

    // MARK: - Persistence and the launch flow

    @Test func theStoredPreferenceRoundTripsAndSurvivesALapsedMembership() throws {
        try withDlssPreferencesPreserved {
            let stored = DlssOverrides(
                superResolutionMode: DlssSuperResolutionMode.balanced.rawValue,
                superResolutionModel: 1,
                superResolutionScale: 58,
                rayReconstructionModel: 5,
                frameGenerationMode: DlssFrameGenerationMode.dynamic.rawValue,
                frameGenerationModel: 1,
                frameGenerationMultiplier: 5
            )
            OPNStreamPreferences.saveDlssOverrides(stored)
            #expect(OPNStreamPreferences.loadDlssOverrides() == stored)

            OPNStreamPreferences.saveDlssEntitlements(
                DlssEntitlements(
                    superResolution: DlssCapability(isEntitled: true, isUpsell: false),
                    frameGeneration: DlssCapability(isEntitled: true, isUpsell: false),
                    frameGenerationMultipliers: [3, 4]
                )
            )
            let entitled = OPNStreamPreferences.effectiveDlssOverrides()
            #expect(entitled.superResolutionMode == DlssSuperResolutionMode.balanced.rawValue)
            #expect(entitled.frameGenerationMultiplier == 3)

            // The membership lapses: the preference stays, the request does not.
            OPNStreamPreferences.clearDlssEntitlements()
            #expect(OPNStreamPreferences.loadDlssOverrides() == stored)
            #expect(OPNStreamPreferences.effectiveDlssOverrides() == DlssOverrides.useGameSettings)
        }
    }

    @Test func theHudResetPathDoesNotTouchTheCloudOverride() throws {
        try withDlssPreferencesPreserved {
            var stored = DlssOverrides.useGameSettings
            stored.superResolutionModel = 1
            stored.superResolutionMode = DlssSuperResolutionMode.quality.rawValue
            stored.superResolutionScale = 67
            OPNStreamPreferences.saveDlssOverrides(stored)
            OPNStreamPreferences.restoreStreamingProfileDefaults()
            #expect(OPNStreamPreferences.loadDlssOverrides() == stored)
        }
    }

    @Test func theSessionRequestCarriesTheOverrideObjectAndOmitsTheMultiplier() throws {
        try withDlssPreferencesPreserved {
            let manager = OPNSessionManager()
            let defaults = manager.requestedStreamingFeatures([:], hdrEnabled: false)
            let defaultOverrides = try #require(defaults["dlssOverrides"] as? [String: Any])
            #expect(defaultOverrides["srMode"] as? Int == 0)
            #expect(defaultOverrides["srModel"] as? Int == 0)
            #expect(defaultOverrides["srScale"] as? Int == 100)
            #expect(defaultOverrides["rrModel"] as? Int == 0)
            #expect(defaultOverrides["fgMode"] as? Int == 0)
            #expect(defaultOverrides["fgModel"] as? Int == 0)
            #expect(defaultOverrides["fgMultiplier"] == nil)

            OPNStreamPreferences.saveDlssEntitlements(
                DlssEntitlements(
                    superResolution: DlssCapability(isEntitled: true, isUpsell: false),
                    frameGeneration: DlssCapability(isEntitled: true, isUpsell: false),
                    rayReconstruction: DlssCapability(isEntitled: true, isUpsell: false),
                    frameGenerationMultipliers: [3, 4, 5, 6]
                )
            )
            let settings: [String: Any] = ["dlssOverrides": [
                "srMode": 6,
                "srModel": 2,
                "srScale": 80,
                "rrModel": 1,
                "fgMode": 1,
                "fgModel": 1,
                "fgMultiplier": 6,
            ]]
            let features = manager.requestedStreamingFeatures(settings, hdrEnabled: false)
            let overrides = try #require(features["dlssOverrides"] as? [String: Any])
            #expect(overrides["srMode"] as? Int == DlssSuperResolutionMode.custom.rawValue)
            #expect(overrides["srModel"] as? Int == 2)
            #expect(overrides["srScale"] as? Int == 80)
            #expect(overrides["rrModel"] as? Int == 1)
            #expect(overrides["fgMode"] as? Int == 1)
            #expect(overrides["fgMultiplier"] as? Int == 6)
        }
    }

    @Test func theSessionRequestNeverCarriesAnUnentitledOverride() throws {
        try withDlssPreferencesPreserved {
            OPNStreamPreferences.saveDlssOverrides(
                DlssOverrides(
                    superResolutionMode: DlssSuperResolutionMode.dlaa.rawValue,
                    superResolutionModel: 1,
                    superResolutionScale: 100,
                    rayReconstructionModel: 1,
                    frameGenerationMode: DlssFrameGenerationMode.dynamic.rawValue,
                    frameGenerationModel: 1,
                    frameGenerationMultiplier: 6
                )
            )
            OPNStreamPreferences.saveDlssEntitlements(
                DlssEntitlements(
                    superResolution: DlssCapability(isEntitled: true, isUpsell: false),
                    frameGeneration: DlssCapability(isEntitled: false, isUpsell: true),
                    rayReconstruction: DlssCapability(isEntitled: false, isUpsell: true)
                )
            )
            let features = OPNSessionManager().requestedStreamingFeatures([:], hdrEnabled: false)
            let overrides = try #require(features["dlssOverrides"] as? [String: Any])
            #expect(overrides["srMode"] as? Int == DlssSuperResolutionMode.dlaa.rawValue)
            #expect(overrides["fgMode"] as? Int == 0)
            #expect(overrides["fgModel"] as? Int == 0)
            #expect(overrides["fgMultiplier"] == nil)
            #expect(overrides["rrModel"] as? Int == 0)
        }
    }

    // MARK: - Settings state

    @Test func theSettingsStateReportsAccessWithoutClaimingActivation() {
        var overrides = DlssOverrides.useGameSettings
        overrides.superResolutionModel = 1
        overrides.superResolutionMode = DlssSuperResolutionMode.quality.rawValue
        overrides.superResolutionScale = 67

        let signedOut = DlssSettingsState.make(overrides: overrides, membership: .signedOut, isStreamRunning: false)
        #expect(signedOut.statusText == "Sign in to check DLSS override availability.")
        #expect(signedOut.showsSummary == false)

        let loading = DlssSettingsState.make(overrides: overrides, membership: .loading, isStreamRunning: false)
        #expect(loading.statusText == "Checking your membership…")

        let missing = DlssSettingsState.make(overrides: overrides, membership: .loaded(.none), isStreamRunning: false)
        #expect(missing.statusText == "Not included with your membership.")
        #expect(missing.superResolutionEnabled == false)

        let included = DlssSettingsState.make(
            overrides: overrides,
            membership: .loaded(DlssEntitlements(superResolution: DlssCapability(isEntitled: true, isUpsell: false))),
            isStreamRunning: true
        )
        #expect(included.statusText == DlssSettingsState.descriptionText)
        #expect(included.superResolutionEnabled)
        #expect(included.showsSummary)
        #expect(included.summaryText == "SR Quality 67%  ·  FG In-game  ·  RR In-game")
        #expect(included.showsNextSessionOnlyNote)
        #expect(DlssSettingsState.nextSessionOnlyText == "Saved for your next session. Your current stream is unchanged.")
    }

    @Test func anUnavailableMembershipReadsAsMissingAccessRatherThanEntitled() {
        let state = DlssSettingsState.make(overrides: .useGameSettings, membership: .unavailable, isStreamRunning: false)
        #expect(state.statusText == DlssSettingsState.missingAccessText)
        #expect(!state.superResolutionEnabled)
        #expect(!state.frameGenerationEnabled)
        #expect(!state.rayReconstructionEnabled)
        #expect(!state.showsSummary)
    }

    private func withDlssPreferencesPreserved(_ body: () throws -> Void) rethrows {
        preferenceDomainTestLock.lock()
        defer { preferenceDomainTestLock.unlock() }
        let defaults = UserDefaults.standard
        let keys = ["OpenNOW.Stream.DlssOverrides", "OpenNOW.Stream.DlssEntitlements"]
        let previous = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in previous {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
            defaults.synchronize()
        }
        for key in keys { defaults.removeObject(forKey: key) }
        try body()
    }
}
