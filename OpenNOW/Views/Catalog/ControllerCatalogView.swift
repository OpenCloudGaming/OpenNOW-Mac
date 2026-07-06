//
//  ControllerCatalogView.swift
//  OpenNOW
//

import AppKit
import Common
import OpenNOWGameServices
import SwiftUI

private enum ControllerDetailAction: Equatable {
    case primary
    case favorite
    case store
    case ownership
    case share
    case shortcut
    case visitStore
    case close

    @MainActor func title(game: OPNCatalogGameObject, selectedVariant: OPNCatalogGameVariantObject?, viewModel: CatalogViewModel) -> String {
        switch self {
        case .primary:
            if game.isLaunchPatching || selectedVariant?.isPatching == true { return viewModel.isQueuedForPatching(game) ? "Queued" : "Queue" }
            if game.isInLibrary || selectedVariant?.inLibrary == true || selectedVariant?.librarySelected == true { return "Play" }
            if selectedVariant != nil { return "Mark Owned" }
            return "Play"
        case .favorite: return viewModel.isFavorite(game) ? "Unfavorite" : "Favorite"
        case .store: return "Change Store"
        case .ownership:
            if selectedVariant?.inLibrary == true || selectedVariant?.librarySelected == true || game.isInLibrary { return "Unmark Owned" }
            return "Mark Owned"
        case .share: return "Share"
        case .shortcut: return "Add Shortcut"
        case .visitStore: return "Visit Store"
        case .close: return "Close"
        }
    }

    var icon: String {
        switch self {
        case .primary: return "play.fill"
        case .favorite: return "heart.fill"
        case .store: return "bag.fill"
        case .ownership: return "checkmark.seal.fill"
        case .share: return "square.and.arrow.up"
        case .shortcut: return "plus.rectangle.on.rectangle"
        case .visitStore: return "safari.fill"
        case .close: return "xmark"
        }
    }
}

private enum ControllerActionMenuItem {
    case refresh
    case clearSearch
    case twitch
    case home
    case library
    case favorites
    case recordings
    case settings
    case switchAccount(LoginAccount)
    case signOut

    var title: String {
        switch self {
        case .refresh: return "Refresh Catalog"
        case .clearSearch: return "Clear Search and Filters"
        case .twitch: return "Toggle Twitch Broadcast"
        case .home: return "Go to Home"
        case .library: return "Go to Library"
        case .favorites: return "Go to Favorites"
        case .recordings: return "Open Recordings"
        case .settings: return "Open Settings"
        case .switchAccount(let account): return "Switch to \(account.displayName)"
        case .signOut: return "Sign Out"
        }
    }

    var icon: String {
        switch self {
        case .refresh: return "arrow.clockwise"
        case .clearSearch: return "line.3.horizontal.decrease.circle"
        case .twitch: return "dot.radiowaves.left.and.right"
        case .home: return "gamecontroller.fill"
        case .library: return "rectangle.stack.fill"
        case .favorites: return "heart.fill"
        case .recordings: return "play.rectangle.fill"
        case .settings: return "gearshape.fill"
        case .switchAccount: return "person.crop.circle"
        case .signOut: return "rectangle.portrait.and.arrow.right"
        }
    }
}

private struct ControllerLayoutMetrics {
    let size: CGSize
    let safeAreaInsets: EdgeInsets

    var contentWidth: CGFloat {
        max(visibleWidth - sideInset * 2, 1)
    }

    var contentLeading: CGFloat {
        safeAreaInsets.leading + sideInset
    }

    var compactHeight: Bool { size.height < 760 }
    var heroHeight: CGFloat { compactHeight ? 230 : 280 }
    var railPreferredTileWidth: CGFloat { compactHeight ? 278 : 300 }

    private var visibleWidth: CGFloat {
        max(size.width - safeAreaInsets.leading - safeAreaInsets.trailing, 1)
    }

    private var sideInset: CGFloat {
        min(max(visibleWidth * 0.025, 24), 56)
    }
}

struct ControllerCatalogView: View {
    @ObservedObject var viewModel: CatalogViewModel
    let accounts: [LoginAccount]
    let onSwitch: (LoginAccount) -> Void
    let onSignOut: () -> Void
    let onForget: (LoginAccount) -> Void

    @StateObject private var inputRouter = ControllerInputRouter()
    @StateObject private var controllerViewModel = ControllerCatalogViewModel()

    private var navigationItems: [ControllerNavigationItem] { controllerViewModel.navigationItems }

