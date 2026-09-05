import Combine
import Foundation

enum ControllerCatalogFocusArea {
    /// The window header above the navigation bar. Holds one control — the button back to desktop
    /// mode — so it has no selection index of its own.
    case header
    case navigation
    /// The search bar at the top of the catalog. Its own area rather than a rail, because it sits
    /// above the hero and has no game selection of its own.
    case search
    case content
}

enum ControllerNavigationItem: CaseIterable, Equatable, Identifiable {
    case home
    case library
    case favorites
    case search
    case recordings
    case settings
    case actions

    var id: String { title }

    var title: String {
        switch self {
        case .home: return "Home"
        case .library: return "Library"
        case .favorites: return "Favorites"
        case .search: return "Search"
        case .recordings: return "Recordings"
        case .settings: return "Settings"
        case .actions: return "Actions"
        }
    }

    var icon: String {
        switch self {
        case .home: return "gamecontroller.fill"
        case .library: return "rectangle.stack.fill"
        case .favorites: return "heart.fill"
        case .search: return "magnifyingglass"
        case .recordings: return "play.rectangle.fill"
        case .settings: return "gearshape.fill"
        case .actions: return "ellipsis.circle.fill"
        }
    }
}

/// What a focus move asks the view to do once the model has updated its own state. Rail and game
/// movement need the live catalog sections, which the model deliberately does not hold.
enum ControllerFocusEffect: Equatable {
    case none
    case moveRail(delta: Int)
    case moveGame(delta: Int)
}

/// The side effects controller mode needs that are not the catalog's: switching account, signing
/// out, and dropping back to desktop mode. Held rather than passed per call because the input
/// handlers are installed once, on appear, and fire from the controller thread afterwards.
@MainActor
struct ControllerCatalogHost {
    var accounts: [LoginAccount] = []
    var signedOutAccountEmails: Set<String> = []
    var onSwitch: (LoginAccount) -> Void = { _ in }
    var onAddAccount: () -> Void = {}
    var onSignOut: () -> Void = {}
    var onExitControllerMode: () -> Void = {}
}

@MainActor
final class ControllerCatalogViewModel: ObservableObject {
    /// The catalog this shell drives. Optional only because the view model is created by
    /// `@StateObject` before the view's `catalog` property is reachable; `bind` fills it in on
    /// appear and it is non-nil for the whole time input can arrive.
    private(set) var catalog: CatalogViewModel?
    private(set) var host = ControllerCatalogHost()

    /// Controller mode has no physical keyboard to assume, so catalog search reuses the stream's
    /// on-screen keyboard rather than leaving the field untypeable on a pad.
    let searchKeyboard = StreamOnScreenKeyboardModel()
    let inputRouter = ControllerInputRouter()
    let steamNavigator = GamepadUINavigator()

    @Published var isSearchKeyboardVisible = false
    @Published var searchPicker: ControllerSearchPicker?
    @Published var searchPickerIndex = 0
    @Published var embeddedPageCommand: ControllerPageCommand?

    @Published var focusArea = ControllerCatalogFocusArea.navigation
    @Published var selectedNavigationIndex = 0
    @Published var selectedRailIndex = 0
    @Published var selectedGameIndices: [String: Int] = [:]
    @Published var isActionMenuVisible = false
    @Published var actionMenuIndex = 0
    @Published var isSearchVisible = false
    @Published var searchRowIndex = 0
    @Published var searchFilterOptionIndices: [String: Int] = [:]
    @Published var searchResultIndex = 0
    @Published var isDetailVisible = false
    @Published var detailActionIndex = 0

    // Library and Favorites are no longer standalone destinations — they are reached from the
    // Home rails' Show All (revamped, filterable catalog view), so they are omitted from the nav.
    /// Search is deliberately absent: it is an overlay raised by the dedicated search button (and
    /// hinted as such in the hint bar), not a place you land on. Listing it as a destination meant
    /// the bar had to claim something was "active" while an overlay was up, and paging with LB/RB
    /// stepped onto a screen that immediately covered the bar it came from.
    let navigationItems: [ControllerNavigationItem] = [.home, .recordings, .settings, .actions]

