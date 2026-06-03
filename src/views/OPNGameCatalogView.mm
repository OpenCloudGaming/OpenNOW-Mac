#import "OPNGameCatalogView.h"
#import "OPNGameCardView.h"
#import "OPNLoadingView.h"
#import "../common/OPNColorTokens.h"
#import "../common/OPNUIHelpers.h"
#include "common/OPNSentry.h"
#include <QuartzCore/QuartzCore.h>
#include <algorithm>
#include <cmath>
#include <cstring>

static const CGFloat kCatalogMinContentInset = 30.0;
static const CGFloat kCatalogMaxContentInset = 106.0;
static const CGFloat kCatalogContentInsetRatio = 0.055;
static const CGFloat kCatalogMinCardWidth = 200.0;
static const CGFloat kCatalogColumnSpacing = 12.0;
static const CGFloat kCatalogTopInset = 170.0;
static const CGFloat kCatalogHeroGap = 62.0;
static const CGFloat kCatalogGridPadding = 28.0;
static const CGFloat kCatalogHeroRatio = 0.3229;
static const NSInteger kCatalogRenderBufferCards = 3;
static const CGFloat kCatalogFallbackHeroAspect = 1.0 / kCatalogHeroRatio;

static CGFloat OPNCatalogHeightScale(CGFloat height) {
    return MIN(1.0, MAX(0.80, MAX(1.0, height) / 900.0));
}

typedef struct {
    CGFloat pageWidth;
    CGFloat contentX;
    CGFloat contentWidth;
    NSInteger columns;
    CGFloat cardWidth;
    CGFloat cardHeight;
    CGFloat spacing;
} OPNCatalogGridMetrics;

static OPNCatalogGridMetrics OPNCatalogGridMetricsForSize(CGFloat width, CGFloat height) {
    CGFloat pageWidth = MAX(1.0, width);
    CGFloat scale = OPNCatalogHeightScale(height);
    CGFloat minimumCardWidth = floor(kCatalogMinCardWidth * scale);
    CGFloat spacing = floor(MAX(9.0, kCatalogColumnSpacing * scale));
    CGFloat contentInset = MIN(kCatalogMaxContentInset, MAX(kCatalogMinContentInset, pageWidth * kCatalogContentInsetRatio));
    CGFloat contentWidth = MAX(1.0, pageWidth - contentInset * 2.0);
    NSInteger columns = MAX(1, (NSInteger)floor((contentWidth + spacing) / (minimumCardWidth + spacing)));
    CGFloat totalSpacing = MAX(0, columns - 1) * spacing;
    CGFloat cardWidth = floor(MAX(1.0, (contentWidth - totalSpacing) / MAX(1, columns)));
    OPNCatalogGridMetrics metrics = { pageWidth, floor(contentInset), contentWidth, columns, cardWidth, cardWidth, spacing };
    return metrics;
}

static NSString *OPNCatalogString(const std::string &value, NSString *fallback) {
    if (value.empty()) return fallback ?: @"";
    NSString *string = [NSString stringWithUTF8String:value.c_str()];
    return string.length > 0 ? string : (fallback ?: @"");
}

static BOOL OPNGameVariantIsAccessible(const OPN::GameVariant &variant) {
    return variant.librarySelected || variant.inLibrary ||
        variant.serviceStatus == "MANUAL" ||
        variant.serviceStatus == "PLATFORM_SYNC" ||
        variant.serviceStatus == "IN_LIBRARY";
}

static BOOL OPNLibraryGameHasAccessibleVariants(const OPN::GameInfo &game) {
    if (game.isInLibrary) return YES;
    for (const OPN::GameVariant &variant : game.variants) {
        if (OPNGameVariantIsAccessible(variant)) return YES;
    }
    return game.variants.empty();
}

static OPN::GameInfo OPNLibraryGameWithAccessibleVariants(const OPN::GameInfo &game) {
    OPN::GameInfo libraryGame = game;
    std::vector<OPN::GameVariant> variants;
    for (const OPN::GameVariant &variant : game.variants) {
        if (OPNGameVariantIsAccessible(variant)) variants.push_back(variant);
    }
    if (!variants.empty()) libraryGame.variants = variants;
    return libraryGame;
}

static NSString *OPNGameIdentity(const OPN::GameInfo &game) {
    if (!game.id.empty()) return [NSString stringWithUTF8String:game.id.c_str()];
    if (!game.uuid.empty()) return [NSString stringWithUTF8String:game.uuid.c_str()];
    if (!game.launchAppId.empty()) return [NSString stringWithUTF8String:game.launchAppId.c_str()];
    return OPNCatalogString(game.title, @"");
}

