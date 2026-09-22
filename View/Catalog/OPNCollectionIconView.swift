//  One collection's glyph, wherever a collection is drawn. A symbol is rendered from SF Symbols; an
//  image is read from the icon store. Either falls back to the catalog default, so a deleted image
//  or a symbol missing from this macOS never leaves a blank tile.

import AppKit
import Combine
import SwiftUI

struct OPNCollectionIconView: View {
    let icon: OPNCollectionIcon
    /// The unscaled square the glyph draws in. The view scales it, and `catalogFont` scales the
    /// symbol, so callers pass the same base size the surrounding text uses.
    let size: CGFloat
    var weight: OPNUIFont.Weight = .bold
    @Environment(\.opnUIScale) private var uiScale
    /// Bumped when the icon store changes so a glyph whose image arrives after the first draw — an
    /// iCloud download in particular — reloads instead of staying on its fallback. Changing state
    /// re-runs the body, which re-reads the store.
    @State private var storeRevision = 0

    var body: some View {
        let resolved = icon.validated ?? .fallback
        Group {
            if resolved.kind == .image, let image = OPNCollectionIconStore.image(for: resolved.value) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: symbolName(for: resolved))
                    .catalogFont(size: size, weight: weight)
            }
        }
        .frame(width: size * uiScale, height: size * uiScale)
        .onReceive(NotificationCenter.default.publisher(for: OPNCollectionIconStore.didChangeNotification)) { _ in
            storeRevision &+= 1
        }
    }

    private func symbolName(for resolved: OPNCollectionIcon) -> String {
        guard resolved.kind == .symbol,
              NSImage(systemSymbolName: resolved.value, accessibilityDescription: nil) != nil else {
            return OPNCollectionIcon.defaultSymbolName
        }
        return resolved.value
    }
}