    var hasControllerOverlay: Bool {
        isActionMenuVisible || isSearchVisible || isDetailVisible
    }

    func selectedGameIndex(for section: CatalogSectionModel, gameCount: Int) -> Int {
        guard gameCount > 0 else { return 0 }
        return min(max(selectedGameIndices[section.id] ?? 0, 0), gameCount - 1)
    }

    func setSelectedGameIndex(_ index: Int, for section: CatalogSectionModel, gameCount: Int) {
        guard gameCount > 0 else {
            selectedGameIndices[section.id] = 0
            return
        }
        selectedGameIndices[section.id] = min(max(index, 0), gameCount - 1)
    }

    /// The focus state machine for the catalog shell. Pure apart from its own published state, so
    /// the routing can be exercised without a live view.
    func moveFocus(_ direction: ControllerInputDirection, navigationItemCount: Int) -> ControllerFocusEffect {
        switch focusArea {
        case .header: moveHeaderFocus(direction)
        case .navigation: moveNavigationFocus(direction, itemCount: navigationItemCount)
        case .search: moveSearchFocus(direction)
        case .content: moveContentFocus(direction)
        }
    }

    private func moveHeaderFocus(_ direction: ControllerInputDirection) -> ControllerFocusEffect {
        if direction == .down { focusArea = .navigation }
        return .none
    }

    private func moveNavigationFocus(_ direction: ControllerInputDirection, itemCount: Int) -> ControllerFocusEffect {
        switch direction {
        case .left: selectedNavigationIndex = max(selectedNavigationIndex - 1, 0)
        case .right: selectedNavigationIndex = min(selectedNavigationIndex + 1, max(itemCount - 1, 0))
        case .down: focusArea = .search
        case .up: focusArea = .header
        }
        return .none
    }

    private func moveSearchFocus(_ direction: ControllerInputDirection) -> ControllerFocusEffect {
        switch direction {
        case .up: focusArea = .navigation
        case .down: focusArea = .content
        case .left, .right: break
        }
        return .none
    }

    /// The top row of the content area is the only one that hands focus back up to the search bar;
    /// everywhere else `up` moves between rails.
    private func moveContentFocus(_ direction: ControllerInputDirection) -> ControllerFocusEffect {
        switch direction {
        case .left: return .moveGame(delta: -1)
        case .right: return .moveGame(delta: 1)
        case .up:
            guard selectedRailIndex == 0 else { return .moveRail(delta: -1) }
            focusArea = .search
            return .none
        case .down: return .moveRail(delta: 1)
        }
    }

    func moveRail(delta: Int, sectionCount: Int) {
        guard sectionCount > 0 else { return }
        selectedRailIndex = min(max(selectedRailIndex + delta, 0), sectionCount - 1)
    }

    func moveActionMenuIndex(delta: Int, itemCount: Int) {
        actionMenuIndex = min(max(actionMenuIndex + delta, 0), max(itemCount - 1, 0))
    }

    func moveSearchRowIndex(delta: Int, rowCount: Int) {
        searchRowIndex = min(max(searchRowIndex + delta, 0), max(rowCount - 1, 0))
    }

    func moveDetailActionIndex(delta: Int, actionCount: Int) {
        detailActionIndex = min(max(detailActionIndex + delta, 0), max(actionCount - 1, 0))
    }

    func clampRailSelection(sectionCount: Int) {
        selectedRailIndex = min(max(selectedRailIndex, 0), max(sectionCount - 1, 0))
    }

    // MARK: - Binding

