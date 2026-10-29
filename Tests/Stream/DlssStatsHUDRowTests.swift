//  The stats HUD's DLSS group: the override this Mac will ask the seat for when the next session
//  starts, and - once the seat's `DlssState` message arrives - what the running session actually
//  has. The request is never presented as an activation.

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import OpenNOW

@MainActor
@Suite struct DlssStatsHUDRowTests {
    @Test func theStatsHUDReportsTheNextSessionRequest() {
        withDlssPreferencesPreserved {
            OPNStreamPreferences.saveDlssOverrides(requestedOverrides)

            let rows = makeOverlay(entitlements: grantedEntitlements).nativeStatsDlssGroup.rows
            #expect(rows.map(\.label) == ["Super Resolution", "Frame Generation", "Ray Reconstruction"])
            #expect(rows.map(\.value) == ["DLAA 100%", "Dynamic up to 4×", "Preset D"])
        }
    }

    @Test func theDlssGroupSaysTheValuesAreForTheNextSession() {
        withDlssPreferencesPreserved {
            OPNStreamPreferences.saveDlssOverrides(requestedOverrides)
            #expect(makeOverlay(entitlements: grantedEntitlements).nativeStatsDlssGroup.label == "DLSS · NEXT SESSION")
        }
    }

    @Test func theDlssGroupNeverClaimsAnOverrideIsActive() {
        withDlssPreferencesPreserved {
            OPNStreamPreferences.saveDlssOverrides(requestedOverrides)
            let group = makeOverlay(entitlements: grantedEntitlements).nativeStatsDlssGroup
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
            let rows = makeOverlay(entitlements: grantedEntitlements).nativeStatsDlssGroup.rows
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
            let overrides = requestedOverrides.applyingAccess(grantedEntitlements)
            let rows = makeOverlay(entitlements: grantedEntitlements).nativeStatsDlssGroup.rows
            #expect(overrides.nextSessionRequestSummary == "SR \(rows[0].value)  ·  FG \(rows[1].value)  ·  RR \(rows[2].value)")
        }
    }

    @Test func concurrentLaunchSnapshotsIgnoreChangesToTheActiveAccountEntitlementMirror() {
        withDlssPreferencesPreserved {
            OPNStreamPreferences.saveDlssOverrides(requestedOverrides)
            let entitled = makeOverlay(entitlements: grantedEntitlements)
            let unentitled = makeOverlay()

            OPNStreamPreferences.saveDlssEntitlements(grantedEntitlements)
            #expect(entitled.nativeStatsDlssGroup.rows.map(\.value) == ["DLAA 100%", "Dynamic up to 4×", "Preset D"])
            #expect(unentitled.nativeStatsDlssGroup.rows.map(\.value) == ["In-game", "In-game", "In-game"])

            OPNStreamPreferences.clearDlssEntitlements()
            #expect(entitled.nativeStatsDlssGroup.rows.map(\.value) == ["DLAA 100%", "Dynamic up to 4×", "Preset D"])
            #expect(unentitled.nativeStatsDlssGroup.rows.map(\.value) == ["In-game", "In-game", "In-game"])
        }
    }

    @Test(arguments: [CGFloat(1.25), CGFloat(1.5)])
    func eachLaunchMembershipRendersAtNonDefaultInterfaceScales(_ scale: CGFloat) throws {
        try withDlssPreferencesPreserved {
            OPNStreamPreferences.saveDlssOverrides(requestedOverrides)
            let overlays = [
                ("entitled", makeOverlay(entitlements: grantedEntitlements)),
                ("unentitled", makeOverlay()),
            ]
            for (name, overlay) in overlays {
                let width = (NativeNVSTStatsPanel.width + 24) * scale
                let height = 220 * scale
                let content = NativeNVSTStatsPanel(transport: "NATIVE NVST", heroes: [], groups: [overlay.nativeStatsDlssGroup])
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .environment(\.opnUIScale, scale)
                    .opnInterfaceScale(scale)
                    .frame(width: width, height: height)
                    .background(Color.black)
                    .transaction { $0.disablesAnimations = true }
                let renderer = ImageRenderer(content: content)
                renderer.scale = 2
                let image = try #require(renderer.nsImage)
                let pixelTolerance = 1 / renderer.scale
                #expect(abs(image.size.width - width) < pixelTolerance)
                #expect(abs(image.size.height - height) < pixelTolerance)
                try writeSnapshot(image, name: "hud-dlss-\(name)-\(Int(scale * 100)).png")
            }
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

    private func makeOverlay(entitlements: DlssEntitlements = .none, applied: NvstDlssStateNotification? = nil) -> NativeNVSTStatsOverlay {
        let configuration = StreamLaunchConfiguration(
            title: "Game", applicationID: "100", accessToken: "test-token", accountLinked: true, selectedStore: "steam"
        ).snapshottingEntitlements(OPNLaunchEntitlements(dlss: entitlements), providerStreamingBaseURL: OPNGameService.defaultStreamingBaseUrl)
        return NativeNVSTStatsOverlay(
            stats: NativeNVSTStreamStatsModel(),
            applicationID: configuration.applicationID,
            detailLevel: .advanced,
            hdrModeText: "",
            appliedDlssState: applied,
            dlssEntitlements: configuration.launchEntitlements.dlss
        )
    }

    private func writeSnapshot(_ image: NSImage, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["OPN_SNAPSHOT_DIR"] else { return }
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }
}
