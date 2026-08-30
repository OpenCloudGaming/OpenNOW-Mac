import AppKit
import SwiftUI

struct CatalogShowAllGridView: NSViewRepresentable {
    typealias NSViewType = NSScrollView

    let viewModel: CatalogViewModel
    let games: [OPNCatalogGameObject]
    let selectedGame: OPNCatalogGameObject?
    let isQueuedForPatching: (OPNCatalogGameObject) -> Bool
    let imageURL: (OPNCatalogGameObject) -> URL?
    let onSelect: (OPNCatalogGameObject) -> Void
    let onPlay: (OPNCatalogGameObject) -> Void
    let onMarkOwned: (OPNCatalogGameObject) -> Void
    let onQueueForPatching: (OPNCatalogGameObject) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let collectionView = NSCollectionView()
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.isSelectable = false
        collectionView.allowsMultipleSelection = false
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [NSColor.clear]
        collectionView.autoresizingMask = [.width]
        let layout = CatalogShowAllGridLayout()
        collectionView.collectionViewLayout = layout
        collectionView.register(CatalogShowAllGridItem.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier(CatalogShowAllGridItem.reuseIdentifier))
        collectionView.register(
            CatalogShowAllGridDetailRow.self,
            forSupplementaryViewOfKind: CatalogShowAllGridLayout.detailRowKind,
            withIdentifier: NSUserInterfaceItemIdentifier("CatalogShowAllGridDetailRow")
        )
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        context.coordinator.collectionView = collectionView

        // The column count is derived from the scroll view's width. SwiftUI may hand us our final
        // width only after the first updateNSView (which happens synchronously for local collection
        // Show All), so track the clip view's frame changes and re-lay out when the width settles or
        // the window is resized. Without this the grid can get stuck at its initial narrow width.
        context.coordinator.frameObserver = AppKitViewFrameObserver(view: scrollView.contentView) { [weak coordinator = context.coordinator] in
            coordinator?.handleWidthChange()
        }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let collectionView = nsView.documentView as? NSCollectionView,
              let layout = collectionView.collectionViewLayout as? CatalogShowAllGridLayout else { return }
        context.coordinator.parent = self

        let width = nsView.contentView.bounds.width
        let widthChanged = context.coordinator.lastWidth != width
        context.coordinator.lastWidth = width
        collectionView.frame.size.width = width

        let scale = context.environment.opnUIScale
        let scaleChanged = context.coordinator.scale != scale
        context.coordinator.scale = scale

        layout.minTileWidth = CatalogVendorLayout.wideTileWidth(scale: scale)
        layout.spacing = CatalogVendorLayout.tileHorizontalMargin(scale: scale) * 2
        context.coordinator.lastViewportHeight = nsView.contentView.bounds.height
        layout.detailRowHeight = CatalogVendorLayout.detailPanelHeight(for: width, viewportHeight: nsView.contentView.bounds.height, scale: scale)

        let selectedIdentity = selectedGame?.catalogIdentity
        let selectedIndex = games.firstIndex { $0.catalogIdentity == selectedIdentity }
        let selectedIndexChanged = layout.selectedItemIndex != selectedIndex
        layout.selectedItemIndex = selectedIndex