static NSArray<NSString *> *OPNHeroImageCandidates(const OPN::GameInfo &game) {
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    auto append = ^(NSString *value) {
        if (value.length > 0 && ![candidates containsObject:value]) [candidates addObject:value];
    };
    auto appendType = [&](const char *type) {
        auto it = game.imageUrlsByType.find(type);
        if (it == game.imageUrlsByType.end()) return;
        for (const std::string &url : it->second) append(OPNCatalogString(url, @""));
    };
    appendType("MARQUEE_HERO_IMAGE");
    appendType("HERO_IMAGE");
    appendType("TV_BANNER");
    appendType("FEATURE_IMAGE");
    appendType("KEY_ART");
    appendType("KEY_IMAGE");
    append(OPNCatalogString(game.heroImageUrl, @""));
    append(OPNCatalogString(game.imageUrl, @""));
    return candidates;
}

@interface OPNCatalogScrollView : NSScrollView
@end

@implementation OPNCatalogScrollView
- (void)scrollWheel:(NSEvent *)event {
    [super scrollWheel:event];
    NSClipView *clipView = self.contentView;
    if (clipView.bounds.origin.y != 0.0) {
        [clipView scrollToPoint:NSMakePoint(clipView.bounds.origin.x, 0.0)];
        [self reflectScrolledClipView:clipView];
    }
}
@end

@interface OPNFlippedDocumentView : NSView
@end

@implementation OPNFlippedDocumentView
- (BOOL)isFlipped { return YES; }
@end

@interface OPNCatalogAmbientView : NSView
@end

@implementation OPNCatalogAmbientView
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSRect bounds = self.bounds;
    if (NSIsEmptyRect(bounds)) return;
    NSGradient *base = [[NSGradient alloc] initWithColorsAndLocations:
        OpnColor(0x020405, 1.0), 0.0,
        OpnColor(0x07120D, 1.0), 0.34,
        OpnColor(0x11141A, 1.0), 0.62,
        OpnColor(0x030405, 1.0), 1.0,
        nil];
    [base drawInRect:bounds angle:-38.0];
    NSGradient *greenBloom = [[NSGradient alloc] initWithColors:@[
        OpnColor(OPN::kBrandGreen, 0.20),
        OpnColor(OPN::kBrandGreen, 0.05),
        OpnColor(OPN::kBrandGreen, 0.0)
    ]];
    [greenBloom drawFromCenter:NSMakePoint(NSMinX(bounds) + NSWidth(bounds) * 0.20, NSMinY(bounds) + 188.0)
                        radius:12.0
                      toCenter:NSMakePoint(NSMinX(bounds) + NSWidth(bounds) * 0.24, NSMinY(bounds) + 230.0)
                        radius:620.0
                       options:0];
}
@end

@interface OPNHeroArtworkView : NSView
@property (nonatomic, strong) NSImage *image;
@end

