import AppKit
import SwiftUI
import Testing
@testable import OpenNOW

/// The app-shell modal panels under the Liquid Glass preference: the material has to reach them, and
/// the message text has to stay legible over the scrim and whatever sits behind it.
@MainActor
@Suite(.serialized) struct OPNModalGlassTests {
    private static let requestedOnSupportedMac = OPNLiquidGlassPolicy(
        isRequested: true, isSupported: true, isReduceTransparency: false
    )

    private static let stageSize = CGSize(width: 900, height: 620)

    /// The panel is centred at a fixed 440pt width; this is the band its message sits in.
    private static let panelBody = CGRect(x: 0.26, y: 0.46, width: 0.48, height: 0.2)

    /// The panel's message and footer sit on the material, so it cannot change the panel's geometry.
    @Test func theConfirmationPanelKeepsItsGeometryWithGlassOn() throws {
        let flat = try #require(GlassEvidence.renderOffscreen(panel(policy: .off)), "the flat panel did not render")
        let glass = try #require(GlassEvidence.renderOffscreen(panel(policy: Self.requestedOnSupportedMac)), "the glass panel did not render")
        #expect(flat.size == glass.size, "the material changed the panel's layout")
    }

    /// Composited: the panel's fill is drawn by the window server when the material is on, so an
    /// offscreen render cannot show it. Writes both modes for a person to judge readability against.
    @Test(.enabled(if: GlassEvidence.captureDirectory != nil)) func theConfirmationPanelDrawsGlass() async throws {
        let glass = try await GlassEvidence.captureInWindow(
            panel(policy: Self.requestedOnSupportedMac),
            over: BrightGlassBackdrop(),
            size: Self.stageSize,
            named: "confirmation-modal-glass.png"
        )
        let flat = try await GlassEvidence.captureInWindow(
            panel(policy: .off),
            over: BrightGlassBackdrop(),
            size: Self.stageSize,
            named: "confirmation-modal-flat.png"
        )

        // The panel is small in the stage, so the comparison is over the panel's own body: a
        // whole-image delta hides a modal that stopped drawing the material.
        let difference = glass.meanAbsoluteDifference(from: flat, in: Self.panelBody)
        #expect(difference > 4, "the modal did not follow the Liquid Glass policy: mean delta \(difference)")

        // The message is Text Secondary at 0.72 white. The median is the body's background — a
        // percentile above it lands on the message's own glyphs and measures the text, not the panel.
        let backgroundLuminance = glass.medianLuminance(in: Self.panelBody)
        #expect(
            backgroundLuminance < 0.05,
            "the panel body is too bright to read the message: median background luminance \(backgroundLuminance)"
        )
    }

    /// The real confirmation panel, scrim and all; the capture supplies the backdrop behind it.
    private func panel(policy: OPNLiquidGlassPolicy) -> some View {
        OPNConfirmationPanel(
            eyebrow: "END SESSION",
            title: "End this session?",
            message: "The game closes on the server and anything unsaved is lost. You can start it again from your library at any time.",
            actions: [
                OPNConfirmationAction("End session", role: .destructive) {},
                OPNConfirmationAction("Cancel", role: .cancel) {},
            ],
            dismiss: {}
        )
        .frame(width: Self.stageSize.width, height: Self.stageSize.height)
        .environment(\.opnUIScale, 1)
        .environment(\.opnLiquidGlass, policy)
    }
}
