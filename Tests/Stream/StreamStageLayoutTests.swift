import SwiftUI
import Testing
@testable import OpenNOW

/// The stage reserves the transparent titlebar's height at the top of the window. It used to leave
/// that slack at the bottom instead, which put the picture - and the HUD panels anchored to its top
/// edge - under the traffic lights in windowed mode. Rendered offscreen and read back as pixels,
/// because the bug was a one-word alignment and nothing about the sizes said it was wrong.
@Suite struct StreamStageLayoutTests {
    private static let viewport = CGSize(width: 320, height: 200)

    @MainActor private static func render(topInset: CGFloat, aspectRatio: CGFloat) throws -> NSBitmapImageRep {
        let stage = StreamStageLayout(viewport: viewport, topInset: topInset, aspectRatio: aspectRatio) { _ in
            Color.white
        }
        let renderer = ImageRenderer(content: stage)
        renderer.scale = 1
        let image = try #require(renderer.nsImage, "the stage did not render")
        let tiff = try #require(image.tiffRepresentation)
        return try #require(NSBitmapImageRep(data: tiff))
    }

    /// Bitmap rows are top-down, so row 0 is the top of the window.
    private static func isWhite(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> Bool {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
        return color.redComponent > 0.9 && color.greenComponent > 0.9 && color.blueComponent > 0.9
    }

    @MainActor @Test func theTitlebarStripStaysClearOfThePicture() throws {
        let inset: CGFloat = 28
        let bitmap = try Self.render(topInset: inset, aspectRatio: 16.0 / 9.0)
        let centreX = Int(Self.viewport.width / 2)

        for y in 0..<Int(inset) {
            #expect(!Self.isWhite(bitmap, x: centreX, y: y), "row \(y) is under the titlebar and must not carry the picture")
        }
        #expect(Self.isWhite(bitmap, x: centreX, y: Int(inset) + 2), "the picture should start immediately below the reserved strip")
    }

    @MainActor @Test func fullScreenReservesNothing() throws {
        let bitmap = try Self.render(topInset: 0, aspectRatio: Self.viewport.width / Self.viewport.height)
        #expect(Self.isWhite(bitmap, x: Int(Self.viewport.width / 2), y: 0), "with no titlebar the picture reaches the top edge")
    }

    @Test func theContentBoxKeepsItsAspectRatioUnderTheInset() {
        let size = StreamStageLayout<EmptyView>.contentSize(viewport: Self.viewport, topInset: 28, aspectRatio: 16.0 / 9.0)
        #expect(size.height <= Self.viewport.height - 28)
        #expect(abs(size.width / size.height - 16.0 / 9.0) < 0.001)
    }

    @Test func aZeroInsetFillsTheViewport() {
        let size = StreamStageLayout<EmptyView>.contentSize(viewport: Self.viewport, topInset: 0, aspectRatio: 16.0 / 9.0)
        #expect(size == Self.viewport)
    }
}