    var body: some View {
        GeometryReader { proxy in
            let layout = ControllerLayoutMetrics(size: proxy.size, safeAreaInsets: proxy.safeAreaInsets)
            ZStack {
                ControllerCatalogBackground(viewModel: viewModel, game: focusedHeroGame)

                VStack(spacing: 0) {
                    ControllerHeader(viewModel: viewModel, glyphs: inputRouter.glyphs, layout: layout)
                    ControllerNavigationBar(
                        items: navigationItems,
                        selectedIndex: controllerViewModel.selectedNavigationIndex,
                        isFocused: controllerViewModel.focusArea == .navigation && !hasModalOverlay,
                        activeItem: activeNavigationItem,
                        layout: layout,
                        select: selectNavigationItem
                    )
                    controllerPage(layout: layout)
                    ControllerHintBar(hints: hints, glyphs: inputRouter.glyphs, layout: layout)
                }
                .frame(width: layout.contentWidth, height: proxy.size.height, alignment: .top)
                .position(x: layout.contentLeading + layout.contentWidth / 2, y: proxy.size.height / 2)
                .clipped()

                if controllerViewModel.isSearchVisible {
                    ControllerSearchOverlay(
                        viewModel: viewModel,
                        glyphs: inputRouter.glyphs,
                        rowIndex: controllerViewModel.searchRowIndex,
                        filterOptionIndices: controllerViewModel.searchFilterOptionIndices,
                        resultIndex: controllerViewModel.searchResultIndex,
                        resultColumnCount: $controllerViewModel.searchResultColumnCount,
                        selectSort: { index in setSort(at: index) },
                        selectFilter: { group, index in setFilterOption(group: group, index: index) },
                        selectResult: { game in openDetails(game, sectionId: "catalog-results") },
                        close: { closeSearchOverlay() },
                        clear: { viewModel.clearSearchAndFilters() }
                    )
                    .transition(.opacity)
                    .zIndex(30)
                }

                if controllerViewModel.isDetailVisible, let game = viewModel.selectedGame {
                    ControllerGameDetailOverlay(
                        viewModel: viewModel,
                        game: game,
                        selectedActionIndex: controllerViewModel.detailActionIndex,
                        actions: detailActions(for: game),
                        glyphs: inputRouter.glyphs,
                        perform: executeDetailAction,
                        close: closeDetails
                    )
                    .transition(.opacity)
                    .zIndex(28)
                }

                if let showAllSection = controllerViewModel.showAllSection {
                    ControllerShowAllOverlay(
                        viewModel: viewModel,
                        section: showAllSection,
                        selectedIndex: controllerViewModel.showAllIndex,
                        columnCount: $controllerViewModel.showAllColumnCount,
                        glyphs: inputRouter.glyphs,
                        select: { game in openDetails(game, sectionId: showAllSection.id) },
                        close: closeShowAll
                    )
                    .transition(.opacity)
                    .zIndex(26)
                }

                if controllerViewModel.isActionMenuVisible {
                    ControllerActionMenuOverlay(
                        items: actionMenuItems,
                        selectedIndex: controllerViewModel.actionMenuIndex,
                        glyphs: inputRouter.glyphs,
                        perform: executeActionMenuItem,
                        close: closeActionMenu
                    )
                    .transition(.opacity)
                    .zIndex(34)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .background(ControllerKeyboardInputBridge { command in inputRouter.sendKeyboardCommand(command) })
        .onAppear {
            inputRouter.onCommand = handleInput
            synchronizeNavigationSelection()
        }
        .onDisappear { inputRouter.onCommand = nil }
        .onChange(of: viewModel.selectedMainPage) { _, _ in synchronizeNavigationSelection() }
        .onChange(of: viewModel.selectedCatalogDestination) { _, _ in synchronizeNavigationSelection() }
        .onChange(of: viewModel.catalogSections.map(\.id)) { _, _ in clampRailSelection() }
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
                openDetails: openDetails,
                showAll: openShowAll
            )
        case .recordings:
            ControllerEmbeddedPage(title: "Recordings", subtitle: "Saved gameplay videos", layout: layout) {
                RecordingsView()
            }
        case .settings:
            ControllerEmbeddedPage(title: "Settings", subtitle: "Streaming, account, interface, and system options", layout: layout) {
                SettingsView(viewModel: viewModel)
            }
        }
    }

    private var hasModalOverlay: Bool {
        controllerViewModel.hasControllerOverlay || viewModel.isLaunchFlowVisible || viewModel.isStorePickerVisible
    }

    private var activeNavigationItem: ControllerNavigationItem {
        if viewModel.selectedMainPage == .recordings { return .recordings }
        if viewModel.selectedMainPage == .settings { return .settings }
        switch viewModel.selectedCatalogDestination {
        case .home: return .home
        case .library: return .library
        case .favorites: return .favorites
        }
    }

    private var focusedHeroGame: OPNCatalogGameObject? {
        if controllerViewModel.isDetailVisible, let selectedGame = viewModel.selectedGame { return selectedGame }
        let sections = viewModel.catalogSections
        if sections.indices.contains(controllerViewModel.selectedRailIndex) {
            let section = sections[controllerViewModel.selectedRailIndex]
            let games = section.visibleGames(expanded: false)
            if let firstGame = games.first { return firstGame }
        }
        return viewModel.heroRotationGames.first ?? sections.flatMap(\.games).first
    }

    private var hints: [ControllerHint] {
        if controllerViewModel.isActionMenuVisible { return [.move, .select, .back] }
        if controllerViewModel.isSearchVisible { return [.move, .select, .back, .clear] }
        if controllerViewModel.isDetailVisible { return [.move, .select, .back, .search] }
        if controllerViewModel.showAllSection != nil { return [.move, .select, .back] }
        if controllerViewModel.focusArea == .content { return [.move, .select, .back, .search, .showAll, .menu] }
        return [.move, .select, .back, .search, .menu]
    }

    private var actionMenuItems: [ControllerActionMenuItem] {
        var items: [ControllerActionMenuItem] = [.refresh]
        if viewModel.isBrowseMode { items.append(.clearSearch) }
        items.append(.twitch)
        items.append(contentsOf: [.home, .library, .favorites, .recordings, .settings])
        for account in accounts where account.id != viewModel.account.id {
            items.append(.switchAccount(account))
        }
        items.append(.signOut)
        return items
    }

    private func handleInput(_ command: ControllerInputCommand) {
        if handleSharedOverlayInput(command) { return }
        if controllerViewModel.isActionMenuVisible { handleActionMenuInput(command); return }
        if controllerViewModel.isSearchVisible { handleSearchInput(command); return }
        if controllerViewModel.showAllSection != nil { handleShowAllInput(command); return }
        if controllerViewModel.isDetailVisible { handleDetailInput(command); return }
        handlePageInput(command)
    }

    private func handleSharedOverlayInput(_ command: ControllerInputCommand) -> Bool {
        if viewModel.isLaunchFlowVisible {
            switch command {
            case .back:
                viewModel.cancelVendorLaunch()
                return true
            case .confirm:
                if viewModel.launchFlowState == .activeSessionPrompt {
                    if viewModel.canResumeActiveLaunchSession { viewModel.resumeActiveLaunchSession() }
                    else { viewModel.endActiveSessionAndLaunchSelectedGame() }
                    return true
                }
                return false
            default:
                return true
            }
        }

        if viewModel.isStorePickerVisible {
            switch command {
            case .back:
                viewModel.closeStorePicker()
            case .move(.up), .move(.left):
                moveSelectedStore(delta: -1)
            case .move(.down), .move(.right):
                moveSelectedStore(delta: 1)
            case .confirm:
                confirmStorePickerStage()
            default:
                break
            }
            return true
        }
        return false
    }

    private func handlePageInput(_ command: ControllerInputCommand) {
        switch command {
        case .move(let direction):
            moveFocus(direction)
        case .confirm:
            confirmFocusedItem()
        case .back:
            if viewModel.selectedMainPage != .games || viewModel.selectedCatalogDestination != .home {
                viewModel.showCatalogDestination(.home)
                controllerViewModel.focusArea = .content
            }
        case .search:
            openSearchOverlay()
        case .actions:
            if controllerViewModel.focusArea == .content, let section = currentSection {
                openShowAll(section)
            } else {
                openActionMenu()
            }
        case .menu:
            openActionMenu()
        case .pageLeft:
            moveRail(delta: -1)
        case .pageRight:
            moveRail(delta: 1)
        }
    }

    private func handleActionMenuInput(_ command: ControllerInputCommand) {
        let items = actionMenuItems
        switch command {
        case .move(.up): controllerViewModel.actionMenuIndex = max(controllerViewModel.actionMenuIndex - 1, 0)
        case .move(.down): controllerViewModel.actionMenuIndex = min(controllerViewModel.actionMenuIndex + 1, max(items.count - 1, 0))
        case .confirm:
            guard items.indices.contains(controllerViewModel.actionMenuIndex) else { return }
            executeActionMenuItem(items[controllerViewModel.actionMenuIndex])
        case .back, .menu, .actions: closeActionMenu()
        default: break
        }
    }

    private func handleSearchInput(_ command: ControllerInputCommand) {
        switch command {
        case .move(.up): controllerViewModel.searchRowIndex = max(controllerViewModel.searchRowIndex - 1, 0)
        case .move(.down): controllerViewModel.searchRowIndex = min(controllerViewModel.searchRowIndex + 1, max(searchRowCount - 1, 0))
        case .move(.left): moveSearchSelection(delta: -1)
        case .move(.right): moveSearchSelection(delta: 1)
        case .confirm: confirmSearchSelection()
        case .actions: viewModel.clearSearchAndFilters()
        case .back, .search: closeSearchOverlay()
        default: break
        }
    }

    private func handleShowAllInput(_ command: ControllerInputCommand) {
        guard let section = controllerViewModel.showAllSection else { return }
        switch command {
        case .move(.left): controllerViewModel.showAllIndex = max(controllerViewModel.showAllIndex - 1, 0)
        case .move(.right): controllerViewModel.showAllIndex = min(controllerViewModel.showAllIndex + 1, max(section.games.count - 1, 0))
        case .move(.up): controllerViewModel.showAllIndex = max(controllerViewModel.showAllIndex - controllerViewModel.showAllColumnCount, 0)
        case .move(.down): controllerViewModel.showAllIndex = min(controllerViewModel.showAllIndex + controllerViewModel.showAllColumnCount, max(section.games.count - 1, 0))
        case .confirm:
            guard section.games.indices.contains(controllerViewModel.showAllIndex) else { return }
            openDetails(section.games[controllerViewModel.showAllIndex], sectionId: section.id)
        case .back, .actions, .menu: closeShowAll()
        case .search: openSearchOverlay()
        default: break
        }
    }

    private func handleDetailInput(_ command: ControllerInputCommand) {
        guard let game = viewModel.selectedGame else { return }
        let actions = detailActions(for: game)
        switch command {
        case .move(.left), .move(.up): controllerViewModel.detailActionIndex = max(controllerViewModel.detailActionIndex - 1, 0)
        case .move(.right), .move(.down): controllerViewModel.detailActionIndex = min(controllerViewModel.detailActionIndex + 1, max(actions.count - 1, 0))
        case .confirm:
            guard actions.indices.contains(controllerViewModel.detailActionIndex) else { return }
            executeDetailAction(actions[controllerViewModel.detailActionIndex])
        case .back: closeDetails()
        case .search: openSearchOverlay()
        case .actions, .menu: openActionMenu()
        default: break
        }
    }

    private func moveFocus(_ direction: ControllerInputDirection) {
        switch controllerViewModel.focusArea {
        case .navigation:
            switch direction {
            case .left: controllerViewModel.selectedNavigationIndex = max(controllerViewModel.selectedNavigationIndex - 1, 0)
            case .right: controllerViewModel.selectedNavigationIndex = min(controllerViewModel.selectedNavigationIndex + 1, max(navigationItems.count - 1, 0))
            case .down: controllerViewModel.focusArea = .content
            case .up: break
            }
        case .content:
            switch direction {
            case .left: moveGame(delta: -1)
            case .right: moveGame(delta: 1)
            case .up:
                if controllerViewModel.selectedRailIndex == 0 { controllerViewModel.focusArea = .navigation } else { moveRail(delta: -1) }
            case .down: moveRail(delta: 1)
            }
        }
    }

    private func confirmFocusedItem() {
        if controllerViewModel.focusArea == .navigation {
            guard navigationItems.indices.contains(controllerViewModel.selectedNavigationIndex) else { return }
            selectNavigationItem(navigationItems[controllerViewModel.selectedNavigationIndex])
            return
        }
        guard let section = currentSection else { return }
        let games = section.visibleGames(expanded: false)
        let index = clampedSelectedGameIndex(for: section, gameCount: games.count)
        guard games.indices.contains(index) else { return }
        openDetails(games[index], sectionId: section.id)
    }

    private func selectNavigationItem(_ item: ControllerNavigationItem) {
        controllerViewModel.selectedNavigationIndex = navigationItems.firstIndex(of: item) ?? controllerViewModel.selectedNavigationIndex
        switch item {
        case .home:
            viewModel.showCatalogDestination(.home)
            controllerViewModel.focusArea = .content
        case .library:
            viewModel.showCatalogDestination(.library)
            controllerViewModel.focusArea = .content
        case .favorites:
            viewModel.showCatalogDestination(.favorites)
            controllerViewModel.focusArea = .content
        case .search:
            openSearchOverlay()
        case .recordings:
            viewModel.showRecordings()
            controllerViewModel.focusArea = .navigation
        case .settings:
            viewModel.showSettings(.interface)
            controllerViewModel.focusArea = .navigation
        case .actions:
            openActionMenu()
        }
    }

    private var currentSection: CatalogSectionModel? {
        let sections = viewModel.catalogSections
        guard sections.indices.contains(controllerViewModel.selectedRailIndex) else { return nil }
        return sections[controllerViewModel.selectedRailIndex]
    }

    private func moveRail(delta: Int) {
        let sections = viewModel.catalogSections
        guard !sections.isEmpty else { return }
        controllerViewModel.selectedRailIndex = min(max(controllerViewModel.selectedRailIndex + delta, 0), sections.count - 1)
    }

    private func moveGame(delta: Int) {
        guard let section = currentSection else { return }
        let gameCount = section.visibleGames(expanded: false).count
        guard gameCount > 0 else { return }
        let index = clampedSelectedGameIndex(for: section, gameCount: gameCount)
        controllerViewModel.setSelectedGameIndex(index + delta, for: section, gameCount: gameCount)
    }

    private func clampedSelectedGameIndex(for section: CatalogSectionModel, gameCount: Int) -> Int {
        controllerViewModel.selectedGameIndex(for: section, gameCount: gameCount)
    }

    private func openDetails(_ game: OPNCatalogGameObject, sectionId: String) {
        viewModel.selectGame(game, inSection: sectionId)
        controllerViewModel.detailActionIndex = 0
        controllerViewModel.isDetailVisible = true
        controllerViewModel.isSearchVisible = false
        controllerViewModel.showAllSection = nil
    }

    private func closeDetails() {
        controllerViewModel.isDetailVisible = false
        viewModel.selectGame(nil)
    }

    private func openSearchOverlay() {
        controllerViewModel.isSearchVisible = true
        controllerViewModel.isActionMenuVisible = false
        controllerViewModel.searchRowIndex = min(controllerViewModel.searchRowIndex, max(searchRowCount - 1, 0))
    }

    private func closeSearchOverlay() {
        controllerViewModel.isSearchVisible = false
    }

    private func openActionMenu() {
        controllerViewModel.actionMenuIndex = min(controllerViewModel.actionMenuIndex, max(actionMenuItems.count - 1, 0))
        controllerViewModel.isActionMenuVisible = true
    }

    private func closeActionMenu() {
        controllerViewModel.isActionMenuVisible = false
    }

    private func openShowAll(_ section: CatalogSectionModel) {
        controllerViewModel.showAllSection = section
        controllerViewModel.showAllIndex = clampedSelectedGameIndex(for: section, gameCount: section.games.count)
    }

    private func closeShowAll() {
        controllerViewModel.showAllSection = nil
        controllerViewModel.showAllIndex = 0
    }

    private func detailActions(for game: OPNCatalogGameObject) -> [ControllerDetailAction] {
        var actions: [ControllerDetailAction] = [.primary, .favorite]
        if game.variants.count > 1 { actions.append(.store) }
        if viewModel.selectedVariant(in: game) != nil { actions.append(.ownership) }
        actions.append(contentsOf: [.share, .shortcut, .visitStore, .close])
        return actions
    }

    private func executeDetailAction(_ action: ControllerDetailAction) {
        guard let game = viewModel.selectedGame else { return }
        let selectedVariant = viewModel.selectedVariant(in: game)
        switch action {
        case .primary:
            if game.isLaunchPatching || selectedVariant?.isPatching == true {
                viewModel.queuePatchingLaunch(game: game, variantIndex: viewModel.selectedVariantIndex)
            } else if game.isInLibrary || selectedVariant?.inLibrary == true || selectedVariant?.librarySelected == true || selectedVariant == nil {
                viewModel.launchSelectedGame()
            } else {
                viewModel.markSelectedVariantOwned()
            }
        case .favorite:
            viewModel.toggleFavoriteSelectedGame()
        case .store:
            viewModel.changeSelectedGameStore()
        case .ownership:
            if selectedVariant?.inLibrary == true || selectedVariant?.librarySelected == true || game.isInLibrary {
                viewModel.removeSelectedVariantOwned()
            } else {
                viewModel.markSelectedVariantOwned()
            }
        case .share:
            viewModel.shareSelectedGame()
        case .shortcut:
            viewModel.addShortcutForSelectedGame()
        case .visitStore:
            viewModel.openStoreForSelectedVariant()
        case .close:
            closeDetails()
        }
    }

    private var searchRowCount: Int {
        2 + viewModel.visibleFilterGroups.count + (viewModel.catalogGames.isEmpty ? 0 : 1)
    }

    private func moveSearchSelection(delta: Int) {
        if controllerViewModel.searchRowIndex == 1 {
            let count = viewModel.sortOptions.count
            guard count > 0 else { return }
            let index = selectedSortIndex()
            setSort(at: min(max(index + delta, 0), count - 1))
            return
        }
        let filterStart = 2
        let filterEnd = filterStart + viewModel.visibleFilterGroups.count
        if controllerViewModel.searchRowIndex >= filterStart, controllerViewModel.searchRowIndex < filterEnd {
            let group = viewModel.visibleFilterGroups[controllerViewModel.searchRowIndex - filterStart]
            guard !group.options.isEmpty else { return }
            let index = min(max((controllerViewModel.searchFilterOptionIndices[group.id] ?? 0) + delta, 0), group.options.count - 1)
            controllerViewModel.searchFilterOptionIndices[group.id] = index
            return
        }
        if controllerViewModel.searchRowIndex == filterEnd, !viewModel.catalogGames.isEmpty {
            controllerViewModel.searchResultIndex = min(max(controllerViewModel.searchResultIndex + delta, 0), viewModel.catalogGames.count - 1)
        }
    }

    private func confirmSearchSelection() {
        if controllerViewModel.searchRowIndex == 0 {
            viewModel.browseCatalog()
            return
        }
        if controllerViewModel.searchRowIndex == 1 {
            setSort(at: selectedSortIndex())
            return
        }
        let filterStart = 2
        let filterEnd = filterStart + viewModel.visibleFilterGroups.count
        if controllerViewModel.searchRowIndex >= filterStart, controllerViewModel.searchRowIndex < filterEnd {
            let group = viewModel.visibleFilterGroups[controllerViewModel.searchRowIndex - filterStart]
            let index = controllerViewModel.searchFilterOptionIndices[group.id] ?? 0
            guard group.options.indices.contains(index) else { return }
            viewModel.toggleFilter(group.options[index].id)
            return
        }
        if controllerViewModel.searchRowIndex == filterEnd, viewModel.catalogGames.indices.contains(controllerViewModel.searchResultIndex) {
            openDetails(viewModel.catalogGames[controllerViewModel.searchResultIndex], sectionId: "catalog-results")
        }
    }

    private func selectedSortIndex() -> Int {
        viewModel.sortOptions.firstIndex { $0.id == viewModel.selectedSortId } ?? 0
    }

    private func setSort(at index: Int) {
        guard viewModel.sortOptions.indices.contains(index) else { return }
        viewModel.setSort(viewModel.sortOptions[index].id)
    }

    private func setFilterOption(group: OPNCatalogFilterGroupObject, index: Int) {
        guard group.options.indices.contains(index) else { return }
        controllerViewModel.searchFilterOptionIndices[group.id] = index
        viewModel.toggleFilter(group.options[index].id)
    }

    private func executeActionMenuItem(_ item: ControllerActionMenuItem) {
        closeActionMenu()
        switch item {
        case .refresh:
            viewModel.refresh()
        case .clearSearch:
            viewModel.clearSearchAndFilters()
        case .twitch:
            viewModel.toggleCatalogTwitchBroadcast()
        case .home:
            viewModel.showCatalogDestination(.home)
        case .library:
            viewModel.showCatalogDestination(.library)
        case .favorites:
            viewModel.showCatalogDestination(.favorites)
        case .recordings:
            viewModel.showRecordings()
        case .settings:
            viewModel.showSettings(.interface)
        case .switchAccount(let account):
            onSwitch(account)
        case .signOut:
            onSignOut()
        }
    }

    private func moveSelectedStore(delta: Int) {
        guard let game = viewModel.selectedGame, game.variants.count > 1 else { return }
        let currentIndex = viewModel.selectedVariantIndex >= 0 ? viewModel.selectedVariantIndex : CatalogViewModel.preferredVariantIndex(for: game)
        let nextIndex = min(max(currentIndex + delta, 0), game.variants.count - 1)
        viewModel.selectGameStoreVariant(at: nextIndex)
    }

    private func confirmStorePickerStage() {
        switch viewModel.ownershipFlowStage {
        case .storeSelection, .hidden:
            guard let game = viewModel.selectedGame else { return }
            let index = viewModel.selectedVariantIndex >= 0 ? viewModel.selectedVariantIndex : CatalogViewModel.preferredVariantIndex(for: game)
            viewModel.selectGameStoreVariant(at: index)
        case .manualMark:
            viewModel.confirmSelectedVariantOwned()
        case .success:
            viewModel.finishOwnershipFlow()
        case .resyncing:
            break
        }
    }

    private func synchronizeNavigationSelection() {
        let item = activeNavigationItem
        controllerViewModel.selectedNavigationIndex = navigationItems.firstIndex(of: item) ?? 0
        clampRailSelection()
    }

    private func clampRailSelection() {
        controllerViewModel.clampRailSelection(sectionCount: viewModel.catalogSections.count)
    }
}

private struct ControllerHeader: View {
    @ObservedObject var viewModel: CatalogViewModel
    let glyphs: ControllerInputGlyphSet
    let layout: ControllerLayoutMetrics

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("GEFORCE NOW")
                    .font(.nvidia(size: 11, weight: .bold))
                    .foregroundStyle(Color.openNowGreen)
                    .tracking(1.6)
                Text(headerTitle)
                    .font(.nvidia(size: 24, weight: .bold))
                    .foregroundStyle(.white.opacity(0.96))
            }
            Spacer(minLength: 0)
            ControllerDeviceBadge(glyphs: glyphs)
            CatalogAccountAvatar(account: viewModel.account, size: 34)
        }
        .frame(width: layout.contentWidth)
        .frame(height: 72)
        .background {
            Color.black.opacity(0.24)
            WindowDragArea()
        }
    }

    private var headerTitle: String {
        switch viewModel.selectedMainPage {
        case .games: return viewModel.selectedCatalogDestination.title
        case .recordings: return "Recordings"
        case .settings: return viewModel.selectedSettingsPage.title
        }
    }
}