@implementation OPNHeroArtworkView
- (BOOL)isFlipped { return YES; }
- (void)setImage:(NSImage *)image {
    _image = image;
    [self setNeedsDisplay:YES];
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [OpnColor(0x030506, 1.0) setFill];
    NSRectFill(self.bounds);
    if (!self.image || self.image.size.width <= 0.0 || self.image.size.height <= 0.0) return;
    CGFloat imageAspect = self.image.size.width / self.image.size.height;
    CGFloat viewAspect = MAX(1.0, NSWidth(self.bounds)) / MAX(1.0, NSHeight(self.bounds));
    NSRect target = self.bounds;
    if (imageAspect > viewAspect) {
        target.size.height = floor(NSWidth(self.bounds) / imageAspect);
        target.origin.y = floor((NSHeight(self.bounds) - NSHeight(target)) * 0.5);
    } else if (imageAspect < viewAspect) {
        target.size.width = floor(NSHeight(self.bounds) * imageAspect);
        target.origin.x = floor((NSWidth(self.bounds) - NSWidth(target)) * 0.5);
    }
    [self.image drawInRect:target fromRect:NSMakeRect(0.0, 0.0, self.image.size.width, self.image.size.height) operation:NSCompositingOperationSourceOver fraction:1.0 respectFlipped:YES hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
}
@end

@interface OPNGameCatalogView ()
@property (nonatomic, strong) OPNCatalogScrollView *scrollView;
@property (nonatomic, strong) OPNFlippedDocumentView *documentView;
@property (nonatomic, strong) OPNLoadingView *loadingView;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSView *heroContainerView;
@property (nonatomic, strong) NSView *sectionHeaderView;
@property (nonatomic, strong) OPNCatalogAmbientView *ambientView;
@property (nonatomic, strong) NSMutableArray<OPNGameCardView *> *cardViews;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, OPNGameCardView *> *cardViewsByIndex;
@property (nonatomic, strong) NSMutableArray<OpnImageLoadToken *> *imageLoadTokens;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *heroAspectByIdentity;
@property (nonatomic, strong) NSTimer *heroRotationTimer;
@property (nonatomic, assign) std::vector<OPN::GameInfo> allGames;
@property (nonatomic, assign) std::vector<OPN::GameInfo> featuredGames;
@property (nonatomic, assign) std::vector<OPN::GameInfo> displayGames;
@property (nonatomic, assign) std::vector<OPN::GameInfo> heroGames;
@property (nonatomic, assign) NSInteger renderStartIndex;
@property (nonatomic, assign) NSInteger displayGameCount;
@property (nonatomic, assign) NSInteger focusedGameIndex;
@property (nonatomic, assign) NSInteger currentHeroIndex;
@property (nonatomic, assign) NSRect heroFrame;
@property (nonatomic, assign) CGFloat cachedCardStartY;
@property (nonatomic, assign) CGFloat lastLayoutWidth;
@property (nonatomic, assign) BOOL renderScheduled;
- (void)renderCatalog;
- (void)scheduleRenderCatalog;
- (std::vector<OPN::GameInfo>)featuredLibraryGamesWithFallback:(const std::vector<OPN::GameInfo> &)fallbackGames;
- (void)addHeroForGame:(const OPN::GameInfo &)game frame:(NSRect)frame;
- (void)loadHeroArtworkForView:(OPNHeroArtworkView *)view gameIdentity:(NSString *)gameIdentity candidates:(NSArray<NSString *> *)candidates index:(NSUInteger)index;
- (void)cancelImageLoads;
- (void)renderVisibleCardsWithMetrics:(OPNCatalogGridMetrics)metrics totalCards:(NSInteger)totalCards;
- (void)scrollFocusedGameIntoViewWithMetrics:(OPNCatalogGridMetrics)metrics;
- (void)configureHeroRotationTimer;
- (CGFloat)heroAspectForGame:(const OPN::GameInfo &)game;
- (const OPN::GameInfo *)currentHeroGame;
- (void)heroRotationTimerFired:(NSTimer *)timer;
- (void)updateHeroOnly;
@end

@implementation OPNGameCatalogView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = NSColor.clearColor.CGColor;
        _cardViews = [NSMutableArray array];
        _cardViewsByIndex = [NSMutableDictionary dictionary];
        _imageLoadTokens = [NSMutableArray array];
        _heroAspectByIdentity = [NSMutableDictionary dictionary];
        _renderStartIndex = 0;
        _focusedGameIndex = 0;
        _currentHeroIndex = 0;
        _heroFrame = NSZeroRect;

        _scrollView = [[OPNCatalogScrollView alloc] initWithFrame:self.bounds];
        _scrollView.drawsBackground = NO;
        _scrollView.borderType = NSNoBorder;
        _scrollView.hasVerticalScroller = NO;
        _scrollView.hasHorizontalScroller = YES;
        _scrollView.autohidesScrollers = YES;
        _scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        _scrollView.contentView.postsBoundsChangedNotifications = YES;
        [self addSubview:_scrollView];

        _documentView = [[OPNFlippedDocumentView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(frame), NSHeight(frame))];
        _documentView.wantsLayer = YES;
        _documentView.layer.backgroundColor = NSColor.clearColor.CGColor;
        _scrollView.documentView = _documentView;

        _statusLabel = OpnLabel(@"", NSZeroRect, 15.0, OpnColor(OPN::kTextMuted), NSFontWeightMedium, NSTextAlignmentCenter);
        [self addSubview:_statusLabel];

        _loadingView = [[OPNLoadingView alloc] initWithFrame:self.bounds message:@"Loading games..."];
        _loadingView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        _loadingView.hidden = YES;
        [self addSubview:_loadingView];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(scrollViewBoundsDidChange:)
                                                     name:NSViewBoundsDidChangeNotification
                                                   object:_scrollView.contentView];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.heroRotationTimer invalidate];
    [self cancelImageLoads];
}

