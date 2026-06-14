import AppKit
import Backend
import GameController
import SwiftUI

@objcMembers
@objc(OPNGameCatalogView)
@MainActor
final class OPNGameCatalogView: NSView {
    var onSelectGame: ((OPNCatalogGameObject, Int32) -> Void)?
    var onBuyGame: ((OPNCatalogGameObject, Int32, String) -> Void)?
    var onMarkGameUnowned: ((OPNCatalogGameObject, Int32) -> Void)?
    var onSignOut: (() -> Void)?
    var onGameCountChanged: ((Int) -> Void)?
    var onCatalogBrowseRequested: ((String, String, [String]) -> Void)?
    var onInterfaceSettingsRequested: (() -> Void)?
    var onStoreRequested: (() -> Void)?
    var onRestartRequested: (() -> Void)?
    var onExitRequested: (() -> Void)?
    var onBackRequested: (() -> Void)?

    let catalogModel: OPNGameCatalogModel
    private var hostingView: NSHostingView<OPNGameCatalogSwiftUIView>?

    var scrollView: NSScrollView
    var documentView: OPNStoreDocumentView
    var loadingView: OPNLoadingView
    var statusLabel: NSTextField
    var buttonHintPillView: OPNStoreHintPillView
    var buttonHintStackView: NSStackView
    var searchPanelView: NSView
    var searchField: NSSearchField
    var searchQuery = ""
    var completedSearchQuery = ""
    var searchGeneration = 0
    var searchInFlight = false
    var searchDebounceTimer: Timer?
    let searchQueue = DispatchQueue(label: "io.opencg.opennow.catalog-search")

    var rowCards = NSMutableArray()
    var rowLayouts = NSMutableArray()
    var heroImageLoadTokens = NSMutableArray()
    var prefetchImageLoadTokens = NSMutableArray()
    var heroRotationTimer: Timer?
    var desktopFeaturedHeroViews = NSMutableArray()
    var desktopHeroContainer: NSView?
    var desktopHeroArtworkView: OPNHeroArtworkView?
    var desktopHeroArtworkTransitionView: OPNHeroArtworkView?
    var desktopHeroTitleFallback: NSTextField?
    var desktopHeroLogoView: NSImageView?
    var desktopHeroLogoTransitionView: NSImageView?
    var desktopHeroIdentity: String?
    var desktopHeroGeneration = 0
    var initialHeroImage: NSImage?
    var initialHeroIdentity: String?
    var desktopFeaturedHeroFrame = NSRect.zero
    var currentHeroIndex = 0
    var focusedRowIndex = 0
    var focusedColumnIndex = 0
    weak var focusedTile: OPNStoreGameTile?
    weak var hoveredTile: OPNStoreGameTile?
    var lastLayoutWidth: CGFloat = 0
    var lastLayoutHeight: CGFloat = 0
    var renderStoreScheduled = false
    var resizeRenderTimer: Timer?
    var initialHeroPreloadInFlight = false
    var initialHeroReady = false
    var initialHeroPreloadGeneration = 0
    var heroFeaturedGameObjects: [OPNCatalogGameObject] = []
    var heroPanelObjects: [OPNCatalogPanelObject] = []
    var heroOwnedLibraryGameObjects: [OPNCatalogGameObject] = []
    var heroLibraryGameObjects: [OPNCatalogGameObject] = []
    var renderingVisibleLibraryGameObjects: [OPNCatalogGameObject] = []
    var renderingVisiblePanelObjects: [OPNCatalogPanelObject] = []
    var panelsFingerprint = ""
    var buttonHintControllerFamily = OPNStoreControllerFamily.keyboard
    var hasLibraryState = false
    private var panelObjects: [OPNCatalogPanelObject] = []
    private var libraryGameObjects: [OPNCatalogGameObject] = []
    private var ownedLibraryGameObjects: [OPNCatalogGameObject] = []

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var hasContent: Bool { !catalogModel.sections.isEmpty || catalogModel.heroGame != nil }

