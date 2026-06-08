#import "OPNGameCatalogPrivate.h"


@interface OPNStoreGameTile ()
@property (nonatomic, assign) OPN::GameInfo gameData;
@property (nonatomic, strong) NSImageView *imageView;
@property (nonatomic, strong) NSView *gradientOverlay;
@property (nonatomic, strong) CAGradientLayer *gradientLayer;
@property (nonatomic, strong) CALayer *accentLayer;
@property (nonatomic, strong) CALayer *shineLayer;
@property (nonatomic, strong) NSView *storeBadgeView;
@property (nonatomic, strong) NSImageView *storeIconView;
@property (nonatomic, strong) NSMutableArray<NSImageView *> *storeIconViews;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *storeIconVariantIndexes;
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSTextField *metaLabel;
@property (nonatomic, strong) NSTextField *featureLabel;
@property (nonatomic, strong) NSTextField *availabilityLabel;
@property (nonatomic, strong) NSButton *playButton;
@property (nonatomic, strong) NSTrackingArea *trackingArea;
@property (nonatomic, assign) BOOL prominent;
@property (nonatomic, assign) BOOL storeFocused;
@property (nonatomic, assign) BOOL pendingMouseSelection;
@property (nonatomic, assign) BOOL draggingRail;
@property (nonatomic, assign) NSPoint lastDragLocationInWindow;
@property (nonatomic, assign) BOOL imageLoadRequested;
@property (nonatomic, assign) NSUInteger imageLoadGeneration;
@property (nonatomic, strong) OpnImageLoadToken *imageLoadToken;
- (void)updateStoreIconSelection;
- (void)saveCurrentStreamSettingsAsProfilePressed:(id)sender;
- (void)togglePerGameStreamProfilePressed:(id)sender;
- (void)deletePerGameStreamProfilePressed:(id)sender;
@end

@implementation OPNStoreGameTile

- (void)dealloc {
    [self.imageLoadToken cancel];
}

- (void)setSelectedVariantIndex:(int)selectedVariantIndex {
    if (!_gameData.variants.empty()) {
        selectedVariantIndex = MAX(0, MIN((int)_gameData.variants.size() - 1, selectedVariantIndex));
    }
    _selectedVariantIndex = selectedVariantIndex;
    self.availabilityLabel.stringValue = OPNStoreAvailabilityTitle(_gameData, _selectedVariantIndex);
    self.playButton.title = OPNStorePrimaryActionTitle(_gameData, _selectedVariantIndex, self.prominent);
    [self updateStoreIconSelection];
}