- (BOOL)isFlipped { return YES; }

- (void)layout {
    [super layout];
    self.loadingView.frame = self.bounds;
    self.statusLabel.frame = NSMakeRect(0.0, NSHeight(self.bounds) * 0.5, NSWidth(self.bounds), 26.0);
    CGFloat cardStartY = self.cachedCardStartY > 0.0 ? self.cachedCardStartY : NSHeight(self.bounds) * 0.5;
    self.scrollView.frame = NSMakeRect(0.0, cardStartY, NSWidth(self.bounds), MAX(0.0, NSHeight(self.bounds) - cardStartY));
    self.ambientView.frame = self.bounds;
    if (std::fabs(self.lastLayoutWidth - NSWidth(self.bounds)) > 1.0) {
        self.lastLayoutWidth = NSWidth(self.bounds);
        [self scheduleRenderCatalog];
    }
}

- (void)setGames:(const std::vector<OPN::GameInfo> &)games {
    _allGames = games;
    self.currentHeroIndex = 0;
    [self renderCatalog];
}

- (void)setCatalogBrowseResult:(const OPN::CatalogBrowseResult &)result {
    _allGames = result.games;
    self.currentHeroIndex = 0;
    if (self.onGameCountChanged) self.onGameCountChanged(result.totalCount > 0 ? result.totalCount : (NSInteger)result.games.size());
    [self renderCatalog];
}

- (void)setFeaturedGames:(const std::vector<OPN::GameInfo> &)games {
    _featuredGames = games;
    self.currentHeroIndex = 0;
    [self renderCatalog];
}

- (void)setActiveSessionAppIds:(const std::vector<int> &)appIds {
    (void)appIds;
}

- (void)setLoading:(BOOL)loading {
    self.loadingView.hidden = !loading;
    if (loading) [self.loadingView startAnimating]; else [self.loadingView stopAnimating];
}

- (void)setError:(NSString *)message {
    self.statusLabel.stringValue = message ?: @"";
    [self setLoading:NO];
}

- (void)setUserName:(NSString *)name {
    (void)name;
}

- (void)scheduleRenderCatalog {
    if (self.renderScheduled) return;
    self.renderScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.renderScheduled = NO;
        [self renderCatalog];
    });
}

- (void)cancelImageLoads {
    for (OpnImageLoadToken *token in self.imageLoadTokens) [token cancel];
    [self.imageLoadTokens removeAllObjects];
}

- (void)trackImageLoadToken:(OpnImageLoadToken *)token {
    if (!token) return;
    [self.imageLoadTokens addObject:token];
    if (self.imageLoadTokens.count > 32) [self.imageLoadTokens removeObjectsInRange:NSMakeRange(0, self.imageLoadTokens.count - 24)];
}

- (std::vector<OPN::GameInfo>)displayLibraryGames {
    std::vector<OPN::GameInfo> games;
    games.reserve(_allGames.size());
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (const OPN::GameInfo &game : _allGames) {
        if (!OPNLibraryGameHasAccessibleVariants(game)) continue;
        OPN::GameInfo libraryGame = OPNLibraryGameWithAccessibleVariants(game);
        NSString *identity = OPNGameIdentity(libraryGame);
        if (identity.length > 0 && [seen containsObject:identity]) continue;
        if (identity.length > 0) [seen addObject:identity];
        games.push_back(libraryGame);
    }
    return games;
}

- (std::vector<OPN::GameInfo>)featuredLibraryGamesWithFallback:(const std::vector<OPN::GameInfo> &)fallbackGames {
    std::vector<OPN::GameInfo> games;
    games.reserve(_featuredGames.empty() ? fallbackGames.size() : _featuredGames.size());
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    auto appendGame = [&](const OPN::GameInfo &game) {
        if (games.size() >= 6) return;
        if (!OPNLibraryGameHasAccessibleVariants(game)) return;
        OPN::GameInfo libraryGame = OPNLibraryGameWithAccessibleVariants(game);
        NSString *identity = OPNGameIdentity(libraryGame);
        if (identity.length > 0 && [seen containsObject:identity]) return;
        if (identity.length > 0) [seen addObject:identity];
        games.push_back(libraryGame);
    };
    for (const OPN::GameInfo &game : _featuredGames) appendGame(game);
    if (games.empty()) {
        for (const OPN::GameInfo &game : fallbackGames) appendGame(game);
    }
    return games;
}

