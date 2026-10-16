//  The exact copy and treatment every compatibility/freshness/loading/access combination produces.

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
        let presentation = DlssCompatibilityPresentation.make(snapshot(.loading, outcome: .unknown), locale: locale)
        #expect(presentation.statusText == "Checking DLSS compatibility…")
        #expect(presentation.statusSupportingText == "Looking up this game in NVIDIA's DLSS games list.")
        #expect(presentation.statusShowsProgress)
        #expect(presentation.support == nil)
        #expect(presentation.compactChip == nil)
        #expect(presentation.freshnessText.isEmpty)
        #expect(presentation.sourceFooter == "Source: NVIDIA's DLSS games list")
    }

    @Test func noUsableDataAndAFailedFetchMakesNoUnsupportedClaim() {
        let presentation = DlssCompatibilityPresentation.make(snapshot(.unavailable, outcome: .unknown), locale: locale)
        #expect(presentation.statusText == "Compatibility information unavailable.")
        #expect(presentation.statusSupportingText.isEmpty)
        #expect(!presentation.statusShowsProgress)
        #expect(presentation.compactChip == nil)
        #expect(!presentation.statusText.lowercased().contains("unsupported"))
    }

    @Test func aCachedCopySaysSoAndCarriesTheCacheHelp() {
        let presentation = DlssCompatibilityPresentation.make(
            snapshot(.ready, outcome: .matched(support), loadedFromCache: true),
            locale: locale
        )
        #expect(presentation.freshnessText.hasPrefix("Cached · Checked "))
        #expect(presentation.freshnessHelpText == "Compatibility information is saved for up to 24 hours before a refresh is attempted.")
        #expect(!presentation.freshnessShowsWarning)
        #expect(presentation.support == support)
        #expect(presentation.compactChip?.label == "DLSS")
        #expect(presentation.compactChip?.accessibilityLabel == "DLSS compatibility information available.")
        #expect(presentation.compactChip?.isStale == false)
    }

    @Test func aFreshlyFetchedResultDropsTheCachedPrefix() {
        let presentation = DlssCompatibilityPresentation.make(
            snapshot(.ready, outcome: .matched(support), loadedFromCache: false),
            locale: locale
        )
        #expect(presentation.freshnessText.hasPrefix("Checked "))
        #expect(!presentation.freshnessText.hasPrefix("Cached"))
        #expect(presentation.freshnessHelpText.isEmpty)
    }

    @Test func aStaleCopyKeepsItsChipAndWarnsWhileUpdating() {
        let presentation = DlssCompatibilityPresentation.make(
            snapshot(.refreshing, outcome: .matched(support), loadedFromCache: true),
            locale: locale
        )
        #expect(presentation.freshnessText == "Saved information · Updating…")
        #expect(presentation.freshnessShowsProgress)
        #expect(presentation.freshnessShowsWarning)
        #expect(presentation.freshnessSupportingText.hasPrefix("Last checked "))
        #expect(presentation.freshnessSupportingText.hasSuffix("Compatibility information may have changed."))
        #expect(presentation.support == support)
        #expect(presentation.compactChip?.isStale == true)
        #expect(presentation.compactChip?.accessibilityLabel == "DLSS compatibility information may be outdated.")
    }

    @Test func aFailedRefreshKeepsTheSavedTableAndSaysTheUpdateIsUnavailable() {
        let presentation = DlssCompatibilityPresentation.make(
            snapshot(.refreshFailed, outcome: .matched(support), loadedFromCache: true),
            locale: locale
        )
        #expect(presentation.freshnessText == "Saved information · Update unavailable")
        #expect(presentation.freshnessShowsWarning)
        #expect(!presentation.freshnessShowsProgress)
        #expect(presentation.support == support)
        #expect(presentation.compactChip?.isStale == true)
    }

    @Test func aStaleCopyWithNothingInFlightStillCarriesTheStaleLine() {
        let presentation = DlssCompatibilityPresentation.make(
            snapshot(.stale, outcome: .matched(support), loadedFromCache: true),
            locale: locale
        )
        #expect(presentation.freshnessText.hasPrefix("Cached · Checked "))
        #expect(presentation.freshnessSupportingText.hasPrefix("Last checked "))
        #expect(!presentation.freshnessShowsWarning)
    }

    @Test func aListedRowWithoutDlssReadsAsUnknownNotAsUnsupported() {
        let presentation = DlssCompatibilityPresentation.make(
            snapshot(.ready, outcome: .listedWithoutSupport, loadedFromCache: false),
            locale: locale
        )
        #expect(presentation.statusText == "DLSS compatibility unknown")
        #expect(presentation.statusSupportingText == "We couldn't confirm this game's DLSS compatibility from NVIDIA's list. This does not mean DLSS is unsupported.")
        #expect(presentation.support == nil)
        #expect(presentation.compactChip == nil)
        // The freshness footer is independent of the feature labels.
        #expect(presentation.freshnessText.hasPrefix("Checked "))
    }

    @Test func anUnlistedGameReadsTheSameWayAsARowWithNoDlss() {
        let presentation = DlssCompatibilityPresentation.make(
            snapshot(.ready, outcome: .unknown, loadedFromCache: false),
            locale: locale
        )
        #expect(presentation.statusText == "DLSS compatibility unknown")
        #expect(presentation.compactChip == nil)
    }

    @Test func perFeatureLabelsUseTheExactCopy() {
        #expect(support.support(for: .superResolution)?.label == "Built into game")
        #expect(support.support(for: .frameGeneration)?.label == "Available via override")
        #expect(support.support(for: .rayReconstruction) == nil)
        #expect(DlssSupport.native.helpText == "NVIDIA lists this feature as built into the game.")
        #expect(DlssSupport.override.helpText == "NVIDIA lists an override for this feature. Requires a supported cloud rig and eligible membership.")
    }

    @Test func theCheckingPlaceholderMatchesTheLoadingState() {
        #expect(DlssCompatibilityPresentation.checking.statusText == DlssCompatibilityPresentation.loadingText)
        #expect(DlssCompatibilityPresentation.checking.statusShowsProgress)
        #expect(DlssCompatibilityPresentation.checking.compactChip == nil)
    }

    private func snapshot(
        _ listState: OPNDlssCompatibilityService.ListState,
        outcome: DlssMatchOutcome,
        loadedFromCache: Bool = false
    ) -> OPNDlssCompatibilityService.Snapshot {
        OPNDlssCompatibilityService.Snapshot(
            outcome: outcome,
            listState: listState,
            lastSuccessfulCheck: checkedAt,
            loadedFromCache: loadedFromCache
        )
    }
}
