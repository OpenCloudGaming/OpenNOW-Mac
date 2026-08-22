//
//  CatalogContentViews.swift
//  MacForceNow
//

import AppKit
import AVKit
import Combine
import CryptoKit
import ImageIO
import SwiftUI

struct CatalogContentView: View {
    let viewModel: CatalogViewModel
    @State private var heroIndex = 0
    @State private var heroAutoScrollEnabled = true
    @State private var isPointerInsideDetailPanel = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.opnUIScale) private var uiScale
    private let heroTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        let heroes = heroGames
        let hero = heroes.indices.contains(heroIndex) ? heroes[heroIndex] : heroes.first
        GeometryReader { viewport in
            if viewModel.selectedShowAllSection != nil {
                CatalogShowAllPage(viewModel: viewModel, onBack: { viewModel.closeShowAll() })
            } else {
                let sections = viewModel.catalogSections
                let isGridDestination = shouldUseGrid(for: viewModel.selectedCatalogDestination)
                ScrollViewReader { proxy in
                    ZStack {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 26) {
                                if viewModel.isActiveHomeSessionVisible, let session = viewModel.activeHomeSession {
                                    VendorActiveSessionHomeBanner(
                                        title: viewModel.activeHomeSessionTitle,
                                        isResumable: session.isResumable,
                                        serverIp: session.serverIp,
                                        onResume: { viewModel.resumeActiveHomeSession() },
                                        onEnd: { viewModel.endActiveHomeSession() }
                                    )
                                }

                                if hero != nil && !isGridDestination {
                                    CatalogHeroView(
                                        viewModel: viewModel,
                                        games: heroes,
                                        activeIndex: heroes.indices.contains(heroIndex) ? heroIndex : 0,
                                        availableWidth: viewport.size.width,
                                        availableHeight: viewport.size.height,
                                        onSelectSlide: { index in
                                            heroAutoScrollEnabled = false
                                            heroIndex = index
                                        },
                                        onPreviousSlide: {
                                            guard !heroes.isEmpty else { return }
                                            heroAutoScrollEnabled = false
                                            heroIndex = max(heroIndex - 1, 0)
                                        },
                                        onNextSlide: {
                                            guard !heroes.isEmpty else { return }
                                            heroAutoScrollEnabled = false
                                            heroIndex = min(heroIndex + 1, heroes.count - 1)
                                        }
                                    )
                                }

                                if !viewModel.errorMessage.isEmpty {
                                    CatalogMessageView(message: viewModel.errorMessage, systemImage: "exclamationmark.triangle.fill")
                                        .padding(.horizontal, CatalogVendorLayout.sectionHeaderMargin(scale: uiScale))
                                }
                                if viewModel.isBrowseMode {
                                    CatalogBrowseControlsView(viewModel: viewModel)
                                        .padding(.horizontal, CatalogVendorLayout.sectionHeaderMargin(scale: uiScale))
                                }
                                if isGridDestination, let section = sections.first {
                                    CatalogDestinationGridView(viewModel: viewModel, section: section)
                                    if selectedGameBelongs(to: section), let detailAnchor = selectedDetailScrollAnchor {
                                        GameDetailPanel(
                                            viewModel: viewModel,
                                            availableWidth: max(0, viewport.size.width - CatalogVendorLayout.sectionHeaderMargin(scale: uiScale) * 2),
                                            viewportHeight: viewport.size.height
                                        )
                                            .padding(.top, -10)
                                            .padding(.bottom, 22)
                                            .padding(.horizontal, CatalogVendorLayout.sectionHeaderMargin(scale: uiScale))
                                            .onHover { isPointerInsideDetailPanel = $0 }
                                            .id(detailAnchor)
                                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                                    }
                                } else {
                                    ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                                        let showsDetail = shouldShowDetail(afterSectionAt: index, sections: sections)
                                        if showsDetail, let railAnchor = selectedRailScrollAnchor {
                                            Color.clear
                                                .frame(height: 0)
                                                .id(railAnchor)
                                        }
                                        CatalogRailView(viewModel: viewModel, section: section, onShowAll: { viewModel.openShowAll(section) })
                                        if showsDetail, let detailAnchor = selectedDetailScrollAnchor {
                                            GameDetailPanel(
                                                viewModel: viewModel,
                                                availableWidth: viewport.size.width,
                                                viewportHeight: viewport.size.height
                                            )
                                                .padding(.top, -8)
                                                .padding(.bottom, 22)
                                                .onHover { isPointerInsideDetailPanel = $0 }
                                                .id(detailAnchor)
                                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                                        }
                                    }
                                }

                                if sections.isEmpty && !viewModel.isLoading && !viewModel.isLoadingPanels {
                                    CatalogEmptyDestinationView(viewModel: viewModel, destination: viewModel.selectedCatalogDestination)
                                        .padding(.horizontal, CatalogVendorLayout.sectionHeaderMargin(scale: uiScale))
                                        .padding(.top, viewModel.selectedCatalogDestination == .home ? 52 : 118)
                                }
                            }
                            .padding(.bottom, 44)
                        }
                        .background(
                            MacForceNowDesign.Surface.app
                                .contentShape(Rectangle())
                                .onTapGesture { viewModel.closeGameDetailsFromBackground() }
                        )
                        .simultaneousGesture(TapGesture().onEnded {
                            guard viewModel.selectedGame != nil, !isPointerInsideDetailPanel else { return }
                            viewModel.closeGameDetailsFromBackground()
                        })

                        if (viewModel.isLoading || viewModel.isLoadingPanels) && sections.isEmpty {
                            CatalogHomeSkeletonView(availableWidth: viewport.size.width)
                                .transition(.opacity)
                        }
                    }
                    .onChange(of: selectedRailScrollAnchor) { _, anchor in
                        scrollToSelectedRail(anchor, proxy: proxy)
                    }
                    .onChange(of: viewModel.selectedGameRevealRequest) { _, _ in
                        scrollToSelectedRail(selectedRailScrollAnchor, proxy: proxy)
                    }
                }
                .background(MacForceNowDesign.Surface.app)
                .onReceive(heroTimer) { _ in
                    guard !reduceMotion, heroAutoScrollEnabled, heroes.count > 1 else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        heroIndex = (heroIndex + 1) % heroes.count
                    }
                }
                .onChange(of: heroIdentityList) { _, identities in
                    guard !identities.isEmpty else {
                        heroIndex = 0
                        return
                    }
                    if heroIndex >= identities.count { heroIndex = 0 }
                }
            }
        }
    }

    private var heroGames: [OPNCatalogGameObject] {
        viewModel.heroRotationGames
    }

    private var selectedRailScrollAnchor: String? {
        guard let selectedGame = viewModel.selectedGame else { return nil }
        return "rail-\(viewModel.selectedSectionId)-\(selectedGame.catalogIdentity)"
    }

    private var heroIdentityList: [String] {
        heroGames.map { CatalogViewModel.identity(for: $0) }
    }

    private var selectedDetailScrollAnchor: String? {
        guard let selectedGame = viewModel.selectedGame else { return nil }
        return "detail-\(viewModel.selectedSectionId)-\(selectedGame.catalogIdentity)"
    }

    private func shouldUseGrid(for destination: CatalogDestination) -> Bool {
        !viewModel.isBrowseMode && (destination == .library || destination == .favorites)
    }

    private func selectedGameBelongs(to section: CatalogSectionModel) -> Bool {
        guard let selectedGame = viewModel.selectedGame else { return false }
        return section.games.contains { CatalogViewModel.looseIdentityMatches($0, selectedGame) }
    }

    private func scrollToSelectedRail(_ anchor: String?, proxy: ScrollViewProxy) {
        guard let anchor else { return }
        scrollToSelectedRail(anchor, proxy: proxy, remainingDeferredPasses: 2)
    }

    private func scrollToSelectedRail(_ anchor: String, proxy: ScrollViewProxy, remainingDeferredPasses: Int) {
        Task { @MainActor in
            withAnimation(.easeInOut(duration: 0.24)) {
                proxy.scrollTo(anchor, anchor: .top)
            }
            if remainingDeferredPasses > 0 {
                scrollToSelectedRail(anchor, proxy: proxy, remainingDeferredPasses: remainingDeferredPasses - 1)
            }
        }
    }

    private func shouldShowDetail(afterSectionAt index: Int, sections: [CatalogSectionModel]) -> Bool {
        guard let selectedGame = viewModel.selectedGame else { return false }
        if !viewModel.selectedSectionId.isEmpty {
            return sections[index].id == viewModel.selectedSectionId && sections[index].games.contains(where: { CatalogViewModel.looseIdentityMatches($0, selectedGame) })
        }
        guard sections[index].games.contains(where: { CatalogViewModel.looseIdentityMatches($0, selectedGame) }) else {
            return false
        }
        return !sections.prefix(index).contains { section in
            section.games.contains { CatalogViewModel.looseIdentityMatches($0, selectedGame) }
        }
    }
}

