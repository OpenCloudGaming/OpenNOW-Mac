//  The launch loading screen's artwork. `ImageRenderer` cannot check this: it never runs the async
//  load, so a view that never leaves its placeholder renders identically to one that is merely
//  waiting. These host the real screen in a window and look at the pixels instead.
//

import AppKit
import SwiftUI
import Testing
@testable import OpenNOW

@Suite(.serialized, .disabled(if: CIWindowTestGate.isHostedRunner, Comment(rawValue: CIWindowTestGate.skipReason))) @MainActor
struct StreamLaunchLoadingScreenRenderTests {
    private static let artworkHost = "launch-artwork.test"
    private static let artworkURL = URL(string: "https://launch-artwork.test/screenshot.jpg;f=webp;w=720")!
    private static let windowSize = CGSize(width: 1200, height: 700)

    /// The artwork is drawn through `CatalogCachedImageView`, whose placeholder has to occupy the
    /// oversized frame it is given. An empty one left the image laid out at zero size, and the screen
    /// black, while the cache and the decode both reported success.
    @Test func theScreenDrawsItsArtwork() async throws {
        let imageData = try #require(Self.brightImageData())
        SessionManagerURLProtocol.install(host: Self.artworkHost) { _ in (200, imageData) }
        defer { SessionManagerURLProtocol.uninstall(host: Self.artworkHost) }
        OPNDesign.applyTheme(accent: .cloudGreen, appearance: .dark, systemColorScheme: .dark)

        let warmed = await CatalogImageCache.shared.image(for: Self.artworkURL, maxPixelSize: StreamLaunchArtwork.decodePixelSize)
        #expect(warmed != nil)

        let bitmap = try await renderBitmap(
            of: StreamLaunchLoadingScreen(title: "Game", stepIndex: 1, artworkURL: Self.artworkURL) { EmptyView() }
        )
        #expect(Self.artworkBandBrightFraction(in: bitmap) > 0.5)
    }

    private func renderBitmap(of screen: StreamLaunchLoadingScreen<EmptyView>) async throws -> NSBitmapImageRep {
        let hosting = NSHostingView(rootView: screen)
        hosting.frame = CGRect(origin: .zero, size: Self.windowSize)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        try? await Task.sleep(for: .milliseconds(600))
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap
    }

    /// The share of the band the artwork occupies alone - below the title, above the stage plate, and
    /// inside the clear middle of the scrim - that is brighter than the black it sits on. Only the
    /// artwork fills this band, so a black screen leaves it near zero and chrome cannot lift it.
    private static func artworkBandBrightFraction(in bitmap: NSBitmapImageRep) -> Double {
        let rows = stride(from: Int(Double(bitmap.pixelsHigh) * 0.28), to: Int(Double(bitmap.pixelsHigh) * 0.44), by: 2)
        let columns = stride(from: 6, to: bitmap.pixelsWide - 6, by: 6)
        var sampled = 0
        var bright = 0
        for row in rows {
            for column in columns {
                sampled += 1
                guard let colour = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) else { continue }
                if colour.redComponent + colour.greenComponent + colour.blueComponent > 0.06 { bright += 1 }
            }
        }
        guard sampled > 0 else { return 0 }
        return Double(bright) / Double(sampled)
    }

    private static func brightImageData() -> Data? {
        let side = 64
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
