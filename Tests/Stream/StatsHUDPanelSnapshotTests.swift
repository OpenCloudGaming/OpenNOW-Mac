import SwiftUI
import Testing
@testable import OpenNOW

/// Renders the whole stats panel offscreen from sample values. `ImageRenderer` needs no screen and
/// no capture permission, and a desktop grab of a live stream window comes back black, so this is
/// the only way to look at the panel's layout - in particular at the two details long enough to
/// take the wrapped row, and at the two leaner levels that drop rows rather than wrap them.
@Suite struct StatsHUDPanelSnapshotTests {
    private static var heroes: [NativeNVSTStatsPanel.Hero] {
        [
            .init(label: "GAME", value: "120", unit: "fps", color: StreamHUDTheme.accent),
            .init(label: "STREAM", value: "120", unit: "fps", color: StreamHUDTheme.textPrimary),
            .init(label: "LATENCY", value: "5", unit: "ms", color: StreamHUDTheme.accent),
        ]
    }

    private static var sample: NativeNVSTStatsPanel {
        NativeNVSTStatsPanel(
            transport: "NATIVE NVST",
            heroes: heroes,
            groups: [
                .init(label: "NETWORK", rows: [
                    .init(label: "Frame Loss", value: "0", detail: "(2 Total)", color: StreamHUDTheme.accent),
                    .init(label: "Packet Loss", value: "0.0%", detail: "(89 Total)", color: StreamHUDTheme.accent),
                    .init(label: "Bandwidth Used", value: "3.2", detail: "Mbps of 150"),
                    .init(label: "Jitter", value: "0.2", detail: "ms"),
                ]),
                .init(label: "VIDEO", rows: [
                    .init(label: "Resolution", value: "5120x2160"),
                    .init(label: "Codec", value: "H265", detail: "hw"),
                    .init(label: "Colour", value: "10-bit 4:2:0", detail: "xf20 → bgr10a2 · game HDR", color: StreamHUDTheme.accent),
                    .init(label: "Render", value: "Native 10-bit", detail: "skipped 432 · balanced"),
                ]),
                .init(label: "TIMING", rows: [
                    .init(label: "Decode", value: "8.1", detail: "ms of 8.3", color: StreamHUDTheme.warning),
                    .init(label: "Present", value: "69.8", detail: "ms · max 81.3 · jitter 0.57"),
                ]),
                .init(label: "AUDIO", rows: [
                    .init(label: "Format", value: "Stereo (7.1 asked)", detail: "Opus", color: StreamHUDTheme.warning),
                    .init(label: "A/V", value: "+42", detail: "ms est. · audio buffer 30 + device 6 ms · video late"),
                ]),
                .init(label: "SESSION", rows: [
                    .init(label: "Rig", value: "GeForce RTX 5080", detail: "5080h / B40"),
                    .init(label: "Server Location", value: "np-tyo-01 (Japan)"),
                ]),
            ]
        )
    }

    /// Minimum: the headline readings alone, keeping the header and the panel's own geometry.
    private static var minimum: NativeNVSTStatsPanel {
        NativeNVSTStatsPanel(transport: "NATIVE NVST", heroes: heroes, groups: [])
    }

    /// Compact: the headline readings plus the handful of numbers a session is judged by.
    private static var compact: NativeNVSTStatsPanel {
        NativeNVSTStatsPanel(
            transport: "NATIVE NVST",
            heroes: heroes,
            groups: [
                .init(label: "OVERVIEW", rows: [
                    .init(label: "Resolution", value: "5120x2160"),
                    .init(label: "Codec", value: "H265", detail: "hw"),
                    .init(label: "Bandwidth Used", value: "3.2", detail: "Mbps of 150"),
                    .init(label: "Packet Loss", value: "0.0%", detail: "(89 Total)", color: StreamHUDTheme.accent),
                    .init(label: "Frame Loss", value: "0", detail: "(2 Total)", color: StreamHUDTheme.accent),
                ]),
            ]
        )
    }

    @MainActor
    private func render(_ panel: NativeNVSTStatsPanel, name: String) throws -> CGFloat {
        let renderer = ImageRenderer(content: panel.padding(12).background(Color.black))
        renderer.scale = 2
        let image = try #require(renderer.nsImage, "the panel did not render")
        #expect(image.size.width > 0)
        writeSnapshot(image, name: name)
        return image.size.height
    }

    /// Written where a person can look at it; the assertions in each test are what gate it.
    @MainActor
    private func writeSnapshot(_ image: NSImage, name: String) {
        guard let directory = ProcessInfo.processInfo.environment["OPN_SNAPSHOT_DIR"],
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    @Test @MainActor func theAdvancedPanelRenders() throws {
        let height = try render(Self.sample, name: "hud-stats-panel.png")
        #expect(height > 300, "the panel collapsed")
    }

    /// Each level drops content rather than merely restyling it, so the panels must come out
    /// strictly shorter as the detail level falls while sharing the header and the geometry.
    @Test @MainActor func leanerLevelsRenderShorterPanels() throws {
        let advanced = try render(Self.sample, name: "hud-stats-panel-advanced.png")
        let compact = try render(Self.compact, name: "hud-stats-panel-compact.png")
        let minimum = try render(Self.minimum, name: "hud-stats-panel-minimum.png")
        #expect(minimum < compact)
        #expect(compact < advanced)
    }
}