struct CatalogHeroView: View {
    let viewModel: CatalogViewModel
    let games: [OPNCatalogGameObject]
    let activeIndex: Int
    let availableWidth: CGFloat
    var availableHeight: CGFloat = 0
    let onSelectSlide: (Int) -> Void
    let onPreviousSlide: () -> Void
    let onNextSlide: () -> Void
    @State private var scrimColor = CatalogMarqueeScrimColor.black
    @Environment(\.opnUIScale) private var uiScale

    private var game: OPNCatalogGameObject? {
        games.indices.contains(activeIndex) ? games[activeIndex] : games.first
    }

    var body: some View {
        if let game {
            GeometryReader { proxy in
                let heroHeight = proxy.size.height > 1 ? proxy.size.height : CatalogVendorLayout.heroHeight(for: proxy.size.width, viewportHeight: availableHeight, scale: uiScale)
                let imageLeading = CatalogVendorLayout.heroImageLeading(for: proxy.size.width)
                let textWidth = CatalogVendorLayout.heroTextWidth(for: proxy.size.width)
                ZStack(alignment: .bottom) {
                    CatalogHeroVendorBackgroundScrim(color: scrimColor)
                    CatalogHeroRemoteImage(url: viewModel.optimizedImageURL(game.bestMarqueeHeroImageURL, width: 1920), contentMode: .fill) { color in
                        scrimColor = color
                    }
                    .frame(width: max(proxy.size.width - imageLeading, 1), height: heroHeight)
                    .mask(CatalogHeroVendorImageMask())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .clipped()
                    // `clipped()` hides the aspect-fill overflow but does not clip hit
                    // testing: on wide windows the image spills hundreds of points above
                    // the hero and swallowed the active-session banner buttons.
                    .contentShape(Rectangle())
                    .id(game.catalogIdentity)
                    .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                    CatalogHeroVendorGradientOverlays(imageLeading: imageLeading)

                    VStack(spacing: 24) {
                        CatalogHeroTitleView(viewModel: viewModel, game: game, scrimColor: scrimColor)
                        VStack(spacing: 2) {
                            Text(game.primaryStoreLabel)
                                .nvidiaFont(size: 13, weight: .bold)
                            if !game.ratingLabel.isEmpty {
                                Text(game.ratingLabel)
                                    .nvidiaFont(size: 13, weight: .bold)
                            }
                        }
                        .foregroundStyle(scrimColor.preferredTextColor.opacity(0.94))
                        Button { viewModel.selectGameFromHero(game) } label: {
                            Text("VIEW DETAILS")
                        }
                        .buttonStyle(VendorGetInButtonStyle(size: .large, uiScale: uiScale, minimumWidth: 142))
                    }
                    .frame(width: textWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, proxy.size.width < 760 ? 76 : 102)
                    .padding(.leading, CatalogVendorLayout.heroTextLeading(for: proxy.size.width))

                    HStack {
                        if activeIndex > 0 {
                            CatalogMarqueeArrow(name: "lt_arrow", action: onPreviousSlide)
                        } else {
                            Color.clear.frame(width: 48 * uiScale, height: 48 * uiScale)
                        }
                        Spacer()
                        if activeIndex < games.count - 1 {
                            CatalogMarqueeArrow(name: "rt_arrow", action: onNextSlide)
                        } else {
                            Color.clear.frame(width: 48 * uiScale, height: 48 * uiScale)
                        }
                    }
                    .frame(height: heroHeight, alignment: .center)
                    .padding(.horizontal, 16 * uiScale)

                    HStack(spacing: 8) {
                        ForEach(Array(games.enumerated()), id: \.element.catalogIdentity) { index, _ in
                            Button { onSelectSlide(index) } label: {
                                Circle()
                                    .fill(index == activeIndex ? MacForceNowDesign.accent : Color.white.opacity(0.58))
                                    .frame(width: index == activeIndex ? 12 * uiScale : 9 * uiScale, height: index == activeIndex ? 12 * uiScale : 9 * uiScale)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 34 * uiScale)
                }
            }
            .frame(height: CatalogVendorLayout.heroHeight(for: availableWidth, viewportHeight: availableHeight, scale: uiScale))
            .clipShape(Rectangle())
        }
    }
}

struct CatalogHeroTitleView: View {
    let viewModel: CatalogViewModel
    let game: OPNCatalogGameObject
    let scrimColor: CatalogMarqueeScrimColor
    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        if let logoURL = viewModel.optimizedImageURL(game.bestLogoImageURL, width: 620) {
            CatalogCachedImageView(url: logoURL, contentMode: .fit, placeholder: fallbackTitle.opacity(0), failure: fallbackTitle)
                .frame(maxWidth: 390 * uiScale, maxHeight: 150 * uiScale)
        } else {
            fallbackTitle
        }
    }

    private var fallbackTitle: some View {
        Text(game.mallDisplayTitle)
            .nvidiaFont(size: 52)
            .tracking(8)
            .foregroundStyle(scrimColor.preferredTextColor.opacity(0.94))
            .lineLimit(2)
            .minimumScaleFactor(0.55)
            .multilineTextAlignment(.center)
    }
}

struct CatalogMarqueeArrow: View {
    let name: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VendorResourceImage(name: name, fileExtension: "svg")
                .scaledToFit()
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
    }
}