    override init(frame frameRect: NSRect) {
        scrollView = NSScrollView(frame: frameRect)
        documentView = OPNStoreDocumentView(frame: NSRect(x: 0, y: 0, width: frameRect.width, height: frameRect.height))
        loadingView = OPNLoadingView(frame: frameRect, message: "Loading games...")
        statusLabel = OPNUIHelpers.label(text: "", frame: .zero, size: 15, color: OPNUIHelpers.color(rgb: 0x787A82, alpha: 1), weight: .medium, alignment: .center)
        buttonHintPillView = OPNStoreHintPillView(frame: .zero)
        buttonHintStackView = NSStackView(frame: .zero)
        searchPanelView = NSView(frame: .zero)
        searchField = NSSearchField(frame: .zero)
        catalogModel = OPNGameCatalogModel()
        super.init(frame: frameRect)
        configureCatalogView(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        heroRotationTimer?.invalidate()
        resizeRenderTimer?.invalidate()
        searchDebounceTimer?.invalidate()
        cancelHeroImageLoads()
        cancelPrefetchImageLoads()
    }

    override func layout() {
        super.layout()
        hostingView?.frame = bounds
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { window?.makeFirstResponder(self) }
        rebuildButtonHintPillForCurrentController()
    }

    @objc(interfacePreferencesChanged:)
    func interfacePreferencesChanged(_ notification: Notification) { rebuildSwiftUICatalog() }

    @objc(controllerConfigurationChanged:)
    func controllerConfigurationChanged(_ notification: Notification) { rebuildButtonHintPillForCurrentController() }

    func removeButtonHintGroups() {
        OPNGameCatalogLayoutSupport.removeButtonHintGroups(from: buttonHintStackView)
    }

    func rebuildButtonHintPillForCurrentController() {
        buttonHintControllerFamily = OPNGameCatalogLayoutSupport.connectedControllerFamily()
        catalogModel.controllerFamily = buttonHintControllerFamily
    }

    func refreshLibrarySelections() {
        rebuildSwiftUICatalog()
    }

    func updateFocusedTiles() {
        catalogModel.clampFocus()
    }

    func scrollFocusedTileIntoView() {
        catalogModel.requestScrollForFocusedItem()
    }

    func moveGamepadFocusByRows(_ rowDelta: Int, columns columnDelta: Int) {
        if catalogModel.moveFocus(rowDelta: rowDelta, columnDelta: columnDelta) {
            scrollFocusedTileIntoView()
        }
    }

    func moveGamepadFocus(by delta: Int) { moveGamepadFocusByRows(0, columns: delta) }

    func activateGamepadFocus() {
        guard let item = catalogModel.focusedItem else { return }
        onSelectGame?(item.gameObject, item.selectedVariantIndex)
    }

    func cycleFocusedGamepadVariant() {
        catalogModel.cycleFocusedVariant()
    }

    override func keyDown(with event: NSEvent) {
        switch OPNGameCatalogLayoutSupport.inputAction(for: event) {
        case .moveLeft, .moveBackward: moveGamepadFocusByRows(0, columns: -1)
        case .moveRight, .moveForward: moveGamepadFocusByRows(0, columns: 1)
        case .moveUp: moveGamepadFocusByRows(-1, columns: 0)
        case .moveDown: moveGamepadFocusByRows(1, columns: 0)
        case .activate: activateGamepadFocus()
        case .cycleVariant: cycleFocusedGamepadVariant()
        default: super.keyDown(with: event)
        }
    }

    func setLoading(_ loading: Bool) {
        let showBlockingLoader = loading && !hasContent
        catalogModel.isLoading = showBlockingLoader
        catalogModel.errorMessage = ""
        showBlockingLoader ? loadingView.startAnimating() : loadingView.stopAnimating()
    }

    func setError(_ message: String?) {
        heroRotationTimer?.invalidate()
        heroRotationTimer = nil
        setLoading(false)
        catalogModel.errorMessage = message ?? ""
    }

    func setUserName(_ name: String?) {}

    func setActiveSessionAppIds(_ appIds: [NSNumber]) {
        let activeIds = Set(appIds.map { $0.stringValue }.filter { !$0.isEmpty })
        guard catalogModel.activeSessionAppIds != activeIds else { return }
        catalogModel.activeSessionAppIds = activeIds
    }

    func setGameObjects(_ games: [OPNCatalogGameObject]) {
        libraryGameObjects = games
        ownedLibraryGameObjects = games
        heroLibraryGameObjects = libraryGameObjects
        heroOwnedLibraryGameObjects = ownedLibraryGameObjects
        renderingVisibleLibraryGameObjects = Self.visibleLibraryGames(from: ownedLibraryGameObjects)
        hasLibraryState = true
        let panels = Self.catalogPanels(for: games)
        onGameCountChanged?(panels.reduce(0) { total, panel in total + panel.sections.reduce(0) { $0 + $1.games.count } })
        setPanelObjects(panels)
    }

    func setCatalogBrowseResultObject(_ result: OPNCatalogBrowseResultObject?) {
        let games = result?.games ?? []
        setPanelObjects(Self.catalogPanels(for: games))
        onGameCountChanged?(result.map { $0.totalCount > 0 ? $0.totalCount : $0.games.count } ?? 0)
    }

    func setPanelObjects(_ panels: [OPNCatalogPanelObject]) {
        let fingerprint = Self.panelsFingerprint(panels)
        if hasContent && fingerprint == panelsFingerprint {
            panelObjects = panels
            mergeKnownStoreMetadataIntoPanels()
            heroPanelObjects = panelObjects
            renderingVisiblePanelObjects = panelObjects
            if !OPNGameCatalogSearchSupport.normalizedString(searchQuery).isEmpty { scheduleAsyncSearchForCurrentQuery() }
            rebuildSwiftUICatalog()
            return
        }
        panelObjects = panels
        panelsFingerprint = fingerprint
        mergeKnownStoreMetadataIntoPanels()
        heroPanelObjects = panelObjects
        renderingVisiblePanelObjects = panelObjects
        if !OPNGameCatalogSearchSupport.normalizedString(searchQuery).isEmpty { scheduleAsyncSearchForCurrentQuery() }
        currentHeroIndex = 0
        initialHeroReady = false
        initialHeroPreloadInFlight = false
        initialHeroPreloadGeneration += 1
        initialHeroImage = nil
        initialHeroIdentity = nil
        configureHeroRotationTimer()
        prefetchHeroArtworkCandidates()
        rebuildSwiftUICatalog()
    }

    func setFeaturedGameObjects(_ games: [OPNCatalogGameObject]) {
        heroFeaturedGameObjects = games
        currentHeroIndex = 0
        initialHeroReady = false
        initialHeroPreloadInFlight = false
        initialHeroPreloadGeneration += 1
        initialHeroImage = nil
        initialHeroIdentity = nil
        configureHeroRotationTimer()
        prefetchHeroArtworkCandidates()
        rebuildSwiftUICatalog()
    }

    func setLibraryGameObjects(_ games: [OPNCatalogGameObject]) {
        libraryGameObjects = games
        ownedLibraryGameObjects = games
        heroLibraryGameObjects = libraryGameObjects
        heroOwnedLibraryGameObjects = ownedLibraryGameObjects
        renderingVisibleLibraryGameObjects = Self.visibleLibraryGames(from: ownedLibraryGameObjects)
        hasLibraryState = true
        mergeKnownStoreMetadataIntoPanels()
        let hasSearchQuery = !OPNGameCatalogSearchSupport.normalizedString(searchQuery).isEmpty
        if hasSearchQuery {
            scheduleAsyncSearchForCurrentQuery()
            if hasContent { refreshLibrarySelections() }
            return
        }
        if hasContent {
            refreshLibrarySelections()
        } else if !panelObjects.isEmpty || !Self.visibleLibraryGames(from: ownedLibraryGameObjects).isEmpty {
            rebuildSwiftUICatalog()
        }
    }

    @discardableResult
    func mergeKnownStoreMetadataIntoPanels() -> Bool {
        guard !panelObjects.isEmpty else { return false }
        var changed = false
        for panel in panelObjects {
            for section in panel.sections {
                for storeGame in section.games {
                    if hasLibraryState { changed = Self.clearOwnershipMetadata(storeGame) || changed }
                    if let knownGame = Self.findKnownGame(storeGame, in: libraryGameObjects) {
                        changed = Self.mergeStoreMetadata(target: storeGame, source: knownGame) || changed
                    }
                }
            }
        }
        heroPanelObjects = panelObjects
        renderingVisiblePanelObjects = panelObjects
        return changed
    }

    @objc(selectedVariantIndexForGameObject:)
    func selectedVariantIndex(for storeGame: OPNCatalogGameObject) -> Int32 {
        for libraryGame in libraryGameObjects where Self.gamesMatch(storeGame, libraryGame) {
            let libraryVariantIndex = Self.selectedLibraryVariantIndex(libraryGame)
            guard libraryVariantIndex >= 0, libraryVariantIndex < libraryGame.variants.count else { return storeGame.variants.isEmpty ? -1 : 0 }
            let libraryVariant = libraryGame.variants[libraryVariantIndex]
            for (index, storeVariant) in storeGame.variants.enumerated() where !libraryVariant.id.isEmpty && storeVariant.id == libraryVariant.id { return Int32(index) }
            for (index, storeVariant) in storeGame.variants.enumerated() where !libraryVariant.appStore.isEmpty && OPNGameCatalogMetadataSupport.stringEqualsCaseInsensitive(storeVariant.appStore, rhs: libraryVariant.appStore) { return Int32(index) }
            return storeGame.variants.isEmpty ? -1 : 0
        }
        return storeGame.variants.isEmpty ? -1 : 0
    }

    private func configureCatalogView(frame: NSRect) {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        let root = OPNGameCatalogSwiftUIView(
            model: catalogModel,
            onSearchChanged: { [weak self] query in self?.handleSwiftUISearchQueryChanged(query) },
            onSelect: { [weak self] item in self?.onSelectGame?(item.gameObject, item.selectedVariantIndex) },
            onMarkUnowned: { [weak self] item in self?.onMarkGameUnowned?(item.gameObject, item.selectedVariantIndex) }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        hostingView = hosting
        rebuildButtonHintPillForCurrentController()
        NotificationCenter.default.addObserver(self, selector: #selector(interfacePreferencesChanged(_:)), name: OPNInterfacePreferencesDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(controllerConfigurationChanged(_:)), name: .GCControllerDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(controllerConfigurationChanged(_:)), name: .GCControllerDidDisconnect, object: nil)
    }

    func handleSwiftUISearchQueryChanged(_ query: String) {
        guard searchQuery != query else { return }
        searchQuery = query
        searchGeneration += 1
        searchDebounceTimer?.invalidate()
        searchDebounceTimer = nil
        if !OPNGameCatalogSearchSupport.normalizedString(searchQuery).isEmpty {
            searchDebounceTimer = Timer.scheduledTimer(timeInterval: OPNGameCatalogLayoutSupport.storeSearchDebounceInterval, target: self, selector: #selector(performAsyncSearchTimerFired(_:)), userInfo: nil, repeats: false)
            return
        }
        scheduleAsyncSearchForCurrentQuery()
    }

    func rebuildSwiftUICatalog() {
        let heroGame = currentHeroGameObject()
        var sections: [OPNGameCatalogSectionModel] = []
        if !renderingVisibleLibraryGameObjects.isEmpty {
            sections.append(OPNGameCatalogSectionModel(id: "owned-library", title: "Library", games: renderingVisibleLibraryGameObjects.map { game in
                OPNGameCatalogItemModel(gameObject: game, selectedVariantIndex: selectedVariantIndex(for: game))
            }))
        }
        for panel in renderingVisiblePanelObjects {
            for section in panel.sections where !section.games.isEmpty {
                let sectionID = section.id.isEmpty ? "section-\(sections.count)-\(section.title)" : section.id
                sections.append(OPNGameCatalogSectionModel(id: sectionID, title: section.title.isEmpty ? "Featured" : section.title, games: section.games.map { game in
                    OPNGameCatalogItemModel(gameObject: game, selectedVariantIndex: selectedVariantIndex(for: game))
                }))
            }
        }
        catalogModel.heroGame = heroGame.map { OPNGameCatalogItemModel(gameObject: $0, selectedVariantIndex: selectedVariantIndex(for: $0)) }
        catalogModel.sections = sections
        catalogModel.searchText = searchQuery
        catalogModel.isLoading = false
        catalogModel.clampFocus()
    }
}

@MainActor
final class OPNGameCatalogModel: ObservableObject {
    @Published var heroGame: OPNGameCatalogItemModel?
    @Published var sections: [OPNGameCatalogSectionModel] = []
    @Published var searchText = ""
    @Published var isLoading = false
    @Published var errorMessage = ""
    @Published var controllerFamily = OPNStoreControllerFamily.keyboard
    @Published var focusedRowIndex = 0
    @Published var focusedColumnIndex = 0
    @Published var focusedTileID: String?
    @Published var focusScrollRequestItemID: String?
    @Published var focusScrollRequestToken = 0
    @Published var activeSessionAppIds: Set<String> = []

    var focusedItem: OPNGameCatalogItemModel? {
        guard focusedRowIndex >= 0, focusedRowIndex < sections.count else { return nil }
        let games = sections[focusedRowIndex].games
        guard focusedColumnIndex >= 0, focusedColumnIndex < games.count else { return nil }
        return games[focusedColumnIndex]
    }

    func clampFocus() {
        guard !sections.isEmpty else {
            focusedRowIndex = 0
            focusedColumnIndex = 0
            focusedTileID = nil
            return
        }
        focusedRowIndex = OPNGameCatalogLayoutSupport.clampedIndex(index: focusedRowIndex, count: sections.count)
        let games = sections[focusedRowIndex].games
        guard !games.isEmpty else {
            focusedColumnIndex = 0
            focusedTileID = nil
            return
        }
        focusedColumnIndex = OPNGameCatalogLayoutSupport.clampedIndex(index: focusedColumnIndex, count: games.count)
        focusedTileID = games[focusedColumnIndex].id
    }

    @discardableResult
    func moveFocus(rowDelta: Int, columnDelta: Int) -> Bool {
        guard !sections.isEmpty else { return false }
        let nextRow = OPNGameCatalogLayoutSupport.clampedIndex(index: focusedRowIndex + rowDelta, count: sections.count)
        guard !sections[nextRow].games.isEmpty else { return false }
        var nextColumn = focusedColumnIndex + columnDelta
        if nextRow != focusedRowIndex && columnDelta == 0 { nextColumn = min(nextColumn, sections[nextRow].games.count - 1) }
        let clampedColumn = OPNGameCatalogLayoutSupport.clampedIndex(index: nextColumn, count: sections[nextRow].games.count)
        guard nextRow != focusedRowIndex || clampedColumn != focusedColumnIndex else { return false }
        focusedRowIndex = nextRow
        focusedColumnIndex = clampedColumn
        focusedTileID = sections[focusedRowIndex].games[focusedColumnIndex].id
        return true
    }

    func requestScrollForFocusedItem() {
        guard let focusedItem else { return }
        focusScrollRequestItemID = focusedItem.id
        focusScrollRequestToken += 1
    }

    func cycleFocusedVariant() {
        guard focusedRowIndex >= 0, focusedRowIndex < sections.count else { return }
        guard focusedColumnIndex >= 0, focusedColumnIndex < sections[focusedRowIndex].games.count else { return }
        let variants = sections[focusedRowIndex].games[focusedColumnIndex].gameObject.variants
        guard variants.count > 1 else { return }
        let current = max(0, Int(sections[focusedRowIndex].games[focusedColumnIndex].selectedVariantIndex))
        sections[focusedRowIndex].games[focusedColumnIndex].selectedVariantIndex = Int32((current + 1) % variants.count)
        focusedTileID = sections[focusedRowIndex].games[focusedColumnIndex].id
    }

    func setVariant(itemID: String, variantIndex: Int32) {
        for sectionIndex in sections.indices {
            guard let gameIndex = sections[sectionIndex].games.firstIndex(where: { $0.id == itemID }) else { continue }
            sections[sectionIndex].games[gameIndex].selectedVariantIndex = variantIndex
            if heroGame?.id == itemID { heroGame?.selectedVariantIndex = variantIndex }
            return
        }
        if heroGame?.id == itemID { heroGame?.selectedVariantIndex = variantIndex }
    }

    func item(withID id: String) -> OPNGameCatalogItemModel? {
        if let heroGame, heroGame.id == id { return heroGame }
        for section in sections {
            if let item = section.games.first(where: { $0.id == id }) { return item }
        }
        return nil
    }

    func hasActiveSession(for item: OPNGameCatalogItemModel) -> Bool {
        guard !activeSessionAppIds.isEmpty else { return false }
        let game = item.gameObject
        if activeSessionAppIds.contains(game.id) || activeSessionAppIds.contains(game.launchAppId) { return true }
        return game.variants.contains { !$0.id.isEmpty && activeSessionAppIds.contains($0.id) }
    }
}

struct OPNGameCatalogSectionModel: Identifiable, Equatable {
    let id: String
    let title: String
    var games: [OPNGameCatalogItemModel]
}

struct OPNGameCatalogItemModel: Identifiable, Equatable {
    let id: String
    let gameObject: OPNCatalogGameObject
    var selectedVariantIndex: Int32

    init(gameObject: OPNCatalogGameObject, selectedVariantIndex: Int32) {
        self.gameObject = gameObject
        self.selectedVariantIndex = selectedVariantIndex
        id = Self.identity(for: gameObject)
    }

    static func == (lhs: OPNGameCatalogItemModel, rhs: OPNGameCatalogItemModel) -> Bool {
        lhs.id == rhs.id && lhs.selectedVariantIndex == rhs.selectedVariantIndex
    }

    private static func identity(for game: OPNCatalogGameObject) -> String {
        if !game.id.isEmpty { return game.id }
        if !game.uuid.isEmpty { return game.uuid }
        if !game.launchAppId.isEmpty { return game.launchAppId }
        return game.title
    }
}

struct OPNGameCatalogSwiftUIView: View {
    @ObservedObject var model: OPNGameCatalogModel
    @State private var selectedDetailItemID = ""
    @State private var favoriteDetailItemIDs: Set<String> = []

    let onSearchChanged: (String) -> Void
    let onSelect: (OPNGameCatalogItemModel) -> Void
    let onMarkUnowned: (OPNGameCatalogItemModel) -> Void

    private let topNavHeight: CGFloat = 64.0

    var body: some View {
        GeometryReader { viewport in
            ZStack {
                Color(nsColor: OPNUIHelpers.color(rgb: 0x141414, alpha: 1.0))
                    .ignoresSafeArea()
                LinearGradient(
                    colors: [Color.black.opacity(0.42), Color.black.opacity(0.0)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: min(634.0, viewport.size.width * 0.42))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .ignoresSafeArea()
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        if model.isLoading {
                            loadingState
                                .padding(.top, 88)
                        } else if !model.errorMessage.isEmpty {
                            errorState
                                .padding(.top, 88)
                        } else {
                            if let heroGame = model.heroGame {
                                heroView(heroGame, viewportSize: viewport.size)
                                    .padding(.top, topNavHeight)
                                    .padding(.bottom, OPNGameCatalogLayoutSupport.heroFirstRowSpacing(forWidth: viewport.size.width))
                            } else {
                                Color.clear.frame(height: topNavHeight + 88)
                            }
                            if model.sections.isEmpty {
                                emptyState
                            } else {
                                catalogSections(viewportSize: viewport.size)
                            }
                        }
                    }
                    .padding(.bottom, 118)
                }
                .ignoresSafeArea(.container, edges: .top)
                topNavigationBar(viewportSize: viewport.size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea(.container, edges: .top)
                controllerHints
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 8)
            }
        }
    }

    private func topNavigationBar(viewportSize: CGSize) -> some View {
        ZStack {
            Color(nsColor: OPNUIHelpers.color(rgb: 0x333333, alpha: 1.0))
            HStack(spacing: 0) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .frame(width: 68, height: topNavHeight)
                Text("Games")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.94))
                Spacer(minLength: 0)
            }
            catalogSearch(viewportSize: viewportSize)
        }
        .frame(height: topNavHeight)
        .overlay(Rectangle().fill(Color.black.opacity(0.28)).frame(height: 1), alignment: .bottom)
    }

