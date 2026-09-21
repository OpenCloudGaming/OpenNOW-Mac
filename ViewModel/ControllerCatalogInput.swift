//  Controller-mode input routing and the actions it can trigger. This is the whole of what a
//  D-pad, A/B, LB/RB and the menu buttons do in the catalog, moved out of `ControllerCatalogView`
//  so it can be exercised without a rendered catalog.
//
//  Animation is deliberately absent: opening and closing the on-screen keyboard used to be wrapped
//  in `withAnimation` here. The view now animates on the published value instead, which keeps
//  SwiftUI out of the view model without changing what the user sees.
//

import Foundation

@MainActor
extension ControllerCatalogViewModel {

    // MARK: - Routing

    func handleInput(_ command: ControllerInputCommand) {
        if handleSharedOverlayInput(command) { return }
        if isActionMenuVisible { handleActionMenuInput(command); return }
        if isSearchVisible || catalog?.selectedShowAllSection != nil { handleSearchInput(command); return }
        if isDetailVisible { handleDetailInput(command); return }
        handlePageInput(command)
    }

    /// Overlays that sit above every page and swallow input wherever you were. Returns whether the
    /// command was consumed.
    private func handleSharedOverlayInput(_ command: ControllerInputCommand) -> Bool {
        guard let catalog else { return false }

        if catalog.isCollectionsNoticePresented {
            if command == .confirm || command == .back { catalog.dismissCollectionsLocalOnlyNotice() }
            return true
        }
        if isCollectionPickerVisible { handleCollectionPickerInput(command); return true }
        if catalog.isLaunchFlowVisible { return handleLaunchFlowInput(command, catalog: catalog) }
        if catalog.isStorePickerVisible { return handleStorePickerInput(command, catalog: catalog) }
        if catalog.isGameInfoVisible { return handleGameInfoInput(command, catalog: catalog) }
        return false
    }

    /// The launch flow swallows everything except its own confirm and cancel.
    private func handleLaunchFlowInput(_ command: ControllerInputCommand, catalog: CatalogViewModel) -> Bool {
        switch command {
        case .back:
            catalog.cancelVendorLaunch()
            return true
        case .confirm:
            guard catalog.launchFlowState == .activeSessionPrompt else { return false }
            if catalog.canResumeActiveLaunchSession {
                catalog.resumeActiveLaunchSession()
            } else {
                catalog.switchToSelectedGame()
            }
            return true
        default:
            return true
        }
    }

    /// The info page is a reading surface: there is nothing on it to move between, so the pad only
    /// dismisses it. Everything else is swallowed rather than driving the rails behind it.
    private func handleGameInfoInput(_ command: ControllerInputCommand, catalog: CatalogViewModel) -> Bool {
        switch command {
        case .back, .confirm:
            catalog.closeGameInfo()
        default:
            break
        }
        return true
    }