private struct ControllerDeviceBadge: View {
    let glyphs: ControllerInputGlyphSet

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: glyphs.usesControllerGlyphs ? "gamecontroller.fill" : "keyboard")
                .font(.nvidia(size: 13, weight: .bold))
                .foregroundStyle(Color.openNowGreen)
            Text(glyphs.deviceName)
                .font(.nvidia(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 250, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .frame(maxWidth: 304)
        .background(Color.white.opacity(0.055))
        .overlay { Rectangle().stroke(Color.white.opacity(0.10), lineWidth: 1) }
    }
}

private struct ControllerNavigationBar: View {
    let items: [ControllerNavigationItem]
    let selectedIndex: Int
    let isFocused: Bool
    let activeItem: ControllerNavigationItem
    let layout: ControllerLayoutMetrics
    let select: (ControllerNavigationItem) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let selected = index == selectedIndex && isFocused
                    let active = activeItem == item
                    Button { select(item) } label: {
                        HStack(spacing: 9) {
                            Image(systemName: item.icon)
                                .font(.nvidia(size: 14, weight: .bold))
                            Text(item.title.uppercased())
                                .font(.nvidia(size: 12, weight: .bold))
                                .tracking(0.8)
                        }
                        .foregroundStyle(selected || active ? .black.opacity(0.86) : .white.opacity(0.78))
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .background(selected || active ? Color.openNowGreen : Color.white.opacity(0.065))
                        .overlay { Rectangle().stroke(selected ? .white.opacity(0.82) : (active ? Color.openNowGreen : Color.white.opacity(0.10)), lineWidth: selected ? 2 : 1) }
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: layout.contentWidth, alignment: .leading)
            .padding(.vertical, 10)
        }
        .frame(width: layout.contentWidth)
        .background(Color.black.opacity(0.18))
    }
}

