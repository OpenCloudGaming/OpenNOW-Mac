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
        catalogModel.focusedTileID = catalogModel.focusedItem?.id
    }

    func moveGamepadFocusByRows(_ rowDelta: Int, columns columnDelta: Int) {
        catalogModel.moveFocus(rowDelta: rowDelta, columnDelta: columnDelta)
        scrollFocusedTileIntoView()
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

    func moveFocus(rowDelta: Int, columnDelta: Int) {
        guard !sections.isEmpty else { return }
        let nextRow = OPNGameCatalogLayoutSupport.clampedIndex(index: focusedRowIndex + rowDelta, count: sections.count)
        guard !sections[nextRow].games.isEmpty else { return }
        var nextColumn = focusedColumnIndex + columnDelta
        if nextRow != focusedRowIndex && columnDelta == 0 { nextColumn = min(nextColumn, sections[nextRow].games.count - 1) }
        focusedRowIndex = nextRow
        focusedColumnIndex = OPNGameCatalogLayoutSupport.clampedIndex(index: nextColumn, count: sections[nextRow].games.count)
        focusedTileID = sections[focusedRowIndex].games[focusedColumnIndex].id
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
                ScrollViewReader { proxy in
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
                                    catalogSections(proxy: proxy)
                                }
                            }
                        }
                        .padding(.bottom, 88)
                    }
                    .onChange(of: model.focusedTileID) { _, tileID in
                        guard let tileID else { return }
                        withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(tileID, anchor: .center) }
                    }
                }
                catalogSearch
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, searchTopPadding(for: viewport.size))
                controllerHints
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 18)
            }
        }
    }

    private var catalogSearch: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color(nsColor: OPNUIHelpers.color(rgb: OPNViewColor.brandGreen, alpha: 1)))
            TextField("Search library and store titles", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(nsColor: OPNUIHelpers.color(rgb: OPNViewColor.textPrimary, alpha: 1)))
                .onChange(of: model.searchText) { _, query in onSearchChanged(query) }
        }
        .padding(.horizontal, 15)
        .frame(width: 420, height: 44)
        .background(Color.black.opacity(0.64), in: Capsule())
        .overlay(Capsule().stroke(Color(nsColor: OPNUIHelpers.color(rgb: OPNViewColor.brandGreen, alpha: 0.34)), lineWidth: 1))
    }

    private func heroView(_ item: OPNGameCatalogItemModel, viewportSize: CGSize) -> some View {
        Button { onSelect(item) } label: {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    OPNCatalogArtworkView(urlStrings: Self.heroImageCandidates(for: item.gameObject), contentMode: .fill)
                        .overlay(LinearGradient(colors: [.black.opacity(0.10), .black.opacity(0.08), .black.opacity(0.54)], startPoint: .top, endPoint: .bottom))
                        .overlay(LinearGradient(colors: [.black.opacity(0.42), .black.opacity(0.10), .clear], startPoint: .leading, endPoint: .trailing))
                    heroIdentity(item)
                        .frame(width: min(OPNGameCatalogLayoutSupport.storeHeroLogoMaxWidth, max(160, geometry.size.width - heroHorizontalInset(for: geometry.size.width) * 2)), height: min(OPNGameCatalogLayoutSupport.storeHeroLogoMaxHeight, max(56, geometry.size.height * 0.44)), alignment: .leading)
                        .padding(.leading, heroHorizontalInset(for: geometry.size.width))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    Rectangle()
                        .fill(Color(nsColor: OPNUIHelpers.color(rgb: OPNViewColor.brandGreen, alpha: 0.88)))
                        .frame(width: 5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            }
            .frame(height: OPNGameCatalogLayoutSupport.heroHeight(forWidth: viewportSize.width, viewportHeight: viewportSize.height))
            .clipShape(RoundedRectangle(cornerRadius: 0, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func heroIdentity(_ item: OPNGameCatalogItemModel) -> some View {
        OPNCatalogLogoView(urlStrings: Self.logoCandidates(for: item.gameObject), fallbackTitle: item.gameObject.title.isEmpty ? "Untitled" : item.gameObject.title)
    }

    private func catalogSections(proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 28) {
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
                    .padding(.horizontal, horizontalInset)

                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: OPNGameCatalogLayoutSupport.storeCardSpacing) {
                            ForEach(Array(section.games.enumerated()), id: \.element.id) { columnIndex, item in
                                OPNCatalogTileView(
                                    item: item,
                                    focused: model.focusedRowIndex == rowIndex && model.focusedColumnIndex == columnIndex,
                                    onSelect: { onSelect(model.item(withID: item.id) ?? item) },
                                    onHover: {
                                        model.focusedRowIndex = rowIndex
                                        model.focusedColumnIndex = columnIndex
                                        model.focusedTileID = item.id
                                    },
                                    onVariantSelected: { variantIndex in model.setVariant(itemID: item.id, variantIndex: variantIndex) },
                                    onMarkUnowned: { onMarkUnowned(model.item(withID: item.id) ?? item) }
                                )
                                .id(item.id)
                                .frame(width: OPNGameCatalogLayoutSupport.storeTileWidth, height: OPNGameCatalogLayoutSupport.storeTileHeight)
                            }
                        }
                        .padding(.horizontal, horizontalInset)
                        .padding(.vertical, 10)
                    }
                    .background(Color.white.opacity(0.032), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.white.opacity(0.055), lineWidth: 1))
                    .padding(.horizontal, max(12, horizontalInset - 18))
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

    private var horizontalInset: CGFloat { 58 }

    private func searchTopPadding(for viewportSize: CGSize) -> CGFloat {
        let scale = viewportSize.height <= 760 ? 0.82 : (viewportSize.height < 900 ? 0.92 : 1.0)
        return floor((140 * scale - 44 * scale) * 0.5)
    }

    private func heroHorizontalInset(for width: CGFloat) -> CGFloat {
        min(OPNGameCatalogLayoutSupport.heroContentInset(forWidth: width), max(24, width * 0.08))
    }

    private static func heroImageCandidates(for game: OPNCatalogGameObject) -> [String] {
        imageCandidates(for: game, preferredTypes: ["MARQUEE_HERO_IMAGE", "HERO_IMAGE", "TV_BANNER", "FEATURE_IMAGE", "KEY_ART", "KEY_IMAGE", "GAME_BOX_ART"], includeScreenshots: true)
    }

    private static func logoCandidates(for game: OPNCatalogGameObject) -> [String] {
        imageCandidates(for: game, preferredTypes: ["GAME_LOGO", "LOGO", "TITLE_LOGO"], includeScreenshots: false)
    }
}

private struct OPNCatalogTileView: View {
    let item: OPNGameCatalogItemModel
    let focused: Bool
    let onSelect: () -> Void
    let onHover: () -> Void
    let onVariantSelected: (Int32) -> Void
    let onMarkUnowned: () -> Void

    var body: some View {
        Button(action: onSelect) {
            ZStack(alignment: .bottomLeading) {
                OPNCatalogArtworkView(urlStrings: imageCandidates(for: item.gameObject, preferredTypes: ["TV_BANNER", "HERO_IMAGE", "KEY_IMAGE", "KEY_ART", "GAME_BOX_ART", "FEATURE_IMAGE"], includeScreenshots: false), contentMode: .fill)
                    .overlay(LinearGradient(colors: [.black.opacity(0.02), .black.opacity(0.12), .black.opacity(0.82)], startPoint: .top, endPoint: .bottom))
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) { storeBadges }
                    Spacer(minLength: 0)
                    Text(item.gameObject.title.isEmpty ? "Untitled" : item.gameObject.title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color(nsColor: OPNUIHelpers.color(rgb: OPNViewColor.textPrimary, alpha: 1)))
                        .lineLimit(1)
                    Text(primaryActionTitle(item).uppercased())
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(Color(nsColor: OPNUIHelpers.color(rgb: OPNViewColor.accentOn, alpha: 1)))
                        .frame(width: 54, height: 28)
                        .background(Color(nsColor: OPNUIHelpers.color(rgb: OPNViewColor.brandGreen, alpha: 0.98)), in: Capsule())
                        .opacity(focused ? 1 : 0)
                }
                .padding(12)
                Rectangle()
                    .fill(Color(nsColor: OPNUIHelpers.color(rgb: OPNViewColor.brandGreen, alpha: 0.96)))
                    .frame(height: 3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .background(Color(nsColor: OPNUIHelpers.color(rgb: 0x070A0C, alpha: 0.92)))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(focused ? Color(nsColor: OPNUIHelpers.color(rgb: OPNViewColor.brandGreen, alpha: 0.98)) : .white.opacity(0.12), lineWidth: focused ? 2.5 : 1.25))
            .shadow(color: focused ? Color(nsColor: OPNUIHelpers.color(rgb: OPNViewColor.brandGreen, alpha: 0.38)) : .clear, radius: focused ? 26 : 0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in if hovering { onHover() } }
        .contextMenu { contextMenu }
    }

    @ViewBuilder
    private var storeBadges: some View {
        let stores = variantStores(item.gameObject)
        ForEach(Array(stores.prefix(4).enumerated()), id: \.offset) { index, store in
            Button { onVariantSelected(Int32(index)) } label: {
                Text(storePrefix(store))
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(Color(nsColor: OPNUIHelpers.color(rgb: OPNViewColor.textPrimary, alpha: 0.88)))
                    .frame(width: 28, height: 28)
                    .background(index == Int(item.selectedVariantIndex) ? Color(nsColor: OPNUIHelpers.color(rgb: OPNViewColor.brandGreen, alpha: 0.24)) : Color.black.opacity(0.72), in: Circle())
                    .overlay(Circle().stroke(index == Int(item.selectedVariantIndex) ? Color(nsColor: OPNUIHelpers.color(rgb: OPNViewColor.brandGreen, alpha: 0.96)) : .white.opacity(0.18), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        let appId = gameProfileAppId(item)
        Button("Save Current Stream Settings as Game Profile") {
            guard !appId.isEmpty else { return }
            OPNStreamPreferences.saveProfile(forGame: appId, profile: OPNStreamPreferences.loadProfile())
        }
        .disabled(appId.isEmpty)
        Button("Use Game Stream Profile") {
            guard !appId.isEmpty, OPNStreamPreferences.profileExists(forGame: appId) else { return }
            OPNStreamPreferences.setProfileEnabled(forGame: appId, enabled: !OPNStreamPreferences.profileEnabled(forGame: appId))
        }
        .disabled(appId.isEmpty || !OPNStreamPreferences.profileExists(forGame: appId))
        Button("Delete Game Stream Profile") {
            guard !appId.isEmpty else { return }
            OPNStreamPreferences.deleteProfile(forGame: appId)
        }
        .disabled(appId.isEmpty || !OPNStreamPreferences.profileExists(forGame: appId))
        if variantCanBeMarkedUnowned(item) {
            Divider()
            Button("Mark Selected Store as Unowned", action: onMarkUnowned)
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

private struct OPNCatalogLogoView: View {
    let urlStrings: [String]
    let fallbackTitle: String

    var body: some View {
        if let urlString = urlStrings.first, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .shadow(color: .black.opacity(0.90), radius: 18, y: 2)
                default:
                    fallback
                }
            }
        } else {
            fallback
        }
    }

    private var fallback: some View {
        Text(fallbackTitle)
            .font(.system(size: 42, weight: .black))
            .foregroundStyle(Color(nsColor: OPNUIHelpers.color(rgb: OPNViewColor.textPrimary, alpha: 1)))
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .shadow(color: .black.opacity(0.82), radius: 18, y: 2)
    }
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
