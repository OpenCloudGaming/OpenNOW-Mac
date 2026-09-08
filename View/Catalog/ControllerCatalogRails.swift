//  The hero billboard and the game rails beneath it, plus the tile they are made of.
//

import AppKit
import SwiftUI

struct ControllerHeroBillboard: View {
    let viewModel: CatalogViewModel
    let game: OPNCatalogGameObject?
    let height: CGFloat

    @Environment(\.opnUIScale) private var uiScale
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let game {
                caption(for: game)
                    // The band's height is the floor or the caption, whichever is larger. The
                    // artwork is a background so it fills that height without being able to set
                    // it - as a stacked sibling its `maxHeight: .infinity` swallowed the whole
                    // scroll viewport and took the band with it.
                    .frame(maxWidth: .infinity, minHeight: height, alignment: .bottomLeading)
                    .background {
                        ZStack {
                            CatalogHeroArtwork(url: viewModel.optimizedImageURL(game.bestMarqueeHeroImageURL, width: billboardArtworkPixels), maxPixelSize: CGFloat(billboardArtworkPixels))
                            LinearGradient(colors: [.black.opacity(0.94), .black.opacity(0.48), .black.opacity(0.10)], startPoint: .leading, endPoint: .trailing)
                            LinearGradient(colors: [.clear, .black.opacity(0.76)], startPoint: .top, endPoint: .bottom)
                        }
                    }
            } else {
                CatalogImageFallback()
                    .frame(maxWidth: .infinity, minHeight: height)
            }
        }
        .clipped()
        .background(Color.black.opacity(0.34))
        .overlay { Rectangle().strokeBorder(OpenNOWDesign.Stroke.subtle, lineWidth: 1) }
    }

    private func caption(for game: OPNCatalogGameObject) -> some View {
        VStack(alignment: .leading, spacing: captionSpacing * uiScale) {
            CatalogHeroWordmark(
                logoURL: viewModel.optimizedImageURL(game.bestLogoImageURL, width: CatalogLogoArtwork.requestWidth),
                title: game.title.isEmpty ? "GeForce NOW" : game.title,
                titlePointSize: titlePointSize,
                boxHeight: headHeight * uiScale
            )
            if showsPills { pillRow(for: game) }
            if showsDescription {
                Text(heroDescription(game))
                    .catalogFont(size: descriptionPointSize, weight: .medium)
                    .foregroundStyle(.white.opacity(0.74))
                    .lineLimit(descriptionLineLimit)
                    .frame(maxWidth: descriptionWidth * uiScale, alignment: .leading)
            }
        }
        .padding(.horizontal, captionHorizontalPadding * uiScale)
        .padding(.vertical, captionVerticalPadding * uiScale)
        .frame(maxWidth: captionWidth * uiScale, alignment: .leading)
    }

    /// `height` already carries the interface scale and `catalogFont` applies it again, so every
    /// ratio below is taken against the unscaled band to avoid scaling twice.
    @ViewBuilder
    private func pillRow(for game: OPNCatalogGameObject) -> some View {
        HStack(spacing: 10 * uiScale) {
            if !game.ratingLabel.isEmpty { ControllerMetadataPill(text: game.ratingLabel) }
            if game.supportsGamepad { ControllerMetadataPill(text: "Gamepad") }
            if game.isInLibrary { ControllerMetadataPill(text: "In Library", highlighted: true) }
            if let badge = game.cardBadgeLabel { ControllerMetadataPill(text: badge) }
        }
    }

    private var unscaledHeight: CGFloat { height / max(uiScale, 0.01) }

    /// The band is full-bleed and roughly cinematic, so its drawn width tracks its height; asking by
    /// height keeps the request on the same ladder as the two game-page heroes.
    private var billboardArtworkPixels: Int {
        CatalogArtworkResolution.pixelWidth(renderedWidth: height * 3, displayScale: displayScale)
    }

    /// The caption is sized from the band rather than from breakpoints, so it shrinks to fit any
    /// window shape instead of overflowing and being cut off at whatever height the band lands on.
    /// Each maximum below is its own ratio taken at `unscaledHeight` 520, the tallest band
    /// `ControllerLayoutMetrics` can produce, so the clamp guards that ceiling rather than shaping.
    private var titlePointSize: CGFloat { OpenNOWDesign.clamped(unscaledHeight * 0.15, minimum: 17, maximum: 78) }

    private var captionSpacing: CGFloat { OpenNOWDesign.clamped(unscaledHeight * 0.035, minimum: 3, maximum: 18) }

    private var captionVerticalPadding: CGFloat { OpenNOWDesign.clamped(unscaledHeight * 0.085, minimum: 8, maximum: 44) }

    /// Held at the same 1.56:1 ratio to the vertical inset the flat 28 used to give a laptop band -
    /// left flat it inverts on a 5K banner and the text hugs the edge of a 5000pt image.
    private var captionHorizontalPadding: CGFloat { OpenNOWDesign.clamped(unscaledHeight * 0.13, minimum: 28, maximum: 68) }

    /// The column has to grow with the type or the larger title only triggers `minimumScaleFactor`
    /// and truncates. This holds roughly 26 characters at full size on every band.
    private var captionWidth: CGFloat { OpenNOWDesign.clamped(unscaledHeight * 2.3, minimum: 720, maximum: 1200) }

    private var descriptionPointSize: CGFloat { OpenNOWDesign.clamped(unscaledHeight * 0.042, minimum: 13, maximum: 22) }

    /// A 50-em measure, never wider than the caption column it sits inside.
    private var descriptionWidth: CGFloat { min(descriptionPointSize * 50, captionWidth - captionHorizontalPadding * 2) }

    private var isLogoAvailable: Bool { !(game?.bestLogoImageURL ?? "").isEmpty }

    /// Taller than the title row on purpose - the ink inside a 16:9 logo canvas can be a third of
    /// its height - but held under half the band so the metadata rows keep their share.
    private var logoBandHeight: CGFloat {
        min(OpenNOWDesign.clamped(unscaledHeight * 0.30, minimum: 56, maximum: 168), unscaledHeight * 0.44)
    }

    // Rough intrinsic heights of the optional rows, unscaled. Only used to decide what the band can
    // afford - the real layout still measures itself.
    private var pillsHeight: CGFloat { 30 }
    private var titleHeight: CGFloat { titlePointSize * 1.3 }

    /// What the caption's first row actually costs, logo or title. The frame above and the budget
    /// below both read this, so a tall wordmark can never push the pills out of the band.
    private var headHeight: CGFloat { isLogoAvailable ? logoBandHeight : titleHeight }

    private var descriptionLineLimit: Int { unscaledHeight >= 300 ? 2 : 1 }
    private var descriptionHeight: CGFloat { CGFloat(descriptionLineLimit) * descriptionPointSize * 1.38 }

    /// What is left for the caption's rows once its own padding is paid for.
    private var captionBudget: CGFloat { unscaledHeight - captionVerticalPadding * 2 }

    /// Each row is included only if the band can actually hold it alongside the title. Fixed
    /// breakpoints cut the caption in half at every height that fell between them.
    private var showsPills: Bool {
        captionBudget >= headHeight + pillsHeight + captionSpacing
    }

    private var showsDescription: Bool {
        captionBudget >= headHeight + pillsHeight + descriptionHeight + captionSpacing * 2
    }

    private func heroDescription(_ game: OPNCatalogGameObject) -> String {
        let description = game.shortDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty { return description }
        let genre = game.genres.prefix(2).joined(separator: ", ")
        return genre.isEmpty ? "Play instantly with GeForce NOW cloud streaming." : "\(genre) available on GeForce NOW."
    }
}