private struct ControllerGamesPage: View {
    @ObservedObject var viewModel: CatalogViewModel
    let focusArea: ControllerCatalogFocusArea
    let selectedRailIndex: Int
    @Binding var selectedGameIndices: [String: Int]
    let layout: ControllerLayoutMetrics
    let openDetails: (OPNCatalogGameObject, String) -> Void
    let showAll: (CatalogSectionModel) -> Void

    var body: some View {
        let sections = viewModel.catalogSections
        GeometryReader { _ in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: layout.compactHeight ? 20 : 24) {
                        ControllerHeroBillboard(viewModel: viewModel, game: heroGame(sections: sections), height: layout.heroHeight)
                            .frame(width: layout.contentWidth)
                            .padding(.top, layout.compactHeight ? 10 : 14)

                        if !viewModel.errorMessage.isEmpty {
                            CatalogMessageView(message: viewModel.errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .frame(width: layout.contentWidth)
                        }

                        if viewModel.isBrowseMode {
                            ControllerBrowseSummary(viewModel: viewModel)
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
                                .padding(.top, 44)
                        }
                    }
                    .padding(.bottom, 46)
                }
                .onChange(of: selectedRailIndex) { _, index in
                    guard sections.indices.contains(index) else { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(sections[index].id, anchor: .center)
                    }
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

private struct ControllerHeroBillboard: View {
    @ObservedObject var viewModel: CatalogViewModel
    let game: OPNCatalogGameObject?
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let game {
                CatalogRemoteImage(url: viewModel.optimizedImageURL(game.bestMarqueeHeroImageURL, width: 1920), contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                LinearGradient(colors: [.black.opacity(0.94), .black.opacity(0.48), .black.opacity(0.10)], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.clear, .black.opacity(0.76)], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 9) {
                    Text("NOW PLAYING IN THE CLOUD")
                        .font(.nvidia(size: 11, weight: .bold))
                        .tracking(1.6)
                        .foregroundStyle(Color.openNowGreen)
                    Text(game.title.isEmpty ? "GeForce NOW" : game.title)
                        .font(.nvidia(size: height < 260 ? 31 : 36, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                    HStack(spacing: 10) {
                        if !game.ratingLabel.isEmpty { ControllerMetadataPill(text: game.ratingLabel) }
                        if game.supportsGamepad { ControllerMetadataPill(text: "Gamepad") }
                        if game.isInLibrary { ControllerMetadataPill(text: "In Library", highlighted: true) }
                        if let badge = game.cardBadgeLabel { ControllerMetadataPill(text: badge) }
                    }
                    Text(heroDescription(game))
                        .font(.nvidia(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.74))
                        .lineLimit(height < 260 ? 1 : 2)
                        .frame(maxWidth: 650, alignment: .leading)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, height < 260 ? 20 : 24)
                .frame(maxWidth: 720, maxHeight: .infinity, alignment: .bottomLeading)
            } else {
                CatalogImageFallback()
            }
        }
        .frame(height: height)
        .background(Color.black.opacity(0.34))
        .overlay { Rectangle().stroke(Color.white.opacity(0.12), lineWidth: 1) }
        .shadow(color: .black.opacity(0.38), radius: 28, y: 18)
        .clipped()
    }

    private func heroDescription(_ game: OPNCatalogGameObject) -> String {
        let description = game.shortDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty { return description }
        let genre = game.genres.prefix(2).joined(separator: ", ")
        return genre.isEmpty ? "Play instantly with GeForce NOW cloud streaming." : "\(genre) available on GeForce NOW."
    }
}

private struct ControllerBrowseSummary: View {
    @ObservedObject var viewModel: CatalogViewModel

    var body: some View {
        HStack(spacing: 10) {
            Text(viewModel.resultSummary.uppercased())
                .font(.nvidia(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.66))
            Text("SORT: \(viewModel.selectedSortLabel.uppercased())")
                .font(.nvidia(size: 12, weight: .bold))
                .foregroundStyle(Color.openNowGreen.opacity(0.90))
            if viewModel.selectedFilterCount > 0 {
                Text("\(viewModel.selectedFilterCount) FILTER\(viewModel.selectedFilterCount == 1 ? "" : "S")")
                    .font(.nvidia(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.66))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(Color.white.opacity(0.055))
        .overlay { Rectangle().stroke(Color.white.opacity(0.10), lineWidth: 1) }
    }
}

private struct ControllerGameRail: View {
    @ObservedObject var viewModel: CatalogViewModel
    let section: CatalogSectionModel
    @Binding var selectedIndex: Int
    let isFocused: Bool
    let layout: ControllerLayoutMetrics
    let openDetails: (OPNCatalogGameObject) -> Void
    let showAll: () -> Void

    private var games: [OPNCatalogGameObject] { section.visibleGames(expanded: false) }
    private var canShowAll: Bool { section.games.count > games.count }
    private var itemSpacing: CGFloat { 18 }

    var body: some View {
        VStack(alignment: .leading, spacing: layout.compactHeight ? 10 : 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(section.title)
                    .font(.nvidia(size: isFocused ? 24 : 21, weight: .bold))
                    .foregroundStyle(isFocused ? .white : .white.opacity(0.84))
                Text("\(section.games.count) games".uppercased())
                    .font(.nvidia(size: 11, weight: .bold))
                    .foregroundStyle(Color.openNowGreen.opacity(0.82))
                Spacer(minLength: 0)
                if canShowAll {
                    Button("SHOW ALL", action: showAll)
                        .buttonStyle(.plain)
                        .font(.nvidia(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.82))
                }
            }
            .frame(width: layout.contentWidth, alignment: .leading)

            GeometryReader { geometry in
                let metrics = layoutMetrics(width: geometry.size.width)
                HStack(spacing: itemSpacing) {
                    ForEach(visibleGames(metrics: metrics), id: \.game.catalogIdentity) { item in
                        ControllerGameTile(
                            game: item.game,
                            imageURL: viewModel.optimizedImageURL(item.game.bestWideImageURL, width: 720),
                            isFocused: isFocused && selectedIndex == item.index,
                            isQueuedForPatching: viewModel.isQueuedForPatching(item.game),
                            tileSize: metrics.tileSize,
                            action: { openDetails(item.game) }
                        )
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
        layout.compactHeight ? 178 : 196
    }

    private func layoutMetrics(width: CGFloat) -> ControllerRailLayoutMetrics {
        let contentWidth = max(width, 1)
        let count = min(max(1, Int((contentWidth + itemSpacing) / (layout.railPreferredTileWidth + itemSpacing))), max(games.count, 1))
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

private struct ControllerGameTile: View {
    let game: OPNCatalogGameObject
    let imageURL: URL?
    let isFocused: Bool
    let isQueuedForPatching: Bool
    let tileSize: CGSize
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topLeading) {
                CatalogRemoteImage(url: imageURL, contentMode: .fill)
                    .frame(width: tileSize.width, height: tileSize.height)
                    .clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.82)], startPoint: .top, endPoint: .bottom)
                if let badge = game.cardBadgeLabel {
                    CatalogGameCardBadge(label: badge)
                        .scaleEffect(0.92, anchor: .topLeading)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Spacer(minLength: 0)
                    HStack(spacing: 8) {
                        if game.isLaunchPatching {
                            Image(systemName: isQueuedForPatching ? "clock.fill" : "wrench.and.screwdriver.fill")
                                .font(.nvidia(size: 12, weight: .bold))
                                .foregroundStyle(Color.openNowGreen)
                        }
                        Text(game.title.isEmpty ? "GeForce NOW" : game.title)
                            .font(.nvidia(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    Text(subtitle)
                        .font(.nvidia(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                }
                .padding(15)
            }
            .frame(width: tileSize.width, height: tileSize.height)
            .overlay { Rectangle().stroke(isFocused ? Color.openNowGreen : Color.white.opacity(0.12), lineWidth: isFocused ? 4 : 1) }
            .shadow(color: isFocused ? Color.openNowGreen.opacity(0.18) : .black.opacity(0.20), radius: isFocused ? 12 : 8, y: 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(game.title.isEmpty ? "Game" : game.title)
    }

    private var subtitle: String {
        if game.isLaunchPatching { return isQueuedForPatching ? "Queued for patch completion" : "Patching" }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title.uppercased())
                    .font(.nvidia(size: 11, weight: .bold))
                    .foregroundStyle(Color.openNowGreen)
                    .tracking(1.4)
                Text(subtitle)
                    .font(.nvidia(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
            }
            .frame(width: layout.contentWidth, alignment: .leading)
            .padding(.top, 20)

            content
                .clipShape(Rectangle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ControllerSearchOverlay: View {
    @ObservedObject var viewModel: CatalogViewModel
    let glyphs: ControllerInputGlyphSet
    let rowIndex: Int
    let filterOptionIndices: [String: Int]
    let resultIndex: Int
    @Binding var resultColumnCount: Int
    let selectSort: (Int) -> Void
    let selectFilter: (OPNCatalogFilterGroupObject, Int) -> Void
    let selectResult: (OPNCatalogGameObject) -> Void
    let close: () -> Void
    let clear: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let columns = max(2, Int((proxy.size.width - 140) / 250))
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.90).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 18) {
                    ControllerOverlayHeader(title: "Search Catalog", subtitle: "Search, sort, filter, and launch from the full catalog.", glyphs: glyphs, close: close)
                    searchField
                    sortRow
                    filterRows
                    resultsGrid(columns: columns)
                }
                .padding(.horizontal, 54)
                .padding(.top, 38)
                .padding(.bottom, 32)
            }
            .onAppear { resultColumnCount = columns }
            .onChange(of: columns) { _, value in resultColumnCount = value }
        }
    }

    private var searchField: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.nvidia(size: 18, weight: .bold))
                .foregroundStyle(rowIndex == 0 ? Color.openNowGreen : .white.opacity(0.62))
            TextField("Search games, stores, genres, publishers, controls, ratings, or tags", text: $viewModel.searchQuery)
                .textFieldStyle(.plain)
                .font(.nvidia(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .onSubmit { viewModel.browseCatalog() }
            if !viewModel.searchQuery.isEmpty {
                Button("CLEAR", action: { viewModel.searchQuery = "" })
                    .buttonStyle(.plain)
                    .font(.nvidia(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
        .background(Color.white.opacity(rowIndex == 0 ? 0.12 : 0.075))
        .overlay { Rectangle().stroke(rowIndex == 0 ? Color.openNowGreen : Color.white.opacity(0.13), lineWidth: rowIndex == 0 ? 2 : 1) }
    }

    private var sortRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            ControllerOverlaySectionTitle("Sort")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(viewModel.sortOptions.enumerated()), id: \.element.id) { index, option in
                        ControllerOptionChip(
                            title: option.label.isEmpty ? option.id : option.label,
                            isSelected: option.id == viewModel.selectedSortId,
                            isFocused: rowIndex == 1 && selectedSortIndex == index,
                            action: { selectSort(index) }
                        )
                    }
                }
            }
        }
    }

    private var filterRows: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(viewModel.visibleFilterGroups.enumerated()), id: \.element.id) { groupIndex, group in
                VStack(alignment: .leading, spacing: 10) {
                    ControllerOverlaySectionTitle(group.label.isEmpty ? group.id : group.label)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Array(group.options.enumerated()), id: \.element.id) { optionIndex, option in
                                ControllerOptionChip(
                                    title: option.label.isEmpty ? option.id : option.label,
                                    isSelected: viewModel.selectedFilterIds.contains(option.id),
                                    isFocused: rowIndex == 2 + groupIndex && (filterOptionIndices[group.id] ?? 0) == optionIndex,
                                    action: { selectFilter(group, optionIndex) }
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private func resultsGrid(columns: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ControllerOverlaySectionTitle(viewModel.resultSummary.isEmpty ? "Results" : viewModel.resultSummary)
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: columns), spacing: 14) {
                    ForEach(Array(viewModel.catalogGames.enumerated()), id: \.element.catalogIdentity) { index, game in
                        ControllerCompactGameCard(
                            viewModel: viewModel,
                            game: game,
                            isFocused: rowIndex == 2 + viewModel.visibleFilterGroups.count && resultIndex == index,
                            action: { selectResult(game) }
                        )
                    }
                }
                .padding(.bottom, 12)
            }
        }
    }

    private var selectedSortIndex: Int {
        viewModel.sortOptions.firstIndex { $0.id == viewModel.selectedSortId } ?? 0
    }
}

private struct ControllerGameDetailOverlay: View {
    @ObservedObject var viewModel: CatalogViewModel
    let game: OPNCatalogGameObject
    let selectedActionIndex: Int
    let actions: [ControllerDetailAction]
    let glyphs: ControllerInputGlyphSet
    let perform: (ControllerDetailAction) -> Void
    let close: () -> Void

    private var selectedVariant: OPNCatalogGameVariantObject? { viewModel.selectedVariant(in: game) }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                CatalogRemoteImage(url: viewModel.optimizedImageURL(game.bestDetailImageURL, width: 1920), contentMode: .fill)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                Color.black.opacity(0.58)
                LinearGradient(colors: [.black.opacity(0.94), .black.opacity(0.64), .clear], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom)

                VStack(alignment: .leading, spacing: 18) {
                    ControllerOverlayHeader(title: game.title.isEmpty ? "Selected Game" : game.title, subtitle: detailSubtitle, glyphs: glyphs, close: close)
                    detailMetadata
                    Text(detailDescription)
                        .font(.nvidia(size: 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineSpacing(4)
                        .lineLimit(5)
                        .frame(maxWidth: 720, alignment: .leading)
                    detailRows
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                                Button { perform(action) } label: {
                                    HStack(spacing: 9) {
                                        Image(systemName: action.icon)
                                            .font(.nvidia(size: 14, weight: .bold))
                                        Text(action.title(game: game, selectedVariant: selectedVariant, viewModel: viewModel).uppercased())
                                            .font(.nvidia(size: 12, weight: .bold))
                                            .tracking(0.8)
                                    }
                                    .foregroundStyle(index == selectedActionIndex ? .black.opacity(0.88) : .white.opacity(0.86))
                                    .padding(.horizontal, 15)
                                    .frame(height: 44)
                                    .background(index == selectedActionIndex ? Color.openNowGreen : Color.white.opacity(0.09))
                                    .overlay { Rectangle().stroke(index == selectedActionIndex ? .white.opacity(0.86) : Color.white.opacity(0.14), lineWidth: index == selectedActionIndex ? 2 : 1) }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
                .padding(.leading, 60)
                .padding(.trailing, 52)
                .frame(width: min(proxy.size.width * 0.64, 900), alignment: .leading)
            }
        }
    }

    private var detailSubtitle: String {
        let store = selectedVariant?.appStoreLabel.isEmpty == false ? selectedVariant?.appStoreLabel ?? "" : game.primaryStoreLabel
        let ownership = game.isInLibrary || selectedVariant?.inLibrary == true || selectedVariant?.librarySelected == true ? "Owned" : "Ownership required"
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
        FlowLayout(spacing: 8) {
            if !game.ratingLabel.isEmpty { ControllerMetadataPill(text: game.ratingLabel) }
            if game.supportsGamepad { ControllerMetadataPill(text: "Gamepad") }
            if game.supportsKeyboard { ControllerMetadataPill(text: "Keyboard") }
            ForEach(Array(game.genres.prefix(3)), id: \.self) { genre in
                ControllerMetadataPill(text: genre)
            }
            if game.isLaunchPatching { ControllerMetadataPill(text: "Patching", highlighted: true) }
        }
        .frame(maxWidth: 720, alignment: .leading)
    }

    private var detailRows: some View {
        VStack(alignment: .leading, spacing: 8) {
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

private struct ControllerShowAllOverlay: View {
    @ObservedObject var viewModel: CatalogViewModel
    let section: CatalogSectionModel
    let selectedIndex: Int
    @Binding var columnCount: Int
    let glyphs: ControllerInputGlyphSet
    let select: (OPNCatalogGameObject) -> Void
    let close: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let columns = max(2, Int((proxy.size.width - 120) / 290))
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.90).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 18) {
                    ControllerOverlayHeader(title: section.title, subtitle: "\(section.games.count) games", glyphs: glyphs, close: close)
                    ScrollViewReader { scrollProxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: columns), spacing: 16) {
                                ForEach(Array(section.games.enumerated()), id: \.element.catalogIdentity) { index, game in
                                    ControllerCompactGameCard(viewModel: viewModel, game: game, isFocused: selectedIndex == index, action: { select(game) })
                                        .id(game.catalogIdentity)
                                }
                            }
                            .padding(.bottom, 18)
                        }
                        .onChange(of: selectedIndex) { _, index in
                            guard section.games.indices.contains(index) else { return }
                            withAnimation(.easeInOut(duration: 0.18)) {
                                scrollProxy.scrollTo(section.games[index].catalogIdentity, anchor: .center)
                            }
                        }
                    }
                }
                .padding(.horizontal, 54)
                .padding(.top, 38)
                .padding(.bottom, 32)
            }
            .onAppear { columnCount = columns }
            .onChange(of: columns) { _, value in columnCount = value }
        }
    }
}

private struct ControllerActionMenuOverlay: View {
    let items: [ControllerActionMenuItem]
    let selectedIndex: Int
    let glyphs: ControllerInputGlyphSet
    let perform: (ControllerActionMenuItem) -> Void
    let close: () -> Void

