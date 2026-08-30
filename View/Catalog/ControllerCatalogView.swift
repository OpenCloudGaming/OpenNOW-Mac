//
//  ControllerCatalogView.swift
//  OpenNOW
//

import AppKit
import SwiftUI


private struct ControllerLayoutMetrics {
    let size: CGSize
    let safeAreaInsets: EdgeInsets
    let scale: CGFloat

    var contentWidth: CGFloat {
        max(size.width - leadingInset - trailingInset, 1)
    }

    var leadingInset: CGFloat {
        safeAreaInsets.leading + baseInset
    }

    var trailingInset: CGFloat {
        safeAreaInsets.trailing + baseInset
    }

    /// The threshold is a scaled point value, not a raw pixel count: at a larger interface scale the
    /// same window holds less content, so it has to fall back to the compact metrics sooner.
    var compactHeight: Bool { size.height < 760 * scale }

    /// Follows the window's width the way the desktop hero does, instead of sitting at a fixed
    /// point height. A constant 280pt banner is roughly right on a laptop and reads as a letterbox
    /// strip on an ultrawide, where the artwork is stretched across several times that width.
    /// Clamped so it still leaves room for the first rail on short windows.
    var heroHeight: CGFloat {
        let minimum = (compactHeight ? 230 : 280) * scale
        let maximum = max(minimum, min(size.height * 0.42, 520 * scale))
        return min(max(contentWidth * 0.22, minimum), maximum)
    }
    var railPreferredTileWidth: CGFloat { (compactHeight ? 278 : 300) * scale }

    // The proportional term follows the window; only the clamp bounds are point values that scale.
    private var baseInset: CGFloat {
        min(max(visibleWidth * 0.022, 28 * scale), 48 * scale)
    }

    private var visibleWidth: CGFloat {
        max(size.width - safeAreaInsets.leading - safeAreaInsets.trailing, 1)
    }
}

struct ControllerCatalogView: View {
    let viewModel: CatalogViewModel
    let accounts: [LoginAccount]
    let topInset: CGFloat
    let onSwitch: (LoginAccount) -> Void
    let onSignOut: () -> Void
    let onForget: (LoginAccount) -> Void

    @AppStorage(OpenNOWInterfacePreferences.controllerModeEnabledKey) private var controllerModeEnabled = false
    @Environment(\.opnUIScale) private var uiScale
    /// Owns the shell's whole controller state machine, and the input router, gamepad navigator and
    /// on-screen keyboard it drives. Still a `@StateObject` on this view, so its lifetime is exactly
    /// what it was when each of those was declared here separately.
    @StateObject private var controllerViewModel = ControllerCatalogViewModel()

    private var activeGlyphs: ControllerInputGlyphSet { controllerViewModel.activeGlyphs }

    private var navigationItems: [ControllerNavigationItem] { controllerViewModel.navigationItems }