- (instancetype)initWithFrame:(NSRect)frame game:(const OPN::GameInfo &)game prominent:(BOOL)prominent {
    self = [super initWithFrame:frame];
    if (self) {
        _gameData = game;
        _prominent = prominent;
        _selectedVariantIndex = game.variants.empty() ? -1 : 0;
        self.wantsLayer = YES;
        self.layer.cornerRadius = prominent ? 28.0 : 18.0;
        self.layer.masksToBounds = YES;
        self.layer.backgroundColor = OpnColor(0x070A0C, 0.92).CGColor;
        self.layer.borderWidth = 1.25;
        self.layer.borderColor = OpnColor(0xFFFFFF, prominent ? 0.18 : 0.12).CGColor;

        _imageView = [[NSImageView alloc] initWithFrame:self.bounds];
        _imageView.imageScaling = NSImageScaleProportionallyUpOrDown;
        _imageView.wantsLayer = YES;
        _imageView.layer.backgroundColor = OpnColor(0x11161A).CGColor;
        [self addSubview:_imageView];

        _gradientOverlay = [[NSView alloc] initWithFrame:self.bounds];
        _gradientOverlay.wantsLayer = YES;
        _gradientLayer = [CAGradientLayer layer];
        _gradientLayer.colors = @[(id)OpnColor(OPN::kBlack, prominent ? 0.08 : 0.02).CGColor,
                                  (id)OpnColor(OPN::kBlack, prominent ? 0.18 : 0.12).CGColor,
                                  (id)OpnColor(OPN::kBlack, prominent ? 0.88 : 0.82).CGColor];
        _gradientLayer.locations = @[@0.0, @0.52, @1.0];
        _gradientLayer.startPoint = CGPointMake(0.5, 0.0);
        _gradientLayer.endPoint = CGPointMake(0.5, 1.0);
        _gradientOverlay.layer = _gradientLayer;
        [self addSubview:_gradientOverlay];

        _shineLayer = [CALayer layer];
        _shineLayer.backgroundColor = OpnColor(OPN::kBrandGreen, prominent ? 0.16 : 0.10).CGColor;
        _shineLayer.opacity = prominent ? 0.88 : 0.52;
        [self.layer addSublayer:_shineLayer];

        _accentLayer = [CALayer layer];
        _accentLayer.backgroundColor = OpnColor(OPN::kBrandGreen, 0.96).CGColor;
        [self.layer addSublayer:_accentLayer];

        CGFloat titleSize = prominent ? 31.0 : 15.0;
        _storeBadgeView = [[NSView alloc] initWithFrame:NSZeroRect];
        _storeBadgeView.wantsLayer = YES;
        _storeBadgeView.layer.backgroundColor = NSColor.clearColor.CGColor;
        [self addSubview:_storeBadgeView];

        _storeIconViews = [NSMutableArray array];
        _storeIconVariantIndexes = [NSMutableArray array];
        NSArray<NSString *> *variantStores = OPNStoreVariantStoreNames(game);
        _storeIconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
        _storeIconView.imageScaling = NSImageScaleProportionallyDown;
        NSString *firstStore = !game.variants.empty() ? OPNStoreString(game.variants.front().appStore, @"") : (variantStores.firstObject ?: OPNStorePrimaryStoreName(game));
        if (firstStore.length == 0) firstStore = variantStores.firstObject ?: OPNStorePrimaryStoreName(game);
        _storeIconView.image = OPNStoreGreyscaleIconImage(OPNCachedStoreIconImage(firstStore) ?: OPNStoreIconPlaceholderImage(firstStore));
        _storeIconView.toolTip = OPNStoreDisplayLabel(firstStore);
        _storeIconView.contentTintColor = OpnColor(0xD7D8DC, 0.50);
        _storeIconView.wantsLayer = YES;
        _storeIconView.layer.backgroundColor = OpnColor(0x030506, 0.72).CGColor;
        _storeIconView.layer.borderWidth = 1.0;
        _storeIconView.layer.borderColor = OpnColor(0xFFFFFF, 0.18).CGColor;
        [_storeBadgeView addSubview:_storeIconView];
        [_storeIconViews addObject:_storeIconView];
        [_storeIconVariantIndexes addObject:@0];
        __weak NSImageView *weakPrimaryIconView = _storeIconView;
        OPNLoadStoreIconImage(firstStore, ^(NSImage *image) {
            if (image && weakPrimaryIconView) weakPrimaryIconView.image = OPNStoreGreyscaleIconImage(image);
        });

        NSUInteger variantIconCount = game.variants.empty() ? variantStores.count : game.variants.size();
        for (NSUInteger index = 1; index < MIN((NSUInteger)4, variantIconCount); index++) {
            NSString *store = !game.variants.empty() ? OPNStoreString(game.variants[index].appStore, @"") : variantStores[index];
            if (store.length == 0) store = variantStores.count > index ? variantStores[index] : OPNStorePrimaryStoreName(game);
            NSImageView *iconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
            iconView.imageScaling = NSImageScaleProportionallyDown;
            iconView.image = OPNStoreGreyscaleIconImage(OPNCachedStoreIconImage(store) ?: OPNStoreIconPlaceholderImage(store));
            iconView.toolTip = OPNStoreDisplayLabel(store);
            iconView.contentTintColor = OpnColor(0xD7D8DC, 0.50);
            iconView.wantsLayer = YES;
            iconView.layer.backgroundColor = OpnColor(0x030506, 0.72).CGColor;
            iconView.layer.borderWidth = 1.0;
            iconView.layer.borderColor = OpnColor(0xFFFFFF, 0.18).CGColor;
            [_storeBadgeView addSubview:iconView];
            [_storeIconViews addObject:iconView];
            [_storeIconVariantIndexes addObject:@((int)index)];
            __weak NSImageView *weakIconView = iconView;
            OPNLoadStoreIconImage(store, ^(NSImage *image) {
                if (image && weakIconView) weakIconView.image = OPNStoreGreyscaleIconImage(image);
            });
        }

        NSString *title = game.title.empty() ? @"Untitled" : [NSString stringWithUTF8String:game.title.c_str()];
        _titleLabel = OpnLabel(title, NSZeroRect, titleSize, OpnColor(OPN::kTextPrimary), NSFontWeightBold);
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _titleLabel.maximumNumberOfLines = prominent ? 2 : 1;
        [self addSubview:_titleLabel];

        _metaLabel = OpnLabel(OPNStorePrimaryGenre(game), NSZeroRect, prominent ? 13.0 : 11.5, OpnColor(0xDBDEE5, 0.86), NSFontWeightSemibold);
        _metaLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self addSubview:_metaLabel];

        _featureLabel = OpnLabel(OPNStoreFeatureSummary(game), NSZeroRect, prominent ? 13.0 : 11.0, OpnColor(0xB9BDC7, 0.82), NSFontWeightMedium);
        _featureLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _featureLabel.maximumNumberOfLines = prominent ? 2 : 1;
        [self addSubview:_featureLabel];

        _availabilityLabel = OpnLabel(@"Cloud ready", NSZeroRect, prominent ? 12.0 : 10.5, OpnColor(OPN::kBrandGreen, 0.96), NSFontWeightBold, NSTextAlignmentRight);
        _availabilityLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self addSubview:_availabilityLabel];

        _playButton = [[NSButton alloc] initWithFrame:NSZeroRect];
        _playButton.title = OPNStorePrimaryActionTitle(game, _selectedVariantIndex, prominent);
        _playButton.bordered = NO;
        _playButton.font = [NSFont systemFontOfSize:prominent ? 14.0 : 11.0 weight:NSFontWeightBlack];
        _playButton.contentTintColor = OpnColor(OPN::kAccentOn);
        _playButton.wantsLayer = YES;
        _playButton.layer.backgroundColor = OpnColor(OPN::kBrandGreen, 0.98).CGColor;
        _playButton.layer.shadowColor = OpnColor(OPN::kBrandGreen).CGColor;
        _playButton.layer.shadowOpacity = prominent ? 0.42 : 0.0;
        _playButton.layer.shadowRadius = prominent ? 24.0 : 0.0;
        _playButton.layer.shadowOffset = CGSizeZero;
        _playButton.hidden = !prominent;
        _playButton.target = self;
        _playButton.action = @selector(selectPressed);
        [self addSubview:_playButton];

        self.selectedVariantIndex = _selectedVariantIndex;
        self.imageView.image = OPNStoreFallbackArtworkImage();
        [self updateTrackingAreas];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }
