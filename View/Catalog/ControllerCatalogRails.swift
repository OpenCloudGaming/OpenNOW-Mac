//  The hero billboard and the game rails beneath it, plus the tile they are made of.
//  Split out of ControllerCatalogView.swift.
//

import AppKit
import SwiftUI

struct ControllerHeroBillboard: View {
    let viewModel: CatalogViewModel
    let game: OPNCatalogGameObject?
    let height: CGFloat

    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let game {
                CatalogRemoteImage(url: viewModel.optimizedImageURL(game.bestMarqueeHeroImageURL, width: 1920), contentMode: .fill, maxPixelSize: 1920)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .contentShape(Rectangle())
                LinearGradient(colors: [.black.opacity(0.94), .black.opacity(0.48), .black.opacity(0.10)], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.clear, .black.opacity(0.76)], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 9 * uiScale) {
                    Text("NOW PLAYING IN THE CLOUD")
                        .nvidiaFont(size: 11, weight: .bold)
                        .tracking(1.6)
                        .foregroundStyle(OpenNOWDesign.accent)
                    Text(game.title.isEmpty ? "GeForce NOW" : game.title)
                        .nvidiaFont(size: height < 260 ? 31 : 36, weight: .bold)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                    HStack(spacing: 10 * uiScale) {
                        if !game.ratingLabel.isEmpty { ControllerMetadataPill(text: game.ratingLabel) }
                        if game.supportsGamepad { ControllerMetadataPill(text: "Gamepad") }
                        if game.isInLibrary { ControllerMetadataPill(text: "In Library", highlighted: true) }
                        if let badge = game.cardBadgeLabel { ControllerMetadataPill(text: badge) }
                    }
                    Text(heroDescription(game))
                        .nvidiaFont(size: 13, weight: .medium)
                        .foregroundStyle(.white.opacity(0.74))
                        .lineLimit(height < 260 ? 1 : 2)
                        .frame(maxWidth: 650 * uiScale, alignment: .leading)
                }
                .padding(.horizontal, 28 * uiScale)
                .padding(.vertical, (height < 260 ? 20 : 24) * uiScale)
                .frame(maxWidth: 720 * uiScale, maxHeight: .infinity, alignment: .bottomLeading)
            } else {
                CatalogImageFallback()
            }
        }
        .frame(height: height)
        .background(Color.black.opacity(0.34))
        .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.subtle, lineWidth: 1) }
        .clipped()
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
                    .nvidiaFont(size: isFocused ? 24 : 21, weight: .bold)
                    .foregroundStyle(isFocused ? .white : .white.opacity(0.84))
                if !section.isPlaceholder {
                    Text("\(section.games.count) games".uppercased())
                        .nvidiaFont(size: 11, weight: .bold)
                        .foregroundStyle(OpenNOWDesign.accent.opacity(0.82))
                }
                Spacer(minLength: 0)
                if canShowAll, !section.isPlaceholder {
                    Button("SHOW ALL", action: showAll)
                        .buttonStyle(.plain)
                        .nvidiaFont(size: 12, weight: .bold)
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
                                .nvidiaFont(size: 12, weight: .bold)
                                .foregroundStyle(OpenNOWDesign.accent)
                        }
                        Text(game.title.isEmpty ? "GeForce NOW" : game.title)
                            .nvidiaFont(size: 16, weight: .bold)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    Text(subtitle)
                        .nvidiaFont(size: 11, weight: .bold)
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
                    .nvidiaFont(size: 11, weight: .bold)
                    .foregroundStyle(OpenNOWDesign.accent)
                    .tracking(1.4)
                Text(subtitle)
                    .nvidiaFont(size: 15, weight: .medium)
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