    var body: some View {
        GeometryReader { proxy in
            let layout = ControllerLayoutMetrics(size: proxy.size, safeAreaInsets: proxy.safeAreaInsets, scale: uiScale)
            ZStack {
                // Search renders in the page slot rather than over the window, so the shell keeps
                // its backdrop throughout instead of blacking out while searching.
                ControllerCatalogBackground(viewModel: viewModel, game: focusedHeroGame)

                VStack(spacing: 0) {
                    ControllerHeader(viewModel: viewModel, glyphs: activeGlyphs, layout: layout, topInset: topInset)
                    ControllerNavigationBar(
                        items: navigationItems,
                        selectedIndex: controllerViewModel.selectedNavigationIndex,
                        isFocused: (controllerViewModel.focusArea == .navigation || viewModel.selectedMainPage != .games) && !hasModalOverlay,
                        activeItem: activeNavigationItem,
                        layout: layout,
                        select: controllerViewModel.selectNavigationItem
                    )
                    if isSearchOverlayPresented && viewModel.selectedMainPage == .games {
                        // In the page slot, not over the whole window: search is a destination in
                        // the nav bar, so hiding the header and nav bar it was reached from left
                        // no way to see where you were or page back out with LB/RB.
                        ControllerSearchOverlay(
                            viewModel: viewModel,
                            rowIndex: controllerViewModel.searchRowIndex,
                            filterOptionIndices: controllerViewModel.searchFilterOptionIndices,
                            resultIndex: controllerViewModel.searchResultIndex,
                            layout: layout,
                            selectResult: { game in controllerViewModel.openDetails(game, sectionId: viewModel.selectedShowAllSection?.id ?? "catalog-results") },
                            close: { controllerViewModel.closeSearchOverlay() },
                            focusSearchRow: { controllerViewModel.searchRowIndex = 0 },
                            openSortPicker: { controllerViewModel.openSortPicker() },
                            openFilterPicker: { group in controllerViewModel.openFilterPicker(group: group) }
                        )
                        .transition(.opacity)
                    } else {
                        controllerPage(layout: layout)
                    }
                    ControllerHintBar(hints: hints, glyphs: activeGlyphs, layout: layout)
                }
                .frame(width: layout.contentWidth, height: proxy.size.height, alignment: .top)
                .padding(.leading, layout.leadingInset)
                .padding(.trailing, layout.trailingInset)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .clipped()

                if isSearchOverlayPresented, let searchPicker = controllerViewModel.searchPicker {
                    ControllerSearchPickerOverlay(
                        picker: searchPicker,
                        selectedIndex: controllerViewModel.searchPickerIndex,
                        selectedOptionIds: viewModel.selectedFilterIds,
                        selectedSortId: viewModel.selectedSortId,
                        glyphs: activeGlyphs,
                        layout: layout,
                        select: { index in controllerViewModel.applySearchPickerSelection(at: index) },
                        close: { controllerViewModel.closeSearchPicker() }
                    )
                    .transition(.opacity)
                    .zIndex(31)
                }

                if controllerViewModel.isDetailVisible, let game = viewModel.selectedGame {
                    ControllerGameDetailOverlay(
                        viewModel: viewModel,
                        game: game,
                        selectedActionIndex: controllerViewModel.detailActionIndex,
                        actions: detailActions(for: game),
                        glyphs: activeGlyphs,
                        layout: layout,
                        perform: controllerViewModel.executeDetailAction,
                        close: controllerViewModel.closeDetails
                    )
                    .transition(.opacity)
                    .zIndex(35)
                }

            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            // Attached as an overlay of the clipped container (rather than as a
            // ZStack sibling) so the action menu inherits exactly the bounds the
            // visible content is laid out in and can never anchor past the
            // window's trailing edge.
            .overlay {
                if isSearchOverlayPresented && controllerViewModel.isSearchKeyboardVisible {
                    StreamOnScreenKeyboardOverlay(controller: controllerViewModel.searchKeyboard)
                        .transition(.opacity)
                }
            }
            // Replaces the `withAnimation(.easeOut(duration: 0.18))` that used to wrap every
            // mutation of this flag. Same curve, same duration - driven by the value rather than by
            // a transaction, so the view model does not have to import SwiftUI to animate.
            .animation(.easeOut(duration: 0.18), value: controllerViewModel.isSearchKeyboardVisible)
            .overlay {
                if controllerViewModel.isActionMenuVisible {
                    ControllerActionMenuOverlay(
                        items: actionMenuItems,
                        selectedIndex: controllerViewModel.actionMenuIndex,
                        glyphs: activeGlyphs,
                        layout: layout,
                        topInset: topInset,
                        isRefreshingCatalog: viewModel.isCatalogRefreshInProgress,
                        perform: controllerViewModel.executeActionMenuItem,
                        close: controllerViewModel.closeActionMenu
                    )
                    .transition(.opacity)
                }
            }
        }
        .background(ControllerKeyboardInputBridge { command in controllerViewModel.inputRouter.sendKeyboardCommand(command) })
        .onAppear {
            controllerViewModel.bind(
                catalog: viewModel,
                host: ControllerCatalogHost(
                    accounts: accounts,
                    onSwitch: onSwitch,
                    onSignOut: onSignOut,
                    onExitControllerMode: { controllerModeEnabled = false }
                )
            )
            controllerViewModel.synchronizeNavigationSelection()
        }
        .onDisappear { controllerViewModel.unbind() }
        .onChange(of: viewModel.selectedMainPage) { _, _ in controllerViewModel.synchronizeNavigationSelection() }
        .onChange(of: viewModel.selectedCatalogDestination) { _, _ in controllerViewModel.synchronizeNavigationSelection() }
        .onChange(of: viewModel.catalogSections.map(\.id)) { _, _ in controllerViewModel.clampRailSelection(sectionCount: viewModel.catalogSections.count) }
        .onChange(of: viewModel.catalogGames.map(\.catalogIdentity)) { _, _ in
            controllerViewModel.searchResultIndex = min(controllerViewModel.searchResultIndex, max(viewModel.catalogGames.count - 1, 0))
        }
    }

    @ViewBuilder private func controllerPage(layout: ControllerLayoutMetrics) -> some View {
        switch viewModel.selectedMainPage {
        case .games:
            ControllerGamesPage(
                viewModel: viewModel,
                focusArea: controllerViewModel.focusArea,
                selectedRailIndex: controllerViewModel.selectedRailIndex,
                selectedGameIndices: $controllerViewModel.selectedGameIndices,
                layout: layout,
                openDetails: controllerViewModel.openDetails,
                showAll: controllerViewModel.openShowAll,
                openSearch: { controllerViewModel.openSearchOverlay() }
            )
        case .recordings:
            ControllerEmbeddedPage(title: "Recordings", subtitle: "Saved gameplay videos", layout: layout) {
                RecordingsView()
                    .environment(\.controllerPageCommand, controllerViewModel.embeddedPageCommand)
            }
        case .settings:
            ControllerEmbeddedPage(title: "Settings", subtitle: "Streaming, account, interface, and system options", layout: layout) {
                SettingsView(viewModel: viewModel)
                    .environment(\.controllerPageCommand, controllerViewModel.embeddedPageCommand)
            }
        }
    }

    // Everything below forwards to `controllerViewModel`. The shell's state machine — focus,
    // overlays, navigation, and what confirming an item does — lives there so it can be tested
    // without a rendered catalog; this view only renders it.

    private var isSearchOverlayPresented: Bool { controllerViewModel.isSearchOverlayPresented }

    private var hasModalOverlay: Bool { controllerViewModel.hasModalOverlay }

    private var activeNavigationItem: ControllerNavigationItem { controllerViewModel.activeNavigationItem }

    private var focusedHeroGame: OPNCatalogGameObject? { controllerViewModel.focusedHeroGame }

    private var actionMenuItems: [ControllerActionMenuItem] { controllerViewModel.actionMenuItems }

    private func detailActions(for game: OPNCatalogGameObject) -> [ControllerDetailAction] {
        controllerViewModel.detailActions(for: game)
    }

    /// Stays in the view: `ControllerHint` is the hint bar's own glyph vocabulary, not shell state.
    private var hints: [ControllerHint] {
        if controllerViewModel.isActionMenuVisible { return [.move, .select, .back] }
        if controllerViewModel.isSearchKeyboardVisible { return [.move, .select, .back] }
        if controllerViewModel.isSearchVisible || viewModel.selectedShowAllSection != nil { return [.move, .select, .back, .clear] }
        if controllerViewModel.isDetailVisible { return [.move, .select, .back, .search] }
        if controllerViewModel.focusArea == .content { return [.move, .select, .back, .search, .showAll, .menu] }
        return [.move, .select, .back, .search, .menu]
    }
}

private struct ControllerHeader: View {
    let viewModel: CatalogViewModel
    let glyphs: ControllerInputGlyphSet
    let layout: ControllerLayoutMetrics
    let topInset: CGFloat

    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        HStack(spacing: 16 * uiScale) {
            VStack(alignment: .leading, spacing: 4 * uiScale) {
                Text("GEFORCE NOW")
                    .nvidiaFont(size: 11, weight: .bold)
                    .foregroundStyle(OpenNOWDesign.accent)
                    .tracking(1.6)
                Text(headerTitle)
                    .nvidiaFont(size: 24, weight: .bold)
                    .foregroundStyle(.white.opacity(0.96))
            }
            Spacer(minLength: 0)
            ControllerDeviceBadge(glyphs: glyphs)
            CatalogAccountAvatar(account: viewModel.account, size: 34)
        }
        .frame(width: layout.contentWidth)
        .frame(height: 72 * uiScale)
        .padding(.top, topInset)
        .background {
            Color.black.opacity(0.24)
            WindowDragArea()
        }
    }

