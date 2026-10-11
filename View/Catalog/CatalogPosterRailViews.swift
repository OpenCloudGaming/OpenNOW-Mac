//  The Poster home layout's rail and destination grid content - portrait twins of CatalogRailView
//  and CatalogDestinationGridView's inner grid, sized entirely off CatalogPosterLayout.
//

import SwiftUI

struct CatalogPosterRailView: View {
    let viewModel: CatalogViewModel
    let section: CatalogSectionModel
    /// Width of the page, not of the scroll content - same contract as `CatalogRailView`.
    var availableWidth: CGFloat = 0
    let onShowAll: () -> Void
    @State private var scrollIndex = 0
    @State private var isRailHovering = false
    @State private var hoveredTileIdentity: String?
    /// Mirror of `CatalogRailView`'s window state: only growth is recorded, the window's own size
    /// comes from `CatalogRailMaterialization`.
    @State private var materializedGameCount = 0
    /// Whether the rail is inside the page's viewport, so an off-screen rail does not warm artwork
    /// the reader has not scrolled to. See `CatalogRailView`.
    @State private var isRailVisible = false
    @Environment(\.opnUIScale) private var uiScale
    @Environment(\.opnTileDensity) private var tileDensity

    /// Every game this rail can scroll to. The row draws a window of this list, not the whole of it.
    private var games: [OPNCatalogGameObject] {
        var visibleGames = section.visibleGames(expanded: false)
        guard let selectedGame = viewModel.selectedGame else { return visibleGames }
        if !viewModel.selectedSectionId.isEmpty, viewModel.selectedSectionId != section.id { return visibleGames }
        guard !visibleGames.contains(where: { CatalogViewModel.looseIdentityMatches($0, selectedGame) }),
              let sectionGame = section.games.first(where: { CatalogViewModel.looseIdentityMatches($0, selectedGame) }) else { return visibleGames }
        visibleGames.append(sectionGame)
        return visibleGames
    }
    private var materializedEnd: Int {
        CatalogRailMaterialization.end(
            gameCount: games.count,
            tilesPerScreen: tilesPerScreen,
            materialized: materializedGameCount,
            required: selectedGameEnd
        )
    }
    /// The games the row materializes right now. A slice rather than an array: this is read from
    /// the body, and copying the window on every pass is the allocation the window exists to bound.
    private var materializedGames: ArraySlice<OPNCatalogGameObject> {
        games.prefix(materializedEnd)
    }
    private var tilesPerScreen: Int {
        CatalogRailMaterialization.tilesPerScreen(availableWidth: availableWidth, scale: uiScale, density: tileDensity, isPoster: true)
    }
    private var selectedGameEnd: Int {
        guard let selectedGame = viewModel.selectedGame,
              let index = games.firstIndex(where: { CatalogViewModel.looseIdentityMatches($0, selectedGame) }) else { return 0 }
        return index + 1
    }
    private var canShowAll: Bool { section.canLoadFullList }
    /// Mirror of `CatalogRailView.showsHeaderShowAll` for the portrait rail: every tile claims one
    /// poster slot and the two container margins, with no spacing between `LazyHStack` children.
    private var showsHeaderShowAll: Bool {
        guard canShowAll else { return false }
        let itemCount = games.count + section.tiles.count + 1
        let slotWidth = CatalogPosterLayout.slotWidth(scale: uiScale, density: tileDensity)
        let contentWidth = CatalogVendorLayout.carouselContainerMargin(scale: uiScale) * 2 + CGFloat(itemCount) * slotWidth
        return CatalogRailShowAllPlacement.showsHeaderLink(availableWidth: availableWidth, contentWidth: contentWidth)
    }
    private var collectionIcon: OPNCollectionIcon? {
        guard case .userCollection(let id) = section.kind else { return nil }
        return viewModel.collection(id: id)?.resolvedIcon
    }
    private var columnCount: Int { CatalogPosterLayout.columnCount(forWidth: availableWidth, scale: uiScale, density: tileDensity) }

    var body: some View {
        if section.isPlaceholder {
            CatalogRailSkeletonView(title: section.title, isPosterLayout: true)
                .transition(.opacity)
        } else {
            loadedBody
        }
    }