    var body: some View {
        ZStack(alignment: .trailing) {
            Color.black.opacity(0.58).ignoresSafeArea().onTapGesture(perform: close)
            VStack(alignment: .leading, spacing: 0) {
                ControllerOverlayHeader(title: "Controller Actions", subtitle: "Catalog navigation and account actions", glyphs: glyphs, close: close)
                    .padding(.horizontal, 22)
                    .padding(.top, 22)
                    .padding(.bottom, 12)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            Button { perform(item) } label: {
                                HStack(spacing: 13) {
                                    Image(systemName: item.icon)
                                        .font(.nvidia(size: 15, weight: .bold))
                                        .foregroundStyle(index == selectedIndex ? .black.opacity(0.86) : Color.openNowGreen)
                                        .frame(width: 28)
                                    Text(item.title)
                                        .font(.nvidia(size: 15, weight: .bold))
                                        .foregroundStyle(index == selectedIndex ? .black.opacity(0.88) : .white.opacity(0.88))
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 14)
                                .frame(height: 48)
                                .background(index == selectedIndex ? Color.openNowGreen : Color.white.opacity(0.055))
                                .overlay { Rectangle().stroke(index == selectedIndex ? .white.opacity(0.78) : Color.white.opacity(0.10), lineWidth: index == selectedIndex ? 2 : 1) }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 22)
                }
            }
            .frame(width: 420, alignment: .topLeading)
            .background(Color(red: 18 / 255, green: 18 / 255, blue: 18 / 255).opacity(0.98))
            .overlay(alignment: .leading) { Rectangle().fill(Color.openNowGreen).frame(width: 3) }
            .shadow(color: .black.opacity(0.54), radius: 34, x: -14, y: 20)
        }
    }
}