- (void)addHeroForGame:(const OPN::GameInfo &)game frame:(NSRect)frame {
    NSView *stage = [[NSView alloc] initWithFrame:frame];
    CGFloat scale = OPNCatalogHeightScale(NSHeight(self.bounds));
    stage.wantsLayer = YES;
    stage.layer.cornerRadius = 34.0 * scale;
    stage.layer.masksToBounds = YES;
    stage.layer.borderWidth = MAX(1.0, 2.0 * scale);
    stage.layer.borderColor = OpnColor(0x203040, 0.92).CGColor;
    stage.layer.shadowColor = OpnColor(0x000000, 1.0).CGColor;
    stage.layer.shadowOpacity = 0.48;
    stage.layer.shadowRadius = 34.0 * scale;
    stage.layer.shadowOffset = CGSizeMake(0.0, 22.0 * scale);
    self.heroContainerView = stage;
    [self addSubview:stage positioned:NSWindowAbove relativeTo:self.ambientView];

    OPNHeroArtworkView *artwork = [[OPNHeroArtworkView alloc] initWithFrame:stage.bounds];
    artwork.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [stage addSubview:artwork];
    [self loadHeroArtworkForView:artwork gameIdentity:OPNGameIdentity(game) candidates:OPNHeroImageCandidates(game) index:0];
}

- (void)configureHeroRotationTimer {
    [self.heroRotationTimer invalidate];
    self.heroRotationTimer = nil;
    if (_heroGames.size() < 2 || NSIsEmptyRect(self.heroFrame)) return;

    self.heroRotationTimer = [NSTimer scheduledTimerWithTimeInterval:7.0
                                                              target:self
                                                            selector:@selector(heroRotationTimerFired:)
                                                            userInfo:nil
                                                             repeats:YES];
}

- (const OPN::GameInfo *)currentHeroGame {
    NSInteger candidateCount = MIN((NSInteger)6, (NSInteger)_heroGames.size());
    if (candidateCount <= 0) return nullptr;
    NSInteger target = ((self.currentHeroIndex % candidateCount) + candidateCount) % candidateCount;
    return &_heroGames[(size_t)target];
}

- (CGFloat)heroAspectForGame:(const OPN::GameInfo &)game {
    NSNumber *aspect = self.heroAspectByIdentity[OPNGameIdentity(game)];
    return aspect.doubleValue > 0.0 ? aspect.doubleValue : kCatalogFallbackHeroAspect;
}

- (void)heroRotationTimerFired:(NSTimer *)timer {
    (void)timer;
    NSInteger candidateCount = MIN((NSInteger)6, (NSInteger)_heroGames.size());
    if (candidateCount < 2) return;
    self.currentHeroIndex = (self.currentHeroIndex + 1) % candidateCount;
    [self updateHeroOnly];
}

- (void)updateHeroOnly {
    const OPN::GameInfo *heroGame = [self currentHeroGame];
    if (!heroGame || NSIsEmptyRect(self.heroFrame) || !self.ambientView) {
        [self renderCatalog];
        return;
    }

    NSView *oldHero = self.heroContainerView;
    [self addHeroForGame:*heroGame frame:self.heroFrame];
    NSView *newHero = self.heroContainerView;
    newHero.alphaValue = 0.0;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.18;
        context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        oldHero.animator.alphaValue = 0.0;
        newHero.animator.alphaValue = 1.0;
    } completionHandler:^{
        [oldHero removeFromSuperview];
    }];
}

- (void)loadHeroArtworkForView:(OPNHeroArtworkView *)view gameIdentity:(NSString *)gameIdentity candidates:(NSArray<NSString *> *)candidates index:(NSUInteger)index {
    if (!view || index >= candidates.count) return;
    __weak OPNHeroArtworkView *weakView = view;
    __weak __typeof__(self) weakSelf = self;
    OpnImageLoadToken *token = OpnLoadImageForURLCancellable(candidates[index], 1600.0, ^(NSImage *image, NSString *resolvedURL, NSData *data) {
        (void)resolvedURL;
        (void)data;
        OPNHeroArtworkView *strongView = weakView;
        if (!strongView.superview) return;
        if (!image) {
            [weakSelf loadHeroArtworkForView:strongView gameIdentity:gameIdentity candidates:candidates index:index + 1];
            return;
        }
        if (image.size.width > 0.0 && image.size.height > 0.0 && gameIdentity.length > 0) {
            CGFloat aspect = image.size.width / image.size.height;
            NSNumber *previousAspect = weakSelf.heroAspectByIdentity[gameIdentity];
            weakSelf.heroAspectByIdentity[gameIdentity] = @(aspect);
            const OPN::GameInfo *currentHero = [weakSelf currentHeroGame];
            BOOL currentHeroMatches = currentHero && [OPNGameIdentity(*currentHero) isEqualToString:gameIdentity];
            if (currentHeroMatches && (!previousAspect || std::fabs(previousAspect.doubleValue - aspect) > 0.01)) {
                [weakSelf scheduleRenderCatalog];
                return;
            }
        }
        strongView.image = image;
    });
    [self trackImageLoadToken:token];
}

