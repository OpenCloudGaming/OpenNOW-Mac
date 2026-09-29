import AppKit
import SwiftUI
import Testing
@testable import OpenNOW

/// The chip containment hardening: an oversized chip is told the line width it actually has, and
/// the label responds by shrinking then ellipsizing. Measured through a hosted view because the
/// overflow was a drawing overflow - the row's own frame was always inside the card.
@MainActor
@Suite("SettingsFlowLayout containment")
struct SettingsFlowLayoutContainmentTests {
    /// One chip, wider than any container under test. 324pt is the widest localized label the spec
    /// works through; the fixed string below is a safe stand-in at every scale.
    private static let oversizedLabel = "Close, Menu Bar Only, Full Screen, Notification"

    @Test(
        "a chip wider than its container is clamped, not drawn past it",
        .disabled(if: CIWindowTestGate.isHostedRunner, Comment(rawValue: CIWindowTestGate.skipReason)),
        arguments: [80, 150, 175, 240],
        [1.0, 2.0]
    )
    func oversizedChipStaysInsideItsContainer(containerWidth: CGFloat, uiScale: CGFloat) throws {
        let measurement = ChipMeasurement()
        let hosting = NSHostingView(
            rootView: OversizedChipHarness(
                containerWidth: containerWidth,
                uiScale: uiScale,
                label: Self.oversizedLabel,
                measurement: measurement
            )
        )
        hosting.frame = CGRect(x: 0, y: 0, width: containerWidth, height: 200)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        pumpRunLoop()

        let chipFrame = try #require(measurement.chipFrame, "the chip reported no frame")
        #expect(chipFrame.maxX <= containerWidth + 0.5, "chip drew to \(chipFrame.maxX), past \(containerWidth)")
        #expect(abs(chipFrame.height - 32 * uiScale) < 0.5, "chip height \(chipFrame.height) != \(32 * uiScale)")
    }

    /// The harness reads geometry through the same named coordinate space the flow layout places
    /// into, so "inside the container" means exactly that.
    private func pumpRunLoop(_ iterations: Int = 6) {
        for _ in 0..<iterations {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
}

@MainActor
private final class ChipMeasurement {
    var chipFrame: CGRect?
}

/// Mirrors the production chip's sizing chain: the flow layout places the button label, so the
/// proposal reaches the padded, height-pinned label and its `Text` response is what we measure.
@MainActor
private struct OversizedChipHarness: View {
    let containerWidth: CGFloat
    let uiScale: CGFloat
    let label: String
    let measurement: ChipMeasurement

    var body: some View {
        SettingsFlowLayout(spacing: 8 * uiScale) {
            Text(label)
                .font(.settingsFont(size: 12 * uiScale, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 12 * uiScale)
                .frame(height: 32 * uiScale)
                .background(OPNDesign.Fill.neutral(0.07))
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named("containment-harness"))
                } action: { frame in
                    measurement.chipFrame = frame
                }
        }
        .frame(width: containerWidth, alignment: .leading)
        .coordinateSpace(name: "containment-harness")
        .environment(\.opnSettingsNarrowRows, false)
        .environment(\.opnSettingsCardWidth, containerWidth)
    }
}