        let needsFullReload = scaleChanged || context.coordinator.needsIdentityUpdate(for: games)
        if needsFullReload {
            let renderStart = CFAbsoluteTimeGetCurrent()
            context.coordinator.updateGameIdentities(from: games)
            collectionView.reloadData()
            if widthChanged || scaleChanged {
                layout.invalidateLayout()
            }
            collectionView.layoutSubtreeIfNeeded()
            let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - renderStart) * 1000)
            OpenNOWLog.info(.catalog, "Show All grid reloaded items=\(games.count) elapsed=\(elapsedMs)ms")
        } else if selectedIndexChanged || widthChanged {
            layout.invalidateLayout()
            collectionView.layoutSubtreeIfNeeded()
            if selectedIndexChanged, let detailRowFrame = layout.detailRowFrame {
                collectionView.scrollToVisible(detailRowFrame)
            }
        } else if context.coordinator.selectedIdentity != selectedIdentity {
            let oldIdentity = context.coordinator.selectedIdentity
            context.coordinator.selectedIdentity = selectedIdentity
            var indexPathsToReload = Set<IndexPath>()
            if let oldIdentity {
                if let oldIndex = context.coordinator.gameIdentities.firstIndex(of: oldIdentity) {
                    indexPathsToReload.insert(IndexPath(item: oldIndex, section: 0))
                }
            }
            if let newIdentity = selectedIdentity {
                if let newIndex = context.coordinator.gameIdentities.firstIndex(of: newIdentity) {
                    indexPathsToReload.insert(IndexPath(item: newIndex, section: 0))
                }
            }
            if !indexPathsToReload.isEmpty {
                collectionView.reloadItems(at: indexPathsToReload)
            }
        }

        let contentSize = layout.collectionViewContentSize
        collectionView.frame.size.height = contentSize.height
    }

    func makeCoordinator() -> CatalogShowAllGridCoordinator {
        CatalogShowAllGridCoordinator(self)
    }
}

@MainActor
final class CatalogShowAllGridCoordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
    var parent: CatalogShowAllGridView
    weak var collectionView: NSCollectionView?
    var gameIdentities: [String] = []
    var selectedIdentity: String?
    var lastWidth: CGFloat = 0
    var lastViewportHeight: CGFloat = 0
    var scale: CGFloat = 1.0
    nonisolated(unsafe) var frameObserver: AppKitViewFrameObserver?
    private var gameCount = 0
    private var firstIdentity: String = ""
    private var lastIdentity: String = ""

    init(_ parent: CatalogShowAllGridView) {
        self.parent = parent
    }


    /// Re-lays out the grid when the enclosing scroll view's width changes so the column count and
    /// document width always match the available space.
    func handleWidthChange() {
        guard let collectionView,
              let scrollView = collectionView.enclosingScrollView,
              let layout = collectionView.collectionViewLayout as? CatalogShowAllGridLayout else { return }
        let width = scrollView.contentView.bounds.width
        let viewportHeight = scrollView.contentView.bounds.height
        let detailRowHeight = CatalogVendorLayout.detailPanelHeight(for: width, viewportHeight: viewportHeight, scale: scale)
        guard width > 0, width != lastWidth || detailRowHeight != layout.detailRowHeight else { return }
        lastWidth = width
        lastViewportHeight = viewportHeight
        layout.detailRowHeight = detailRowHeight
        collectionView.frame.size.width = width
        layout.invalidateLayout()
        collectionView.layoutSubtreeIfNeeded()
        collectionView.frame.size.height = layout.collectionViewContentSize.height
        refreshDetailRows()
    }

    /// Re-hosts the detail panel so it picks up the new width/height after a resize.
    private func refreshDetailRows() {
        guard let collectionView else { return }
        for case let row as CatalogShowAllGridDetailRow in collectionView.visibleSupplementaryViews(ofKind: CatalogShowAllGridLayout.detailRowKind) {
            configure(detailRow: row)
        }
    }

    func configure(detailRow: CatalogShowAllGridDetailRow) {
        detailRow.configure(
            detailPanel: GameDetailPanel(
                viewModel: parent.viewModel,
                availableWidth: lastWidth,
                viewportHeight: lastViewportHeight
            )
            .environment(\.opnUIScale, scale)
        )
    }

    func needsIdentityUpdate(for games: [OPNCatalogGameObject]) -> Bool {
        let count = games.count
        if count != gameCount { return true }
        if count == 0 { return false }
        let first = games[0].catalogIdentity
        let last = games[count - 1].catalogIdentity
        return first != firstIdentity || last != lastIdentity
    }

    func updateGameIdentities(from games: [OPNCatalogGameObject]) {
        gameIdentities = games.map(\.catalogIdentity)
        gameCount = gameIdentities.count
        firstIdentity = gameIdentities.first ?? ""
        lastIdentity = gameIdentities.last ?? ""
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
        let game = parent.games[indexPath.item]
        configure(item: gridItem, game: game)
        return gridItem
    }

    private func configure(item: CatalogShowAllGridItem, game: OPNCatalogGameObject) {
        let selectedIdentity = parent.selectedGame?.catalogIdentity
        item.configure(
            game: game,
            imageURL: parent.imageURL(game),
            isSelected: selectedIdentity == game.catalogIdentity,
            isQueuedForPatching: parent.isQueuedForPatching(game),
            scale: scale,
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

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
    }

    func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
        guard indexPath.item >= parent.games.count - 12 else { return }
        parent.viewModel.loadNextCatalogPage()
    }
}

