import AppKit
import SwiftUI
import Testing
@testable import OpenNOW

/// The stream HUD's (⌘G) dock under the Liquid Glass preference: the material must not move the dock,
/// and it has to stay legible over bright, busy video — which only a composited capture can show.
@MainActor
@Suite(.serialized) struct StreamHUDGlassTests {
    nonisolated private static var captureDirectory: String? {
        ProcessInfo.processInfo.environment["OPN_SNAPSHOT_DIR"]
    }

    private static let requestedOnSupportedMac = OPNLiquidGlassPolicy(
        isRequested: true, isSupported: true, isReduceTransparency: false
    )

    private static let stageSize = CGSize(width: 900, height: 620)

    /// The dock's empty interior as a fraction of the stage: inside the dock's 344pt width, below the
    /// section rows and above the footer.
    private static let dockInterior = CGRect(x: 0.02, y: 0.48, width: 0.34, height: 0.42)

    /// The material replaces the dock's fill, so it cannot change the dock's own geometry.
    @Test func theDockKeepsItsGeometryWithGlassOn() throws {
        let flat = try #require(render(dock(policy: .off)), "the flat dock did not render")
        let glass = try #require(render(dock(policy: Self.requestedOnSupportedMac)), "the glass dock did not render")
        #expect(flat.size == glass.size, "the material changed the dock's layout")
        #expect(glass.size == Self.stageSize)
    }

    /// Composited: the dock's fill is drawn by the window server when the material is on, so an
    /// offscreen render cannot show it. Writes both modes for a person to judge readability against.
    @Test(.enabled(if: Self.captureDirectory != nil)) func theDockDrawsGlassOverBrightVideo() async throws {
        let directory = try #require(Self.captureDirectory, "set OPN_SNAPSHOT_DIR to capture")
        let glass = try await capture(dock(policy: Self.requestedOnSupportedMac), named: "stream-hud-dock-glass.png", into: directory)
        let flat = try await capture(dock(policy: .off), named: "stream-hud-dock-flat.png", into: directory)

        let difference = meanAbsoluteDifference(glass, flat)
        #expect(difference > 2, "the HUD dock did not follow the Liquid Glass policy: mean delta \(difference)")

        // The dock's dimmest tier is Text Tertiary at 0.52 white, which needs a background below
        // ~0.07 relative luminance to clear 4.5:1. Measured with the scrim in place, not assumed.
        let backgroundLuminance = percentileLuminance(of: glass, in: Self.dockInterior)
        #expect(
            backgroundLuminance < 0.08,
            "the dock is too bright to read over video: p95 background luminance \(backgroundLuminance)"
        )
    }

    // MARK: - Fixtures

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

    private func render(_ view: some View) -> NSImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.nsImage
    }

    /// The dock over a bright, busy backdrop in a real window, captured the way the window server
    /// composed it. Waits once for the window and once for the first real draw.
    private func capture(_ view: some View, named name: String, into directory: String) async throws -> CGImage {
        let hosting = NSHostingView(rootView: ZStack {
            BrightGameContent()
            view
        })
        hosting.frame = NSRect(origin: .zero, size: Self.stageSize)
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

        let image = try #require(captured, "the window server returned no image for our own window")
        let bitmap = NSBitmapImageRep(cgImage: image)
        let png = try #require(bitmap.representation(using: .png, properties: [:]), "could not encode \(name)")
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
        return image
    }

    /// The 95th-percentile relative luminance inside `rect`, so one stray bright pixel cannot decide
    /// whether the dock is legible.
    private func percentileLuminance(of image: CGImage, in rect: CGRect) -> Double {
        guard let bytes = grayBytes(image) else { return 1 }
        let minX = Int(rect.minX * CGFloat(image.width))
        let maxX = Int(rect.maxX * CGFloat(image.width))
        let minY = Int(rect.minY * CGFloat(image.height))
        let maxY = Int(rect.maxY * CGFloat(image.height))
        var luminances = [Double]()
        for y in minY..<maxY {
            for x in minX..<maxX {
                luminances.append(relativeLuminance(gray: bytes[y * image.width + x]))
            }
        }
        guard !luminances.isEmpty else { return 1 }
        luminances.sort()
        return luminances[Int(Double(luminances.count - 1) * 0.95)]
    }

    /// WCAG relative luminance from an 8-bit sRGB grey value.
    private func relativeLuminance(gray: UInt8) -> Double {
        let channel = Double(gray) / 255
        let linear = channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        return linear
    }

    private func meanAbsoluteDifference(_ lhs: CGImage, _ rhs: CGImage) -> Double {
        guard let left = grayBytes(lhs), let right = grayBytes(rhs), left.count == right.count else { return 0 }
        var total = 0
        for index in left.indices {
            total += abs(Int(left[index]) - Int(right[index]))
        }
        return Double(total) / Double(left.count)
    }

    private func grayBytes(_ image: CGImage) -> [UInt8]? {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let bytesPerPixel = max(image.bitsPerPixel / 8, 1)
        var gray = [UInt8]()
        gray.reserveCapacity(image.width * image.height)
        for y in 0..<image.height {
            for x in 0..<image.width {
                let offset = y * image.bytesPerRow + x * bytesPerPixel
                let red = Int(bytes[offset])
                let green = Int(bytes[offset + 1])
                let blue = Int(bytes[offset + 2])
                gray.append(UInt8((red * 299 + green * 587 + blue * 114) / 1000))
            }
        }
        return gray
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
}

/// A stand-in for the worst case behind the dock: bright sky, a saturated horizon, dark objects and
/// hard-edged type, so a material that washes the dock out is unmistakable.
private struct BrightGameContent: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.55, green: 0.82, blue: 1.0), Color(red: 1.0, green: 0.88, blue: 0.55), Color(red: 0.15, green: 0.62, blue: 0.42)],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack(spacing: 0) {
                ForEach(0..<26, id: \.self) { index in
                    Rectangle()
                        .fill(.white.opacity(index.isMultiple(of: 2) ? 0.92 : 0.08))
                        .frame(height: 14)
                }
            }
            Text("BRIGHT GAME CONTENT")
                .font(.system(size: 46, weight: .black))
                .foregroundStyle(.black.opacity(0.82))
                .rotationEffect(.degrees(-14))
        }
    }
}
