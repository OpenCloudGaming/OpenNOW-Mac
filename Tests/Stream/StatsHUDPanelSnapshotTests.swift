import SwiftUI
import Testing
@testable import OpenNOW

/// Renders the whole stats panel offscreen from sample values. `ImageRenderer` needs no screen and
/// no capture permission, and a desktop grab of a live stream window comes back black, so this is
/// the only way to look at the panel's layout - in particular at the two details long enough to
/// take the wrapped row.
@Suite struct StatsHUDPanelSnapshotTests {
    private static var sample: NativeNVSTStatsPanel {
        NativeNVSTStatsPanel(
            transport: "NATIVE NVST",
            heroes: [
                .init(label: "GAME", value: "120", unit: "fps", color: WebRTCMediaStreamTheme.accent),
                .init(label: "STREAM", value: "120", unit: "fps", color: WebRTCMediaStreamTheme.textPrimary),
                .init(label: "LATENCY", value: "5", unit: "ms", color: WebRTCMediaStreamTheme.accent),
            ],
            groups: [
                .init(label: "NETWORK", rows: [
                    .init(label: "Frame Loss", value: "0", detail: "(2 Total)", color: WebRTCMediaStreamTheme.accent),
                    .init(label: "Packet Loss", value: "0.0%", detail: "(89 Total)", color: WebRTCMediaStreamTheme.accent),
                    .init(label: "Bandwidth Used", value: "3.2", detail: "Mbps of 150"),
                    .init(label: "Jitter", value: "0.2", detail: "ms"),
                ]),
                .init(label: "VIDEO", rows: [
                    .init(label: "Resolution", value: "5120x2160"),
                    .init(label: "Codec", value: "H265", detail: "hw"),
                    .init(label: "Colour", value: "10-bit 4:2:0", detail: "xf20 → bgr10a2 · game HDR", color: WebRTCMediaStreamTheme.accent),
                    .init(label: "Render", value: "Native 10-bit", detail: "skipped 432 · balanced"),
                ]),
                .init(label: "TIMING", rows: [
                    .init(label: "Decode", value: "8.1", detail: "ms of 8.3", color: WebRTCMediaStreamTheme.warning),
                    .init(label: "Present", value: "69.8", detail: "ms · max 81.3 · jitter 0.57"),
                ]),
                .init(label: "AUDIO", rows: [
                    .init(label: "Format", value: "Stereo (7.1 asked)", detail: "Opus", color: WebRTCMediaStreamTheme.warning),
                    .init(label: "A/V", value: "+42", detail: "ms est. · audio buffer 30 + device 6 ms · video late"),
                ]),
                .init(label: "SESSION", rows: [
                    .init(label: "Rig", value: "GeForce RTX 5080", detail: "5080h / B40"),
                    .init(label: "Server Location", value: "np-tyo-01 (Japan)"),
                ]),
            ]
        )
    }

    @MainActor @Test func theStatsPanelRenders() throws {
        let renderer = ImageRenderer(content: Self.sample.padding(12).background(Color.black))
        renderer.scale = 2
        let image = try #require(renderer.nsImage, "the panel did not render")
        #expect(image.size.width >= NativeNVSTStatsPanel.width)
        #expect(image.size.height > 300, "the panel collapsed")

        // Written where a person can look at it; the assertions above are what gates the test.
        if let directory = ProcessInfo.processInfo.environment["OPN_SNAPSHOT_DIR"],
           let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("hud-stats-panel.png"))
        }
    }
}