    private func catalogSearch(viewportSize: CGSize) -> some View {
        let panelSize = searchPanelSize(for: viewportSize)
        return HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.72))
                .frame(width: 18, height: 30)
            TextField("Search games, stores, or genres", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.88))
                .frame(height: 30)
                .onChange(of: model.searchText) { _, query in onSearchChanged(query) }
        }
        .padding(.horizontal, 12)
        .frame(width: panelSize.width, height: panelSize.height)
        .background(Color(nsColor: OPNUIHelpers.color(rgb: 0x292929, alpha: 0.92)))
        .overlay(Rectangle().stroke(Color.white.opacity(0.24), lineWidth: 1))
    }

    private func heroView(_ item: OPNGameCatalogItemModel, viewportSize: CGSize) -> some View {
        let height = OPNGameCatalogLayoutSupport.heroHeight(forWidth: viewportSize.width, viewportHeight: viewportSize.height)
        return ZStack(alignment: .topLeading) {
            OPNCatalogHeroStageView(item: item)
            heroRibbon
            heroDetails(item)
            heroDots
        }
        .frame(height: height)
    }

    private var heroRibbon: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Color(nsColor: OPNUIHelpers.color(rgb: 0x76B900, alpha: 1.0)))
                .frame(width: 12)
                .rotationEffect(.degrees(14))
                .offset(x: -5)
            Text("New Season")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.95))
                .padding(.leading, 8)
                .padding(.trailing, 16)
        }
        .frame(height: 28)
        .background(Color(nsColor: OPNUIHelpers.color(rgb: 0x333333, alpha: 0.86)))
        .padding(.top, 12)
    }

    private func heroDetails(_ item: OPNGameCatalogItemModel) -> some View {
        VStack(spacing: 18) {
            Text(heroStoreLabel(for: item))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.80))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Button("VIEW DETAILS") { toggleDetail(for: item) }
                .buttonStyle(OPNCatalogHeroActionButtonStyle())
                .frame(width: 146, height: 42)
        }
        .frame(width: 210)
        .padding(.leading, 226)
        .padding(.top, 285)
    }

    private var heroDots: some View {
        HStack(spacing: 16) {
            ForEach(0..<6, id: \.self) { index in
                Circle()
                    .fill(index == 4 ? Color(nsColor: OPNUIHelpers.color(rgb: 0x76B900, alpha: 1.0)) : Color.white.opacity(0.58))
                    .frame(width: index == 4 ? 14 : 9, height: index == 4 ? 14 : 9)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 34)
    }

    private func heroStoreLabel(for item: OPNGameCatalogItemModel) -> String {
        let stores = item.gameObject.availableStores.map { OPNGameCatalogArtworkSupport.displayLabel($0) }.filter { !$0.isEmpty }
        let variantStore = variant(at: item.selectedVariantIndex, in: item.gameObject).map { OPNGameCatalogArtworkSupport.displayLabel($0.appStore) } ?? ""
        let store = stores.first ?? variantStore
        return "\(store.isEmpty ? "Cloud" : store)\nESRB: TEEN"
    }

    private func catalogSections(viewportSize: CGSize) -> some View {
        let headerLeft = OPNGameCatalogLayoutSupport.storeSectionHeaderMargin
        let headerRight = OPNGameCatalogLayoutSupport.storeSectionHeaderRightMargin
        let railWidth = max(320, max(980, viewportSize.width))
        let tileSize = OPNGameCatalogLayoutSupport.tileMetrics(forRailWidth: railWidth)
        let rowHeight = tileSize.height + OPNGameCatalogLayoutSupport.storeTileTopMargin + OPNGameCatalogLayoutSupport.storeTileScrimHeight
        return VStack(spacing: 12) {
            ForEach(Array(model.sections.enumerated()), id: \.element.id) { rowIndex, section in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(displayTitle(for: section.title))
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(Color.white)
                        Spacer()
                        Text("SEE ALL")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.92))
                    }
                    .frame(height: OPNGameCatalogLayoutSupport.storeSectionTitleHeight)
                    .padding(.leading, headerLeft)
                    .padding(.trailing, headerRight)
                    ScrollViewReader { rowProxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: OPNGameCatalogLayoutSupport.storeCardSpacing) {
                                ForEach(Array(section.games.enumerated()), id: \.element.id) { columnIndex, item in
                                    OPNCatalogStoreTileView(
                                        item: item,
                                        activeSession: model.hasActiveSession(for: item),
                                        focused: model.focusedRowIndex == rowIndex && model.focusedColumnIndex == columnIndex,
                                        focusScrollRequestToken: model.focusScrollRequestItemID == item.id ? model.focusScrollRequestToken : 0,
                                        onSelect: { selectedVariantIndex in
                                            model.setVariant(itemID: item.id, variantIndex: selectedVariantIndex)
                                            toggleDetail(for: model.item(withID: item.id) ?? OPNGameCatalogItemModel(gameObject: item.gameObject, selectedVariantIndex: selectedVariantIndex))
                                        },
                                        onHover: {
                                            model.focusedRowIndex = rowIndex
                                            model.focusedColumnIndex = columnIndex
                                        },
                                        onMarkUnowned: { selectedVariantIndex in
                                            model.setVariant(itemID: item.id, variantIndex: selectedVariantIndex)
                                            onMarkUnowned(model.item(withID: item.id) ?? OPNGameCatalogItemModel(gameObject: item.gameObject, selectedVariantIndex: selectedVariantIndex))
                                        }
                                    )
                                    .id(item.id)
                                    .frame(width: tileSize.width, height: tileSize.height)
                                }
                            }
                            .padding(.leading, headerLeft - OPNGameCatalogLayoutSupport.storeTileHorizontalMargin)
                            .padding(.trailing, headerRight - OPNGameCatalogLayoutSupport.storeTileHorizontalMargin)
                            .padding(.top, OPNGameCatalogLayoutSupport.storeTileTopMargin)
                            .padding(.bottom, OPNGameCatalogLayoutSupport.storeTileScrimHeight)
                        }
                        .onChange(of: model.focusScrollRequestToken) { _, _ in
                            guard let itemID = model.focusScrollRequestItemID, section.games.contains(where: { $0.id == itemID }) else { return }
                            rowProxy.scrollTo(itemID, anchor: .center)
                        }
                    }
                    .frame(height: rowHeight)
                    if let selectedItem = selectedDetailItem(in: section) {
                        activeGameDetail(selectedItem, viewportSize: viewportSize)
                    }
                }
            }
        }
        .padding(.top, 18)
        .background(Color(nsColor: OPNUIHelpers.color(rgb: 0x141414, alpha: 1.0)))
    }

    private func displayTitle(for title: String) -> String {
        title.caseInsensitiveCompare("Library") == .orderedSame ? "My Library" : title
    }

    private func selectedDetailItem(in section: OPNGameCatalogSectionModel) -> OPNGameCatalogItemModel? {
        guard !selectedDetailItemID.isEmpty else { return nil }
        return section.games.first { $0.id == selectedDetailItemID }
    }

    private func toggleDetail(for item: OPNGameCatalogItemModel) {
        selectedDetailItemID = selectedDetailItemID == item.id ? "" : item.id
    }

    private func activeGameDetail(_ item: OPNGameCatalogItemModel, viewportSize: CGSize) -> some View {
        let height = min(580.0, max(430.0, viewportSize.height * 0.54))
        let leftWidth = min(760.0, max(520.0, viewportSize.width * 0.45))
        return ZStack(alignment: .topLeading) {
            Color(nsColor: OPNUIHelpers.color(rgb: 0x303030, alpha: 1.0))
            HStack(spacing: 0) {
                Spacer(minLength: leftWidth)
                OPNCatalogArtworkView(urlStrings: activeGameArtworkCandidates(for: item.gameObject), contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .overlay(LinearGradient(colors: [Color(nsColor: OPNUIHelpers.color(rgb: 0x303030, alpha: 1.0)), Color(nsColor: OPNUIHelpers.color(rgb: 0x303030, alpha: 0.70)), .clear], startPoint: .leading, endPoint: .trailing))
                    .overlay(LinearGradient(colors: [.clear, Color.black.opacity(0.34)], startPoint: .top, endPoint: .bottom))
            }
            activeGameInfo(item, leftWidth: leftWidth)
            Button { selectedDetailItemID = "" } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .frame(width: 52, height: 52)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, 8)
            .padding(.trailing, 28)
            activeGameLogo(item.gameObject)
            activeGameDots
        }
        .frame(height: height)
    }

    private func activeGameInfo(_ item: OPNGameCatalogItemModel, leftWidth: CGFloat) -> some View {
        let isFavorite = favoriteDetailItemIDs.contains(item.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 18) {
                    Text(item.gameObject.title.isEmpty ? "Selected Game" : item.gameObject.title)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.96))
                        .lineLimit(1)
                    detailMetadata(item.gameObject)
                    detailBadges()
                    detailStoreRow(item)
                    HStack(spacing: 18) {
                        Button(primaryActionTitle(item).uppercased()) { onSelect(item) }
                            .buttonStyle(OPNCatalogDetailPlayButtonStyle())
                            .frame(width: 74, height: 41)
                        Menu {
                            if variantCanBeMarkedUnowned(item) {
                                Button("Mark as Unowned") { onMarkUnowned(item) }
                            } else {
                                Button("Game Options") {}
                                    .disabled(true)
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(Color.white.opacity(0.92))
                                .frame(width: 38, height: 38)
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                    }
                    HStack(spacing: 0) {
                        Text("Access unlocked with your membership. Game ownership required to play. ")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.70))
                        Text("Learn more")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color(nsColor: OPNUIHelpers.color(rgb: 0x76B900, alpha: 1.0)))
                            .underline()
                    }
                    Text(detailDescription(item.gameObject))
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.90))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    detailCapabilities()
                    detailRating(item.gameObject)
                    HStack(spacing: 6) {
                        Text("READ MORE")
                            .font(.system(size: 15, weight: .bold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(Color.white.opacity(0.92))
                    .padding(.top, 20)
                }
                Spacer(minLength: 20)
                Button {
                    if isFavorite { favoriteDetailItemIDs.remove(item.id) } else { favoriteDetailItemIDs.insert(item.id) }
                } label: {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .frame(width: 52, height: 52)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, OPNGameCatalogLayoutSupport.storeSectionHeaderMargin)
        .padding(.top, 24)
        .frame(width: leftWidth, alignment: .topLeading)
    }

    private func detailMetadata(_ game: OPNCatalogGameObject) -> some View {
        HStack(spacing: 11) {
            Text(contentRatingLabel(game))
                .font(.system(size: 12, weight: .bold))
            Image(systemName: "person.3.fill")
            Image(systemName: "keyboard")
            Image(systemName: "gamecontroller.fill")
            Text("·")
            Text(detailGenreLabel(game))
                .lineLimit(1)
        }
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(Color.white.opacity(0.82))
    }

    private func detailBadges() -> some View {
        HStack(spacing: 4) {
            detailBadge("checkmark.circle.fill", "For Premium Members", highlighted: true)
            detailBadge(nil, "RTX", highlighted: false)
            detailBadge(nil, "Reflex", highlighted: false)
        }
    }

    private func detailStoreRow(_ item: OPNGameCatalogItemModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "cloud.fill")
                .font(.system(size: 13, weight: .bold))
            Text(detailStoreLabel(item))
                .font(.system(size: 14, weight: .bold))
            detailBadge(nil, gameNeedsPurchase(item) ? "Required" : "Owned", highlighted: false)
        }
        .foregroundStyle(Color.white.opacity(0.88))
        .padding(.top, 12)
    }

    private func detailBadge(_ icon: String?, _ text: String, highlighted: Bool) -> some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
            }
            Text(text)
                .font(.system(size: 12, weight: .bold))
        }
        .foregroundStyle(Color.white.opacity(highlighted ? 0.94 : 0.70))
        .padding(.horizontal, 10)
        .frame(height: 23)
        .background(Color.white.opacity(highlighted ? 0.18 : 0.08))
    }

    private func detailCapabilities() -> some View {
        VStack(spacing: 0) {
            Divider().background(Color.white.opacity(0.22))
            detailCapabilityRow(icon: "checkmark.circle.fill", title: "RTX", subtitle: "Ready - You may need to turn this on in-game")
            detailCapabilityRow(icon: "lock.fill", title: "Reflex", subtitle: "Upgrade your membership to unlock")
            Divider().background(Color.white.opacity(0.22))
        }
        .padding(.top, 2)
    }

    private func detailCapabilityRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .frame(width: 18)
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .frame(width: 58, alignment: .leading)
            Text(subtitle)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.70))
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.white.opacity(0.88))
        .frame(height: 31)
    }

    private func detailRating(_ game: OPNCatalogGameObject) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Text(String(contentRatingLabel(game).prefix(1)))
                    .font(.system(size: 38, weight: .black))
                    .foregroundStyle(Color.black)
                    .frame(width: 52, height: 52)
                    .background(Color.white)
                Text("ESRB")
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(Color.white)
                    .frame(width: 52, height: 12)
                    .background(Color.black)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(contentRatingLabel(game))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.90))
                Text("Blood, Violence")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.64))
                Divider().background(Color.white.opacity(0.22))
                Text("In-Game Purchases, Users Interact")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.64))
            }
        }
        .padding(.top, 18)
    }

    private var activeGameDots: some View {
        HStack(spacing: 12) {
            ForEach(0..<7, id: \.self) { index in
                Circle()
                    .fill(index == 0 ? Color(nsColor: OPNUIHelpers.color(rgb: 0x76B900, alpha: 1.0)) : Color.white.opacity(0.52))
                    .frame(width: 9, height: 9)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 42)
    }

    private func activeGameLogo(_ game: OPNCatalogGameObject) -> some View {
        OPNCatalogArtworkView(urlStrings: logoCandidates(for: game), contentMode: .fit)
            .frame(width: 200, height: 74)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, 40)
            .padding(.bottom, 38)
    }

    private func activeGameArtworkCandidates(for game: OPNCatalogGameObject) -> [String] {
        imageCandidates(for: game, preferredTypes: ["SCREENSHOT", "FEATURE_IMAGE", "HERO_IMAGE", "MARQUEE_HERO_IMAGE", "TV_BANNER", "KEY_ART", "GAME_BOX_ART"], includeScreenshots: true)
    }

    private func detailDescription(_ game: OPNCatalogGameObject) -> String {
        let trimmed = game.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return "\(game.title.isEmpty ? "This game" : game.title) is ready to stream on GeForce NOW. Launch instantly from your cloud gaming library."
    }

    private func detailGenreLabel(_ game: OPNCatalogGameObject) -> String {
        let labels = game.genres.prefix(2).map { OPNGameCatalogMetadataSupport.displayString($0, fallback: "") }.filter { !$0.isEmpty }
        return labels.isEmpty ? primaryGenre(game) : labels.joined(separator: ", ")
    }

    private func detailStoreLabel(_ item: OPNGameCatalogItemModel) -> String {
        variant(at: item.selectedVariantIndex, in: item.gameObject).map { OPNGameCatalogArtworkSupport.displayLabel($0.appStore) }.flatMap { $0.isEmpty ? nil : $0 } ?? variantStores(item.gameObject).first ?? "Cloud"
    }

    private func contentRatingLabel(_ game: OPNCatalogGameObject) -> String {
        let rating = game.contentRatings.first.map { OPNGameCatalogMetadataSupport.displayString($0, fallback: "") } ?? ""
        return rating.isEmpty ? "TEEN" : rating.uppercased()
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Loading games...")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(nsColor: OPNUIHelpers.color(rgb: OPNViewColor.textSecondary, alpha: 1)))
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    private var errorState: some View {
        statePanel(eyebrow: "CATALOG ERROR", title: model.errorMessage, subtitle: "Try again after the service refreshes.")
    }

    private var emptyState: some View {
        statePanel(eyebrow: "SIGNAL LOST", title: "No games found", subtitle: "The catalog returned no games. Try again after the service refreshes.")
    }

    private func statePanel(eyebrow: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Text(eyebrow)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(Color(nsColor: OPNUIHelpers.color(rgb: OPNViewColor.brandGreen, alpha: 1)))
            Text(title)
                .font(.system(size: 27, weight: .bold))
                .foregroundStyle(Color(nsColor: OPNUIHelpers.color(rgb: OPNViewColor.textPrimary, alpha: 1)))
            Text(subtitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(nsColor: OPNUIHelpers.color(rgb: OPNViewColor.textSecondary, alpha: 1)))
        }
        .frame(maxWidth: 760, minHeight: 220)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    private var controllerHints: some View {
        HStack(spacing: 18) {
            if model.controllerFamily == .keyboard {
                hint("↑↓←→", "Move")
                hint("Enter Space", "Select")
                hint("V", "Variant")
            } else {
                hint("D-Pad Stick", "Move")
                hint("A", "Select")
                hint("Y", "Variant")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
        .background(Color.black.opacity(0.56))
        .overlay(Rectangle().stroke(Color.white.opacity(0.14), lineWidth: 1))
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.90))
            Text(label)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.68))
        }
    }

    private func horizontalInset(forWidth width: CGFloat) -> CGFloat {
        OPNGameCatalogLayoutSupport.heroContentInset(forWidth: max(980.0, width))
    }

    private func searchPanelSize(for viewportSize: CGSize) -> CGSize {
        let scale = viewportSize.height <= 760 ? 0.82 : (viewportSize.height < 900 ? 0.92 : 1.0)
        let panelHeight = floor(46 * scale)
        let availableWidth = max(OPNGameCatalogLayoutSupport.storeSearchPanelMinWidth, viewportSize.width - 48)
        let panelWidth = min(540.0, availableWidth)
        return CGSize(width: panelWidth, height: panelHeight)
    }

    private func searchTopPadding(for viewportSize: CGSize) -> CGFloat {
        let scale = viewportSize.height <= 760 ? 0.82 : (viewportSize.height < 900 ? 0.92 : 1.0)
        return floor((140 * scale - searchPanelSize(for: viewportSize).height) * 0.5)
    }

}

