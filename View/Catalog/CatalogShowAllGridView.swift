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
    @Environment(\.opnUIScale) private var uiScale
    @AppStorage(OPNHomeLayout.modeKey) private var homeLayoutRawValue = OPNHomeLayout.Mode.classic.rawValue
    @AppStorage(OPNThemePreferences.tileTitleVisibilityKey) private var tileTitleVisibilityRawValue = OPNThemePreferences.TileTitleVisibility.onHover.rawValue

    var isPosterLayout: Bool {
        (OPNHomeLayout.Mode(rawValue: homeLayoutRawValue) ?? .classic) == .poster
    }

    var tileTitleVisibility: OPNThemePreferences.TileTitleVisibility {
        OPNThemePreferences.TileTitleVisibility(rawValue: tileTitleVisibilityRawValue) ?? .onHover
    }

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
            coordinator?.scheduleLayoutUpdate()
        }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(self, scale: uiScale, density: context.environment.opnTileDensity)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: CatalogShowAllGridCoordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> CatalogShowAllGridCoordinator {
        CatalogShowAllGridCoordinator(self)
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
        tileTitleVisibility: OPNThemePreferences.TileTitleVisibility,
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
                tileTitleVisibility: tileTitleVisibility,
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
    let tileTitleVisibility: OPNThemePreferences.TileTitleVisibility
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
                    .opnHoverScale(!isHovering, factor: 0.92)
                    .allowsHitTesting(isHovering)
                    .accessibilityHidden(!isHovering)
                    .zIndex(2)
            }
            .opnHoverScale(isHovering, factor: CatalogShowAllLayout.tileScaleFactor)
            .opnMotion(OPNDesign.Motion.hover, value: isHovering)
        }
        // Outside the tracker: the grid is the container whose children need ordering.
        .zIndex(isHovering ? 1 : 0)
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
                    .catalogFont(size: 10, weight: .bold)
                Text(playButtonTitle)
                    .catalogFont(size: 11, weight: .bold)
                    .tracking(0.9)
            }
            .foregroundStyle(game.isLaunchPatching ? (isQueuedForPatching ? OPNDesign.Fixed.accent.opacity(0.92) : OPNDesign.Text.primary) : .black.opacity(0.88))
            .padding(.horizontal, 13 * uiScale)
            .frame(height: 30 * uiScale)
            .background(game.isLaunchPatching ? Color.black.opacity(0.62) : OPNDesign.Fixed.accent)
            .overlay { Rectangle().stroke(game.isLaunchPatching ? (isQueuedForPatching ? OPNDesign.Fixed.accent.opacity(0.55) : OPNDesign.Fill.neutral(0.30)) : OPNDesign.Fixed.accent, lineWidth: 1) }
            .shadow(color: .black.opacity(0.38), radius: 9, x: 0, y: 4)
        }
        .buttonStyle(.opnPressable(scale: 0.94))
        .disabled(game.isLaunchPatching && isQueuedForPatching)
    }

    private var tileContent: some View {
        ZStack(alignment: .topLeading) {
            let showsTitleTray = OPNThemePreferences.showsTileTitle(visibility: tileTitleVisibility, isHovering: isHovering, isSelected: isSelected)
            // The grid decides the tile's size in its collection view layout, so the artwork has no
            // fixed frame the way the rails give it. A bare frame around an `.aspectRatio(.fill)`
            // image does not contain it: that image is not flexible, so the oversized result it
            // reports survives the frame, grows the whole ZStack, and drags the hover scrim and the
            // title tray into the grid's gutter - where they paint over, or fall behind, the
            // neighbouring item. `Color.clear` is flexible: it takes the tile's proposed size, and
            // clipping the artwork to it keeps every layer inside its own tile. Portrait poster art
            // is the case that actually overflows, which is why only Poster layout showed this.
            Color.clear
                .overlay {
                    CatalogRemoteImage(url: imageURL, contentMode: .fill, maxPixelSize: 768)
                }
                .clipped()
            if isHovering || isSelected {
                Color.black.opacity(0.50)
            }
            if showsTitleTray {
                LinearGradient(colors: [CatalogShowAllLayout.tileTray, CatalogShowAllLayout.tileTray.opacity(0)], startPoint: .bottom, endPoint: UnitPoint(x: 0.5, y: 0.63))
            }
            if let badge = game.cardBadgeLabel {
                CatalogGameCardBadge(label: badge)
            }
            if showsTitleTray {
                VStack {
                    Spacer(minLength: 0)
                    HStack(spacing: 8) {
                        Text(game.title.isEmpty ? "GeForce NOW" : game.title)
                            .catalogFont(size: 12, weight: isSelected ? .medium : .regular)
                            .lineLimit(1)
                            .foregroundStyle(OPNDesign.Text.primary)
                        Spacer(minLength: 0)
                        Image(systemName: isSelected ? "chevron.up" : "chevron.down")
                            .catalogFont(size: 10, weight: .bold)
                            .foregroundStyle(OPNDesign.Text.secondary)
                    }
                    .padding(.horizontal, 16 * uiScale)
                    .frame(height: CatalogShowAllLayout.cardTrayHeight * uiScale)
                    .background(CatalogShowAllLayout.tileTray.opacity(1))
                }
            }
        }
        .overlay(alignment: .bottom) {
            if isSelected {
                Rectangle()
                    .fill(OPNDesign.Fixed.accent)
                    .frame(height: 4)
            }
        }
        .shadow(color: isSelected ? .black.opacity(0.28) : .clear, radius: 5, x: 0, y: 3)
    }
}