- (void)renderCatalog {
    [self cancelImageLoads];
    for (NSView *view in [self.documentView.subviews copy]) [view removeFromSuperview];
    for (OPNGameCardView *card in self.cardViews) [card removeFromSuperview];
    [self.cardViews removeAllObjects];
    [self.cardViewsByIndex removeAllObjects];
    [self.heroContainerView removeFromSuperview];
    self.heroContainerView = nil;
    self.heroFrame = NSZeroRect;
    [self.sectionHeaderView removeFromSuperview];
    self.sectionHeaderView = nil;
    [self.ambientView removeFromSuperview];
    self.ambientView = nil;

    CGFloat width = MAX(1.0, NSWidth(self.bounds));
    CGFloat height = MAX(1.0, NSHeight(self.bounds));
    CGFloat scale = OPNCatalogHeightScale(height);
    OPNCatalogGridMetrics metrics = OPNCatalogGridMetricsForSize(width, height);
    self.displayGames = [self displayLibraryGames];
    self.displayGameCount = (NSInteger)self.displayGames.size();
    self.focusedGameIndex = self.displayGameCount > 0 ? MAX(0, MIN(self.focusedGameIndex, self.displayGameCount - 1)) : 0;

    OPNCatalogAmbientView *ambient = [[OPNCatalogAmbientView alloc] initWithFrame:self.bounds];
    ambient.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:ambient positioned:NSWindowBelow relativeTo:nil];
    self.ambientView = ambient;

    self.heroGames = [self featuredLibraryGamesWithFallback:self.displayGames];
    if (_heroGames.size() > 6) _heroGames.resize(6);
    BOOL hasHero = !_heroGames.empty();
    self.currentHeroIndex = hasHero ? MAX(0, MIN(self.currentHeroIndex, (NSInteger)_heroGames.size() - 1)) : 0;
    CGFloat sectionHeight = MIN(82.0, MAX(42.0, floor(height * 0.064)));
    CGFloat bottomPadding = MIN(36.0, MAX(14.0, floor(height * 0.030)));
    CGFloat topInset = MIN(kCatalogTopInset * scale, MAX(104.0, floor(height * 0.17)));
    CGFloat heroGap = MAX(38.0, floor(kCatalogHeroGap * scale));
    CGFloat gridPadding = MAX(18.0, floor(kCatalogGridPadding * scale));
    const OPN::GameInfo *heroGame = hasHero ? [self currentHeroGame] : nullptr;
    CGFloat heroAspect = heroGame ? [self heroAspectForGame:*heroGame] : kCatalogFallbackHeroAspect;
    CGFloat maximumHeroHeight = hasHero ? 520.0 : 0.0;
    CGFloat idealHeroHeight = hasHero ? floor(metrics.contentWidth / MAX(0.1, heroAspect)) : 0.0;
    CGFloat availableHeroHeight = height - bottomPadding - metrics.cardHeight - sectionHeight - heroGap - topInset;
    if (availableHeroHeight < 0.0) {
        CGFloat recovery = MIN(topInset - 72.0 * scale, -availableHeroHeight);
        topInset -= MAX(0.0, recovery);
        availableHeroHeight = height - bottomPadding - metrics.cardHeight - sectionHeight - heroGap - topInset;
    }
    CGFloat heroHeight = hasHero ? floor(MIN(MIN(idealHeroHeight, maximumHeroHeight), MAX(0.0, availableHeroHeight))) : 0.0;
    CGFloat heroWidth = hasHero ? floor(MIN(metrics.contentWidth, heroHeight * heroAspect)) : 0.0;
    if (hasHero && heroHeight > 1.0 && heroWidth > 1.0 && heroGame) {
        CGFloat heroX = metrics.contentX + floor((metrics.contentWidth - heroWidth) * 0.5);
        self.heroFrame = NSMakeRect(heroX, topInset, heroWidth, heroHeight);
        [self addHeroForGame:*heroGame frame:self.heroFrame];
    }
    [self configureHeroRotationTimer];

    CGFloat gridTop = hasHero && heroHeight > 1.0 ? topInset + heroHeight + heroGap : topInset;
    NSView *sectionContainer = [[NSView alloc] initWithFrame:NSMakeRect(0.0, gridTop, metrics.pageWidth, sectionHeight + 14.0)];
    NSString *countText = [NSString stringWithFormat:@"%ld %@", (long)self.displayGameCount, self.displayGameCount == 1 ? @"game" : @"games"];
    NSTextField *section = OpnLabel(@"Library", NSMakeRect(metrics.contentX, 0.0, MIN(520.0, metrics.contentWidth - 180.0), sectionHeight), MIN(42.0, MAX(26.0, floor(sectionHeight * 0.70))), OpnColor(OPN::kTextPrimary), NSFontWeightBlack);
    [sectionContainer addSubview:section];
    CGFloat countX = metrics.contentX + MIN(250.0, MAX(172.0, metrics.contentWidth * 0.22));
    NSTextField *count = OpnLabel(countText, NSMakeRect(countX, MAX(0.0, floor((sectionHeight - 24.0) * 0.52)), 180.0, 24.0), MIN(22.0, MAX(13.0, floor(sectionHeight * 0.34))), OpnColor(OPN::kTextMuted), NSFontWeightBold);
    [sectionContainer addSubview:count];
    [self addSubview:sectionContainer positioned:NSWindowAbove relativeTo:self.ambientView];
    self.sectionHeaderView = sectionContainer;

    CGFloat cardStartY = gridTop + sectionHeight;
    self.cachedCardStartY = cardStartY;
    self.scrollView.frame = NSMakeRect(0.0, cardStartY, width, MAX(0.0, height - cardStartY));

    NSInteger totalCards = (NSInteger)self.displayGames.size();
    [self renderVisibleCardsWithMetrics:metrics totalCards:totalCards];

    CGFloat totalWidth = MAX(width, metrics.contentX * 2.0 + (CGFloat)totalCards * (metrics.cardWidth + metrics.spacing));
    CGFloat totalHeight = MAX(NSHeight(self.scrollView.frame), metrics.cardHeight + gridPadding * 2.0);
    self.documentView.frame = NSMakeRect(0.0, 0.0, totalWidth, totalHeight);
    self.statusLabel.stringValue = totalCards == 0 ? @"No games found." : @"";
    if (self.onGameCountChanged) self.onGameCountChanged(totalCards);
    [self setNeedsLayout:YES];
}

