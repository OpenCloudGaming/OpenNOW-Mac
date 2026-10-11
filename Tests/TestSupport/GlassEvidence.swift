import AppKit
import SwiftUI
import Testing
@testable import OpenNOW

/// Composited Liquid Glass evidence.
///
/// Liquid Glass is drawn by the window server, so an `ImageRenderer` shows nothing of it and a screen
/// grab comes back black while the display is asleep. These put a view in a real window over a bright
/// backdrop and measure what was composed.
enum GlassEvidence {
    /// Opt-in capture directory, shared so every glass suite agrees on where its evidence lands.
    nonisolated static var captureDirectory: String? {
        ProcessInfo.processInfo.environment["OPN_SNAPSHOT_DIR"]
    }

    /// An offscreen render, for the assertions that do not need the window server: layout parity and
    /// the flat path.
    @MainActor
    static func renderOffscreen(_ view: some View) -> NSImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.nsImage
    }

    /// Captures `content` in a borderless window over `backdrop`, writes the PNG into the capture
    /// directory, and returns it. Waits once for the window and once for the first real draw.
    @MainActor
    static func captureInWindow(
        _ content: some View,
        over backdrop: some View,
        size: CGSize,
        named name: String
    ) async throws -> GlassCapture {
        let directory = try #require(captureDirectory, "set OPN_SNAPSHOT_DIR to capture")
        let hosting = NSHostingView(rootView: ZStack {
            backdrop
            content
        })
        hosting.frame = NSRect(origin: .zero, size: size)
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
        try write(image, named: name, into: directory)
        return GlassCapture(image: image)
    }

    /// `CGWindowListCreateImage` left this SDK's headers but is still exported by CoreGraphics, and it
    /// is the one composited capture that does not go through ScreenCaptureKit's permission gate.
    private static func captureWindow(_ window: CGWindowID) -> CGImage? {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        typealias CaptureFunction = @convention(c) (CGRect, UInt32, CGWindowID, UInt32) -> Unmanaged<CGImage>?
        let function = unsafeBitCast(symbol, to: CaptureFunction.self)
        let options = CGWindowImageOption.boundsIgnoreFraming.rawValue | CGWindowImageOption.bestResolution.rawValue
        return function(.null, CGWindowListOption.optionIncludingWindow.rawValue, window, options)?.takeRetainedValue()
    }

    private static func write(_ image: CGImage, named name: String, into directory: String) throws {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let png = try #require(bitmap.representation(using: .png, properties: [:]), "could not encode \(name)")
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }
}

/// A composited capture, with the measurements a glass suite asserts on. Every `rect` is normalized:
/// fractions of the image, so a measurement survives a different capture scale.
struct GlassCapture {
    let image: CGImage

    /// The whole capture, for a surface that fills it.
    static let wholeImage = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// Mean absolute grey-level difference from `other` inside `rect`. Measured over the surface
    /// rather than the frame, so a panel that quietly stopped drawing the material fails instead of
    /// passing on a whole-image average.
    func meanAbsoluteDifference(from other: GlassCapture, in rect: CGRect) -> Double {
        guard let left = grayBytes(image), let right = grayBytes(other.image), left.count == right.count else { return 0 }
        let samples = indices(of: image, in: rect)
        guard !samples.isEmpty else { return 0 }
        var total = 0
        for index in samples {
            total += abs(Int(left[index]) - Int(right[index]))
        }
        return Double(total) / Double(samples.count)
    }

    /// The median relative luminance inside `rect`: the surface's own background, with glyphs treated
    /// as outliers rather than as the thing being measured.
    func medianLuminance(in rect: CGRect) -> Double {
        guard let bytes = grayBytes(image) else { return 1 }
        let samples = indices(of: image, in: rect)
        guard !samples.isEmpty else { return 1 }
        let luminances = samples.map { relativeLuminance(gray: bytes[$0]) }.sorted()
        return luminances[luminances.count / 2]
    }

    /// Pixels inside `rect` where green leads the other channels by more than `threshold`. The way to
    /// prove an accent-coloured badge is drawn above a plate rather than buried under it.
    func greenDominantPixelCount(in rect: CGRect, threshold: Int) -> Int {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return 0 }
        let bytesPerPixel = max(image.bitsPerPixel / 8, 1)
        var count = 0
        for index in indices(of: image, in: rect) {
            let offset = index * bytesPerPixel
            let red = Int(bytes[offset])
            let green = Int(bytes[offset + 1])
            let blue = Int(bytes[offset + 2])
            if green - max(red, blue) > threshold { count += 1 }
        }
        return count
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

    /// Luma of each pixel, row by row, so a rect's indices address this array directly.
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

    /// WCAG relative luminance from an 8-bit sRGB grey value.
    private func relativeLuminance(gray: UInt8) -> Double {
        let channel = Double(gray) / 255
        return channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
}

/// Bright, busy content behind a glass surface: a saturated gradient, hard stripes and heavy type, so
/// a material's blur and the contrast it costs are both unmistakable.
struct BrightGlassBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.55, green: 0.82, blue: 1.0),
                    Color(red: 1.0, green: 0.88, blue: 0.55),
                    Color(red: 0.15, green: 0.62, blue: 0.42),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack(spacing: 0) {
                ForEach(0..<30, id: \.self) { index in
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
