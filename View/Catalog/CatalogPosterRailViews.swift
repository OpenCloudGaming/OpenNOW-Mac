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
    @Environment(\.opnUIScale) private var uiScale
    @Environment(\.opnTileDensity) private var tileDensity

    private var games: [OPNCatalogGameObject] {
        var visibleGames = section.visibleGames(expanded: false)
        guard let selectedGame = viewModel.selectedGame else { return visibleGames }
        if !viewModel.selectedSectionId.isEmpty, viewModel.selectedSectionId != section.id { return visibleGames }
        guard !visibleGames.contains(where: { CatalogViewModel.looseIdentityMatches($0, selectedGame) }),
              let sectionGame = section.games.first(where: { CatalogViewModel.looseIdentityMatches($0, selectedGame) }) else { return visibleGames }
        visibleGames.append(sectionGame)
        return visibleGames
    }
    private var canShowAll: Bool { section.canLoadFullList }
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
            HStack {
                Text(section.title)
                    .catalogFont(size: 20, weight: .medium)
                    .foregroundStyle(OPNDesign.Text.primary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if canShowAll {
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
                            ForEach(games, id: \.catalogIdentity) { game in
                                EquatableView(content: CatalogPosterTile(
                                    game: game,
                                    imageURL: viewModel.optimizedImageURL(game.bestPosterImageURL, width: 512),
                                    isSelected: isSelected(game),
                                    isSelectionActive: viewModel.selectedGame != nil,
                                    isQueuedForPatching: viewModel.isQueuedForPatching(game),
                                    isResumableSession: viewModel.isResumableSessionGame(game),
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
                            if canShowAll {
                                CatalogPosterSeeMoreTile(title: "Show All", action: onShowAll)
                            }
                        }
                        .frame(height: CatalogPosterLayout.tileRowHeight(scale: uiScale, density: tileDensity))
                        .padding(.horizontal, CatalogVendorLayout.carouselContainerMargin(scale: uiScale))
                        .padding(.bottom, 4 * uiScale)
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
        .onAppear { prefetchNearVisibleImages() }
        .onChange(of: games.map(\.catalogIdentity)) { _, _ in prefetchNearVisibleImages() }
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
        viewModel.prefetchPosterImages(section: section, games: games)
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