struct CatalogBrowseControlsView: View {
    let viewModel: CatalogViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if !viewModel.resultSummary.isEmpty {
                    Text(viewModel.resultSummary.uppercased())
                        .nvidiaFont(size: 12, weight: .bold)
                        .foregroundStyle(.white.opacity(0.62))
                }
                if viewModel.hasMoreCatalogResults {
                    Text("SHOWING TOP RESULTS")
                        .nvidiaFont(size: 12, weight: .bold)
                        .foregroundStyle(MacForceNowDesign.accent.opacity(0.88))
                }
                Spacer()
                if !viewModel.searchQuery.trimmed.isEmpty || viewModel.selectedFilterCount > 0 {
                    Button("CLEAR") { viewModel.clearSearchAndFilters() }
                        .buttonStyle(.plain)
                        .nvidiaFont(size: 12, weight: .bold)
                        .foregroundStyle(.white.opacity(0.84))
                }
                MacForceNowDropdownMenu(
                    items: viewModel.sortOptions.map { option in
                        MacForceNowDropdownItem(
                            id: option.id,
                            title: option.label.isEmpty ? option.id : option.label,
                            isSelected: option.id == viewModel.selectedSortId
                        ) { viewModel.setSort(option.id) }
                    },
                    isDisabled: viewModel.sortOptions.isEmpty
                ) {
                    HStack(spacing: MacForceNowDesign.Spacing.xSmall) {
                        Text("SORT: \(viewModel.selectedSortLabel.uppercased())")
                        Image(systemName: "chevron.down")
                    }
                    .nvidiaFont(size: 12, weight: .bold)
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.horizontal, MacForceNowDesign.Spacing.controlRow)
                    .frame(height: 34)
                    .background(Color.white.opacity(0.08))
                }
            }

            if !viewModel.visibleFilterGroups.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(viewModel.visibleFilterGroups, id: \.id) { group in
                            MacForceNowDropdownMenu(
                                items: group.options.map { option in
                                    MacForceNowDropdownItem(
                                        id: option.id,
                                        title: option.label.isEmpty ? option.id : option.label,
                                        isSelected: viewModel.selectedFilterIds.contains(option.id)
                                    ) { viewModel.toggleFilter(option.id) }
                                }
                            ) {
                                HStack(spacing: 7) {
                                    Text((group.label.isEmpty ? group.id : group.label).uppercased())
                                    Image(systemName: "slider.horizontal.3")
                                }
                                .nvidiaFont(size: 11, weight: .bold)
                                .foregroundStyle(.white.opacity(0.82))
                                .padding(.horizontal, MacForceNowDesign.Spacing.controlRow)
                                .frame(height: 32)
                                .background(Color.white.opacity(0.075))
                                .overlay { Rectangle().stroke(Color.white.opacity(0.12), lineWidth: 1) }
                            }
                        }
                        ForEach(selectedFilterOptions, id: \.id) { option in
                            Button { viewModel.toggleFilter(option.id) } label: {
                                HStack(spacing: 7) {
                                    Text(option.label.uppercased())
                                    Image(systemName: "xmark")
                                }
                                .nvidiaFont(size: 11, weight: .bold)
                                .foregroundStyle(.black.opacity(0.88))
                                .padding(.horizontal, 11)
                                .frame(height: 32)
                                .background(MacForceNowDesign.accent)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var selectedFilterOptions: [OPNCatalogFilterOptionObject] {
        viewModel.visibleFilterGroups.flatMap(\.options).filter { viewModel.selectedFilterIds.contains($0.id) }
    }
}

struct CatalogEmptyDestinationView: View {
    let viewModel: CatalogViewModel
    let destination: CatalogDestination

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .nvidiaFont(size: 22, weight: .bold)
                    .foregroundStyle(MacForceNowDesign.accent)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .nvidiaFont(size: 24, weight: .bold)
                        .foregroundStyle(.white)
                    Text(message)
                        .nvidiaFont(size: 14, weight: .medium)
                        .foregroundStyle(.white.opacity(0.62))
                }
            }
            HStack(spacing: 10) {
                Button(primaryActionTitle) { primaryAction() }
                    .buttonStyle(VendorGetInButtonStyle())
                if viewModel.isBrowseMode {
                    Button("CLEAR FILTERS") { viewModel.clearSearchAndFilters() }
                        .buttonStyle(VendorLaunchSecondaryButtonStyle())
                }
            }
            .padding(.top, 4)
        }
        .padding(22)
        .frame(maxWidth: 620, alignment: .leading)
        .background(Color.white.opacity(0.055))
        .overlay { Rectangle().stroke(Color.white.opacity(0.10), lineWidth: 1) }
    }

    private var icon: String {
        switch destination {
        case .home: return "gamecontroller.fill"
        case .library: return "rectangle.stack.fill"
        case .favorites: return "heart.fill"
        }
    }

    private var title: String {
        switch destination {
        case .home: return "No games to show"
        case .library: return "Your library is empty"
        case .favorites: return "No favorites yet"
        }
    }

    private var message: String {
        switch destination {
        case .home: return "Refresh the catalog or adjust search and filters to find supported GeForce NOW games."
        case .library: return "Connect or sync your game store accounts to populate My Library."
        case .favorites: return "Open a game detail panel and use the heart button to add it to My Favorites."
        }
    }

    private var primaryActionTitle: String {
        switch destination {
        case .home: return viewModel.isBrowseMode ? "REFRESH" : "REFRESH CATALOG"
        case .library: return "OPEN CONNECTIONS"
        case .favorites: return "BROWSE GAMES"
        }
    }

    private func primaryAction() {
        switch destination {
        case .home:
            viewModel.refresh()
        case .library:
            viewModel.showSettings(.connections)
        case .favorites:
            viewModel.showCatalogDestination(.home)
        }
    }
}