- (OPN::GameInfo)game { return _gameData; }

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    (void)event;
    return YES;
}

- (NSView *)hitTest:(NSPoint)point {
    NSView *hitView = [super hitTest:point];
    if (!hitView) return nil;
    if (hitView == self.playButton || [hitView isDescendantOf:self.playButton]) return hitView;
    return self;
}

- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds);
    CGFloat height = NSHeight(self.bounds);
    self.imageView.frame = self.bounds;
    self.gradientOverlay.frame = self.bounds;
    self.gradientLayer.frame = self.gradientOverlay.bounds;
    self.shineLayer.frame = NSMakeRect(width * 0.10, height - 5.0, width * 0.80, 5.0);
    self.shineLayer.cornerRadius = 2.5;
    self.accentLayer.frame = self.prominent ? NSMakeRect(0.0, 0.0, 5.0, height) : NSMakeRect(0.0, 0.0, width, 3.0);
    if (self.prominent) {
        CGFloat iconSize = 34.0;
        CGFloat iconGap = 8.0;
        CGFloat badgeWidth = self.storeIconViews.count * iconSize + MAX((NSUInteger)0, self.storeIconViews.count - 1) * iconGap;
        self.storeBadgeView.frame = NSMakeRect(30.0, 28.0, badgeWidth, 34.0);
        for (NSUInteger index = 0; index < self.storeIconViews.count; index++) {
            NSImageView *iconView = self.storeIconViews[index];
            iconView.frame = NSMakeRect(index * (iconSize + iconGap), 0.0, iconSize, iconSize);
            iconView.layer.cornerRadius = iconSize * 0.5;
        }
        self.availabilityLabel.frame = NSMakeRect(width - 188.0, 34.0, 150.0, 20.0);
        self.metaLabel.frame = NSMakeRect(30.0, height - 150.0, width - 220.0, 20.0);
        self.titleLabel.frame = NSMakeRect(30.0, height - 126.0, width - 220.0, 74.0);
        self.featureLabel.frame = NSMakeRect(30.0, height - 49.0, width - 210.0, 21.0);
        self.playButton.frame = NSMakeRect(width - 152.0, height - 70.0, 112.0, 42.0);
        self.playButton.layer.cornerRadius = 21.0;
    } else {
        CGFloat iconSize = 28.0;
        CGFloat iconGap = 6.0;
        CGFloat badgeWidth = self.storeIconViews.count * iconSize + MAX((NSUInteger)0, self.storeIconViews.count - 1) * iconGap;
        self.storeBadgeView.frame = NSMakeRect(12.0, 12.0, badgeWidth, 28.0);
        for (NSUInteger index = 0; index < self.storeIconViews.count; index++) {
            NSImageView *iconView = self.storeIconViews[index];
            iconView.frame = NSMakeRect(index * (iconSize + iconGap), 0.0, iconSize, iconSize);
            iconView.layer.cornerRadius = iconSize * 0.5;
        }
        self.availabilityLabel.frame = NSZeroRect;
        self.metaLabel.frame = NSZeroRect;
        self.titleLabel.frame = NSZeroRect;
        self.featureLabel.frame = NSZeroRect;
        self.playButton.frame = NSMakeRect(width - 64.0, height - 48.0, 50.0, 28.0);
        self.playButton.layer.cornerRadius = 14.0;
    }
    BOOL showProminentText = self.prominent;
    self.titleLabel.hidden = !showProminentText;
    self.metaLabel.hidden = !showProminentText;
    self.featureLabel.hidden = !showProminentText;
    self.availabilityLabel.hidden = !showProminentText;
}