private struct OPNCatalogHeroActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(Color.black.opacity(0.92))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: OPNUIHelpers.color(rgb: 0x76B900, alpha: configuration.isPressed ? 0.76 : 1.0)))
    }
}

private struct OPNCatalogDetailPlayButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .black))
            .foregroundStyle(Color.black.opacity(0.92))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: OPNUIHelpers.color(rgb: 0x76B900, alpha: configuration.isPressed ? 0.76 : 1.0)))
    }
}

private struct OPNCatalogStoreTileView: NSViewRepresentable {
    let item: OPNGameCatalogItemModel
    let activeSession: Bool
    let focused: Bool
    let focusScrollRequestToken: Int
    let onSelect: (Int32) -> Void
    let onHover: () -> Void
    let onMarkUnowned: (Int32) -> Void

    final class Coordinator {
        var appliedFocusScrollRequestToken = 0
        var pendingStateToken = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> OPNStoreGameTile {
        let tile = OPNStoreGameTile(frame: .zero, gameObject: item.gameObject, prominent: false)
        configureCallbacks(tile)
        scheduleStateUpdate(for: tile, context: context)
        return tile
    }

    func updateNSView(_ nsView: OPNStoreGameTile, context: Context) {
        configureCallbacks(nsView)
        scheduleStateUpdate(for: nsView, context: context)
    }