    private var headerTitle: String {
        switch viewModel.selectedMainPage {
        case .games: return viewModel.selectedCatalogDestination.title
        case .recordings: return "Recordings"
        case .settings: return viewModel.selectedSettingsGroup.title
        }
    }
}

private struct ControllerDeviceBadge: View {
    let glyphs: ControllerInputGlyphSet

    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        Image(systemName: glyphs.usesControllerGlyphs ? "gamecontroller.fill" : "keyboard")
            .nvidiaFont(size: 13, weight: .bold)
            .foregroundStyle(OpenNOWDesign.accent)
            .frame(width: 40 * uiScale, height: 34 * uiScale)
            .background(Color.white.opacity(0.055))
            .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.subtle, lineWidth: 1) }
            .accessibilityLabel(glyphs.deviceName)
    }
}

private struct ControllerNavigationBar: View {
    let items: [ControllerNavigationItem]
    let selectedIndex: Int
    let isFocused: Bool
    let activeItem: ControllerNavigationItem
    let layout: ControllerLayoutMetrics
    let select: (ControllerNavigationItem) -> Void

    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12 * uiScale) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let selected = index == selectedIndex && isFocused
                    let active = activeItem == item
                    Button { select(item) } label: {
                        HStack(spacing: 9 * uiScale) {
                            Image(systemName: item.icon)
                                .nvidiaFont(size: 14, weight: .bold)
                            Text(item.title.uppercased())
                                .nvidiaFont(size: 12, weight: .bold)
                                .tracking(0.8)
                        }
                        .foregroundStyle(active ? .black.opacity(0.86) : .white.opacity(0.78))
                        .padding(.horizontal, 14 * uiScale)
                        .frame(height: 40 * uiScale)
                        .background(active ? OpenNOWDesign.accent : Color.white.opacity(0.055))
                        .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.subtle, lineWidth: 1) }
                        .openNowFocusRing(selected)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: layout.contentWidth, alignment: .leading)
            .padding(.vertical, 10 * uiScale)
        }
        .frame(width: layout.contentWidth)
        .background(Color.black.opacity(0.18))
    }
}

private struct ControllerGamesPage: View {
    let viewModel: CatalogViewModel
    let focusArea: ControllerCatalogFocusArea
    let selectedRailIndex: Int
    @Binding var selectedGameIndices: [String: Int]
    let layout: ControllerLayoutMetrics
    let openDetails: (OPNCatalogGameObject, String) -> Void
    let showAll: (CatalogSectionModel) -> Void
    let openSearch: () -> Void

    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        let sections = viewModel.catalogSections
        GeometryReader { _ in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: (layout.compactHeight ? 20 : 24) * uiScale) {
                        ControllerSearchEntryBar(isFocused: focusArea == .search, open: openSearch)
                            .frame(width: layout.contentWidth)

                        if viewModel.isActiveHomeSessionVisible, let session = viewModel.activeHomeSession {
                            VendorActiveSessionHomeBanner(
                                title: viewModel.activeHomeSessionTitle,
                                isResumable: session.isResumable,
                                serverIp: session.serverIp,
                                onResume: { viewModel.resumeActiveHomeSession() },
                                onEnd: { viewModel.endActiveHomeSession() }
                            )
                        }

                        ControllerHeroBillboard(viewModel: viewModel, game: heroGame(sections: sections), height: layout.heroHeight)
                            .frame(width: layout.contentWidth)
                            .padding(.top, (layout.compactHeight ? 10 : 14) * uiScale)

                        if !viewModel.errorMessage.isEmpty {
                            CatalogMessageView(message: viewModel.errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .frame(width: layout.contentWidth)
                        }

                        ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                            ControllerGameRail(
                                viewModel: viewModel,
                                section: section,
                                selectedIndex: binding(for: section),
                                isFocused: focusArea == .content && selectedRailIndex == index,
                                layout: layout,
                                openDetails: { game in openDetails(game, section.id) },
                                showAll: { showAll(section) }
                            )
                            .id(section.id)
                        }

                        if sections.isEmpty && !viewModel.isLoading && !viewModel.isLoadingPanels {
                            CatalogEmptyDestinationView(viewModel: viewModel, destination: viewModel.selectedCatalogDestination)
                                .frame(width: layout.contentWidth)
                                .padding(.top, 44 * uiScale)
                        }
                    }
                    .padding(.bottom, 46 * uiScale)
                }
                .onChange(of: selectedRailIndex) { _, index in
                    guard sections.indices.contains(index) else { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(sections[index].id, anchor: .center)
                    }
                }
                // The page is removed from the hierarchy while the search overlay is
                // up, so restore the focused rail's scroll position on reinsertion.
                .onAppear {
                    guard sections.indices.contains(selectedRailIndex) else { return }
                    proxy.scrollTo(sections[selectedRailIndex].id, anchor: .center)
                }
            }
        }
        .overlay {
            if (viewModel.isLoading || viewModel.isLoadingPanels) && sections.isEmpty {
                VendorSplashLoadingView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func binding(for section: CatalogSectionModel) -> Binding<Int> {
        Binding(
            get: { selectedGameIndices[section.id] ?? 0 },
            set: { selectedGameIndices[section.id] = $0 }
        )
    }

    private func heroGame(sections: [CatalogSectionModel]) -> OPNCatalogGameObject? {
        if sections.indices.contains(selectedRailIndex) {
            let section = sections[selectedRailIndex]
            let games = section.visibleGames(expanded: false)
            if let firstGame = games.first { return firstGame }
        }
        return viewModel.heroRotationGames.first ?? sections.flatMap(\.games).first
    }
}

/// The catalog's own way into search. Search is not a nav-bar destination, so without a visible
/// entry here it existed only as a button press the hint bar mentions - fine once you know it, and
/// invisible until then.
private struct ControllerSearchEntryBar: View {
    let isFocused: Bool
    let open: () -> Void

    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12 * uiScale) {
                Image(systemName: "magnifyingglass")
                    .nvidiaFont(size: 15, weight: .bold)
                    .foregroundStyle(isFocused ? .black.opacity(0.86) : OpenNOWDesign.accent)
                Text("Search")
                    .nvidiaFont(size: 14, weight: .medium)
                    .foregroundStyle(isFocused ? .black.opacity(0.82) : .white.opacity(0.62))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16 * uiScale)
            .frame(height: 44 * uiScale)
            .background(isFocused ? OpenNOWDesign.accent : Color.white.opacity(0.055))
            .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.subtle, lineWidth: 1) }
            .openNowFocusRing(isFocused)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Search games")
    }
}

