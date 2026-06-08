#import "OPNGameCatalogPrivate.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation OPNGameCatalogView (Rendering)

using namespace OPN;

- (void)layout {
    [super layout];
    CGFloat navClearance = kStoreNavigationClearance;
    self.scrollView.frame = NSMakeRect(0.0, navClearance, NSWidth(self.bounds), MAX(0.0, NSHeight(self.bounds) - navClearance));
    self.loadingView.frame = self.bounds;
    self.statusLabel.frame = NSMakeRect(0, NSHeight(self.bounds) * 0.5, NSWidth(self.bounds), 26.0);
    self.documentView.frame = NSMakeRect(0.0, 0.0, MAX(980.0, NSWidth(self.bounds)), MAX(NSHeight(self.documentView.frame), NSHeight(self.bounds)));
    [self updateButtonHintPillFrame];
    [self updateDesktopHeroFrameForCurrentBounds];
    [self updateRowFramesForCurrentBounds];
    [self updateRowVirtualizationForVisibleBounds];
    if (std::fabs(self.lastLayoutWidth - NSWidth(self.bounds)) > 1.0 || std::fabs(self.lastLayoutHeight - NSHeight(self.bounds)) > 1.0) {
        self.lastLayoutWidth = NSWidth(self.bounds);
        self.lastLayoutHeight = NSHeight(self.bounds);
        [self scheduleRenderStoreAfterResize];
    }
}

- (void)updateButtonHintPillFrame {
    if (!self.buttonHintPillView || !self.buttonHintStackView) return;
    CGFloat availableWidth = MAX(0.0, NSWidth(self.bounds) - 48.0);
    CGFloat pillWidth = MIN(680.0, MAX(360.0, availableWidth));
    CGFloat pillX = floor((NSWidth(self.bounds) - pillWidth) * 0.5);
    CGFloat pillY = MAX(0.0, floor(NSHeight(self.bounds) - kStoreButtonHintPillBottomInset - kStoreButtonHintPillHeight));
    self.buttonHintPillView.frame = NSMakeRect(pillX, pillY, pillWidth, kStoreButtonHintPillHeight);
    self.buttonHintPillView.layer.cornerRadius = kStoreButtonHintPillHeight * 0.5;
    NSSize stackSize = self.buttonHintStackView.fittingSize;
    CGFloat stackWidth = MIN(stackSize.width, MAX(0.0, pillWidth - 36.0));
    CGFloat stackHeight = MIN(stackSize.height, MAX(0.0, kStoreButtonHintPillHeight - 12.0));
    self.buttonHintStackView.frame = NSMakeRect(floor((pillWidth - stackWidth) * 0.5),
                                                floor((kStoreButtonHintPillHeight - stackHeight) * 0.5),
                                                stackWidth,
                                                stackHeight);
    [self updateSearchPanelFrame];
}

- (void)updateSearchPanelFrame {
    if (!self.searchPanelView || !self.searchField) return;
    CGFloat width = NSWidth(self.bounds);
    CGFloat height = NSHeight(self.bounds);
    CGFloat scale = height <= 760.0 ? 0.82 : (height < 900.0 ? 0.92 : 1.0);
    CGFloat panelHeight = floor(44.0 * scale);
    CGFloat availableWidth = MAX(kStoreSearchPanelMinWidth, width - 48.0);
    CGFloat panelWidth = MIN(kStoreSearchPanelMaxWidth, availableWidth);
    CGFloat x = floor((width - panelWidth) * 0.5);
    CGFloat y = floor((140.0 * scale - panelHeight) * 0.5);
    self.searchPanelView.frame = NSMakeRect(x, y, panelWidth, panelHeight);
    self.searchPanelView.layer.cornerRadius = panelHeight * 0.5;
    self.searchField.frame = NSMakeRect(14.0, floor((panelHeight - 30.0) * 0.5), panelWidth - 28.0, 30.0);
}

