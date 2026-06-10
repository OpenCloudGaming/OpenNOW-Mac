import AppKit
import GameController

@objcMembers
@objc(OPNGameCatalogView)
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
    var hasContent: Bool { rowCards.count > 0 || desktopFeaturedHeroViews.count > 0 }

    override init(frame frameRect: NSRect) {
        scrollView = NSScrollView(frame: frameRect)
        documentView = OPNStoreDocumentView(frame: NSRect(x: 0, y: 0, width: frameRect.width, height: frameRect.height))
        loadingView = OPNLoadingView(frame: frameRect, message: "Loading games...")
        statusLabel = OPNUIHelpers.label(text: "", frame: .zero, size: 15, color: OPNUIHelpers.color(rgb: 0x787A82, alpha: 1), weight: .medium, alignment: .center)
        buttonHintPillView = OPNStoreHintPillView(frame: .zero)
        buttonHintStackView = NSStackView(frame: .zero)
        searchPanelView = NSView(frame: .zero)
        searchField = NSSearchField(frame: .zero)
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
        let navClearance = OPNGameCatalogLayoutSupport.storeNavigationClearance
        scrollView.frame = NSRect(x: 0, y: navClearance, width: bounds.width, height: max(0, bounds.height - navClearance))
        loadingView.frame = bounds
        statusLabel.frame = NSRect(x: 0, y: bounds.height * 0.5, width: bounds.width, height: 26)
        documentView.frame = NSRect(x: 0, y: 0, width: max(980, bounds.width), height: max(documentView.frame.height, bounds.height))
        updateButtonHintPillFrame()
        updateDesktopHeroFrameForCurrentBounds()
        updateRowFramesForCurrentBounds()
        updateRowVirtualizationForVisibleBounds()
        if abs(lastLayoutWidth - bounds.width) > 1 || abs(lastLayoutHeight - bounds.height) > 1 {
            lastLayoutWidth = bounds.width
            lastLayoutHeight = bounds.height
            scheduleRenderStoreAfterResize()
        }
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
    func interfacePreferencesChanged(_ notification: Notification) { renderStore() }

    @objc(controllerConfigurationChanged:)
    func controllerConfigurationChanged(_ notification: Notification) { rebuildButtonHintPillForCurrentController() }

    func removeButtonHintGroups() {
        OPNGameCatalogLayoutSupport.removeButtonHintGroups(from: buttonHintStackView)
    }

    func rebuildButtonHintPillForCurrentController() {
        buttonHintControllerFamily = OPNGameCatalogLayoutSupport.rebuildButtonHintStackView(buttonHintStackView, currentFamily: buttonHintControllerFamily)
        updateButtonHintPillFrame()
    }

    func refreshLibrarySelections() {
        for case let row as [OPNStoreGameTile] in rowCards {
            for card in row { card.selectedVariantIndex = selectedVariantIndex(for: card.gameObject) }
        }
        updateFocusedTiles()
    }

    func updateFocusedTiles() {
        guard rowCards.count > 0 else { return }
        focusedRowIndex = OPNGameCatalogLayoutSupport.clampedIndex(index: focusedRowIndex, count: rowCards.count)
        guard let focusedRow = rowCards[focusedRowIndex] as? [OPNStoreGameTile], !focusedRow.isEmpty else { return }
        focusedColumnIndex = OPNGameCatalogLayoutSupport.clampedIndex(index: focusedColumnIndex, count: focusedRow.count)
        let nextFocusedTile = focusedRow[focusedColumnIndex]
        if focusedTile === nextFocusedTile {
            nextFocusedTile.setStoreFocused(true)
            return
        }
        focusedTile?.setStoreFocused(false)
        nextFocusedTile.setStoreFocused(true)
        focusedTile = nextFocusedTile
    }

    func scrollFocusedTileIntoView() {
        guard focusedRowIndex >= 0, focusedRowIndex < rowCards.count, let row = rowCards[focusedRowIndex] as? [OPNStoreGameTile] else { return }
        guard focusedColumnIndex >= 0, focusedColumnIndex < row.count else { return }
        let tile = row[focusedColumnIndex]
        let tileInDocument = tile.convert(tile.bounds, to: documentView)
        documentView.scrollToVisible(tileInDocument.insetBy(dx: -28, dy: -46))
        tile.scrollToVisible(tile.bounds.insetBy(dx: -24, dy: -12))
    }

    func moveGamepadFocusByRows(_ rowDelta: Int, columns columnDelta: Int) {
        guard rowCards.count > 0 else { return }
        let nextRow = OPNGameCatalogLayoutSupport.clampedIndex(index: focusedRowIndex + rowDelta, count: rowCards.count)
        guard let row = rowCards[nextRow] as? [OPNStoreGameTile], !row.isEmpty else { return }
        var nextColumn = focusedColumnIndex + columnDelta
        if nextRow != focusedRowIndex && columnDelta == 0 { nextColumn = min(nextColumn, row.count - 1) }
        nextColumn = OPNGameCatalogLayoutSupport.clampedIndex(index: nextColumn, count: row.count)
        guard nextRow != focusedRowIndex || nextColumn != focusedColumnIndex else { return }
        focusedRowIndex = nextRow
        focusedColumnIndex = nextColumn
        updateFocusedTiles()
        scrollFocusedTileIntoView()
    }

    func moveGamepadFocus(by delta: Int) { moveGamepadFocusByRows(0, columns: delta) }

    func activateGamepadFocus() {
        guard focusedRowIndex >= 0, focusedRowIndex < rowCards.count, let row = rowCards[focusedRowIndex] as? [OPNStoreGameTile] else { return }
        guard focusedColumnIndex >= 0, focusedColumnIndex < row.count else { return }
        row[focusedColumnIndex].activate()
    }

    func cycleFocusedGamepadVariant() {
        guard focusedRowIndex >= 0, focusedRowIndex < rowCards.count, let row = rowCards[focusedRowIndex] as? [OPNStoreGameTile] else { return }
        guard focusedColumnIndex >= 0, focusedColumnIndex < row.count else { return }
        row[focusedColumnIndex].cycleSelectedVariant()
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
        loadingView.isHidden = !showBlockingLoader
        buttonHintPillView.isHidden = showBlockingLoader
        statusLabel.stringValue = ""
        showBlockingLoader ? loadingView.startAnimating() : loadingView.stopAnimating()
    }

    func setError(_ message: String?) {
        heroRotationTimer?.invalidate()
        heroRotationTimer = nil
        setLoading(false)
        statusLabel.stringValue = message ?? ""
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
            refreshLibrarySelections()
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
        renderStoreWhenInitialHeroReady()
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
        hasContent ? updateDesktopFeaturedHeroOnly() : renderStoreWhenInitialHeroReady()
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
            if rowCards.count > 0 || desktopFeaturedHeroViews.count > 0 { refreshLibrarySelections() }
            return
        }
        if rowCards.count > 0 || desktopFeaturedHeroViews.count > 0 {
            refreshLibrarySelections()
            scheduleRenderStore()
        } else if !panelObjects.isEmpty || !Self.visibleLibraryGames(from: ownedLibraryGameObjects).isEmpty {
            renderStoreWhenInitialHeroReady()
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
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)
        documentView.wantsLayer = true
        scrollView.documentView = documentView
        scrollView.contentView.postsBoundsChangedNotifications = true
        addSubview(statusLabel)
        loadingView.autoresizingMask = [.width, .height]
        loadingView.isHidden = true
        addSubview(loadingView)
        buttonHintPillView.wantsLayer = true
        buttonHintPillView.layer?.backgroundColor = OPNUIHelpers.color(rgb: 0, alpha: 0.50).cgColor
        buttonHintPillView.layer?.cornerRadius = OPNGameCatalogLayoutSupport.storeButtonHintPillHeight * 0.5
        buttonHintPillView.layer?.masksToBounds = true
        addSubview(buttonHintPillView)
        buttonHintStackView.orientation = .horizontal
        buttonHintStackView.alignment = .centerY
        buttonHintStackView.distribution = .gravityAreas
        buttonHintStackView.spacing = 18
        buttonHintPillView.addSubview(buttonHintStackView)
        searchPanelView.wantsLayer = true
        searchPanelView.layer?.backgroundColor = OPNUIHelpers.color(rgb: 0, alpha: 0.64).cgColor
        searchPanelView.layer?.cornerRadius = 18
        searchPanelView.layer?.borderWidth = 1
        searchPanelView.layer?.borderColor = OPNUIHelpers.color(rgb: 0x34C759, alpha: 0.34).cgColor
        addSubview(searchPanelView, positioned: .above, relativeTo: nil)
        searchField.placeholderString = "Search library and store titles"
        searchField.delegate = self
        searchField.focusRingType = .none
        searchField.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        searchPanelView.addSubview(searchField)
        rebuildButtonHintPillForCurrentController()
        NotificationCenter.default.addObserver(self, selector: #selector(interfacePreferencesChanged(_:)), name: OPNInterfacePreferencesDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(storeScrollViewBoundsDidChange(_:)), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(controllerConfigurationChanged(_:)), name: .GCControllerDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(controllerConfigurationChanged(_:)), name: .GCControllerDidDisconnect, object: nil)
    }
}