struct CatalogRailView: View {
    let imageCache: any CatalogImageServing = CatalogImageCache.shared
    let viewModel: CatalogViewModel
    let section: CatalogSectionModel
    let onShowAll: () -> Void
    @State private var scrollIndex = 0
    @Environment(\.opnUIScale) private var uiScale

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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(section.title)
                    .nvidiaFont(size: 20, weight: .medium)
                    .foregroundStyle(.white.opacity(0.96))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if canShowAll {
                    Button("SHOW ALL", action: onShowAll)
                        .buttonStyle(.plain)
                        .nvidiaFont(size: 13, weight: .bold)
                        .foregroundStyle(.white.opacity(0.92))
                }
            }
            .frame(height: 28)
            .padding(.horizontal, CatalogVendorLayout.sectionHeaderMargin(scale: uiScale))

            ScrollViewReader { proxy in
                ZStack {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(games, id: \.catalogIdentity) { game in
                                EquatableView(content: CatalogGameTile(
                                    game: game,
                                    imageURL: viewModel.optimizedImageURL(game.bestWideImageURL, width: 768),
                                    isSelected: isSelected(game),
                                    isSelectionActive: viewModel.selectedGame != nil,
                                    isQueuedForPatching: viewModel.isQueuedForPatching(game),
                                    showsFreeAccountAccessBadges: viewModel.isFreeTierAccount,
                                    onSelect: { viewModel.toggleGameSelection(game, inSection: section.id) },
                                    onPlay: { viewModel.launch(game: game) },
                                    onMarkOwned: {
                                        viewModel.selectGame(game, inSection: section.id)
                                        viewModel.handleUnownedSelectedVariantPrimaryAction()
                                    },
                                    onQueueForPatching: { viewModel.queuePatchingLaunch(game: game) }
                                ))
                                    .id(game.catalogIdentity)
                            }
                            ForEach(Array(section.tiles.enumerated()), id: \.offset) { _, tile in
                                CatalogPanelActionTile(
                                    tile: tile,
                                    imageURL: viewModel.optimizedImageURL(tile.imageUrl, width: 768),
                                    action: { viewModel.openPanelTile(tile) }
                                )
                            }
                            if canShowAll {
                                CatalogSeeMoreTile(title: "Show All", action: onShowAll)
                            }
                        }
                        .frame(height: CatalogVendorLayout.wideTileHeight(scale: uiScale) + CatalogVendorLayout.tileTopMargin(scale: uiScale))
                        .padding(.horizontal, CatalogVendorLayout.carouselContainerMargin(scale: uiScale))
                        .padding(.bottom, 4)
                    }
                    if games.count > 3 {
                        HStack {
                            CatalogRailArrow(name: "lt_arrow") {
                                moveRail(proxy: proxy, delta: -3)
                            }
                            Spacer()
                            CatalogRailArrow(name: "rt_arrow") {
                                moveRail(proxy: proxy, delta: 3)
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                }
                .onAppear { revealSelectedGameIfNeeded(proxy: proxy, request: viewModel.selectedGameRevealRequest) }
                .onChange(of: viewModel.selectedGameRevealRequest) { _, request in revealSelectedGameIfNeeded(proxy: proxy, request: request) }
            }
        }
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
        var urls: [URL] = []
        var seen = Set<String>()
        for game in games.prefix(8) {
            appendPrefetchURL(game.bestTileImageURL, width: 768, urls: &urls, seen: &seen)
            appendPrefetchURL(game.bestWideImageURL, width: 768, urls: &urls, seen: &seen)
            appendPrefetchURL(game.bestLogoImageURL, width: 300, urls: &urls, seen: &seen)
        }
        for tile in section.tiles.prefix(4) {
            appendPrefetchURL(tile.imageUrl, width: 768, urls: &urls, seen: &seen)
        }
        imageCache.prefetch(urls)
    }

    private func appendPrefetchURL(_ rawValue: String, width: Int, urls: inout [URL], seen: inout Set<String>) {
        guard let url = viewModel.optimizedImageURL(rawValue, width: width) else { return }
        let key = url.absoluteString
        guard !seen.contains(key) else { return }
        seen.insert(key)
        urls.append(url)
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

struct CatalogDestinationGridView: View {
    let imageCache: any CatalogImageServing = CatalogImageCache.shared
    let viewModel: CatalogViewModel
    let section: CatalogSectionModel
    @Environment(\.opnUIScale) private var uiScale

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: CatalogVendorLayout.wideTileWidth(scale: uiScale) + CatalogVendorLayout.tileHorizontalMargin(scale: uiScale) * 2), spacing: 4 * uiScale, alignment: .top)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16 * uiScale) {
            HStack(alignment: .lastTextBaseline, spacing: 20 * uiScale) {
                Text(section.title)
                    .nvidiaFont(size: 24, weight: .bold)
                    .foregroundStyle(.white.opacity(0.96))
                    .accessibilityAddTraits(.isHeader)
                Text("\(section.games.count) game\(section.games.count == 1 ? "" : "s")")
                    .nvidiaFont(size: 12, weight: .bold)
                    .foregroundStyle(MacForceNowDesign.accent.opacity(0.86))
                    .tracking(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, CatalogVendorLayout.sectionHeaderMargin(scale: uiScale))
            .padding(.top, 24 * uiScale)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8 * uiScale) {
                ForEach(Array(section.games.enumerated()), id: \.element.catalogIdentity) { _, game in
                    CatalogGameTile(
                        game: game,
                        imageURL: viewModel.optimizedImageURL(game.bestWideImageURL, width: 768),
                        isSelected: isSelected(game),
                        isSelectionActive: viewModel.selectedGame != nil,
                        isQueuedForPatching: viewModel.isQueuedForPatching(game),
                        showsFreeAccountAccessBadges: viewModel.isFreeTierAccount,
                        onSelect: { viewModel.toggleGameSelection(game, inSection: section.id) },
                        onPlay: { viewModel.launch(game: game) },
                        onMarkOwned: {
                            viewModel.selectGame(game, inSection: section.id)
                            viewModel.handleUnownedSelectedVariantPrimaryAction()
                        },
                        onQueueForPatching: { viewModel.queuePatchingLaunch(game: game) }
                    )
                }
            }
            .padding(.horizontal, CatalogVendorLayout.carouselContainerMargin(scale: uiScale))
            .padding(.bottom, 12 * uiScale)
        }
        .onAppear { prefetchGridImages() }
        .onChange(of: section.games.map(\.catalogIdentity)) { _, _ in prefetchGridImages() }
    }

    private func isSelected(_ game: OPNCatalogGameObject) -> Bool {
        guard let selectedGame = viewModel.selectedGame else { return false }
        return CatalogViewModel.looseIdentityMatches(selectedGame, game)
    }

    private func prefetchGridImages() {
        var urls: [URL] = []
        var seen = Set<String>()
        for game in section.games.prefix(18) {
            appendPrefetchURL(game.bestTileImageURL, width: 768, urls: &urls, seen: &seen)
            appendPrefetchURL(game.bestWideImageURL, width: 768, urls: &urls, seen: &seen)
            appendPrefetchURL(game.bestLogoImageURL, width: 300, urls: &urls, seen: &seen)
        }
        imageCache.prefetch(urls)
    }

    private func appendPrefetchURL(_ rawValue: String, width: Int, urls: inout [URL], seen: inout Set<String>) {
        guard let url = viewModel.optimizedImageURL(rawValue, width: width) else { return }
        let key = url.absoluteString
        guard !seen.contains(key) else { return }
        seen.insert(key)
        urls.append(url)
    }
}