- (void)scheduleRenderStore {
    if (self.renderStoreScheduled) return;
    self.renderStoreScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.renderStoreScheduled = NO;
        [self renderStoreWhenInitialHeroReady];
    });
}

- (void)scheduleRenderStoreAfterResize {
    if (!self.hasContent) {
        [self scheduleRenderStore];
        return;
    }
    [self updateDesktopHeroFrameForCurrentBounds];
    [self updateRowFramesForCurrentBounds];
    [self updateRowVirtualizationForVisibleBounds];
}

- (void)resizeRenderTimerFired:(NSTimer *)timer {
    (void)timer;
    self.resizeRenderTimer = nil;
    [self scheduleRenderStore];
}

- (void)renderStore {
    [self cancelHeroImageLoads];
    for (NSView *view in [self.documentView.subviews copy]) {
        [view removeFromSuperview];
    }
    [self.rowCards removeAllObjects];
    [self.rowLayouts removeAllObjects];
    [self.desktopFeaturedHeroViews removeAllObjects];
    self.desktopHeroContainer = nil;
    self.desktopHeroArtworkView = nil;
    self.desktopHeroArtworkTransitionView = nil;
    self.desktopHeroTitleFallback = nil;
    self.desktopHeroLogoView = nil;
    self.desktopHeroLogoTransitionView = nil;
    self.desktopHeroIdentity = nil;
    self.desktopFeaturedHeroFrame = NSZeroRect;

    CGFloat viewportWidth = MAX(1.0, NSWidth(self.bounds));
    CGFloat width = MAX(980.0, viewportWidth);
    CGFloat contentX = OPNStoreHeroContentInsetForWidth(width);
    CGFloat contentWidth = MAX(680.0, width - contentX * 2.0);
    CGFloat y = kStoreTopInset;

    const GameInfo *heroGame = [self currentHeroGame];

    CGFloat heroHeight = 0.0;
    if (heroGame) {
        heroHeight = OPNStoreHeroHeightForWidth(viewportWidth, NSHeight(self.bounds));
        [self addDesktopHeroStageForGame:*heroGame y:y contentX:0.0 width:viewportWidth height:heroHeight];
    }

    CGFloat rowY = heroGame ? y + heroHeight + kStoreHeroFirstRowSpacing : y;
    NSInteger renderedRows = 0;
    BOOL hasCompletedSearch = OPNStoreSearchNormalizedString(self.completedSearchQuery).length > 0;
    const std::vector<GameInfo> &visibleLibraryGames = hasCompletedSearch ? _filteredLibraryGames : _ownedLibraryGames;
    const std::vector<PanelResult> &visiblePanels = hasCompletedSearch ? _filteredPanels : _panels;

    PanelSection librarySection = OPNCatalogSingleLibrarySectionForGames(visibleLibraryGames);
    if (!librarySection.games.empty()) {
        [self addSection:librarySection index:renderedRows y:rowY contentX:contentX width:width];
        rowY = OPNStoreNextRowYAfterRow(rowY, renderedRows, heroGame != nullptr, NSHeight(self.bounds));
        renderedRows++;
    }
    for (const PanelResult &panel : visiblePanels) {
        for (const PanelSection &section : panel.sections) {
            if (section.games.empty()) continue;
            [self addSection:section index:renderedRows y:rowY contentX:contentX width:width];
            rowY = OPNStoreNextRowYAfterRow(rowY, renderedRows, heroGame != nullptr, NSHeight(self.bounds));
            renderedRows++;
        }
    }

    if (renderedRows == 0 && !self.loadingView.hidden) {
        self.statusLabel.stringValue = @"";
    } else if (renderedRows == 0) {
        self.statusLabel.stringValue = @"";
        [self addEmptyStoreStateWithY:rowY contentX:contentX width:contentWidth];
        rowY += 260.0;
    } else {
        self.statusLabel.stringValue = @"";
    }

    CGFloat documentHeight = MAX(NSHeight(self.bounds), rowY + 88.0);
    self.documentView.frame = NSMakeRect(0, 0, width, documentHeight);
    [self updateFocusedTiles];
    [self updateRowVirtualizationForVisibleBounds];
}

