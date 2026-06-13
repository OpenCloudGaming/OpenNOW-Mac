import AppKit
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
    func setActiveSessionAppIds(_ appIds: [NSNumber]) {}

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

    let onSearchChanged: (String) -> Void
    let onSelect: (OPNGameCatalogItemModel) -> Void
    let onMarkUnowned: (OPNGameCatalogItemModel) -> Void

    var body: some View {
        GeometryReader { viewport in
            ZStack {
                Color.clear
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
                                    .padding(.bottom, OPNGameCatalogLayoutSupport.storeHeroFirstRowSpacing)
                            } else {
                                Color.clear.frame(height: 88)
                            }
                            if model.sections.isEmpty {
                                emptyState
                            } else {
                                catalogSections(viewportSize: viewport.size)
                            }
                        }
                    }
                    .padding(.bottom, 88)
                }
                .ignoresSafeArea(.container, edges: .top)
                catalogSearch(viewportSize: viewport.size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, searchTopPadding(for: viewport.size))
                    .ignoresSafeArea(.container, edges: .top)
                controllerHints
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 18)
            }
        }
    }

    private func catalogSearch(viewportSize: CGSize) -> some View {
        let panelSize = searchPanelSize(for: viewportSize)
        return HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color(nsColor: OPNUIHelpers.color(rgb: OPNViewColor.brandGreen, alpha: 1)))
                .frame(height: 30)
            TextField("Search library and store titles", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(nsColor: OPNUIHelpers.color(rgb: OPNViewColor.textPrimary, alpha: 1)))
                .frame(height: 30)
                .onChange(of: model.searchText) { _, query in onSearchChanged(query) }
        }
        .padding(.horizontal, 15)
        .frame(width: panelSize.width, height: panelSize.height)
        .background(Color.black.opacity(0.64), in: Capsule())
        .overlay(Capsule().stroke(Color(nsColor: OPNUIHelpers.color(rgb: OPNViewColor.brandGreen, alpha: 0.34)), lineWidth: 1))
    }

    private func heroView(_ item: OPNGameCatalogItemModel, viewportSize: CGSize) -> some View {
        OPNCatalogHeroStageView(item: item)
            .frame(height: OPNGameCatalogLayoutSupport.heroHeight(forWidth: viewportSize.width, viewportHeight: viewportSize.height))
    }

    private func catalogSections(viewportSize: CGSize) -> some View {
        let contentInset = horizontalInset(forWidth: viewportSize.width)
        let railWidth = max(320, max(980, viewportSize.width) - contentInset * 2)
        let tileSize = OPNGameCatalogLayoutSupport.tileMetrics(forRailWidth: railWidth)
        let rowOuterInset = max(12, contentInset - 18)
        return VStack(spacing: 28) {
            ForEach(Array(model.sections.enumerated()), id: \.element.id) { rowIndex, section in
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(String(format: "%02d", rowIndex + 1))
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(Color(nsColor: OPNUIHelpers.color(rgb: OPNViewColor.brandGreen, alpha: 1)))
                        Text(section.title)
                            .font(.system(size: 23, weight: .bold))
                            .foregroundStyle(Color(nsColor: OPNUIHelpers.color(rgb: OPNViewColor.textPrimary, alpha: 1)))
                        Spacer()
                        Text("\(section.games.count) games")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color(nsColor: OPNUIHelpers.color(rgb: 0x787A82, alpha: 1)))
                    }
                    .padding(.horizontal, contentInset)

                    ScrollViewReader { rowProxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: OPNGameCatalogLayoutSupport.storeCardSpacing) {
                                ForEach(Array(section.games.enumerated()), id: \.element.id) { columnIndex, item in
                                    OPNCatalogStoreTileView(
                                        item: item,
                                        focused: model.focusedRowIndex == rowIndex && model.focusedColumnIndex == columnIndex,
                                        focusScrollRequestToken: model.focusScrollRequestItemID == item.id ? model.focusScrollRequestToken : 0,
                                        onSelect: { selectedVariantIndex in
                                            model.setVariant(itemID: item.id, variantIndex: selectedVariantIndex)
                                            onSelect(model.item(withID: item.id) ?? OPNGameCatalogItemModel(gameObject: item.gameObject, selectedVariantIndex: selectedVariantIndex))
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
                            .padding(.trailing, 24)
                            .padding(.top, 10)
                            .padding(.bottom, 20)
                        }
                        .onChange(of: model.focusScrollRequestToken) { _, _ in
                            guard let itemID = model.focusScrollRequestItemID, section.games.contains(where: { $0.id == itemID }) else { return }
                            rowProxy.scrollTo(itemID, anchor: .center)
                        }
                    }
                    .frame(height: OPNGameCatalogLayoutSupport.storeTileHeight + 30)
                    .padding(.horizontal, 18)
                    .background(Color.white.opacity(0.032), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.white.opacity(0.055), lineWidth: 1))
                    .padding(.horizontal, rowOuterInset)
                }
            }
        }
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
        .padding(.horizontal, 20)
        .frame(height: 40)
        .background(Color.black.opacity(0.50), in: Capsule())
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(Color(nsColor: OPNUIHelpers.color(rgb: OPNViewColor.textPrimary, alpha: 0.92)))
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(nsColor: OPNUIHelpers.color(rgb: OPNViewColor.textSecondary, alpha: 1)))
        }
    }

    private func horizontalInset(forWidth width: CGFloat) -> CGFloat {
        OPNGameCatalogLayoutSupport.heroContentInset(forWidth: max(980.0, width))
    }

    private func searchPanelSize(for viewportSize: CGSize) -> CGSize {
        let scale = viewportSize.height <= 760 ? 0.82 : (viewportSize.height < 900 ? 0.92 : 1.0)
        let panelHeight = floor(44 * scale)
        let availableWidth = max(OPNGameCatalogLayoutSupport.storeSearchPanelMinWidth, viewportSize.width - 48)
        let panelWidth = min(OPNGameCatalogLayoutSupport.storeSearchPanelMaxWidth, availableWidth)
        return CGSize(width: panelWidth, height: panelHeight)
    }

    private func searchTopPadding(for viewportSize: CGSize) -> CGFloat {
        let scale = viewportSize.height <= 760 ? 0.82 : (viewportSize.height < 900 ? 0.92 : 1.0)
        return floor((140 * scale - searchPanelSize(for: viewportSize).height) * 0.5)
    }

}