- (void)setStoreFocused:(BOOL)focused {
    _storeFocused = focused;
    self.alphaValue = 1.0;
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.18];
    self.layer.borderWidth = focused ? 2.5 : 1.25;
    self.layer.borderColor = (focused ? OpnColor(OPN::kBrandGreen, 0.98) : OpnColor(0xFFFFFF, self.prominent ? 0.18 : 0.12)).CGColor;
    [self updateStoreIconSelection];
    self.shineLayer.opacity = focused ? 1.0 : (self.prominent ? 0.88 : 0.52);
    self.layer.shadowColor = OpnColor(OPN::kBrandGreen, 1.0).CGColor;
    self.layer.shadowOpacity = focused ? 0.38 : 0.0;
    self.layer.shadowRadius = focused ? 26.0 : 0.0;
    self.layer.shadowOffset = CGSizeZero;
    self.layer.zPosition = focused ? 10.0 : 0.0;
    self.layer.transform = CATransform3DIdentity;
    [CATransaction commit];
    self.playButton.hidden = !(self.prominent || focused);
}

- (void)updateStoreIconSelection {
    for (NSUInteger index = 0; index < self.storeIconViews.count; index++) {
        NSImageView *iconView = self.storeIconViews[index];
        int variantIndex = index < self.storeIconVariantIndexes.count ? self.storeIconVariantIndexes[index].intValue : -1;
        BOOL selected = variantIndex == self.selectedVariantIndex && !_gameData.variants.empty();
        iconView.layer.borderWidth = 1.0;
        iconView.layer.borderColor = (selected
            ? OpnColor(OPN::kBrandGreen, 0.96)
            : (self.storeFocused ? OpnColor(OPN::kBrandGreen, 0.42) : OpnColor(0xFFFFFF, 0.18))).CGColor;
        iconView.layer.backgroundColor = selected ? OpnColor(OPN::kBrandGreen, 0.24).CGColor : OpnColor(0x030506, 0.72).CGColor;
    }
}

