//  The settings card's derived state: the account's access, the request it will send, what the
//  running session actually has once the seat reports, and the preset vocabulary its pickers explain.

import Foundation
import Testing
@testable import OpenNOW

@Suite struct DlssSettingsStateTests {
    @Test func theSettingsStateReportsAccessWithoutClaimingActivation() {
        var overrides = DlssOverrides.useGameSettings
        overrides.superResolutionModel = 1
        overrides.superResolutionMode = DlssSuperResolutionMode.quality.rawValue
        overrides.superResolutionScale = 67

        let signedOut = DlssSettingsState.make(overrides: overrides, membership: .signedOut, isStreamRunning: false, appliedDlssState: nil)
        #expect(signedOut.statusText == DlssAccessCopy.signedOut)
        #expect(signedOut.isSummaryVisible == false)

        let loading = DlssSettingsState.make(overrides: overrides, membership: .loading, isStreamRunning: false, appliedDlssState: nil)
        #expect(loading.statusText == DlssAccessCopy.membershipLoading)

        let missing = DlssSettingsState.make(overrides: overrides, membership: .loaded(.none), isStreamRunning: false, appliedDlssState: nil)
        #expect(missing.statusText == DlssAccessCopy.missing)
        #expect(missing.isSuperResolutionEnabled == false)

        let included = DlssSettingsState.make(
            overrides: overrides,
            membership: .loaded(DlssEntitlements(superResolution: DlssCapability(isEntitled: true, isUpsell: false))),
            isStreamRunning: true,
            appliedDlssState: nil
        )
        #expect(included.statusText == DlssAccessCopy.description)
        #expect(included.isSuperResolutionEnabled)
        #expect(included.isSummaryVisible)
        #expect(included.summaryText == "SR Quality 67%  ·  FG In-game  ·  RR In-game")
        #expect(included.isNextSessionOnlyNoteVisible)
        #expect(DlssAccessCopy.nextSessionOnly == "Saved for your next session. Your current stream is unchanged.")
    }

    @Test func anUnavailableMembershipReadsAsMissingAccessRatherThanEntitled() {
        let state = DlssSettingsState.make(overrides: .useGameSettings, membership: .unavailable, isStreamRunning: false, appliedDlssState: nil)
        #expect(state.statusText == DlssAccessCopy.missing)
        #expect(!state.isSuperResolutionEnabled)
        #expect(!state.isFrameGenerationEnabled)
        #expect(!state.isRayReconstructionEnabled)
        #expect(!state.isSummaryVisible)
    }

    /// The card states the request and, once the seat has reported, what the running session
    /// actually has. It says nothing about a session that has not reported one.
    @Test func theSettingsCardReportsWhatTheRunningSessionApplied() {
        let entitlements = DlssEntitlements(
            superResolution: DlssCapability(isEntitled: true, isUpsell: false),
            frameGeneration: DlssCapability(isEntitled: true, isUpsell: false),
            rayReconstruction: DlssCapability(isEntitled: true, isUpsell: false),
            frameGenerationMultipliers: [3, 4, 5, 6]
        )
        let applied = NvstDlssStateNotification(
            isSuperResolutionOverridden: true,
            isRayReconstructionOverridden: true,
            isFrameGenerationOverridden: true,
            activeFrameGenerationMultiplier: 4,
            overrides: NvstDlssStateNotification.Overrides(
                superResolutionMode: DlssSuperResolutionMode.dlaa.rawValue,
                superResolutionModel: 1,
                superResolutionScale: 100,
                rayReconstructionModel: 7,
                frameGenerationMode: DlssFrameGenerationMode.dynamic.rawValue,
                frameGenerationModel: 1,
                frameGenerationMultiplier: 4
            )
        )

        let reported = DlssSettingsState.make(
            overrides: .useGameSettings,
            membership: .loaded(entitlements),
            isStreamRunning: true,
            appliedDlssState: applied
        )
        #expect(reported.isAppliedSummaryVisible)
        #expect(reported.appliedSummaryText == "SR DLAA 100%  ·  FG Dynamic up to 4×  ·  RR Preset F")
        #expect(DlssAccessCopy.appliedHeading == "Current session")

        let unreported = DlssSettingsState.make(
            overrides: .useGameSettings,
            membership: .loaded(entitlements),
            isStreamRunning: true,
            appliedDlssState: nil
        )
        #expect(!unreported.isAppliedSummaryVisible)
        #expect(unreported.appliedSummaryText.isEmpty)
    }