struct CatalogRailArrow: View {
    let name: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VendorResourceImage(name: name, fileExtension: "svg")
                .scaledToFit()
                .frame(width: 30, height: 30)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.24), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

struct CatalogSeeMoreTile: View {
    let title: String
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: "ellipsis")
                    .nvidiaFont(size: 34, weight: .bold)
                    .foregroundStyle(.white.opacity(0.82))
                Text(title.uppercased())
                    .nvidiaFont(size: 16, weight: .medium)
                    .foregroundStyle(.white.opacity(0.88))
            }
            .frame(width: CatalogVendorLayout.wideTileWidth(scale: uiScale), height: CatalogVendorLayout.wideTileHeight(scale: uiScale))
            .background(Color(red: 43 / 255, green: 43 / 255, blue: 43 / 255))
            .overlay { Rectangle().stroke(Color.white.opacity(0.24), lineWidth: 2) }
            .scaleEffect(isHovering ? CatalogVendorLayout.tileScaleFactor : 1.0)
            .animation(.easeOut(duration: 0.2), value: isHovering)
            .padding(.horizontal, CatalogVendorLayout.tileHorizontalMargin(scale: uiScale))
            .padding(.top, CatalogVendorLayout.tileTopMargin(scale: uiScale))
            .frame(width: CatalogVendorLayout.wideTileWidth(scale: uiScale) + CatalogVendorLayout.tileHorizontalMargin(scale: uiScale) * 2, height: CatalogVendorLayout.wideTileHeight(scale: uiScale) + CatalogVendorLayout.tileTopMargin(scale: uiScale), alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("See all")
    }
}