- (void)cycleSelectedVariant {
    if (_gameData.variants.size() <= 1) return;
    if (self.storeIconVariantIndexes.count == 0) return;
    NSUInteger currentIconIndex = NSNotFound;
    for (NSUInteger index = 0; index < self.storeIconVariantIndexes.count; index++) {
        if (self.storeIconVariantIndexes[index].intValue == self.selectedVariantIndex) {
            currentIconIndex = index;
            break;
        }
    }
    NSUInteger nextIconIndex = currentIconIndex == NSNotFound ? 0 : (currentIconIndex + 1) % self.storeIconVariantIndexes.count;
    self.selectedVariantIndex = self.storeIconVariantIndexes[nextIconIndex].intValue;
}

- (void)selectPressed {
    if (self.onSelect) self.onSelect();
}

- (void)markUnownedPressed:(id)sender {
    (void)sender;
    if (self.onMarkUnowned) self.onMarkUnowned();
}

- (void)saveCurrentStreamSettingsAsProfilePressed:(id)sender {
    (void)sender;
    std::string appId = OPNStoreGameProfileAppId(_gameData, self.selectedVariantIndex);
    if (appId.empty()) return;
    OPN::SaveStreamPreferenceProfileForGame(appId, OPN::LoadStreamPreferenceProfile());
    self.selectedVariantIndex = self.selectedVariantIndex;
}

- (void)togglePerGameStreamProfilePressed:(id)sender {
    (void)sender;
    std::string appId = OPNStoreGameProfileAppId(_gameData, self.selectedVariantIndex);
    if (appId.empty() || !OPN::StreamPreferenceProfileExistsForGame(appId)) return;
    OPN::SetStreamPreferenceProfileEnabledForGame(appId, !OPN::StreamPreferenceProfileEnabledForGame(appId));
    self.selectedVariantIndex = self.selectedVariantIndex;
}

- (void)deletePerGameStreamProfilePressed:(id)sender {
    (void)sender;
    std::string appId = OPNStoreGameProfileAppId(_gameData, self.selectedVariantIndex);
    if (appId.empty()) return;
    OPN::DeleteStreamPreferenceProfileForGame(appId);
    self.selectedVariantIndex = self.selectedVariantIndex;
}

- (NSMenu *)menuForEvent:(NSEvent *)event {
    (void)event;
    std::string appId = OPNStoreGameProfileAppId(_gameData, self.selectedVariantIndex);
    BOOL hasAppId = !appId.empty();
    BOOL hasProfile = hasAppId && OPN::StreamPreferenceProfileExistsForGame(appId);
    BOOL profileEnabled = hasAppId && OPN::StreamPreferenceProfileEnabledForGame(appId);
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Game Actions"];
    NSMenuItem *saveProfileItem = [[NSMenuItem alloc] initWithTitle:@"Save Current Stream Settings as Game Profile"
                                                             action:@selector(saveCurrentStreamSettingsAsProfilePressed:)
                                                      keyEquivalent:@""];
    saveProfileItem.target = self;
    saveProfileItem.enabled = hasAppId;
    [menu addItem:saveProfileItem];

    NSMenuItem *toggleProfileItem = [[NSMenuItem alloc] initWithTitle:@"Use Game Stream Profile"
                                                               action:@selector(togglePerGameStreamProfilePressed:)
                                                        keyEquivalent:@""];
    toggleProfileItem.target = self;
    toggleProfileItem.enabled = hasProfile;
    toggleProfileItem.state = profileEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:toggleProfileItem];

    NSMenuItem *deleteProfileItem = [[NSMenuItem alloc] initWithTitle:@"Delete Game Stream Profile"
                                                               action:@selector(deletePerGameStreamProfilePressed:)
                                                        keyEquivalent:@""];
    deleteProfileItem.target = self;
    deleteProfileItem.enabled = hasProfile;
    [menu addItem:deleteProfileItem];

    if (!OPNStoreVariantCanBeMarkedUnowned(_gameData, self.selectedVariantIndex)) return menu;
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *markUnownedItem = [[NSMenuItem alloc] initWithTitle:@"Mark Selected Store as Unowned"
                                                             action:@selector(markUnownedPressed:)
                                                      keyEquivalent:@""];
    markUnownedItem.target = self;
    [menu addItem:markUnownedItem];
    return menu;
}