    private func scheduleStateUpdate(for tile: OPNStoreGameTile, context: Context) {
        let selectedVariantIndex = item.selectedVariantIndex
        let isFocused = focused
        let requestToken = focusScrollRequestToken
        let coordinator = context.coordinator
        coordinator.pendingStateToken += 1
        let pendingStateToken = coordinator.pendingStateToken
        DispatchQueue.main.async { [weak tile, weak coordinator] in
            guard let tile, let coordinator, coordinator.pendingStateToken == pendingStateToken else { return }
            tile.selectedVariantIndex = selectedVariantIndex
            tile.setActiveSession(activeSession)
            tile.setStoreFocused(isFocused)
            tile.ensureImageLoaded()
            if requestToken > 0 && coordinator.appliedFocusScrollRequestToken != requestToken {
                coordinator.appliedFocusScrollRequestToken = requestToken
                tile.scrollIntoListingPosition()
            }
        }
    }

    private func configureCallbacks(_ tile: OPNStoreGameTile) {
        tile.onSelect = { [weak tile] in
            onSelect(tile?.selectedVariantIndex ?? item.selectedVariantIndex)
        }
        tile.onHover = onHover
        tile.onMarkUnowned = { [weak tile] in
            onMarkUnowned(tile?.selectedVariantIndex ?? item.selectedVariantIndex)
        }
    }
}

private struct OPNCatalogArtworkView: View {
    let urlStrings: [String]
    let contentMode: ContentMode

