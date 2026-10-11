import AppKit
import SwiftUI
import Testing
@testable import OpenNOW

/// Composited Liquid Glass evidence. Liquid Glass is drawn by the window server, so an `ImageRenderer`
/// shows nothing of it and a screen grab comes back black while the display is asleep.
enum GlassEvidence {
    /// Opt-in capture directory, shared so every glass suite agrees on where its evidence lands.
    nonisolated static var captureDirectory: String? {
        ProcessInfo.processInfo.environment["OPN_SNAPSHOT_DIR"]
    }

    /// Whether a glass-versus-flat comparison is meaningful: it needs a directory to write into and a
    /// Mac that draws the material, since below macOS 26 both policies take the flat branch.
    nonisolated static var isGlassCaptureAvailable: Bool {
        captureDirectory != nil && OPNLiquidGlassPolicy.isSupportedOnThisMac
    }

    /// An offscreen render, for the assertions that do not need the window server: layout parity and
    /// the flat path.
    @MainActor
    static func renderOffscreen(_ view: some View) -> NSImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.nsImage
    }

    /// Captures `surface` with the material on and off, which is the comparison every glass suite
    /// makes. Writes `<name>-glass.png` and `<name>-flat.png` and returns both.
    @MainActor
    static func captureBothModes(
        named name: String,
        over backdrop: some View,
        size: CGSize,
        @ViewBuilder surface: (OPNLiquidGlassPolicy) -> some View
    ) async throws -> (glass: GlassCapture, flat: GlassCapture) {
        let glass = try await captureInWindow(
            surface(.requestedOnSupportedMac),
            over: backdrop,
            size: size,
            named: "\(name)-glass.png"
        )
        let flat = try await captureInWindow(
            surface(.off),
            over: backdrop,
            size: size,
            named: "\(name)-flat.png"
        )
        return (glass, flat)
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
        // Deferred, not called at the end: either sleep can throw on cancellation, and a window left
        // on screen would pollute every later capture.
        defer { window.orderOut(nil) }

        try await Task.sleep(for: .milliseconds(1200))
        _ = captureWindow(CGWindowID(window.windowNumber))
        try await Task.sleep(for: .milliseconds(400))
        let captured = captureWindow(CGWindowID(window.windowNumber))

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

    /// Mean absolute grey-level difference from `other` inside `rect`. Measured over the surface, so a
    /// panel that quietly stopped drawing the material fails instead of passing on a whole-image mean.
    func meanAbsoluteDifference(from other: GlassCapture, in rect: CGRect) -> Double {
        guard let left = pixels, let right = other.pixels else { return 0 }
        let samples = left.indices(in: rect)
        guard !samples.isEmpty else { return 0 }
        var total = 0
        for index in samples {
            total += abs(Int(left.luma(at: index)) - Int(right.luma(at: index)))
        }
        return Double(total) / Double(samples.count)
    }

    /// The median relative luminance inside `rect`: the surface's own background, with glyphs treated
    /// as outliers rather than as the thing being measured.
    func medianLuminance(in rect: CGRect) -> Double {
        guard let pixels else { return 1 }
        let samples = pixels.indices(in: rect)
        guard !samples.isEmpty else { return 1 }
        let luminances = samples.map { relativeLuminance(gray: pixels.luma(at: $0)) }.sorted()
        return luminances[luminances.count / 2]
    }

    /// Pixels inside `rect` where green leads the other channels by more than `threshold`. The way to
    /// prove an accent-coloured badge is drawn above a plate rather than buried under it.
    func greenDominantPixelCount(in rect: CGRect, threshold: Int) -> Int {
        guard let pixels else { return 0 }
        var count = 0
        for index in pixels.indices(in: rect) {
            let colour = pixels.colour(at: index)
            if colour.green - max(colour.red, colour.blue) > threshold { count += 1 }
        }
        return count
    }

    /// The capture redrawn into one known layout, so a padded stride or a different source channel
    /// order cannot skew a measurement.
    private var pixels: GlassPixels? { GlassPixels(image) }

    /// WCAG relative luminance from an 8-bit sRGB grey value.
    private func relativeLuminance(gray: UInt8) -> Double {
        let channel = Double(gray) / 255
        return channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
}

/// A capture's pixels as 8-bit RGBA, top row first, so callers can address them by index.
private struct GlassPixels {
    private let bytes: [UInt8]
    private let bytesPerRow: Int
    private let width: Int
    private let height: Int

    init?(_ image: CGImage) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let isDrawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            // Flipped so the buffer's first row is the image's top row, matching a normalized rect.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard isDrawn else { return nil }
        self.bytes = bytes
        self.bytesPerRow = width * 4
        self.width = width
        self.height = height
    }

    /// The pixel indices a normalized rect covers, row by row.
    func indices(in rect: CGRect) -> [Int] {
        let minX = Int(rect.minX * CGFloat(width))
        let maxX = Int(rect.maxX * CGFloat(width))
        let minY = Int(rect.minY * CGFloat(height))
        let maxY = Int(rect.maxY * CGFloat(height))
        var indices = [Int]()
        for y in minY..<maxY {
            for x in minX..<maxX {
                indices.append(y * width + x)
            }
        }
        return indices
    }

    func colour(at index: Int) -> (red: Int, green: Int, blue: Int) {
        let offset = (index / width) * bytesPerRow + (index % width) * 4
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

    func luma(at index: Int) -> UInt8 {
        let colour = colour(at: index)
        return UInt8((colour.red * 299 + colour.green * 587 + colour.blue * 114) / 1000)
    }
}

extension OPNLiquidGlassPolicy {
    /// The policy a Mac that asked for glass and can draw it resolves to, which every glass suite's
    /// comparison needs.
    static let requestedOnSupportedMac = OPNLiquidGlassPolicy(
        isRequested: true, isSupported: true, isReduceTransparency: false
    )
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