- (void)addEmptyStoreStateWithY:(CGFloat)y contentX:(CGFloat)contentX width:(CGFloat)width {
    NSView *emptyPanel = [[NSView alloc] initWithFrame:NSMakeRect(contentX, y, width, 220.0)];
    emptyPanel.wantsLayer = YES;
    emptyPanel.layer.cornerRadius = 28.0;
    emptyPanel.layer.backgroundColor = OpnColor(0xFFFFFF, 0.045).CGColor;
    emptyPanel.layer.borderWidth = 1.0;
    emptyPanel.layer.borderColor = OpnColor(0xFFFFFF, 0.10).CGColor;
    [self.documentView addSubview:emptyPanel];

    NSTextField *eyebrow = OpnLabel(@"SIGNAL LOST", NSMakeRect(0.0, 54.0, width, 18.0), 12.0, OpnColor(kBrandGreen), NSFontWeightBlack, NSTextAlignmentCenter);
    [emptyPanel addSubview:eyebrow];
    NSTextField *title = OpnLabel(@"No games found", NSMakeRect(0.0, 78.0, width, 34.0), 27.0, OpnColor(kTextPrimary), NSFontWeightBold, NSTextAlignmentCenter);
    [emptyPanel addSubview:title];
    NSTextField *subtitle = OpnLabel(@"The catalog returned no games. Try again after the service refreshes.", NSMakeRect(0.0, 120.0, width, 22.0), 13.0, OpnColor(kTextSecondary), NSFontWeightMedium, NSTextAlignmentCenter);
    [emptyPanel addSubview:subtitle];
}


- (void)updateDesktopHeroFrameForCurrentBounds {
    if (!self.desktopHeroContainer || !self.desktopHeroArtworkView || NSIsEmptyRect(self.desktopFeaturedHeroFrame)) return;
    CGFloat width = MAX(1.0, NSWidth(self.bounds));
    CGFloat height = OPNStoreHeroHeightForWidth(width, NSHeight(self.bounds));
    self.desktopFeaturedHeroFrame = NSMakeRect(NSMinX(self.desktopFeaturedHeroFrame), NSMinY(self.desktopFeaturedHeroFrame), width, height);
    self.desktopHeroContainer.frame = self.desktopFeaturedHeroFrame;
    self.desktopHeroArtworkView.frame = self.desktopHeroContainer.bounds;
    self.desktopHeroArtworkTransitionView.frame = self.desktopHeroContainer.bounds;
    [self updateDesktopHeroLogoFrame];
}

- (void)updateRowFramesForCurrentBounds {
    CGFloat width = MAX(980.0, NSWidth(self.bounds));
    CGFloat contentX = OPNStoreHeroContentInsetForWidth(width);
    CGFloat availableWidth = MAX(320.0, width - contentX * 2.0);
    CGFloat rowY = NSIsEmptyRect(self.desktopFeaturedHeroFrame) ? kStoreTopInset : NSMaxY(self.desktopFeaturedHeroFrame) + kStoreHeroFirstRowSpacing;
    NSInteger rowIndex = 0;
    BOOL hasHero = !NSIsEmptyRect(self.desktopFeaturedHeroFrame);
    for (OPNStoreRowLayout *rowLayout in self.rowLayouts) {
        rowLayout.y = rowY;
        CGFloat y = rowY;
        rowLayout.glowView.frame = NSMakeRect(contentX - 18.0, y + 36.0, availableWidth + 36.0, kStoreTileHeight + 44.0);
        rowLayout.indexLabel.frame = NSMakeRect(contentX, y + 5.0, 42.0, 18.0);
        rowLayout.titleLabel.frame = NSMakeRect(contentX + 42.0, y, availableWidth - 142.0, 30.0);
        rowLayout.hintLabel.frame = NSMakeRect(contentX + availableWidth - 110.0, y + 6.0, 110.0, 18.0);
        rowLayout.scrollView.frame = NSMakeRect(contentX, y + 48.0, availableWidth, kStoreTileHeight + 30.0);

        NSSize tileMetrics = OPNStoreTileMetricsForRailWidth(availableWidth);
        CGFloat fittedTileWidth = tileMetrics.width;
        CGFloat fittedTileHeight = tileMetrics.height;
        CGFloat x = 0.0;
        for (OPNStoreGameTile *card in rowLayout.cards) {
            card.frame = NSMakeRect(x, 10.0, fittedTileWidth, fittedTileHeight);
            x += fittedTileWidth + kStoreCardSpacing;
        }
        rowLayout.documentView.frame = NSMakeRect(0.0, 0.0, MAX(x + 24.0, NSWidth(rowLayout.scrollView.frame)), kStoreTileHeight + 30.0);
        [self updateImagePreloadingForRowLayout:rowLayout];
        rowY = OPNStoreNextRowYAfterRow(rowY, rowIndex, hasHero, NSHeight(self.bounds));
        rowIndex++;
    }
    if (self.rowLayouts.count > 0) {
        self.documentView.frame = NSMakeRect(0.0, 0.0, width, MAX(NSHeight(self.bounds), rowY + 88.0));
    }
}