struct CatalogPanelActionTile: View {
    let tile: OPNCatalogPanelTileObject
    let imageURL: URL?
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                CatalogRemoteImage(url: imageURL, contentMode: .fill, maxPixelSize: 768)
                    .frame(width: CatalogVendorLayout.wideTileWidth(scale: uiScale), height: CatalogVendorLayout.wideTileHeight(scale: uiScale))
                    .clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.84)], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 5) {
                    if !tile.subtitle.isEmpty {
                        Text(tile.subtitle.uppercased())
                            .nvidiaFont(size: 10, weight: .bold)
                            .tracking(0.8)
                            .foregroundStyle(MacForceNowDesign.accent)
                            .lineLimit(1)
                    }
                    Text(tile.title.isEmpty ? (tile.kind == "filter" ? "Browse Games" : "Featured") : tile.title)
                        .nvidiaFont(size: 17, weight: .bold)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(actionLabel)
                        .nvidiaFont(size: 11, weight: .bold)
                        .tracking(0.7)
                        .foregroundStyle(.black.opacity(0.88))
                        .padding(.horizontal, 10)
                        .frame(height: 25)
                        .background(MacForceNowDesign.accent)
                }
                .padding(14)
            }
            .frame(width: CatalogVendorLayout.wideTileWidth(scale: uiScale), height: CatalogVendorLayout.wideTileHeight(scale: uiScale))
            .overlay { Rectangle().stroke(isHovering ? MacForceNowDesign.accent : Color.white.opacity(0.16), lineWidth: isHovering ? 2 : 1) }
            .scaleEffect(isHovering ? CatalogVendorLayout.tileScaleFactor : 1.0)
            .animation(.easeOut(duration: 0.2), value: isHovering)
            .padding(.horizontal, CatalogVendorLayout.tileHorizontalMargin(scale: uiScale))
            .padding(.top, CatalogVendorLayout.tileTopMargin(scale: uiScale))
            .frame(width: CatalogVendorLayout.wideTileWidth(scale: uiScale) + CatalogVendorLayout.tileHorizontalMargin(scale: uiScale) * 2, height: CatalogVendorLayout.wideTileHeight(scale: uiScale) + CatalogVendorLayout.tileTopMargin(scale: uiScale), alignment: .top)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(tile.title.isEmpty ? actionLabel : tile.title)
    }

    private var actionLabel: String {
        if !tile.actionLabel.isEmpty { return tile.actionLabel.uppercased() }
        return tile.kind == "filter" ? "BROWSE" : "OPEN"
    }
}

