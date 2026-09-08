//  The two pieces every catalog hero band is built from: the banner artwork and the wordmark that
//  stands in for the game's name.
//

import SwiftUI

/// Fill-cropped artwork anchored above centre, because a band four times wider than it is tall
/// discards half a 16:9 frame and a centred crop takes a quarter of it off the top with the heads.
struct CatalogHeroArtwork: View {
    let url: URL?
    let maxPixelSize: CGFloat

    /// `Color.clear` takes the offered size and the oversized image rides in an overlay, so the
    /// greedy aspect-fill child can never inflate the band it is drawn into.
    var body: some View {
        Color.clear
            .overlay(alignment: .catalogArtworkCrop) {
                CatalogRemoteImage(url: url, contentMode: .fill, maxPixelSize: maxPixelSize)
            }
            .clipped()
            // `clipped()` does not clip hit testing, and the aspect-fill overflow is hundreds of
            // points tall on a wide band.
            .contentShape(Rectangle())
    }
}

/// Resolves at three tenths of any view's height, so an overlay pairing it against an oversized
/// child leaves 30% of the overflow above the band and 70% below it at every band shape.
private enum CatalogArtworkCropAnchor: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat { context.height * 0.3 }
}

extension VerticalAlignment {
    static let catalogArtworkCrop = VerticalAlignment(CatalogArtworkCropAnchor.self)
}

extension Alignment {
    static let catalogArtworkCrop = Alignment(horizontal: .center, vertical: .catalogArtworkCrop)
}

/// A game's own wordmark where a banner would otherwise print its name. A game with no logo hands
/// this a nil URL, which fails the load on the first pass, so the title is the image's failure branch.
struct CatalogHeroWordmark: View {
    let logoURL: URL?
    let title: String
    /// Unscaled: `catalogFont` applies the interface scale. `boxHeight` is already scaled.
    let titlePointSize: CGFloat
    var titleLineLimit = 1
    /// Honoured only when there is a logo. The artwork arrives on a fixed 16:9 canvas whose ink
    /// fills a third to all of its height, so the band is a constant and the ink inside it varies.
    let boxHeight: CGFloat

    var body: some View {
        CatalogCachedImageView(
            url: logoURL,
            contentMode: .fit,
            maxPixelSize: CGFloat(CatalogLogoArtwork.requestWidth),
            placeholder: titleText.opacity(logoURL == nil ? 1 : 0),
            failure: titleText
        )
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
        // Reserving the band for a game with no logo would hang its title under an empty gap.
        .frame(height: logoURL == nil ? nil : boxHeight, alignment: .bottomLeading)
    }

    private var titleText: some View {
        Text(title)
            .catalogFont(size: titlePointSize, weight: .bold)
            .foregroundStyle(OpenNOWDesign.Text.primary)
            .lineLimit(titleLineLimit)
            .minimumScaleFactor(0.68)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
