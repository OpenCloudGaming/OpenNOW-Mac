//
//  ControllerCatalogView.swift
//  OpenNOW
//

import AppKit
import SwiftUI


struct ControllerLayoutMetrics {
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
