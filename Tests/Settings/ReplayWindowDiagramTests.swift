import AppKit
import SwiftUI
import Testing
@testable import OpenNOW

/// The one duration vocabulary Instant Replay's diagram and both of its sliders read, so a minute
/// never reads three ways across the card.
@MainActor
@Suite struct ReplayWindowDiagramTests {
    @Test func aSubMinuteClipReadsInSeconds() {
        #expect(ReplayWindowDiagram.durationText(seconds: 45) == "45 s")
        #expect(ReplayWindowDiagram.durationText(seconds: 10) == "10 s")
    }

    @Test func wholeMinutesDropTheirSeconds() {
        #expect(ReplayWindowDiagram.durationText(seconds: 60) == "1 min")
        #expect(ReplayWindowDiagram.durationText(seconds: 1_800) == "30 min")
    }

    @Test func aPartialMinuteKeepsBothParts() {
        #expect(ReplayWindowDiagram.durationText(seconds: 90) == "1 min 30 s")
    }

    @Test func anHourAndAHalfReadsBothUnits() {
        #expect(ReplayWindowDiagram.durationText(seconds: 3_600) == "1 h")
        #expect(ReplayWindowDiagram.durationText(seconds: 5_400) == "1 h 30 min")
        #expect(ReplayWindowDiagram.durationText(seconds: 7_200) == "2 h")
    }

    @Test func aNegativeDurationNeverReachesTheReader() {
        #expect(ReplayWindowDiagram.durationText(seconds: -5) == "0 s")
    }

    /// `AGENTS.md` asks every touched view to be looked at at a non-default interface scale. This is
    /// that check done where a person cannot be: each scale has to render, and the diagram has to
    /// grow with it — a constant left unscaled would hold its height flat.
    @Test func theDiagramRendersAndGrowsAtEveryInterfaceScale() throws {
        var heights: [CGFloat] = []
        for scale in [1.0, 1.25, 1.5] {
            let renderer = ImageRenderer(content: diagramOnCardSurface(scale: scale))
            let image = try #require(renderer.nsImage, "no render at scale \(scale)")
            #expect(image.size.width > 0)
            #expect(image.size.height > 0)
            heights.append(image.size.height)
            writeSnapshot(image, named: "replay-window-scale-\(scale)")
        }
        #expect(heights[0] < heights[1])
        #expect(heights[1] < heights[2])
    }

    /// On the card's own surface and padding: a bare render judges the track fill and the caption's
    /// descenders against transparency instead of what the reader sees.
    private func diagramOnCardSurface(scale: CGFloat) -> some View {
        ReplayWindowDiagram(windowSeconds: 7_200, clipSeconds: 45, uiScale: scale)
            .padding(.horizontal, OPNDesign.Spacing.large(scale: scale))
            .padding(.vertical, OPNDesign.Spacing.small(scale: scale))
            .frame(width: 520 * scale, alignment: .leading)
            .background(OPNDesign.Surface.panel)
    }

    /// Opt-in, the same way the menu-bar snapshots are: nothing is written on a normal run.
    private func writeSnapshot(_ image: NSImage, named name: String) {
        guard let directory = ProcessInfo.processInfo.environment["OPN_SNAPSHOT_DIR"],
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("\(name).png")
        try? png.write(to: url)
    }
}
