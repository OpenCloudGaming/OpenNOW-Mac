import AppKit
import SwiftUI
import Testing
@testable import OpenNOW

/// The rating badge is the one surface in this change whose drawn size moved with Interface Scale, so
/// its decode rung had to move with it. A fixed 58 x 76pt frame sitting beside text that scales is
/// exactly the layout bug the scale exists to avoid, and it is invisible at 1.0.
///
/// `ImageRenderer` needs no window and no network: the badge falls back to its own mark when the
/// rating URL is empty, which is the branch that carries the frame and the type sizes.
@Suite struct CatalogRatingBadgeScaleTests {
    private func ratedGame() -> OPNCatalogGameObject {
        var info = OPNGameInfo()
        info.title = "Rated"
        return OPNCatalogGameObject(game: info)
    }

    @MainActor
    private func render(scale: CGFloat) throws -> NSImage {
        let renderer = ImageRenderer(
            content: CatalogRatingBadge(game: ratedGame(), shortRating: "T")
                .environment(\.opnUIScale, scale)
        )
        renderer.scale = 1
        let image = try #require(renderer.nsImage, "the badge did not render at Interface Scale \(scale)")
        writeSnapshot(image, name: "rating-badge-scale-\(scale).png")
        return image
    }

    @MainActor
    private func writeSnapshot(_ image: NSImage, name: String) {
        guard let directory = ProcessInfo.processInfo.environment["OPN_SNAPSHOT_DIR"],
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    @Test @MainActor func theRatingBadgeGrowsWithInterfaceScale() throws {
        let base = try render(scale: 1)
        let oneAndAQuarter = try render(scale: 1.25)
        let oneAndAHalf = try render(scale: 1.5)

        #expect(abs(base.size.height - 76) < 1)
        #expect(abs(base.size.width - 58) < 1)
        #expect(abs(oneAndAQuarter.size.height - 76 * 1.25) < 1)
        #expect(abs(oneAndAHalf.size.height - 76 * 1.5) < 1)
        #expect(abs(oneAndAHalf.size.width - 58 * 1.5) < 1)
    }
}
