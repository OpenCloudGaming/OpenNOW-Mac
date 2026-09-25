import AppKit
import SwiftUI
import Testing
@testable import OpenNOW

@Suite(.serialized, .disabled(if: CIWindowTestGate.isHostedRunner, Comment(rawValue: CIWindowTestGate.skipReason))) @MainActor
struct CatalogShowAllGridUpdateTests {
    @Test func updatesWaitUntilTheCurrentLayoutPassFinishes() async {
        let fixture = GridFixture()
        defer { fixture.close() }
        fixture.collectionView.onLayout = {
            fixture.coordinator.update(fixture.grid(), scale: 1.25, density: 1)
            fixture.coordinator.scheduleLayoutUpdate()
            #expect(fixture.collectionView.reloadCount == 0)
        }
        fixture.collectionView.needsLayout = true
        fixture.collectionView.layoutSubtreeIfNeeded()
        #expect(!fixture.collectionView.isLayoutReentered)

        await finishMainQueueTurn()

        #expect(fixture.collectionView.reloadCount == 1)
        #expect(fixture.collectionView.numberOfItems(inSection: 0) == fixture.games.count)
        #expect(!fixture.collectionView.isLayoutReentered)
    }

    @Test func queuedUpdatesApplyOneConsistentSnapshot() async throws {
        let fixture = GridFixture()
        defer { fixture.close() }
        fixture.coordinator.update(fixture.grid(selectedGame: fixture.games[0]), scale: 1.25, density: 1)
        let latestGames = Array(fixture.games.suffix(2))
        fixture.coordinator.update(fixture.grid(games: latestGames, selectedGame: latestGames[1]), scale: 1.5, density: 0.82)

        #expect(fixture.collectionView.reloadCount == 0)
        #expect(fixture.coordinator.collectionView(fixture.collectionView, numberOfItemsInSection: 0) == fixture.games.count)
        await finishMainQueueTurn()

        #expect(fixture.collectionView.reloadCount == 1)
        #expect(fixture.collectionView.numberOfItems(inSection: 0) == 2)
        #expect(fixture.layout.selectedItemIndex == 1)
        let expectedTileWidth = fixture.grid().isPosterLayout
            ? CatalogPosterLayout.posterTileWidth(scale: 1.5, density: 0.82)
            : CatalogVendorLayout.wideTileWidth(scale: 1.5, density: 0.82)
        #expect(fixture.layout.minTileWidth == expectedTileWidth)
        #expect(try #require(fixture.layout.detailRowFrame).width == fixture.scrollView.contentView.bounds.width)
        #expect(fixture.collectionView.frame.height == fixture.layout.collectionViewContentSize.height)
    }

    @Test func dismantlingDiscardsQueuedUpdates() async {
        let fixture = GridFixture()
        defer { fixture.close() }
        fixture.coordinator.update(fixture.grid(), scale: 1.5, density: 1)
        CatalogShowAllGridView.dismantleNSView(fixture.scrollView, coordinator: fixture.coordinator)

        await finishMainQueueTurn()

        #expect(fixture.collectionView.reloadCount == 0)
        #expect(fixture.collectionView.dataSource == nil)
        #expect(fixture.collectionView.delegate == nil)
        #expect(fixture.coordinator.frameObserver == nil)
    }

