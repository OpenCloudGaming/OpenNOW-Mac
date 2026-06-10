import AppKit

private func opnSmoothstep(_ value: CGFloat) -> CGFloat {
    let x = max(0.0, min(1.0, value))
    return x * x * (3.0 - 2.0 * x)
}

@objc(OPNCarouselFocusLayout)
final class OPNCarouselFocusLayout: NSCollectionViewLayout {
    @objc var itemSize = NSSize(width: 164.0, height: 164.0)
    @objc var itemSpacing: CGFloat = 26.0
    @objc var sideInset: CGFloat = 64.0
    @objc var focusScale: CGFloat = 1.0
    @objc var minimumScale: CGFloat = 1.0
    @objc var minimumAlpha: CGFloat = 0.48

    private var cachedAttributes: [NSCollectionViewLayoutAttributes] = []
    private var cachedContentSize = NSSize.zero

    override init() {
        super.init()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func prepare() {
        super.prepare()
        cachedAttributes.removeAll()

        guard let collectionView else {
            cachedContentSize = .zero
            return
        }

        let sectionCount = collectionView.numberOfSections
        let itemCount = sectionCount > 0 ? collectionView.numberOfItems(inSection: 0) : 0
        let bounds = collectionView.bounds
        let centerY = floor(bounds.midY)
        var x = sideInset

        for item in 0..<itemCount {
            let indexPath = IndexPath(item: item, section: 0)
            let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
            attributes.frame = NSRect(x: x, y: centerY - itemSize.height * 0.5, width: itemSize.width, height: itemSize.height)
            attributes.zIndex = item
            cachedAttributes.append(attributes)
            x += itemSize.width + itemSpacing
        }

        let contentWidth = sideInset + CGFloat(itemCount) * itemSize.width + CGFloat(max(0, itemCount - 1)) * itemSpacing + sideInset
        cachedContentSize = NSSize(width: max(bounds.width, contentWidth), height: max(bounds.height, itemSize.height))
    }

    override var collectionViewContentSize: NSSize {
        cachedContentSize
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        guard let collectionView else { return [] }

        let visibleRect = collectionView.enclosingScrollView?.contentView.bounds ?? collectionView.bounds
        let viewportCenterX = visibleRect.midX
        let influenceRadius = max(1.0, visibleRect.width * 0.48)
        let expandedRect = rect.insetBy(dx: -itemSize.width, dy: -itemSize.height)
        var visibleAttributes: [NSCollectionViewLayoutAttributes] = []

        for baseAttributes in cachedAttributes where baseAttributes.frame.intersects(expandedRect) {
            guard let attributes = baseAttributes.copy() as? NSCollectionViewLayoutAttributes else { continue }
            let distance = abs(baseAttributes.frame.midX - viewportCenterX)
            let proximity = 1.0 - min(1.0, distance / influenceRadius)
            let prominence = opnSmoothstep(proximity)
            let scale = minimumScale + (focusScale - minimumScale) * prominence
            let width = itemSize.width * scale
            let height = itemSize.height * scale
            let midX = baseAttributes.frame.midX
            let midY = baseAttributes.frame.midY

            attributes.frame = NSRect(x: floor(midX - width * 0.5), y: floor(midY - height * 0.5), width: width, height: height)
            attributes.alpha = minimumAlpha + (1.0 - minimumAlpha) * prominence
            attributes.zIndex = Int((prominence * 1000.0).rounded())
            visibleAttributes.append(attributes)
        }

        return visibleAttributes
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.item >= 0, indexPath.item < cachedAttributes.count else { return nil }
        return cachedAttributes[indexPath.item].copy() as? NSCollectionViewLayoutAttributes
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        true
    }

    override func targetContentOffset(forProposedContentOffset proposedContentOffset: NSPoint, withScrollingVelocity velocity: NSPoint) -> NSPoint {
        guard let collectionView, !cachedAttributes.isEmpty else { return proposedContentOffset }

        let bounds = collectionView.bounds
        let proposedCenterX = proposedContentOffset.x + bounds.width * 0.5
        var nearestDistance = CGFloat.greatestFiniteMagnitude
        var nearestCenterX = proposedCenterX

        for attributes in cachedAttributes {
            let distance = abs(attributes.frame.midX - proposedCenterX)
            if distance < nearestDistance {
                nearestDistance = distance
                nearestCenterX = attributes.frame.midX
            }
        }

        var targetX = nearestCenterX - bounds.width * 0.5
        targetX = max(0.0, min(targetX, max(0.0, cachedContentSize.width - bounds.width)))
        return NSPoint(x: targetX, y: proposedContentOffset.y)
    }
}