    var body: some View {
        if let urlString = urlStrings.first, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: contentMode)
                default:
                    fallback
                }
            }
        } else {
            fallback
        }
    }

    private var fallback: some View {
        Image(nsImage: OPNGameCatalogArtworkSupport.fallbackArtworkImage())
            .resizable()
            .aspectRatio(contentMode: contentMode)
    }
}

private struct OPNCatalogHeroStageView: NSViewRepresentable {
    let item: OPNGameCatalogItemModel

    func makeNSView(context: Context) -> OPNCatalogHeroStageNSView {
        OPNCatalogHeroStageNSView(frame: .zero)
    }

    func updateNSView(_ nsView: OPNCatalogHeroStageNSView, context: Context) {
        nsView.update(gameObject: item.gameObject)
    }
}

@MainActor
private final class OPNCatalogHeroStageNSView: NSView {
    private let artworkView = OPNHeroArtworkView(frame: .zero)
    private let titleFallback: NSTextField
    private let logoView = NSImageView(frame: .zero)
    private var artworkTransitionView: OPNHeroArtworkView?
    private var logoTransitionView: NSImageView?
    private var imageLoadTokens: [OpnImageLoadToken] = []
    private var representedIdentity = ""
    private var generation = 0

    override init(frame frameRect: NSRect) {
        let textShadow = NSShadow()
        textShadow.shadowBlurRadius = 18.0
        textShadow.shadowOffset = NSSize(width: 0.0, height: -2.0)
        textShadow.shadowColor = OPNUIHelpers.color(rgb: 0x000000, alpha: 0.82)
        titleFallback = OPNUIHelpers.label(text: "", frame: .zero, size: 42.0, color: OPNUIHelpers.color(rgb: 0xF5F5F7, alpha: 1.0), weight: .black, alignment: .left)
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true
        let fallbackArtwork = OPNUIHelpers.fallbackHeroArtworkImage()
        artworkView.fadeColor = OPNGameCatalogArtworkSupport.heroFadeColor(for: fallbackArtwork)
        artworkView.imageEdgeFadeFraction = 0.22
        artworkView.image = fallbackArtwork
        addSubview(artworkView, positioned: .below, relativeTo: nil)
        titleFallback.maximumNumberOfLines = 2
        titleFallback.lineBreakMode = .byWordWrapping
        titleFallback.shadow = textShadow
        titleFallback.wantsLayer = true
        titleFallback.layer?.zPosition = 1000.0
        addSubview(titleFallback, positioned: .above, relativeTo: nil)
        logoView.isHidden = true
        OPNGameCatalogArtworkSupport.configureHeroLogoImageView(logoView, zPosition: 1001.0)
        addSubview(logoView, positioned: .above, relativeTo: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    deinit {
        imageLoadTokens.forEach { $0.cancel() }
    }

    override func layout() {
        super.layout()
        artworkView.frame = bounds
        artworkView.imageContentFrame = OPNGameCatalogArtworkSupport.heroArtworkFrame(in: bounds)
        artworkTransitionView?.frame = bounds
        artworkTransitionView?.imageContentFrame = OPNGameCatalogArtworkSupport.heroArtworkFrame(in: bounds)
        updateLogoFrame()
    }

    func update(gameObject: OPNCatalogGameObject) {
        let identity = Self.gameIdentity(for: gameObject)
        guard identity != representedIdentity else {
            titleFallback.stringValue = gameObject.title
            updateLogoFrame()
            return
        }
        representedIdentity = identity
        generation += 1
        let currentGeneration = generation
        imageLoadTokens.forEach { $0.cancel() }
        imageLoadTokens.removeAll()
        titleFallback.stringValue = gameObject.title
        titleFallback.isHidden = false
        titleFallback.alphaValue = 1.0
        logoView.image = nil
        logoView.isHidden = true
        logoView.alphaValue = 1.0
        let fallbackArtwork = OPNUIHelpers.fallbackHeroArtworkImage()
        artworkView.fadeColor = OPNGameCatalogArtworkSupport.heroFadeColor(for: fallbackArtwork)
        artworkView.image = fallbackArtwork
        artworkView.alphaValue = 1.0
        updateLogoFrame()
        loadArtwork(for: gameObject, identity: identity, generation: currentGeneration)
        loadLogo(for: gameObject, generation: currentGeneration)
    }

    private func loadArtwork(for gameObject: OPNCatalogGameObject, identity: String, generation currentGeneration: Int) {
        let candidates = heroImageCandidates(for: gameObject)
        if let cachedImage = OPNUIHelpers.cachedMemoryImage(candidates: candidates, maxPixelDimension: 1600.0, resolvedURL: nil), OPNGameCatalogArtworkSupport.heroImageHasVisibleContent(cachedImage) {
            setArtworkImage(cachedImage, animated: false)
            return
        }
        guard !candidates.isEmpty else { return }
        loadArtwork(candidates: candidates, identity: identity, index: 0, generation: currentGeneration)
    }

    private func loadArtwork(candidates: [String], identity: String, index: Int, generation currentGeneration: Int) {
        guard index < candidates.count else { return }
        let remainingCandidates = Array(candidates[index...])
        if let cachedImage = OPNUIHelpers.cachedMemoryImage(candidates: remainingCandidates, maxPixelDimension: 1600.0, resolvedURL: nil), OPNGameCatalogArtworkSupport.heroImageHasVisibleContent(cachedImage) {
            setArtworkImage(cachedImage, animated: true)
            return
        }
        let token = OPNUIHelpers.loadImageForURLCancellable(urlString: candidates[index], maxPixelDimension: 1600.0) { [weak self] image, _, _ in
            guard let self, self.generation == currentGeneration, self.representedIdentity == identity else { return }
            guard let image, OPNGameCatalogArtworkSupport.heroImageHasVisibleContent(image) else {
                self.loadArtwork(candidates: candidates, identity: identity, index: index + 1, generation: currentGeneration)
                return
            }
            self.setArtworkImage(image, animated: true)
        }
        track(token)
    }

    private func loadLogo(for gameObject: OPNCatalogGameObject, generation currentGeneration: Int) {
        let candidates = logoCandidates(for: gameObject)
        let applyLogo: (NSImage?) -> Void = { [weak self] image in
            guard let self, self.generation == currentGeneration else { return }
            DispatchQueue.global(qos: .utility).async {
                let visibleLogo = image.flatMap(OPNGameCatalogArtworkSupport.visibleLogoImage)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == currentGeneration else { return }
                    self.setLogoImage(visibleLogo, animated: true)
                }
            }
        }
        if let cachedLogo = OPNUIHelpers.cachedMemoryImage(candidates: candidates, maxPixelDimension: 720.0, resolvedURL: nil) {
            applyLogo(cachedLogo)
            return
        }
        let token = OPNUIHelpers.loadImageFromCandidatesCancellable(candidates: candidates, maxPixelDimension: 720.0) { image, _, _ in
            applyLogo(image)
        }
        track(token)
    }

    private func setArtworkImage(_ image: NSImage, animated: Bool) {
        let fadeColor = OPNGameCatalogArtworkSupport.heroFadeColor(for: image)
        guard animated, artworkView.image != nil, artworkView.superview != nil else {
            artworkTransitionView?.removeFromSuperview()
            artworkTransitionView = nil
            artworkView.fadeColor = fadeColor
            artworkView.image = image
            artworkView.alphaValue = 1.0
            updateLogoFrame()
            return
        }
        artworkTransitionView?.removeFromSuperview()
        let transitionView = OPNHeroArtworkView(frame: artworkView.frame)
        transitionView.autoresizingMask = [.width, .height]
        transitionView.imageContentFrame = OPNGameCatalogArtworkSupport.heroArtworkFrame(in: bounds)
        transitionView.imageEdgeFadeFraction = 0.22
        transitionView.fadeColor = fadeColor
        transitionView.image = image
        transitionView.alphaValue = 0.0
        addSubview(transitionView, positioned: .above, relativeTo: artworkView)
        artworkTransitionView = transitionView
        bringLogoToFront()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = OPNGameCatalogLayoutSupport.storeHeroBackgroundFadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            transitionView.animator().alphaValue = 1.0
        } completionHandler: { [weak self, weak transitionView] in
            MainActor.assumeIsolated {
                guard let self, let transitionView, self.artworkTransitionView === transitionView else { return }
                self.artworkView.fadeColor = fadeColor
                self.artworkView.image = image
                self.artworkView.alphaValue = 1.0
                transitionView.removeFromSuperview()
                self.artworkTransitionView = nil
                self.updateLogoFrame()
            }
        }
    }