struct ControllerGameRail: View {
    let viewModel: CatalogViewModel
    let section: CatalogSectionModel
    @Binding var selectedIndex: Int
    let isFocused: Bool
    let layout: ControllerLayoutMetrics
    let openDetails: (OPNCatalogGameObject) -> Void
    let showAll: () -> Void

    private var games: [OPNCatalogGameObject] { section.visibleGames(expanded: false) }
    private var canShowAll: Bool { section.canLoadFullList }
    private var itemSpacing: CGFloat { 18 * uiScale }

    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        VStack(alignment: .leading, spacing: (layout.compactHeight ? 10 : 12) * uiScale) {
            HStack(alignment: .firstTextBaseline, spacing: 12 * uiScale) {
                Text(section.title)
                    .catalogFont(size: isFocused ? 24 : 21, weight: .bold)
                    .foregroundStyle(isFocused ? .white : .white.opacity(0.84))
                if !section.isPlaceholder {
                    Text("\(section.games.count) games".uppercased())
                        .catalogFont(size: 11, weight: .bold)
                        .foregroundStyle(OpenNOWDesign.accent.opacity(0.82))
                }
                Spacer(minLength: 0)
                if canShowAll, !section.isPlaceholder {
                    Button("SHOW ALL", action: showAll)
                        .buttonStyle(.plain)
                        .catalogFont(size: 12, weight: .bold)
                        .foregroundStyle(.white.opacity(0.82))
                }
            }
            .frame(width: layout.contentWidth, alignment: .leading)

            GeometryReader { geometry in
                let metrics = layoutMetrics(width: geometry.size.width)
                HStack(spacing: itemSpacing) {
                    if section.isPlaceholder {
                        // Deferred library/favorites rail. The row already reserves its height, so
                        // this only fills it with something that reads as loading rather than as an
                        // empty rail the user can focus and find nothing in.
                        ForEach(0..<metrics.visibleCount, id: \.self) { _ in
                            SkeletonBlock()
                                .frame(width: metrics.tileSize.width, height: metrics.tileSize.height)
                        }
                    }
                    ForEach(visibleGames(metrics: metrics), id: \.game.catalogIdentity) { item in
                        ControllerGameTile(
                            game: item.game,
                            imageURL: viewModel.optimizedImageURL(item.game.bestWideImageURL, width: 720),
                            isFocused: isFocused && selectedIndex == item.index,
                            isQueuedForPatching: viewModel.isQueuedForPatching(item.game),
                            showsFreeAccountAccessBadges: viewModel.isFreeTierAccount,
                            tileSize: metrics.tileSize,
                            action: { openDetails(item.game) }
                        )
                        .equatable()
                    }
                }
                .frame(width: geometry.size.width, height: metrics.rowHeight, alignment: .leading)
                .clipped()
            }
            .frame(height: estimatedRailHeight)
        }
        .onChange(of: games.count) { _, count in
            selectedIndex = min(selectedIndex, max(count - 1, 0))
        }
    }

    private var estimatedRailHeight: CGFloat {
        (layout.compactHeight ? 178 : 196) * uiScale
    }

    private func layoutMetrics(width: CGFloat) -> ControllerRailLayoutMetrics {
        let contentWidth = max(width, 1)
        let fitted = max(1, Int((contentWidth + itemSpacing) / (layout.railPreferredTileWidth + itemSpacing)))
        // A placeholder rail has no games to clamp against, so it fills the row instead of
        // collapsing to a single tile.
        let count = section.isPlaceholder ? fitted : min(fitted, max(games.count, 1))
        let totalSpacing = CGFloat(max(count - 1, 0)) * itemSpacing
        let tileWidth = floor(max((contentWidth - totalSpacing) / CGFloat(count), 1))
        let tileHeight = floor(tileWidth * 9 / 16)
        return ControllerRailLayoutMetrics(visibleCount: count, tileSize: CGSize(width: tileWidth, height: tileHeight), rowHeight: tileHeight + 4)
    }

    private func visibleGames(metrics: ControllerRailLayoutMetrics) -> [(index: Int, game: OPNCatalogGameObject)] {
        guard !games.isEmpty else { return [] }
        let selected = min(max(selectedIndex, 0), games.count - 1)
        let maxStart = max(games.count - metrics.visibleCount, 0)
        let start = min(max(selected - metrics.visibleCount + 1, 0), maxStart)
        let end = min(start + metrics.visibleCount, games.count)
        return Array(games[start..<end].enumerated()).map { offset, game in (index: start + offset, game: game) }
    }
}

