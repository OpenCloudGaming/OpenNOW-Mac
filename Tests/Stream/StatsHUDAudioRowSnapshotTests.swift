import SwiftUI
import Testing
@testable import OpenNOW

/// Renders the stats HUD's Audio row offscreen so the four layouts, and the shortfall state, can be
/// looked at without a running stream. `ImageRenderer` needs no screen and no capture permission.
@Suite struct StatsHUDAudioRowSnapshotTests {
    private struct AudioRowPreview: View {
        let cases: [(String, NativeNVSTPerformanceSnapshot)]

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("STREAM STATS")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
                ForEach(Array(cases.enumerated()), id: \.offset) { _, entry in
                    HStack(spacing: 6) {
                        Text("Audio")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.62))
                        Spacer(minLength: 8)
                        Text(entry.1.audioFormatSummary)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(entry.1.audioChannelCount == entry.1.requestedAudioChannelCount ? .white : Color.orange)
                        Text("Opus")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                        Text("· \(entry.0)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    .frame(width: 300, alignment: .leading)
                }
            }
            .padding(12)
            .background(Color(red: 0.09, green: 0.09, blue: 0.09))
        }
    }

    private static func snapshot(_ negotiated: Int, _ requested: Int) -> NativeNVSTPerformanceSnapshot {
        NativeNVSTPerformanceSnapshot(
            available: true, gameFramesPerSecond: 0, streamFramesPerSecond: 0,
            latencyMilliseconds: 0, jitterMilliseconds: 0, frameLoss: 0, totalFrameLoss: 0,
            packetLoss: 0, totalPacketLoss: 0, bitrateMegabitsPerSecond: 0,
            bandwidthUtilizationPercent: 0, resolution: "", codec: "", serverLocation: "",
            audioChannelCount: negotiated, requestedAudioChannelCount: requested
        )
    }

    @MainActor @Test func theAudioRowRendersEveryLayout() throws {
        let cases: [(String, NativeNVSTPerformanceSnapshot)] = [
            ("measured on SoR4", Self.snapshot(2, 2)),
            ("measured on SoR4", Self.snapshot(6, 6)),
            ("measured on SoR4", Self.snapshot(8, 8)),
            ("seat answered short", Self.snapshot(2, 6)),
            ("seat answered short", Self.snapshot(6, 8)),
        ]
        let renderer = ImageRenderer(content: AudioRowPreview(cases: cases))
        renderer.scale = 2
        let image = try #require(renderer.nsImage, "the row did not render")
        #expect(image.size.width > 0 && image.size.height > 0)

        // Written where a person can look at it; the assertions above are what gates the test.
        if let directory = ProcessInfo.processInfo.environment["OPN_SNAPSHOT_DIR"],
           let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("hud-audio-row.png"))
        }
    }
}