    /// Called from the view's `onAppear`. Binding once, rather than on every render, is deliberate
    /// and matches what the view did before: the input handlers were installed in `onAppear` and
    /// captured the view struct as it was at that moment, accounts and callbacks included.
    func bind(catalog: CatalogViewModel, host: ControllerCatalogHost) {
        self.catalog = catalog
        self.host = host
        configureSearchKeyboard()
        inputRouter.onCommand = { [weak self] command in self?.handleInput(command) }
        steamNavigator.onCommand = { [weak self] command in self?.handleInput(command) }
        steamNavigator.start(capturingInput: true)
    }

    func unbind() {
        inputRouter.onCommand = nil
        steamNavigator.onCommand = nil
        steamNavigator.stop()
    }

    var activeGlyphs: ControllerInputGlyphSet {
        inputRouter.isControllerConnected ? inputRouter.glyphs : steamNavigator.glyphs
    }

    // MARK: - Derived catalog state

    var isSearchOverlayPresented: Bool {
        isSearchVisible || catalog?.selectedShowAllSection != nil
    }

    var hasModalOverlay: Bool {
        hasControllerOverlay
            || catalog?.selectedShowAllSection != nil
            || catalog?.isLaunchFlowVisible == true
            || catalog?.isStorePickerVisible == true
            || catalog?.isGameInfoVisible == true
    }

    /// Search is not in the bar, so while its overlay is up the bar keeps highlighting the
    /// destination underneath - which is also the one LB/RB pages away from.
    var activeNavigationItem: ControllerNavigationItem {
        guard let catalog else { return .home }
        if catalog.selectedMainPage == .recordings { return .recordings }
        if catalog.selectedMainPage == .settings { return .settings }
        switch catalog.selectedCatalogDestination {
        case .home: return .home
        case .library: return .library
        case .favorites: return .favorites
        }
    }

    var focusedHeroGame: OPNCatalogGameObject? {
        guard let catalog else { return nil }
        if isDetailVisible, let selectedGame = catalog.selectedGame { return selectedGame }
        let sections = catalog.catalogSections
        if sections.indices.contains(selectedRailIndex) {
            let section = sections[selectedRailIndex]
            if let firstGame = section.visibleGames(expanded: false).first { return firstGame }
        }
        return catalog.heroRotationGames.first ?? sections.flatMap(\.games).first
    }

    /// Destinations LB/RB step through, in nav-bar order. `.actions` opens a menu rather than
    /// going anywhere, so it is not a stop on the way.
    var pageableNavigationItems: [ControllerNavigationItem] {
        navigationItems.filter { $0 != .actions }
    }

    var currentSection: CatalogSectionModel? {
        guard let catalog else { return nil }
        let sections = catalog.catalogSections
        guard sections.indices.contains(selectedRailIndex) else { return nil }
        return sections[selectedRailIndex]
    }

    var searchRowCount: Int {
        guard let catalog else { return 2 }
        return 2 + (catalog.catalogGames.isEmpty ? 0 : 1)
    }

    var actionMenuItems: [ControllerActionMenuItem] {
        guard let catalog else { return [] }
        var items: [ControllerActionMenuItem] = [.refresh]
        if catalog.isBrowseMode { items.append(.clearSearch) }
        items.append(contentsOf: [.home, .recordings, .desktopMode, .settings])
        for account in host.accounts where account.id != catalog.account.id {
            items.append(.switchAccount(account, needsSignIn: host.signedOutAccountEmails.contains(account.email)))
        }
        items.append(.addAccount)
        items.append(.signOut)
        return items
    }

    func detailActions(for game: OPNCatalogGameObject) -> [ControllerDetailAction] {
        var actions: [ControllerDetailAction] = [.primary, .favorite]
        if game.variants.count > 1 { actions.append(.store) }
        if catalog?.selectedVariant(in: game) != nil { actions.append(.ownership) }
        actions.append(contentsOf: [.share, .shortcut, .visitStore, .close])
        return actions
    }
}

