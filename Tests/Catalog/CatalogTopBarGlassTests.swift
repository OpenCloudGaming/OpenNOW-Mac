import AppKit
import SwiftUI
import Testing
@testable import OpenNOW

/// The catalog top bar's opt-in Liquid Glass: the material must not move the bar, and the Remote
/// Co-Op BETA badge has to stay readable above a glass plate.
@MainActor
@Suite(.serialized) struct CatalogTopBarGlassTests {
    private static let barWidth: CGFloat = 1100

    /// The trigger carries its own padding in both modes, so the material cannot resize the bar.
    @Test func theBarKeepsItsGeometryWithGlassOn() throws {
        OPNDesign.applyTheme(accent: .cloudGreen, appearance: .dark, systemColorScheme: .dark)
        let flat = try #require(GlassEvidence.renderOffscreen(topBar(policy: .off)), "the flat bar did not render")
        let glass = try #require(GlassEvidence.renderOffscreen(topBar(policy: .requestedOnSupportedMac)), "the glass bar did not render")
        #expect(flat.size == glass.size, "the material changed the bar's layout")
        #expect(glass.size.height == CatalogVendorLayout.appBarHeight(scale: 1))
    }

    /// Composited, because the window server draws the material: the badge has to read above the plate.
    /// A `GlassEffectContainer` around the icon row composites its glass over the badge and buries it.
    @Test(.enabled(if: GlassEvidence.captureDirectory != nil)) func theRemoteCoOpBadgeReadsAboveTheGlass() async throws {
        let capture = try await GlassEvidence.captureInWindow(
            topBar(policy: .requestedOnSupportedMac),
            over: BrightGlassBackdrop(),
            size: CGSize(width: Self.barWidth, height: CatalogVendorLayout.appBarHeight(scale: 1)),
            named: "catalog-top-bar-glass.png"
        )

        let badgePixels = capture.greenDominantPixelCount(in: GlassCapture.wholeImage, threshold: 60)
        #expect(badgePixels >= 100, "the BETA badge is buried under the plate: \(badgePixels) accent-green pixels")
    }

    /// The bar as the window builds it, with the Remote Co-Op entry point on so the badged plate is
    /// drawn at all.
    private func topBar(policy: OPNLiquidGlassPolicy) -> some View {
        let viewModel = makeCatalogViewModelForTesting()
        viewModel.remoteCoOpPreferences.isEnabled = true
        return CatalogTopBar(
            viewModel: viewModel,
            showsMainMenu: .constant(false),
            showsAccountMenu: .constant(false),
            onSwitch: { _ in },
            onSignOut: { _ in },
            onForget: { _ in }
        )
        .frame(width: Self.barWidth, height: CatalogVendorLayout.appBarHeight(scale: 1))
        .environment(\.opnUIScale, 1)
        .environment(\.opnLiquidGlass, policy)
    }
}