- (void)activate {
    [self selectPressed];
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint localPoint = [self convertPoint:event.locationInWindow fromView:nil];
    NSPoint badgePoint = [self.storeBadgeView convertPoint:localPoint fromView:self];
    self.pendingMouseSelection = NO;
    self.draggingRail = NO;
    for (NSUInteger index = 0; index < self.storeIconViews.count; index++) {
        NSImageView *iconView = self.storeIconViews[index];
        if (!NSPointInRect([iconView convertPoint:badgePoint fromView:self.storeBadgeView], iconView.bounds)) continue;
        if (index < self.storeIconVariantIndexes.count) {
            int variantIndex = self.storeIconVariantIndexes[index].intValue;
            if (variantIndex >= 0 && variantIndex < (int)_gameData.variants.size()) self.selectedVariantIndex = variantIndex;
        }
        return;
    }
    self.pendingMouseSelection = YES;
    self.lastDragLocationInWindow = event.locationInWindow;
    NSScrollView *scrollView = self.enclosingScrollView;
    if ([scrollView isKindOfClass:OPNStoreRailScrollView.class]) {
        [(OPNStoreRailScrollView *)scrollView beginDragScrollingAtTime:event.timestamp];
    }
}

- (void)mouseDragged:(NSEvent *)event {
    if (!self.pendingMouseSelection && !self.draggingRail) {
        [super mouseDragged:event];
        return;
    }
    NSPoint location = event.locationInWindow;
    CGFloat deltaX = self.lastDragLocationInWindow.x - location.x;
    CGFloat deltaY = self.lastDragLocationInWindow.y - location.y;
    BOOL dragThresholdReached = self.draggingRail || std::hypot(deltaX, deltaY) >= 4.0;
    self.lastDragLocationInWindow = location;
    if (!dragThresholdReached) return;

    self.pendingMouseSelection = NO;
    self.draggingRail = YES;
    NSScrollView *scrollView = self.enclosingScrollView;
    if ([scrollView isKindOfClass:OPNStoreRailScrollView.class]) {
        [(OPNStoreRailScrollView *)scrollView dragScrollHorizontallyByDelta:deltaX timestamp:event.timestamp];
    }
}

- (void)mouseUp:(NSEvent *)event {
    (void)event;
    BOOL shouldSelect = self.pendingMouseSelection && !self.draggingRail;
    BOOL shouldContinueScroll = self.draggingRail;
    self.pendingMouseSelection = NO;
    self.draggingRail = NO;
    if (shouldContinueScroll) {
        NSScrollView *scrollView = self.enclosingScrollView;
        if ([scrollView isKindOfClass:OPNStoreRailScrollView.class]) {
            [(OPNStoreRailScrollView *)scrollView endDragScrollingWithInertia];
        }
    }
    if (shouldSelect) [self selectPressed];
}

- (void)mouseEntered:(NSEvent *)event {
    (void)event;
    if (self.onHover) self.onHover();
    if (!self.prominent) self.playButton.hidden = NO;
    if (!self.storeFocused) self.layer.borderColor = OpnColor(OPN::kBrandGreen, 0.42).CGColor;
}