    @Test func theAccessCopySeparatesWhatTheGameSupportsFromWhatTheAccountIncludes() {
        let entitled = DlssMembershipState.loaded(DlssEntitlements(
            superResolution: DlssCapability(isEntitled: true, isUpsell: false),
            frameGeneration: DlssCapability(isEntitled: false, isUpsell: true),
            rayReconstruction: DlssCapability(isEntitled: false, isUpsell: false),
            frameGenerationMultipliers: [3, 4]
        ))
        #expect(DlssAccessCopy.accessText(for: .superResolution, membership: entitled) == DlssAccessCopy.included)
        #expect(DlssAccessCopy.accessText(for: .frameGeneration, membership: entitled) == DlssAccessCopy.upsell)
        #expect(DlssAccessCopy.accessText(for: .rayReconstruction, membership: entitled) == DlssAccessCopy.missing)
        // The multiplier ceiling follows the frame-generation entitlement, not the listed maximum.
        #expect(DlssAccessCopy.multiplierAccessText(for: entitled) == DlssAccessCopy.missing)

        let dynamicIncluded = DlssMembershipState.loaded(DlssEntitlements(
            frameGeneration: DlssCapability(isEntitled: true, isUpsell: false),
            frameGenerationMultipliers: [3, 4]
        ))
        #expect(DlssAccessCopy.multiplierAccessText(for: dynamicIncluded) == "Your membership includes up to 4×.")
        #expect(DlssAccessCopy.accessText(for: .superResolution, membership: .signedOut) == DlssAccessCopy.signedOut)
        #expect(DlssAccessCopy.accessText(for: .superResolution, membership: .loading) == DlssAccessCopy.membershipLoading)
        #expect(DlssAccessCopy.multiplierAccessText(for: .loaded(.none)) == DlssAccessCopy.missing)
    }

    /// Every option a model picker offers carries an explanation, so no chip is left unexplained.
    @Test func everyPresetAPickerOffersIsExplained() {
        #expect(DlssModelPreset.superResolutionModels.allSatisfy { DlssPresetHelp.superResolution[$0] != nil })
        #expect(DlssModelPreset.frameGenerationModels.allSatisfy { DlssPresetHelp.frameGeneration[$0] != nil })
        #expect(DlssModelPreset.rayReconstructionModels.allSatisfy { DlssPresetHelp.rayReconstruction[$0] != nil })
    }

    /// The legend is built from the picker's own values, so it explains every option it shows and
    /// keeps the row's own lead sentence above them.
    @Test func theLegendExplainsEveryPresetUnderItsRowsLead() {
        let values = DlssModelPreset.frameGenerationModels
        let legend = DlssPresetHelp.legend(
            for: values,
            help: DlssPresetHelp.frameGeneration,
            lead: "Used when Frame Generation is Dynamic."
        )

        #expect(legend.hasPrefix("Used when Frame Generation is Dynamic.\n\n"))
        for value in values {
            #expect(legend.contains(DlssPresetHelp.frameGeneration[value] ?? ""))
        }
    }

    /// Without a lead the legend is the introduction and one line per preset, which is what the
    /// Super Resolution row uses.
    @Test func aLegendWithoutALeadIsTheIntroductionAndOneLinePerPreset() {
        let legend = DlssPresetHelp.legend(
            for: DlssModelPreset.superResolutionModels,
            help: DlssPresetHelp.superResolution
        )
        #expect(legend.components(separatedBy: "\n").count == DlssModelPreset.superResolutionModels.count + 1)
    }

    /// Super Resolution and Ray Reconstruction share preset letters but not meanings, which is why
    /// the explanations are held per feature rather than per letter.
    @Test func theSamePresetLetterMeansDifferentThingsToDifferentFeatures() {
        #expect(DlssPresetHelp.superResolution[5] != DlssPresetHelp.rayReconstruction[5])
        #expect(DlssPresetHelp.superResolution[7] != DlssPresetHelp.rayReconstruction[7])
    }
}
