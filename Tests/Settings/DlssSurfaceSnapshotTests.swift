//  The DLSS surfaces rendered offscreen at every access state and interface scale, plus the beta
//  scope stated as data so a change to what wears the tag has to be deliberate.

import AppKit
import SwiftUI
import Testing
@testable import OpenNOW

@Suite struct DlssSurfaceSnapshotTests {
    private let fullEntitlements = DlssEntitlements(
        superResolution: DlssCapability(isEntitled: true, isUpsell: false),
        frameGeneration: DlssCapability(isEntitled: true, isUpsell: false),
        rayReconstruction: DlssCapability(isEntitled: true, isUpsell: false),
        frameGenerationMultipliers: [3, 4]
    )

    private var configuredOverrides: DlssOverrides {
        DlssOverrides(
            superResolutionMode: DlssSuperResolutionMode.custom.rawValue,
            superResolutionModel: 2,
            superResolutionScale: 80,
            rayReconstructionModel: 5,
            frameGenerationMode: DlssFrameGenerationMode.dynamic.rawValue,
            frameGenerationModel: 1,
            frameGenerationMultiplier: 4
        )
    }

    @Test func theBetaTagScopeIsTheCardAndTheSectionOnly() {
        #expect(DlssBetaScope.isTagged(DlssBetaScope.cardTitle))
        #expect(DlssBetaScope.isTagged(DlssBetaScope.sectionTitle))
        #expect(DlssBetaScope.cardHeadingAccessibilityLabel == "Cloud DLSS Overrides, Beta")
        #expect(DlssBetaScope.sectionHeadingAccessibilityLabel == "DLSS Compatibility, Beta")
        #expect(DlssBetaScope.taggedSurfaces.count == 2)
        #expect(!DlssBetaScope.untaggedSurfaces.isEmpty)
        #expect(!DlssBetaScope.isTagged("Video destination"))
        #expect(!DlssBetaScope.isTagged(DlssBetaScope.chipLabel))
    }

    @MainActor @Test func theOverridesCardRendersEveryAccessStateAtEveryScale() throws {
        let memberships: [DlssMembershipState] = [
            .signedOut,
            .loading,
            .unavailable,
            .loaded(.none),
            .loaded(fullEntitlements),
        ]
        for membership in memberships {
            let image = try render(overridesCard(scale: 1.0, membership: membership))
            #expect(image.size.width > 0)
            #expect(image.size.height > 0)
        }
        for scale in [1.25, 1.5] {
            let image = try render(overridesCard(scale: scale, membership: .loaded(fullEntitlements)))
            #expect(image.size.height > 0, "no render at scale \(scale)")
        }
    }

    @MainActor @Test func theOverridesCardGrowsWithTheInterfaceScale() throws {
        let normal = try render(overridesCard(scale: 1.0, membership: .loaded(fullEntitlements), width: 1360))
        let scaled = try render(overridesCard(scale: 1.5, membership: .loaded(fullEntitlements), width: 1360 * 1.5))
        // Every constant in the card scales, so the taller interface must produce a taller card.
        // A constant left unscaled shows up here as a ratio below the scale factor.
        let ratio = scaled.size.height / normal.size.height
        #expect(ratio > 1.35, "the card is not scaling with the interface: ratio \(ratio)")
    }

    @MainActor @Test func theOverridesCardRendersInANarrowColumn() throws {
        let image = try render(overridesCard(scale: 1.0, membership: .loaded(fullEntitlements), width: 520))
        #expect(image.size.width > 0)
    }

    @MainActor @Test func theCompatibilitySectionRendersEveryState() throws {
        let matched = DlssMatchOutcome.matched(DlssGameSupport(superResolution: .native, frameGeneration: .override, multiFrameGeneration: DlssMultiFrameGeneration(maxMultiplier: 6), rayReconstruction: nil, dlaa: .native))
        let listStates: [OPNDlssCompatibilityService.ListState] = [.loading, .ready, .refreshing, .refreshFailed, .stale, .unavailable]
        for listState in listStates {
            let image = try render(compatibilitySection(listState: listState, outcome: matched, membership: .loaded(fullEntitlements)))
            #expect(image.size.width > 0)
            #expect(image.size.height > 0)
        }
        for outcome in [DlssMatchOutcome.listedWithoutSupport, .unknown] {
            let image = try render(compatibilitySection(listState: .ready, outcome: outcome, membership: .loaded(fullEntitlements)))
            #expect(image.size.height > 0)
        }
    }

    @MainActor @Test func theCompatibilitySectionRendersAtEveryScale() throws {
        for scale in [1.0, 1.25, 1.5] {
            let image = try render(compatibilitySection(listState: .ready, outcome: .matched(DlssGameSupport(superResolution: .native)), membership: .signedOut, scale: scale))
            #expect(image.size.height > 0)
        }
    }

    // MARK: - Fixtures

    @Test func theOverridesCardLabelsEachControlOnce() throws {
        let source = try String(contentsOf: Self.overridesCardSourceURL, encoding: .utf8)
        let titles = try Self.controlTitles(in: source)
        #expect(titles.count > 5, "the source scan found almost nothing; the pattern has drifted")
        // A heading that repeats the label of the control under it reads as two settings, which is
        // exactly how the card shipped once.
        let repeated = titles.filter { title, count in count > 1 }.keys.sorted()
        #expect(repeated.isEmpty, "a control label is written more than once: \(repeated)")
    }

    private static var overridesCardSourceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("View/Settings/SettingsDlssViews.swift")
    }

    /// Every literal label a control in the card is given, with how many times it is written.
    private static func controlTitles(in source: String) throws -> [String: Int] {
        let expression = try NSRegularExpression(pattern: #"title:\s*"([^"]+)""#)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return expression.matches(in: source, range: range).reduce(into: [:]) { counts, match in
            guard let titleRange = Range(match.range(at: 1), in: source) else { return }
            counts[String(source[titleRange]), default: 0] += 1
        }
    }

    @MainActor
    private func overridesCard(scale: CGFloat, membership: DlssMembershipState, width: CGFloat? = nil) -> some View {
        let model = makeCatalogViewModelForTesting()
        model.dlssOverrides = configuredOverrides
        model.dlssMembershipState = membership
        return CloudDlssOverridesCard(viewModel: model, uiScale: scale)
            .frame(width: width ?? 1360 * scale, alignment: .leading)
            .background(OPNDesign.Surface.panel)
            .environment(\.opnSettingsNarrowRows, false)
    }

    @MainActor
    private func compatibilitySection(
        listState: OPNDlssCompatibilityService.ListState,
        outcome: DlssMatchOutcome,
        membership: DlssMembershipState,
        scale: CGFloat = 1.0
    ) -> some View {
        let model = makeCatalogViewModelForTesting()
        model.dlssMembershipState = membership
        model.dlssCompatibilityGameKey = "test-game"
        model.isDlssCompatibilityWaiting = listState == .loading
        model.dlssCompatibility = DlssCompatibilityPresentation.make(
            OPNDlssCompatibilityService.Snapshot(
                outcome: outcome,
                listState: listState,
                lastSuccessfulCheck: Date(timeIntervalSince1970: 1_700_000_000),
                isLoadedFromCache: true
            )
        )
        return DlssCompatibilitySection(viewModel: model, uiScale: scale)
            .frame(width: 760 * scale, alignment: .leading)
            .background(OPNDesign.Surface.app)
            .environment(\.opnUIScale, scale)
    }

    @MainActor
    private func render(_ view: some View) throws -> NSImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return try #require(renderer.nsImage, "no render")
    }
}