    @Test(arguments: [1.25, 1.5])
    func theHostedGridKeepsItsDetailRowAlignedAfterResizing(scale: CGFloat) async throws {
        let fixture = GridFixture()
        defer { fixture.close() }
        fixture.model.selectedGame = fixture.games[0]
        let hostingView = NSHostingView(rootView: fixture.grid(selectedGame: fixture.games[0]).environment(\.opnUIScale, scale))
        fixture.window.contentView = hostingView
        fixture.window.setContentSize(NSSize(width: 3000, height: 1200))
        fixture.window.orderFrontRegardless()
        await settleLayout(in: fixture.window)
        let collectionView = try #require(findCollectionView(in: hostingView))
        let layout = try #require(collectionView.collectionViewLayout as? CatalogShowAllGridLayout)
        let originalDetailHeight = try #require(layout.detailRowFrame).height

        fixture.window.setContentSize(NSSize(width: 3000, height: 600))
        await settleLayout(in: fixture.window)
        let scrollView = try #require(collectionView.enclosingScrollView)
        let detailFrame = try #require(layout.detailRowFrame)
        #expect(detailFrame.width == scrollView.contentView.bounds.width)
        #expect(detailFrame.height < originalDetailHeight)
        #expect(detailFrame.height == CatalogVendorLayout.detailPanelHeight(
            for: scrollView.contentView.bounds.width, viewportHeight: scrollView.contentView.bounds.height, scale: scale
        ))
        #expect(collectionView.frame.height == layout.collectionViewContentSize.height)

        fixture.window.setContentSize(NSSize(width: 1440, height: 900))
        await settleLayout(in: fixture.window)
        #expect(try #require(layout.detailRowFrame).width == scrollView.contentView.bounds.width)
        try capture(hostingView, name: "show-all-grid-\(scale).png")
        let expandedHeight = layout.collectionViewContentSize.height

        fixture.model.selectedGame = nil
        hostingView.rootView = fixture.grid().environment(\.opnUIScale, scale)
        await settleLayout(in: fixture.window)
        #expect(layout.detailRowFrame == nil)
        #expect(layout.collectionViewContentSize.height < expandedHeight)
        #expect(collectionView.frame.height == layout.collectionViewContentSize.height)
    }

    private func settleLayout(in window: NSWindow) async {
        window.layoutIfNeeded()
        await finishMainQueueTurn()
        window.layoutIfNeeded()
        await finishMainQueueTurn()
        window.displayIfNeeded()
    }

    private func finishMainQueueTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func findCollectionView(in view: NSView) -> NSCollectionView? {
        if let collectionView = view as? NSCollectionView { return collectionView }
        return view.subviews.lazy.compactMap { findCollectionView(in: $0) }.first
    }

    private func capture(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["OPN_SNAPSHOT_DIR"] else { return }
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = try #require(bitmap.representation(using: .png, properties: [:]))
        try image.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }
}

@MainActor
private final class GridFixture {
    let model = makeCatalogViewModelForTesting()
    let games: [OPNCatalogGameObject] = (0..<12).map { index in
        var game = OPNGameInfo()
        game.id = "layout-game-\(index)"
        game.title = "Layout Game \(index + 1)"
        return OPNCatalogGameObject(game: game)
    }
    let collectionView = LayoutRecordingCollectionView()
    let layout = CatalogShowAllGridLayout()
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    let window: NSWindow
    lazy var coordinator = CatalogShowAllGridCoordinator(grid())

    init() {
        model.isLoading = true
        window = NSWindow(contentRect: scrollView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = coordinator
        collectionView.delegate = coordinator
        collectionView.register(CatalogShowAllGridItem.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier(CatalogShowAllGridItem.reuseIdentifier))
        collectionView.register(
            CatalogShowAllGridDetailRow.self,
            forSupplementaryViewOfKind: CatalogShowAllGridLayout.detailRowKind,
            withIdentifier: NSUserInterfaceItemIdentifier("CatalogShowAllGridDetailRow")
        )
        scrollView.documentView = collectionView
        window.contentView = scrollView
        coordinator.collectionView = collectionView
    }

    func grid(games: [OPNCatalogGameObject]? = nil, selectedGame: OPNCatalogGameObject? = nil) -> CatalogShowAllGridView {
        CatalogShowAllGridView(
            viewModel: model, games: games ?? self.games, selectedGame: selectedGame,
            isQueuedForPatching: { _ in false }, imageURL: { _ in nil },
            onSelect: { _ in }, onPlay: { _ in }, onMarkOwned: { _ in }, onQueueForPatching: { _ in }
        )
    }

    func close() {
        coordinator.detach()
        window.close()
    }
}

@MainActor
private final class LayoutRecordingCollectionView: NSCollectionView {
    var onLayout: (() -> Void)?
    private var isLayingOut = false
    private(set) var isLayoutReentered = false
    private(set) var reloadCount = 0

    override func layout() {
        isLayingOut = true
        defer { isLayingOut = false }
        super.layout()
        let callback = onLayout
        onLayout = nil
        callback?()
    }

    override func layoutSubtreeIfNeeded() {
        isLayoutReentered = isLayoutReentered || isLayingOut
        super.layoutSubtreeIfNeeded()
    }

    override func reloadData() {
        reloadCount += 1
        super.reloadData()
    }
}