private struct ControllerOverlayHeader: View {
    let title: String
    let subtitle: String
    let glyphs: ControllerInputGlyphSet
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title.uppercased())
                    .font(.nvidia(size: 27, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.nvidia(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                ControllerGlyphPill(glyph: glyphs.back)
                Text("BACK")
                    .font(.nvidia(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.62))
            }
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.nvidia(size: 16, weight: .bold))
                    .foregroundStyle(.white.opacity(0.80))
                    .frame(width: 38, height: 38)
                    .background(Color.white.opacity(0.08))
                    .overlay { Rectangle().stroke(Color.white.opacity(0.14), lineWidth: 1) }
            }
            .buttonStyle(.plain)
        }
    }
}

private struct ControllerCompactGameCard: View {
    @ObservedObject var viewModel: CatalogViewModel
    let game: OPNCatalogGameObject
    let isFocused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                CatalogRemoteImage(url: viewModel.optimizedImageURL(game.bestWideImageURL, width: 520), contentMode: .fill)
                    .frame(height: 128)
                    .clipped()
                Text(game.title.isEmpty ? "GeForce NOW" : game.title)
                    .font(.nvidia(size: 14, weight: .bold))
                    .foregroundStyle(.white.opacity(0.94))
                    .lineLimit(1)
                Text(game.primaryStoreLabel.isEmpty ? (game.isInLibrary ? "In Library" : "Cloud ready") : game.primaryStoreLabel)
                    .font(.nvidia(size: 11, weight: .bold))
                    .foregroundStyle(Color.openNowGreen.opacity(0.84))
                    .lineLimit(1)
            }
            .padding(10)
            .background(Color.white.opacity(isFocused ? 0.12 : 0.055))
            .overlay { Rectangle().stroke(isFocused ? Color.openNowGreen : Color.white.opacity(0.10), lineWidth: isFocused ? 3 : 1) }
        }
        .buttonStyle(.plain)
    }
}