    private func setLogoImage(_ image: NSImage?, animated: Bool) {
        logoTransitionView?.removeFromSuperview()
        logoTransitionView = nil
        guard animated, let image else {
            logoView.image = image
            logoView.frame = image.map { OPNGameCatalogArtworkSupport.heroLogoFrame(for: $0, bounds: bounds, artworkImage: artworkView.image) } ?? OPNGameCatalogArtworkSupport.heroLogoFallbackFrame(bounds, artworkImage: artworkView.image)
            logoView.alphaValue = 1.0
            logoView.isHidden = image == nil
            titleFallback.isHidden = image != nil
            titleFallback.alphaValue = 1.0
            bringLogoToFront()
            return
        }
        let logoFrame = OPNGameCatalogArtworkSupport.heroLogoFrame(for: image, bounds: bounds, artworkImage: artworkView.image)
        let transitionView = NSImageView(frame: logoFrame)
        transitionView.image = image
        transitionView.alphaValue = 0.0
        transitionView.isHidden = false
        OPNGameCatalogArtworkSupport.configureHeroLogoImageView(transitionView, zPosition: 1002.0)
        addSubview(transitionView, positioned: .above, relativeTo: nil)
        logoTransitionView = transitionView
        bringLogoToFront()
        addSubview(transitionView, positioned: .above, relativeTo: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + OPNGameCatalogLayoutSupport.storeHeroLogoFadeDelay) { [weak self, weak transitionView] in
            guard let self, let transitionView, self.logoTransitionView === transitionView else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = OPNGameCatalogLayoutSupport.storeHeroLogoFadeDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                transitionView.animator().alphaValue = 1.0
                self.logoView.animator().alphaValue = 0.0
                self.titleFallback.animator().alphaValue = 0.0
            } completionHandler: { [weak self, weak transitionView] in
                MainActor.assumeIsolated {
                    guard let self, let transitionView, self.logoTransitionView === transitionView else { return }
                    self.logoView.frame = logoFrame
                    self.logoView.image = image
                    self.logoView.isHidden = false
                    self.logoView.alphaValue = 1.0
                    self.titleFallback.isHidden = true
                    self.titleFallback.alphaValue = 1.0
                    transitionView.removeFromSuperview()
                    self.logoTransitionView = nil
                    self.bringLogoToFront()
                }
            }
        }
    }

    private func updateLogoFrame() {
        titleFallback.frame = OPNGameCatalogArtworkSupport.heroLogoFallbackFrame(bounds, artworkImage: artworkView.image)
        logoView.frame = logoView.image.map { OPNGameCatalogArtworkSupport.heroLogoFrame(for: $0, bounds: bounds, artworkImage: artworkView.image) } ?? OPNGameCatalogArtworkSupport.heroLogoFallbackFrame(bounds, artworkImage: artworkView.image)
        if let transitionImage = logoTransitionView?.image {
            logoTransitionView?.frame = OPNGameCatalogArtworkSupport.heroLogoFrame(for: transitionImage, bounds: bounds, artworkImage: artworkView.image)
        }
        bringLogoToFront()
    }

    private func bringLogoToFront() {
        OPNGameCatalogArtworkSupport.bringHeroLogoToFront(container: self, titleFallback: titleFallback, logoView: logoView)
        if logoTransitionView?.superview === self, let logoTransitionView { addSubview(logoTransitionView, positioned: .above, relativeTo: nil) }
    }

    private func track(_ token: OpnImageLoadToken?) {
        guard let token else { return }
        imageLoadTokens.append(token)
        if imageLoadTokens.count > 16 {
            let removeCount = imageLoadTokens.count - 12
            for token in imageLoadTokens.prefix(removeCount) { token.cancel() }
            imageLoadTokens.removeFirst(removeCount)
        }
    }

    private static func gameIdentity(for game: OPNCatalogGameObject) -> String {
        if !game.id.isEmpty { return game.id }
        if !game.uuid.isEmpty { return game.uuid }
        if !game.launchAppId.isEmpty { return game.launchAppId }
        return game.title
    }
}

