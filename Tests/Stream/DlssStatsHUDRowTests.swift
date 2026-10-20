//  The stats HUD's DLSS group: the override this Mac will ask the seat for when the next session
//  starts, and - once the seat's `DlssState` message arrives - what the running session actually
//  has. The request is never presented as an activation.

import Foundation
import Testing
@testable import OpenNOW

@MainActor
@Suite struct DlssStatsHUDRowTests {
    @Test func theStatsHUDReportsTheNextSessionRequest() {
        withDlssPreferencesPreserved {
            OPNStreamPreferences.saveDlssOverrides(requestedOverrides)
            OPNStreamPreferences.saveDlssEntitlements(grantedEntitlements)

            let rows = makeOverlay().nativeStatsDlssGroup.rows
            #expect(rows.map(\.label) == ["Super Resolution", "Frame Generation", "Ray Reconstruction"])
            #expect(rows.map(\.value) == ["DLAA 100%", "Dynamic up to 4×", "Preset D"])
        }
    }

    @Test func theDlssGroupSaysTheValuesAreForTheNextSession() {
        withDlssPreferencesPreserved {
            OPNStreamPreferences.saveDlssOverrides(requestedOverrides)
            OPNStreamPreferences.saveDlssEntitlements(grantedEntitlements)
            #expect(makeOverlay().nativeStatsDlssGroup.label == "DLSS · NEXT SESSION")
        }
    }

    @Test func theDlssGroupNeverClaimsAnOverrideIsActive() {
        withDlssPreferencesPreserved {
            OPNStreamPreferences.saveDlssOverrides(requestedOverrides)
            OPNStreamPreferences.saveDlssEntitlements(grantedEntitlements)
            let group = makeOverlay().nativeStatsDlssGroup
            let text = ([group.label] + group.rows.flatMap { [$0.label, $0.value, $0.detail ?? ""] }).joined(separator: " ").lowercased()
            let words = Set(text.split { !$0.isLetter }.map(String.init))
            for claim in ["active", "enabled", "unsupported", "on"] {
                #expect(!words.contains(claim), "the HUD claims \(claim)")
            }
        }
    }

    @Test func anUnentitledOverrideIsReportedAsNotRequested() {
        withDlssPreferencesPreserved {
            OPNStreamPreferences.saveDlssOverrides(requestedOverrides)
            OPNStreamPreferences.clearDlssEntitlements()

            let rows = makeOverlay().nativeStatsDlssGroup.rows
            #expect(rows.map(\.value) == ["In-game", "In-game", "In-game"])
        }
    }

    @Test func gameSettingsReadAsInGame() {
        withDlssPreferencesPreserved {
            OPNStreamPreferences.saveDlssOverrides(.useGameSettings)
            OPNStreamPreferences.saveDlssEntitlements(grantedEntitlements)
            let rows = makeOverlay().nativeStatsDlssGroup.rows
            #expect(rows.map(\.value) == ["In-game", "In-game", "In-game"])
        }
    }

    @Test func theDlssGroupIsAdvancedDetailOnly() {
        let overlay = makeOverlay()
        #expect(!overlay.nativeStatsGroups(for: .minimum).contains { $0.label.hasPrefix("DLSS") })
        #expect(!overlay.nativeStatsGroups(for: .compact).contains { $0.label.hasPrefix("DLSS") })
        #expect(overlay.nativeStatsGroups(for: .advanced).last?.label == "DLSS · NEXT SESSION")
    }

    /// The seat's own report is the only confirmation an override took effect, so it replaces the
    /// request rather than sitting beside it.
    @Test func theSeatsReportReplacesTheRequestOnceItArrives() {
        withDlssPreferencesPreserved {
            OPNStreamPreferences.saveDlssOverrides(requestedOverrides)
            OPNStreamPreferences.saveDlssEntitlements(grantedEntitlements)

            let group = makeOverlay(applied: appliedState).nativeStatsDlssGroup
            #expect(group.label == "DLSS · THIS SESSION")
            #expect(group.rows.map(\.label) == ["Super Resolution", "Frame Generation", "Ray Reconstruction"])
            #expect(group.rows.map(\.value) == ["DLAA 100%", "Dynamic up to 4×", "Preset F"])
        }
    }