private struct ControllerOptionChip: View {
    let title: String
    let isSelected: Bool
    let isFocused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(.nvidia(size: 12, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(isSelected || isFocused ? .black.opacity(0.88) : .white.opacity(0.82))
                .padding(.horizontal, 13)
                .frame(height: 36)
                .background(isSelected || isFocused ? Color.openNowGreen : Color.white.opacity(0.075))
                .overlay { Rectangle().stroke(isFocused ? .white.opacity(0.82) : (isSelected ? Color.openNowGreen : Color.white.opacity(0.12)), lineWidth: isFocused ? 2 : 1) }
        }
        .buttonStyle(.plain)
    }
}

private struct ControllerOverlaySectionTitle: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.nvidia(size: 12, weight: .bold))
            .tracking(1.1)
            .foregroundStyle(Color.openNowGreen.opacity(0.86))
    }
}

private struct ControllerMetadataPill: View {
    let text: String
    var highlighted = false

    var body: some View {
        Text(text.uppercased())
            .font(.nvidia(size: 11, weight: .bold))
            .tracking(0.7)
            .foregroundStyle(highlighted ? .black.opacity(0.88) : .white.opacity(0.82))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(highlighted ? Color.openNowGreen : Color.white.opacity(0.10))
            .overlay { Rectangle().stroke(highlighted ? Color.openNowGreen : Color.white.opacity(0.14), lineWidth: 1) }
    }
}

