#import "GameCatalog/OPNGameCatalogPrivate.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"

@implementation OPNGameCatalogView

using namespace OPN;

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = [NSColor clearColor].CGColor;
        _rowCards = [NSMutableArray array];
        _rowLayouts = [NSMutableArray array];
        _heroImageLoadTokens = [NSMutableArray array];
        _prefetchImageLoadTokens = [NSMutableArray array];
        _desktopFeaturedHeroViews = [NSMutableArray array];
        _desktopFeaturedHeroFrame = NSZeroRect;
        _focusedRowIndex = 0;
        _focusedColumnIndex = 0;
        _scrollView = [[NSScrollView alloc] initWithFrame:self.bounds];
        _scrollView.drawsBackground = NO;
        _scrollView.borderType = NSNoBorder;
        _scrollView.hasVerticalScroller = NO;
        _scrollView.hasHorizontalScroller = NO;
        _scrollView.autohidesScrollers = YES;
        _scrollView.contentInsets = NSEdgeInsetsZero;
        _scrollView.scrollerInsets = NSEdgeInsetsZero;
        _scrollView.automaticallyAdjustsContentInsets = NO;
        _scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self addSubview:_scrollView];

        _documentView = [[OPNStoreDocumentView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(frame), NSHeight(frame))];
        _documentView.wantsLayer = YES;
        _scrollView.documentView = _documentView;
        _scrollView.contentView.postsBoundsChangedNotifications = YES;

        _statusLabel = OpnLabel(@"", NSZeroRect, 15.0, OpnColor(kTextMuted), NSFontWeightMedium, NSTextAlignmentCenter);
        [self addSubview:_statusLabel];

        _loadingView = [[OPNLoadingView alloc] initWithFrame:self.bounds message:@"Loading games..."];
        _loadingView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        _loadingView.hidden = YES;
        [self addSubview:_loadingView];

        _buttonHintPillView = [[OPNStoreHintPillView alloc] initWithFrame:NSZeroRect];
        _buttonHintPillView.wantsLayer = YES;
        _buttonHintPillView.layer.backgroundColor = OpnColor(kBlack, 0.50).CGColor;
        _buttonHintPillView.layer.cornerRadius = kStoreButtonHintPillHeight * 0.5;
        _buttonHintPillView.layer.masksToBounds = YES;
        [self addSubview:_buttonHintPillView];

        _buttonHintStackView = [[NSStackView alloc] initWithFrame:NSZeroRect];
        _buttonHintStackView.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        _buttonHintStackView.alignment = NSLayoutAttributeCenterY;
        _buttonHintStackView.distribution = NSStackViewDistributionGravityAreas;
        _buttonHintStackView.spacing = 18.0;
        [_buttonHintPillView addSubview:_buttonHintStackView];
        _buttonHintControllerFamily = (OPNStoreControllerFamily)NSIntegerMin;
        _searchQuery = @"";
        _completedSearchQuery = @"";
        _searchQueue = dispatch_queue_create("io.opencg.opennow.catalog-search", DISPATCH_QUEUE_SERIAL);
        _searchLibrarySnapshot = std::make_shared<const std::vector<GameInfo>>(_ownedLibraryGames);
        _searchPanelsSnapshot = std::make_shared<const std::vector<PanelResult>>(_panels);
        [self rebuildButtonHintPillForCurrentController];

        _searchPanelView = [[NSView alloc] initWithFrame:NSZeroRect];
        _searchPanelView.wantsLayer = YES;
        _searchPanelView.layer.backgroundColor = OpnColor(kBlack, 0.64).CGColor;
        _searchPanelView.layer.cornerRadius = 18.0;
        _searchPanelView.layer.borderWidth = 1.0;
        _searchPanelView.layer.borderColor = OpnColor(kBrandGreen, 0.34).CGColor;
        [self addSubview:_searchPanelView positioned:NSWindowAbove relativeTo:nil];

        _searchField = [[NSSearchField alloc] initWithFrame:NSZeroRect];
        _searchField.placeholderString = @"Search library and store titles";
        _searchField.delegate = self;
        _searchField.focusRingType = NSFocusRingTypeNone;
        _searchField.font = [NSFont systemFontOfSize:15.0 weight:NSFontWeightSemibold];
        [_searchPanelView addSubview:_searchField];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(interfacePreferencesChanged:)
                                                     name:OPNInterfacePreferencesDidChangeNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(storeScrollViewBoundsDidChange:)
                                                      name:NSViewBoundsDidChangeNotification
                                                    object:_scrollView.contentView];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(controllerConfigurationChanged:)
                                                     name:GCControllerDidConnectNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(controllerConfigurationChanged:)
                                                     name:GCControllerDidDisconnectNotification
                                                   object:nil];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)hasContent { return self.rowCards.count > 0 || self.desktopFeaturedHeroViews.count > 0; }

- (void)mouseDown:(NSEvent *)event {
    [self.window makeFirstResponder:self];
    [super mouseDown:event];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window) [self.window makeFirstResponder:self];
    [self rebuildButtonHintPillForCurrentController];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.heroRotationTimer invalidate];
    [self.resizeRenderTimer invalidate];
    [self.searchDebounceTimer invalidate];
    [self cancelHeroImageLoads];
    [self cancelPrefetchImageLoads];
}

- (void)interfacePreferencesChanged:(NSNotification *)notification {
    (void)notification;
    [self renderStore];
}

- (void)controllerConfigurationChanged:(NSNotification *)notification {
    (void)notification;
    [self rebuildButtonHintPillForCurrentController];
}


@end

#pragma clang diagnostic pop