private struct ControllerHeroBillboard: View {
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

private struct ControllerGameRail: View {
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

private struct ControllerRailLayoutMetrics {
    let visibleCount: Int
    let tileSize: CGSize
    let rowHeight: CGFloat
}

private struct ControllerGameTile: View, Equatable {
    let game: OPNCatalogGameObject
    let imageURL: URL?
    let isFocused: Bool
    let isQueuedForPatching: Bool
    let showsFreeAccountAccessBadges: Bool
    let tileSize: CGSize
    let action: () -> Void

    // The action closure is deliberately excluded: it is rebuilt on every parent render but always
    // targets the same game, and comparing it would defeat the `.equatable()` body-skip that keeps
    // a d-pad move from re-evaluating every visible tile. The card this replaced had exactly this
    // conformance; swapping it out silently dropped the skip.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.game.catalogIdentity == rhs.game.catalogIdentity
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

private struct ControllerEmbeddedPage<Content: View>: View {
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

private struct ControllerSearchOverlay: View {
    @Bindable var viewModel: CatalogViewModel
    let rowIndex: Int
    let filterOptionIndices: [String: Int]
    let resultIndex: Int
    let layout: ControllerLayoutMetrics
    let selectResult: (OPNCatalogGameObject) -> Void
    let close: () -> Void
    let focusSearchRow: () -> Void
    let openSortPicker: () -> Void
    let openFilterPicker: (OPNCatalogFilterGroupObject) -> Void

    /// The field is the focused row's real first responder, not just a highlighted box. The
    /// keyboard bridge already steps aside whenever a text field owns the keyboard, so focus here
    /// is what makes typing reach the query at all - without it the overlay opened with nothing
    /// focused and keystrokes went nowhere until the field was clicked with a mouse.
    @FocusState private var isSearchFieldFocused: Bool

    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        GeometryReader { proxy in
            let columns = overlayColumnCount(width: layout.contentWidth, minimumWidth: 250 * uiScale, spacing: 14 * uiScale)
            VStack(alignment: .leading, spacing: 16 * uiScale) {
                searchField
                filterBar
                resultsGrid(columns: columns)
            }
            .frame(width: layout.contentWidth, alignment: .leading)
            .padding(.top, 16 * uiScale)
            .padding(.bottom, 12 * uiScale)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
        }
        .opnTakingFocus($isSearchFieldFocused, while: rowIndex == 0)
        .onChange(of: rowIndex) { _, row in
            // Moving off the search row hands the keyboard back to the navigation bridge.
            if row != 0 { isSearchFieldFocused = false }
        }
        .onChange(of: isSearchFieldFocused) { _, isFocused in
            guard isFocused, rowIndex != 0 else { return }
            focusSearchRow()
        }
        .onExitCommand { close() }
    }

    private var searchField: some View {
        HStack(spacing: 14 * uiScale) {
            Image(systemName: "magnifyingglass")
                .nvidiaFont(size: 18, weight: .bold)
                .foregroundStyle(rowIndex == 0 ? OpenNOWDesign.accent : .white.opacity(0.62))
            TextField("Search", text: $viewModel.searchQuery)
                .textFieldStyle(.plain)
                .nvidiaFont(size: 20, weight: .medium)
                .foregroundStyle(.white)
                .focused($isSearchFieldFocused)
                .onSubmit { viewModel.browseCatalog() }
            if !viewModel.searchQuery.isEmpty {
                Button("CLEAR", action: { viewModel.searchQuery = "" })
                    .buttonStyle(.plain)
                    .nvidiaFont(size: 12, weight: .bold)
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
        .padding(.horizontal, 18 * uiScale)
        .frame(height: 58 * uiScale)
        .background(Color.white.opacity(rowIndex == 0 ? 0.12 : 0.075))
        .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.subtle, lineWidth: 1) }
        .openNowFocusRing(rowIndex == 0)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10 * uiScale) {
                sortChip
                ForEach(Array(viewModel.visibleFilterGroups.enumerated()), id: \.element.id) { groupIndex, group in
                    filterChip(for: group, groupIndex: groupIndex)
                }
                if viewModel.selectedFilterCount > 0 {
                    clearFiltersChip
                }
            }
            .padding(.vertical, 4 * uiScale)
        }
    }

    /// Which chip in the filter bar is focused. The input side has always tracked this in
    /// `_barIndex`; nothing rendered from it, so moving along the bar was invisible and the sort
    /// chip looked permanently focused.
    private var focusedBarIndex: Int { filterOptionIndices[ControllerSearchBar.indexKey] ?? 0 }