private struct ControllerDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        if !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(label.uppercased())
                    .font(.nvidia(size: 10, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(.white.opacity(0.42))
                    .frame(width: 96, alignment: .leading)
                Text(value)
                    .font(.nvidia(size: 13, weight: .bold))
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

    var body: some View {
        HStack(spacing: 14) {
            ForEach(hints, id: \.self) { hint in
                ControllerHintItem(hint: hint, glyphs: glyphs)
            }
            Spacer(minLength: 0)
            Text(glyphs.usesControllerGlyphs ? "Controller mode" : "Keyboard fallback")
                .font(.nvidia(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.38))
                .tracking(0.8)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(width: layout.contentWidth, alignment: .leading)
        .frame(height: 46)
        .background(Color.black.opacity(0.36))
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
    }
}

private struct ControllerHintItem: View {
    let hint: ControllerHint
    let glyphs: ControllerInputGlyphSet

    var body: some View {
        HStack(spacing: 6) {
            if hint == .move, !glyphs.usesControllerGlyphs {
                ControllerKeyboardMovePill(glyphs: glyphs)
            } else {
                ForEach(Array(glyphSet.enumerated()), id: \.offset) { _, glyph in
                    ControllerGlyphPill(glyph: glyph, compact: hint == .move)
                }
            }
            Text(title)
                .font(.nvidia(size: 10, weight: .bold))
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

    var body: some View {
        HStack(spacing: compact ? 0 : 5) {
            if !glyph.symbolName.isEmpty {
                Image(systemName: glyph.symbolName)
                    .font(.nvidia(size: compact ? 11 : 12, weight: .bold))
            }
            if shouldShowText {
                Text(glyph.fallbackText)
                    .font(.nvidia(size: compact ? 0 : 9, weight: .bold))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(Color.openNowGreen)
        .padding(.horizontal, compact ? 6 : 7)
        .frame(minWidth: compact ? 25 : 0)
        .frame(height: 22)
        .background(Color.openNowGreen.opacity(0.12))
        .overlay { Rectangle().stroke(Color.openNowGreen.opacity(0.30), lineWidth: 1) }
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

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: glyphs.left.symbolName)
            Image(systemName: glyphs.up.symbolName)
            Image(systemName: glyphs.down.symbolName)
            Image(systemName: glyphs.right.symbolName)
        }
        .font(.nvidia(size: 11, weight: .bold))
        .foregroundStyle(Color.openNowGreen)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Color.openNowGreen.opacity(0.12))
        .overlay { Rectangle().stroke(Color.openNowGreen.opacity(0.30), lineWidth: 1) }
        .accessibilityLabel("Arrow keys")
    }
}

private struct ControllerCatalogBackground: View {
    @ObservedObject var viewModel: CatalogViewModel
    let game: OPNCatalogGameObject?

    var body: some View {
        ZStack {
            Color.gfnBackgroundGreen.ignoresSafeArea()
            if let game {
                CatalogRemoteImage(url: viewModel.optimizedImageURL(game.bestDetailImageURL, width: 1280), contentMode: .fill)
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
                guard !Self.isTextInputActive else { return event }
                guard let command = Self.command(for: event) else { return event }
                self.onCommand(command)
                return nil
            }
        }

        func removeMonitor() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        private static var isTextInputActive: Bool {
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