- (void)renderVisibleCardsWithMetrics:(OPNCatalogGridMetrics)metrics totalCards:(NSInteger)totalCards {
    NSInteger visibleCards = MAX(1, (NSInteger)floor(NSWidth(self.scrollView.frame) / (metrics.cardWidth + metrics.spacing)));
    NSRect visibleBounds = self.scrollView.contentView.bounds;
    CGFloat visibleMidX = NSMidX(visibleBounds);
    NSInteger centerIndex = totalCards > 0 ? MAX(0, MIN(totalCards - 1, (NSInteger)floor((visibleMidX - metrics.contentX + metrics.spacing * 0.5) / (metrics.cardWidth + metrics.spacing)))) : 0;
    NSInteger renderStart = MAX(0, centerIndex - visibleCards / 2 - kCatalogRenderBufferCards);
    NSInteger renderEnd = MIN(totalCards, centerIndex + visibleCards / 2 + kCatalogRenderBufferCards + 1);
    self.renderStartIndex = renderStart;

    NSMutableSet<NSNumber *> *visibleIndexes = [NSMutableSet set];
    for (NSInteger index = renderStart; index < renderEnd; index++) {
        NSNumber *key = @(index);
        [visibleIndexes addObject:key];
        const OPN::GameInfo &game = _displayGames[(size_t)index];
        CGFloat gridPadding = MAX(18.0, floor(kCatalogGridPadding * OPNCatalogHeightScale(NSHeight(self.bounds))));
        NSRect frame = NSMakeRect(metrics.contentX + (CGFloat)index * (metrics.cardWidth + metrics.spacing), gridPadding, metrics.cardWidth, metrics.cardHeight);
        OPNGameCardView *card = self.cardViewsByIndex[key];
        if (card) {
            card.frame = frame;
            [card updateGame:game];
            [card setGamepadFocused:index == self.focusedGameIndex];
            continue;
        }

        card = [[OPNGameCardView alloc] initWithFrame:frame game:game];
        card.imageRevealDelay = 0.012 * (NSTimeInterval)MIN((NSInteger)18, index - renderStart);
        [card setGamepadFocused:index == self.focusedGameIndex];
        OPN::GameInfo gameCopy = game;
        __weak __typeof__(self) weakSelf = self;
        __weak OPNGameCardView *weakCard = card;
        card.onPlay = ^{
            __typeof__(self) strongSelf = weakSelf;
            OPNGameCardView *strongCard = weakCard;
            if (!strongSelf || !strongCard || !strongSelf.onSelectGame) return;
            int variantIndex = strongCard.selectedVariantIndex >= 0 ? strongCard.selectedVariantIndex : 0;
            strongSelf.onSelectGame(gameCopy, variantIndex);
        };
        [self.documentView addSubview:card];
        [self.cardViews addObject:card];
        self.cardViewsByIndex[key] = card;
    }

    for (NSNumber *key in [self.cardViewsByIndex.allKeys copy]) {
        if ([visibleIndexes containsObject:key]) continue;
        OPNGameCardView *card = self.cardViewsByIndex[key];
        [card setGamepadFocused:NO];
        [card removeFromSuperview];
        [self.cardViews removeObject:card];
        [self.cardViewsByIndex removeObjectForKey:key];
    }
}