private func heroImageCandidates(for game: OPNCatalogGameObject) -> [String] {
    imageCandidates(for: game, preferredTypes: ["MARQUEE_HERO_IMAGE", "HERO_IMAGE", "TV_BANNER", "FEATURE_IMAGE", "KEY_ART", "KEY_IMAGE", "GAME_BOX_ART"], includeScreenshots: true)
}

private func logoCandidates(for game: OPNCatalogGameObject) -> [String] {
    imageCandidates(for: game, preferredTypes: ["GAME_LOGO", "LOGO", "TITLE_LOGO"], includeScreenshots: false)
}

private func imageCandidates(for game: OPNCatalogGameObject, preferredTypes: [String], includeScreenshots: Bool) -> [String] {
    var urls: [String] = []
    func append(_ value: String?) {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !urls.contains(trimmed) else { return }
        urls.append(trimmed)
    }
    for type in preferredTypes { (game.imageUrlsByType[type] ?? []).forEach(append) }
    append(game.heroImageUrl)
    append(game.imageUrl)
    if includeScreenshots { game.screenshotUrls.forEach(append) }
    return urls
}

private func primaryGenre(_ game: OPNCatalogGameObject) -> String {
    if let genre = game.genres.first { return OPNGameCatalogMetadataSupport.displayString(genre, fallback: "Cloud Game") }
    if !game.playType.isEmpty { return OPNGameCatalogMetadataSupport.displayString(game.playType, fallback: "Cloud Game") }
    return "Cloud Game"
}

private func featureSummary(_ game: OPNCatalogGameObject) -> String {
    var parts: [String] = []
    if game.maxOnlinePlayers > 1 { parts.append("\(game.maxOnlinePlayers) online") }
    if game.maxLocalPlayers > 1 { parts.append("\(game.maxLocalPlayers) local") }
    for feature in game.featureLabels {
        let label = OPNGameCatalogMetadataSupport.displayString(feature, fallback: "")
        if !label.isEmpty { parts.append(label) }
        if parts.count >= 2 { break }
    }
    return parts.isEmpty ? "Ready to stream" : parts.joined(separator: " · ")
}

private func variantStores(_ game: OPNCatalogGameObject) -> [String] {
    var stores: [String] = []
    var seen = Set<String>()
    func append(_ rawStore: String) {
        let store = OPNGameCatalogArtworkSupport.displayLabel(rawStore)
        guard !store.isEmpty, seen.insert(store.uppercased()).inserted else { return }
        stores.append(store)
    }
    game.variants.forEach { append($0.appStore) }
    game.availableStores.forEach(append)
    if stores.isEmpty { stores.append("Cloud") }
    return stores
}

private func storePrefix(_ store: String) -> String {
    let normalized = store.uppercased()
    if normalized.contains("STEAM") { return "ST" }
    if normalized.contains("EPIC") { return "EP" }
    if normalized.contains("XBOX") { return "XB" }
    if normalized.contains("UBISOFT") || normalized.contains("UPLAY") { return "UB" }
    if normalized.contains("BATTLE") { return "BN" }
    if normalized.contains("EA") { return "EA" }
    return String(store.prefix(2)).uppercased()
}

private func variant(at index: Int32, in game: OPNCatalogGameObject) -> OPNCatalogGameVariantObject? {
    let safeIndex = Int(index)
    guard safeIndex >= 0, safeIndex < game.variants.count else { return nil }
    return game.variants[safeIndex]
}

private func variantIsOwned(_ variant: OPNCatalogGameVariantObject) -> Bool {
    OPNGameCatalogMetadataSupport.variantIsOwned(inLibrary: variant.inLibrary, librarySelected: variant.librarySelected, serviceStatus: variant.serviceStatus)
}

private func gameNeedsPurchase(_ item: OPNGameCatalogItemModel) -> Bool {
    if let selectedVariant = variant(at: item.selectedVariantIndex, in: item.gameObject) { return !variantIsOwned(selectedVariant) }
    return item.gameObject.variants.contains { !variantIsOwned($0) }
}

private func primaryActionTitle(_ item: OPNGameCatalogItemModel) -> String {
    OPNGameCatalogMetadataSupport.primaryActionTitle(needsPurchase: gameNeedsPurchase(item), prominent: false)
}

private func gameProfileAppId(_ item: OPNGameCatalogItemModel) -> String {
    if let selectedVariant = variant(at: item.selectedVariantIndex, in: item.gameObject), !selectedVariant.id.isEmpty { return selectedVariant.id }
    if !item.gameObject.launchAppId.isEmpty { return item.gameObject.launchAppId }
    return item.gameObject.id
}

private func variantCanBeMarkedUnowned(_ item: OPNGameCatalogItemModel) -> Bool {
    guard let selectedVariant = variant(at: item.selectedVariantIndex, in: item.gameObject), !selectedVariant.id.isEmpty else { return false }
    return variantIsOwned(selectedVariant)
}