- (void)mouseExited:(NSEvent *)event {
    (void)event;
    if (!self.prominent && !self.storeFocused) self.playButton.hidden = YES;
    if (!self.storeFocused) self.layer.borderColor = OpnColor(0xFFFFFF, self.prominent ? 0.18 : 0.12).CGColor;
}

- (void)resetMouseTrackingIfOutside {
    if (self.prominent || self.storeFocused) return;
    NSWindow *window = self.window;
    if (!window) return;
    NSPoint screenPoint = [NSEvent mouseLocation];
    NSPoint windowPoint = [window convertPointFromScreen:screenPoint];
    NSPoint localPoint = [self convertPoint:windowPoint fromView:nil];
    if (!NSPointInRect(localPoint, self.bounds)) {
        self.playButton.hidden = YES;
        self.layer.borderColor = OpnColor(0xFFFFFF, 0.12).CGColor;
    }
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.trackingArea && [self.trackingAreas containsObject:self.trackingArea]) {
        [self removeTrackingArea:self.trackingArea];
    }
    self.trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                     options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInActiveApp
                                                       owner:self
                                                    userInfo:nil];
    [self addTrackingArea:self.trackingArea];
}

- (void)loadImage {
    self.imageLoadGeneration++;
    NSArray<NSString *> *candidates = OPNStoreImageCandidatesForGame(_gameData, self.prominent);
    if (candidates.count == 0) {
        self.imageView.image = OPNStoreFallbackArtworkImage();
        return;
    }
    [self loadImageFromCandidates:candidates index:0];
}

- (void)ensureImageLoaded {
    if (self.imageLoadRequested) return;
    self.imageLoadRequested = YES;
    [self loadImage];
}

- (void)cancelImageLoad {
    if (!self.imageLoadToken) return;
    [self.imageLoadToken cancel];
    self.imageLoadToken = nil;
    self.imageLoadRequested = self.imageView.image != nil && self.imageView.image != OPNStoreFallbackArtworkImage();
    self.imageLoadGeneration++;
}

- (void)loadImageFromCandidates:(NSArray<NSString *> *)urlStrings index:(NSUInteger)index {
    NSUInteger generation = self.imageLoadGeneration;
    if (index >= urlStrings.count) {
        if (!self.imageView.image) self.imageView.image = OPNStoreFallbackArtworkImage();
        return;
    }
    NSString *urlString = urlStrings[index];
    if (urlString.length == 0) {
        [self loadImageFromCandidates:urlStrings index:index + 1];
        return;
    }

    __weak __typeof__(self) weakSelf = self;
    CGFloat scale = self.window.screen.backingScaleFactor > 0.0 ? self.window.screen.backingScaleFactor : NSScreen.mainScreen.backingScaleFactor;
    CGFloat maxPixelDimension = MAX(NSWidth(self.bounds), NSHeight(self.bounds)) * MAX(1.0, scale) * (self.prominent ? 1.6 : 1.25);
    self.imageLoadToken = OpnLoadImageForURLCancellable(urlString, maxPixelDimension, ^(NSImage *image, NSString *resolvedURL, NSData *data) {
        (void)resolvedURL;
        (void)data;
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (generation != strongSelf.imageLoadGeneration) return;
        strongSelf.imageLoadToken = nil;
        if (!image) {
            [strongSelf loadImageFromCandidates:urlStrings index:index + 1];
            return;
        }
        NSTimeInterval revealDelay = strongSelf.imageView.image ? 0.0 : strongSelf.imageRevealDelay;
        strongSelf.imageView.alphaValue = 0.0;
        strongSelf.imageView.image = image;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(revealDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __typeof__(self) revealSelf = weakSelf;
            if (!revealSelf || generation != revealSelf.imageLoadGeneration) return;
            [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
                context.duration = 0.22;
                context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
                revealSelf.imageView.animator.alphaValue = 1.0;
            } completionHandler:nil];
        });
    });
}

@end


@implementation OPNStoreRowLayout
@end
