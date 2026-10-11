import AppKit
import SwiftUI
import Testing
@testable import OpenNOW

/// The app-shell modal panels under the Liquid Glass preference: the material has to reach them, and
/// the message text has to stay legible over the scrim and whatever sits behind it.
@MainActor
@Suite(.serialized) struct OPNModalGlassTests {
    nonisolated private static var captureDirectory: String? {
        ProcessInfo.processInfo.environment["OPN_SNAPSHOT_DIR"]
    }

    private static let requestedOnSupportedMac = OPNLiquidGlassPolicy(
        isRequested: true, isSupported: true, isReduceTransparency: false
    )

    private static let stageSize = CGSize(width: 900, height: 620)

    /// The panel's message and footer sit on the material, so it cannot change the panel's geometry.
    @Test func theConfirmationPanelKeepsItsGeometryWithGlassOn() throws {
        let flat = try #require(render(panel(policy: .off)), "the flat panel did not render")
        let glass = try #require(render(panel(policy: Self.requestedOnSupportedMac)), "the glass panel did not render")
        #expect(flat.size == glass.size, "the material changed the panel's layout")
    }

    /// Composited: the panel's fill is drawn by the window server when the material is on, so an
    /// offscreen render cannot show it. Writes both modes for a person to judge readability against.
    @Test(.enabled(if: Self.captureDirectory != nil)) func theConfirmationPanelDrawsGlass() async throws {
        let directory = try #require(Self.captureDirectory, "set OPN_SNAPSHOT_DIR to capture")
        let glass = try await capture(panel(policy: Self.requestedOnSupportedMac), named: "confirmation-modal-glass.png", into: directory)
        let flat = try await capture(panel(policy: .off), named: "confirmation-modal-flat.png", into: directory)

        // The panel is small in a 900×620 stage, so the comparison is over the panel's own body:
        // a whole-image delta hides a modal that stopped drawing the material.
        let difference = meanAbsoluteDifference(glass, flat, in: Self.panelBody)
        #expect(difference > 4, "the modal did not follow the Liquid Glass policy: mean delta \(difference)")

        // The message is Text Secondary at 0.72 white. The median is the body's background — a
        // percentile above it lands on the message's own glyphs and measures the text, not the panel.
        let backgroundLuminance = medianLuminance(of: glass, in: Self.panelBody)
        #expect(
            backgroundLuminance < 0.05,
            "the panel body is too bright to read the message: median background luminance \(backgroundLuminance)"
        )
    }

    // MARK: - Fixtures

    /// The real confirmation panel, scrim and all, over bright content.
    private func panel(policy: OPNLiquidGlassPolicy) -> some View {
        ZStack {
            BrightContent()
            OPNConfirmationPanel(
                eyebrow: "END SESSION",
                title: "End this session?",
                message: "The game closes on the server and anything unsaved is lost. You can start it again from your library at any time.",
                actions: [
                    OPNConfirmationAction("End session", role: .destructive) {},
                    OPNConfirmationAction("Cancel", role: .cancel) {},
                ],
                dismiss: {}
            )
        }
        .frame(width: Self.stageSize.width, height: Self.stageSize.height)
        .environment(\.opnUIScale, 1)
        .environment(\.opnLiquidGlass, policy)
    }

    /// The panel is centred at a fixed 440pt width; this is the band its message sits in.
    private static let panelBody = CGRect(x: 0.26, y: 0.46, width: 0.48, height: 0.2)

    private func render(_ view: some View) -> NSImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.nsImage
    }

    private func capture(_ view: some View, named name: String, into directory: String) async throws -> CGImage {
        let hosting = NSHostingView(rootView: view)
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

    private func meanAbsoluteDifference(_ lhs: CGImage, _ rhs: CGImage, in rect: CGRect) -> Double {
        guard let left = grayBytes(lhs), let right = grayBytes(rhs), left.count == right.count else { return 0 }
        let samples = indices(of: lhs, in: rect)
        guard !samples.isEmpty else { return 0 }
        var total = 0
        for index in samples {
            total += abs(Int(left[index]) - Int(right[index]))
        }
        return Double(total) / Double(samples.count)
    }

    /// The median relative luminance inside `rect`: the panel's background, with its glyphs treated as
    /// outliers rather than as the thing being measured.
    private func medianLuminance(of image: CGImage, in rect: CGRect) -> Double {
        guard let bytes = grayBytes(image) else { return 1 }
        let samples = indices(of: image, in: rect)
        guard !samples.isEmpty else { return 1 }
        let luminances = samples.map { relativeLuminance(gray: bytes[$0]) }.sorted()
        return luminances[luminances.count / 2]
    }

    private func indices(of image: CGImage, in rect: CGRect) -> [Int] {
        let minX = Int(rect.minX * CGFloat(image.width))
        let maxX = Int(rect.maxX * CGFloat(image.width))
        let minY = Int(rect.minY * CGFloat(image.height))
        let maxY = Int(rect.maxY * CGFloat(image.height))
        var indices = [Int]()
        for y in minY..<maxY {
            for x in minX..<maxX {
                indices.append(y * image.width + x)
            }
        }
        return indices
    }

    /// WCAG relative luminance from an 8-bit sRGB grey value.
    private func relativeLuminance(gray: UInt8) -> Double {
        let channel = Double(gray) / 255
        return channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
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

/// Bright, busy content behind the scrim, so a material that washes the panel out is unmistakable.
private struct BrightContent: View {
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
            Text("BRIGHT CONTENT")
                .font(.system(size: 44, weight: .black))
                .foregroundStyle(.black.opacity(0.82))
                .rotationEffect(.degrees(-14))
        }
    }
}