private struct OPNCatalogStoreTileView: NSViewRepresentable {
    let item: OPNGameCatalogItemModel
    let focused: Bool
    let focusScrollRequestToken: Int
    let onSelect: (Int32) -> Void
    let onHover: () -> Void
    let onMarkUnowned: (Int32) -> Void

    final class Coordinator {
        var appliedFocusScrollRequestToken = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> OPNStoreGameTile {
        let tile = OPNStoreGameTile(frame: .zero, gameObject: item.gameObject, prominent: false)
        configure(tile)
        return tile
    }

    func updateNSView(_ nsView: OPNStoreGameTile, context: Context) {
        configure(nsView)
        if focusScrollRequestToken > 0 && context.coordinator.appliedFocusScrollRequestToken != focusScrollRequestToken {
            context.coordinator.appliedFocusScrollRequestToken = focusScrollRequestToken
            nsView.scrollIntoListingPosition()
        }
    }

    private func configure(_ tile: OPNStoreGameTile) {
        tile.selectedVariantIndex = item.selectedVariantIndex
        tile.setStoreFocused(focused)
        tile.ensureImageLoaded()
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
        artworkView.image = OPNUIHelpers.fallbackHeroArtworkImage()
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
        artworkTransitionView?.frame = bounds
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
        artworkView.image = OPNUIHelpers.fallbackHeroArtworkImage()
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
        guard animated, artworkView.image != nil, artworkView.superview != nil else {
            artworkTransitionView?.removeFromSuperview()
            artworkTransitionView = nil
            artworkView.image = image
            artworkView.alphaValue = 1.0
            updateLogoFrame()
            return
        }
        artworkTransitionView?.removeFromSuperview()
        let transitionView = OPNHeroArtworkView(frame: artworkView.frame)
        transitionView.autoresizingMask = [.width, .height]
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