- (void)updateRowVirtualizationForVisibleBounds {
    if (self.rowLayouts.count == 0) return;
    NSRect visibleBounds = self.scrollView.contentView.bounds;
    CGFloat buffer = NSHeight(visibleBounds) + kStoreRowHeight;
    CGFloat visibleMinY = NSMinY(visibleBounds) - buffer;
    CGFloat visibleMaxY = NSMaxY(visibleBounds) + buffer;
    for (OPNStoreRowLayout *rowLayout in self.rowLayouts) {
        CGFloat rowMinY = rowLayout.y;
        CGFloat rowMaxY = rowMinY + kStoreRowHeight;
        BOOL shouldMount = rowMaxY >= visibleMinY && rowMinY <= visibleMaxY;
        if (rowLayout.mounted == shouldMount) continue;
        rowLayout.mounted = shouldMount;
        rowLayout.glowView.hidden = !shouldMount;
        rowLayout.indexLabel.hidden = !shouldMount;
        rowLayout.titleLabel.hidden = !shouldMount;
        rowLayout.hintLabel.hidden = !shouldMount;
        rowLayout.scrollView.hidden = !shouldMount;
        if (shouldMount) [self updateImagePreloadingForRowLayout:rowLayout];
        else for (OPNStoreGameTile *card in rowLayout.cards) [card cancelImageLoad];
    }
}

- (void)updateImagePreloadingForMountedRows {
    for (OPNStoreRowLayout *rowLayout in self.rowLayouts) {
        if (!rowLayout.mounted) continue;
        [self updateImagePreloadingForRowLayout:rowLayout];
    }
}

- (void)updateImagePreloadingForRowLayout:(OPNStoreRowLayout *)rowLayout {
    if (!rowLayout || !rowLayout.mounted || rowLayout.cards.count == 0) return;
    NSRect visibleRect = rowLayout.scrollView.contentView.bounds;
    CGFloat cardSpan = kStoreTileWidth + kStoreCardSpacing;
    if (rowLayout.cards.count > 0) {
        OPNStoreGameTile *firstCard = rowLayout.cards.firstObject;
        cardSpan = MAX(1.0, NSWidth(firstCard.frame) + kStoreCardSpacing);
    }
    CGFloat horizontalBuffer = cardSpan * (CGFloat)kStoreRailImagePreloadCardBuffer;
    NSRect preloadRect = NSInsetRect(visibleRect, -horizontalBuffer, 0.0);
    NSRect prefetchRect = NSInsetRect(visibleRect, -horizontalBuffer * 2.5, 0.0);
    for (OPNStoreGameTile *card in rowLayout.cards) {
        if (NSIntersectsRect(card.frame, preloadRect)) [card ensureImageLoaded];
        else {
            [card cancelImageLoad];
            if (NSIntersectsRect(card.frame, prefetchRect)) {
                NSArray<NSString *> *candidates = OPNStoreImageCandidatesForGame(card.game, card.prominent);
                if (candidates.count > 0) [self trackPrefetchImageLoadToken:OpnPrefetchImageFromCandidates(candidates, 900.0)];
            }
        }
    }
}

