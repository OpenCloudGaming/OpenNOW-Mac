import AppKit
import SwiftUI
import Testing
@testable import OpenNOW

/// The catalog top bar's opt-in Liquid Glass: the material must not move the bar, and the Remote
/// Co-Op BETA badge has to stay readable above a glass plate.
@MainActor
@Suite(.serialized) struct CatalogTopBarGlassTests {
    /// Opt-in capture directory, the same one the menu-bar glass captures write into.
    nonisolated private static var captureDirectory: String? {
        ProcessInfo.processInfo.environment["OPN_SNAPSHOT_DIR"]
    }

    private static let requestedOnSupportedMac = OPNLiquidGlassPolicy(
        isRequested: true, isSupported: true, isReduceTransparency: false
    )

    private static let barWidth: CGFloat = 1100

    /// The trigger carries its own padding in both modes, so the material cannot resize the bar.
    @Test func theBarKeepsItsGeometryWithGlassOn() throws {
        OPNDesign.applyTheme(accent: .cloudGreen, appearance: .dark, systemColorScheme: .dark)
        let flat = try #require(render(topBar(policy: .off)), "the flat bar did not render")
        let glass = try #require(render(topBar(policy: Self.requestedOnSupportedMac)), "the glass bar did not render")
        #expect(flat.size == glass.size, "the material changed the bar's layout")
        #expect(glass.size.height == CatalogVendorLayout.appBarHeight(scale: 1))
    }

    /// Composited, because Liquid Glass is drawn by the window server: the badge has to read above the
    /// plate, which an offscreen render cannot show. A `GlassEffectContainer` around the icon row
    /// composites its glass over the badge and buries it — this is the guard for that.
    @Test(.enabled(if: Self.captureDirectory != nil)) func theRemoteCoOpBadgeReadsAboveTheGlass() async throws {
        let directory = try #require(Self.captureDirectory, "set OPN_SNAPSHOT_DIR to capture")
        let image = try await captureBar(policy: Self.requestedOnSupportedMac)
        try write(image, named: "catalog-top-bar-glass.png", into: directory)

        let badgePixels = countOfAccentGreenPixels(in: image)
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

    private func render(_ view: some View) -> NSImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.nsImage
    }

    /// The bar over a high-contrast backdrop in a real window, captured the way the window server
    /// composed it. Waits once for the window and once for the first real draw.
    private func captureBar(policy: OPNLiquidGlassPolicy) async throws -> CGImage {
        let hosting = NSHostingView(rootView: ZStack {
            GlassEvidenceStripes()
            topBar(policy: policy)
        })
        let height = CatalogVendorLayout.appBarHeight(scale: 1)
        hosting.frame = NSRect(x: 0, y: 0, width: Self.barWidth, height: height)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: 200, y: 260))
        window.orderFrontRegardless()

        try await Task.sleep(for: .milliseconds(1200))
        _ = captureWindow(CGWindowID(window.windowNumber))
        try await Task.sleep(for: .milliseconds(400))
        let captured = captureWindow(CGWindowID(window.windowNumber))
        window.orderOut(nil)

        return try #require(captured, "the window server returned no image for our own window")
    }

    /// The badge is the only accent-green thing in the bar, and the backdrop's stripes and gradient
    /// never make green the dominant channel, so counting them proves the badge is drawn on top.
    private func countOfAccentGreenPixels(in image: CGImage) -> Int {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return 0 }
        let bytesPerPixel = max(image.bitsPerPixel / 8, 1)
        var count = 0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let offset = y * image.bytesPerRow + x * bytesPerPixel
                let red = Int(bytes[offset])
                let green = Int(bytes[offset + 1])
                let blue = Int(bytes[offset + 2])
                if green - max(red, blue) > 60 { count += 1 }
            }
        }
        return count
    }

    private func capture(_ region: CGRect, option: CGWindowListOption, window: CGWindowID) -> CGImage? {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        typealias CaptureFunction = @convention(c) (CGRect, UInt32, CGWindowID, UInt32) -> Unmanaged<CGImage>?
        let function = unsafeBitCast(symbol, to: CaptureFunction.self)
        let options = CGWindowImageOption.boundsIgnoreFraming.rawValue | CGWindowImageOption.bestResolution.rawValue
        return function(region, option.rawValue, window, options)?.takeRetainedValue()
    }

    private func captureWindow(_ window: CGWindowID) -> CGImage? {
        capture(.null, option: .optionIncludingWindow, window: window)
    }

    private func write(_ image: CGImage, named name: String, into directory: String) throws {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let png = try #require(bitmap.representation(using: .png, properties: [:]), "could not encode \(name)")
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }
}

/// Fine stripes and heavy colour, so a material's blur is unmistakable where it is not behind glass.
private struct GlassEvidenceStripes: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [.purple, .orange, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 6) {
                ForEach(0..<12, id: \.self) { index in
                    Rectangle()
                        .fill(.white.opacity(index.isMultiple(of: 2) ? 0.85 : 0.15))
                        .frame(height: 6)
                }
            }
        }
    }
}
