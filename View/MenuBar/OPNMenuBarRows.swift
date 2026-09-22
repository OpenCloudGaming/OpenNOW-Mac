import SwiftUI

/// The row metrics the popover's lists share. Fixed rather than measured, so a list's height is
/// computed instead of probed and the panel can hold one cap for every list.
enum OPNMenuBarListMetrics {
    /// How many rows a list shows before it starts to scroll, so a long list holds the panel's height.
    static let visibleRows = 5
    /// One game row's height: the 34pt artwork with 5pt above and below it.
    static let rowHeight: CGFloat = 44
    static let rowSpacing: CGFloat = 8

    static var visibleHeight: CGFloat {
        let rows = CGFloat(visibleRows)
        return rows * rowHeight + (rows - 1) * rowSpacing
    }
}

/// A list that grows with its contents and scrolls past the shared row cap; the scroll view is only
/// introduced then, because one capped by `maxHeight` is greedy even when the list is shorter.
struct OPNMenuBarCappedList<Rows: View>: View {
    let rowCount: Int
    private let rows: Rows

    init(rowCount: Int, @ViewBuilder rows: () -> Rows) {
        self.rowCount = rowCount
        self.rows = rows()
    }

    var body: some View {
        if rowCount > OPNMenuBarListMetrics.visibleRows {
            ScrollView(.vertical) {
                rows
            }
            .scrollIndicators(.visible)
            .frame(height: OPNMenuBarListMetrics.visibleHeight)
        } else {
            rows
        }
    }
}

/// A game row's box art, drawn from the catalog's own image cache so opening the popover never
/// re-downloads something the catalog already has.
struct OPNMenuBarArtwork: View {
    let url: String?

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "gamecontroller.fill")
                    .font(.opnUI(size: 14, weight: .bold))
                    .foregroundStyle(OPNDesign.Text.muted)
            }
        }
        .frame(width: 34, height: 34)
        .background(OPNDesign.Fill.neutral(0.08))
        // swiftlint:disable:next design_no_corner_radius -- status-item popover chrome: artwork tiles match the Control Center cards this surface is modelled on
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: url) { await load() }
    }

    private func load() async {
        // Cleared first: a row can be reused for another game, and a stale cover is worse than the
        // placeholder while the new one loads.
        image = nil
        guard let url, let parsed = URL(string: url) else { return }
        let cached = await CatalogImageCache.shared.image(for: parsed, maxPixelSize: 96)
        image = cached?.image
    }
}

/// One game in a list: box art, title, and the play timestamp a Continue Playing row adds, with the
/// glyph the row launches from.
struct OPNMenuBarGameRow: View {
    let game: OPNMenuBarGame
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 9) {
            OPNMenuBarArtwork(url: game.artworkURL)
            VStack(alignment: .leading, spacing: 1) {
                Text(game.title)
                    .font(.opnUI(size: 12.5, weight: .semibold))
                    .foregroundStyle(OPNDesign.Text.primary)
                    .lineLimit(1)
                // The card's header already says what the list is; only the play timestamp adds
                // anything, so a favorite or a collection member is a title-only row.
                if let lastPlayedText = OPNMenuBarReadout.lastPlayedText(for: game.lastPlayedAt) {
                    Text(lastPlayedText)
                        .font(.opnUI(size: 10.5, weight: .medium))
                        .foregroundStyle(OPNDesign.Text.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Image(systemName: "play.fill")
                .font(.opnUI(size: 10, weight: .bold))
                .foregroundStyle(isEnabled ? OPNDesign.accent : OPNDesign.Text.muted)
        }
        .padding(.horizontal, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: OPNMenuBarListMetrics.rowHeight)
        .opnMenuBarRow()
    }
}

/// A game row that starts its session.
struct OPNMenuBarGameButton: View {
    let game: OPNMenuBarGame
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            OPNMenuBarGameRow(game: game, isEnabled: isEnabled)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel("Launch \(game.title)")
    }
}

/// A card's eyebrow: what the list below it is.
struct OPNMenuBarEyebrow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.opnUI(size: 10, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(OPNDesign.Text.muted)
    }
}

/// The line a card shows when its list has nothing to draw, or when it has something to explain.
struct OPNMenuBarEmptyText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.opnUI(size: 11.5, weight: .medium))
            .foregroundStyle(OPNDesign.Text.tertiary)
            .padding(.vertical, 2)
    }
}
