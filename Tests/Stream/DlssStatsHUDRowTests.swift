//  The stats HUD's DLSS group: the override this Mac will ask the seat for when the next session
//  starts. It reports a request, never an activation - CloudMatch never echoes the override back.

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

    private func makeOverlay() -> NativeNVSTStatsOverlay {
        NativeNVSTStatsOverlay(
            stats: NativeNVSTStreamStatsModel(),
            applicationID: "100",
            detailLevel: .advanced,
            hdrModeText: ""
        )
    }
}