    private var loadedBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10 * uiScale) {
                if let collectionIcon {
                    OPNCollectionIconView(icon: collectionIcon, size: 18, weight: .bold)
                        .foregroundStyle(OPNDesign.accentInk)
                }
                Text(section.title)
                    .catalogFont(size: 20, weight: .medium)
                    .foregroundStyle(OPNDesign.Text.primary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if showsHeaderShowAll {
                    Button("SHOW ALL", action: onShowAll)
                        .buttonStyle(.plain)
                        .catalogFont(size: 13, weight: .bold)
                        .foregroundStyle(OPNDesign.Text.primary)
                }
            }
            .frame(height: 28 * uiScale)
            .padding(.horizontal, CatalogVendorLayout.sectionHeaderMargin(scale: uiScale))

            ScrollViewReader { proxy in
                ZStack {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 0) {
                            ForEach(materializedGames, id: \.catalogIdentity) { game in
                                EquatableView(content: CatalogPosterTile(
                                    game: game,
                                    imageURL: viewModel.optimizedImageURL(game.bestPosterImageURL, width: 512),
                                    isSelected: isSelected(game),
                                    isSelectionActive: viewModel.selectedGame != nil,
                                    isQueuedForPatching: viewModel.isQueuedForPatching(game),
                                    isResumableSession: viewModel.isResumableSessionGame(game),
                                    isWatched: viewModel.isWatching(game),
                                    showsFreeAccountAccessBadges: viewModel.isFreeTierAccount,
                                    onSelect: { viewModel.toggleGameSelection(game, inSection: section.id) },
                                    onPlay: { viewModel.launch(game: game) },
                                    onMarkOwned: {
                                        viewModel.selectGame(game, inSection: section.id)
                                        viewModel.handleUnownedSelectedVariantPrimaryAction()
                                    },
                                    onQueueForPatching: { viewModel.queuePatchingLaunch(game: game) },
                                    onHoverChanged: { hovering in
                                        hoveredTileIdentity = hovering ? game.catalogIdentity : (hoveredTileIdentity == game.catalogIdentity ? nil : hoveredTileIdentity)
                                        viewModel.isPointerInsideGameTile = hovering
                                    }
                                ))
                                    .id(game.catalogIdentity)
                                    .zIndex(hoveredTileIdentity == game.catalogIdentity ? 1 : 0)
                            }
                            ForEach(Array(section.tiles.enumerated()), id: \.offset) { _, tile in
                                CatalogPosterActionTile(
                                    tile: tile,
                                    imageURL: viewModel.optimizedImageURL(tile.imageUrl, width: 768),
                                    action: { viewModel.openPanelTile(tile) }
                                )
                            }
                            // Only once the window covers the rail. Drawing it at the window's own end
                            // would move the affordance one screen right every time the window grew.
                            if canShowAll, materializedGames.count == games.count {
                                CatalogPosterSeeMoreTile(title: "Show All", action: onShowAll)
                            }
                        }
                        .frame(height: CatalogPosterLayout.tileRowHeight(scale: uiScale, density: tileDensity))
                        .padding(.horizontal, CatalogVendorLayout.carouselContainerMargin(scale: uiScale))
                        .padding(.bottom, 4 * uiScale)
                        .onScrollGeometryChange(for: Bool.self) { geometry in
                            let remaining = geometry.contentSize.width - geometry.contentOffset.x - geometry.containerSize.width
                            return remaining <= CatalogRailMaterialization.trailingTriggerDistance(
                                availableWidth: availableWidth,
                                scale: uiScale,
                                density: tileDensity,
                                isPoster: true
                            )
                        } action: { _, isNearTrailingEdge in
                            guard isNearTrailingEdge else { return }
                            extendMaterializedWindow()
                        }
                    }
                    if games.count > columnCount {
                        HStack {
                            CatalogRailArrow(name: "arrow-left") {
                                moveRail(proxy: proxy, delta: -max(1, columnCount - 1))
                            }
                            Spacer()
                            CatalogRailArrow(name: "arrow-right") {
                                moveRail(proxy: proxy, delta: max(1, columnCount - 1))
                            }
                        }
                        .padding(.horizontal, 8)
                        .opacity(isRailHovering ? 1 : 0)
                        .allowsHitTesting(isRailHovering)
                        .accessibilityHidden(!isRailHovering)
                        .opnMotion(OPNDesign.Motion.hover, value: isRailHovering)
                    }
                }
                .onHover { isRailHovering = $0 }
                .onAppear { revealSelectedGameIfNeeded(proxy: proxy, request: viewModel.selectedGameRevealRequest) }
                .onChange(of: viewModel.selectedGameRevealRequest) { _, request in revealSelectedGameIfNeeded(proxy: proxy, request: request) }
            }
        }
        .frame(maxWidth: availableWidth > 0 ? availableWidth : .infinity, alignment: .leading)
        // Warm only the rails the page is actually showing - see `CatalogRailView`.
        .onScrollVisibilityChange(threshold: 0.01) { isVisible in
            isRailVisible = isVisible
            guard isVisible else { return }
            prefetchNearVisibleImages()
        }
        .onChange(of: section.gameIdentitySignature) { _, _ in
            guard isRailVisible else { return }
            prefetchNearVisibleImages()
        }
        // See `CatalogRailView`: the screen follows the width, the interface scale and the density.
        .onChange(of: tilesPerScreen) { _, _ in
            guard isRailVisible else { return }
            prefetchNearVisibleImages()
        }
    }

    private func extendMaterializedWindow() {
        let grown = CatalogRailMaterialization.grownEnd(gameCount: games.count, tilesPerScreen: tilesPerScreen, current: materializedEnd)
        guard grown != materializedEnd else { return }
        materializedGameCount = grown
    }

    private func moveRail(proxy: ScrollViewProxy, delta: Int) {
        guard !games.isEmpty else { return }
        scrollIndex = min(max(scrollIndex + delta, 0), max(games.count - 1, 0))
        withAnimation(.easeInOut(duration: 0.22)) {
            proxy.scrollTo(games[scrollIndex].catalogIdentity, anchor: .leading)
        }
    }

    private func isSelected(_ game: OPNCatalogGameObject) -> Bool {
        guard let selectedGame = viewModel.selectedGame else { return false }
        if !viewModel.selectedSectionId.isEmpty, viewModel.selectedSectionId != section.id { return false }
        return CatalogViewModel.looseIdentityMatches(selectedGame, game)
    }

    private func prefetchNearVisibleImages() {
        viewModel.prefetchPosterImages(section: section, games: games, limit: tilesPerScreen)
    }

    private func revealSelectedGameIfNeeded(proxy: ScrollViewProxy, request: CatalogGameRevealRequest?) {
        guard let request, request.sectionId.isEmpty || request.sectionId == section.id else { return }
        guard games.contains(where: { $0.catalogIdentity == request.gameIdentity }) else { return }
        Task { @MainActor in
            guard games.contains(where: { $0.catalogIdentity == request.gameIdentity }) else { return }
            withAnimation(.easeInOut(duration: 0.24)) {
                proxy.scrollTo(request.gameIdentity, anchor: .center)
            }
        }
    }
}