    private var sortChip: some View {
        let sortLabel = viewModel.sortOptions.first { $0.id == viewModel.selectedSortId }?.label ?? viewModel.selectedSortLabel
        let isFocused = rowIndex == 1 && focusedBarIndex == ControllerSearchBar.sortIndex
        return Button {
            openSortPicker()
        } label: {
            HStack(spacing: 8 * uiScale) {
                Image(systemName: "arrow.up.arrow.down")
                    .nvidiaFont(size: 11, weight: .bold)
                Text("SORT: \(sortLabel.uppercased())")
                    .nvidiaFont(size: 12, weight: .bold)
                    .tracking(0.6)
            }
            .foregroundStyle(isFocused ? .black.opacity(0.88) : .white.opacity(0.82))
            .padding(.horizontal, 14 * uiScale)
            .frame(height: 36 * uiScale)
            .background(isFocused ? OpenNOWDesign.accent : Color.white.opacity(0.075))
            .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.subtle, lineWidth: 1) }
            .openNowFocusRing(isFocused)
        }
        .buttonStyle(.plain)
    }

    private func filterChip(for group: OPNCatalogFilterGroupObject, groupIndex: Int) -> some View {
        let selectedOption = group.options.first { viewModel.selectedFilterIds.contains($0.id) }
        let label = selectedOption?.label ?? group.label
        let isSelected = selectedOption != nil
        let isFocused = rowIndex == 1 && focusedBarIndex == ControllerSearchBar.filterIndex(groupIndex)
        return Button {
            openFilterPicker(group)
        } label: {
            HStack(spacing: 8 * uiScale) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .nvidiaFont(size: 10, weight: .bold)
                }
                Text("\(group.label.uppercased()): \(label.uppercased())")
                    .nvidiaFont(size: 12, weight: .bold)
                    .tracking(0.6)
            }
            .foregroundStyle(isFocused ? .black.opacity(0.88) : (isSelected ? OpenNOWDesign.accent : .white.opacity(0.82)))
            .padding(.horizontal, 14 * uiScale)
            .frame(height: 36 * uiScale)
            .background(isFocused ? OpenNOWDesign.accent : (isSelected ? OpenNOWDesign.accent.opacity(0.15) : Color.white.opacity(0.075)))
            .overlay { Rectangle().stroke(isSelected ? OpenNOWDesign.accent : OpenNOWDesign.Stroke.subtle, lineWidth: 1) }
            .openNowFocusRing(isFocused)
        }
        .buttonStyle(.plain)
    }

    private var clearFiltersChip: some View {
        let isFocused = rowIndex == 1 && focusedBarIndex == ControllerSearchBar.clearIndex(groupCount: viewModel.visibleFilterGroups.count)
        return Button {
            viewModel.clearSearchAndFilters()
        } label: {
            HStack(spacing: 6 * uiScale) {
                Image(systemName: "xmark.circle.fill")
                    .nvidiaFont(size: 12, weight: .bold)
                Text("CLEAR FILTERS")
                    .nvidiaFont(size: 11, weight: .bold)
                    .tracking(0.6)
            }
            .foregroundStyle(isFocused ? .black.opacity(0.88) : .white.opacity(0.72))
            .padding(.horizontal, 12 * uiScale)
            .frame(height: 36 * uiScale)
            .background(isFocused ? OpenNOWDesign.accent : Color.white.opacity(0.05))
            .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.subtle, lineWidth: 1) }
            .openNowFocusRing(isFocused)
        }
        .buttonStyle(.plain)
    }

    private func resultsGrid(columns: Int) -> some View {
        let isResultsRowFocused = rowIndex == 2
        return VStack(alignment: .leading, spacing: 10 * uiScale) {
            ControllerOverlaySectionTitle(viewModel.resultSummary.isEmpty ? "Results" : viewModel.resultSummary)
            GeometryReader { grid in
                // The same tile the rails use, so a game looks identical whether it was found by
                // browsing or by searching.
                let spacing = 14 * uiScale
                let tileWidth = max((grid.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns), 1)
                let tileSize = CGSize(width: floor(tileWidth), height: floor(tileWidth * 9 / 16))
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(tileSize.width), spacing: spacing), count: columns), spacing: spacing) {
                        ForEach(Array(viewModel.catalogGames.enumerated()), id: \.element.catalogIdentity) { index, game in
                            ControllerGameTile(
                                game: game,
                                imageURL: viewModel.optimizedImageURL(game.bestWideImageURL, width: 720),
                                isFocused: isResultsRowFocused && resultIndex == index,
                                isQueuedForPatching: viewModel.isQueuedForPatching(game),
                                showsFreeAccountAccessBadges: viewModel.isFreeTierAccount,
                                tileSize: tileSize,
                                action: { selectResult(game) }
                            )
                            .equatable()
                        }
                    }
                    .padding(.bottom, 12 * uiScale)
                }
            }
        }
    }

}

private struct ControllerSearchPickerOverlay: View {
    let picker: ControllerSearchPicker
    let selectedIndex: Int
    let selectedOptionIds: [String]
    let selectedSortId: String
    let glyphs: ControllerInputGlyphSet
    let layout: ControllerLayoutMetrics
    let select: (Int) -> Void
    let close: () -> Void

    @Environment(\.opnUIScale) private var uiScale

    /// Sized from the row count rather than left to fill: the list is inside a ScrollView, which
    /// is greedy, so an unconstrained panel stretched to the full window height even for a
    /// three-option sort list.
    private var panelHeight: CGFloat {
        let rowHeight = 44 * uiScale
        let rowSpacing = 8 * uiScale
        let rows = CGFloat(picker.options.count)
        let chrome = 118 * uiScale
        let content = rows * rowHeight + max(rows - 1, 0) * rowSpacing + chrome
        return min(content, layout.size.height * 0.72)
    }

    private func isApplied(_ option: ControllerSearchPicker.Option) -> Bool {
        switch picker.kind {
        case .sort:
            return option.id == selectedSortId
        case .filter:
            guard option.id != ControllerSearchPicker.clearOptionId else {
                return !picker.options.contains { $0.id != ControllerSearchPicker.clearOptionId && selectedOptionIds.contains($0.id) }
            }
            return selectedOptionIds.contains(option.id)
        }
    }

    var body: some View {
        ZStack {
            OpenNOWDesign.Surface.scrim
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(alignment: .leading, spacing: 0) {
                ControllerOverlayHeader(title: picker.title, subtitle: "Choose one", glyphs: glyphs, close: close)
                    .padding(.horizontal, 22 * uiScale)
                    .padding(.top, 18 * uiScale)
                    .padding(.bottom, 12 * uiScale)

                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 8 * uiScale) {
                            ForEach(Array(picker.options.enumerated()), id: \.element.id) { index, option in
                                let isFocused = index == selectedIndex
                                Button { select(index) } label: {
                                    HStack(spacing: 13 * uiScale) {
                                        Image(systemName: isApplied(option) ? "checkmark.circle.fill" : "circle")
                                            .nvidiaFont(size: 13, weight: .bold)
                                            .foregroundStyle(isFocused ? .black.opacity(0.86) : OpenNOWDesign.accent)
                                        Text(option.label)
                                            .nvidiaFont(size: 14, weight: .bold)
                                            .foregroundStyle(isFocused ? .black.opacity(0.88) : .white.opacity(0.88))
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 14 * uiScale)
                                    .frame(height: 44 * uiScale)
                                    .background(isFocused ? OpenNOWDesign.accent : Color.white.opacity(0.055))
                                    .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.subtle, lineWidth: 1) }
                                    .openNowFocusRing(isFocused)
                                }
                                .buttonStyle(.plain)
                                .id(option.id)
                            }
                        }
                        .padding(.horizontal, 22 * uiScale)
                        .padding(.bottom, 22 * uiScale)
                    }
                    .onChange(of: selectedIndex) { _, index in
                        guard picker.options.indices.contains(index) else { return }
                        withAnimation(.easeOut(duration: 0.16)) {
                            proxy.scrollTo(picker.options[index].id, anchor: .center)
                        }
                    }
                }
            }
            .frame(width: min(520 * uiScale, layout.contentWidth), height: panelHeight, alignment: .topLeading)
            .background(OpenNOWDesign.Surface.deep.opacity(0.98))
            .overlay(alignment: .top) { Rectangle().fill(OpenNOWDesign.accent).frame(height: 2) }
            .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.subtle, lineWidth: 1) }
        }
    }
}