    /// A seat that reports the feature is not overridden reads as the game's own setting, not as a
    /// failure and not as the request that was sent.
    @Test func aSeatThatOverrodeNothingReadsAsInGame() {
        withDlssPreferencesPreserved {
            OPNStreamPreferences.saveDlssOverrides(requestedOverrides)
            OPNStreamPreferences.saveDlssEntitlements(grantedEntitlements)

            let group = makeOverlay(applied: NvstDlssStateNotification(
                isSuperResolutionOverridden: false,
                isRayReconstructionOverridden: false,
                isFrameGenerationOverridden: false,
                activeFrameGenerationMultiplier: 0,
                overrides: .none
            )).nativeStatsDlssGroup
            #expect(group.label == "DLSS · THIS SESSION")
            #expect(group.rows.map(\.value) == ["In-game", "In-game", "In-game"])
        }
    }

    /// The live multiplier is what the seat is running; the override's own multiplier is only the
    /// ceiling that was asked for, and is what the row falls back to while the seat reports none.
    @Test func theFrameGenerationRowPrefersTheMultiplierTheSeatIsRunning() {
        withDlssPreferencesPreserved {
            OPNStreamPreferences.saveDlssOverrides(requestedOverrides)
            OPNStreamPreferences.saveDlssEntitlements(grantedEntitlements)

            let state = NvstDlssStateNotification(
                isSuperResolutionOverridden: appliedState.isSuperResolutionOverridden,
                isRayReconstructionOverridden: appliedState.isRayReconstructionOverridden,
                isFrameGenerationOverridden: appliedState.isFrameGenerationOverridden,
                activeFrameGenerationMultiplier: 3,
                overrides: appliedState.overrides
            )
            let rows = makeOverlay(applied: state).nativeStatsDlssGroup.rows
            #expect(rows[1].value == "Dynamic up to 3×")
        }
    }

    private var appliedState: NvstDlssStateNotification {
        NvstDlssStateNotification(
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
    }

    /// The settings card and the stats HUD read the same three labels, so they cannot disagree.
    @Test func theHudRowAndTheCardSummaryAgree() {
        withDlssPreferencesPreserved {
            OPNStreamPreferences.saveDlssOverrides(requestedOverrides)
            OPNStreamPreferences.saveDlssEntitlements(grantedEntitlements)
            let overrides = OPNStreamPreferences.effectiveDlssOverrides()
            let rows = makeOverlay().nativeStatsDlssGroup.rows
            #expect(overrides.nextSessionRequestSummary == "SR \(rows[0].value)  ·  FG \(rows[1].value)  ·  RR \(rows[2].value)")
        }
    }

    private var requestedOverrides: DlssOverrides {
        DlssOverrides(
            superResolutionMode: DlssSuperResolutionMode.dlaa.rawValue,
            superResolutionModel: 1,
            superResolutionScale: 100,
            rayReconstructionModel: 5,
            frameGenerationMode: DlssFrameGenerationMode.dynamic.rawValue,
            frameGenerationModel: 1,
            frameGenerationMultiplier: 4
        )
    }

    private var grantedEntitlements: DlssEntitlements {
        DlssEntitlements(
            superResolution: DlssCapability(isEntitled: true, isUpsell: false),
            frameGeneration: DlssCapability(isEntitled: true, isUpsell: false),
            rayReconstruction: DlssCapability(isEntitled: true, isUpsell: false),
            frameGenerationMultipliers: [3, 4, 5, 6]
        )
    }

    private func makeOverlay(applied: NvstDlssStateNotification? = nil) -> NativeNVSTStatsOverlay {
        NativeNVSTStatsOverlay(
            stats: NativeNVSTStreamStatsModel(),
            applicationID: "100",
            detailLevel: .advanced,
            hdrModeText: "",
            appliedDlssState: applied
        )
    }
}