final class CatalogShowAllGridItem: NSCollectionViewItem {
    static let reuseIdentifier = "CatalogShowAllGridItem"

    private var hostingView: NSHostingView<AnyView>?

    override func loadView() {
        let view = NSView()
        view.wantsLayer = true
        self.view = view
    }

    func configure(
        game: OPNCatalogGameObject,
        imageURL: URL?,
        isSelected: Bool,
        isQueuedForPatching: Bool,
        scale: CGFloat,
        onSelect: @escaping () -> Void,
        onPlay: @escaping () -> Void,
        onMarkOwned: @escaping () -> Void,
        onQueueForPatching: @escaping () -> Void
    ) {
        let tile = AnyView(
            CatalogShowAllGridTile(
                game: game,
                imageURL: imageURL,
                isSelected: isSelected,
                isQueuedForPatching: isQueuedForPatching,
                onSelect: onSelect,
                onPlay: onPlay,
                onMarkOwned: onMarkOwned,
                onQueueForPatching: onQueueForPatching
            )
            .environment(\.opnUIScale, scale)
        )
        if let hostingView = hostingView {
            hostingView.rootView = tile
        } else {
            let hostingView = NSHostingView(rootView: tile)
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                hostingView.topAnchor.constraint(equalTo: view.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
            self.hostingView = hostingView
        }
    }
}

struct CatalogShowAllGridTile: View {
    let game: OPNCatalogGameObject
    let imageURL: URL?
    let isSelected: Bool
    let isQueuedForPatching: Bool
    let onSelect: () -> Void
    let onPlay: () -> Void
    let onMarkOwned: () -> Void
    let onQueueForPatching: () -> Void
    @State private var isHovering = false
    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        CatalogHoverTracker(onHover: { isHovering = $0 }) {
            ZStack(alignment: .topLeading) {
                tileContent
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect() }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(game.title.isEmpty ? "Game tile" : game.title)
                    .accessibilityAddTraits(.isButton)

                playButton
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .opacity(isHovering ? 1 : 0)
                    .allowsHitTesting(isHovering)
                    .accessibilityHidden(!isHovering)
                    .zIndex(2)
            }
            .scaleEffect(isHovering ? CatalogShowAllLayout.tileScaleFactor : 1.0)
            .animation(.easeOut(duration: 0.16), value: isHovering)
            .zIndex(isHovering ? 1 : 0)
        }
    }

    private var playButtonAction: () -> Void {
        if game.isLaunchPatching { return onQueueForPatching }
        return game.cardPrimaryActionIsLaunchable ? onPlay : onMarkOwned
    }

    private var playButtonTitle: String {
        if game.isLaunchPatching { return isQueuedForPatching ? "QUEUED" : "QUEUE" }
        return game.cardPrimaryActionIsLaunchable ? "PLAY" : "MARK OWNED"
    }

    private var playButtonIconName: String {
        if game.isLaunchPatching { return isQueuedForPatching ? "clock.fill" : "plus.circle.fill" }
        return game.cardPrimaryActionIsLaunchable ? "play.fill" : "checkmark.seal.fill"
    }

    private var playButton: some View {
        Button(action: playButtonAction) {
            HStack(spacing: 7) {
                Image(systemName: playButtonIconName)
                    .nvidiaFont(size: 10, weight: .bold)
                Text(playButtonTitle)
                    .nvidiaFont(size: 11, weight: .bold)
                    .tracking(0.9)
            }
            .foregroundStyle(game.isLaunchPatching ? (isQueuedForPatching ? OpenNOWDesign.accent.opacity(0.92) : .white.opacity(0.86)) : .black.opacity(0.88))
            .padding(.horizontal, 13 * uiScale)
            .frame(height: 30 * uiScale)
            .background(game.isLaunchPatching ? Color.black.opacity(0.62) : OpenNOWDesign.accent)
            .overlay { Rectangle().stroke(game.isLaunchPatching ? (isQueuedForPatching ? OpenNOWDesign.accent.opacity(0.55) : Color.white.opacity(0.30)) : OpenNOWDesign.accent, lineWidth: 1) }
            .shadow(color: .black.opacity(0.38), radius: 9, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(game.isLaunchPatching && isQueuedForPatching)
    }

    private var tileContent: some View {
        ZStack(alignment: .topLeading) {
            let isActive = isHovering || isSelected
            CatalogRemoteImage(url: imageURL, contentMode: .fill, maxPixelSize: 768)
                .clipped()
            if isActive {
                Color.black.opacity(0.50)
                LinearGradient(colors: [CatalogShowAllLayout.tileTray, CatalogShowAllLayout.tileTray.opacity(0)], startPoint: .bottom, endPoint: UnitPoint(x: 0.5, y: 0.63))
            }
            if let badge = game.cardBadgeLabel {
                CatalogGameCardBadge(label: badge)
            }
            if isActive {
                VStack {
                    Spacer(minLength: 0)
                    HStack(spacing: 8) {
                        Text(game.title.isEmpty ? "GeForce NOW" : game.title)
                            .nvidiaFont(size: 12, weight: isSelected ? .medium : .regular)
                            .lineLimit(1)
                            .foregroundStyle(.white.opacity(0.90))
                        Spacer(minLength: 0)
                        Image(systemName: isSelected ? "chevron.up" : "chevron.down")
                            .nvidiaFont(size: 10, weight: .bold)
                            .foregroundStyle(.white.opacity(0.76))
                    }
                    .padding(.horizontal, 16)
                    .frame(height: CatalogShowAllLayout.cardTrayHeight)
                    .background(CatalogShowAllLayout.tileTray.opacity(1))
                }
            }
        }
        .overlay(alignment: .bottom) {
            if isSelected {
                Rectangle()
                    .fill(OpenNOWDesign.accent)
                    .frame(height: 4)
            }
        }
        .shadow(color: isSelected ? .black.opacity(0.28) : .clear, radius: 5, x: 0, y: 3)
    }
}

final class CatalogShowAllGridLayout: NSCollectionViewLayout {
    static let detailRowKind = "CatalogShowAllGridDetailRow"

    var minTileWidth: CGFloat = CatalogVendorLayout.wideTileWidth(scale: 1.0)
    var spacing: CGFloat = CatalogVendorLayout.tileHorizontalMargin(scale: 1.0) * 2
    var detailRowHeight: CGFloat = CatalogVendorLayout.detailPanelMinHeight(scale: 1.0)
    var selectedItemIndex: Int?

    private var itemAttributes: [IndexPath: NSCollectionViewLayoutAttributes] = [:]
    private var detailRowAttributes: NSCollectionViewLayoutAttributes?
    private var contentSizeValue: NSSize = .zero

    var detailRowFrame: NSRect? {
        detailRowAttributes?.frame
    }

    override func prepare() {
        itemAttributes.removeAll()
        detailRowAttributes = nil
        guard let collectionView = collectionView else { return }
        let width = collectionView.frame.width
        let columns = max(2, Int((width + spacing) / (minTileWidth + spacing)))
        let totalSpacing = CGFloat(max(columns - 1, 0)) * spacing
        let itemWidth = floor(max(width - totalSpacing, minTileWidth * 2) / CGFloat(columns))
        let itemHeight = floor(itemWidth * 9 / 16)
        let itemSize = NSSize(width: itemWidth, height: itemHeight)
        let itemCount = collectionView.numberOfItems(inSection: 0)

        var x: CGFloat = 0
        var y: CGFloat = 0
        var itemCountInRow = 0
        var maxContentHeight: CGFloat = 0

        for index in 0..<itemCount {
            let indexPath = IndexPath(item: index, section: 0)
            let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
            attributes.frame = NSRect(x: x, y: y, width: itemSize.width, height: itemSize.height)
            itemAttributes[indexPath] = attributes
            maxContentHeight = max(maxContentHeight, y + itemSize.height)

            itemCountInRow += 1
            if itemCountInRow == columns {
                x = 0
                y += itemSize.height + spacing
                itemCountInRow = 0
            } else {
                x += itemSize.width + spacing
            }
        }

        if let selectedIndex = selectedItemIndex, itemCount > 0, selectedIndex >= 0, selectedIndex < itemCount {
            let selectedRow = selectedIndex / columns
            let selectedRowEndIndex = min((selectedRow + 1) * columns - 1, itemCount - 1)
            let endIndexPath = IndexPath(item: selectedRowEndIndex, section: 0)
            if let endAttributes = itemAttributes[endIndexPath] {
                let detailRowY = endAttributes.frame.maxY + spacing
                let detailIndexPath = IndexPath(item: 0, section: 0)
                let attributes = NSCollectionViewLayoutAttributes(forSupplementaryViewOfKind: CatalogShowAllGridLayout.detailRowKind, with: detailIndexPath)
                attributes.frame = NSRect(x: 0, y: detailRowY, width: width, height: detailRowHeight)
                detailRowAttributes = attributes

                let shift = detailRowHeight + spacing
                for index in (selectedRowEndIndex + 1)..<itemCount {
                    let indexPath = IndexPath(item: index, section: 0)
                    if let attr = itemAttributes[indexPath] {
                        attr.frame.origin.y += shift
                    }
                }
                maxContentHeight += shift
            }
        }

        contentSizeValue = NSSize(width: width, height: maxContentHeight)
    }

    override var collectionViewContentSize: NSSize { contentSizeValue }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        var result: [NSCollectionViewLayoutAttributes] = []
        for attr in itemAttributes.values {
            if attr.frame.intersects(rect) {
                result.append(attr)
            }
        }
        if let attr = detailRowAttributes, attr.frame.intersects(rect) {
            result.append(attr)
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        itemAttributes[indexPath]
    }

    override func layoutAttributesForSupplementaryView(ofKind kind: String, at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard kind == CatalogShowAllGridLayout.detailRowKind else { return nil }
        return detailRowAttributes
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        guard let collectionView = collectionView else { return false }
        return newBounds.width != collectionView.bounds.width
    }
}

final class CatalogShowAllGridDetailRow: NSView, NSCollectionViewElement {
    private var hostingView: NSHostingView<AnyView>?

    func configure(detailPanel: any View) {
        let rootView = AnyView(detailPanel)
        if let hostingView = hostingView {
            hostingView.rootView = rootView
        } else {
            let hostingView = NSHostingView(rootView: rootView)
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
                hostingView.topAnchor.constraint(equalTo: topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
            self.hostingView = hostingView
        }
    }
}

enum CatalogShowAllLayout {
    static let cardTrayHeight: CGFloat = 28
    static let tileScaleFactor: CGFloat = 1.04
    static let tileTray = Color(red: 18 / 255, green: 18 / 255, blue: 18 / 255)
}