private struct ControllerGameDetailOverlay: View {
    let viewModel: CatalogViewModel
    let game: OPNCatalogGameObject
    let selectedActionIndex: Int
    let actions: [ControllerDetailAction]
    let glyphs: ControllerInputGlyphSet
    let layout: ControllerLayoutMetrics
    let perform: (ControllerDetailAction) -> Void
    let close: () -> Void

    private var selectedVariant: OPNCatalogGameVariantObject? { viewModel.selectedVariant(in: game) }
    private var selectedPlatformOption: CatalogPlatformOption? { viewModel.selectedPlatformOption(in: game) }

    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        GeometryReader { proxy in
            let panelWidth = min(layout.contentWidth * 0.62, 900)
            ZStack {
                ControllerArtworkBackdrop(viewModel: viewModel, game: game, size: proxy.size)

                VStack(alignment: .leading, spacing: 18 * uiScale) {
                    ControllerOverlayHeader(title: game.title.isEmpty ? "Selected Game" : game.title, subtitle: detailSubtitle, glyphs: glyphs, close: close)
                    detailMetadata
                    Text(detailDescription)
                        .nvidiaFont(size: 18, weight: .medium)
                        .foregroundStyle(.white.opacity(0.82))
                        .lineSpacing(4)
                        .lineLimit(5)
                        .frame(maxWidth: 720 * uiScale, alignment: .leading)
                    detailRows
                    FlowLayout(spacing: 12 * uiScale) {
                        ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                            Button { perform(action) } label: {
                                HStack(spacing: 9 * uiScale) {
                                    Image(systemName: action.icon)
                                        .nvidiaFont(size: 14, weight: .bold)
                                    Text(action.title(game: game, selectedVariant: selectedVariant, viewModel: viewModel).uppercased())
                                        .nvidiaFont(size: 12, weight: .bold)
                                        .tracking(0.8)
                                }
                                .foregroundStyle(index == selectedActionIndex ? .black.opacity(0.88) : .white.opacity(0.86))
                                .padding(.horizontal, 15 * uiScale)
                                .frame(height: 44 * uiScale)
                                .background(index == selectedActionIndex ? OpenNOWDesign.accent : Color.white.opacity(0.075))
                                .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.regular, lineWidth: 1) }
                                .openNowFocusRing(index == selectedActionIndex)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 8 * uiScale)
                }
                .frame(width: panelWidth, alignment: .leading)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
    }

    private var detailSubtitle: String {
        let store = selectedPlatformOption?.title ?? game.primaryStoreLabel
        let ownership = selectedPlatformOption?.hasAccess == true ? "Ready" : (selectedPlatformOption?.status.isEmpty == false ? selectedPlatformOption?.status ?? "Ownership required" : "Ownership required")
        return [store, ownership].filter { !$0.isEmpty }.joined(separator: " • ")
    }

    private var detailDescription: String {
        let short = game.shortDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !short.isEmpty { return short }
        let long = game.longDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !long.isEmpty { return long }
        return "Play instantly through GeForce NOW cloud streaming."
    }

    private var detailMetadata: some View {
        FlowLayout(spacing: 8 * uiScale) {
            if !game.ratingLabel.isEmpty { ControllerMetadataPill(text: game.ratingLabel) }
            if game.supportsGamepad { ControllerMetadataPill(text: "Gamepad") }
            if game.supportsKeyboard { ControllerMetadataPill(text: "Keyboard") }
            ForEach(Array(game.genres.prefix(3)), id: \.self) { genre in
                ControllerMetadataPill(text: genre)
            }
            if game.isLaunchPatching { ControllerMetadataPill(text: "Patching", highlighted: true) }
        }
        .frame(maxWidth: 720 * uiScale, alignment: .leading)
    }

    private var detailRows: some View {
        VStack(alignment: .leading, spacing: 8 * uiScale) {
            ControllerDetailRow(label: "Publisher", value: game.publisherName)
            ControllerDetailRow(label: "Developer", value: game.developerName)
            ControllerDetailRow(label: "Stores", value: game.storeLine)
            ControllerDetailRow(label: "Players", value: playerLine)
        }
    }

    private var playerLine: String {
        if game.maxOnlinePlayers > 1, game.maxLocalPlayers > 1 { return "1-\(game.maxLocalPlayers) local, online multiplayer" }
        if game.maxOnlinePlayers > 1 { return "Online multiplayer" }
        if game.maxLocalPlayers > 1 { return "1-\(game.maxLocalPlayers) local players" }
        return "Single player"
    }
}

private func overlayColumnCount(width: CGFloat, minimumWidth: CGFloat, spacing: CGFloat) -> Int {
    max(2, Int((width + spacing) / (minimumWidth + spacing)))
}