- (void)scrollFocusedGameIntoViewWithMetrics:(OPNCatalogGridMetrics)metrics {
    if (self.displayGameCount <= 0) return;
    CGFloat targetX = metrics.contentX + (CGFloat)self.focusedGameIndex * (metrics.cardWidth + metrics.spacing);
    NSRect visible = self.scrollView.contentView.bounds;
    CGFloat minVisibleX = NSMinX(visible) + metrics.contentX * 0.30;
    CGFloat maxVisibleX = NSMaxX(visible) - metrics.cardWidth - metrics.contentX * 0.30;
    CGFloat scrollX = NSMinX(visible);
    if (targetX < minVisibleX) {
        scrollX = MAX(0.0, targetX - metrics.contentX * 0.30);
    } else if (targetX > maxVisibleX) {
        scrollX = MAX(0.0, targetX - NSWidth(visible) + metrics.cardWidth + metrics.contentX * 0.30);
    }
    if (std::fabs(scrollX - NSMinX(visible)) <= 1.0) return;
    [self.scrollView.contentView scrollToPoint:NSMakePoint(scrollX, 0.0)];
    [self.scrollView reflectScrolledClipView:self.scrollView.contentView];
}

- (void)moveGamepadFocusBy:(NSInteger)delta {
    if (self.displayGameCount <= 0 || delta == 0) return;
    NSInteger nextIndex = MAX(0, MIN(self.displayGameCount - 1, self.focusedGameIndex + delta));
    if (nextIndex == self.focusedGameIndex) return;
    self.focusedGameIndex = nextIndex;
    OPNCatalogGridMetrics metrics = OPNCatalogGridMetricsForSize(MAX(1.0, NSWidth(self.bounds)), MAX(1.0, NSHeight(self.bounds)));
    [self scrollFocusedGameIntoViewWithMetrics:metrics];
    [self renderVisibleCardsWithMetrics:metrics totalCards:self.displayGameCount];
}

- (void)activateGamepadFocus {
    if (self.displayGameCount <= 0 || !self.onSelectGame) return;
    NSInteger index = MAX(0, MIN(self.displayGameCount - 1, self.focusedGameIndex));
    const OPN::GameInfo &game = _displayGames[(size_t)index];
    OPNGameCardView *card = self.cardViewsByIndex[@(index)];
    int variantIndex = card && card.selectedVariantIndex >= 0 ? card.selectedVariantIndex : 0;
    self.onSelectGame(game, variantIndex);
}

- (void)scrollViewBoundsDidChange:(NSNotification *)notification {
    if (notification.object != self.scrollView.contentView) return;
    for (OPNGameCardView *card in self.cardViews) [card resetMouseTrackingIfOutside];
    [self renderVisibleCardsWithMetrics:OPNCatalogGridMetricsForSize(MAX(1.0, NSWidth(self.bounds)), MAX(1.0, NSHeight(self.bounds))) totalCards:self.displayGameCount];
}

@end