    /// The store picker owns the whole d-pad while it is up.
    private func handleStorePickerInput(_ command: ControllerInputCommand, catalog: CatalogViewModel) -> Bool {
        switch command {
        case .back:
            catalog.closeStorePicker()
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

    private func handlePageInput(_ command: ControllerInputCommand) {
        guard let catalog else { return }
        // Recordings and Settings embed desktop views that have no controller focus model of their
        // own. Routing d-pad moves into `moveFocus` there silently drove the games rails behind the
        // page - the catalog visibly changed underneath while nothing on screen responded - so
        // those pages keep focus in the navigation bar and only accept page switching and Back.
        guard catalog.selectedMainPage == .games else {
            handleEmbeddedPageInput(command)
            return
        }
        switch command {
        case .move(let direction):
            moveFocus(direction)
        case .confirm:
            confirmFocusedItem()
        case .back:
            if catalog.selectedMainPage != .games || catalog.selectedCatalogDestination != .home {
                catalog.showCatalogDestination(.home)
                focusArea = .content
            }
        case .search:
            openSearchOverlay()
        case .actions:
            if focusArea == .content, let section = currentSection {
                openShowAll(section)
            } else {
                openActionMenu()
            }
        case .menu:
            openActionMenu()
        case .pageLeft:
            cycleNavigation(delta: -1)
        case .pageRight:
            cycleNavigation(delta: 1)
        }
    }

    private func handleEmbeddedPageInput(_ command: ControllerInputCommand) {
        switch command {
        case .move, .confirm:
            // The page owns its own selection, so the command goes to it rather than being
            // interpreted here. LB/RB stay with the shell for switching destination.
            embeddedPageCommand = ControllerPageCommand(command: command, sequence: (embeddedPageCommand?.sequence ?? 0) + 1)
        case .back:
            catalog?.showCatalogDestination(.home)
            focusArea = .content
        case .search:
            openSearchOverlay()
        case .actions, .menu:
            openActionMenu()
        case .pageLeft:
            cycleNavigation(delta: -1)
        case .pageRight:
            cycleNavigation(delta: 1)
        }
    }

    private func handleActionMenuInput(_ command: ControllerInputCommand) {
        if isAccountOptionsVisible {
            handleAccountOptionsInput(command)
            return
        }
        let items = actionMenuItems
        switch command {
        case .move(.up): moveActionMenuIndex(delta: -1, itemCount: items.count)
        case .move(.down): moveActionMenuIndex(delta: 1, itemCount: items.count)
        case .confirm:
            guard items.indices.contains(actionMenuIndex) else { return }
            executeActionMenuItem(items[actionMenuIndex])
        case .back, .menu, .actions: closeActionMenu()
        // The secondary action: with an `.account` row focused, X opens that account's options
        // rather than doing nothing, which is all this command did in the action menu before.
        case .search:
            guard items.indices.contains(actionMenuIndex), case .account(let account, _, _) = items[actionMenuIndex] else { return }
            openAccountOptions(for: account)
        default: break
        }
    }

    private func handleSearchInput(_ command: ControllerInputCommand) {
        if handlesSearchOverlayModal(command) { return }
        switch command {
        case .move(.up): moveSearchRowIndex(delta: -1, rowCount: searchRowCount)
        case .move(.down): moveSearchRowIndex(delta: 1, rowCount: searchRowCount)
        case .move(.left): moveSearchSelection(delta: -1)
        case .move(.right): moveSearchSelection(delta: 1)
        case .confirm: confirmSearchSelection()
        case .actions:
            catalog?.clearSearch()
            catalog?.clearFilters()
            catalog?.browseCatalog()
        case .back, .search: closeSearchOverlay()
        case .pageLeft: cycleNavigation(delta: -1)
        case .pageRight: cycleNavigation(delta: 1)
        default: break
        }
    }

    /// The search overlay's layered modals: a local collection page, the sort/filter picker, and
    /// the on-screen keyboard. Returns whether one of them consumed the command.
    private func handlesSearchOverlayModal(_ command: ControllerInputCommand) -> Bool {
        if catalog?.isShowingLocalCollection == true {
            handleLocalCollectionInput(command)
            return true
        }
        if searchPicker != nil {
            handleSearchPickerInput(command)
            return true
        }
        if isSearchKeyboardVisible {
            handleSearchKeyboardInput(command)
            return true
        }
        return false
    }

    /// The pad's route through a collection's page. There is no search field or filter bar here:
    /// a collection is local data, so there is nothing on the server to filter it by.
    private func handleLocalCollectionInput(_ command: ControllerInputCommand) {
        guard let catalog else { return }
        switch command {
        case .move(.left): moveSearchSelection(delta: -1)
        case .move(.right): moveSearchSelection(delta: 1)
        case .confirm:
            if catalog.displayedShowAllGames.indices.contains(searchResultIndex) {
                openDetails(catalog.displayedShowAllGames[searchResultIndex], sectionId: catalog.selectedShowAllSection?.id ?? "catalog-results")
            }
        case .back, .search: closeSearchOverlay()
        case .pageLeft: cycleNavigation(delta: -1)
        case .pageRight: cycleNavigation(delta: 1)
        default: break
        }
    }

    private func handleSearchKeyboardInput(_ command: ControllerInputCommand) {
        switch command {
        case .move(.up): searchKeyboard.handleNavigationAction(.move(dx: 0, dy: -1))
        case .move(.down): searchKeyboard.handleNavigationAction(.move(dx: 0, dy: 1))
        case .move(.left): searchKeyboard.handleNavigationAction(.move(dx: -1, dy: 0))
        case .move(.right): searchKeyboard.handleNavigationAction(.move(dx: 1, dy: 0))
        case .confirm: searchKeyboard.handleNavigationAction(.activate)
        case .actions: searchKeyboard.handleNavigationAction(.backspace)
        case .pageLeft: searchKeyboard.handleNavigationAction(.shift)
        case .pageRight: searchKeyboard.handleNavigationAction(.space)
        case .back, .search, .menu: closeSearchKeyboard()
        }
    }

    private func handleDetailInput(_ command: ControllerInputCommand) {
        guard let game = catalog?.selectedGame else { return }
        if isDetailLightboxVisible { handleDetailLightboxInput(command, game: game); return }
        if isDetailMoreMenuVisible { handleDetailMoreInput(command, game: game); return }
        let pages = detailPages(for: game)
        switch command {
        case .move(let direction): handleDetailMove(direction, game: game)
        case .confirm: confirmDetailSelection(actions: detailActions(for: game), game: game)
        case .back: closeDetails()
        case .search: openSearchOverlay()
        // Y opens the game's own secondary actions here, not the catalog-wide menu: on this page
        // that is what "more" means.
        case .actions, .menu: openDetailMoreMenu(for: game)
        case .pageLeft: showDetailPage(detailPage.stepped(by: -1, in: pages))
        case .pageRight: showDetailPage(detailPage.stepped(by: 1, in: pages))
        }
    }

    // MARK: - Focus movement

    private func moveFocus(_ direction: ControllerInputDirection) {
        switch moveFocus(direction, navigationItemCount: navigationItems.count) {
        case .none: break
        case .moveRail(let delta): moveRail(delta: delta)
        case .moveGame(let delta): moveGame(delta: delta)
        }
    }

    private func confirmFocusedItem() {
        if focusArea == .header {
            host.onExitControllerMode()
            return
        }
        if focusArea == .search {
            openSearchOverlay()
            return
        }
        if focusArea == .navigation {
            guard navigationItems.indices.contains(selectedNavigationIndex) else { return }
            selectNavigationItem(navigationItems[selectedNavigationIndex])
            return
        }
        guard let section = currentSection else { return }
        let games = section.visibleGames(expanded: false)
        let index = selectedGameIndex(for: section, gameCount: games.count)
        guard games.indices.contains(index) else { return }
        openDetails(games[index], sectionId: section.id)
    }

    func cycleNavigation(delta: Int) {
        let items = pageableNavigationItems
        guard !items.isEmpty else { return }
        let current = items.firstIndex(of: activeNavigationItem) ?? 0
        let next = min(max(current + delta, 0), items.count - 1)
        guard next != current else { return }
        let target = items[next]
        // Paging off the search overlay has to dismiss it; selecting a destination alone would
        // change the page underneath and leave the overlay covering it.
        if isSearchVisible {
            closeSearchOverlay()
        }
        selectNavigationItem(target)
    }

    func selectNavigationItem(_ item: ControllerNavigationItem) {
        guard let catalog else { return }
        selectedNavigationIndex = navigationItems.firstIndex(of: item) ?? selectedNavigationIndex
        switch item {
        case .home:
            catalog.showCatalogDestination(.home)
            focusArea = .content
        case .library:
            catalog.showCatalogDestination(.library)
            focusArea = .content
        case .favorites:
            catalog.showCatalogDestination(.favorites)
            focusArea = .content
        case .search:
            openSearchOverlay()
        case .recordings:
            catalog.showRecordings()
            focusArea = .navigation
        case .screenshots:
            catalog.showScreenshots()
            focusArea = .navigation
        case .settings:
            catalog.showSettings(.input)
            focusArea = .navigation
        case .actions:
            openActionMenu()
        }
    }

    private func moveRail(delta: Int) {
        moveRail(delta: delta, sectionCount: catalog?.catalogSections.count ?? 0)
    }

    private func moveGame(delta: Int) {
        guard let section = currentSection else { return }
        let gameCount = section.visibleGames(expanded: false).count
        guard gameCount > 0 else { return }
        let index = selectedGameIndex(for: section, gameCount: gameCount)
        setSelectedGameIndex(index + delta, for: section, gameCount: gameCount)
    }

    func synchronizeNavigationSelection() {
        selectedNavigationIndex = navigationItems.firstIndex(of: activeNavigationItem) ?? 0
        clampRailSelection(sectionCount: catalog?.catalogSections.count ?? 0)
    }

    // MARK: - Detail panel

    func openDetails(_ game: OPNCatalogGameObject, sectionId: String) {
        catalog?.selectGame(game, inSection: sectionId)
        detailActionIndex = 0
        detailPage = .about
        detailFocusRow = .actions
        detailScreenshotIndex = 0
        isDetailLightboxVisible = false
        detailMoreActionIndex = 0
        isDetailMoreMenuVisible = false
        isDetailVisible = true
        isSearchVisible = false
    }

    func closeDetails() {
        isDetailVisible = false
        isDetailLightboxVisible = false
        isDetailMoreMenuVisible = false
        catalog?.selectGame(nil)
    }

    private func handleDetailMoreInput(_ command: ControllerInputCommand, game: OPNCatalogGameObject) {
        let actions = detailMoreActions(for: game)
        switch command {
        case .move(.up), .move(.left):
            detailMoreActionIndex = max(detailMoreActionIndex - 1, 0)
        case .move(.down), .move(.right):
            detailMoreActionIndex = min(detailMoreActionIndex + 1, max(actions.count - 1, 0))
        case .confirm:
            guard actions.indices.contains(detailMoreActionIndex) else { return }
            let action = actions[detailMoreActionIndex]
            closeDetailMoreMenu()
            executeDetailAction(action)
        case .back, .actions, .menu:
            closeDetailMoreMenu()
        default:
            break
        }
    }

    private func handleDetailMove(_ direction: ControllerInputDirection, game: OPNCatalogGameObject) {
        switch direction {
        case .up: focusDetailRow(.actions)
        case .down: focusDetailRow(.content, game: game)
        case .left: moveWithinDetailRow(delta: -1, actions: detailActions(for: game), game: game)
        case .right: moveWithinDetailRow(delta: 1, actions: detailActions(for: game), game: game)
        }
    }

    /// The strip is the only focusable content row, so `down` is inert everywhere else rather than
    /// moving focus somewhere the page cannot draw it.
    private func focusDetailRow(_ row: ControllerGameDetailFocusRow, game: OPNCatalogGameObject? = nil) {
        guard row == .content else {
            detailFocusRow = .actions
            return
        }
        guard let game, detailPage == .screenshots, !detailScreenshots(for: game).isEmpty else { return }
        detailFocusRow = .content
    }

    private func moveWithinDetailRow(delta: Int, actions: [ControllerDetailAction], game: OPNCatalogGameObject) {
        guard detailFocusRow == .content else {
            moveDetailActionIndex(delta: delta, actionCount: actions.count)
            return
        }
        let screenshots = detailScreenshots(for: game)
        guard !screenshots.isEmpty else { return }
        detailScreenshotIndex = min(max(detailScreenshotIndex + delta, 0), screenshots.count - 1)
    }

    private func confirmDetailSelection(actions: [ControllerDetailAction], game: OPNCatalogGameObject) {
        guard detailFocusRow == .content else {
            guard actions.indices.contains(detailActionIndex) else { return }
            executeDetailAction(actions[detailActionIndex])
            return
        }
        guard !detailScreenshots(for: game).isEmpty else { return }
        isDetailLightboxVisible = true
    }

    private func handleDetailLightboxInput(_ command: ControllerInputCommand, game: OPNCatalogGameObject) {
        let screenshots = detailScreenshots(for: game)
        switch command {
        case .move(.left): detailScreenshotIndex = max(detailScreenshotIndex - 1, 0)
        case .move(.right): detailScreenshotIndex = min(detailScreenshotIndex + 1, max(screenshots.count - 1, 0))
        case .back, .confirm: closeDetailLightbox()
        default: break
        }
    }

    func showDetailPage(_ page: ControllerGameDetailPage) {
        detailPage = page
        detailFocusRow = .actions
        detailScreenshotIndex = 0
    }

    func closeDetailLightbox() {
        isDetailLightboxVisible = false
    }

    func openDetailMoreMenu(for game: OPNCatalogGameObject) {
        guard !detailMoreActions(for: game).isEmpty else { return }
        detailMoreActionIndex = 0
        isDetailMoreMenuVisible = true
    }

    func closeDetailMoreMenu() {
        isDetailMoreMenuVisible = false
    }

    func executeDetailAction(_ action: ControllerDetailAction) {
        guard let catalog, let game = catalog.selectedGame else { return }
        let selectedVariant = catalog.selectedVariant(in: game)
        switch action {
        case .primary:
            handleDetailPrimary(catalog: catalog, game: game, selectedVariant: selectedVariant)
        case .favorite:
            catalog.toggleFavoriteSelectedGame()
        case .collections:
            openCollectionPicker(game: game)
        case .store:
            catalog.changeSelectedGameStore()
        case .ownership:
            if selectedVariant.map({ CatalogViewModel.variantIsOwned($0, in: game) }) == true {
                catalog.removeSelectedVariantOwned()
            } else {
                catalog.markSelectedVariantOwned()
            }
        case .share:
            catalog.shareSelectedGame()
        case .shortcut:
            catalog.addShortcutForSelectedGame()
        case .visitStore:
            catalog.openStoreForSelectedVariant()
        case .more:
            openDetailMoreMenu(for: game)
        }
    }

    private func handleDetailPrimary(catalog: CatalogViewModel, game: OPNCatalogGameObject, selectedVariant: OPNCatalogGameVariantObject?) {
        if game.isLaunchPatching || selectedVariant?.isPatching == true {
            catalog.queuePatchingLaunch(game: game, variantIndex: catalog.selectedVariantIndex)
        } else if catalog.selectedPlatformHasAccess(in: game) || selectedVariant == nil {
            catalog.launchSelectedGame()
        } else {
            catalog.handleUnownedSelectedVariantPrimaryAction()
        }
    }

    // MARK: - Search overlay

    /// Captures the catalog rather than the view: these handlers outlive every render, so holding a
    /// view would pin a stale copy of its whole scope - accounts, callbacks and all.
    func configureSearchKeyboard() {
        searchKeyboard.onOutput = { [weak self] output in
            guard let self, let catalog = self.catalog else { return }
            switch output {
            case .text(let text):
                catalog.searchQuery.append(text)
            case .keyPress(let keyCode):
                switch keyCode {
                case 51: // backspace
                    guard !catalog.searchQuery.isEmpty else { return }
                    catalog.searchQuery.removeLast()
                case 36, 76: // return / enter
                    catalog.browseCatalog()
                    self.isSearchKeyboardVisible = false
                default:
                    break
                }
            }
        }
        searchKeyboard.onDismiss = { [weak self] in
            self?.isSearchKeyboardVisible = false
        }
    }

    private func openSearchKeyboard() {
        searchKeyboard.reset()
        configureSearchKeyboard()
        isSearchKeyboardVisible = true
    }

    private func closeSearchKeyboard() {
        isSearchKeyboardVisible = false
    }

    func openSearchOverlay() {
        guard let catalog else { return }
        isSearchVisible = true
        isActionMenuVisible = false
        searchRowIndex = min(searchRowIndex, max(searchRowCount - 1, 0))
        // Closing search clears `catalogGames`, so a reopen needs the browse even once the filter
        // and sort definitions are already in hand - otherwise the results grid comes back empty
        // and only fills in once something is typed.
        if catalog.catalogGames.isEmpty || catalog.sortOptions.isEmpty || catalog.filterGroups.isEmpty {
            catalog.browseCatalog()
        }
    }

    func closeSearchOverlay() {
        isSearchVisible = false
        isSearchKeyboardVisible = false
        catalog?.closeShowAll()
    }

    func openShowAll(_ section: CatalogSectionModel) {
        guard let catalog else { return }
        catalog.openShowAll(section)
        isSearchVisible = true
        searchRowIndex = catalog.isShowingLocalCollection ? 2 : 0
        searchResultIndex = 0
        for group in catalog.visibleFilterGroups {
            if let index = group.options.firstIndex(where: { catalog.selectedFilterIds.contains($0.id) }) {
                searchFilterOptionIndices[group.id] = index
            } else {
                searchFilterOptionIndices[group.id] = 0
            }
        }
    }

    private func moveSearchSelection(delta: Int) {
        guard let catalog else { return }
        if searchRowIndex == 1 {
            let chipCount = ControllerSearchBar.count(groupCount: catalog.visibleFilterGroups.count, hasClear: catalog.selectedFilterCount > 0)
            let currentChip = searchFilterOptionIndices[ControllerSearchBar.indexKey] ?? 0
            let next = min(max(currentChip + delta, 0), chipCount - 1)
            searchFilterOptionIndices[ControllerSearchBar.indexKey] = next
            return
        }
        if searchRowIndex == 2, !catalog.displayedShowAllGames.isEmpty {
            searchResultIndex = min(max(searchResultIndex + delta, 0), catalog.displayedShowAllGames.count - 1)
        }
    }

    private func confirmSearchSelection() {
        guard let catalog else { return }
        if searchRowIndex == 0 {
            openSearchKeyboard()
            return
        }
        if searchRowIndex == 1 {
            let chipIndex = searchFilterOptionIndices[ControllerSearchBar.indexKey] ?? 0
            if chipIndex == ControllerSearchBar.sortIndex {
                openSortPicker()
            } else if chipIndex <= catalog.visibleFilterGroups.count {
                openFilterPicker(group: catalog.visibleFilterGroups[chipIndex - 1])
            } else {
                catalog.clearSearch()
                catalog.clearFilters()
                catalog.browseCatalog()
            }
            return
        }
        if searchRowIndex == 2, catalog.displayedShowAllGames.indices.contains(searchResultIndex) {
            openDetails(catalog.displayedShowAllGames[searchResultIndex], sectionId: "catalog-results")
        }
    }

    // MARK: - Actions menu

    func openActionMenu() {
        actionMenuIndex = min(actionMenuIndex, max(actionMenuItems.count - 1, 0))
        isActionMenuVisible = true
    }

    func closeActionMenu() {
        isActionMenuVisible = false
        closeAccountOptions()
    }

    func executeActionMenuItem(_ item: ControllerActionMenuItem) {
        guard let catalog else { return }
        if !item.isRefresh { closeActionMenu() }
        switch item {
        case .refresh:
            guard !catalog.isCatalogRefreshInProgress else { return }
            catalog.refresh()
        case .clearSearch:
            catalog.clearSearch()
            catalog.clearFilters()
            catalog.browseCatalog()
        case .recordings:
            catalog.showRecordings()
        case .screenshots:
            catalog.showScreenshots()
        case .settings:
            catalog.showSettings(.input)
        case .home, .library, .favorites, .userCollection:
            performNavigationItem(item, catalog: catalog)
        case .desktopMode, .account, .addAccount:
            handleActionMenuHostItem(item)
        }
    }


    /// Runs a navigation row. A user collection is a local page, so it never routes through
    /// `CatalogDestination`; the three server destinations keep sharing `destination(for:)`.
    private func performNavigationItem(_ item: ControllerActionMenuItem, catalog: CatalogViewModel) {
        if case .userCollection(let id, _) = item {
            catalog.openUserCollection(id: id)
            focusArea = .content
            return
        }
        catalog.showCatalogDestination(Self.destination(for: item))
    }

    /// The catalog destination each navigation menu item selects. `home` is the only item the
    /// caller routes here besides these two, so anything else is a caller mistake.
    private static func destination(for item: ControllerActionMenuItem) -> CatalogDestination {
        switch item {
        case .library: return .library
        case .favorites: return .favorites
        case .home: return .home
        default:
            assertionFailure("destination(for:) called with a non-navigation item")
            return .home
        }
    }

    // MARK: - Store picker

    private func moveSelectedStore(delta: Int) {
        guard let catalog, let game = catalog.selectedGame else { return }
        let options = catalog.platformOptions(for: game)
        guard options.count > 1 else { return }
        let currentOption = catalog.selectedPlatformOption(in: game)
        let currentOptionIndex = options.firstIndex { $0.id == currentOption?.id } ?? 0
        let nextOptionIndex = min(max(currentOptionIndex + delta, 0), options.count - 1)
        catalog.focusGameStoreOption(options[nextOptionIndex])
    }

    private func confirmStorePickerStage() {
        guard let catalog else { return }
        switch catalog.ownershipFlowStage {
        case .storeSelection, .none:
            guard let option = catalog.selectedPlatformOption(in: catalog.selectedGame) else { return }
            catalog.selectGameStoreOption(option)
        case .manualMark:
            catalog.confirmSelectedVariantOwned()
        case .success:
            catalog.finishOwnershipFlow()
        case .resyncing:
            break
        }
    }
}
