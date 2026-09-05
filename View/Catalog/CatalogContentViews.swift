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
                    ScrollView {
                        // Deliberately eager. A LazyVStack here re-runs
                        // `LazyStack.measureEstimates` on every scroll offset change, and
                        // estimating a rail means applying its whole view list - every tile in
                        // every rail, rebuilt and thrown away per layout pass. On the home page
                        // that pinned the main thread at 100% CPU for the length of a scroll.
                        // A plain VStack measures the rails once and keeps them.
                        //
                        // If this ever goes lazy again, note also that `.animation(_:value:)` on a
                        // lazy stack loops: each per-item materialisation phase change re-dirties
                        // layout, which recomputes the phases, which animates again, inside
                        // `LazyLayoutViewCache.updateItemPhases`.
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

                            if !isGridDestination {
                                if hero != nil {
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
                                } else if viewModel.isLoadingMarquee {
                                    // The hero comes from the marquee query, the rails from the main
                                    // one. Whichever lands second used to resize the page: with no
                                    // hero the rails start at the top, then the banner appears and
                                    // pushes them down by its full height. Hold the exact height
                                    // `CatalogHeroView` will claim until the marquee resolves.
                                    SkeletonBlock()
                                        .frame(height: CatalogVendorLayout.heroHeight(
                                            for: viewport.size.width,
                                            viewportHeight: viewport.size.height,
                                            scale: uiScale
                                        ))
                                }
                            }

                            if !viewModel.displayedErrorMessage.isEmpty {
                                CatalogMessageView(
                                    message: viewModel.displayedErrorMessage,
                                    systemImage: "exclamationmark.triangle.fill",
                                    diagnosticsState: viewModel.diagnosticsState,
                                    onGenerateDiagnostics: {
                                        viewModel.presentDiagnosticsUploadConfirmation(context: viewModel.displayedErrorMessage)
                                    },
                                    onDismiss: { viewModel.dismissLaunchError() }
                                )
                                    .padding(.horizontal, CatalogVendorLayout.sectionHeaderMargin(scale: uiScale))
                            }
                            if viewModel.isBrowseMode {
                                CatalogBrowseControlsView(viewModel: viewModel)
                                    .padding(.horizontal, CatalogVendorLayout.sectionHeaderMargin(scale: uiScale))
                            }
                            if isGridDestination, sections.isEmpty, isLoadingInitialSections {
                                CatalogGridSkeletonView(isScrollable: false)
                                    .padding(.top, 24 * uiScale)
                            } else if isGridDestination, let section = sections.first {
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
                                // Only when there is nothing at all yet. On Home the library and
                                // favorites rails have already claimed their slots by this point,
                                // so they carry the loading state and real rails append below them
                                // instead of displacing anything already on screen.
                                if sections.isEmpty, isLoadingInitialSections {
                                    ForEach(0..<3, id: \.self) { _ in
                                        CatalogRailSkeletonView()
                                    }
                                }
                            }

                            if sections.isEmpty && !isLoadingInitialSections {
                                CatalogEmptyDestinationView(viewModel: viewModel, destination: viewModel.selectedCatalogDestination)
                                    .padding(.horizontal, CatalogVendorLayout.sectionHeaderMargin(scale: uiScale))
                                    .padding(.top, viewModel.selectedCatalogDestination == .home ? 52 : 118)
                            }
                        }
                        .padding(.bottom, 44)
                    }
                    .background(
                        OpenNOWDesign.Surface.app
                            .contentShape(Rectangle())
                            .onTapGesture { viewModel.closeGameDetailsFromBackground() }
                    )
                    .simultaneousGesture(TapGesture().onEnded {
                        guard viewModel.selectedGame != nil, !isPointerInsideDetailPanel else { return }
                        viewModel.closeGameDetailsFromBackground()
                    })
                    .onChange(of: selectedRailScrollAnchor) { _, anchor in
                        scrollToSelectedRail(anchor, proxy: proxy)
                    }
                    .onChange(of: viewModel.selectedGameRevealRequest) { _, _ in
                        scrollToSelectedRail(selectedRailScrollAnchor, proxy: proxy)
                    }
                }
                .background(OpenNOWDesign.Surface.app)
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

    /// True while the first page of rails is still in flight. Drives the in-flow rail skeletons,
    /// which replaced an overlaid full-page skeleton: one layout tree means the loading and loaded
    /// states cannot drift apart in height the way two hand-matched trees did.
    private var isLoadingInitialSections: Bool {
        viewModel.isLoading || viewModel.isLoadingPanels
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
                                    .fill(index == activeIndex ? OpenNOWDesign.accent : Color.white.opacity(0.58))
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
                        .foregroundStyle(OpenNOWDesign.accent.opacity(0.88))
                }
                Spacer()
                if !viewModel.searchQuery.trimmed.isEmpty || viewModel.selectedFilterCount > 0 {
                    Button("CLEAR") { viewModel.clearSearchAndFilters() }
                        .buttonStyle(.plain)
                        .nvidiaFont(size: 12, weight: .bold)
                        .foregroundStyle(.white.opacity(0.84))
                }
                OpenNOWDropdownMenu(
                    items: viewModel.sortOptions.map { option in
                        OpenNOWDropdownItem(
                            id: option.id,
                            title: option.label.isEmpty ? option.id : option.label,
                            isSelected: option.id == viewModel.selectedSortId
                        ) { viewModel.setSort(option.id) }
                    },
                    isDisabled: viewModel.sortOptions.isEmpty
                ) {
                    HStack(spacing: OpenNOWDesign.Spacing.xSmall) {
                        Text("SORT: \(viewModel.selectedSortLabel.uppercased())")
                        Image(systemName: "chevron.down")
                    }
                    .nvidiaFont(size: 12, weight: .bold)
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.horizontal, OpenNOWDesign.Spacing.controlRow)
                    .frame(height: 34)
                    .background(Color.white.opacity(0.08))
                }
            }

            if !viewModel.visibleFilterGroups.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(viewModel.visibleFilterGroups, id: \.id) { group in
                            OpenNOWDropdownMenu(
                                items: group.options.map { option in
                                    OpenNOWDropdownItem(
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
                                .padding(.horizontal, OpenNOWDesign.Spacing.controlRow)
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
                                .background(OpenNOWDesign.accent)
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
                    .foregroundStyle(OpenNOWDesign.accent)
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

    var primaryActionTitle: String {
        switch destination {
        case .home: return viewModel.isBrowseMode ? "REFRESH" : "REFRESH CATALOG"
        case .library: return "OPEN CONNECTIONS"
        case .favorites: return "BROWSE GAMES"
        }
    }

    func primaryAction() {
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