struct ControllerRailLayoutMetrics {
    let visibleCount: Int
    let tileSize: CGSize
    let rowHeight: CGFloat
}

struct ControllerGameTile: View, Equatable {
    let game: OPNCatalogGameObject
    let imageURL: URL?
    let isFocused: Bool
    let isQueuedForPatching: Bool
    let showsFreeAccountAccessBadges: Bool
    let tileSize: CGSize
    let action: () -> Void

    // `View` conformance isolates the whole struct to the main actor, and `==` has to stay
    // `nonisolated` to satisfy `Equatable`, so it can only read stored properties that are both
    // `let` and `Sendable`. `OPNCatalogGameObject` is neither, so the identity the comparison
    // actually wants is snapshotted here at init instead of being derived from the object.
    private let gameIdentity: String

    init(
        game: OPNCatalogGameObject,
        imageURL: URL?,
        isFocused: Bool,
        isQueuedForPatching: Bool,
        showsFreeAccountAccessBadges: Bool,
        tileSize: CGSize,
        action: @escaping () -> Void
    ) {
        self.game = game
        self.imageURL = imageURL
        self.isFocused = isFocused
        self.isQueuedForPatching = isQueuedForPatching
        self.showsFreeAccountAccessBadges = showsFreeAccountAccessBadges
        self.tileSize = tileSize
        self.action = action
        self.gameIdentity = game.catalogIdentity
    }

