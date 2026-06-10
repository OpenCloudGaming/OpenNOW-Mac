import AppKit

extension OPNGameCatalogView {
    @objc func updateButtonHintPillFrame() {
        let availableWidth = max(0, bounds.width - 48)
        let pillWidth = min(680, max(360, availableWidth))
        let pillX = floor((bounds.width - pillWidth) * 0.5)
        let pillY = max(0, floor(bounds.height - OPNGameCatalogLayoutSupport.storeButtonHintPillBottomInset - OPNGameCatalogLayoutSupport.storeButtonHintPillHeight))
        buttonHintPillView.frame = NSRect(x: pillX, y: pillY, width: pillWidth, height: OPNGameCatalogLayoutSupport.storeButtonHintPillHeight)
        buttonHintPillView.layer?.cornerRadius = OPNGameCatalogLayoutSupport.storeButtonHintPillHeight * 0.5
        let stackSize = buttonHintStackView.fittingSize
        let stackWidth = min(stackSize.width, max(0, pillWidth - 36))
        let stackHeight = min(stackSize.height, max(0, OPNGameCatalogLayoutSupport.storeButtonHintPillHeight - 12))
        buttonHintStackView.frame = NSRect(x: floor((pillWidth - stackWidth) * 0.5), y: floor((OPNGameCatalogLayoutSupport.storeButtonHintPillHeight - stackHeight) * 0.5), width: stackWidth, height: stackHeight)
        updateSearchPanelFrame()
    }

    @objc func updateSearchPanelFrame() {
        let scale = bounds.height <= 760 ? 0.82 : (bounds.height < 900 ? 0.92 : 1.0)
        let panelHeight = floor(44 * scale)
        let availableWidth = max(OPNGameCatalogLayoutSupport.storeSearchPanelMinWidth, bounds.width - 48)
        let panelWidth = min(OPNGameCatalogLayoutSupport.storeSearchPanelMaxWidth, availableWidth)
        searchPanelView.frame = NSRect(x: floor((bounds.width - panelWidth) * 0.5), y: floor((140 * scale - panelHeight) * 0.5), width: panelWidth, height: panelHeight)
        searchPanelView.layer?.cornerRadius = panelHeight * 0.5
        searchField.frame = NSRect(x: 14, y: floor((panelHeight - 30) * 0.5), width: panelWidth - 28, height: 30)
    }