- (void)addSection:(const PanelSection &)section index:(NSInteger)sectionIndex y:(CGFloat)y contentX:(CGFloat)contentX width:(CGFloat)width {
    CGFloat rightInset = contentX;
    CGFloat availableWidth = MAX(320.0, width - contentX - rightInset);
    NSString *sectionTitle = section.title.empty() ? @"Featured" : [NSString stringWithUTF8String:section.title.c_str()];

    NSView *rowGlow = [[NSView alloc] initWithFrame:NSMakeRect(contentX - 18.0, y + 36.0, availableWidth + 36.0, kStoreTileHeight + 44.0)];
    rowGlow.wantsLayer = YES;
    rowGlow.layer.cornerRadius = 24.0;
    rowGlow.layer.backgroundColor = OpnColor(0xFFFFFF, 0.032).CGColor;
    rowGlow.layer.borderWidth = 1.0;
    rowGlow.layer.borderColor = OpnColor(0xFFFFFF, 0.055).CGColor;
    [self.documentView addSubview:rowGlow];

    NSTextField *indexLabel = OpnLabel([NSString stringWithFormat:@"%02ld", (long)sectionIndex + 1], NSMakeRect(contentX, y + 5.0, 42.0, 18.0), 11.0, OpnColor(kBrandGreen), NSFontWeightBlack);
    [self.documentView addSubview:indexLabel];
    NSTextField *label = OpnLabel(sectionTitle, NSMakeRect(contentX + 42.0, y, availableWidth - 142.0, 30.0), 23.0, OpnColor(kTextPrimary), NSFontWeightBold);
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.documentView addSubview:label];
    NSString *hintText = [NSString stringWithFormat:@"%ld games", (long)section.games.size()];
    NSTextField *railHint = OpnLabel(hintText, NSMakeRect(contentX + availableWidth - 110.0, y + 6.0, 110.0, 18.0), 12.0, OpnColor(kTextMuted), NSFontWeightSemibold, NSTextAlignmentRight);
    [self.documentView addSubview:railHint];

    OPNStoreRailScrollView *rowScroll = [[OPNStoreRailScrollView alloc] initWithFrame:NSMakeRect(contentX, y + 48.0, availableWidth, kStoreTileHeight + 30.0)];
    rowScroll.drawsBackground = NO;
    rowScroll.borderType = NSNoBorder;
    rowScroll.hasHorizontalScroller = NO;
    rowScroll.hasVerticalScroller = NO;
    rowScroll.autohidesScrollers = YES;
    [self.documentView addSubview:rowScroll];

    OPNStoreDocumentView *rowDocument = [[OPNStoreDocumentView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(rowScroll.frame), kStoreTileHeight + 30.0)];
    rowDocument.wantsLayer = YES;
    rowScroll.documentView = rowDocument;
    rowScroll.contentView.postsBoundsChangedNotifications = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(rowScrollViewBoundsDidChange:)
                                                 name:NSViewBoundsDidChangeNotification
                                               object:rowScroll.contentView];

    NSMutableArray<OPNStoreGameTile *> *cards = [NSMutableArray array];
    NSSize tileMetrics = OPNStoreTileMetricsForRailWidth(availableWidth);
    CGFloat fittedTileWidth = tileMetrics.width;
    CGFloat fittedTileHeight = tileMetrics.height;
    CGFloat x = 0.0;
    NSInteger column = 0;
    for (const GameInfo &game : section.games) {
        OPNStoreGameTile *card = [[OPNStoreGameTile alloc] initWithFrame:NSMakeRect(x, 10.0, fittedTileWidth, fittedTileHeight) game:game prominent:NO];
        card.imageRevealDelay = MIN(0.42, 0.035 * column + 0.025 * sectionIndex);
        card.selectedVariantIndex = [self selectedVariantIndexForStoreGame:game];
        [card setStoreFocused:NO];
        __weak __typeof__(self) weakSelf = self;
        __weak OPNStoreGameTile *weakCard = card;
        card.onSelect = ^{
            __typeof__(self) strongSelf = weakSelf;
            OPNStoreGameTile *strongCard = weakCard;
            if (!strongSelf || !strongCard || !strongSelf.onSelectGame) return;
            int variantIndex = strongCard.selectedVariantIndex >= 0 ? strongCard.selectedVariantIndex : 0;
            strongSelf.onSelectGame(strongCard.game, variantIndex);
        };
        card.onBuy = ^(NSString *purchaseURL) {
            __typeof__(self) strongSelf = weakSelf;
            OPNStoreGameTile *strongCard = weakCard;
            if (!strongSelf || !strongCard || !strongSelf.onBuyGame) return;
            int variantIndex = strongCard.selectedVariantIndex >= 0 ? strongCard.selectedVariantIndex : 0;
            strongSelf.onBuyGame(strongCard.game, variantIndex, purchaseURL ?: @"");
        };
        card.onMarkUnowned = ^{
            __typeof__(self) strongSelf = weakSelf;
            OPNStoreGameTile *strongCard = weakCard;
            if (!strongSelf || !strongCard || !strongSelf.onMarkGameUnowned) return;
            int variantIndex = strongCard.selectedVariantIndex >= 0 ? strongCard.selectedVariantIndex : 0;
            strongSelf.onMarkGameUnowned(strongCard.game, variantIndex);
        };
        NSInteger hoverRowIndex = self.rowCards.count;
        NSInteger hoverColumnIndex = column;
        card.onHover = ^{
            __typeof__(self) strongSelf = weakSelf;
            OPNStoreGameTile *strongCard = weakCard;
            if (!strongSelf) return;
            strongSelf.hoveredTile = strongCard;
            if (strongSelf.focusedRowIndex == hoverRowIndex && strongSelf.focusedColumnIndex == hoverColumnIndex) return;
            strongSelf.focusedRowIndex = hoverRowIndex;
            strongSelf.focusedColumnIndex = hoverColumnIndex;
            [strongSelf updateFocusedTiles];
        };
        [rowDocument addSubview:card];
        [cards addObject:card];
        x += fittedTileWidth + kStoreCardSpacing;
        column++;
    }
    rowDocument.frame = NSMakeRect(0, 0, MAX(x + 24.0, NSWidth(rowScroll.frame)), kStoreTileHeight + 30.0);
    [self.rowCards addObject:cards];

    OPNStoreRowLayout *rowLayout = [[OPNStoreRowLayout alloc] init];
    rowLayout.glowView = rowGlow;
    rowLayout.indexLabel = indexLabel;
    rowLayout.titleLabel = label;
    rowLayout.hintLabel = railHint;
    rowLayout.scrollView = rowScroll;
    rowLayout.documentView = rowDocument;
    rowLayout.cards = cards;
    rowLayout.y = y;
    rowLayout.mounted = NO;
    [self.rowLayouts addObject:rowLayout];
}

- (void)storeScrollViewBoundsDidChange:(NSNotification *)notification {
    if (notification.object != self.scrollView.contentView) return;
    [self updateRowVirtualizationForVisibleBounds];
    [self updateImagePreloadingForMountedRows];
    [self.hoveredTile resetMouseTrackingIfOutside];
}

- (void)rowScrollViewBoundsDidChange:(NSNotification *)notification {
    for (OPNStoreRowLayout *rowLayout in self.rowLayouts) {
        if (notification.object != rowLayout.scrollView.contentView) continue;
        [self updateImagePreloadingForRowLayout:rowLayout];
        return;
    }
}

@end

#pragma clang diagnostic pop
