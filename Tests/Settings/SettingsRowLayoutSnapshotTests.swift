import AppKit
import SwiftUI
import Testing
@testable import OpenNOW

/// The reported Session Ready card, rendered at the acceptance widths and interface scales so the
/// before and after layouts can be compared by looking at them. The assertions gate the test; the
/// PNGs are written only when `OPN_SNAPSHOT_DIR` names a directory.
@MainActor
@Suite(.serialized, .streamLifecycleExclusive)
struct SettingsRowLayoutSnapshotTests {
    nonisolated private static var captureDirectory: String? {
        ProcessInfo.processInfo.environment["OPN_SNAPSHOT_DIR"]
    }

    @Test("the Session Ready card renders at every acceptance width")
    func sessionReadyCardRendersAcrossWidths() throws {
        for scale in [CGFloat(1.0), 2.0] {
            for cardWidth in [CGFloat(600), 900, 1216] {
                let card = fixture(cardWidth: cardWidth, uiScale: scale)
                let renderer = ImageRenderer(content: card)
                renderer.scale = 2
                renderer.proposedSize = ProposedViewSize(width: cardWidth, height: nil)
                let image = try #require(
                    renderer.nsImage,
                    "card \(Int(cardWidth)) at uiScale \(scale) did not render"
                )
                #expect(image.size.width >= cardWidth, "card collapsed horizontally")
                #expect(image.size.height > 80 * scale, "card collapsed vertically")
                try write(image, named: "settings-session-ready-\(Int(cardWidth))-x\(scale).png")
            }
        }
    }

    @ViewBuilder private func fixture(cardWidth: CGFloat, uiScale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 16 * uiScale) {
            SettingsCard(title: "Session Ready", uiScale: uiScale) {
                SettingsOptionRow(
                    title: "When the Stream Is Ready",
                    subtitle: "While OpenNOW is in the background and a queued or provisioning session becomes ready: post a system notification, bring OpenNOW to the front automatically, bring it forward and put the stream in full screen, or do nothing.",
                    options: ["Off", "Notification", "Bring to Front", "Full Screen"],
                    selectedIndex: 1,
                    uiScale: uiScale
                ) { _ in }
            }
            SettingsCard(title: "Session Insights", uiScale: uiScale) {
                SettingsToggleRow(
                    title: "Session Insights",
                    subtitle: "Show a summary of what a stream measured about itself — how long it ran, its shape, and any dropped frames, decode errors or recoveries — when the stream ends. The summary carries a Don't show this again option.",
                    isOn: true,
                    uiScale: uiScale
                ) { _ in }
            }
        }
        .padding(24 * uiScale)
        .frame(width: cardWidth, alignment: .leading)
        .background(SettingsSurfaceBackground())
        .environment(
            \.opnSettingsNarrowRows,
            SettingsLayoutMetrics.usesNarrowRows(cardWidth: cardWidth, uiScale: uiScale)
        )
        .environment(\.opnSettingsCardWidth, cardWidth)
    }

    private func write(_ image: NSImage, named name: String) throws {
        guard let directory = Self.captureDirectory,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }
}