    @objc func scheduleRenderStore() {
        guard !renderStoreScheduled else { return }
        renderStoreScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.renderStoreScheduled = false
            self.renderStoreWhenInitialHeroReady()
        }
    }

    @objc func scheduleRenderStoreAfterResize() {
        guard hasContent else {
            scheduleRenderStore()
            return
        }
        updateDesktopHeroFrameForCurrentBounds()
        updateRowFramesForCurrentBounds()
        updateRowVirtualizationForVisibleBounds()
    }

    @objc func resizeRenderTimerFired(_ timer: Timer) {
        resizeRenderTimer = nil
        scheduleRenderStore()
    }

    @objc func renderStore() {
        cancelHeroImageLoads()
        for view in documentView.subviews { view.removeFromSuperview() }
        rowCards.removeAllObjects()
        rowLayouts.removeAllObjects()
        desktopFeaturedHeroViews.removeAllObjects()
        desktopHeroContainer = nil
        desktopHeroArtworkView = nil
        desktopHeroArtworkTransitionView = nil
        desktopHeroTitleFallback = nil
        desktopHeroLogoView = nil
        desktopHeroLogoTransitionView = nil
        desktopHeroIdentity = nil
        desktopFeaturedHeroFrame = .zero

        let viewportWidth = max(1, bounds.width)
        let width = max(980, viewportWidth)
        let contentX = OPNGameCatalogLayoutSupport.heroContentInset(forWidth: width)
        let contentWidth = max(680, width - contentX * 2)
        let topInset = OPNGameCatalogLayoutSupport.storeTopInset
        var rowY = topInset
        var renderedRows = 0
        let heroGame = currentHeroGameObject()

        if let heroGame {
            let heroHeight = OPNGameCatalogLayoutSupport.heroHeight(forWidth: viewportWidth, viewportHeight: bounds.height)
            addDesktopHeroStageForGameObject(heroGame, y: topInset, contentX: 0, width: viewportWidth, height: heroHeight)
            rowY = topInset + heroHeight + OPNGameCatalogLayoutSupport.storeHeroFirstRowSpacing
        }

        if !renderingVisibleLibraryGameObjects.isEmpty {
            let librarySection = OPNCatalogPanelSectionObject()
            librarySection.id = "owned-library"
            librarySection.title = "Library"
            librarySection.typeName = "CatalogSection"
            librarySection.games = renderingVisibleLibraryGameObjects
            addSection(librarySection, index: renderedRows, y: rowY, contentX: contentX, width: width)
            rowY = OPNGameCatalogLayoutSupport.nextRowY(afterRow: rowY, rowIndex: renderedRows, hasHero: heroGame != nil, viewportHeight: bounds.height)
            renderedRows += 1
        }

        for panel in renderingVisiblePanelObjects {
            for section in panel.sections where !section.games.isEmpty {
                addSection(section, index: renderedRows, y: rowY, contentX: contentX, width: width)
                rowY = OPNGameCatalogLayoutSupport.nextRowY(afterRow: rowY, rowIndex: renderedRows, hasHero: heroGame != nil, viewportHeight: bounds.height)
                renderedRows += 1
            }
        }

        if renderedRows == 0 && !loadingView.isHidden {
            statusLabel.stringValue = ""
        } else if renderedRows == 0 {
            statusLabel.stringValue = ""
            addEmptyStoreState(y: rowY, contentX: contentX, width: contentWidth)
            rowY += 260
        } else {
            statusLabel.stringValue = ""
        }

        documentView.frame = NSRect(x: 0, y: 0, width: width, height: max(bounds.height, rowY + 88))
        updateFocusedTiles()
        updateRowVirtualizationForVisibleBounds()
    }

    @objc(addEmptyStoreStateWithY:contentX:width:)
    func addEmptyStoreState(y: CGFloat, contentX: CGFloat, width: CGFloat) {
        let emptyPanel = NSView(frame: NSRect(x: contentX, y: y, width: width, height: 220))
        emptyPanel.wantsLayer = true
        emptyPanel.layer?.cornerRadius = 28
        emptyPanel.layer?.backgroundColor = OPNUIHelpers.color(rgb: 0xFFFFFF, alpha: 0.045).cgColor
        emptyPanel.layer?.borderWidth = 1
        emptyPanel.layer?.borderColor = OPNUIHelpers.color(rgb: 0xFFFFFF, alpha: 0.10).cgColor
        documentView.addSubview(emptyPanel)

        let eyebrow = OPNUIHelpers.label(text: "SIGNAL LOST", frame: NSRect(x: 0, y: 54, width: width, height: 18), size: 12, color: OPNUIHelpers.color(rgb: 0x34C759, alpha: 1), weight: .black, alignment: .center)
        emptyPanel.addSubview(eyebrow)
        let title = OPNUIHelpers.label(text: "No games found", frame: NSRect(x: 0, y: 78, width: width, height: 34), size: 27, color: OPNUIHelpers.color(rgb: 0xF5F5F7, alpha: 1), weight: .bold, alignment: .center)
        emptyPanel.addSubview(title)
        let subtitle = OPNUIHelpers.label(text: "The catalog returned no games. Try again after the service refreshes.", frame: NSRect(x: 0, y: 120, width: width, height: 22), size: 13, color: OPNUIHelpers.color(rgb: 0xB7B8BE, alpha: 1), weight: .medium, alignment: .center)
        emptyPanel.addSubview(subtitle)
    }

    @objc func updateDesktopHeroFrameForCurrentBounds() {
        guard let container = desktopHeroContainer, let artworkView = desktopHeroArtworkView, !desktopFeaturedHeroFrame.isEmpty else { return }
        let width = max(1, bounds.width)
        let height = OPNGameCatalogLayoutSupport.heroHeight(forWidth: width, viewportHeight: bounds.height)
        desktopFeaturedHeroFrame = NSRect(x: desktopFeaturedHeroFrame.minX, y: desktopFeaturedHeroFrame.minY, width: width, height: height)
        container.frame = desktopFeaturedHeroFrame
        artworkView.frame = container.bounds
        desktopHeroArtworkTransitionView?.frame = container.bounds
        updateDesktopHeroLogoFrame()
    }

    @objc func updateRowFramesForCurrentBounds() {
        let width = max(980, bounds.width)
        let contentX = OPNGameCatalogLayoutSupport.heroContentInset(forWidth: width)
        let availableWidth = max(320, width - contentX * 2)
        var rowY = desktopFeaturedHeroFrame.isEmpty ? OPNGameCatalogLayoutSupport.storeTopInset : desktopFeaturedHeroFrame.maxY + OPNGameCatalogLayoutSupport.storeHeroFirstRowSpacing
        let hasHero = !desktopFeaturedHeroFrame.isEmpty
        for (rowIndex, rowLayout) in rowLayouts.compactMap({ $0 as? OPNStoreRowLayout }).enumerated() {
            rowLayout.y = rowY
            let y = rowY
            rowLayout.glowView?.frame = NSRect(x: contentX - 18, y: y + 36, width: availableWidth + 36, height: OPNGameCatalogLayoutSupport.storeTileHeight + 44)
            rowLayout.indexLabel?.frame = NSRect(x: contentX, y: y + 5, width: 42, height: 18)
            rowLayout.titleLabel?.frame = NSRect(x: contentX + 42, y: y, width: availableWidth - 142, height: 30)
            rowLayout.hintLabel?.frame = NSRect(x: contentX + availableWidth - 110, y: y + 6, width: 110, height: 18)
            rowLayout.scrollView?.frame = NSRect(x: contentX, y: y + 48, width: availableWidth, height: OPNGameCatalogLayoutSupport.storeTileHeight + 30)
            let tileMetrics = OPNGameCatalogLayoutSupport.tileMetrics(forRailWidth: availableWidth)
            var x: CGFloat = 0
            for card in rowLayout.cards {
                card.frame = NSRect(x: x, y: 10, width: tileMetrics.width, height: tileMetrics.height)
                x += tileMetrics.width + OPNGameCatalogLayoutSupport.storeCardSpacing
            }
            let scrollWidth = rowLayout.scrollView?.frame.width ?? 0
            rowLayout.documentView?.frame = NSRect(x: 0, y: 0, width: max(x + 24, scrollWidth), height: OPNGameCatalogLayoutSupport.storeTileHeight + 30)
            updateImagePreloading(for: rowLayout)
            rowY = OPNGameCatalogLayoutSupport.nextRowY(afterRow: rowY, rowIndex: rowIndex, hasHero: hasHero, viewportHeight: bounds.height)
        }
        if rowLayouts.count > 0 {
            documentView.frame = NSRect(x: 0, y: 0, width: width, height: max(bounds.height, rowY + 88))
        }
    }

    @objc func updateRowVirtualizationForVisibleBounds() {
        guard rowLayouts.count > 0 else { return }
        let visibleBounds = scrollView.contentView.bounds
        let buffer = visibleBounds.height + OPNGameCatalogLayoutSupport.storeRowHeight
        let visibleMinY = visibleBounds.minY - buffer
        let visibleMaxY = visibleBounds.maxY + buffer
        for rowLayout in rowLayouts.compactMap({ $0 as? OPNStoreRowLayout }) {
            let rowMinY = rowLayout.y
            let rowMaxY = rowMinY + OPNGameCatalogLayoutSupport.storeRowHeight
            let shouldMount = rowMaxY >= visibleMinY && rowMinY <= visibleMaxY
            guard rowLayout.mounted != shouldMount else { continue }
            rowLayout.mounted = shouldMount
            rowLayout.glowView?.isHidden = !shouldMount
            rowLayout.indexLabel?.isHidden = !shouldMount
            rowLayout.titleLabel?.isHidden = !shouldMount
            rowLayout.hintLabel?.isHidden = !shouldMount
            rowLayout.scrollView?.isHidden = !shouldMount
            if shouldMount {
                updateImagePreloading(for: rowLayout)
            } else {
                rowLayout.cards.forEach { $0.cancelImageLoad() }
            }
        }
    }

    @objc func updateImagePreloadingForMountedRows() {
        for rowLayout in rowLayouts.compactMap({ $0 as? OPNStoreRowLayout }) where rowLayout.mounted {
            updateImagePreloading(for: rowLayout)
        }
    }

    @objc(updateImagePreloadingForRowLayout:)
    func updateImagePreloading(for rowLayout: OPNStoreRowLayout?) {
        guard let rowLayout, rowLayout.mounted, !rowLayout.cards.isEmpty, let scrollView = rowLayout.scrollView else { return }
        let visibleRect = scrollView.contentView.bounds
        var cardSpan = OPNGameCatalogLayoutSupport.storeTileWidth + OPNGameCatalogLayoutSupport.storeCardSpacing
        if let firstCard = rowLayout.cards.first {
            cardSpan = max(1, firstCard.frame.width + OPNGameCatalogLayoutSupport.storeCardSpacing)
        }
        let horizontalBuffer = cardSpan * CGFloat(OPNGameCatalogLayoutSupport.storeRailImagePreloadCardBuffer)
        let preloadRect = visibleRect.insetBy(dx: -horizontalBuffer, dy: 0)
        let prefetchRect = visibleRect.insetBy(dx: -horizontalBuffer * 2.5, dy: 0)
        for card in rowLayout.cards {
            if card.frame.intersects(preloadRect) {
                card.ensureImageLoaded()
            } else {
                card.cancelImageLoad()
                if card.frame.intersects(prefetchRect) {
                    let candidates = card.imageCandidates()
                    if !candidates.isEmpty {
                        trackPrefetchImageLoadToken(OPNUIHelpers.prefetchImage(candidates: candidates, maxPixelDimension: 900))
                    }
                }
            }
        }
    }

    @objc(addSection:index:y:contentX:width:)
    func addSection(_ section: OPNCatalogPanelSectionObject, index sectionIndex: Int, y: CGFloat, contentX: CGFloat, width: CGFloat) {
        let rightInset = contentX
        let availableWidth = max(320, width - contentX - rightInset)
        let sectionTitle = section.title.isEmpty ? "Featured" : section.title

        let rowGlow = NSView(frame: NSRect(x: contentX - 18, y: y + 36, width: availableWidth + 36, height: OPNGameCatalogLayoutSupport.storeTileHeight + 44))
        rowGlow.wantsLayer = true
        rowGlow.layer?.cornerRadius = 24
        rowGlow.layer?.backgroundColor = OPNUIHelpers.color(rgb: 0xFFFFFF, alpha: 0.032).cgColor
        rowGlow.layer?.borderWidth = 1
        rowGlow.layer?.borderColor = OPNUIHelpers.color(rgb: 0xFFFFFF, alpha: 0.055).cgColor
        documentView.addSubview(rowGlow)

        let indexLabel = OPNUIHelpers.label(text: String(format: "%02d", sectionIndex + 1), frame: NSRect(x: contentX, y: y + 5, width: 42, height: 18), size: 11, color: OPNUIHelpers.color(rgb: 0x34C759, alpha: 1), weight: .black, alignment: .left)
        documentView.addSubview(indexLabel)
        let label = OPNUIHelpers.label(text: sectionTitle, frame: NSRect(x: contentX + 42, y: y, width: availableWidth - 142, height: 30), size: 23, color: OPNUIHelpers.color(rgb: 0xF5F5F7, alpha: 1), weight: .bold, alignment: .left)
        label.lineBreakMode = .byTruncatingTail
        documentView.addSubview(label)
        let railHint = OPNUIHelpers.label(text: "\(section.games.count) games", frame: NSRect(x: contentX + availableWidth - 110, y: y + 6, width: 110, height: 18), size: 12, color: OPNUIHelpers.color(rgb: 0x787A82, alpha: 1), weight: .semibold, alignment: .right)
        documentView.addSubview(railHint)

        let rowScroll = OPNStoreRailScrollView(frame: NSRect(x: contentX, y: y + 48, width: availableWidth, height: OPNGameCatalogLayoutSupport.storeTileHeight + 30))
        rowScroll.drawsBackground = false
        rowScroll.borderType = .noBorder
        rowScroll.hasHorizontalScroller = false
        rowScroll.hasVerticalScroller = false
        rowScroll.autohidesScrollers = true
        documentView.addSubview(rowScroll)

        let rowDocument = OPNStoreDocumentView(frame: NSRect(x: 0, y: 0, width: rowScroll.frame.width, height: OPNGameCatalogLayoutSupport.storeTileHeight + 30))
        rowDocument.wantsLayer = true
        rowScroll.documentView = rowDocument
        rowScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(rowScrollViewBoundsDidChange(_:)), name: NSView.boundsDidChangeNotification, object: rowScroll.contentView)

        var cards: [OPNStoreGameTile] = []
        let tileMetrics = OPNGameCatalogLayoutSupport.tileMetrics(forRailWidth: availableWidth)
        var x: CGFloat = 0
        for (column, gameObject) in section.games.enumerated() {
            let card = OPNStoreGameTile(frame: NSRect(x: x, y: 10, width: tileMetrics.width, height: tileMetrics.height), gameObject: gameObject, prominent: false)
            card.imageRevealDelay = min(0.42, 0.035 * Double(column) + 0.025 * Double(sectionIndex))
            card.selectedVariantIndex = selectedVariantIndex(for: gameObject)
            card.setStoreFocused(false)
            card.onSelect = { [weak self, weak card] in
                guard let self, let card, let onSelectGame else { return }
                let variantIndex = card.selectedVariantIndex >= 0 ? card.selectedVariantIndex : 0
                onSelectGame(card.gameObject, variantIndex)
            }
            card.onBuy = { [weak self, weak card] purchaseURL in
                guard let self, let card, let onBuyGame else { return }
                let variantIndex = card.selectedVariantIndex >= 0 ? card.selectedVariantIndex : 0
                onBuyGame(card.gameObject, variantIndex, purchaseURL)
            }
            card.onMarkUnowned = { [weak self, weak card] in
                guard let self, let card, let onMarkGameUnowned else { return }
                let variantIndex = card.selectedVariantIndex >= 0 ? card.selectedVariantIndex : 0
                onMarkGameUnowned(card.gameObject, variantIndex)
            }
            let hoverRowIndex = rowCards.count
            let hoverColumnIndex = column
            card.onHover = { [weak self, weak card] in
                guard let self else { return }
                self.hoveredTile = card
                if self.focusedRowIndex == hoverRowIndex && self.focusedColumnIndex == hoverColumnIndex { return }
                self.focusedRowIndex = hoverRowIndex
                self.focusedColumnIndex = hoverColumnIndex
                self.updateFocusedTiles()
            }
            rowDocument.addSubview(card)
            cards.append(card)
            x += tileMetrics.width + OPNGameCatalogLayoutSupport.storeCardSpacing
        }
        rowDocument.frame = NSRect(x: 0, y: 0, width: max(x + 24, rowScroll.frame.width), height: OPNGameCatalogLayoutSupport.storeTileHeight + 30)
        rowCards.add(cards)

        let rowLayout = OPNStoreRowLayout()
        rowLayout.glowView = rowGlow
        rowLayout.indexLabel = indexLabel
        rowLayout.titleLabel = label
        rowLayout.hintLabel = railHint
        rowLayout.scrollView = rowScroll
        rowLayout.documentView = rowDocument
        rowLayout.cards = cards
        rowLayout.y = y
        rowLayout.mounted = false
        rowLayouts.add(rowLayout)
    }

    @objc func storeScrollViewBoundsDidChange(_ notification: Notification) {
        guard notification.object as AnyObject? === scrollView.contentView else { return }
        updateRowVirtualizationForVisibleBounds()
        updateImagePreloadingForMountedRows()
        hoveredTile?.resetMouseTrackingIfOutside()
    }

    @objc func rowScrollViewBoundsDidChange(_ notification: Notification) {
        for rowLayout in rowLayouts.compactMap({ $0 as? OPNStoreRowLayout }) {
            guard notification.object as AnyObject? === rowLayout.scrollView?.contentView else { continue }
            updateImagePreloading(for: rowLayout)
            return
        }
    }
}
