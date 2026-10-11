import AppKit
import SwiftUI
import Testing
@testable import OpenNOW

/// The stream HUD's (⌘G) dock under the Liquid Glass preference: the material must not move the dock,
/// and it has to stay legible over bright video — which only a composited capture can show.
@MainActor
@Suite(.serialized) struct StreamHUDGlassTests {
    private static let requestedOnSupportedMac = OPNLiquidGlassPolicy(
        isRequested: true, isSupported: true, isReduceTransparency: false
    )

    private static let stageSize = CGSize(width: 900, height: 620)

    /// The dock's empty interior: inside its 344pt width, below the section rows and above the footer.
    private static let dockInterior = CGRect(x: 0.02, y: 0.48, width: 0.34, height: 0.42)

    /// The material replaces the dock's fill, so it cannot change the dock's own geometry.
    @Test func theDockKeepsItsGeometryWithGlassOn() throws {
        let flat = try #require(GlassEvidence.renderOffscreen(dock(policy: .off)), "the flat dock did not render")
        let glass = try #require(GlassEvidence.renderOffscreen(dock(policy: Self.requestedOnSupportedMac)), "the glass dock did not render")
        #expect(flat.size == glass.size, "the material changed the dock's layout")
        #expect(glass.size == Self.stageSize)
    }

    /// Composited: the dock's fill is drawn by the window server when the material is on, so an
    /// offscreen render cannot show it. Writes both modes for a person to judge readability against.
    @Test(.enabled(if: GlassEvidence.captureDirectory != nil)) func theDockDrawsGlassOverBrightVideo() async throws {
        let glass = try await GlassEvidence.captureInWindow(
            dock(policy: Self.requestedOnSupportedMac),
            over: BrightGlassBackdrop(),
            size: Self.stageSize,
            named: "stream-hud-dock-glass.png"
        )
        let flat = try await GlassEvidence.captureInWindow(
            dock(policy: .off),
            over: BrightGlassBackdrop(),
            size: Self.stageSize,
            named: "stream-hud-dock-flat.png"
        )

        let difference = glass.meanAbsoluteDifference(from: flat, in: GlassCapture.wholeImage)
        #expect(difference > 2, "the HUD dock did not follow the Liquid Glass policy: mean delta \(difference)")

        // The dock's dimmest tier is Text Tertiary at 0.52 white, which needs a background below
        // ~0.07 relative luminance to clear 4.5:1. Measured with the scrim in place, not assumed.
        let backgroundLuminance = glass.medianLuminance(in: Self.dockInterior)
        #expect(
            backgroundLuminance < 0.08,
            "the dock is too bright to read over video: median background luminance \(backgroundLuminance)"
        )
    }

    /// The real dock with representative section content, built from the same theme tokens the live
    /// sections use so the contrast in the capture is the contrast a reader gets.
    private func dock(policy: OPNLiquidGlassPolicy) -> some View {
        StreamUnifiedSidebar(
            title: "Cyberpunk 2077",
            closeAction: {},
            sessionLimit: StreamSessionLimitUpdate(remainingSeconds: 3120).flatMap { StreamSessionSidebarLimit(update: $0) },
            powerAction: {},
            isPowerFocused: false,
            customizeAction: {},
            shortcutsHelpAction: {},
            shortcutsHelpLabel: "Shortcuts"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Text("QUALITY")
                    .font(.streamFont(size: 10, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(StreamHUDTheme.textTertiary)
                ForEach(["Balanced", "1080p · 60 fps", "H.264 · 8-bit"], id: \.self) { row in
                    HStack {
                        Text(row)
                            .font(.streamFont(size: 13, weight: .medium))
                            .foregroundStyle(StreamHUDTheme.textPrimary)
                        Spacer(minLength: 0)
                        Text("Auto")
                            .font(.streamFont(size: 12, weight: .bold))
                            .foregroundStyle(StreamHUDTheme.textSecondary)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(OPNCornerShape(role: .control).fill(Color.white.opacity(0.075)))
                }
                Text("STATISTICS")
                    .font(.streamFont(size: 10, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(StreamHUDTheme.textTertiary)
                Text("Decode 4.2 ms · 60 fps · 42 Mbps")
                    .font(.streamFont(size: 12, weight: .medium))
                    .foregroundStyle(StreamHUDTheme.textSecondary)
            }
        }
        .frame(width: Self.stageSize.width, height: Self.stageSize.height)
        .environment(\.opnLiquidGlass, policy)
    }
}