private struct ControllerActionMenuOverlay: View {
    let items: [ControllerActionMenuItem]
    let selectedIndex: Int
    let glyphs: ControllerInputGlyphSet
    let layout: ControllerLayoutMetrics
    let topInset: CGFloat
    let isRefreshingCatalog: Bool
    let perform: (ControllerActionMenuItem) -> Void
    let close: () -> Void

    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        ZStack(alignment: .trailing) {
            Color.black.opacity(0.58).onTapGesture(perform: close)
            VStack(alignment: .leading, spacing: 0) {
                ControllerOverlayHeader(title: "Controller Actions", subtitle: "Catalog navigation and account actions", glyphs: glyphs, close: close)
                    .padding(.horizontal, 22 * uiScale)
                    .padding(.top, 22 + topInset)
                    .padding(.bottom, 12 * uiScale)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8 * uiScale) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            Button { perform(item) } label: {
                                HStack(spacing: 13 * uiScale) {
                                    if item.isRefresh, isRefreshingCatalog {
                                        ProgressView()
                                            .controlSize(.small)
                                            .tint(index == selectedIndex ? .black.opacity(0.86) : OpenNOWDesign.accent)
                                            .scaleEffect(0.82)
                                            .frame(width: 28 * uiScale)
                                    } else {
                                        Image(systemName: item.icon)
                                            .nvidiaFont(size: 15, weight: .bold)
                                            .foregroundStyle(index == selectedIndex ? .black.opacity(0.86) : OpenNOWDesign.accent)
                                            .frame(width: 28 * uiScale)
                                    }
                                    Text(item.isRefresh && isRefreshingCatalog ? "Refreshing Catalog" : item.title)
                                        .nvidiaFont(size: 15, weight: .bold)
                                        .foregroundStyle(index == selectedIndex ? .black.opacity(0.88) : .white.opacity(0.88))
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 14 * uiScale)
                                .frame(height: 48 * uiScale)
                                .background(index == selectedIndex ? OpenNOWDesign.accent : Color.white.opacity(0.055))
                                .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.subtle, lineWidth: 1) }
                                .openNowFocusRing(index == selectedIndex)
                            }
                            .buttonStyle(.plain)
                            .disabled(item.isRefresh && isRefreshingCatalog)
                        }
                    }
                    .padding(.horizontal, 22 * uiScale)
                    .padding(.bottom, 22 * uiScale)
                }
            }
            .frame(maxWidth: 420 * uiScale, maxHeight: .infinity, alignment: .topLeading)
            .background(OpenNOWDesign.Surface.deep.opacity(0.98))
            .overlay(alignment: .leading) { Rectangle().fill(OpenNOWDesign.accent).frame(width: 3) }
            .padding(.leading, layout.leadingInset)
            .padding(.trailing, layout.trailingInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

private struct ControllerOverlayHeader: View {
    let title: String
    let subtitle: String
    let glyphs: ControllerInputGlyphSet
    let close: () -> Void

    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        HStack(alignment: .top, spacing: 16 * uiScale) {
            VStack(alignment: .leading, spacing: 6 * uiScale) {
                Text(title.uppercased())
                    .nvidiaFont(size: 27, weight: .bold)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .nvidiaFont(size: 14, weight: .medium)
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8 * uiScale) {
                ControllerGlyphPill(glyph: glyphs.back)
                Text("BACK")
                    .nvidiaFont(size: 11, weight: .bold)
                    .foregroundStyle(.white.opacity(0.62))
            }
            Button(action: close) {
                Image(systemName: "xmark")
                    .nvidiaFont(size: 16, weight: .bold)
                    .foregroundStyle(.white.opacity(0.80))
                    .frame(width: 38 * uiScale, height: 38 * uiScale)
                    .background(Color.white.opacity(0.08))
                    .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.regular, lineWidth: 1) }
            }
            .buttonStyle(.plain)
        }
    }
}

private struct ControllerOverlaySectionTitle: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .nvidiaFont(size: 12, weight: .bold)
            .tracking(1.1)
            .foregroundStyle(OpenNOWDesign.accent.opacity(0.86))
    }
}

private struct ControllerMetadataPill: View {
    let text: String
    var highlighted = false

    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        Text(text.uppercased())
            .nvidiaFont(size: 11, weight: .bold)
            .tracking(0.7)
            .foregroundStyle(highlighted ? .black.opacity(0.88) : .white.opacity(0.82))
            .padding(.horizontal, 10 * uiScale)
            .frame(height: 28 * uiScale)
            .background(highlighted ? OpenNOWDesign.accent : Color.white.opacity(0.075))
            .overlay { Rectangle().stroke(highlighted ? OpenNOWDesign.accent : OpenNOWDesign.Stroke.regular, lineWidth: 1) }
    }
}

private struct ControllerDetailRow: View {
    let label: String
    let value: String

    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        if !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 16 * uiScale) {
                Text(label.uppercased())
                    .nvidiaFont(size: 10, weight: .bold)
                    .tracking(0.7)
                    .foregroundStyle(.white.opacity(0.42))
                    .frame(width: 96 * uiScale, alignment: .leading)
                Text(value)
                    .nvidiaFont(size: 13, weight: .bold)
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(2)
            }
        }
    }
}

private enum ControllerHint: Equatable {
    case move
    case select
    case back
    case search
    case showAll
    case menu
    case clear
}

private struct ControllerHintBar: View {
    let hints: [ControllerHint]
    let glyphs: ControllerInputGlyphSet
    let layout: ControllerLayoutMetrics

    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        HStack(spacing: 14 * uiScale) {
            ForEach(hints, id: \.self) { hint in
                ControllerHintItem(hint: hint, glyphs: glyphs)
            }
            Spacer(minLength: 0)
            Text(glyphs.usesControllerGlyphs ? "Controller mode" : "Keyboard fallback")
                .nvidiaFont(size: 11, weight: .bold)
                .foregroundStyle(.white.opacity(0.38))
                .tracking(0.8)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(width: layout.contentWidth, alignment: .leading)
        .frame(height: 46 * uiScale)
        .background(Color.black.opacity(0.36))
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
    }
}