final class CatalogShowAllGridLayout: NSCollectionViewLayout {
    static let detailRowKind = "CatalogShowAllGridDetailRow"

    var minTileWidth: CGFloat = CatalogVendorLayout.wideTileWidth(scale: 1.0)
    /// Tile height per point of width: 9/16 for the landscape tiles, 3/2 for portrait posters.
    var tileHeightRatio: CGFloat = 9.0 / 16.0
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
        let metrics = CatalogShowAllLayout.itemMetrics(forWidth: width, minTileWidth: minTileWidth, spacing: spacing, tileHeightRatio: tileHeightRatio)
        let columns = metrics.columns
        let horizontalInset = metrics.horizontalInset
        let verticalInset = metrics.verticalInset
        let itemSize = NSSize(width: metrics.itemSize.width, height: metrics.itemSize.height)
        let itemCount = collectionView.numberOfItems(inSection: 0)

        var x: CGFloat = horizontalInset
        var y: CGFloat = verticalInset
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
                x = horizontalInset
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

        contentSizeValue = NSSize(width: width, height: maxContentHeight + verticalInset)
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
    /// The rails' tray height, not a second one: a search result and a home tile are the same
    /// component and the bar was 12pt shorter here.
    static let cardTrayHeight = CatalogVendorLayout.cardTrayHeight(scale: 1)
    /// Deliberately gentler than the rails'. A rail spaces its tiles apart; this grid is an
    /// NSCollectionView, where each item is its own layer and the enlarged tile can neither be
    /// reordered over the one beside it nor draw outside the scroll view that clips it.
    static let tileScaleFactor: CGFloat = 1.04
    /// The home rails' tray token, not a second near-black of its own: the two trays sat side by
    /// side across a search and did not match.
    static let tileTray = CatalogVendorLayout.tileTray

    struct ItemMetrics: Equatable {
        let columns: Int
        let itemSize: CGSize
        let horizontalInset: CGFloat
        let verticalInset: CGFloat
    }

    /// Hover grows a tile about its centre, and the scroll view clips anything that leaves the
    /// grid, so the insets are the room that growth needs on all four sides.
    static func itemMetrics(forWidth width: CGFloat, minTileWidth: CGFloat, spacing: CGFloat, tileHeightRatio: CGFloat) -> ItemMetrics {
        let columns = max(2, Int((width + spacing) / (minTileWidth + spacing)))
        let totalSpacing = CGFloat(max(columns - 1, 0)) * spacing
        let growth = tileScaleFactor - 1
        let unpaddedItemWidth = max(width - totalSpacing, minTileWidth * 2) / CGFloat(columns)
        let horizontalInset = ceil(unpaddedItemWidth * growth / 2)
        let availableWidth = max(width - horizontalInset * 2, minTileWidth * 2)
        let itemWidth = floor(max(availableWidth - totalSpacing, minTileWidth * 2) / CGFloat(columns))
        let itemHeight = floor(itemWidth * tileHeightRatio)
        return ItemMetrics(
            columns: columns,
            itemSize: CGSize(width: itemWidth, height: itemHeight),
            horizontalInset: horizontalInset,
            verticalInset: ceil(itemHeight * growth / 2)
        )
    }
}
