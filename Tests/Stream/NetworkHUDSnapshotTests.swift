import AppKit
import SwiftUI
import Testing
@testable import OpenNOW

@Suite struct NetworkHUDSnapshotTests {
    @Test(arguments: [CGFloat(1.25), CGFloat(1.5)], [false, true]) @MainActor
    func currentLossRemainsReadableAtNonDefaultScales(scale: CGFloat, isPacketLossActive: Bool) throws {
        let stats = NativeNVSTStreamStatsModel()
        stats.latestNativeStats = NativeNVSTPerformanceSnapshot(
            available: true,
            gameFramesPerSecond: 60,
            streamFramesPerSecond: 60,
            latencyMilliseconds: 7,
            jitterMilliseconds: 0.3,
            frameLoss: 0,
            totalFrameLoss: 0,
            packetLoss: isPacketLossActive ? 12 : 0,
            totalPacketLoss: 27_580,
            packetLossPercent: isPacketLossActive ? 1.2 : 0,
            bitrateMegabitsPerSecond: 40,
            bandwidthUtilizationPercent: 0,
            resolution: "2560x1600",
            codec: "H265",
            serverLocation: "test"
        )
        let content = VStack {
            NativeNVSTNetworkHUDPanel(stats: stats, isCollapsed: false, isFocused: false, onToggle: {})
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(StreamHUDTheme.appBar)
        .environment(\.opnUIScale, scale)
        .opnInterfaceScale(scale)
        .frame(width: 340 * scale, height: 200 * scale)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let pixelTolerance = 1 / renderer.scale
        #expect(abs(image.size.width - 340 * scale) < pixelTolerance)
        #expect(abs(image.size.height - 200 * scale) < pixelTolerance)

        guard let directory = ProcessInfo.processInfo.environment["OPN_SNAPSHOT_DIR"] else { return }
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let state = isPacketLossActive ? "active" : "recovered"
        let url = URL(fileURLWithPath: directory).appendingPathComponent("hud-network-\(state)-\(scale).png")
        try png.write(to: url, options: .atomic)
    }
}