struct VendorActiveSessionHomeBanner: View {
    let title: String
    let isResumable: Bool
    let serverIp: String
    let onResume: () -> Void
    let onEnd: () -> Void

    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(MacForceNowDesign.accent)
                .frame(width: 8 * uiScale, height: 8 * uiScale)
                .shadow(color: MacForceNowDesign.accent, radius: 4)
                .padding(.trailing, 10 * uiScale)

            VStack(alignment: .leading, spacing: 2 * uiScale) {
                Text("SESSION ACTIVE")
                    .nvidiaFont(size: 10, weight: .bold)
                    .foregroundStyle(MacForceNowDesign.accent)
                    .tracking(1.2)
                Text(title)
                    .nvidiaFont(size: 14, weight: .bold)
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }

            Spacer(minLength: 16 * uiScale)

            HStack(spacing: 8 * uiScale) {
                if isResumable {
                    Button("RESUME") { onResume() }
                        .buttonStyle(VendorActiveSessionBannerButtonStyle(primary: true))
                }
                Button("END") { onEnd() }
                    .buttonStyle(VendorActiveSessionBannerButtonStyle(primary: false))
            }
        }
        .padding(.horizontal, CatalogVendorLayout.sectionHeaderMargin(scale: uiScale))
        .padding(.vertical, 10 * uiScale)
        .background(MacForceNowDesign.Surface.chrome)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
    }
}

private struct VendorActiveSessionBannerButtonStyle: ButtonStyle {
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .nvidiaFont(size: 11, weight: .bold)
            .foregroundStyle(primary ? .black : .white.opacity(0.86))
            .tracking(0.8)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(primary
                ? MacForceNowDesign.accent.opacity(configuration.isPressed ? 0.78 : 1.0)
                : Color.white.opacity(configuration.isPressed ? 0.10 : 0.055))
            .overlay {
                if !primary {
                    Rectangle().stroke(Color.white.opacity(0.14), lineWidth: 1)
                }
            }
    }
}