private struct ControllerHintItem: View {
    let hint: ControllerHint
    let glyphs: ControllerInputGlyphSet

    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        HStack(spacing: 6 * uiScale) {
            if hint == .move, !glyphs.usesControllerGlyphs {
                ControllerKeyboardMovePill(glyphs: glyphs)
            } else {
                ForEach(Array(glyphSet.enumerated()), id: \.offset) { _, glyph in
                    ControllerGlyphPill(glyph: glyph, compact: hint == .move)
                }
            }
            Text(title)
                .nvidiaFont(size: 10, weight: .bold)
                .foregroundStyle(.white.opacity(0.64))
                .tracking(0.5)
        }
    }

    private var glyphSet: [ControllerInputGlyph] {
        switch hint {
        case .move: return [glyphs.left, glyphs.up, glyphs.down, glyphs.right]
        case .select: return [glyphs.confirm]
        case .back: return [glyphs.back]
        case .search: return [glyphs.search]
        case .showAll: return [glyphs.actions]
        case .menu: return [glyphs.menu]
        case .clear: return [glyphs.actions]
        }
    }

    private var title: String {
        switch hint {
        case .move: return "MOVE"
        case .select: return "SELECT"
        case .back: return "BACK"
        case .search: return "SEARCH"
        case .showAll: return "SHOW ALL"
        case .menu: return "MENU"
        case .clear: return "CLEAR"
        }
    }
}

private struct ControllerGlyphPill: View {
    let glyph: ControllerInputGlyph
    var compact = false

    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        HStack(spacing: (compact ? 0 : 5) * uiScale) {
            if !glyph.symbolName.isEmpty {
                Image(systemName: glyph.symbolName)
                    .nvidiaFont(size: compact ? 11 : 12, weight: .bold)
            }
            if shouldShowText {
                Text(glyph.fallbackText)
                    .nvidiaFont(size: compact ? 0 : 9, weight: .bold)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(OpenNOWDesign.accent)
        .padding(.horizontal, (compact ? 6 : 7) * uiScale)
        .frame(minWidth: (compact ? 25 : 0) * uiScale)
        .frame(height: 22 * uiScale)
        .background(OpenNOWDesign.accent.opacity(0.12))
        .overlay { Rectangle().stroke(OpenNOWDesign.accent.opacity(0.30), lineWidth: 1) }
        .accessibilityLabel(glyph.accessibilityLabel)
    }

    private var shouldShowText: Bool {
        guard !compact else { return false }
        guard !["↑", "↓", "←", "→"].contains(glyph.fallbackText) else { return false }
        return true
    }
}

private struct ControllerKeyboardMovePill: View {
    let glyphs: ControllerInputGlyphSet

    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        HStack(spacing: 5 * uiScale) {
            Image(systemName: glyphs.left.symbolName)
            Image(systemName: glyphs.up.symbolName)
            Image(systemName: glyphs.down.symbolName)
            Image(systemName: glyphs.right.symbolName)
        }
        .nvidiaFont(size: 11, weight: .bold)
        .foregroundStyle(OpenNOWDesign.accent)
        .padding(.horizontal, 8 * uiScale)
        .frame(height: 22 * uiScale)
        .background(OpenNOWDesign.accent.opacity(0.12))
        .overlay { Rectangle().stroke(OpenNOWDesign.accent.opacity(0.30), lineWidth: 1) }
        .accessibilityLabel("Arrow keys")
    }
}

/// Blurred cover art behind the game detail overlay, carrying the stream launch screen's treatment
/// - artwork under a top-to-bottom scrim - so choosing a game and launching it share one visual
/// language instead of the details sitting on flat black.
///
/// The artwork is laid out larger than the surface, blurred, and only then clipped back: blurring
/// at the exact size pulls the soft edge inward and leaves a translucent border around the page.
private struct ControllerArtworkBackdrop: View {
    let viewModel: CatalogViewModel
    let game: OPNCatalogGameObject
    let size: CGSize

    private static let bleed: CGFloat = 80

    var body: some View {
        ZStack {
            Color.black

            CatalogCachedImageView(
                url: viewModel.optimizedImageURL(game.bestDetailImageURL, width: 1280),
                contentMode: .fill,
                maxPixelSize: 1280,
                placeholder: Color.clear,
                failure: Color.clear
            )
            .frame(width: size.width + Self.bleed, height: size.height + Self.bleed)
            .blur(radius: 30)
            .frame(width: size.width, height: size.height)
            .clipped()
            .opacity(0.45)

            // Keeps the description and metadata rows legible over bright artwork.
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.54), location: 0),
                    .init(color: .black.opacity(0.20), location: 0.42),
                    .init(color: .black.opacity(0.78), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

private struct ControllerCatalogBackground: View {
    let viewModel: CatalogViewModel
    let game: OPNCatalogGameObject?

    var body: some View {
        ZStack {
            OpenNOWDesign.Surface.app.ignoresSafeArea()
            if let game {
                CatalogRemoteImage(url: viewModel.optimizedImageURL(game.bestDetailImageURL, width: 1280), contentMode: .fill, maxPixelSize: 1280)
                    .ignoresSafeArea()
                    .blur(radius: 44)
                    .opacity(0.26)
            }
            LinearGradient(colors: [.black.opacity(0.84), .black.opacity(0.38), .black.opacity(0.82)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
    }
}

private struct ControllerKeyboardInputBridge: NSViewRepresentable {
    let onCommand: (ControllerInputCommand) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCommand: onCommand)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.installMonitor()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onCommand = onCommand
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        var onCommand: (ControllerInputCommand) -> Void
        private var monitor: Any?

        init(onCommand: @escaping (ControllerInputCommand) -> Void) {
            self.onCommand = onCommand
        }

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                guard let command = Self.command(for: event) else { return event }
                if MainActor.assumeIsolated({ Self.isTextInputActive }) {
                    // A focused field owns the keyboard: letters are text, and left/right are
                    // caret moves inside the query. Up and down stay navigation so the row can
                    // still be left without reaching for a pad.
                    guard case .move(let direction) = command, direction == .up || direction == .down else {
                        return event
                    }
                }
                self.onCommand(command)
                return nil
            }
        }

        func removeMonitor() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        @MainActor private static var isTextInputActive: Bool {
            guard let responder = NSApp.keyWindow?.firstResponder else { return false }
            return responder is NSTextView || String(describing: type(of: responder)).localizedCaseInsensitiveContains("Text")
        }

        private static func command(for event: NSEvent) -> ControllerInputCommand? {
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return nil }
            switch event.keyCode {
            case 126: return .move(.up)
            case 125: return .move(.down)
            case 123: return .move(.left)
            case 124: return .move(.right)
            case 36, 76: return .confirm
            case 53: return .back
            case 3: return .search
            case 46: return .actions
            case 48: return .menu
            case 33: return .pageLeft
            case 30: return .pageRight
            default: return nil
            }
        }
    }
}