    // The action closure is deliberately excluded: it is rebuilt on every parent render but always
    // targets the same game, and comparing it would defeat the `.equatable()` body-skip that keeps
    // a d-pad move from re-evaluating every visible tile. The card this replaced had exactly this
    // conformance; swapping it out silently dropped the skip.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.gameIdentity == rhs.gameIdentity
            && lhs.imageURL == rhs.imageURL
            && lhs.isFocused == rhs.isFocused
            && lhs.isQueuedForPatching == rhs.isQueuedForPatching
            && lhs.showsFreeAccountAccessBadges == rhs.showsFreeAccountAccessBadges
            && lhs.tileSize == rhs.tileSize
    }

    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topLeading) {
                CatalogRemoteImage(url: imageURL, contentMode: .fill, maxPixelSize: 720)
                    .frame(width: tileSize.width, height: tileSize.height)
                    .clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.82)], startPoint: .top, endPoint: .bottom)
                if let badge = game.cardBadgeLabel {
                    CatalogGameCardBadge(label: badge)
                        .scaleEffect(0.92, anchor: .topLeading)
                }
                if let badge = game.freeAccountAccessBadgeLabel(isFreeTierAccount: showsFreeAccountAccessBadges) {
                    CatalogGameAccessBadge(label: badge)
                        .scaleEffect(0.92, anchor: .topTrailing)
                        .padding(9 * uiScale)
                        .frame(width: tileSize.width, height: tileSize.height, alignment: .topTrailing)
                }
                VStack(alignment: .leading, spacing: 7 * uiScale) {
                    Spacer(minLength: 0)
                    HStack(spacing: 8 * uiScale) {
                        if game.isLaunchPatching {
                            Image(systemName: isQueuedForPatching ? "clock.fill" : "wrench.and.screwdriver.fill")
                                .catalogFont(size: 12, weight: .bold)
                                .foregroundStyle(OpenNOWDesign.accent)
                        }
                        Text(game.title.isEmpty ? "GeForce NOW" : game.title)
                            .catalogFont(size: 16, weight: .bold)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    Text(subtitle)
                        .catalogFont(size: 11, weight: .bold)
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                }
                .padding(15 * uiScale)
            }
            .frame(width: tileSize.width, height: tileSize.height)
            .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.subtle, lineWidth: 1) }
            .openNowFocusRing(isFocused)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(game.title.isEmpty ? "Game" : game.title)
    }

    private var subtitle: String {
        if game.isLaunchPatching { return isQueuedForPatching ? "Queued for patch completion" : game.patchStatusPrimaryDisplayText }
        if game.isInLibrary { return "In Library" }
        if !game.primaryStoreLabel.isEmpty { return game.primaryStoreLabel }
        return game.supportsGamepad ? "Gamepad supported" : "Cloud ready"
    }
}

struct ControllerEmbeddedPage<Content: View>: View {
    let title: String
    let subtitle: String
    let layout: ControllerLayoutMetrics
    private let content: Content

    init(title: String, subtitle: String, layout: ControllerLayoutMetrics, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.layout = layout
        self.content = content()
    }

    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        VStack(alignment: .leading, spacing: 16 * uiScale) {
            VStack(alignment: .leading, spacing: 6 * uiScale) {
                Text(title.uppercased())
                    .catalogFont(size: 11, weight: .bold)
                    .foregroundStyle(OpenNOWDesign.accent)
                    .tracking(1.4)
                Text(subtitle)
                    .catalogFont(size: 15, weight: .medium)
                    .foregroundStyle(.white.opacity(0.62))
            }
            .frame(width: layout.contentWidth, alignment: .leading)
            .padding(.top, 20 * uiScale)

            content
                .clipShape(Rectangle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Index arithmetic for the search page's filter bar: slot 0 is sort, then one slot per visible
/// filter group, then the clear-filters chip. The input handler and the chips both read it so the
/// focused chip and the moved-to chip are always the same one.
/// An open list of options for one chip in the filter bar. Confirming a chip used to advance it
/// blind to its next option, so there was no way to see what a group offered or pick a specific
/// sort - only to cycle and watch the results change.
