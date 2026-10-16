//  The exact copy and treatment every compatibility/freshness/loading combination produces.

import Foundation
import Testing
@testable import OpenNOW

@Suite struct DlssCompatibilityPresentationTests {
    private let locale = Locale(identifier: "en_US_POSIX")
    private let checkedAt = Date(timeIntervalSince1970: 1_700_000_000)
    private let support = DlssGameSupport(
        superResolution: .native,
        frameGeneration: .override,
        multiFrameGeneration: DlssMultiFrameGeneration(maxMultiplier: 6),
        rayReconstruction: nil,
        dlaa: .native
    )

    @Test func noSavedDataAndStillLookingShowsTheCheckingStatusAndNoChip() {
        let presentation = make(.loading, outcome: .unknown)
        #expect(presentation.statusText == "Checking DLSS compatibility…")
        #expect(presentation.statusSupportingText == "Looking up this game in NVIDIA's DLSS games list.")
        #expect(presentation.statusGlyph == .progress)
        #expect(presentation.gameSupport == nil)
        #expect(presentation.compactChip == nil)
        #expect(presentation.freshnessText.isEmpty)
        #expect(presentation.sourceFooter == "Source: NVIDIA's DLSS games list")
    }

    @Test func noUsableDataAndAFailedFetchMakesNoUnsupportedClaim() {
        let presentation = make(.unavailable, outcome: .unknown)
        #expect(presentation.statusText == "Compatibility information unavailable.")
        #expect(presentation.statusSupportingText.isEmpty)
        #expect(presentation.statusGlyph == .info)
        #expect(presentation.compactChip == nil)
        #expect(!presentation.statusText.lowercased().contains("unsupported"))
    }

    @Test func aCachedCopySaysSoAndCarriesTheCacheHelp() {
        let presentation = make(.ready, outcome: .matched(support), isLoadedFromCache: true)
        #expect(presentation.freshnessText.hasPrefix("Cached · Checked "))
        #expect(presentation.freshnessHelpText == "Compatibility information is saved for up to 24 hours before a refresh is attempted.")
        #expect(presentation.freshnessGlyph == .clock)
        #expect(presentation.gameSupport == support)
        #expect(presentation.compactChip?.label == "DLSS")
        #expect(presentation.compactChip?.accessibilityLabel == "DLSS compatibility information available.")
        #expect(presentation.compactChip?.isStale == false)
    }

    @Test func aFreshlyFetchedResultDropsTheCachedPrefix() {
        let presentation = make(.ready, outcome: .matched(support), isLoadedFromCache: false)
        #expect(presentation.freshnessText.hasPrefix("Checked "))
        #expect(!presentation.freshnessText.hasPrefix("Cached"))
        #expect(presentation.freshnessHelpText.isEmpty)
    }

    @Test func aStaleCopyKeepsItsChipAndWarnsWhileUpdating() {
        let presentation = make(.refreshing, outcome: .matched(support), isLoadedFromCache: true)
        #expect(presentation.freshnessText == "Saved information · Updating…")
        #expect(presentation.freshnessGlyph == .progress)
        #expect(presentation.freshnessSupportingText.hasPrefix("Last checked "))
        #expect(presentation.freshnessSupportingText.hasSuffix("Compatibility information may have changed."))
        #expect(presentation.gameSupport == support)
        #expect(presentation.compactChip?.isStale == true)
        #expect(presentation.compactChip?.accessibilityLabel == "DLSS compatibility information may be outdated.")
    }

    @Test func aFailedRefreshKeepsTheSavedTableAndSaysTheUpdateIsUnavailable() {
        let presentation = make(.refreshFailed, outcome: .matched(support), isLoadedFromCache: true)
        #expect(presentation.freshnessText == "Saved information · Update unavailable")
        #expect(presentation.freshnessGlyph == .warning)
        #expect(presentation.gameSupport == support)
        #expect(presentation.compactChip?.isStale == true)
    }

    @Test func aStaleCopyWithNothingInFlightStillCarriesTheStaleLine() {
        let presentation = make(.stale, outcome: .matched(support), isLoadedFromCache: true)
        #expect(presentation.freshnessText.hasPrefix("Cached · Checked "))
        #expect(presentation.freshnessSupportingText.hasPrefix("Last checked "))
        #expect(presentation.freshnessGlyph == .clock)
    }

    @Test func aListedRowWithoutDlssReadsAsUnknownNotAsUnsupported() {
        let presentation = make(.ready, outcome: .listedWithoutSupport)
        #expect(presentation.statusText == "DLSS compatibility unknown")
        #expect(presentation.statusSupportingText == "We couldn't confirm this game's DLSS compatibility from NVIDIA's list. This does not mean DLSS is unsupported.")
        #expect(presentation.statusGlyph == .question)
        #expect(presentation.gameSupport == nil)
        #expect(presentation.compactChip == nil)
        // The freshness footer is independent of the feature labels.
        #expect(presentation.freshnessText.hasPrefix("Checked "))
    }

    @Test func anUnlistedGameReadsTheSameWayAsARowWithNoDlss() {
        let presentation = make(.ready, outcome: .unknown)
        #expect(presentation.statusText == "DLSS compatibility unknown")
        #expect(presentation.compactChip == nil)
    }

    @Test func perFeatureLabelsUseTheExactCopy() {
        #expect(support.reportedSupport(for: .superResolution)?.label == "Built into game")
        #expect(support.reportedSupport(for: .frameGeneration)?.label == "Available via override")
        #expect(support.reportedSupport(for: .rayReconstruction) == nil)
        #expect(DlssSupport.native.helpText == "NVIDIA lists this feature as built into the game.")
        #expect(DlssSupport.override.helpText == "NVIDIA lists an override for this feature. Requires a supported cloud rig and eligible membership.")
    }

    @Test func theCheckingPlaceholderMatchesTheLoadingState() {
        #expect(DlssCompatibilityPresentation.checking.statusText == DlssCompatibilityPresentation.loadingText)
        #expect(DlssCompatibilityPresentation.checking.statusGlyph == .progress)
        #expect(DlssCompatibilityPresentation.checking.compactChip == nil)
    }

    private func make(
        _ listState: OPNDlssCompatibilityService.ListState,
        outcome: DlssMatchOutcome,
        isLoadedFromCache: Bool = false
    ) -> DlssCompatibilityPresentation {
        DlssCompatibilityPresentation.make(
            OPNDlssCompatibilityService.Snapshot(
                outcome: outcome,
                listState: listState,
                lastSuccessfulCheck: checkedAt,
                isLoadedFromCache: isLoadedFromCache
            ),
            locale: locale
        )
    }
}
