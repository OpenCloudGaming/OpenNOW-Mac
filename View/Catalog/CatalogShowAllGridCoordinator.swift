import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class CatalogShowAllGridCoordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
    private struct Update {
        let parent: CatalogShowAllGridView
        let scale: CGFloat
        let density: CGFloat
    }

    private var parent: CatalogShowAllGridView
    weak var collectionView: NSCollectionView?
    nonisolated(unsafe) var frameObserver: AppKitViewFrameObserver?
    private var pendingUpdate: Update?
    private var isUpdateScheduled = false
    private var gameIdentities: [String] = []
    private var selectedIdentity: String?
    private var lastWidth: CGFloat = 0
    private var lastViewportHeight: CGFloat = 0
    private var scale: CGFloat = 1
    private var density: CGFloat = 1
    private var isPosterLayout = false
    private var tileTitleVisibility: OPNThemePreferences.TileTitleVisibility = .onHover

    init(_ parent: CatalogShowAllGridView) {
        self.parent = parent
    }

    func update(_ parent: CatalogShowAllGridView, scale: CGFloat, density: CGFloat) {
        pendingUpdate = Update(parent: parent, scale: scale, density: density)
        scheduleLayoutUpdate()
    }

    func scheduleLayoutUpdate() {
        guard !isUpdateScheduled else { return }
        isUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isUpdateScheduled = false
            self.applyUpdate()
        }
    }

    func detach() {
        pendingUpdate = nil
        frameObserver = nil
        collectionView?.dataSource = nil
        collectionView?.delegate = nil
        collectionView = nil
    }

    private func applyUpdate() {
        guard let collectionView,
              let scrollView = collectionView.enclosingScrollView,
              let layout = collectionView.collectionViewLayout as? CatalogShowAllGridLayout else { return }
        let update = pendingUpdate
        pendingUpdate = nil
        if let update { parent = update.parent }

        let width = scrollView.contentView.bounds.width
        let viewportHeight = scrollView.contentView.bounds.height
        let isViewportChanged = lastWidth != width || lastViewportHeight != viewportHeight
        let previousDetailRowHeight = layout.detailRowHeight
        lastWidth = width
        lastViewportHeight = viewportHeight
        collectionView.frame.size.width = width
        let isSizingChanged = applySizing(to: layout, scale: update?.scale ?? scale, density: update?.density ?? density)
        let isGeometryChanged = isViewportChanged || previousDetailRowHeight != layout.detailRowHeight
        let selectedIdentity = parent.selectedGame?.catalogIdentity
        let selectedIndex = parent.games.firstIndex { $0.catalogIdentity == selectedIdentity }
        let isSelectionChanged = layout.selectedItemIndex != selectedIndex
        layout.selectedItemIndex = selectedIndex

        let identities = parent.games.map(\.catalogIdentity)
        let isFullReload = isSizingChanged || gameIdentities != identities
        if isFullReload {
            let renderStart = CFAbsoluteTimeGetCurrent()
            gameIdentities = identities
            self.selectedIdentity = selectedIdentity
            collectionView.reloadData()
            applyLayout(to: collectionView, layout: layout, isAnimated: false)
            let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - renderStart) * 1000)
            OPNLog.info(.catalog, "Show All grid reloaded items=\(parent.games.count) elapsed=\(elapsedMs)ms")
        }
        if !isFullReload {
            reloadSelectionAffectedItems(in: collectionView, selectedIdentity: selectedIdentity)
        }
        if !isFullReload, isSelectionChanged || isGeometryChanged {
            applyLayout(to: collectionView, layout: layout, isAnimated: isSelectionChanged)
        }
        collectionView.frame.size.height = layout.collectionViewContentSize.height
        if isViewportChanged { refreshDetailRows(in: collectionView) }
        if isSelectionChanged, let detailRowFrame = layout.detailRowFrame {
            collectionView.animator().scrollToVisible(detailRowFrame)
        }
    }

    private func applySizing(to layout: CatalogShowAllGridLayout, scale: CGFloat, density: CGFloat) -> Bool {
        let isPosterLayout = parent.isPosterLayout
        let tileTitleVisibility = parent.tileTitleVisibility
        let isSizingChanged = self.scale != scale || self.density != density
            || self.isPosterLayout != isPosterLayout || self.tileTitleVisibility != tileTitleVisibility
        self.scale = scale
        self.density = density
        self.isPosterLayout = isPosterLayout
        self.tileTitleVisibility = tileTitleVisibility
        layout.minTileWidth = isPosterLayout
            ? CatalogPosterLayout.posterTileWidth(scale: scale, density: density)
            : CatalogVendorLayout.wideTileWidth(scale: scale, density: density)
        layout.tileHeightRatio = isPosterLayout ? 1 / CatalogPosterLayout.aspectRatio : 9.0 / 16.0
        layout.spacing = CatalogVendorLayout.tileHorizontalMargin(scale: scale) * 2
        layout.detailRowHeight = CatalogVendorLayout.detailPanelHeight(for: lastWidth, viewportHeight: lastViewportHeight, scale: scale)
        return isSizingChanged
    }

    private func applyLayout(to collectionView: NSCollectionView, layout: CatalogShowAllGridLayout, isAnimated: Bool) {
        guard isAnimated else {
            layout.invalidateLayout()
            collectionView.layoutSubtreeIfNeeded()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            layout.invalidateLayout()
            collectionView.layoutSubtreeIfNeeded()
        }
    }

    private func reloadSelectionAffectedItems(in collectionView: NSCollectionView, selectedIdentity: String?) {
        guard self.selectedIdentity != selectedIdentity else { return }
        let oldIdentity = self.selectedIdentity
        self.selectedIdentity = selectedIdentity
        let indexPaths = Set([oldIdentity, selectedIdentity].compactMap { identity -> IndexPath? in
            guard let identity, let index = gameIdentities.firstIndex(of: identity) else { return nil }
            return IndexPath(item: index, section: 0)
        })
        guard !indexPaths.isEmpty else { return }
        collectionView.reloadItems(at: indexPaths)
    }

    private func refreshDetailRows(in collectionView: NSCollectionView) {
        for case let row as CatalogShowAllGridDetailRow in collectionView.visibleSupplementaryViews(ofKind: CatalogShowAllGridLayout.detailRowKind) {
            configure(detailRow: row)
        }
    }

    private func configure(detailRow: CatalogShowAllGridDetailRow) {
        detailRow.configure(
            detailPanel: GameDetailPanel(
                viewModel: parent.viewModel,
                availableWidth: lastWidth,
                viewportHeight: lastViewportHeight
            )
            .environment(\.opnUIScale, scale)
        )
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        parent.games.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(
            withIdentifier: NSUserInterfaceItemIdentifier(CatalogShowAllGridItem.reuseIdentifier),
            for: indexPath
        )
        guard let gridItem = item as? CatalogShowAllGridItem else { return item }
        configure(item: gridItem, game: parent.games[indexPath.item])
        return gridItem
    }

    private func configure(item: CatalogShowAllGridItem, game: OPNCatalogGameObject) {
        item.configure(
            game: game,
            imageURL: parent.imageURL(game),
            isSelected: parent.selectedGame?.catalogIdentity == game.catalogIdentity,
            isQueuedForPatching: parent.isQueuedForPatching(game),
            scale: scale,
            tileTitleVisibility: tileTitleVisibility,
            onSelect: { [weak self] in self?.parent.onSelect(game) },
            onPlay: { [weak self] in self?.parent.onPlay(game) },
            onMarkOwned: { [weak self] in self?.parent.onMarkOwned(game) },
            onQueueForPatching: { [weak self] in self?.parent.onQueueForPatching(game) }
        )
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> NSView {
        guard kind == CatalogShowAllGridLayout.detailRowKind else { return NSView() }
        let view = collectionView.makeSupplementaryView(
            ofKind: kind,
            withIdentifier: NSUserInterfaceItemIdentifier("CatalogShowAllGridDetailRow"),
            for: indexPath
        )
        if let detailRow = view as? CatalogShowAllGridDetailRow {
            configure(detailRow: detailRow)
        }
        return view
    }

    func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
        guard indexPath.item >= parent.games.count - 12 else { return }
        parent.viewModel.loadNextCatalogPage()
    }
}
