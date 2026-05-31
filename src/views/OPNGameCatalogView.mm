#import "OPNGameCatalogView.h"
#import "OPNGameCardView.h"
#import "OPNLoadingView.h"
#import "../common/OPNColorTokens.h"
#import "../common/OPNCoreAnimationCoordinator.h"
#import "../common/OPNUIHelpers.h"
#import "../streaming/OPNStreamPreferences.h"
#import <GameController/GameController.h>
#include <QuartzCore/QuartzCore.h>
#include <algorithm>
#include <cstdlib>
#include <cmath>
#include <cstring>
#include "common/OPNSentry.h"

static const CGFloat kGridPadding = 28.0;
static const CGFloat kCardSpacing = 18.0;
static const CGFloat kNavHeight = 62.0;
static const CGFloat kToolbarHeight = 82.0;
static const CGFloat kDesktopLibraryTopInset = 146.0;
static const CGFloat kDesktopLibraryHeroTopOffset = 120.0;
static const CGFloat kDesktopLibraryHeroHeight = 424.0;
static const CGFloat kDesktopLibraryGridTopGap = 62.0;
static const CGFloat kDesktopLibraryRowSpacing = 34.0;
static const CGFloat kControllerRailSelectorOverlap = 22.0;
static const CGFloat kControllerRailDetailOverlap = 22.0;
static const CGFloat kControllerGameHubVerticalReserve = 96.0;
static const CGFloat kControllerGameHubPreferredHeight = 430.0;
static const CGFloat kControllerHeroMarqueeRatio = 0.3229;
static const NSInteger kDesktopGridRenderBufferRows = 3;
static NSString *const OPNFavoriteGameIdsDefaultsKey = @"OpenNOW.Library.FavoriteGameIds";

typedef void (^OPNCatalogImageCompletion)(NSImage *image, NSString *urlString, NSData *data);

typedef NS_ENUM(NSInteger, OPNControllerHeroPrimaryAction) {
    OPNControllerHeroPrimaryActionResume = 0,
    OPNControllerHeroPrimaryActionPlay = 1,
    OPNControllerHeroPrimaryActionBuy = 2,
};

static OpnImageLoadToken *OPNCatalogLoadImageFromCandidates(NSArray<NSString *> *candidates, NSUInteger index, OPNCatalogImageCompletion completion) {
    if (index >= candidates.count) return OpnLoadImageFromCandidatesCancellable(@[], 1600.0, completion);
    NSArray<NSString *> *remainingCandidates = [candidates subarrayWithRange:NSMakeRange(index, candidates.count - index)];
    return OpnLoadImageFromCandidatesCancellable(remainingCandidates, 1600.0, completion);
}

static NSColor *OPNCatalogColorFromHexString(NSString *hex) {
    NSString *clean = [[hex ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] uppercaseString];
    if ([clean hasPrefix:@"#"]) clean = [clean substringFromIndex:1];
    if (clean.length != 6) return nil;
    unsigned int rgb = 0;
    if (![[NSScanner scannerWithString:clean] scanHexInt:&rgb]) return nil;
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 0xFF) / 255.0
                               green:((rgb >> 8) & 0xFF) / 255.0
                                blue:(rgb & 0xFF) / 255.0
                               alpha:1.0];
}

static NSColor *OPNCatalogVendorMarqueeBackgroundColor(NSData *data) {
    if (data.length == 0) return nil;
    const char *bytes = (const char *)data.bytes;
    NSUInteger length = data.length;
    const char *needle = "{\"colors\"";
    size_t needleLength = strlen(needle);
    NSUInteger start = NSNotFound;
    for (NSUInteger i = 0; i + needleLength < length; i++) {
        if (memcmp(bytes + i, needle, needleLength) == 0) {
            start = i;
            break;
        }
    }
    if (start == NSNotFound) return nil;

    NSInteger depth = 0;
    NSUInteger end = NSNotFound;
    for (NSUInteger i = start; i < length; i++) {
        if (bytes[i] == '{') depth++;
        if (bytes[i] == '}') {
            depth--;
            if (depth == 0) {
                end = i + 1;
                break;
            }
        }
    }
    if (end == NSNotFound || end <= start) return nil;

    NSData *jsonData = [data subdataWithRange:NSMakeRange(start, end - start)];
    NSDictionary *metadata = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
    NSDictionary *colors = [metadata isKindOfClass:NSDictionary.class] ? metadata[@"colors"] : nil;
    NSString *hex = [colors isKindOfClass:NSDictionary.class] ? colors[@"left"] : nil;
    return OPNCatalogColorFromHexString(hex);
}

static NSColor *OPNCatalogDerivedHeroBackgroundColor(NSImage *image, NSData *metadataData) {
    (void)image;
    return OPNCatalogVendorMarqueeBackgroundColor(metadataData);
}

@interface OPNCatalogScrollView : NSScrollView
@end

@implementation OPNCatalogScrollView

- (void)scrollWheel:(NSEvent *)event {
    if (!OpnControllerModeEnabled()) {
        [super scrollWheel:event];
        return;
    }

    [super scrollWheel:event];
    NSClipView *clipView = self.contentView;
    if (clipView.bounds.origin.y == 0.0) return;
    [clipView scrollToPoint:NSMakePoint(clipView.bounds.origin.x, 0.0)];
    [self reflectScrolledClipView:clipView];
}

@end

typedef struct {
    CGFloat scale;
    CGFloat topInset;
    CGFloat bottomInset;
    CGFloat contentInset;
    CGFloat heroY;
    CGFloat heroHeight;
    CGFloat rowTitleY;
    CGFloat rowTitleWidth;
    CGFloat rowTitleHeight;
    CGFloat rowTitleFontSize;
    CGFloat countX;
    CGFloat countY;
    CGFloat countWidth;
    CGFloat countHeight;
    CGFloat countFontSize;
    CGFloat cardY;
    CGFloat cardSize;
    CGFloat cardSpacing;
    NSInteger visibleCardCount;
    CGFloat contentHeight;
} OPNControllerLibraryMetrics;

static OPNControllerLibraryMetrics OPNControllerLibraryMetricsForSize(CGFloat width, CGFloat height) {
    CGFloat safeWidth = MAX(1.0, width);
    CGFloat safeHeight = MAX(1.0, height);
    CGFloat scale = MIN(safeWidth / 1280.0, safeHeight / 720.0);
    CGFloat topInset = safeHeight * (28.0 / 720.0);
    CGFloat bottomInset = safeHeight * (72.0 / 720.0);
    CGFloat contentInset = safeWidth * (52.0 / 1280.0);
    CGFloat availableHeroWidth = MAX(1.0, safeWidth - contentInset * 2.0);
    CGFloat heroY = safeHeight * (2.0 / 720.0);
    CGFloat heroHeight = MIN(availableHeroWidth * kControllerHeroMarqueeRatio, safeHeight * (330.0 / 720.0));
    CGFloat rowGap = safeHeight * (18.0 / 720.0);
    CGFloat rowTitleHeight = safeHeight * (34.0 / 720.0);
    CGFloat rowTitleY = heroY + heroHeight + rowGap;
    CGFloat cardY = rowTitleY + rowTitleHeight + safeHeight * (12.0 / 720.0);
    CGFloat cardSpacing = safeWidth * (18.0 / 1280.0);
    CGFloat availableRailWidth = MAX(1.0, safeWidth - contentInset * 2.0);
    CGFloat visibleRailHeight = MAX(1.0, safeHeight - topInset - bottomInset);
    CGFloat verticalCardSize = floor(MAX(1.0, visibleRailHeight - cardY - safeHeight * (20.0 / 720.0)));
    CGFloat cardSize = floor(MAX(1.0, verticalCardSize));
    NSInteger visibleCardCount = MAX(1, (NSInteger)floor((availableRailWidth + cardSpacing) / MAX(1.0, cardSize + cardSpacing)));
    OPNControllerLibraryMetrics metrics = {
        scale,
        topInset,
        bottomInset,
        contentInset,
        heroY,
        heroHeight,
        rowTitleY,
        safeWidth * (170.0 / 1280.0),
        rowTitleHeight,
        safeHeight * (26.0 / 720.0),
        contentInset + safeWidth * (158.0 / 1280.0),
        rowTitleY + safeHeight * (8.0 / 720.0),
        safeWidth * (110.0 / 1280.0),
        safeHeight * (18.0 / 720.0),
        safeHeight * (14.0 / 720.0),
        cardY,
        cardSize,
        cardSpacing,
        visibleCardCount,
        cardY + cardSize + safeHeight * (24.0 / 720.0)
    };
    return metrics;
}

static unsigned OPNControllerAccentRGB(void) {
    return OPN::kBrandGreen;
}

static unsigned OPNControllerAccentSoftRGB(void) {
    return OpnBlendRGB(OPN::kBrandGreen, 0xFFFFFF, 0.42);
}

static unsigned OPNControllerAccentBlackRGB(CGFloat blackMix) {
    return OpnBlendRGB(OPN::kBrandGreen, 0x000000, blackMix);
}

static NSString *OPNCatalogString(const std::string &value, NSString *fallback = @"") {
    return value.empty() ? fallback : [NSString stringWithUTF8String:value.c_str()];
}

static NSString *OPNCatalogDisplayLabel(NSString *value) {
    NSString *trimmed = [value ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) return @"";

    NSString *specialKey = [[trimmed stringByReplacingOccurrencesOfString:@"-" withString:@"_"] uppercaseString];
    NSDictionary<NSString *, NSString *> *specialLabels = @{
        @"FREE_TO_PLAY": @"Free to Play",
        @"MASSIVELY_MULTIPLAYER_ONLINE": @"Massively Multiplayer Online",
        @"MASSIVELY_MULTIPLAYER": @"Massively Multiplayer",
        @"MMO": @"MMO",
    };
    NSString *specialLabel = specialLabels[specialKey];
    if (specialLabel.length > 0) return specialLabel;

    NSString *spaced = [[trimmed stringByReplacingOccurrencesOfString:@"_" withString:@" "] stringByReplacingOccurrencesOfString:@"-" withString:@" "];
    NSArray<NSString *> *tokens = [spaced componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSSet<NSString *> *acronyms = [NSSet setWithArray:@[@"AI", @"DLC", @"EA", @"ESRB", @"FPS", @"GOG", @"HDR", @"MMO", @"MOBA", @"NVIDIA", @"PC", @"PVE", @"PVP", @"RTX", @"VR"]];
    NSSet<NSString *> *lowercaseWords = [NSSet setWithArray:@[@"and", @"of", @"or", @"to"]];
    NSMutableArray<NSString *> *labels = [NSMutableArray array];

    for (NSString *token in tokens) {
        if (token.length == 0) continue;
        NSString *upper = token.uppercaseString;
        if ([acronyms containsObject:upper]) {
            [labels addObject:upper];
            continue;
        }

        NSString *lower = token.lowercaseString;
        if (labels.count > 0 && [lowercaseWords containsObject:lower]) {
            [labels addObject:lower];
            continue;
        }

        NSString *first = [lower substringToIndex:1].uppercaseString;
        NSString *rest = lower.length > 1 ? [lower substringFromIndex:1] : @"";
        [labels addObject:[first stringByAppendingString:rest]];
    }

    return labels.count > 0 ? [labels componentsJoinedByString:@" "] : trimmed;
}

static NSString *OPNCatalogDisplayString(const std::string &value, NSString *fallback = @"") {
    NSString *raw = OPNCatalogString(value, @"");
    NSString *label = OPNCatalogDisplayLabel(raw);
    return label.length > 0 ? label : fallback;
}

static NSAttributedString *OPNOutlinedControllerStoreText(NSString *text) {
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    style.lineBreakMode = NSLineBreakByTruncatingTail;
    NSShadow *shadow = [[NSShadow alloc] init];
    shadow.shadowColor = OpnColor(0x000000, 0.78);
    shadow.shadowBlurRadius = 8.0;
    shadow.shadowOffset = NSMakeSize(0.0, 1.0);
    return [[NSAttributedString alloc] initWithString:text ?: @""
                                           attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:17.0 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: NSColor.whiteColor,
        NSShadowAttributeName: shadow,
        NSParagraphStyleAttributeName: style,
    }];
}

static NSAttributedString *OPNOutlinedControllerDescriptionText(NSString *text) {
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    style.lineBreakMode = NSLineBreakByWordWrapping;
    style.lineSpacing = 3.0;
    NSShadow *shadow = [[NSShadow alloc] init];
    shadow.shadowColor = OpnColor(0x000000, 0.82);
    shadow.shadowBlurRadius = 9.0;
    shadow.shadowOffset = NSMakeSize(0.0, 1.0);
    return [[NSAttributedString alloc] initWithString:text ?: @""
                                           attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:14.5 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: NSColor.whiteColor,
        NSShadowAttributeName: shadow,
        NSParagraphStyleAttributeName: style,
    }];
}

@interface OPNFlippedGridDocumentView : NSView
@end

@implementation OPNFlippedGridDocumentView
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
        OpnColor(OPN::kBrandGreen, 0.22),
        OpnColor(OPN::kBrandGreen, 0.055),
        OpnColor(OPN::kBrandGreen, 0.0)
    ]];
    [greenBloom drawFromCenter:NSMakePoint(NSMinX(bounds) + NSWidth(bounds) * 0.20, NSMinY(bounds) + 188.0)
                        radius:12.0
                      toCenter:NSMakePoint(NSMinX(bounds) + NSWidth(bounds) * 0.24, NSMinY(bounds) + 230.0)
                        radius:620.0
                       options:0];

    NSGradient *vignette = [[NSGradient alloc] initWithColorsAndLocations:
        OpnColor(0x000000, 0.0), 0.0,
        OpnColor(0x000000, 0.72), 1.0,
        nil];
    [vignette drawInRect:bounds angle:-90.0];
}

@end

@interface OPNControllerPreviewBackgroundView : NSView
@property (nonatomic, strong) NSImage *image;
@property (nonatomic, strong) NSColor *derivedBackgroundColor;
@property (nonatomic, assign) CGFloat cornerRadius;
@property (nonatomic, assign) BOOL rightAlignImageToHeight;
- (void)setImage:(NSImage *)image metadataData:(NSData *)metadataData;
@end

@implementation OPNControllerPreviewBackgroundView

- (BOOL)isFlipped { return YES; }

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _cornerRadius = 0.0;
        _derivedBackgroundColor = OpnColor(0x080A0C, 1.0);
        _rightAlignImageToHeight = NO;
    }
    return self;
}

- (void)setImage:(NSImage *)image {
    [self setImage:image metadataData:nil];
}

- (void)setImage:(NSImage *)image metadataData:(NSData *)metadataData {
    _image = image;
    _derivedBackgroundColor = OPNCatalogDerivedHeroBackgroundColor(image, metadataData);
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSRect bounds = self.bounds;
    if (NSIsEmptyRect(bounds)) return;

    if (self.cornerRadius > 0.0) {
        NSBezierPath *clipPath = [NSBezierPath bezierPathWithRoundedRect:bounds xRadius:self.cornerRadius yRadius:self.cornerRadius];
        [clipPath addClip];
    }
    if (self.derivedBackgroundColor) {
        [self.derivedBackgroundColor setFill];
        NSRectFill(bounds);
    }

    if (self.image && self.image.size.width > 0.0 && self.image.size.height > 0.0) {
        CGFloat imageAspect = self.image.size.width / self.image.size.height;
        CGFloat boundsAspect = NSWidth(bounds) / MAX(1.0, NSHeight(bounds));
        NSRect sourceRect = NSMakeRect(0.0, 0.0, self.image.size.width, self.image.size.height);
        if (self.rightAlignImageToHeight) {
            CGFloat drawWidth = NSHeight(bounds) * imageAspect;
            NSRect drawRect = NSMakeRect(NSMaxX(bounds) - drawWidth, NSMinY(bounds), drawWidth, NSHeight(bounds));
            [self.image drawInRect:drawRect fromRect:sourceRect operation:NSCompositingOperationSourceOver fraction:1.0 respectFlipped:YES hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
        } else if (imageAspect > boundsAspect) {
            CGFloat sourceWidth = self.image.size.height * boundsAspect;
            sourceRect.origin.x = floor((self.image.size.width - sourceWidth) * 0.5);
            sourceRect.size.width = sourceWidth;
            [self.image drawInRect:bounds fromRect:sourceRect operation:NSCompositingOperationSourceOver fraction:1.0 respectFlipped:YES hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
        } else {
            CGFloat sourceHeight = self.image.size.width / boundsAspect;
            sourceRect.origin.y = floor((self.image.size.height - sourceHeight) * 0.5);
            sourceRect.size.height = sourceHeight;
            [self.image drawInRect:bounds fromRect:sourceRect operation:NSCompositingOperationSourceOver fraction:1.0 respectFlipped:YES hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
        }
    }

    NSGradient *leftScrim = [[NSGradient alloc] initWithColors:@[OpnColor(0x000000, 0.58), OpnColor(0x000000, 0.28), OpnColor(0x000000, 0.0)]];
    [leftScrim drawInRect:bounds angle:0.0];

}

@end

@interface OPNCenteredSearchFieldCell : NSSearchFieldCell
@end

@implementation OPNCenteredSearchFieldCell

- (NSRect)opn_centeredTextRectForBounds:(NSRect)rect {
    NSRect textRect = [super drawingRectForBounds:rect];
    NSFont *font = self.font ?: [NSFont systemFontOfSize:[NSFont systemFontSize]];
    CGFloat textHeight = ceil(font.ascender - font.descender + 2.0);
    textRect.origin.y = rect.origin.y + floor((NSHeight(rect) - textHeight) / 2.0) + 2.0;
    textRect.size.height = textHeight;
    return textRect;
}

- (NSRect)drawingRectForBounds:(NSRect)rect {
    return [self opn_centeredTextRectForBounds:rect];
}

- (void)editWithFrame:(NSRect)rect
               inView:(NSView *)controlView
               editor:(NSText *)textObj
             delegate:(id)delegate
                event:(NSEvent *)event {
    [super editWithFrame:[self opn_centeredTextRectForBounds:rect]
                  inView:controlView
                  editor:textObj
                delegate:delegate
                   event:event];
}

- (void)selectWithFrame:(NSRect)rect
                 inView:(NSView *)controlView
                 editor:(NSText *)textObj
               delegate:(id)delegate
                  start:(NSInteger)selStart
                 length:(NSInteger)selLength {
    [super selectWithFrame:[self opn_centeredTextRectForBounds:rect]
                    inView:controlView
                    editor:textObj
                  delegate:delegate
                     start:selStart
                    length:selLength];
}

@end

@class OPNControllerPromptBarView;
@class OPNControllerGameHubView;
@class OPNControllerHomeTileView;

typedef NS_ENUM(NSInteger, OPNControllerCatalogSurface) {
    OPNControllerCatalogSurfaceHome = 0,
    OPNControllerCatalogSurfaceLibrary = 1,
};

typedef NS_ENUM(NSInteger, OPNControllerHomeTileStyle) {
    OPNControllerHomeTileStyleHero = 0,
    OPNControllerHomeTileStyleCommand = 1,
    OPNControllerHomeTileStyleGame = 2,
};

typedef NS_ENUM(NSInteger, OPNControllerPromptMode) {
    OPNControllerPromptModeHome = 0,
    OPNControllerPromptModeGame = 1,
    OPNControllerPromptModeDetails = 2,
};

@interface OPNGameCatalogView ()
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSView *gridContentView;
@property (nonatomic, strong) NSSearchField *searchField;
@property (nonatomic, strong) NSTextField *userLabel;
@property (nonatomic, strong) NSButton *signOutButton;
@property (nonatomic, strong) NSTextField *libraryIconLabel;
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSButton *sortButton;
@property (nonatomic, strong) NSButton *filterButton;
@property (nonatomic, strong) NSTextField *gameCountLabel;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) OPNLoadingView *loadingView;
@property (nonatomic, strong) NSView *categoryBarView;
@property (nonatomic, strong) NSMutableArray<NSButton *> *categoryButtons;
@property (nonatomic, copy) NSArray<NSDictionary<NSString *, NSString *> *> *categoryItems;
@property (nonatomic, copy) NSString *selectedCategoryId;
@property (nonatomic, strong) NSMutableSet<NSString *> *favoriteGameIds;
@property (nonatomic, strong) NSView *controllerDetailView;
@property (nonatomic, strong) OPNControllerPreviewBackgroundView *controllerDetailBackgroundView;
@property (nonatomic, strong) NSTextField *controllerDetailStatsLabel;
@property (nonatomic, strong) NSTextField *controllerDetailFeaturesLabel;
@property (nonatomic, strong) OPNControllerGameHubView *controllerGameHubView;
@property (nonatomic, strong) OPNControllerPromptBarView *controllerPromptBarView;
@property (nonatomic, strong) OPNControllerPromptBarView *controllerBottomPromptBarView;
@property (nonatomic, strong) NSTextField *controllerSectionLabel;
@property (nonatomic, strong) NSView *controllerLibraryRailView;
@property (nonatomic, strong) NSMutableArray<NSView *> *controllerHeroViews;
@property (nonatomic, strong) NSMutableArray<OPNControllerHomeTileView *> *controllerHomeTileViews;
@property (nonatomic, strong) CAGradientLayer *controllerDetailGradientLayer;
@property (nonatomic, strong) CALayer *controllerDetailAccentLayer;
@property (nonatomic, strong) NSMutableArray<OPNGameCardView *> *cardViews;
@property (nonatomic, strong) NSMutableArray<OpnImageLoadToken *> *catalogImageLoadTokens;
@property (nonatomic, assign) std::vector<OPN::GameInfo> allGames;
@property (nonatomic, assign) std::vector<OPN::GameInfo> featuredGames;
@property (nonatomic, assign) std::vector<int> activeSessionAppIds;
@property (nonatomic, assign) CGFloat lastLayoutWidth;
@property (nonatomic, assign) BOOL needsGridRenderAfterResize;
@property (nonatomic, copy) NSString *selectedSortId;
@property (nonatomic, strong) NSMutableSet<NSString *> *selectedFilterIds;
@property (nonatomic, assign) std::vector<OPN::CatalogFilterGroup> catalogFilterGroups;
@property (nonatomic, assign) std::vector<OPN::CatalogSortOption> catalogSortOptions;
@property (nonatomic, assign) NSInteger catalogTotalCount;
@property (nonatomic, assign) NSInteger catalogSupportedCount;
@property (nonatomic, assign) NSInteger focusedCardIndex;
@property (nonatomic, assign) NSInteger focusedHomeItemIndex;
@property (nonatomic, assign) OPNControllerCatalogSurface controllerSurface;
@property (nonatomic, assign) NSInteger controllerRenderedGameCount;
@property (nonatomic, assign) NSInteger controllerDisplayGameCount;
@property (nonatomic, assign) NSInteger desktopRenderStartIndex;
@property (nonatomic, assign) NSInteger desktopRenderedGameCount;
@property (nonatomic, assign) NSInteger desktopDisplayGameCount;
@property (nonatomic, assign) BOOL hasDesktopFeaturedGame;
@property (nonatomic, assign) OPN::GameInfo desktopFeaturedGame;
@property (nonatomic, assign) int desktopFeaturedVariantIndex;
@property (nonatomic, assign) CGFloat controllerLibraryRailContentWidth;
@property (nonatomic, assign) CGFloat controllerLibraryRailOffsetX;
@property (nonatomic, assign) NSInteger controllerLibraryWindowStartIndex;
@property (nonatomic, assign) NSInteger controllerLibraryVisibleStartIndex;
@property (nonatomic, assign) NSInteger gridColumnCount;
@property (nonatomic, strong) NSView *detailsOverlayView;
@property (nonatomic, strong) NSView *controllerStoreFilterOverlayView;
@property (nonatomic, strong) NSMutableArray<NSTextField *> *controllerStoreFilterOptionLabels;
@property (nonatomic, copy) NSArray<NSDictionary<NSString *, NSString *> *> *controllerStoreFilterItems;
@property (nonatomic, assign) NSInteger focusedControllerStoreFilterIndex;
@property (nonatomic, assign) CFTimeInterval controllerYPressedAt;
@property (nonatomic, assign) BOOL controllerYHoldActive;
@property (nonatomic, assign) BOOL controllerYConsumedByHold;
@property (nonatomic, strong) NSTimer *gamepadNavigationTimer;
@property (nonatomic, strong) NSTimer *controllerDetailBackgroundTimer;
@property (nonatomic, strong) NSTimer *controllerHeroRotationTimer;
@property (nonatomic, copy) NSArray<NSString *> *controllerDetailBackgroundURLs;
@property (nonatomic, copy) NSString *controllerDetailBackgroundURL;
@property (nonatomic, copy) NSString *controllerDetailBackgroundGameId;
@property (nonatomic, assign) NSInteger controllerDetailBackgroundIndex;
@property (nonatomic, assign) NSInteger controllerHeroIndex;
@property (nonatomic, assign) CGFloat controllerHeroImageAspectRatio;
@property (nonatomic, assign) uint16_t previousGamepadButtons;
@property (nonatomic, assign) CFTimeInterval lastGamepadMoveTime;
- (void)stopGamepadNavigation;
- (void)cancelCatalogImageLoads;
- (void)trackCatalogImageLoadToken:(OpnImageLoadToken *)token;
- (void)scrollLibraryToTop;
- (void)requestCatalogBrowse;
- (void)rebuildCategoryBar;
- (NSString *)activeCategoryTitle;
- (BOOL)game:(const OPN::GameInfo &)game matchesCategory:(NSString *)categoryId;
- (void)cycleCategoryBy:(NSInteger)delta;
- (NSInteger)gameCountForCategory:(NSString *)categoryId;
- (const OPN::GameInfo *)currentLastPlayedGame;
- (int)preferredVariantIndexForGame:(const OPN::GameInfo &)game;
- (void)addDesktopLibraryMetricPillWithTitle:(NSString *)title value:(NSString *)value frame:(NSRect)frame;
- (void)addDesktopLibraryHeroForGame:(const OPN::GameInfo &)game frame:(NSRect)frame;
- (void)selectDesktopFeaturedGame:(const OPN::GameInfo &)game variantIndex:(int)variantIndex;
- (void)desktopHeroPlayClicked:(id)sender;
- (void)renderControllerHomeSurface;
- (void)renderControllerLibrary;
- (void)renderControllerHero;
- (void)renderControllerHeroAnimated:(BOOL)animated;
- (void)renderControllerLibraryRail;
- (void)scrollControllerLibraryRailToCardAtIndex:(NSInteger)index animated:(BOOL)animated;
- (std::vector<OPN::GameInfo>)featuredLibraryGamesWithFallback:(const std::vector<OPN::GameInfo> &)fallbackGames;
- (void)addControllerHeroForGame:(const OPN::GameInfo &)game frame:(NSRect)frame activeIndex:(NSInteger)activeIndex totalCount:(NSInteger)totalCount;
- (void)loadControllerHeroImageForView:(OPNControllerPreviewBackgroundView *)view candidates:(NSArray<NSString *> *)candidates index:(NSUInteger)index;
- (std::vector<OPN::GameInfo>)controllerFeaturedGamesFromDisplayGames:(const std::vector<OPN::GameInfo> &)displayGames;
- (const OPN::GameInfo *)currentControllerHeroGame;
- (OPNControllerHeroPrimaryAction)primaryActionForHeroGame:(const OPN::GameInfo &)game;
- (void)startControllerHeroRotationIfNeeded;
- (void)stopControllerHeroRotation;
- (void)controllerHeroRotationTimerFired:(NSTimer *)timer;
- (void)controllerHeroResumeClicked:(id)sender;
- (void)controllerHeroMoreInfoClicked:(id)sender;
- (void)loadControllerHeroLogoForView:(NSImageView *)view candidates:(NSArray<NSString *> *)candidates index:(NSUInteger)index;
- (void)loadControllerHomeImageForTile:(OPNControllerHomeTileView *)tile candidates:(NSArray<NSString *> *)candidates index:(NSUInteger)index expectedIdentifier:(NSString *)expectedIdentifier;
- (std::vector<OPN::GameInfo>)controllerHomeQueueGamesWithLimit:(NSInteger)limit;
- (const OPN::GameInfo *)controllerHomeGameForIdentifier:(NSString *)identifier;
- (NSInteger)controllerHomeLibraryCount;
- (NSInteger)controllerHomeFavoriteCount;
- (void)focusControllerHomeItemAtIndex:(NSInteger)index scrollIntoView:(BOOL)scrollIntoView;
- (void)moveControllerHomeFocusByRows:(NSInteger)rows columns:(NSInteger)columns;
- (void)activateFocusedControllerHomeItem;
- (NSString *)favoriteIdentifierForGame:(const OPN::GameInfo &)game;
- (BOOL)isFavoriteGame:(const OPN::GameInfo &)game;
- (void)toggleFavoriteForFocusedGame;
- (void)persistFavoriteGameIds;
- (void)focusCardAtIndex:(NSInteger)index scrollIntoView:(BOOL)scrollIntoView;
- (NSInteger)controllerInitialRenderedGameCount;
- (NSInteger)desktopInitialRenderedGameCountForColumns:(NSInteger)columns;
- (void)resetDesktopGridRenderWindow;
- (void)libraryScrollViewBoundsDidChange:(NSNotification *)notification;
- (BOOL)preloadControllerGameIfNeededForIndex:(NSInteger)index direction:(NSInteger)direction;
- (void)preloadControllerNeighborForDirection:(NSInteger)direction;
- (BOOL)appendControllerGameCardAtIndex:(NSInteger)index;
- (void)openFocusedGameDetails;
- (void)closeGameDetails;
- (std::vector<OPN::GameInfo>)controllerLibraryDisplayGames;
- (void)showControllerStoreFilterOverlay;
- (void)hideControllerStoreFilterOverlayApplyingSelection:(BOOL)applySelection;
- (void)moveControllerStoreFilterFocusBy:(NSInteger)delta;
- (void)layoutControllerStoreFilterOverlay;
- (void)updateControllerStoreFilterOverlaySelection;
- (void)rebuildControllerStoreFilterItems;
- (void)launchFocusedGame;
- (void)launchLastPlayedGame;
- (void)cycleFocusedVariant;
- (void)updateControllerDetailContent;
- (void)configureControllerDetailBackgroundForGame:(const OPN::GameInfo &)game;
- (void)startControllerDetailBackgroundRotationIfNeeded;
- (void)stopControllerDetailBackgroundRotation;
- (void)controllerDetailBackgroundTimerFired:(NSTimer *)timer;
- (void)loadControllerDetailBackgroundFromCandidates:(NSArray<NSString *> *)candidates index:(NSUInteger)index expectedURL:(NSString *)expectedURL;
- (void)installGamepadValueHandlers;
- (void)startGamepadNavigationIfNeeded;
- (void)controllerDidConnect:(NSNotification *)notification;
- (void)controllerDidDisconnect:(NSNotification *)notification;
@end

static uint16_t OPNCatalogGamepadButtons(void) {
    NSArray<GCController *> *controllers = [GCController controllers];
    if (controllers.count == 0) return 0;
    GCExtendedGamepad *pad = controllers.firstObject.extendedGamepad;
    if (!pad) return 0;
    uint16_t buttons = 0;
    if (pad.buttonA.value > 0.5) buttons |= 1u << 0;
    if (pad.buttonB.value > 0.5) buttons |= 1u << 1;
    if (pad.buttonY.value > 0.5) buttons |= 1u << 2;
    if (pad.leftShoulder.value > 0.5) buttons |= 1u << 3;
    if (pad.rightShoulder.value > 0.5) buttons |= 1u << 4;
    if (pad.dpad.up.value > 0.5 || pad.leftThumbstick.yAxis.value > 0.65) buttons |= 1u << 5;
    if (pad.dpad.down.value > 0.5 || pad.leftThumbstick.yAxis.value < -0.65) buttons |= 1u << 6;
    if (pad.dpad.left.value > 0.5 || pad.leftThumbstick.xAxis.value < -0.65) buttons |= 1u << 7;
    if (pad.dpad.right.value > 0.5 || pad.leftThumbstick.xAxis.value > 0.65) buttons |= 1u << 8;
    if (pad.buttonX.value > 0.5) buttons |= 1u << 9;
    return buttons;
}

static BOOL OPNCatalogGamepadNavigationActive(NSView *view) {
    NSWindow *window = view.window;
    if (!window || window.contentViewController != nil) return NO;
    return window.contentView == view || [view isDescendantOf:window.contentView];
}

static NSString *OPNCatalogJoinedStrings(const std::vector<std::string> &values, NSString *fallback) {
    NSMutableArray<NSString *> *items = [NSMutableArray array];
    for (const std::string &value : values) {
        if (!value.empty()) {
            NSString *label = OPNCatalogDisplayString(value, @"");
            if (label.length > 0) [items addObject:label];
        }
        if (items.count >= 4) break;
    }
    return items.count > 0 ? [items componentsJoinedByString:@"  /  "] : fallback;
}

static NSArray<NSString *> *OPNControllerCategoryArtworkCandidates(const OPN::GameInfo &game) {
    NSMutableArray<NSString *> *urls = [NSMutableArray arrayWithCapacity:2];
    NSString *poster = OPNCatalogString(game.imageUrl, @"");
    NSString *hero = OPNCatalogString(game.heroImageUrl, @"");
    if (hero.length > 0) [urls addObject:hero];
    if (poster.length > 0 && ![poster isEqualToString:hero]) [urls addObject:poster];
    return urls;
}

static NSArray<NSString *> *OPNControllerCategoryBackgroundCandidates(const OPN::GameInfo &game) {
    NSMutableArray<NSString *> *urls = [NSMutableArray array];
    for (const std::string &screenshotUrl : game.screenshotUrls) {
        NSString *url = OPNCatalogString(screenshotUrl, @"");
        if (url.length > 0 && ![urls containsObject:url]) [urls addObject:url];
    }
    if (urls.count > 0) return urls;
    for (NSString *fallback in OPNControllerCategoryArtworkCandidates(game)) {
        if (fallback.length > 0 && ![urls containsObject:fallback]) [urls addObject:fallback];
    }
    return urls;
}

static NSArray<NSString *> *OPNControllerHeroBackgroundCandidates(const OPN::GameInfo &game) {
    NSMutableArray<NSString *> *urls = [NSMutableArray array];
    auto appendImageType = [&](const char *type) {
        auto imageValues = game.imageUrlsByType.find(type);
        if (imageValues == game.imageUrlsByType.end()) return;
        for (const std::string &value : imageValues->second) {
            NSString *candidate = OPNCatalogString(value, @"");
            if (candidate.length > 0 && ![urls containsObject:candidate]) [urls addObject:candidate];
        }
    };
    appendImageType("MARQUEE_HERO_IMAGE");
    appendImageType("FEATURE_IMAGE");
    appendImageType("HERO_IMAGE");
    appendImageType("TV_BANNER");
    appendImageType("KEY_ART");
    appendImageType("KEY_IMAGE");
    for (NSString *candidate in OPNControllerCategoryArtworkCandidates(game)) {
        if (candidate.length > 0 && ![urls containsObject:candidate]) [urls addObject:candidate];
    }
    for (NSString *candidate in OPNControllerCategoryBackgroundCandidates(game)) {
        if (candidate.length > 0 && ![urls containsObject:candidate]) [urls addObject:candidate];
    }
    return urls;
}

static NSArray<NSString *> *OPNControllerHeroLogoCandidates(const OPN::GameInfo &game) {
    NSMutableArray<NSString *> *urls = [NSMutableArray array];
    auto imageValues = game.imageUrlsByType.find("GAME_LOGO");
    if (imageValues == game.imageUrlsByType.end()) return urls;
    for (const std::string &value : imageValues->second) {
        NSString *candidate = OPNCatalogString(value, @"");
        if (candidate.length > 0 && ![urls containsObject:candidate]) [urls addObject:candidate];
    }
    return urls;
}

static NSString *OPNCatalogCommaJoinedStrings(const std::vector<std::string> &values) {
    NSMutableArray<NSString *> *items = [NSMutableArray array];
    for (const std::string &value : values) {
        if (!value.empty()) {
            NSString *label = OPNCatalogDisplayString(value, @"");
            if (label.length > 0) [items addObject:label];
        }
    }
    return [items componentsJoinedByString:@", "];
}

static NSString *OPNCatalogCommaJoinedStrings(const std::vector<std::string> &values, NSUInteger limit) {
    NSMutableArray<NSString *> *items = [NSMutableArray array];
    for (const std::string &value : values) {
        if (!value.empty()) {
            NSString *label = OPNCatalogDisplayString(value, @"");
            if (label.length > 0 && ![items containsObject:label]) [items addObject:label];
        }
        if (items.count >= limit) break;
    }
    return [items componentsJoinedByString:@", "];
}

static NSString *OPNCatalogPlayerCountText(int localPlayers, int onlinePlayers) {
    NSMutableArray<NSString *> *items = [NSMutableArray array];
    if (localPlayers > 0) [items addObject:[NSString stringWithFormat:@"%d local", localPlayers]];
    if (onlinePlayers > 0) [items addObject:[NSString stringWithFormat:@"%d online", onlinePlayers]];
    return [items componentsJoinedByString:@", "];
}

static NSString *OPNCategoryId(NSString *prefix, NSString *value) {
    NSString *cleanValue = [[value ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    if (cleanValue.length == 0) return @"";
    return [NSString stringWithFormat:@"%@:%@", prefix, cleanValue];
}

static NSString *OPNStoreCategoryTitle(NSString *store) {
    NSString *upper = store.uppercaseString;
    if ([upper containsString:@"STEAM"]) return @"Steam";
    if ([upper containsString:@"EPIC"] || [upper containsString:@"EGS"]) return @"Epic";
    if ([upper containsString:@"UBISOFT"] || [upper containsString:@"UPLAY"]) return @"Ubisoft";
    if ([upper containsString:@"BATTLE"]) return @"Battle.net";
    if ([upper containsString:@"XBOX"] || [upper containsString:@"MICROSOFT"]) return @"Xbox";
    if ([upper containsString:@"EA"] || [upper containsString:@"ORIGIN"]) return @"EA";
    if ([upper containsString:@"GOG"]) return @"GOG";
    return OPNCatalogDisplayLabel(store);
}

static bool OPNGameVariantStatusIsOwned(const std::string &status) {
    return status == "MANUAL" || status == "PLATFORM_SYNC" || status == "IN_LIBRARY";
}

static bool OPNGameVariantIsLibraryAccessible(const OPN::GameVariant &variant) {
    return variant.librarySelected || variant.inLibrary || OPNGameVariantStatusIsOwned(variant.serviceStatus);
}

static OPN::GameInfo OPNGameWithLibraryAccessibleVariants(const OPN::GameInfo &game) {
    OPN::GameInfo filtered = game;
    if (game.variants.empty()) return filtered;

    filtered.variants.clear();
    filtered.availableStores.clear();
    for (const OPN::GameVariant &variant : game.variants) {
        if (!OPNGameVariantIsLibraryAccessible(variant)) continue;
        filtered.variants.push_back(variant);
        if (!variant.appStore.empty() && std::find(filtered.availableStores.begin(), filtered.availableStores.end(), variant.appStore) == filtered.availableStores.end()) {
            filtered.availableStores.push_back(variant.appStore);
        }
    }
    return filtered;
}

static bool OPNLibraryGameHasAccessibleVariants(const OPN::GameInfo &game) {
    if (game.variants.empty()) return true;
    for (const OPN::GameVariant &variant : game.variants) {
        if (OPNGameVariantIsLibraryAccessible(variant)) return true;
    }
    return false;
}

static bool OPNGameIdentityMatches(const OPN::GameInfo &lhs, const OPN::GameInfo &rhs) {
    if (!lhs.id.empty() && lhs.id == rhs.id) return true;
    if (!lhs.uuid.empty() && lhs.uuid == rhs.uuid) return true;
    if (!lhs.launchAppId.empty() && lhs.launchAppId == rhs.launchAppId) return true;
    return false;
}

static bool OPNGameIsOwned(const OPN::GameInfo &game) {
    if (game.isInLibrary) return true;
    for (const OPN::GameVariant &variant : game.variants) {
        if (OPNGameVariantIsLibraryAccessible(variant)) return true;
    }
    return false;
}

static bool OPNNumericStringEqualsInt(const std::string &value, int target) {
    if (target <= 0 || value.empty()) return false;
    char *end = nullptr;
    long parsed = std::strtol(value.c_str(), &end, 10);
    return end && *end == '\0' && parsed == target;
}

static bool OPNGameMatchesActiveSessionAppId(const OPN::GameInfo &game, int appId) {
    if (OPNNumericStringEqualsInt(game.launchAppId, appId) || OPNNumericStringEqualsInt(game.id, appId)) return true;
    for (const OPN::GameVariant &variant : game.variants) {
        if (OPNNumericStringEqualsInt(variant.id, appId)) return true;
    }
    return false;
}

static bool OPNGameHasActiveSession(const OPN::GameInfo &game, const std::vector<int> &activeSessionAppIds) {
    for (int appId : activeSessionAppIds) {
        if (OPNGameMatchesActiveSessionAppId(game, appId)) return true;
    }
    return false;
}

static NSString *OPNCatalogStoreSummary(const std::vector<std::string> &stores, NSString *fallback) {
    NSMutableArray<NSString *> *uniqueItems = [NSMutableArray array];
    for (const std::string &storeValue : stores) {
        NSString *label = OPNStoreCategoryTitle(OPNCatalogString(storeValue, @""));
        if (label.length > 0 && ![uniqueItems containsObject:label]) [uniqueItems addObject:label];
    }
    if (uniqueItems.count == 0) return fallback ?: @"Store not listed";
    NSUInteger visibleCount = MIN((NSUInteger)3, uniqueItems.count);
    NSArray<NSString *> *visibleItems = [uniqueItems subarrayWithRange:NSMakeRange(0, visibleCount)];
    NSString *summary = [visibleItems componentsJoinedByString:@", "];
    NSUInteger remainingCount = uniqueItems.count > visibleCount ? uniqueItems.count - visibleCount : 0;
    return remainingCount > 0 ? [summary stringByAppendingFormat:@" +%lu", (unsigned long)remainingCount] : summary;
}

typedef NS_ENUM(NSInteger, OPNControllerPromptStyle) {
    OPNControllerPromptStyleKeyboard = 0,
    OPNControllerPromptStylePlayStation = 1,
    OPNControllerPromptStyleXbox = 2,
    OPNControllerPromptStyleNintendo = 3,
};

static void OPNStrokePath(NSBezierPath *path, NSColor *color, CGFloat width);

static void OPNStrokePath(NSBezierPath *path, NSColor *color, CGFloat width) {
    [color setStroke];
    path.lineWidth = width;
    path.lineCapStyle = NSLineCapStyleRound;
    path.lineJoinStyle = NSLineJoinStyleRound;
    [path stroke];
}

@interface OPNControllerHomeTileView : NSView
@property (nonatomic, copy) NSString *actionIdentifier;
@property (nonatomic, copy) NSString *gameIdentifier;
@property (nonatomic, copy) NSString *eyebrow;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, copy) NSString *detail;
@property (nonatomic, copy) NSString *glyph;
@property (nonatomic, strong) NSImage *image;
@property (nonatomic, assign) OPNControllerHomeTileStyle tileStyle;
@property (nonatomic, assign, getter=isControllerFocused) BOOL controllerFocused;
@property (nonatomic, copy) void (^onSelect)(void);
- (instancetype)initWithFrame:(NSRect)frame style:(OPNControllerHomeTileStyle)style;
@end

@implementation OPNControllerHomeTileView

- (instancetype)initWithFrame:(NSRect)frame style:(OPNControllerHomeTileStyle)style {
    self = [super initWithFrame:frame];
    if (self) {
        _tileStyle = style;
        _actionIdentifier = @"";
        _gameIdentifier = @"";
        _eyebrow = @"";
        _title = @"";
        _subtitle = @"";
        _detail = @"";
        _glyph = @"";
        self.wantsLayer = YES;
        self.layer.masksToBounds = NO;
        self.layer.shadowColor = NSColor.blackColor.CGColor;
        self.layer.shadowOpacity = 0.36;
        self.layer.shadowRadius = 24.0;
        self.layer.shadowOffset = CGSizeMake(0.0, 14.0);
    }
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)setControllerFocused:(BOOL)controllerFocused {
    if (_controllerFocused == controllerFocused) return;
    _controllerFocused = controllerFocused;
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.20];
    [CATransaction setAnimationTimingFunction:[OPNCoreAnimationCoordinator appleQuinticTimingFunction]];
    self.layer.zPosition = controllerFocused ? 48.0 : 0.0;
    self.layer.shadowColor = (controllerFocused ? OpnColor(OPNControllerAccentSoftRGB()) : NSColor.blackColor).CGColor;
    self.layer.shadowOpacity = controllerFocused ? 0.58 : 0.36;
    self.layer.shadowRadius = controllerFocused ? 34.0 : 24.0;
    CATransform3D transform = CATransform3DIdentity;
    if (controllerFocused) transform = CATransform3DScale(transform, 1.025, 1.025, 1.0);
    self.layer.transform = transform;
    [CATransaction commit];
    [self setNeedsDisplay:YES];
}

- (void)setImage:(NSImage *)image {
    _image = image;
    [self setNeedsDisplay:YES];
}

- (void)setEyebrow:(NSString *)eyebrow { _eyebrow = [eyebrow copy] ?: @""; [self setNeedsDisplay:YES]; }
- (void)setTitle:(NSString *)title { _title = [title copy] ?: @""; [self setNeedsDisplay:YES]; }
- (void)setSubtitle:(NSString *)subtitle { _subtitle = [subtitle copy] ?: @""; [self setNeedsDisplay:YES]; }
- (void)setDetail:(NSString *)detail { _detail = [detail copy] ?: @""; [self setNeedsDisplay:YES]; }
- (void)setGlyph:(NSString *)glyph { _glyph = [glyph copy] ?: @""; [self setNeedsDisplay:YES]; }

- (NSDictionary<NSAttributedStringKey, id> *)textAttributesWithSize:(CGFloat)size
                                                             weight:(NSFontWeight)weight
                                                              color:(NSColor *)color
                                                          alignment:(NSTextAlignment)alignment
                                                          lineBreak:(NSLineBreakMode)lineBreak {
    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.alignment = alignment;
    paragraph.lineBreakMode = lineBreak;
    return @{
        NSFontAttributeName: [NSFont systemFontOfSize:size weight:weight],
        NSForegroundColorAttributeName: color,
        NSParagraphStyleAttributeName: paragraph,
    };
}

- (void)drawImage:(NSImage *)image inAspectFillRect:(NSRect)rect alpha:(CGFloat)alpha {
    if (!image || image.size.width <= 0.0 || image.size.height <= 0.0 || NSWidth(rect) <= 1.0 || NSHeight(rect) <= 1.0) return;
    CGFloat imageAspect = image.size.width / image.size.height;
    CGFloat targetAspect = NSWidth(rect) / MAX(1.0, NSHeight(rect));
    NSRect source = NSZeroRect;
    source.size = image.size;
    if (imageAspect > targetAspect) {
        CGFloat sourceWidth = image.size.height * targetAspect;
        source.origin.x = (image.size.width - sourceWidth) * 0.5;
        source.size.width = sourceWidth;
    } else {
        CGFloat sourceHeight = image.size.width / targetAspect;
        source.origin.y = (image.size.height - sourceHeight) * 0.5;
        source.size.height = sourceHeight;
    }
    [image drawInRect:rect
             fromRect:source
            operation:NSCompositingOperationSourceOver
             fraction:alpha
       respectFlipped:YES
                 hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
}

- (BOOL)drawCommandIconInRect:(NSRect)rect color:(NSColor *)color {
    if (self.tileStyle != OPNControllerHomeTileStyleCommand || self.actionIdentifier.length == 0) return NO;
    NSString *action = self.actionIdentifier.lowercaseString;
    NSRect icon = NSInsetRect(rect, NSWidth(rect) * 0.24, NSHeight(rect) * 0.24);
    CGFloat strokeWidth = MAX(2.0, NSWidth(rect) * 0.055);

    [color setStroke];
    [color setFill];

    if ([action isEqualToString:@"library"]) {
        CGFloat cardHeight = NSHeight(icon) * 0.42;
        for (NSInteger index = 0; index < 3; index++) {
            CGFloat offset = (CGFloat)index * NSHeight(icon) * 0.15;
            NSRect stackRect = NSMakeRect(NSMinX(icon) + offset,
                                          NSMinY(icon) + NSHeight(icon) - cardHeight - offset,
                                          NSWidth(icon) - offset * 1.35,
                                          cardHeight);
            NSBezierPath *stack = [NSBezierPath bezierPathWithRoundedRect:stackRect xRadius:4.0 yRadius:4.0];
            stack.lineWidth = strokeWidth;
            [stack stroke];
        }
        return YES;
    }

    if ([action isEqualToString:@"favorites"]) {
        CGFloat headHeight = NSHeight(icon) * 0.38;
        NSRect headRect = NSMakeRect(NSMinX(icon) + NSWidth(icon) * 0.18,
                                     NSMinY(icon) + NSHeight(icon) * 0.05,
                                     NSWidth(icon) * 0.64,
                                     headHeight);
        NSBezierPath *head = [NSBezierPath bezierPathWithRoundedRect:headRect xRadius:5.0 yRadius:5.0];
        head.lineWidth = strokeWidth;
        [head stroke];

        NSBezierPath *pin = [NSBezierPath bezierPath];
        [pin moveToPoint:NSMakePoint(NSMidX(icon), NSMaxY(headRect))];
        [pin lineToPoint:NSMakePoint(NSMidX(icon), NSMinY(icon) + NSHeight(icon) * 0.78)];
        [pin lineToPoint:NSMakePoint(NSMidX(icon) - NSWidth(icon) * 0.22, NSMaxY(icon))];
        [pin moveToPoint:NSMakePoint(NSMidX(icon), NSMinY(icon) + NSHeight(icon) * 0.78)];
        [pin lineToPoint:NSMakePoint(NSMidX(icon) + NSWidth(icon) * 0.22, NSMaxY(icon))];
        pin.lineWidth = strokeWidth;
        pin.lineCapStyle = NSLineCapStyleRound;
        pin.lineJoinStyle = NSLineJoinStyleRound;
        [pin stroke];
        return YES;
    }

    if ([action isEqualToString:@"store"]) {
        NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:icon];
        ring.lineWidth = strokeWidth;
        [ring stroke];

        NSBezierPath *needle = [NSBezierPath bezierPath];
        [needle moveToPoint:NSMakePoint(NSMidX(icon), NSMinY(icon) + NSHeight(icon) * 0.19)];
        [needle lineToPoint:NSMakePoint(NSMinX(icon) + NSWidth(icon) * 0.66, NSMinY(icon) + NSHeight(icon) * 0.58)];
        [needle lineToPoint:NSMakePoint(NSMidX(icon), NSMaxY(icon) - NSHeight(icon) * 0.19)];
        [needle lineToPoint:NSMakePoint(NSMinX(icon) + NSWidth(icon) * 0.34, NSMinY(icon) + NSHeight(icon) * 0.42)];
        [needle closePath];
        [needle fill];
        return YES;
    }

    if ([action isEqualToString:@"settings"]) {
        NSPoint center = NSMakePoint(NSMidX(icon), NSMidY(icon));
        CGFloat outerRadius = MIN(NSWidth(icon), NSHeight(icon)) * 0.42;
        CGFloat innerRadius = outerRadius * 0.38;
        for (NSInteger index = 0; index < 8; index++) {
            CGFloat angle = ((CGFloat)index / 8.0) * (CGFloat)(M_PI * 2.0);
            NSBezierPath *spoke = [NSBezierPath bezierPath];
            [spoke moveToPoint:NSMakePoint(center.x + cos(angle) * outerRadius * 0.78, center.y + sin(angle) * outerRadius * 0.78)];
            [spoke lineToPoint:NSMakePoint(center.x + cos(angle) * outerRadius, center.y + sin(angle) * outerRadius)];
            spoke.lineWidth = strokeWidth;
            spoke.lineCapStyle = NSLineCapStyleRound;
            [spoke stroke];
        }
        NSRect outer = NSMakeRect(center.x - outerRadius * 0.72, center.y - outerRadius * 0.72, outerRadius * 1.44, outerRadius * 1.44);
        NSBezierPath *gear = [NSBezierPath bezierPathWithOvalInRect:outer];
        gear.lineWidth = strokeWidth;
        [gear stroke];
        NSRect inner = NSMakeRect(center.x - innerRadius, center.y - innerRadius, innerRadius * 2.0, innerRadius * 2.0);
        NSBezierPath *hole = [NSBezierPath bezierPathWithOvalInRect:inner];
        hole.lineWidth = strokeWidth;
        [hole stroke];
        return YES;
    }

    return NO;
}

- (void)drawGlyphInRect:(NSRect)rect {
    NSString *glyph = self.glyph.length > 0 ? self.glyph : @">";
    NSBezierPath *orb = [NSBezierPath bezierPathWithOvalInRect:rect];
    NSGradient *orbGradient = [[NSGradient alloc] initWithStartingColor:OpnColor(OPNControllerAccentSoftRGB(), self.controllerFocused ? 0.92 : 0.55)
                                                            endingColor:OpnColor(OPNControllerAccentRGB(), self.controllerFocused ? 0.44 : 0.20)];
    [orbGradient drawInBezierPath:orb angle:-35.0];
    OPNStrokePath(orb, OpnColor(0xFFFFFF, self.controllerFocused ? 0.46 : 0.18), 1.0);
    if ([self drawCommandIconInRect:rect color:OpnColor(OPNControllerAccentBlackRGB(0.90), 0.94)]) return;
    NSMutableParagraphStyle *center = [[NSMutableParagraphStyle alloc] init];
    center.alignment = NSTextAlignmentCenter;
    NSDictionary<NSAttributedStringKey, id> *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:NSHeight(rect) * 0.44 weight:NSFontWeightBlack],
        NSForegroundColorAttributeName: OpnColor(OPNControllerAccentBlackRGB(0.90), 0.94),
        NSParagraphStyleAttributeName: center,
    };
    [glyph drawInRect:NSMakeRect(NSMinX(rect), NSMinY(rect) + NSHeight(rect) * 0.25, NSWidth(rect), NSHeight(rect) * 0.52) withAttributes:attrs];
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSRect bounds = self.bounds;
    if (NSWidth(bounds) < 40.0 || NSHeight(bounds) < 40.0) return;

    CGFloat radius = self.tileStyle == OPNControllerHomeTileStyleHero ? 30.0 : 24.0;
    NSBezierPath *card = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, 1.0, 1.0) xRadius:radius yRadius:radius];
    NSGradient *cardGradient = [[NSGradient alloc] initWithColors:@[
        OpnColor(OPNControllerAccentBlackRGB(self.controllerFocused ? 0.52 : 0.72), self.tileStyle == OPNControllerHomeTileStyleHero ? 0.92 : 0.82),
        OpnColor(0x060A08, 0.92),
        OpnColor(0x020403, 0.96),
    ]];
    [cardGradient drawInBezierPath:card angle:self.tileStyle == OPNControllerHomeTileStyleHero ? 0.0 : -28.0];

    [NSGraphicsContext saveGraphicsState];
    [card addClip];
    CGFloat width = NSWidth(bounds);
    CGFloat height = NSHeight(bounds);
    if (self.tileStyle == OPNControllerHomeTileStyleHero) {
        [self drawImage:self.image inAspectFillRect:bounds alpha:self.image ? 0.88 : 0.0];
        NSGradient *leftScrim = [[NSGradient alloc] initWithColorsAndLocations:
            OpnColor(0x06100A, 0.98), 0.0,
            OpnColor(0x06100A, 0.84), 0.40,
            OpnColor(0x06100A, 0.30), 0.68,
            OpnColor(0x06100A, 0.08), 1.0,
            nil];
        [leftScrim drawInRect:bounds angle:0.0];
        NSGradient *floorScrim = [[NSGradient alloc] initWithStartingColor:OpnColor(0x020403, 0.0)
                                                              endingColor:OpnColor(0x020403, 0.72)];
        [floorScrim drawInRect:bounds angle:-90.0];
        NSBezierPath *lens = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(width * 0.42, -height * 0.38, width * 0.68, height * 1.34)];
        NSGradient *lensGlow = [[NSGradient alloc] initWithStartingColor:OpnColor(OPNControllerAccentSoftRGB(), self.controllerFocused ? 0.20 : 0.12)
                                                             endingColor:OpnColor(OPNControllerAccentRGB(), 0.0)];
        [lensGlow drawInBezierPath:lens angle:22.0];
    } else if (self.image) {
        NSRect imageRect = NSMakeRect(0.0, 0.0, width, height * 0.50);
        [self drawImage:self.image inAspectFillRect:imageRect alpha:0.86];
        NSGradient *scrim = [[NSGradient alloc] initWithStartingColor:OpnColor(0x020403, 0.0) endingColor:OpnColor(0x020403, 0.82)];
        [scrim drawInRect:imageRect angle:-90.0];
    } else if (self.tileStyle == OPNControllerHomeTileStyleGame) {
        CGFloat glyphSize = self.tileStyle == OPNControllerHomeTileStyleGame ? MIN(width, height) * 0.28 : MIN(width, height) * 0.34;
        [self drawGlyphInRect:NSMakeRect(22.0, 20.0, glyphSize, glyphSize)];
    }

    NSRect glowRect = NSMakeRect(-width * 0.12, height * 0.62, width * 0.86, height * 0.62);
    NSGradient *glow = [[NSGradient alloc] initWithStartingColor:OpnColor(OPNControllerAccentRGB(), self.controllerFocused ? 0.20 : 0.08)
                                                    endingColor:OpnColor(OPNControllerAccentRGB(), 0.0)];
    [glow drawInBezierPath:[NSBezierPath bezierPathWithOvalInRect:glowRect] angle:90.0];
    [NSGraphicsContext restoreGraphicsState];

    OPNStrokePath(card, OpnColor(self.controllerFocused ? 0xFFFFFF : 0xFFFFFF, self.controllerFocused ? 0.92 : 0.12), self.controllerFocused ? 3.0 : 1.0);
    if (self.controllerFocused) {
        OPNStrokePath([NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, 7.0, 7.0) xRadius:MAX(4.0, radius - 6.0) yRadius:MAX(4.0, radius - 6.0)], OpnColor(OPNControllerAccentSoftRGB(), 0.34), 1.0);
    }

    [NSGraphicsContext saveGraphicsState];
    [card addClip];
    void (^drawPill)(NSRect, CGFloat) = ^(NSRect pillRect, CGFloat fontSize) {
        if (self.detail.length == 0 || NSWidth(pillRect) <= 1.0 || NSHeight(pillRect) <= 1.0) return;
        NSBezierPath *pill = [NSBezierPath bezierPathWithRoundedRect:pillRect xRadius:NSHeight(pillRect) * 0.5 yRadius:NSHeight(pillRect) * 0.5];
        [OpnColor(OPNControllerAccentSoftRGB(), self.controllerFocused ? 0.92 : 0.16) setFill];
        [pill fill];
        OPNStrokePath(pill, OpnColor(OPNControllerAccentSoftRGB(), self.controllerFocused ? 0.0 : 0.26), 1.0);
        [self.detail drawInRect:NSInsetRect(pillRect, 12.0, MAX(3.0, (NSHeight(pillRect) - fontSize - 2.0) * 0.5))
                 withAttributes:[self textAttributesWithSize:fontSize
                                                       weight:NSFontWeightBlack
                                                        color:self.controllerFocused ? OpnColor(OPNControllerAccentBlackRGB(0.90), 0.94) : OpnColor(OPNControllerAccentSoftRGB(), 0.90)
                                                    alignment:NSTextAlignmentCenter
                                                    lineBreak:NSLineBreakByTruncatingTail]];
    };

    if (self.tileStyle == OPNControllerHomeTileStyleHero) {
        CGFloat pad = 30.0;
        CGFloat textWidth = width * 0.43;
        [self.eyebrow.uppercaseString drawInRect:NSMakeRect(pad, 32.0, textWidth, 17.0)
                                  withAttributes:[self textAttributesWithSize:12.0 weight:NSFontWeightBlack color:OpnColor(OPNControllerAccentSoftRGB(), 0.96) alignment:NSTextAlignmentLeft lineBreak:NSLineBreakByTruncatingTail]];
        [self.title drawInRect:NSMakeRect(pad, 63.0, textWidth, 86.0)
                withAttributes:[self textAttributesWithSize:34.0 weight:NSFontWeightBlack color:OpnColor(OPN::kTextPrimary) alignment:NSTextAlignmentLeft lineBreak:NSLineBreakByWordWrapping]];
        [self.subtitle drawInRect:NSMakeRect(pad, 166.0, textWidth, 62.0)
                   withAttributes:[self textAttributesWithSize:15.0 weight:NSFontWeightSemibold color:OpnColor(0xD9DEE0, 0.78) alignment:NSTextAlignmentLeft lineBreak:NSLineBreakByWordWrapping]];
        CGFloat pillWidth = MIN(textWidth, MAX(104.0, ceil([self.detail sizeWithAttributes:@{NSFontAttributeName: [NSFont systemFontOfSize:12.5 weight:NSFontWeightBlack]}].width) + 30.0));
        drawPill(NSMakeRect(pad, height - 62.0, pillWidth, 32.0), 12.5);
    } else if (self.tileStyle == OPNControllerHomeTileStyleCommand) {
        CGFloat pad = 26.0;
        CGFloat glyphSize = MIN(62.0, MAX(46.0, height * 0.34));
        NSRect glyphRect = NSMakeRect(pad, 28.0, glyphSize, glyphSize);
        if (!self.image) [self drawGlyphInRect:glyphRect];
        CGFloat textX = NSMaxX(glyphRect) + 20.0;
        CGFloat textWidth = MAX(90.0, width - textX - pad);
        [self.eyebrow.uppercaseString drawInRect:NSMakeRect(textX, 30.0, textWidth, 15.0)
                                  withAttributes:[self textAttributesWithSize:10.5 weight:NSFontWeightBlack color:OpnColor(OPNControllerAccentSoftRGB(), 0.92) alignment:NSTextAlignmentLeft lineBreak:NSLineBreakByTruncatingTail]];
        [self.title drawInRect:NSMakeRect(textX, 51.0, textWidth, 34.0)
                withAttributes:[self textAttributesWithSize:24.0 weight:NSFontWeightBlack color:OpnColor(OPN::kTextPrimary) alignment:NSTextAlignmentLeft lineBreak:NSLineBreakByTruncatingTail]];
        CGFloat pillWidth = MIN(textWidth, MAX(78.0, ceil([self.detail sizeWithAttributes:@{NSFontAttributeName: [NSFont systemFontOfSize:11.5 weight:NSFontWeightBlack]}].width) + 26.0));
        drawPill(NSMakeRect(textX, 93.0, pillWidth, 26.0), 11.5);
        [self.subtitle drawInRect:NSMakeRect(pad, height - 36.0, width - pad * 2.0, 18.0)
                   withAttributes:[self textAttributesWithSize:12.0 weight:NSFontWeightSemibold color:OpnColor(0xD9DEE0, 0.64) alignment:NSTextAlignmentLeft lineBreak:NSLineBreakByTruncatingTail]];
    } else {
        CGFloat pad = 22.0;
        CGFloat textY = self.image ? height * 0.47 + 8.0 : 28.0;
        CGFloat textWidth = width - pad * 2.0;
        CGFloat pillWidth = MIN(textWidth, MAX(82.0, ceil([self.detail sizeWithAttributes:@{NSFontAttributeName: [NSFont systemFontOfSize:11.0 weight:NSFontWeightBlack]}].width) + 24.0));
        drawPill(NSMakeRect(pad, textY, pillWidth, 25.0), 11.0);
        [self.title drawInRect:NSMakeRect(pad, textY + 34.0, textWidth, 28.0)
                withAttributes:[self textAttributesWithSize:20.0 weight:NSFontWeightBlack color:OpnColor(OPN::kTextPrimary) alignment:NSTextAlignmentLeft lineBreak:NSLineBreakByTruncatingTail]];
        CGFloat subtitleY = MIN(height - 27.0, textY + 64.0);
        [self.subtitle drawInRect:NSMakeRect(pad, subtitleY, textWidth, 18.0)
                   withAttributes:[self textAttributesWithSize:11.5 weight:NSFontWeightSemibold color:OpnColor(0xD9DEE0, 0.70) alignment:NSTextAlignmentLeft lineBreak:NSLineBreakByTruncatingTail]];
    }
    [NSGraphicsContext restoreGraphicsState];
}

- (void)mouseDown:(NSEvent *)event {
    (void)event;
    if (self.onSelect) self.onSelect();
}

@end

static NSColor *OPNReferencePromptFill(NSString *button) {
    if ([button isEqualToString:@"primary"]) return OpnColor(0x35E36E);
    if ([button isEqualToString:@"back"]) return OpnColor(0xF23D3D);
    if ([button isEqualToString:@"filter"]) return OpnColor(0xF2CC35);
    if ([button isEqualToString:@"search"]) return OpnColor(0x4B78F0);
    return OpnColor(0xE8E8E8);
}

static NSString *OPNReferencePromptLetter(NSString *button) {
    if ([button isEqualToString:@"primary"]) return @"A";
    if ([button isEqualToString:@"back"]) return @"B";
    if ([button isEqualToString:@"filter"]) return @"Y";
    if ([button isEqualToString:@"search"]) return @"X";
    return @"";
}

@interface OPNControllerPromptBarView : NSView
@property (nonatomic, assign) BOOL includeStore;
@property (nonatomic, assign) BOOL includeBack;
@property (nonatomic, assign) BOOL includeCategorySwitch;
@property (nonatomic, assign) OPNControllerPromptMode mode;
@end

@interface OPNControllerGameHubView : NSView
@property (nonatomic, copy) NSString *gameTitle;
@property (nonatomic, copy) NSString *genreSummary;
@property (nonatomic, copy) NSString *launchStatus;
@property (nonatomic, copy) NSString *studioInfo;
@property (nonatomic, copy) NSString *playerInfo;
@property (nonatomic, copy) NSString *controlInfo;
@property (nonatomic, copy) NSString *currentStoreInfo;
@property (nonatomic, copy) NSString *storeInfo;
@end

@implementation OPNControllerGameHubView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.wantsLayer = YES;
        _gameTitle = @"";
        _genreSummary = @"";
        _launchStatus = @"";
        _studioInfo = @"";
        _playerInfo = @"";
        _controlInfo = @"";
        _currentStoreInfo = @"";
        _storeInfo = @"";
    }
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)setGameTitle:(NSString *)gameTitle {
    _gameTitle = [gameTitle copy] ?: @"";
    [self setNeedsDisplay:YES];
}

- (void)setGenreSummary:(NSString *)genreSummary {
    _genreSummary = [genreSummary copy] ?: @"";
    [self setNeedsDisplay:YES];
}

- (void)setLaunchStatus:(NSString *)launchStatus {
    _launchStatus = [launchStatus copy] ?: @"";
    [self setNeedsDisplay:YES];
}

- (void)setStudioInfo:(NSString *)studioInfo {
    _studioInfo = [studioInfo copy] ?: @"";
    [self setNeedsDisplay:YES];
}

- (void)setPlayerInfo:(NSString *)playerInfo {
    _playerInfo = [playerInfo copy] ?: @"";
    [self setNeedsDisplay:YES];
}

- (void)setControlInfo:(NSString *)controlInfo {
    _controlInfo = [controlInfo copy] ?: @"";
    [self setNeedsDisplay:YES];
}

- (void)setCurrentStoreInfo:(NSString *)currentStoreInfo {
    _currentStoreInfo = [currentStoreInfo copy] ?: @"";
    [self setNeedsDisplay:YES];
}

- (void)setStoreInfo:(NSString *)storeInfo {
    _storeInfo = [storeInfo copy] ?: @"";
    [self setNeedsDisplay:YES];
}

- (NSDictionary<NSAttributedStringKey, id> *)attributesWithSize:(CGFloat)size
                                                         weight:(NSFontWeight)weight
                                                          color:(NSColor *)color
                                                      alignment:(NSTextAlignment)alignment {
    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.lineBreakMode = NSLineBreakByTruncatingTail;
    paragraph.alignment = alignment;
    return @{
        NSFontAttributeName: [NSFont systemFontOfSize:size weight:weight],
        NSForegroundColorAttributeName: color,
        NSParagraphStyleAttributeName: paragraph,
    };
}

- (void)drawStatusRowWithTitle:(NSString *)title value:(NSString *)value y:(CGFloat)y {
    NSRect bounds = self.bounds;
    CGFloat x = 22.0;
    CGFloat width = MAX(0.0, NSWidth(bounds) - 44.0);
    NSRect rowRect = NSMakeRect(x, y, width, 38.0);
    NSBezierPath *row = [NSBezierPath bezierPathWithRoundedRect:rowRect xRadius:13.0 yRadius:13.0];
    [OpnColor(0xFFFFFF, 0.045) setFill];
    [row fill];
    OPNStrokePath(row, OpnColor(0xFFFFFF, 0.070), 1.0);

    [title drawInRect:NSMakeRect(NSMinX(rowRect) + 14.0, NSMinY(rowRect) + 11.0, width * 0.35, 18.0)
       withAttributes:[self attributesWithSize:11.0 weight:NSFontWeightSemibold color:OpnColor(0xF4FFF7, 0.58) alignment:NSTextAlignmentLeft]];
    [value drawInRect:NSMakeRect(NSMinX(rowRect) + width * 0.34, NSMinY(rowRect) + 10.0, width * 0.62, 18.0)
       withAttributes:[self attributesWithSize:12.0 weight:NSFontWeightSemibold color:OpnColor(0xFFFFFF, 0.88) alignment:NSTextAlignmentRight]];
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSRect bounds = self.bounds;
    if (NSWidth(bounds) < 80.0 || NSHeight(bounds) < 80.0) return;

    NSBezierPath *panel = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, 0.5, 0.5) xRadius:24.0 yRadius:24.0];
    NSGradient *panelGradient = [[NSGradient alloc] initWithColors:@[
        OpnColor(OPNControllerAccentBlackRGB(0.93), 0.80),
        OpnColor(OPNControllerAccentBlackRGB(0.88), 0.64),
        OpnColor(0x05070A, 0.70),
    ]];
    [panelGradient drawInBezierPath:panel angle:-18.0];
    OPNStrokePath(panel, OpnColor(0xFFFFFF, 0.15), 1.0);

    [NSGraphicsContext saveGraphicsState];
    [panel addClip];

    NSRect glowRect = NSMakeRect(22.0, 20.0, 72.0, 4.0);
    NSBezierPath *glow = [NSBezierPath bezierPathWithRoundedRect:glowRect xRadius:2.0 yRadius:2.0];
    [OpnColor(OPNControllerAccentRGB(), 0.86) setFill];
    [glow fill];

    [@"GAME HUB" drawInRect:NSMakeRect(22.0, 34.0, NSWidth(bounds) - 44.0, 18.0)
             withAttributes:[self attributesWithSize:11.0 weight:NSFontWeightBold color:OpnColor(0xFFFFFF, 0.55) alignment:NSTextAlignmentLeft]];
    [self.gameTitle drawInRect:NSMakeRect(22.0, 56.0, NSWidth(bounds) - 44.0, 31.0)
                withAttributes:[self attributesWithSize:23.0 weight:NSFontWeightSemibold color:OpnColor(OPN::kTextPrimary) alignment:NSTextAlignmentLeft]];
    [self.genreSummary drawInRect:NSMakeRect(22.0, 88.0, NSWidth(bounds) - 44.0, 20.0)
                  withAttributes:[self attributesWithSize:12.0 weight:NSFontWeightMedium color:OpnColor(0xF4FFF7, 0.68) alignment:NSTextAlignmentLeft]];

    CGFloat playY = 126.0;
    NSRect playRect = NSMakeRect(22.0, playY, NSWidth(bounds) - 44.0, 54.0);
    NSBezierPath *play = [NSBezierPath bezierPathWithRoundedRect:playRect xRadius:20.0 yRadius:20.0];
    NSGradient *playGradient = [[NSGradient alloc] initWithStartingColor:OpnColor(OPNControllerAccentRGB(), 0.92)
                                                             endingColor:OpnColor(OPNControllerAccentSoftRGB(), 0.92)];
    [playGradient drawInBezierPath:play angle:0.0];
    [@"Play Now" drawInRect:NSMakeRect(NSMinX(playRect) + 18.0, NSMinY(playRect) + 15.0, NSWidth(playRect) * 0.48, 24.0)
             withAttributes:[self attributesWithSize:17.0 weight:NSFontWeightBold color:OpnColor(OPNControllerAccentBlackRGB(0.92)) alignment:NSTextAlignmentLeft]];
    [self.launchStatus drawInRect:NSMakeRect(NSMinX(playRect) + NSWidth(playRect) * 0.46, NSMinY(playRect) + 17.0, NSWidth(playRect) * 0.46, 20.0)
                   withAttributes:[self attributesWithSize:12.0 weight:NSFontWeightSemibold color:OpnColor(OPNControllerAccentBlackRGB(0.88), 0.74) alignment:NSTextAlignmentRight]];

    CGFloat rowY = playY + 72.0;
    [self drawStatusRowWithTitle:@"STUDIO" value:self.studioInfo y:rowY];
    [self drawStatusRowWithTitle:@"PLAYERS" value:self.playerInfo y:rowY + 46.0];
    [self drawStatusRowWithTitle:@"CONTROLS" value:self.controlInfo y:rowY + 92.0];
    [self drawStatusRowWithTitle:@"CURRENT STORE" value:self.currentStoreInfo y:rowY + 138.0];
    [self drawStatusRowWithTitle:@"STORES" value:self.storeInfo y:rowY + 184.0];
    [NSGraphicsContext restoreGraphicsState];
}

@end

@implementation OPNControllerPromptBarView

- (BOOL)isFlipped { return YES; }

- (void)setIncludeStore:(BOOL)includeStore {
    if (_includeStore == includeStore) return;
    _includeStore = includeStore;
    [self setNeedsDisplay:YES];
}

- (void)setIncludeBack:(BOOL)includeBack {
    if (_includeBack == includeBack) return;
    _includeBack = includeBack;
    [self setNeedsDisplay:YES];
}

- (void)setIncludeCategorySwitch:(BOOL)includeCategorySwitch {
    if (_includeCategorySwitch == includeCategorySwitch) return;
    _includeCategorySwitch = includeCategorySwitch;
    [self setNeedsDisplay:YES];
}

- (void)setMode:(OPNControllerPromptMode)mode {
    if (_mode == mode) return;
    _mode = mode;
    [self setNeedsDisplay:YES];
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)promptItems {
    if (self.mode == OPNControllerPromptModeHome) {
        return @[
            @{@"button": @"primary", @"title": @"Open"},
            @{@"button": @"back", @"title": @"Library"},
            @{@"button": @"search", @"title": @"Tabs"},
        ];
    }
    return @[
        @{@"button": @"primary", @"title": @"Select"},
        @{@"button": @"back", @"title": @"Back"},
        @{@"button": @"filter", @"title": @"Filter"},
        @{@"button": @"search", @"title": @"Search"},
    ];
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGFloat height = NSHeight(self.bounds);
    CGFloat scale = MAX(0.6, height / 36.0);
    CGFloat x = 0.0;
    CGFloat y = floor((height - 24.0 * scale) * 0.5);
    NSDictionary<NSAttributedStringKey, id> *labelAttributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:14.0 * scale weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: OpnColor(0xFFFFFF, 0.84),
    };
    NSDictionary<NSAttributedStringKey, id> *buttonAttributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12.0 * scale weight:NSFontWeightBlack],
        NSForegroundColorAttributeName: OpnColor(0x050807, 0.92),
    };

    for (NSDictionary<NSString *, NSString *> *item in [self promptItems]) {
        NSString *title = item[@"title"] ?: @"";
        NSString *button = item[@"button"] ?: @"";
        CGFloat titleWidth = ceil([title sizeWithAttributes:labelAttributes].width);
        CGFloat buttonSize = 24.0 * scale;
        NSRect buttonRect = NSMakeRect(x, y, buttonSize, buttonSize);
        NSBezierPath *buttonPath = [NSBezierPath bezierPathWithOvalInRect:buttonRect];
        [OPNReferencePromptFill(button) setFill];
        [buttonPath fill];
        NSMutableParagraphStyle *center = [[NSMutableParagraphStyle alloc] init];
        center.alignment = NSTextAlignmentCenter;
        NSMutableDictionary<NSAttributedStringKey, id> *buttonTextAttributes = [buttonAttributes mutableCopy];
        buttonTextAttributes[NSParagraphStyleAttributeName] = center;
        [OPNReferencePromptLetter(button) drawInRect:NSMakeRect(NSMinX(buttonRect), NSMinY(buttonRect) + 4.0 * scale, buttonSize, 14.0 * scale)
                                     withAttributes:buttonTextAttributes];

        [title drawInRect:NSMakeRect(NSMaxX(buttonRect) + 10.0 * scale, y + 3.0 * scale, titleWidth + 4.0 * scale, 18.0 * scale)
           withAttributes:labelAttributes];
        x += buttonSize + titleWidth + 42.0 * scale;
    }

    NSString *moreTitle = @"More Options";
    CGFloat moreTitleWidth = ceil([moreTitle sizeWithAttributes:labelAttributes].width);
    CGFloat menuSize = 24.0 * scale;
    CGFloat rightX = NSWidth(self.bounds) - menuSize - 10.0 * scale - moreTitleWidth;
    NSRect menuRect = NSMakeRect(rightX, y, menuSize, menuSize);
    NSBezierPath *menuCircle = [NSBezierPath bezierPathWithOvalInRect:menuRect];
    [OpnColor(0xFFFFFF, 0.88) setFill];
    [menuCircle fill];
    [OpnColor(0x0A0D0C, 0.92) setStroke];
    for (NSInteger row = 0; row < 3; row++) {
        CGFloat lineY = NSMinY(menuRect) + (7.0 + row * 5.0) * scale;
        NSBezierPath *line = [NSBezierPath bezierPath];
        [line moveToPoint:NSMakePoint(NSMinX(menuRect) + 7.0 * scale, lineY)];
        [line lineToPoint:NSMakePoint(NSMaxX(menuRect) - 7.0 * scale, lineY)];
        line.lineWidth = 1.6 * scale;
        [line stroke];
    }
    [moreTitle drawInRect:NSMakeRect(NSMaxX(menuRect) + 10.0 * scale, y + 3.0 * scale, moreTitleWidth + 4.0 * scale, 18.0 * scale)
           withAttributes:labelAttributes];
}

@end

@implementation OPNGameCatalogView

using namespace OPN;

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _cardViews = [NSMutableArray array];
        _catalogImageLoadTokens = [NSMutableArray array];
        _controllerHeroViews = [NSMutableArray array];
        _controllerHomeTileViews = [NSMutableArray array];
        _controllerStoreFilterOptionLabels = [NSMutableArray array];
        _controllerStoreFilterItems = @[];
        _categoryButtons = [NSMutableArray array];
        _categoryItems = @[];
        _selectedCategoryId = @"all";
        NSArray<NSString *> *storedFavorites = [NSUserDefaults.standardUserDefaults arrayForKey:OPNFavoriteGameIdsDefaultsKey];
        _favoriteGameIds = [NSMutableSet setWithArray:[storedFavorites isKindOfClass:NSArray.class] ? storedFavorites : @[]];
        _selectedSortId = @"last_played";
        _selectedFilterIds = [NSMutableSet set];
        _focusedCardIndex = -1;
        _focusedHomeItemIndex = 0;
        _controllerSurface = OPNControllerCatalogSurfaceHome;
        _controllerRenderedGameCount = 0;
        _controllerDisplayGameCount = 0;
        _desktopRenderStartIndex = 0;
        _hasDesktopFeaturedGame = NO;
        _desktopFeaturedVariantIndex = -1;
        _controllerLibraryRailContentWidth = 0.0;
        _controllerLibraryRailOffsetX = 0.0;
        _controllerLibraryWindowStartIndex = 0;
        _controllerLibraryVisibleStartIndex = 0;
        _controllerHeroIndex = 0;
        _controllerHeroImageAspectRatio = 16.0 / 9.0;
        _focusedControllerStoreFilterIndex = 0;
        _gridColumnCount = 1;
        self.wantsLayer = YES;
        self.layer.opaque = NO;
        self.layer.backgroundColor = [NSColor clearColor].CGColor;

        _controllerDetailBackgroundView = [[OPNControllerPreviewBackgroundView alloc] initWithFrame:self.bounds];
        _controllerDetailBackgroundView.hidden = YES;
        _controllerDetailBackgroundView.wantsLayer = YES;
        _controllerDetailBackgroundView.layer.masksToBounds = YES;
        [self addSubview:_controllerDetailBackgroundView];

        _libraryIconLabel = OpnLabel(@"", NSMakeRect(30, kNavHeight + 36, 0, 0),
                                     1, OpnColor(kBrandGreen), NSFontWeightBold);
        _libraryIconLabel.hidden = YES;
        [self addSubview:_libraryIconLabel];

        _titleLabel = OpnLabel(@"", NSMakeRect(0, 0, 0, 0),
                               28, OpnColor(kTextPrimary), NSFontWeightSemibold);
        _titleLabel.hidden = YES;
        [self addSubview:_titleLabel];

        _userLabel = OpnLabel(@"", NSMakeRect(24, kNavHeight + 40, 240, 18),
                              12, OpnColor(kTextMuted), NSFontWeightMedium);
        _userLabel.hidden = YES;
        [self addSubview:_userLabel];

        _signOutButton = [[NSButton alloc] initWithFrame:
            NSMakeRect(frame.size.width - 116, 58, 92, 30)];
        _signOutButton.title = @"Sign Out";
        _signOutButton.bordered = NO;
        _signOutButton.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
        _signOutButton.contentTintColor = OpnColor(kTextMuted);
        _signOutButton.target = self;
        _signOutButton.action = @selector(signOutClicked);
        _signOutButton.hidden = YES;
        [self addSubview:_signOutButton];

        _searchField = [[NSSearchField alloc] initWithFrame:NSMakeRect(238, kNavHeight + 27, 420, 38)];
        _searchField.cell = [[OPNCenteredSearchFieldCell alloc] initTextCell:@""];
        _searchField.placeholderString = @"Search your games";
        _searchField.delegate = self;
        _searchField.target = self;
        _searchField.action = @selector(searchChanged);
        _searchField.enabled = YES;
        _searchField.editable = YES;
        _searchField.selectable = YES;
        _searchField.font = [NSFont systemFontOfSize:14 weight:NSFontWeightMedium];
        _searchField.textColor = OpnColor(kTextPrimary);
        _searchField.bezeled = NO;
        _searchField.drawsBackground = NO;
        _searchField.focusRingType = NSFocusRingTypeNone;
        _searchField.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        _searchField.wantsLayer = YES;
        _searchField.layer.cornerRadius = 14;
        _searchField.layer.backgroundColor = OpnColor(OPNControllerAccentBlackRGB(0.88), 0.92).CGColor;
        _searchField.layer.borderColor = OpnColor(0xFFFFFF, 0.13).CGColor;
        _searchField.layer.borderWidth = 1;
        if ([_searchField.cell respondsToSelector:@selector(setDrawsBackground:)]) {
            [(NSSearchFieldCell *)_searchField.cell setDrawsBackground:NO];
        }
        NSTextFieldCell *searchCell = (NSTextFieldCell *)_searchField.cell;
        searchCell.alignment = NSTextAlignmentCenter;
        NSMutableParagraphStyle *placeholderStyle = [[NSMutableParagraphStyle alloc] init];
        placeholderStyle.alignment = NSTextAlignmentCenter;
        searchCell.placeholderAttributedString = [[NSAttributedString alloc]
            initWithString:@"Search your games"
                attributes:@{NSForegroundColorAttributeName: OpnColor(kTextMuted, 0.82),
                             NSFontAttributeName: [NSFont systemFontOfSize:14 weight:NSFontWeightMedium],
                             NSParagraphStyleAttributeName: placeholderStyle}];
        [self addSubview:_searchField];

        _filterButton = [[NSButton alloc] initWithFrame:NSMakeRect(0, kNavHeight + 27, 110, 38)];
        _filterButton.title = @"Filters";
        _filterButton.bordered = NO;
        _filterButton.font = [NSFont systemFontOfSize:13 weight:NSFontWeightRegular];
        _filterButton.contentTintColor = OpnColor(kTextSecondary);
        _filterButton.target = self;
        _filterButton.action = @selector(filterClicked:);
        _filterButton.wantsLayer = YES;
        _filterButton.layer.cornerRadius = 11;
        _filterButton.layer.backgroundColor = OpnColor(kInputBackground, 0.74).CGColor;
        _filterButton.layer.borderColor = OpnColor(0xFFFFFF, 0.09).CGColor;
        _filterButton.layer.borderWidth = 1;
        [self addSubview:_filterButton];

        _sortButton = [[NSButton alloc] initWithFrame:NSMakeRect(674, kNavHeight + 27, 144, 38)];
        _sortButton.title = @"Last Played";
        _sortButton.bordered = NO;
        _sortButton.font = [NSFont systemFontOfSize:13 weight:NSFontWeightRegular];
        _sortButton.contentTintColor = OpnColor(kTextSecondary);
        _sortButton.target = self;
        _sortButton.action = @selector(sortClicked:);
        _sortButton.wantsLayer = YES;
        _sortButton.layer.cornerRadius = 11;
        _sortButton.layer.backgroundColor = OpnColor(kInputBackground, 0.74).CGColor;
        _sortButton.layer.borderColor = OpnColor(0xFFFFFF, 0.09).CGColor;
        _sortButton.layer.borderWidth = 1;
        [self addSubview:_sortButton];

        _gameCountLabel = OpnLabel(@"", NSMakeRect(0, 0, 0, 0),
                                   12, OpnColor(kTextMuted), NSFontWeightRegular, NSTextAlignmentRight);
        _gameCountLabel.hidden = YES;
        [self addSubview:_gameCountLabel];

        _categoryBarView = [[NSView alloc] initWithFrame:NSZeroRect];
        _categoryBarView.wantsLayer = YES;
        _categoryBarView.hidden = YES;
        [self addSubview:_categoryBarView];

        CGFloat gridY = kNavHeight + kToolbarHeight;
        NSRect scrollFrame = NSMakeRect(0, gridY, frame.size.width, frame.size.height - gridY);
        _scrollView = [[OPNCatalogScrollView alloc] initWithFrame:scrollFrame];
        _scrollView.wantsLayer = YES;
        _scrollView.hasVerticalScroller = YES;
        _scrollView.hasHorizontalScroller = NO;
        _scrollView.autohidesScrollers = YES;
        _scrollView.drawsBackground = NO;
        _scrollView.borderType = NSNoBorder;
        _scrollView.layer.opaque = NO;
        _scrollView.layer.backgroundColor = NSColor.clearColor.CGColor;
        _scrollView.contentView.drawsBackground = NO;
        _scrollView.contentView.backgroundColor = NSColor.clearColor;
        _scrollView.contentView.wantsLayer = YES;
        _scrollView.contentView.layer.opaque = NO;
        _scrollView.contentView.layer.backgroundColor = NSColor.clearColor.CGColor;
        _scrollView.contentView.postsBoundsChangedNotifications = YES;
        [self addSubview:_scrollView];


        _gridContentView = [[OPNFlippedGridDocumentView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, 100)];
        _gridContentView.wantsLayer = YES;
        _gridContentView.layer.opaque = NO;
        _gridContentView.layer.backgroundColor = NSColor.clearColor.CGColor;
        _scrollView.documentView = _gridContentView;

        _statusLabel = OpnLabel(@"", NSMakeRect(0, gridY + 100, frame.size.width, 24),
                                15, OpnColor(kTextMuted));
        _statusLabel.alignment = NSTextAlignmentCenter;
        [self addSubview:_statusLabel];

        _controllerDetailView = [[OPNFlippedGridDocumentView alloc] initWithFrame:NSZeroRect];
        _controllerDetailView.hidden = YES;
        _controllerDetailView.wantsLayer = YES;
        _controllerDetailView.layer.cornerRadius = 0.0;
        _controllerDetailView.layer.borderWidth = 0.0;
        _controllerDetailView.layer.borderColor = OpnColor(0xFFFFFF, 0.0).CGColor;
        _controllerDetailView.layer.backgroundColor = NSColor.clearColor.CGColor;
        _controllerDetailView.layer.shadowColor = OpnColor(OPNControllerAccentRGB()).CGColor;
        _controllerDetailView.layer.shadowOpacity = 0.0;
        _controllerDetailView.layer.shadowRadius = 0.0;
        _controllerDetailView.layer.shadowOffset = CGSizeZero;
        _controllerDetailView.layer.transform = CATransform3DIdentity;

        _controllerDetailGradientLayer = [CAGradientLayer layer];
        _controllerDetailGradientLayer.colors = @[(id)NSColor.clearColor.CGColor,
                                                   (id)NSColor.clearColor.CGColor,
                                                   (id)NSColor.clearColor.CGColor];
        _controllerDetailGradientLayer.locations = @[@0.0, @0.46, @1.0];
        _controllerDetailGradientLayer.startPoint = CGPointMake(0.0, 0.0);
        _controllerDetailGradientLayer.endPoint = CGPointMake(1.0, 1.0);
        _controllerDetailGradientLayer.opacity = 0.0;
        [_controllerDetailView.layer addSublayer:_controllerDetailGradientLayer];

        _controllerDetailAccentLayer = [CALayer layer];
        _controllerDetailAccentLayer.backgroundColor = OpnColor(OPNControllerAccentSoftRGB(), 0.86).CGColor;
        _controllerDetailAccentLayer.cornerRadius = 2.0;
        [_controllerDetailView.layer addSublayer:_controllerDetailAccentLayer];
        [self addSubview:_controllerDetailView];

        _controllerDetailStatsLabel = OpnLabel(@"", NSZeroRect, 14.0, OpnColor(kTextSecondary), NSFontWeightMedium);
        [_controllerDetailView addSubview:_controllerDetailStatsLabel];

        _controllerDetailFeaturesLabel = OpnLabel(@"", NSZeroRect, 14.0, OpnColor(kTextMuted), NSFontWeightRegular);
        _controllerDetailFeaturesLabel.maximumNumberOfLines = 8;
        [_controllerDetailView addSubview:_controllerDetailFeaturesLabel];

        _controllerGameHubView = [[OPNControllerGameHubView alloc] initWithFrame:NSZeroRect];
        _controllerGameHubView.hidden = YES;
        [_controllerDetailView addSubview:_controllerGameHubView];

        _controllerPromptBarView = [[OPNControllerPromptBarView alloc] initWithFrame:NSZeroRect];
        _controllerPromptBarView.wantsLayer = YES;
        [_controllerDetailView addSubview:_controllerPromptBarView];

        _controllerBottomPromptBarView = [[OPNControllerPromptBarView alloc] initWithFrame:NSZeroRect];
        _controllerBottomPromptBarView.wantsLayer = YES;
        _controllerBottomPromptBarView.hidden = YES;
        [self addSubview:_controllerBottomPromptBarView];

        _controllerSectionLabel = OpnLabel(@"", NSZeroRect, 18.0, OpnColor(kTextPrimary), NSFontWeightBold);
        _controllerSectionLabel.hidden = YES;
        [self addSubview:_controllerSectionLabel];

        _loadingView = [[OPNLoadingView alloc] initWithFrame:self.bounds
                                                      message:@"Loading games..."];
        _loadingView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        _loadingView.hidden = YES;
        [self addSubview:_loadingView];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(interfacePreferencesChanged:)
                                                     name:OPNInterfacePreferencesDidChangeNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(controllerDidConnect:)
                                                     name:GCControllerDidConnectNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(controllerDidDisconnect:)
                                                     name:GCControllerDidDisconnectNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(libraryScrollViewBoundsDidChange:)
                                                     name:NSViewBoundsDidChangeNotification
                                                   object:_scrollView.contentView];
        [self startGamepadNavigationIfNeeded];
        [self layoutCatalogSubviews];
    }
    return self;
}

- (void)dealloc {
    [self cancelCatalogImageLoads];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopGamepadNavigation];
    [self stopControllerDetailBackgroundRotation];
    [self stopControllerHeroRotation];
}

- (void)cancelCatalogImageLoads {
    for (OpnImageLoadToken *token in self.catalogImageLoadTokens) [token cancel];
    [self.catalogImageLoadTokens removeAllObjects];
}

- (void)trackCatalogImageLoadToken:(OpnImageLoadToken *)token {
    if (!token) return;
    [self.catalogImageLoadTokens addObject:token];
    if (self.catalogImageLoadTokens.count > 96) {
        [self.catalogImageLoadTokens removeObjectsInRange:NSMakeRange(0, self.catalogImageLoadTokens.count - 64)];
    }
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window) {
        [self startGamepadNavigationIfNeeded];
        [self startControllerDetailBackgroundRotationIfNeeded];
        [self startControllerHeroRotationIfNeeded];
    } else {
        [self stopGamepadNavigation];
        [self stopControllerDetailBackgroundRotation];
        [self stopControllerHeroRotation];
    }
}

- (void)applyControllerAccentColors {
    self.searchField.layer.backgroundColor = OpnColor(OPNControllerAccentBlackRGB(0.88), 0.92).CGColor;
    self.controllerDetailView.layer.backgroundColor = NSColor.clearColor.CGColor;
    self.controllerDetailView.layer.shadowColor = OpnColor(OPNControllerAccentRGB()).CGColor;
    self.controllerDetailGradientLayer.colors = @[(id)NSColor.clearColor.CGColor,
                                                  (id)NSColor.clearColor.CGColor,
                                                  (id)NSColor.clearColor.CGColor];
    self.controllerDetailGradientLayer.opacity = 0.0;
    self.controllerDetailAccentLayer.backgroundColor = OpnColor(OPNControllerAccentSoftRGB(), 0.86).CGColor;
    self.layer.backgroundColor = NSColor.clearColor.CGColor;
}

- (void)interfacePreferencesChanged:(NSNotification *)notification {
    (void)notification;
    [self applyControllerAccentColors];
    [self renderGrid];
    [self startGamepadNavigationIfNeeded];
}

- (BOOL)acceptsFirstResponder { return YES; }

- (BOOL)becomeFirstResponder {
    BOOL result = [super becomeFirstResponder];
    if (self.focusedCardIndex < 0 && self.cardViews.count > 0) [self focusCardAtIndex:0 scrollIntoView:NO];
    return result;
}

- (BOOL)isFlipped { return YES; }

- (void)mouseDown:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (!self.searchField.hidden && NSPointInRect(point, self.searchField.frame)) {
        [self.window makeFirstResponder:self.searchField];
        [self.searchField mouseDown:event];
        return;
    }
    [super mouseDown:event];
}

- (void)setUserName:(NSString *)name {
    _userLabel.stringValue = name ? [NSString stringWithFormat:@"Signed in as %@", name] : @"";
}

- (void)setLoading:(BOOL)loading {
    _loadingView.hidden = !loading;
    if (loading) {
        [_loadingView startAnimating];
        _statusLabel.stringValue = @"";
    } else {
        [_loadingView stopAnimating];
        _statusLabel.stringValue = @"";
    }
}

- (void)setError:(NSString *)message {
    _loadingView.hidden = YES;
    [_loadingView stopAnimating];
    _statusLabel.stringValue = message ? message : @"";
}

- (void)setGames:(const std::vector<OPN::GameInfo> &)games {
    _allGames = games;
    self.catalogTotalCount = (NSInteger)games.size();
    self.catalogSupportedCount = (NSInteger)games.size();
    [self resetDesktopGridRenderWindow];
    [self rebuildCategoryBar];
    [self renderGrid];
    [self scrollLibraryToTop];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self scrollLibraryToTop];
    });
}

- (const OPN::GameInfo *)currentLastPlayedGame {
    if (_allGames.empty() || ![self.selectedSortId isEqualToString:@"last_played"]) return nullptr;
    return &_allGames.front();
}

- (int)preferredVariantIndexForGame:(const OPN::GameInfo &)game {
    for (size_t index = 0; index < game.variants.size(); index++) {
        if (game.variants[index].librarySelected) return (int)index;
    }
    return 0;
}

- (void)addDesktopLibraryMetricPillWithTitle:(NSString *)title value:(NSString *)value frame:(NSRect)frame {
    NSView *pill = [[NSView alloc] initWithFrame:frame];
    pill.wantsLayer = YES;
    pill.layer.cornerRadius = 18.0;
    pill.layer.backgroundColor = OpnColor(0xFFFFFF, 0.055).CGColor;
    pill.layer.borderWidth = 1.0;
    pill.layer.borderColor = OpnColor(0xFFFFFF, 0.105).CGColor;
    [self.gridContentView addSubview:pill];

    NSTextField *valueLabel = OpnLabel(value ?: @"0", NSMakeRect(14.0, 8.0, NSWidth(frame) - 28.0, 26.0), 22.0, OpnColor(kTextPrimary), NSFontWeightBold, NSTextAlignmentCenter);
    [pill addSubview:valueLabel];
    NSTextField *titleLabel = OpnLabel((title ?: @"").uppercaseString, NSMakeRect(10.0, 35.0, NSWidth(frame) - 20.0, 14.0), 10.0, OpnColor(kTextMuted), NSFontWeightBlack, NSTextAlignmentCenter);
    [pill addSubview:titleLabel];
}

- (void)addDesktopLibraryHeroForGame:(const OPN::GameInfo &)game frame:(NSRect)frame {
    NSView *stage = [[NSView alloc] initWithFrame:frame];
    stage.wantsLayer = YES;
    CAGradientLayer *stageGradient = [CAGradientLayer layer];
    stageGradient.frame = stage.bounds;
    stageGradient.colors = @[(id)OpnColor(0x0B1710, 0.96).CGColor,
                             (id)OpnColor(0x10131A, 0.94).CGColor,
                             (id)OpnColor(0x030506, 0.98).CGColor];
    stageGradient.locations = @[@0.0, @0.56, @1.0];
    stageGradient.startPoint = CGPointMake(0.0, 0.0);
    stageGradient.endPoint = CGPointMake(1.0, 1.0);
    stage.layer = stageGradient;
    stage.layer.cornerRadius = 34.0;
    stage.layer.borderWidth = 1.0;
    stage.layer.borderColor = OpnColor(0xFFFFFF, 0.13).CGColor;
    stage.layer.shadowColor = OpnColor(0x000000, 1.0).CGColor;
    stage.layer.shadowOpacity = 0.34;
    stage.layer.shadowRadius = 28.0;
    stage.layer.shadowOffset = CGSizeMake(0.0, 18.0);
    [self.gridContentView addSubview:stage];

    CALayer *accent = [CALayer layer];
    accent.frame = NSMakeRect(0.0, 0.0, NSWidth(frame), 3.0);
    accent.backgroundColor = OpnColor(kBrandGreen, 0.90).CGColor;
    [stage.layer addSublayer:accent];

    CGFloat width = NSWidth(frame);
    CGFloat height = NSHeight(frame);
    CGFloat artWidth = MIN(width * 0.58, MAX(470.0, width - 420.0));
    CGFloat artX = width - artWidth - 34.0;
    CGFloat artHeight = height - 68.0;
    OPNControllerPreviewBackgroundView *artwork = [[OPNControllerPreviewBackgroundView alloc] initWithFrame:NSMakeRect(artX, 34.0, artWidth, artHeight)];
    artwork.cornerRadius = 28.0;
    artwork.wantsLayer = YES;
    artwork.layer.cornerRadius = 28.0;
    artwork.layer.masksToBounds = YES;
    artwork.layer.borderWidth = 1.0;
    artwork.layer.borderColor = OpnColor(0xFFFFFF, 0.16).CGColor;
    [stage addSubview:artwork];
    [self loadControllerHeroImageForView:artwork candidates:OPNControllerHeroBackgroundCandidates(game) index:0];

    CGFloat textWidth = MAX(320.0, artX - 64.0);
    NSTextField *kicker = OpnLabel(@"READY TO STREAM", NSMakeRect(34.0, 38.0, textWidth, 18.0), 12.0, OpnColor(kBrandGreen), NSFontWeightBlack);
    [stage addSubview:kicker];

    NSString *titleText = OPNCatalogString(game.title, @"Untitled");
    NSTextField *title = OpnLabel(titleText, NSMakeRect(34.0, 64.0, textWidth, 96.0), 42.0, OpnColor(kTextPrimary), NSFontWeightBlack);
    title.lineBreakMode = NSLineBreakByWordWrapping;
    title.maximumNumberOfLines = 2;
    [stage addSubview:title];

    NSString *description = OPNCatalogString(game.description, @"Jump back into your cloud library with your linked PC stores close at hand.");
    NSTextField *body = OpnLabel(description, NSMakeRect(36.0, 170.0, textWidth - 10.0, 68.0), 14.0, OpnColor(kTextSecondary), NSFontWeightMedium);
    body.lineBreakMode = NSLineBreakByWordWrapping;
    body.maximumNumberOfLines = 3;
    [stage addSubview:body];

    NSString *store = game.availableStores.empty() ? @"Cloud Ready" : OPNStoreCategoryTitle(OPNCatalogString(game.availableStores.front(), @""));
    NSString *metaText = OPNCatalogJoinedStrings(game.genres, store);
    NSTextField *meta = OpnLabel(metaText, NSMakeRect(36.0, height - 88.0, textWidth - 10.0, 22.0), 13.0, OpnColor(kTextMuted), NSFontWeightSemibold);
    meta.lineBreakMode = NSLineBreakByTruncatingTail;
    [stage addSubview:meta];

    BOOL resumeAvailable = OPNGameHasActiveSession(game, _activeSessionAppIds);
    NSString *primaryTitle = resumeAvailable ? @"Resume" : @"Play";
    NSButton *primary = OpnButton(primaryTitle, NSMakeRect(36.0, height - 54.0, 132.0, 34.0), OpnColor(OPNControllerAccentSoftRGB(), 0.96), OpnColor(OPNControllerAccentBlackRGB(0.88)));
    primary.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightBold];
    primary.target = self;
    primary.action = @selector(desktopHeroPlayClicked:);
    primary.layer.cornerRadius = 17.0;
    [stage addSubview:primary];

    NSString *secondaryTitle = resumeAvailable ? @"Active session ready" : @"Launch from cloud";
    NSTextField *actionHint = OpnLabel(secondaryTitle, NSMakeRect(NSMaxX(primary.frame) + 14.0, height - 46.0, MAX(120.0, textWidth - 182.0), 18.0), 12.0, OpnColor(kTextMuted), NSFontWeightSemibold);
    actionHint.lineBreakMode = NSLineBreakByTruncatingTail;
    [stage addSubview:actionHint];
}

- (void)selectDesktopFeaturedGame:(const OPN::GameInfo &)game variantIndex:(int)variantIndex {
    self.desktopFeaturedGame = game;
    self.desktopFeaturedVariantIndex = variantIndex >= 0 ? variantIndex : [self preferredVariantIndexForGame:game];
    self.hasDesktopFeaturedGame = YES;
    [self renderGrid];
}

- (void)desktopHeroPlayClicked:(id)sender {
    (void)sender;
    if (!self.hasDesktopFeaturedGame || !self.onSelectGame) return;
    int variantIndex = self.desktopFeaturedVariantIndex >= 0 ? self.desktopFeaturedVariantIndex : [self preferredVariantIndexForGame:self.desktopFeaturedGame];
    self.onSelectGame(self.desktopFeaturedGame, variantIndex);
}

- (void)setCatalogBrowseResult:(const OPN::CatalogBrowseResult &)result {
    OPN::LogInfo(@"[CatalogView] setCatalogBrowseResult games=%lu total=%d returned=%d supported=%d selectedSort=%s filters=%lu currentCards=%lu", (unsigned long)result.games.size(), result.totalCount, result.numberReturned, result.numberSupported, result.selectedSortId.c_str(), (unsigned long)result.selectedFilterIds.size(), (unsigned long)self.cardViews.count);
    _allGames = result.games;
    [self resetDesktopGridRenderWindow];
    for (OPNGameCardView *card in self.cardViews) {
        NSString *identifier = [self favoriteIdentifierForGame:card.game];
        BOOL updated = NO;
        for (const OPN::GameInfo &game : _allGames) {
            NSString *candidate = [self favoriteIdentifierForGame:game];
            if (identifier.length == 0 || ![identifier isEqualToString:candidate]) continue;
            [card updateGame:game];
            updated = YES;
            break;
        }
        NSString *title = OPNCatalogString(card.game.title, @"<untitled>");
        OPN::LogInfo(@"[CatalogView] existing card metadata refresh title=%@ identifier=%@ updated=%d", title, identifier ?: @"", updated);
    }
    self.catalogFilterGroups = result.filterGroups;
    self.catalogSortOptions = result.sortOptions;
    self.catalogTotalCount = result.totalCount;
    self.catalogSupportedCount = result.numberSupported;
    self.selectedSortId = OPNCatalogString(result.selectedSortId, @"last_played");
    [self.selectedFilterIds removeAllObjects];
    for (const std::string &filterId : result.selectedFilterIds) {
        if (!filterId.empty()) [self.selectedFilterIds addObject:[NSString stringWithUTF8String:filterId.c_str()]];
    }
    NSString *sortTitle = @"Last Played";
    for (const OPN::CatalogSortOption &option : self.catalogSortOptions) {
        if (option.id == result.selectedSortId) {
            sortTitle = OPNCatalogString(option.label, sortTitle);
            break;
        }
    }
    self.sortButton.title = sortTitle;
    self.filterButton.title = self.selectedFilterIds.count > 0
        ? [NSString stringWithFormat:@"Filters (%lu)", (unsigned long)self.selectedFilterIds.count]
        : @"Filters";
    self.searchField.stringValue = OPNCatalogString(result.searchQuery, @"");
    [self updateControllerDetailContent];
    [self rebuildCategoryBar];
    [self renderGrid];
    [self scrollLibraryToTop];
}

- (void)setFeaturedGames:(const std::vector<OPN::GameInfo> &)games {
    _featuredGames = games;
    self.controllerHeroIndex = 0;
    if (OpnControllerModeEnabled() && self.controllerSurface == OPNControllerCatalogSurfaceLibrary) {
        [self renderControllerHero];
        [self startControllerHeroRotationIfNeeded];
    } else if (OpnControllerModeEnabled()) {
        [self renderGrid];
    } else {
        self.hasDesktopFeaturedGame = NO;
        [self renderGrid];
    }
}

- (void)setActiveSessionAppIds:(const std::vector<int> &)appIds {
    _activeSessionAppIds = appIds;
    if (OpnControllerModeEnabled()) {
        if (self.controllerSurface == OPNControllerCatalogSurfaceLibrary) {
            [self renderControllerHero];
        } else {
            [self renderGrid];
        }
    } else {
        [self renderGrid];
    }
}

- (void)showControllerHome {
    if (!OpnControllerModeEnabled()) return;
    if (self.controllerSurface == OPNControllerCatalogSurfaceHome) {
        if (self.onControllerSurfaceChanged) self.onControllerSurfaceChanged(YES);
        return;
    }
    self.controllerSurface = OPNControllerCatalogSurfaceHome;
    self.focusedHomeItemIndex = MAX(0, self.focusedHomeItemIndex);
    self.focusedCardIndex = -1;
    [self hideControllerStoreFilterOverlayApplyingSelection:NO];
    [self stopControllerHeroRotation];
    [self stopControllerDetailBackgroundRotation];
    if (self.onControllerSurfaceChanged) self.onControllerSurfaceChanged(YES);
    [self renderGrid];
    [self scrollLibraryToTop];
}

- (void)showControllerLibrary {
    if (!OpnControllerModeEnabled()) return;
    if (self.controllerSurface == OPNControllerCatalogSurfaceLibrary) {
        if (self.onControllerSurfaceChanged) self.onControllerSurfaceChanged(NO);
        return;
    }
    self.controllerSurface = OPNControllerCatalogSurfaceLibrary;
    self.focusedHomeItemIndex = 0;
    if (self.focusedCardIndex < 0) self.focusedCardIndex = 0;
    self.controllerLibraryVisibleStartIndex = 0;
    self.controllerLibraryRailOffsetX = 0.0;
    if (self.onControllerSurfaceChanged) self.onControllerSurfaceChanged(NO);
    [self renderGrid];
    [self scrollLibraryToTop];
}

- (void)rebuildCategoryBar {
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *items = [NSMutableArray array];
    if (OpnControllerModeEnabled()) {
        [items addObject:@{@"id": @"library", @"title": @"Library"}];
        [items addObject:@{@"id": @"favorites", @"title": @"Favorites"}];
        BOOL selectedStillExists = NO;
        for (NSDictionary<NSString *, NSString *> *item in items) {
            if ([item[@"id"] isEqualToString:self.selectedCategoryId]) selectedStillExists = YES;
        }
        if (!selectedStillExists) self.selectedCategoryId = @"library";
        self.categoryItems = items;
        for (NSView *view in self.categoryBarView.subviews) [view removeFromSuperview];
        [self.categoryButtons removeAllObjects];
        return;
    }

    [items addObject:@{@"id": @"all", @"title": @"All"}];
    [items addObject:@{@"id": @"favorites", @"title": @"Favorites"}];

    NSInteger libraryCount = 0;
    NSMutableDictionary<NSString *, NSNumber *> *storeCounts = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *storeTitles = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSNumber *> *genreCounts = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *genreTitles = [NSMutableDictionary dictionary];

    for (const OPN::GameInfo &game : _allGames) {
        if (game.isInLibrary) libraryCount++;
        for (const std::string &storeValue : game.availableStores) {
            if (storeValue.empty()) continue;
            NSString *store = [NSString stringWithUTF8String:storeValue.c_str()];
            NSString *categoryId = OPNCategoryId(@"store", store);
            if (categoryId.length == 0) continue;
            storeCounts[categoryId] = @((storeCounts[categoryId] ?: @0).integerValue + 1);
            if (!storeTitles[categoryId]) storeTitles[categoryId] = OPNStoreCategoryTitle(store);
        }
        for (const std::string &genreValue : game.genres) {
            if (genreValue.empty()) continue;
            NSString *genre = [NSString stringWithUTF8String:genreValue.c_str()];
            NSString *categoryId = OPNCategoryId(@"genre", genre);
            if (categoryId.length == 0) continue;
            genreCounts[categoryId] = @((genreCounts[categoryId] ?: @0).integerValue + 1);
            if (!genreTitles[categoryId]) genreTitles[categoryId] = OPNCatalogDisplayLabel(genre);
        }
    }

    if (libraryCount > 0) [items addObject:@{@"id": @"library", @"title": @"Library"}];

    NSArray<NSString *> *sortedGenreIds = [[genreCounts allKeys] sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSInteger countA = genreCounts[a].integerValue;
        NSInteger countB = genreCounts[b].integerValue;
        if (countA != countB) return countA > countB ? NSOrderedAscending : NSOrderedDescending;
        return [genreTitles[a] localizedCaseInsensitiveCompare:genreTitles[b]];
    }];
    for (NSString *categoryId in sortedGenreIds) {
        if (items.count >= 9) break;
        NSString *title = genreTitles[categoryId];
        if (title.length > 0) [items addObject:@{@"id": categoryId, @"title": title}];
    }

    NSArray<NSString *> *sortedStoreIds = [[storeCounts allKeys] sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSInteger countA = storeCounts[a].integerValue;
        NSInteger countB = storeCounts[b].integerValue;
        if (countA != countB) return countA > countB ? NSOrderedAscending : NSOrderedDescending;
        return [storeTitles[a] localizedCaseInsensitiveCompare:storeTitles[b]];
    }];
    for (NSString *categoryId in sortedStoreIds) {
        if (items.count >= 14) break;
        NSString *title = storeTitles[categoryId];
        if (title.length > 0) [items addObject:@{@"id": categoryId, @"title": [@"Store: " stringByAppendingString:title]}];
    }

    BOOL selectedStillExists = NO;
    for (NSDictionary<NSString *, NSString *> *item in items) {
        if ([item[@"id"] isEqualToString:self.selectedCategoryId]) selectedStillExists = YES;
    }
    if (!selectedStillExists) self.selectedCategoryId = @"all";

    self.categoryItems = items;
    for (NSView *view in self.categoryBarView.subviews) [view removeFromSuperview];
    [self.categoryButtons removeAllObjects];

    CGFloat x = 0.0;
    for (NSDictionary<NSString *, NSString *> *item in items) {
        NSString *title = item[@"title"] ?: @"";
        CGFloat buttonWidth = MIN(130.0, MAX(60.0, title.length * 8.4 + 28.0));
        NSButton *button = [[NSButton alloc] initWithFrame:NSMakeRect(x, 0.0, buttonWidth, 30.0)];
        button.title = title;
        button.identifier = item[@"id"] ?: @"all";
        button.bordered = NO;
        button.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightSemibold];
        button.target = self;
        button.action = @selector(categoryButtonClicked:);
        button.wantsLayer = YES;
        button.layer.cornerRadius = 15.0;
        [self.categoryBarView addSubview:button];
        [self.categoryButtons addObject:button];
        x += buttonWidth + 8.0;
    }
}

- (NSString *)activeCategoryTitle {
    NSString *selectedCategoryId = self.selectedCategoryId.length > 0 ? self.selectedCategoryId : @"all";
    for (NSDictionary<NSString *, NSString *> *item in self.categoryItems) {
        if ([item[@"id"] isEqualToString:selectedCategoryId]) {
            NSString *title = item[@"title"];
            return title.length > 0 ? title : @"All";
        }
    }
    return @"All";
}

- (void)categoryButtonClicked:(NSButton *)sender {
    NSString *categoryId = sender.identifier.length > 0 ? sender.identifier : @"all";
    if ([categoryId isEqualToString:self.selectedCategoryId]) return;
    self.selectedCategoryId = categoryId;
    self.focusedCardIndex = 0;
    self.controllerRenderedGameCount = [self controllerInitialRenderedGameCount];
    [self resetDesktopGridRenderWindow];
    if (OpnControllerModeEnabled()) OpnPlayConsoleTone(OPNConsoleToneChange);
    [self renderGrid];
    [self scrollLibraryToTop];
}

- (NSInteger)gameCountForCategory:(NSString *)categoryId {
    NSInteger count = 0;
    for (const OPN::GameInfo &game : self.allGames) {
        if ([self game:game matchesCategory:categoryId]) count++;
    }
    return count;
}

- (BOOL)game:(const OPN::GameInfo &)game matchesCategory:(NSString *)categoryId {
    if (categoryId.length == 0 || [categoryId isEqualToString:@"all"]) return YES;
    if ([categoryId isEqualToString:@"favorites"]) return [self isFavoriteGame:game];
    if ([categoryId isEqualToString:@"library"]) return game.isInLibrary;
    if ([categoryId hasPrefix:@"store:"]) {
        for (const std::string &storeValue : game.availableStores) {
            NSString *store = [NSString stringWithUTF8String:storeValue.c_str()];
            if ([OPNCategoryId(@"store", store) isEqualToString:categoryId]) return YES;
        }
        return NO;
    }
    if ([categoryId hasPrefix:@"genre:"]) {
        for (const std::string &genreValue : game.genres) {
            NSString *genre = [NSString stringWithUTF8String:genreValue.c_str()];
            if ([OPNCategoryId(@"genre", genre) isEqualToString:categoryId]) return YES;
        }
        return NO;
    }
    return YES;
}

- (NSString *)favoriteIdentifierForGame:(const OPN::GameInfo &)game {
    if (!game.id.empty()) return [NSString stringWithUTF8String:game.id.c_str()];
    if (!game.uuid.empty()) return [NSString stringWithUTF8String:game.uuid.c_str()];
    if (!game.launchAppId.empty()) return [NSString stringWithUTF8String:game.launchAppId.c_str()];
    return OPNCatalogString(game.title, @"");
}

- (BOOL)isFavoriteGame:(const OPN::GameInfo &)game {
    NSString *identifier = [self favoriteIdentifierForGame:game];
    return identifier.length > 0 && [self.favoriteGameIds containsObject:identifier];
}

- (void)persistFavoriteGameIds {
    NSArray<NSString *> *sortedIds = [[self.favoriteGameIds allObjects] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    [NSUserDefaults.standardUserDefaults setObject:sortedIds forKey:OPNFavoriteGameIdsDefaultsKey];
    [NSUserDefaults.standardUserDefaults synchronize];
}

- (void)toggleFavoriteForFocusedGame {
    OPNGameCardView *card = [self focusedCard];
    if (!card) return;
    NSString *identifier = [self favoriteIdentifierForGame:card.game];
    if (identifier.length == 0) return;
    if ([self.favoriteGameIds containsObject:identifier]) {
        [self.favoriteGameIds removeObject:identifier];
    } else {
        [self.favoriteGameIds addObject:identifier];
    }
    [self persistFavoriteGameIds];
    if (OpnControllerModeEnabled()) OpnPlayConsoleTone(OPNConsoleToneChange);
    [self rebuildCategoryBar];
    if ([self.selectedCategoryId isEqualToString:@"favorites"] && ![self isFavoriteGame:card.game]) {
        self.focusedCardIndex = MIN(self.focusedCardIndex, MAX(0, (NSInteger)self.cardViews.count - 2));
        [self renderGrid];
    } else {
        [self updateControllerDetailContent];
        [self layoutCatalogSubviews];
    }
}

- (void)cycleCategoryBy:(NSInteger)delta {
    if (self.categoryItems.count <= 1 || delta == 0) return;
    NSInteger currentIndex = 0;
    for (NSUInteger i = 0; i < self.categoryItems.count; i++) {
        if ([self.categoryItems[i][@"id"] isEqualToString:self.selectedCategoryId]) {
            currentIndex = (NSInteger)i;
            break;
        }
    }
    NSInteger nextIndex = (currentIndex + delta) % (NSInteger)self.categoryItems.count;
    if (nextIndex < 0) nextIndex += (NSInteger)self.categoryItems.count;
    self.selectedCategoryId = self.categoryItems[(NSUInteger)nextIndex][@"id"] ?: @"all";
    self.focusedCardIndex = 0;
    self.controllerRenderedGameCount = [self controllerInitialRenderedGameCount];
    [self resetDesktopGridRenderWindow];
    if (OpnControllerModeEnabled()) OpnPlayConsoleTone(OPNConsoleToneChange);
    [self renderGrid];
    [self scrollLibraryToTop];
}

- (std::vector<OPN::GameInfo>)controllerLibraryDisplayGames {
    std::vector<OPN::GameInfo> displayGames;
    displayGames.reserve(_allGames.size());
    BOOL categoryFiltered = self.selectedCategoryId.length > 0 && ![self.selectedCategoryId isEqualToString:@"all"] && ![self.selectedCategoryId isEqualToString:@"library"];
    for (const OPN::GameInfo &game : _allGames) {
        if (!game.isInLibrary) continue;
        if (!OPNLibraryGameHasAccessibleVariants(game)) continue;
        OPN::GameInfo libraryGame = OPNGameWithLibraryAccessibleVariants(game);
        if (categoryFiltered && ![self game:libraryGame matchesCategory:self.selectedCategoryId]) continue;
        displayGames.push_back(libraryGame);
    }
    if (displayGames.empty() && !categoryFiltered) {
        for (const OPN::GameInfo &game : _allGames) {
            if (!OPNLibraryGameHasAccessibleVariants(game)) continue;
            OPN::GameInfo libraryGame = OPNGameWithLibraryAccessibleVariants(game);
            if ([self game:libraryGame matchesCategory:self.selectedCategoryId]) displayGames.push_back(libraryGame);
        }
    }
    return displayGames;
}

- (void)rebuildControllerStoreFilterItems {
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *items = [NSMutableArray arrayWithObject:@{@"id": @"library", @"title": @"All Stores"}];
    BOOL hasLibraryGames = NO;
    for (const OPN::GameInfo &game : _allGames) {
        if (game.isInLibrary) {
            hasLibraryGames = YES;
            break;
        }
    }
    for (NSDictionary<NSString *, NSString *> *category in self.categoryItems) {
        NSString *categoryId = category[@"id"] ?: @"";
        if (![categoryId hasPrefix:@"store:"]) continue;
        NSInteger matchingCount = 0;
        for (const OPN::GameInfo &game : _allGames) {
            if (hasLibraryGames && !game.isInLibrary) continue;
            if ([self game:game matchesCategory:categoryId]) matchingCount++;
        }
        if (matchingCount <= 0) continue;
        NSString *title = category[@"title"] ?: @"Store";
        if ([title hasPrefix:@"Store: "]) title = [title substringFromIndex:@"Store: ".length];
        [items addObject:@{@"id": categoryId, @"title": title}];
    }
    self.controllerStoreFilterItems = items;
    NSInteger selectedIndex = 0;
    for (NSUInteger index = 0; index < items.count; index++) {
        if ([items[index][@"id"] isEqualToString:self.selectedCategoryId]) {
            selectedIndex = (NSInteger)index;
            break;
        }
    }
    self.focusedControllerStoreFilterIndex = selectedIndex;
}

- (void)showControllerStoreFilterOverlay {
    [self rebuildControllerStoreFilterItems];
    [self.controllerStoreFilterOverlayView removeFromSuperview];
    [self.controllerStoreFilterOptionLabels removeAllObjects];

    NSView *overlay = [[NSView alloc] initWithFrame:self.bounds];
    overlay.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    overlay.wantsLayer = YES;
    overlay.layer.backgroundColor = OpnColor(0x020304, 0.82).CGColor;

    NSView *panel = [[OPNFlippedGridDocumentView alloc] initWithFrame:NSZeroRect];
    panel.wantsLayer = YES;
    panel.layer.cornerRadius = 26.0;
    panel.layer.borderWidth = 1.5;
    panel.layer.borderColor = OpnColor(0xFFFFFF, 0.20).CGColor;
    panel.layer.backgroundColor = OpnColor(0x0A0C0F, 0.98).CGColor;
    panel.layer.shadowColor = OpnColor(OPNControllerAccentRGB()).CGColor;
    panel.layer.shadowOpacity = 0.32;
    panel.layer.shadowRadius = 42.0;
    panel.layer.shadowOffset = CGSizeZero;
    [overlay addSubview:panel];

    NSTextField *eyebrow = OpnLabel(@"STORE FILTER", NSZeroRect, 12.0, OpnColor(OPN::kBrandGreen), NSFontWeightBold);
    eyebrow.identifier = @"eyebrow";
    [panel addSubview:eyebrow];
    NSTextField *title = OpnLabel(@"Choose a Store", NSZeroRect, 28.0, OpnColor(kTextPrimary), NSFontWeightBold);
    title.identifier = @"title";
    [panel addSubview:title];
    NSTextField *hint = OpnLabel(@"Hold Y, use up/down, release Y to apply", NSZeroRect, 13.0, OpnColor(kTextSecondary), NSFontWeightMedium);
    hint.identifier = @"hint";
    [panel addSubview:hint];

    for (NSDictionary<NSString *, NSString *> *item in self.controllerStoreFilterItems) {
        NSTextField *option = OpnLabel(item[@"title"] ?: @"Store", NSZeroRect, 17.0, OpnColor(kTextPrimary), NSFontWeightSemibold);
        option.wantsLayer = YES;
        option.layer.cornerRadius = 14.0;
        option.layer.masksToBounds = YES;
        [panel addSubview:option];
        [self.controllerStoreFilterOptionLabels addObject:option];
    }

    self.controllerStoreFilterOverlayView = overlay;
    [self addSubview:overlay positioned:NSWindowAbove relativeTo:nil];
    [self layoutControllerStoreFilterOverlay];
    [self updateControllerStoreFilterOverlaySelection];
    OpnPlayConsoleTone(OPNConsoleToneChange);
}

- (void)hideControllerStoreFilterOverlayApplyingSelection:(BOOL)applySelection {
    if (applySelection && self.focusedControllerStoreFilterIndex >= 0 && self.focusedControllerStoreFilterIndex < (NSInteger)self.controllerStoreFilterItems.count) {
        NSString *categoryId = self.controllerStoreFilterItems[(NSUInteger)self.focusedControllerStoreFilterIndex][@"id"] ?: @"library";
        BOOL changed = ![categoryId isEqualToString:self.selectedCategoryId];
        self.selectedCategoryId = categoryId;
        self.focusedCardIndex = 0;
        self.controllerHeroIndex = 0;
        self.controllerLibraryVisibleStartIndex = 0;
        self.controllerLibraryRailOffsetX = 0.0;
        self.controllerRenderedGameCount = [self controllerInitialRenderedGameCount];
        [self resetDesktopGridRenderWindow];
        if (changed) OpnPlayConsoleTone(OPNConsoleToneSelect);
        [self renderGrid];
        [self scrollLibraryToTop];
    }
    [self.controllerStoreFilterOverlayView removeFromSuperview];
    self.controllerStoreFilterOverlayView = nil;
    [self.controllerStoreFilterOptionLabels removeAllObjects];
    self.controllerYHoldActive = NO;
}

- (void)moveControllerStoreFilterFocusBy:(NSInteger)delta {
    if (self.controllerStoreFilterItems.count == 0 || delta == 0) return;
    NSInteger next = (self.focusedControllerStoreFilterIndex + delta) % (NSInteger)self.controllerStoreFilterItems.count;
    if (next < 0) next += (NSInteger)self.controllerStoreFilterItems.count;
    if (next == self.focusedControllerStoreFilterIndex) return;
    self.focusedControllerStoreFilterIndex = next;
    [self updateControllerStoreFilterOverlaySelection];
    OpnPlayConsoleTone(OPNConsoleToneMove);
}

- (void)layoutControllerStoreFilterOverlay {
    NSView *overlay = self.controllerStoreFilterOverlayView;
    if (!overlay) return;
    overlay.frame = self.bounds;
    NSView *panel = overlay.subviews.firstObject;
    if (!panel) return;
    CGFloat width = NSWidth(self.bounds);
    CGFloat height = NSHeight(self.bounds);
    CGFloat panelWidth = MIN(420.0, MAX(320.0, width - 96.0));
    CGFloat optionHeight = 38.0;
    CGFloat panelHeight = 128.0 + self.controllerStoreFilterOptionLabels.count * (optionHeight + 8.0);
    panelHeight = MIN(MAX(220.0, panelHeight), MAX(220.0, height - 96.0));
    panel.frame = NSMakeRect(floor((width - panelWidth) / 2.0), floor((height - panelHeight) / 2.0), panelWidth, panelHeight);
    CGPathRef panelShadowPath = OpnCreateRoundedRectPath(panel.bounds, 26.0, 26.0);
    panel.layer.shadowPath = panelShadowPath;
    CGPathRelease(panelShadowPath);
    for (NSView *view in panel.subviews) {
        if (![view isKindOfClass:NSTextField.class]) continue;
        NSTextField *label = (NSTextField *)view;
        if ([label.identifier isEqualToString:@"eyebrow"]) label.frame = NSMakeRect(26.0, 24.0, panelWidth - 52.0, 18.0);
        if ([label.identifier isEqualToString:@"title"]) label.frame = NSMakeRect(24.0, 46.0, panelWidth - 48.0, 36.0);
        if ([label.identifier isEqualToString:@"hint"]) label.frame = NSMakeRect(26.0, 84.0, panelWidth - 52.0, 20.0);
    }
    CGFloat y = 116.0;
    for (NSTextField *option in self.controllerStoreFilterOptionLabels) {
        option.frame = NSMakeRect(24.0, y, panelWidth - 48.0, optionHeight);
        y += optionHeight + 8.0;
    }
}

- (void)updateControllerStoreFilterOverlaySelection {
    for (NSUInteger index = 0; index < self.controllerStoreFilterOptionLabels.count; index++) {
        NSTextField *label = self.controllerStoreFilterOptionLabels[index];
        BOOL selected = (NSInteger)index == self.focusedControllerStoreFilterIndex;
        NSDictionary<NSString *, NSString *> *item = index < self.controllerStoreFilterItems.count ? self.controllerStoreFilterItems[index] : nil;
        label.stringValue = [NSString stringWithFormat:@"  %@", item[@"title"] ?: @"Store"];
        label.textColor = selected ? OpnColor(OPNControllerAccentBlackRGB(0.88)) : OpnColor(kTextPrimary);
        label.layer.backgroundColor = (selected ? OpnColor(OPNControllerAccentSoftRGB(), 0.94) : OpnColor(0xFFFFFF, 0.075)).CGColor;
        label.layer.borderWidth = selected ? 0.0 : 1.0;
        label.layer.borderColor = OpnColor(0xFFFFFF, 0.12).CGColor;
    }
}

- (void)renderGrid {
    OPN::LogInfo(@"[CatalogView] renderGrid begin controller=%d surface=%ld category=%@ allGames=%lu renderedLimit=%ld focused=%ld", OpnControllerModeEnabled(), (long)self.controllerSurface, self.selectedCategoryId, (unsigned long)self.allGames.size(), (long)self.controllerRenderedGameCount, (long)self.focusedCardIndex);
    BOOL controllerMode = OpnControllerModeEnabled();
    if (controllerMode) {
        [self cancelCatalogImageLoads];
        for (NSView *view in [self.gridContentView.subviews copy]) { [view removeFromSuperview]; }
        [_cardViews removeAllObjects];
        [self.controllerHomeTileViews removeAllObjects];
        [self.controllerHeroViews removeAllObjects];
        if (self.controllerSurface == OPNControllerCatalogSurfaceHome) {
            [self renderControllerHomeSurface];
        } else {
            [self renderControllerLibrary];
        }
        return;
    }

    NSMutableArray<OPNGameCardView *> *reusableCards = [NSMutableArray arrayWithCapacity:self.cardViews.count];
    NSMutableDictionary<NSString *, NSMutableArray<OPNGameCardView *> *> *reusableCardsByIdentifier = [NSMutableDictionary dictionary];
    for (NSView *view in [self.gridContentView.subviews copy]) {
        if ([view isKindOfClass:OPNGameCardView.class]) {
            OPNGameCardView *card = (OPNGameCardView *)view;
            [reusableCards addObject:card];
            NSString *identifier = [self favoriteIdentifierForGame:card.game];
            if (identifier.length == 0) identifier = [NSString stringWithFormat:@"%p", (void *)card];
            NSMutableArray<OPNGameCardView *> *bucket = reusableCardsByIdentifier[identifier];
            if (!bucket) {
                bucket = [NSMutableArray array];
                reusableCardsByIdentifier[identifier] = bucket;
            }
            [bucket addObject:card];
        } else {
            [view removeFromSuperview];
        }
    }
    [_cardViews removeAllObjects];

    CGFloat pageWidth = MAX(980.0, NSWidth(self.bounds));
    CGFloat contentX = MAX(42.0, MIN(86.0, floor(pageWidth * 0.065)));
    CGFloat contentWidth = MAX(680.0, pageWidth - contentX * 2.0);
    CGFloat headerY = kDesktopLibraryTopInset;
    OPNCatalogAmbientView *ambient = [[OPNCatalogAmbientView alloc] initWithFrame:NSMakeRect(0.0, 0.0, pageWidth, MAX(NSHeight(self.bounds), 1800.0))];
    [self.gridContentView addSubview:ambient positioned:NSWindowBelow relativeTo:nil];

    NSTextField *eyebrow = OpnLabel(@"GEFORCE NOW LIBRARY", NSMakeRect(contentX, headerY, 300.0, 18.0), 12.0, OpnColor(kBrandGreen), NSFontWeightBold);
    [self.gridContentView addSubview:eyebrow];
    NSTextField *title = OpnLabel(@"Your Cloud Games, Ready to Launch", NSMakeRect(contentX, headerY + 20.0, MIN(760.0, contentWidth - 300.0), 52.0), 39.0, OpnColor(kTextPrimary), NSFontWeightBold);
    title.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.gridContentView addSubview:title];
    NSTextField *subtitle = OpnLabel(@"A fast-launch desktop library for the games already tied to your cloud account.", NSMakeRect(contentX, headerY + 74.0, MIN(780.0, contentWidth - 260.0), 24.0), 14.0, OpnColor(kTextSecondary), NSFontWeightMedium);
    subtitle.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.gridContentView addSubview:subtitle];

    CGFloat cardWidth = [OPNGameCardView cardSize].width;
    CGFloat cardHeight = [OPNGameCardView cardSize].height;
    CGFloat availableWidth = contentWidth;
    NSInteger cols = controllerMode ? 1 : MAX(1, (NSInteger)((availableWidth + kCardSpacing) / (cardWidth + kCardSpacing)));
    self.gridColumnCount = cols;
    CGFloat gridSpacing = controllerMode ? 26.0 : (cols > 1 ? floor((availableWidth - cols * cardWidth) / (cols - 1)) : kCardSpacing);
    gridSpacing = MAX(kCardSpacing, gridSpacing);
    CGFloat xStart = controllerMode ? 64.0 : contentX + (cols > 1 ? 0.0 : floor(MAX(0.0, (contentWidth - cardWidth) / 2.0)));

    std::vector<OPN::GameInfo> displayGames;
    displayGames.reserve(_allGames.size());
    for (const OPN::GameInfo &game : _allGames) {
        if (!OPNLibraryGameHasAccessibleVariants(game)) continue;
        OPN::GameInfo libraryGame = OPNGameWithLibraryAccessibleVariants(game);
        if ([self game:libraryGame matchesCategory:self.selectedCategoryId]) displayGames.push_back(libraryGame);
    }
    NSInteger totalVisibleCount = (NSInteger)displayGames.size();
    NSInteger favoriteCount = 0;
    for (const OPN::GameInfo &game : displayGames) {
        if ([self isFavoriteGame:game]) favoriteCount++;
    }
    CGFloat pillY = headerY + 16.0;
    CGFloat pillWidth = 112.0;
    CGFloat pillGap = 10.0;
    CGFloat pillX = contentX + contentWidth - pillWidth * 3.0 - pillGap * 2.0;
    [self addDesktopLibraryMetricPillWithTitle:@"Games" value:[NSString stringWithFormat:@"%ld", (long)totalVisibleCount] frame:NSMakeRect(pillX, pillY, pillWidth, 58.0)];
    [self addDesktopLibraryMetricPillWithTitle:@"Favorites" value:[NSString stringWithFormat:@"%ld", (long)favoriteCount] frame:NSMakeRect(pillX + pillWidth + pillGap, pillY, pillWidth, 58.0)];
    [self addDesktopLibraryMetricPillWithTitle:@"Stores" value:[NSString stringWithFormat:@"%ld", (long)MAX((NSInteger)1, self.categoryItems.count - 2)] frame:NSMakeRect(pillX + (pillWidth + pillGap) * 2.0, pillY, pillWidth, 58.0)];

    std::vector<OPN::GameInfo> featuredGames = [self featuredLibraryGamesWithFallback:displayGames];
    const OPN::GameInfo *heroGame = featuredGames.empty() ? nullptr : &featuredGames[(size_t)MAX(0, MIN(self.controllerHeroIndex, (NSInteger)featuredGames.size() - 1))];
    if (heroGame) {
        self.desktopFeaturedGame = *heroGame;
        self.desktopFeaturedVariantIndex = [self preferredVariantIndexForGame:self.desktopFeaturedGame];
        self.hasDesktopFeaturedGame = YES;
        heroGame = &_desktopFeaturedGame;
    } else {
        self.hasDesktopFeaturedGame = NO;
        self.desktopFeaturedVariantIndex = -1;
    }
    CGFloat heroHeight = 0.0;
    if (heroGame) {
        heroHeight = MIN(kDesktopLibraryHeroHeight, MAX(360.0, floor(contentWidth * 0.36)));
        [self addDesktopLibraryHeroForGame:*heroGame frame:NSMakeRect(contentX, headerY + kDesktopLibraryHeroTopOffset, contentWidth, heroHeight)];
    }
    CGFloat gridTop = heroGame ? headerY + kDesktopLibraryHeroTopOffset + heroHeight + kDesktopLibraryGridTopGap : headerY + 146.0;

    NSString *sectionTitle = [self activeCategoryTitle];
    NSTextField *section = OpnLabel(sectionTitle, NSMakeRect(contentX, gridTop, MIN(520.0, contentWidth - 180.0), 34.0), 25.0, OpnColor(kTextPrimary), NSFontWeightBold);
    section.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.gridContentView addSubview:section];
    NSTextField *count = OpnLabel([NSString stringWithFormat:@"%ld %@", (long)totalVisibleCount, totalVisibleCount == 1 ? @"game" : @"games"], NSMakeRect(NSMaxX(section.frame) + 12.0, gridTop + 9.0, 140.0, 18.0), 13.0, OpnColor(kTextMuted), NSFontWeightRegular);
    [self.gridContentView addSubview:count];
    CGFloat cardStartY = gridTop + 52.0;
    self.controllerDisplayGameCount = controllerMode ? (NSInteger)displayGames.size() : 0;
    NSInteger renderStartIndex = 0;
    NSInteger renderEndIndex = (NSInteger)displayGames.size();
    if (controllerMode) {
        if (self.controllerRenderedGameCount <= 0) self.controllerRenderedGameCount = [self controllerInitialRenderedGameCount];
        renderEndIndex = MIN((NSInteger)displayGames.size(), MAX([self controllerInitialRenderedGameCount], self.controllerRenderedGameCount));
        OPN::LogInfo(@"[CatalogView] controller render window category=%@ display=%lu initial=%ld renderLimit=%ld scrollWidth=%.1f", self.selectedCategoryId, (unsigned long)displayGames.size(), (long)[self controllerInitialRenderedGameCount], (long)renderEndIndex, NSWidth(self.scrollView.frame));
    } else {
        self.desktopDisplayGameCount = (NSInteger)displayGames.size();
        NSInteger totalRows = displayGames.empty() ? 0 : (NSInteger)ceil((double)displayGames.size() / MAX(1.0, (double)cols));
        CGFloat rowHeight = cardHeight + kDesktopLibraryRowSpacing;
        NSRect visibleBounds = self.scrollView.contentView.bounds;
        CGFloat visibleMinY = MAX(0.0, NSMinY(visibleBounds) - cardStartY);
        CGFloat visibleMaxY = MAX(visibleMinY, NSMaxY(visibleBounds) - cardStartY);
        NSInteger firstVisibleRow = rowHeight > 0.0 ? MAX(0, (NSInteger)floor(visibleMinY / rowHeight)) : 0;
        NSInteger lastVisibleRow = rowHeight > 0.0 ? MAX(firstVisibleRow, (NSInteger)ceil(visibleMaxY / rowHeight)) : firstVisibleRow;
        NSInteger renderStartRow = MAX(0, firstVisibleRow - kDesktopGridRenderBufferRows);
        NSInteger renderEndRow = MIN(totalRows, lastVisibleRow + kDesktopGridRenderBufferRows + 1);
        renderStartIndex = MIN((NSInteger)displayGames.size(), renderStartRow * cols);
        renderEndIndex = MIN((NSInteger)displayGames.size(), renderEndRow * cols);
        self.desktopRenderStartIndex = renderStartIndex;
        self.desktopRenderedGameCount = MAX(0, renderEndIndex - renderStartIndex);
    }

    NSInteger visibleCount = 0;
    for (NSInteger gameIndex = renderStartIndex; gameIndex < renderEndIndex; gameIndex++) {
        auto &game = displayGames[(size_t)gameIndex];
        NSInteger col = controllerMode ? visibleCount : gameIndex % cols;
        NSInteger row = controllerMode ? 0 : gameIndex / cols;
        CGFloat x = controllerMode ? xStart + visibleCount * (cardWidth + gridSpacing) : xStart + col * (cardWidth + gridSpacing);
        CGFloat y = controllerMode ? 34.0 + kControllerRailSelectorOverlap : cardStartY + row * (cardHeight + kDesktopLibraryRowSpacing);
        NSRect cardFrame = NSMakeRect(x, y, cardWidth, cardHeight);
        NSString *gameIdentifier = [self favoriteIdentifierForGame:game];
        NSMutableArray<OPNGameCardView *> *matchingCards = gameIdentifier.length > 0 ? reusableCardsByIdentifier[gameIdentifier] : nil;
        OPNGameCardView *card = matchingCards.count > 0 ? matchingCards.firstObject : nil;
        if (card) [matchingCards removeObjectAtIndex:0];
        NSTimeInterval imageRevealDelay = 0.012 * (NSTimeInterval)MIN((NSInteger)18, visibleCount);
        if (card) {
            card.imageRevealDelay = imageRevealDelay;
            card.frame = cardFrame;
            [card updateGame:game];
        } else {
            card = [[OPNGameCardView alloc] initWithFrame:cardFrame game:game];
            card.imageRevealDelay = imageRevealDelay;
        }
        GameInfo gameCopy = game;
        __weak __typeof__(self) weakSelf = self;
        __weak OPNGameCardView *weakCard = card;
        card.onPlay = ^{
            __typeof__(self) s = weakSelf;
            OPNGameCardView *c = weakCard;
            if (!s || !c) return;
            NSUInteger cardIndex = [s.cardViews indexOfObject:c];
            if (cardIndex != NSNotFound) {
                NSInteger focusedIndex = OpnControllerModeEnabled() ? (NSInteger)cardIndex : s.desktopRenderStartIndex + (NSInteger)cardIndex;
                [s focusCardAtIndex:focusedIndex scrollIntoView:NO];
            }
            if (OpnControllerModeEnabled()) {
                [s launchFocusedGame];
            } else {
                if (cardIndex != NSNotFound) {
                    if (s.onSelectGame) {
                        int variantIdx = c.selectedVariantIndex >= 0 ? c.selectedVariantIndex : [s preferredVariantIndexForGame:gameCopy];
                        s.onSelectGame(gameCopy, variantIdx);
                    }
                }
            }
        };
        if (card.superview != _gridContentView) [_gridContentView addSubview:card];
        [_cardViews addObject:card];

        visibleCount++;
    }

    for (OPNGameCardView *card in reusableCards) {
        if (![self.cardViews containsObject:card]) [card removeFromSuperview];
    }

    CGFloat totalHeight = controllerMode ? cardHeight + 104.0 : cardStartY + cardHeight + kGridPadding;
    if (!controllerMode) {
        NSInteger totalRows = displayGames.empty() ? 0 : (NSInteger)ceil((double)displayGames.size() / MAX(1.0, (double)cols));
        totalHeight = totalRows > 0 ? cardStartY + totalRows * cardHeight + MAX(0, totalRows - 1) * kDesktopLibraryRowSpacing + 88.0 : gridTop + 220.0;
    }
    CGFloat totalWidth = controllerMode
        ? xStart * 2.0 + visibleCount * cardWidth + MAX(0, visibleCount - 1) * gridSpacing
        : pageWidth;
    ambient.frame = NSMakeRect(0.0, 0.0, pageWidth, MAX(totalHeight, NSHeight(self.bounds)));
    _gridContentView.frame = NSMakeRect(0, 0,
        MAX(totalWidth, _scrollView.frame.size.width),
        MAX(totalHeight, _scrollView.frame.size.height));

    _gameCountLabel.stringValue = [NSString stringWithFormat:@"%ld %@", (long)totalVisibleCount, totalVisibleCount == 1 ? @"game" : @"games"];
    if (self.onGameCountChanged) self.onGameCountChanged(totalVisibleCount);
    _statusLabel.stringValue = totalVisibleCount == 0 ? @"No games found." : @"";
    if (self.focusedCardIndex >= totalVisibleCount) self.focusedCardIndex = totalVisibleCount - 1;
    if (self.focusedCardIndex < 0 && totalVisibleCount > 0) self.focusedCardIndex = 0;
    [self focusCardAtIndex:self.focusedCardIndex scrollIntoView:NO];
    [self updateControllerDetailContent];
    [self startControllerHeroRotationIfNeeded];
    [self layoutCatalogSubviews];
}

- (NSInteger)controllerHomeLibraryCount {
    NSInteger count = 0;
    for (const OPN::GameInfo &game : self.allGames) {
        if (game.isInLibrary) count++;
    }
    return count;
}

- (NSInteger)controllerHomeFavoriteCount {
    NSInteger count = 0;
    for (const OPN::GameInfo &game : self.allGames) {
        if ([self isFavoriteGame:game]) count++;
    }
    return count;
}

- (std::vector<OPN::GameInfo>)controllerHomeQueueGamesWithLimit:(NSInteger)limit {
    std::vector<OPN::GameInfo> games;
    if (limit <= 0) return games;
    games.reserve((size_t)MIN(limit, (NSInteger)(_allGames.size() + _featuredGames.size())));
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    auto appendGame = [&](const OPN::GameInfo &game) {
        if ((NSInteger)games.size() >= limit) return;
        if (!OPNGameIsOwned(game)) return;
        if (!OPNLibraryGameHasAccessibleVariants(game)) return;
        NSString *identifier = [self favoriteIdentifierForGame:game];
        if (identifier.length == 0) identifier = OPNCatalogString(game.title, @"");
        if (identifier.length == 0 || [seen containsObject:identifier]) return;
        [seen addObject:identifier];
        games.push_back(OPNGameWithLibraryAccessibleVariants(game));
    };

    const OPN::GameInfo *lastPlayedGame = [self currentLastPlayedGame];
    if (lastPlayedGame) appendGame(*lastPlayedGame);
    for (const OPN::GameInfo &game : _featuredGames) appendGame(game);
    for (const OPN::GameInfo &game : _allGames) {
        if (game.isInLibrary) appendGame(game);
    }
    for (const OPN::GameInfo &game : _allGames) appendGame(game);
    return games;
}

- (const OPN::GameInfo *)controllerHomeGameForIdentifier:(NSString *)identifier {
    if (identifier.length == 0) return nullptr;
    for (const OPN::GameInfo &game : _allGames) {
        NSString *candidate = [self favoriteIdentifierForGame:game];
        if (candidate.length > 0 && [candidate isEqualToString:identifier]) return &game;
    }
    for (const OPN::GameInfo &game : _featuredGames) {
        NSString *candidate = [self favoriteIdentifierForGame:game];
        if (candidate.length > 0 && [candidate isEqualToString:identifier]) return &game;
    }
    return nullptr;
}

- (void)loadControllerHomeImageForTile:(OPNControllerHomeTileView *)tile candidates:(NSArray<NSString *> *)candidates index:(NSUInteger)index expectedIdentifier:(NSString *)expectedIdentifier {
    if (!tile || index >= candidates.count || expectedIdentifier.length == 0) return;
    __weak OPNControllerHomeTileView *weakTile = tile;
    __weak __typeof__(self) weakSelf = self;
    OpnImageLoadToken *token = OPNCatalogLoadImageFromCandidates(candidates, index, ^(NSImage *image, NSString *resolvedURL, NSData *data) {
        (void)resolvedURL;
        (void)data;
        OPNControllerHomeTileView *strongTile = weakTile;
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf || !strongTile || !strongTile.superview || ![strongTile.gameIdentifier isEqualToString:expectedIdentifier]) return;
        if (image) strongTile.image = image;
    });
    [self trackCatalogImageLoadToken:token];
}

- (void)renderControllerHomeSurface {
    self.controllerSurface = OPNControllerCatalogSurfaceHome;
    self.controllerDisplayGameCount = 0;
    self.focusedCardIndex = -1;
    [self stopControllerHeroRotation];
    [self stopControllerDetailBackgroundRotation];
    self.controllerDetailView.hidden = YES;
    self.controllerDetailBackgroundView.hidden = YES;
    self.controllerGameHubView.hidden = YES;
    self.controllerPromptBarView.hidden = YES;
    [self.controllerHomeTileViews removeAllObjects];

    CGFloat width = MAX(1.0, NSWidth(self.bounds));
    CGFloat height = MAX(1.0, NSHeight(self.bounds));
    OPNControllerLibraryMetrics metrics = OPNControllerLibraryMetricsForSize(width, height);
    CGFloat contentInset = metrics.contentInset;
    CGFloat contentWidth = MAX(1.0, width - contentInset * 2.0);
    CGFloat scale = metrics.scale;
    NSInteger libraryCount = [self controllerHomeLibraryCount];
    NSInteger favoriteCount = [self controllerHomeFavoriteCount];

    std::vector<OPN::GameInfo> queueGames = [self controllerHomeQueueGamesWithLimit:4];
    const OPN::GameInfo *lastPlayedGame = [self currentLastPlayedGame];
    const OPN::GameInfo *heroGame = lastPlayedGame ? lastPlayedGame : (queueGames.empty() ? nullptr : &queueGames.front());

    CGFloat gap = MAX(18.0, 24.0 * scale);
    CGFloat heroY = 39.0 * scale;
    CGFloat heroWidth = floor(contentWidth * 0.50);
    CGFloat sideWidth = contentWidth - heroWidth - gap;
    CGFloat heroHeight = MIN(MAX(258.0, height * 0.405), 338.0);
    CGFloat commandHeight = floor((heroHeight - gap) / 2.0);
    CGFloat commandWidth = floor((sideWidth - gap) / 2.0);

    __weak __typeof__(self) weakSelf = self;
    OPNControllerHomeTileView *(^addTile)(OPNControllerHomeTileStyle, NSRect, NSString *, NSString *, NSString *, NSString *, NSString *, NSString *, const OPN::GameInfo *) = ^OPNControllerHomeTileView *(OPNControllerHomeTileStyle style, NSRect frame, NSString *action, NSString *glyph, NSString *tileEyebrow, NSString *tileTitle, NSString *tileSubtitle, NSString *tileDetail, const OPN::GameInfo *game) {
        OPNControllerHomeTileView *tile = [[OPNControllerHomeTileView alloc] initWithFrame:frame style:style];
        tile.actionIdentifier = action ?: @"";
        tile.glyph = glyph ?: @"";
        tile.eyebrow = tileEyebrow ?: @"";
        tile.title = tileTitle ?: @"";
        tile.subtitle = tileSubtitle ?: @"";
        tile.detail = tileDetail ?: @"";
        if (game) {
            NSString *identifier = [self favoriteIdentifierForGame:*game];
            tile.gameIdentifier = identifier.length > 0 ? identifier : OPNCatalogString(game->title, @"");
            NSArray<NSString *> *candidates = style == OPNControllerHomeTileStyleHero ? OPNControllerHeroBackgroundCandidates(*game) : OPNControllerCategoryArtworkCandidates(*game);
            NSString *expectedIdentifier = tile.gameIdentifier;
            [self loadControllerHomeImageForTile:tile candidates:candidates index:0 expectedIdentifier:expectedIdentifier];
        }
        __weak OPNControllerHomeTileView *weakTile = tile;
        tile.onSelect = ^{
            __typeof__(self) strongSelf = weakSelf;
            OPNControllerHomeTileView *strongTile = weakTile;
            if (!strongSelf || !strongTile) return;
            NSUInteger index = [strongSelf.controllerHomeTileViews indexOfObject:strongTile];
            if (index != NSNotFound) [strongSelf focusControllerHomeItemAtIndex:(NSInteger)index scrollIntoView:NO];
            [strongSelf activateFocusedControllerHomeItem];
        };
        [self.gridContentView addSubview:tile];
        [self.controllerHomeTileViews addObject:tile];
        return tile;
    };

    NSString *heroTitle = heroGame ? OPNCatalogString(heroGame->title, @"Resume Session") : @"Build your launch queue";
    NSString *heroSubtitle = @"Open the lean-back library built for controller navigation.";
    if (heroGame) {
        NSString *genres = OPNCatalogJoinedStrings(heroGame->genres, @"");
        NSString *store = heroGame->availableStores.empty() ? @"Cloud ready" : OPNStoreCategoryTitle(OPNCatalogString(heroGame->availableStores.front(), @""));
        heroSubtitle = genres.length > 0 ? [NSString stringWithFormat:@"%@ / %@", store, genres] : store;
    }
    addTile(OPNControllerHomeTileStyleHero,
            NSMakeRect(contentInset, heroY, heroWidth, heroHeight),
            @"resume",
            @"P",
            heroGame ? @"NOW" : @"START",
            heroTitle,
            heroSubtitle,
            heroGame ? @"PLAY" : @"LIBRARY",
            heroGame);

    CGFloat sideX = contentInset + heroWidth + gap;
    addTile(OPNControllerHomeTileStyleCommand,
            NSMakeRect(sideX, heroY, commandWidth, commandHeight),
            @"library",
            @"L",
            @"COLLECTION",
            @"Library",
            [NSString stringWithFormat:@"%ld ready to browse", (long)libraryCount],
            @"OPEN",
            nullptr);
    addTile(OPNControllerHomeTileStyleCommand,
            NSMakeRect(sideX + commandWidth + gap, heroY, commandWidth, commandHeight),
            @"favorites",
            @"F",
            @"PINNED",
            @"Favorites",
            favoriteCount > 0 ? [NSString stringWithFormat:@"%ld saved shortcuts", (long)favoriteCount] : @"No favorites yet",
            @"FILTER",
            nullptr);
    addTile(OPNControllerHomeTileStyleCommand,
            NSMakeRect(sideX, heroY + commandHeight + gap, commandWidth, commandHeight),
            @"store",
            @"S",
            @"DISCOVER",
            @"Store",
            @"Find supported cloud games",
            @"VISIT",
            nullptr);
    addTile(OPNControllerHomeTileStyleCommand,
            NSMakeRect(sideX + commandWidth + gap, heroY + commandHeight + gap, commandWidth, commandHeight),
            @"settings",
            @"*",
            @"SYSTEM",
            @"Settings",
            @"Controller, stream, account",
            @"TUNE",
            nullptr);

    CGFloat queueY = heroY + heroHeight + gap;
    CGFloat queueHeight = MIN(216.0, MAX(190.0, height * 0.28));
    CGFloat queueTitleY = queueY + 4.0;
    NSTextField *queueTitle = OpnLabel(@"Launch Queue", NSMakeRect(contentInset, queueTitleY, 240.0, 24.0), 18.0, OpnColor(OPN::kTextPrimary), NSFontWeightBlack);
    [self.gridContentView addSubview:queueTitle];
    NSTextField *queueHint = OpnLabel(@"Featured and recent games without leaving Home", NSMakeRect(contentInset + 150.0, queueTitleY + 4.0, 420.0, 18.0), 12.0, OpnColor(OPN::kTextMuted), NSFontWeightSemibold);
    [self.gridContentView addSubview:queueHint];

    CGFloat gameTileY = queueY + 36.0;
    CGFloat gameGap = gap * 0.72;
    CGFloat gameTileWidth = floor((contentWidth - gameGap * 3.0) / 4.0);
    for (NSInteger index = 0; index < 4; index++) {
        const OPN::GameInfo *game = index < (NSInteger)queueGames.size() ? &queueGames[(size_t)index] : nullptr;
        NSString *gameTitle = game ? OPNCatalogString(game->title, @"Cloud Game") : (index == 0 ? @"Library" : @"Empty Slot");
        NSString *gameSubtitle = game ? OPNCatalogJoinedStrings(game->genres, @"Ready to stream") : @"Add more games to fill this lane";
        addTile(OPNControllerHomeTileStyleGame,
                NSMakeRect(contentInset + index * (gameTileWidth + gameGap), gameTileY, gameTileWidth, queueHeight - 34.0),
                game ? @"game" : @"library",
                game ? @"" : @"+",
                game ? @"QUEUE" : @"OPEN",
                gameTitle,
                gameSubtitle,
                game ? @"PLAY" : @"LIBRARY",
                game);
    }

    CGFloat contentHeight = MAX(NSHeight(self.scrollView.frame), gameTileY + queueHeight + 18.0);
    self.gridContentView.frame = NSMakeRect(0.0, 0.0, width, contentHeight);
    if (self.focusedHomeItemIndex < 0) self.focusedHomeItemIndex = 0;
    if (self.focusedHomeItemIndex >= (NSInteger)self.controllerHomeTileViews.count) self.focusedHomeItemIndex = (NSInteger)self.controllerHomeTileViews.count - 1;
    [self focusControllerHomeItemAtIndex:self.focusedHomeItemIndex scrollIntoView:NO];
    self.gameCountLabel.stringValue = [NSString stringWithFormat:@"%ld %@", (long)libraryCount, libraryCount == 1 ? @"game" : @"games"];
    if (self.onGameCountChanged) self.onGameCountChanged(libraryCount);
    self.statusLabel.stringValue = self.controllerHomeTileViews.count == 0 ? @"Controller Home is empty." : @"";
    [self layoutCatalogSubviews];
}

- (void)focusControllerHomeItemAtIndex:(NSInteger)index scrollIntoView:(BOOL)scrollIntoView {
    NSInteger itemCount = (NSInteger)self.controllerHomeTileViews.count;
    if (itemCount == 0) {
        self.focusedHomeItemIndex = -1;
        return;
    }
    NSInteger previousIndex = self.focusedHomeItemIndex;
    NSInteger clamped = MAX(0, MIN(index, itemCount - 1));
    self.focusedHomeItemIndex = clamped;
    for (NSUInteger i = 0; i < self.controllerHomeTileViews.count; i++) {
        self.controllerHomeTileViews[i].controllerFocused = (NSInteger)i == clamped;
    }
    if (OpnControllerModeEnabled() && scrollIntoView && previousIndex >= 0 && previousIndex != clamped) {
        OpnPlayConsoleTone(OPNConsoleToneMove);
    }
    if (!scrollIntoView) return;
    OPNControllerHomeTileView *tile = self.controllerHomeTileViews[(NSUInteger)clamped];
    [self.gridContentView scrollRectToVisible:NSInsetRect(tile.frame, -24.0, -24.0)];
    [self.scrollView reflectScrolledClipView:self.scrollView.contentView];
}

- (void)moveControllerHomeFocusByRows:(NSInteger)rows columns:(NSInteger)columns {
    NSInteger itemCount = (NSInteger)self.controllerHomeTileViews.count;
    if (itemCount == 0 || (rows == 0 && columns == 0)) return;
    NSInteger currentIndex = MAX(0, MIN(self.focusedHomeItemIndex, itemCount - 1));
    NSView *currentView = self.controllerHomeTileViews[(NSUInteger)currentIndex];
    NSRect currentFrame = currentView.frame;
    CGFloat currentX = NSMidX(currentView.frame);
    CGFloat currentY = NSMidY(currentView.frame);
    CGFloat bestScore = CGFLOAT_MAX;
    NSInteger bestIndex = NSNotFound;
    BOOL hasAxisAlignedCandidate = NO;
    for (NSInteger index = 0; index < itemCount; index++) {
        if (index == currentIndex) continue;
        NSView *candidateView = self.controllerHomeTileViews[(NSUInteger)index];
        NSRect candidateFrame = candidateView.frame;
        CGFloat dx = NSMidX(candidateFrame) - currentX;
        CGFloat dy = NSMidY(candidateFrame) - currentY;
        BOOL verticalOverlap = NSMinY(candidateFrame) < NSMaxY(currentFrame) && NSMaxY(candidateFrame) > NSMinY(currentFrame);
        BOOL horizontalOverlap = NSMinX(candidateFrame) < NSMaxX(currentFrame) && NSMaxX(candidateFrame) > NSMinX(currentFrame);
        if (columns > 0 && dx > 1.0 && verticalOverlap) hasAxisAlignedCandidate = YES;
        if (columns < 0 && dx < -1.0 && verticalOverlap) hasAxisAlignedCandidate = YES;
        if (rows > 0 && dy > 1.0 && horizontalOverlap) hasAxisAlignedCandidate = YES;
        if (rows < 0 && dy < -1.0 && horizontalOverlap) hasAxisAlignedCandidate = YES;
    }
    for (NSInteger index = 0; index < itemCount; index++) {
        if (index == currentIndex) continue;
        NSView *candidateView = self.controllerHomeTileViews[(NSUInteger)index];
        NSRect candidateFrame = candidateView.frame;
        CGFloat dx = NSMidX(candidateView.frame) - currentX;
        CGFloat dy = NSMidY(candidateView.frame) - currentY;
        CGFloat score = CGFLOAT_MAX;
        BOOL axisAligned = YES;
        if (columns != 0) {
            axisAligned = NSMinY(candidateFrame) < NSMaxY(currentFrame) && NSMaxY(candidateFrame) > NSMinY(currentFrame);
        } else if (rows != 0) {
            axisAligned = NSMinX(candidateFrame) < NSMaxX(currentFrame) && NSMaxX(candidateFrame) > NSMinX(currentFrame);
        }
        if (hasAxisAlignedCandidate && !axisAligned) continue;
        if (rows > 0 && dy > 1.0) {
            score = fabs(dx) * 2.4 + dy;
        } else if (rows < 0 && dy < -1.0) {
            score = fabs(dx) * 2.4 + fabs(dy);
        } else if (columns > 0 && dx > 1.0) {
            score = fabs(dy) * 2.4 + dx;
        } else if (columns < 0 && dx < -1.0) {
            score = fabs(dy) * 2.4 + fabs(dx);
        }
        if (score < bestScore) {
            bestScore = score;
            bestIndex = index;
        }
    }
    if (bestIndex != NSNotFound) [self focusControllerHomeItemAtIndex:bestIndex scrollIntoView:YES];
}

- (void)activateFocusedControllerHomeItem {
    if (self.focusedHomeItemIndex < 0 || self.focusedHomeItemIndex >= (NSInteger)self.controllerHomeTileViews.count) return;
    OPNControllerHomeTileView *tile = self.controllerHomeTileViews[(NSUInteger)self.focusedHomeItemIndex];
    NSString *action = tile.actionIdentifier ?: @"";
    if (OpnControllerModeEnabled()) OpnPlayConsoleTone(OPNConsoleToneSelect);
    if ([action isEqualToString:@"resume"]) {
        const OPN::GameInfo *lastPlayedGame = [self currentLastPlayedGame];
        if (lastPlayedGame) {
            [self launchLastPlayedGame];
            return;
        }
        [self showControllerLibrary];
        return;
    }
    if ([action isEqualToString:@"game"]) {
        const OPN::GameInfo *game = [self controllerHomeGameForIdentifier:tile.gameIdentifier];
        if (game && self.onSelectGame) {
            OPN::GameInfo libraryGame = OPNGameWithLibraryAccessibleVariants(*game);
            self.onSelectGame(libraryGame, [self preferredVariantIndexForGame:libraryGame]);
        }
        return;
    }
    if ([action isEqualToString:@"favorites"]) {
        self.selectedCategoryId = @"favorites";
        [self showControllerLibrary];
        return;
    }
    if ([action isEqualToString:@"library"]) {
        self.selectedCategoryId = @"library";
        [self showControllerLibrary];
        return;
    }
    if ([action isEqualToString:@"store"]) {
        if (self.onStoreRequested) self.onStoreRequested();
        return;
    }
    if ([action isEqualToString:@"settings"]) {
        if (self.onInterfaceSettingsRequested) self.onInterfaceSettingsRequested();
        return;
    }
}

- (void)renderControllerLibrary {
    self.controllerSurface = OPNControllerCatalogSurfaceLibrary;
    [self.controllerHomeTileViews removeAllObjects];

    CGFloat width = MAX(1.0, NSWidth(self.bounds));
    CGFloat contentInset = 52.0;
    NSClipView *clipView = self.scrollView.contentView;
    if (clipView.bounds.origin.x != 0.0) {
        [clipView scrollToPoint:NSMakePoint(0.0, 0.0)];
        [self.scrollView reflectScrolledClipView:clipView];
    }
    CGFloat height = MAX(1.0, NSHeight(self.bounds));
    OPNControllerLibraryMetrics metrics = OPNControllerLibraryMetricsForSize(width, height);
    contentInset = metrics.contentInset;

    std::vector<OPN::GameInfo> displayGames = [self controllerLibraryDisplayGames];
    self.controllerDisplayGameCount = (NSInteger)displayGames.size();
    if (self.focusedCardIndex < 0 && !displayGames.empty()) self.focusedCardIndex = 0;
    if (self.focusedCardIndex >= (NSInteger)displayGames.size()) self.focusedCardIndex = (NSInteger)displayGames.size() - 1;

    [self renderControllerHero];

    NSString *sectionTitle = [self activeCategoryTitle];
    CGFloat maximumTitleWidth = MAX(metrics.rowTitleWidth, width - contentInset * 2.0 - metrics.countWidth - metrics.cardSpacing);
    NSTextField *title = OpnLabel(sectionTitle, NSMakeRect(contentInset, metrics.rowTitleY, metrics.rowTitleWidth, metrics.rowTitleHeight), metrics.rowTitleFontSize, OpnColor(OPN::kTextPrimary), NSFontWeightBold);
    title.lineBreakMode = NSLineBreakByTruncatingTail;
    CGFloat titleWidth = MIN(maximumTitleWidth, MAX(metrics.rowTitleWidth, ceil(title.intrinsicContentSize.width) + 8.0));
    title.frame = NSMakeRect(contentInset, metrics.rowTitleY, titleWidth, metrics.rowTitleHeight);
    [self.gridContentView addSubview:title];
    NSString *countText = [NSString stringWithFormat:@"%ld %@", (long)displayGames.size(), displayGames.size() == 1 ? @"game" : @"games"];
    NSTextField *count = OpnLabel(countText, NSMakeRect(NSMaxX(title.frame) + metrics.cardSpacing * 0.6, metrics.countY, metrics.countWidth, metrics.countHeight), metrics.countFontSize, OpnColor(OPN::kTextMuted), NSFontWeightRegular);
    [self.gridContentView addSubview:count];

    self.gameCountLabel.stringValue = countText;
    if (self.onGameCountChanged) self.onGameCountChanged((NSInteger)displayGames.size());
    self.statusLabel.stringValue = displayGames.empty() ? @"No games found." : @"";
    [self renderControllerLibraryRail];
    [self focusCardAtIndex:self.focusedCardIndex scrollIntoView:NO];
    [self scrollControllerLibraryRailToCardAtIndex:self.focusedCardIndex animated:NO];
    [self startControllerHeroRotationIfNeeded];
    [self layoutCatalogSubviews];
}

- (void)renderControllerHero {
    [self renderControllerHeroAnimated:NO];
}

- (void)renderControllerHeroAnimated:(BOOL)animated {
    (void)animated;
    NSArray<NSView *> *outgoingViews = [self.controllerHeroViews copy];
    for (NSView *view in outgoingViews) {
        [view removeFromSuperview];
    }
    [self.controllerHeroViews removeAllObjects];

    CGFloat width = MAX(1.0, NSWidth(self.bounds));
    CGFloat height = MAX(1.0, NSHeight(self.bounds));
    OPNControllerLibraryMetrics metrics = OPNControllerLibraryMetricsForSize(width, height);
    CGFloat contentInset = metrics.contentInset;

    std::vector<OPN::GameInfo> featuredGames = [self controllerFeaturedGamesFromDisplayGames:_featuredGames];
    if (featuredGames.empty()) {
        [self stopControllerHeroRotation];
        return;
    }
    if (self.controllerHeroIndex >= (NSInteger)featuredGames.size()) self.controllerHeroIndex = 0;
    NSInteger heroIndex = MAX(0, MIN(self.controllerHeroIndex, (NSInteger)featuredGames.size() - 1));
    CGFloat availableHeroWidth = width - contentInset * 2.0;
    CGFloat heroWidth = MIN(availableHeroWidth, metrics.heroHeight / kControllerHeroMarqueeRatio);
    NSRect heroFrame = NSMakeRect(contentInset + (availableHeroWidth - heroWidth) * 0.5, metrics.heroY, heroWidth, metrics.heroHeight);
    [self addControllerHeroForGame:featuredGames[(size_t)heroIndex]
                             frame:heroFrame
                      activeIndex:heroIndex
                      totalCount:(NSInteger)featuredGames.size()];
}

- (void)renderControllerLibraryRail {
    if (!OpnControllerModeEnabled()) return;

    CGFloat width = MAX(1.0, NSWidth(self.bounds));
    CGFloat height = MAX(1.0, NSHeight(self.bounds));
    OPNControllerLibraryMetrics metrics = OPNControllerLibraryMetricsForSize(width, height);
    CGFloat contentInset = metrics.contentInset;
    CGFloat cardWidth = metrics.cardSize;
    CGFloat cardHeight = metrics.cardSize;

    std::vector<OPN::GameInfo> displayGames = [self controllerLibraryDisplayGames];
    NSInteger totalGames = (NSInteger)displayGames.size();
    self.controllerDisplayGameCount = totalGames;
    if (self.focusedCardIndex < 0 && totalGames > 0) self.focusedCardIndex = 0;
    if (self.focusedCardIndex >= totalGames) self.focusedCardIndex = totalGames - 1;

    NSInteger visibleStart = 0;
    if (totalGames > metrics.visibleCardCount) {
        visibleStart = MAX(0, MIN(self.controllerLibraryVisibleStartIndex, totalGames - metrics.visibleCardCount));
        if (self.focusedCardIndex < visibleStart) {
            visibleStart = self.focusedCardIndex;
        } else if (self.focusedCardIndex >= visibleStart + metrics.visibleCardCount) {
            visibleStart = self.focusedCardIndex - metrics.visibleCardCount + 1;
        }
        visibleStart = MAX(0, MIN(visibleStart, totalGames - metrics.visibleCardCount));
    }
    self.controllerLibraryVisibleStartIndex = visibleStart;
    NSInteger renderStart = MAX(0, visibleStart - 1);
    NSInteger renderEnd = MIN(totalGames, visibleStart + metrics.visibleCardCount + 1);
    self.controllerLibraryWindowStartIndex = renderStart;
    self.controllerRenderedGameCount = MAX(0, renderEnd - renderStart);

    NSView *railView = self.controllerLibraryRailView;
    if (!railView) {
        railView = [[OPNFlippedGridDocumentView alloc] initWithFrame:NSMakeRect(0.0, 0.0, width, metrics.contentHeight)];
        railView.wantsLayer = YES;
        railView.layer.backgroundColor = NSColor.clearColor.CGColor;
        self.controllerLibraryRailView = railView;
    } else {
        for (NSView *subview in [railView.subviews copy]) [subview removeFromSuperview];
    }
    [self.cardViews removeAllObjects];
    if (railView.superview != self.gridContentView) [self.gridContentView addSubview:railView];

    for (NSInteger index = renderStart; index < renderEnd; index++) {
        const OPN::GameInfo &game = displayGames[(size_t)index];
        CGFloat x = contentInset + index * (cardWidth + metrics.cardSpacing);
        OPNGameCardView *card = [[OPNGameCardView alloc] initWithFrame:NSMakeRect(x, metrics.cardY, cardWidth, cardHeight) game:game];
        card.imageRevealDelay = 0.018 * (NSTimeInterval)MIN((NSInteger)10, index - renderStart);
        card.controllerFocused = index == self.focusedCardIndex;
        GameInfo gameCopy = game;
        __weak __typeof__(self) weakSelf = self;
        __weak OPNGameCardView *weakCard = card;
        card.onPlay = ^{
            __typeof__(self) strongSelf = weakSelf;
            OPNGameCardView *strongCard = weakCard;
            if (!strongSelf || !strongCard) return;
            NSUInteger cardIndex = [strongSelf.cardViews indexOfObject:strongCard];
            if (cardIndex != NSNotFound) [strongSelf focusCardAtIndex:strongSelf.controllerLibraryWindowStartIndex + (NSInteger)cardIndex scrollIntoView:NO];
            if (strongSelf.onSelectGame) strongSelf.onSelectGame(gameCopy, strongCard.selectedVariantIndex >= 0 ? strongCard.selectedVariantIndex : 0);
        };
        [railView addSubview:card];
        [self.cardViews addObject:card];
    }

    CGFloat contentWidth = totalGames == 0 ? width : contentInset * 2.0 + totalGames * cardWidth + MAX(0, totalGames - 1) * metrics.cardSpacing;
    self.controllerLibraryRailContentWidth = MAX(width, contentWidth);
    railView.frame = NSMakeRect(-self.controllerLibraryRailOffsetX, 0.0, self.controllerLibraryRailContentWidth, metrics.contentHeight);
    self.gridContentView.frame = NSMakeRect(0.0, 0.0, width, MAX(metrics.contentHeight, NSHeight(self.scrollView.frame)));
}

- (void)scrollControllerLibraryRailToCardAtIndex:(NSInteger)index animated:(BOOL)animated {
    if (!OpnControllerModeEnabled() || self.controllerSurface != OPNControllerCatalogSurfaceLibrary || !self.controllerLibraryRailView || self.cardViews.count == 0) return;
    NSInteger clamped = MAX(0, MIN(index, self.controllerDisplayGameCount - 1));
    NSInteger localIndex = clamped - self.controllerLibraryWindowStartIndex;
    if (localIndex < 0 || localIndex >= (NSInteger)self.cardViews.count) return;
    CGFloat visibleWidth = NSWidth(self.scrollView.contentView.bounds);
    if (visibleWidth <= 1.0) visibleWidth = NSWidth(self.scrollView.frame);
    OPNControllerLibraryMetrics metrics = OPNControllerLibraryMetricsForSize(MAX(1.0, NSWidth(self.bounds)), MAX(1.0, NSHeight(self.bounds)));
    CGFloat targetX = self.controllerLibraryVisibleStartIndex * (metrics.cardSize + metrics.cardSpacing);
    CGFloat maxX = MAX(0.0, self.controllerLibraryRailContentWidth - visibleWidth);
    targetX = MAX(0.0, MIN(targetX, maxX));
    self.controllerLibraryRailOffsetX = targetX;
    NSRect railFrame = self.controllerLibraryRailView.frame;
    railFrame.origin.x = -targetX;
    railFrame.size.width = self.controllerLibraryRailContentWidth;
    if (animated) {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.24;
            context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
            self.controllerLibraryRailView.animator.frame = railFrame;
        } completionHandler:nil];
    } else {
        self.controllerLibraryRailView.frame = railFrame;
    }
}

- (std::vector<OPN::GameInfo>)featuredLibraryGamesWithFallback:(const std::vector<OPN::GameInfo> &)fallbackGames {
    std::vector<OPN::GameInfo> games;
    games.reserve(_featuredGames.empty() ? fallbackGames.size() : _featuredGames.size());

    auto appendFeatured = [&](const OPN::GameInfo &sourceGame) {
        if (!OPNLibraryGameHasAccessibleVariants(sourceGame)) return;
        OPN::GameInfo libraryGame = OPNGameWithLibraryAccessibleVariants(sourceGame);
        for (const OPN::GameInfo &existing : games) {
            if (OPNGameIdentityMatches(existing, libraryGame)) return;
        }
        games.push_back(libraryGame);
    };

    for (const OPN::GameInfo &game : _featuredGames) appendFeatured(game);
    if (games.empty()) {
        for (const OPN::GameInfo &game : fallbackGames) appendFeatured(game);
    }
    return games;
}

- (std::vector<OPN::GameInfo>)controllerFeaturedGamesFromDisplayGames:(const std::vector<OPN::GameInfo> &)displayGames {
    std::vector<OPN::GameInfo> featuredGames;
    for (const OPN::GameInfo &game : displayGames) {
        if (featuredGames.size() >= static_cast<size_t>(6)) break;
        if (!OPNLibraryGameHasAccessibleVariants(game)) continue;
        featuredGames.push_back(OPNGameWithLibraryAccessibleVariants(game));
    }
    return featuredGames;
}

- (const OPN::GameInfo *)currentControllerHeroGame {
    std::vector<OPN::GameInfo> featuredGames = [self controllerFeaturedGamesFromDisplayGames:_featuredGames];
    if (featuredGames.empty()) return nullptr;
    NSInteger heroIndex = MAX(0, MIN(self.controllerHeroIndex, (NSInteger)featuredGames.size() - 1));
    NSInteger visibleIndex = 0;
    for (const OPN::GameInfo &game : _featuredGames) {
        if (!OPNLibraryGameHasAccessibleVariants(game)) continue;
        if (visibleIndex == heroIndex) return &game;
        visibleIndex++;
    }
    return nullptr;
}

- (OPNControllerHeroPrimaryAction)primaryActionForHeroGame:(const OPN::GameInfo &)game {
    if (OPNGameHasActiveSession(game, _activeSessionAppIds)) return OPNControllerHeroPrimaryActionResume;
    if (OPNGameIsOwned(game)) return OPNControllerHeroPrimaryActionPlay;
    return OPNControllerHeroPrimaryActionBuy;
}

- (void)addControllerHeroForGame:(const OPN::GameInfo &)game frame:(NSRect)frame activeIndex:(NSInteger)activeIndex totalCount:(NSInteger)totalCount {
    OPNControllerPreviewBackgroundView *hero = [[OPNControllerPreviewBackgroundView alloc] initWithFrame:frame];
    CGFloat heroHeight = MAX(1.0, NSHeight(frame));
    CGFloat heroScale = MIN(heroHeight / 270.0, 2.0);
    CGFloat cornerRadius = heroHeight * (18.0 / 270.0);
    CGFloat leftInset = 68.0 * heroScale;
    CGFloat logoWidth = 340.0 * heroScale;
    CGFloat logoHeight = 84.0 * heroScale;
    CGFloat actionScale = heroScale * 0.68;
    CGFloat resumeButtonWidth = 136.0 * actionScale;
    CGFloat secondaryButtonWidth = 136.0 * actionScale;
    CGFloat moreButtonWidth = 50.0 * actionScale;
    CGFloat buttonHeight = 42.0 * actionScale;
    CGFloat buttonGap = 14.0 * actionScale;
    CGFloat actionFontSize = 14.5 * actionScale;

    NSView *heroShadow = [[NSView alloc] initWithFrame:frame];
    heroShadow.wantsLayer = YES;
    heroShadow.layer.cornerRadius = cornerRadius;
    heroShadow.layer.masksToBounds = NO;
    heroShadow.layer.backgroundColor = NSColor.clearColor.CGColor;
    heroShadow.layer.shadowColor = NSColor.blackColor.CGColor;
    heroShadow.layer.shadowOpacity = 0.58;
    heroShadow.layer.shadowRadius = heroHeight * (30.0 / 270.0);
    heroShadow.layer.shadowOffset = CGSizeMake(0.0, heroHeight * (16.0 / 270.0));
    CGPathRef heroShadowPath = OpnCreateRoundedRectPath(heroShadow.bounds, cornerRadius, cornerRadius);
    heroShadow.layer.shadowPath = heroShadowPath;
    CGPathRelease(heroShadowPath);
    [self.gridContentView addSubview:heroShadow];
    [self.controllerHeroViews addObject:heroShadow];

    hero.cornerRadius = cornerRadius;
    hero.rightAlignImageToHeight = NO;
    hero.wantsLayer = YES;
    hero.layer.cornerRadius = cornerRadius;
    hero.layer.masksToBounds = YES;
    hero.layer.borderWidth = heroHeight * (1.0 / 270.0);
    hero.layer.borderColor = OpnColor(0xFFFFFF, 0.14).CGColor;
    [self.gridContentView addSubview:hero];
    [self.controllerHeroViews addObject:hero];
    [self loadControllerHeroImageForView:hero candidates:OPNControllerHeroBackgroundCandidates(game) index:0];

    NSImageView *logoView = [[NSImageView alloc] initWithFrame:NSMakeRect(NSMinX(frame) + leftInset, NSMinY(frame) + heroHeight * (74.0 / 270.0), logoWidth, logoHeight)];
    logoView.imageScaling = NSImageScaleProportionallyUpOrDown;
    logoView.imageAlignment = NSImageAlignLeft;
    logoView.wantsLayer = YES;
    logoView.layer.opacity = 0.0;
    logoView.layer.shadowColor = NSColor.blackColor.CGColor;
    logoView.layer.shadowOpacity = 0.55;
    logoView.layer.shadowRadius = heroHeight * (10.0 / 270.0);
    logoView.layer.shadowOffset = CGSizeMake(0.0, heroHeight * (4.0 / 270.0));
    [self.gridContentView addSubview:logoView];
    [self.controllerHeroViews addObject:logoView];
    [self loadControllerHeroLogoForView:logoView candidates:OPNControllerHeroLogoCandidates(game) index:0];

    OPNControllerHeroPrimaryAction primaryAction = [self primaryActionForHeroGame:game];
    NSString *primaryTitle = primaryAction == OPNControllerHeroPrimaryActionResume ? @"▶  Resume" : (primaryAction == OPNControllerHeroPrimaryActionPlay ? @"▶  Play" : @"Buy");
    NSButton *primary = OpnButton(primaryTitle, NSMakeRect(NSMinX(frame) + leftInset, NSMinY(frame) + heroHeight * (198.0 / 270.0), resumeButtonWidth, buttonHeight), OpnColor(0x45F27C, 0.98), OpnColor(0x051008));
    primary.font = [NSFont systemFontOfSize:actionFontSize weight:NSFontWeightBold];
    primary.layer.cornerRadius = buttonHeight * 0.24;
    primary.layer.shadowColor = OpnColor(0x45F27C).CGColor;
    primary.layer.shadowOpacity = 0.42;
    primary.layer.shadowRadius = buttonHeight * 0.38;
    primary.layer.shadowOffset = CGSizeZero;
    primary.target = self;
    primary.action = @selector(controllerHeroResumeClicked:);
    [self.gridContentView addSubview:primary];
    [self.controllerHeroViews addObject:primary];

    NSButton *more = OpnButton(@"ⓘ  More Info", NSMakeRect(NSMaxX(primary.frame) + buttonGap, NSMinY(primary.frame), secondaryButtonWidth, buttonHeight), OpnColor(0x14181C, 0.92), OpnColor(0xFFFFFF, 0.92), true, OpnColor(0xFFFFFF, 0.08));
    more.font = [NSFont systemFontOfSize:actionFontSize weight:NSFontWeightMedium];
    more.layer.cornerRadius = primary.layer.cornerRadius;
    more.target = self;
    more.action = @selector(controllerHeroMoreInfoClicked:);
    [self.gridContentView addSubview:more];
    [self.controllerHeroViews addObject:more];

    NSButton *ellipsis = OpnButton(@"•••", NSMakeRect(NSMaxX(more.frame) + buttonGap, NSMinY(primary.frame), moreButtonWidth, buttonHeight), OpnColor(0x14181C, 0.92), OpnColor(0xFFFFFF, 0.92), true, OpnColor(0xFFFFFF, 0.08));
    ellipsis.font = [NSFont systemFontOfSize:actionFontSize weight:NSFontWeightBold];
    ellipsis.layer.cornerRadius = primary.layer.cornerRadius;
    ellipsis.target = self;
    ellipsis.action = @selector(controllerHeroMoreInfoClicked:);
    [self.gridContentView addSubview:ellipsis];
    [self.controllerHeroViews addObject:ellipsis];

    CGFloat dotSpacing = 24.0 * heroScale;
    CGFloat activeDotWidth = 22.0 * heroScale;
    CGFloat inactiveDotWidth = 14.0 * heroScale;
    CGFloat dotHeight = 5.0 * heroScale;
    CGFloat dotWidth = totalCount > 0 ? (totalCount - 1) * dotSpacing + activeDotWidth : 0.0;
    CGFloat dotX = NSMidX(frame) - dotWidth * 0.5;
    CGFloat dotY = NSMaxY(frame) + heroHeight * (14.0 / 270.0);
    for (NSInteger index = 0; index < totalCount; index++) {
        BOOL active = index == activeIndex;
        NSRect dotRect = active ? NSMakeRect(dotX + index * dotSpacing, dotY, activeDotWidth, dotHeight) : NSMakeRect(dotX + index * dotSpacing + (activeDotWidth - inactiveDotWidth) * 0.5, dotY, inactiveDotWidth, dotHeight);
        NSView *dot = [[NSView alloc] initWithFrame:dotRect];
        dot.wantsLayer = YES;
        dot.layer.cornerRadius = dotHeight * 0.5;
        dot.layer.backgroundColor = (active ? OpnColor(OPN::kBrandGreen, 0.95) : OpnColor(0xFFFFFF, 0.18)).CGColor;
        [self.gridContentView addSubview:dot];
        [self.controllerHeroViews addObject:dot];
    }
}

- (void)loadControllerHeroImageForView:(OPNControllerPreviewBackgroundView *)view candidates:(NSArray<NSString *> *)candidates index:(NSUInteger)index {
    if (!view || index >= candidates.count) return;
    __weak OPNControllerPreviewBackgroundView *weakView = view;
    __weak __typeof__(self) weakSelf = self;
    OpnImageLoadToken *token = OPNCatalogLoadImageFromCandidates(candidates, index, ^(NSImage *image, NSString *resolvedURL, NSData *data) {
        (void)resolvedURL;
        OPNControllerPreviewBackgroundView *strongView = weakView;
        if (strongView.superview && image) [strongView setImage:image metadataData:data];
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf || !image || image.size.width <= 0.0 || image.size.height <= 0.0) return;
        CGFloat aspectRatio = image.size.width / image.size.height;
        if (fabs(strongSelf.controllerHeroImageAspectRatio - aspectRatio) <= 0.01) return;
        strongSelf.controllerHeroImageAspectRatio = aspectRatio;
    });
    [self trackCatalogImageLoadToken:token];
}

- (void)loadControllerHeroLogoForView:(NSImageView *)view candidates:(NSArray<NSString *> *)candidates index:(NSUInteger)index {
    if (!view || index >= candidates.count) return;
    __weak NSImageView *weakView = view;
    OpnImageLoadToken *token = OPNCatalogLoadImageFromCandidates(candidates, index, ^(NSImage *image, NSString *resolvedURL, NSData *data) {
        (void)resolvedURL;
        (void)data;
        NSImageView *strongView = weakView;
        if (!strongView.superview || !image) return;

        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        strongView.image = image;
        strongView.layer.opacity = 1.0;
        [CATransaction commit];
    });
    [self trackCatalogImageLoadToken:token];
}

- (void)startControllerHeroRotationIfNeeded {
    std::vector<OPN::GameInfo> featuredGames = OpnControllerModeEnabled()
        ? [self controllerFeaturedGamesFromDisplayGames:_featuredGames]
        : [self featuredLibraryGamesWithFallback:std::vector<OPN::GameInfo>()];
    if (!self.window || featuredGames.size() <= 1) {
        [self stopControllerHeroRotation];
        return;
    }
    if (self.controllerHeroRotationTimer) return;
    self.controllerHeroRotationTimer = [NSTimer timerWithTimeInterval:8.0
                                                               target:self
                                                             selector:@selector(controllerHeroRotationTimerFired:)
                                                             userInfo:nil
                                                              repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.controllerHeroRotationTimer forMode:NSRunLoopCommonModes];
}

- (void)stopControllerHeroRotation {
    [self.controllerHeroRotationTimer invalidate];
    self.controllerHeroRotationTimer = nil;
}

- (void)controllerHeroRotationTimerFired:(NSTimer *)timer {
    (void)timer;
    std::vector<OPN::GameInfo> featuredGames = OpnControllerModeEnabled()
        ? [self controllerFeaturedGamesFromDisplayGames:_featuredGames]
        : [self featuredLibraryGamesWithFallback:std::vector<OPN::GameInfo>()];
    if (!self.window || featuredGames.size() <= 1) {
        [self stopControllerHeroRotation];
        return;
    }
    NSInteger featuredCount = (NSInteger)featuredGames.size();
    if (featuredCount <= 1) return;
    self.controllerHeroIndex = (self.controllerHeroIndex + 1) % featuredCount;
    if (OpnControllerModeEnabled()) {
        [self renderControllerHeroAnimated:YES];
    } else {
        self.hasDesktopFeaturedGame = NO;
        [self renderGrid];
    }
}

- (void)controllerHeroResumeClicked:(id)sender {
    (void)sender;
    const OPN::GameInfo *heroGame = [self currentControllerHeroGame];
    if (!heroGame) return;
    if (!OPNLibraryGameHasAccessibleVariants(*heroGame)) {
        [self controllerHeroMoreInfoClicked:nil];
        return;
    }
    if ([self primaryActionForHeroGame:*heroGame] == OPNControllerHeroPrimaryActionBuy) {
        [self controllerHeroMoreInfoClicked:nil];
        return;
    }
    if (!self.onSelectGame) return;
    if (OpnControllerModeEnabled()) OpnPlayConsoleTone(OPNConsoleToneSelect);
    OPN::GameInfo libraryGame = OPNGameWithLibraryAccessibleVariants(*heroGame);
    self.onSelectGame(libraryGame, [self preferredVariantIndexForGame:libraryGame]);
}

- (void)controllerHeroMoreInfoClicked:(id)sender {
    (void)sender;
    const OPN::GameInfo *heroGame = [self currentControllerHeroGame];
    if (!heroGame) return;
    std::vector<OPN::GameInfo> displayGames = [self controllerLibraryDisplayGames];
    for (size_t index = 0; index < displayGames.size(); index++) {
        const OPN::GameInfo &game = displayGames[index];
        BOOL idMatches = !heroGame->id.empty() && game.id == heroGame->id;
        BOOL uuidMatches = !heroGame->uuid.empty() && game.uuid == heroGame->uuid;
        if (!idMatches && !uuidMatches) continue;
        [self focusCardAtIndex:(NSInteger)index scrollIntoView:YES];
        [self openFocusedGameDetails];
        return;
    }
}

- (void)scrollLibraryToTop {
    NSClipView *clipView = self.scrollView.contentView;
    [clipView scrollToPoint:NSMakePoint(0, 0)];
    [self.scrollView reflectScrolledClipView:clipView];
    self.controllerLibraryRailOffsetX = 0.0;
    if (self.controllerLibraryRailView) {
        NSRect railFrame = self.controllerLibraryRailView.frame;
        railFrame.origin.x = 0.0;
        self.controllerLibraryRailView.frame = railFrame;
    }
}

- (void)sortClicked:(NSButton *)sender {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Sort Games"];
    if (self.catalogSortOptions.empty()) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:self.sortButton.title action:nil keyEquivalent:@""];
        [menu addItem:item];
    }
    for (const OPN::CatalogSortOption &option : self.catalogSortOptions) {
        NSString *sortId = OPNCatalogString(option.id, @"last_played");
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:OPNCatalogString(option.label, sortId)
                                                      action:@selector(sortMenuItemSelected:)
                                               keyEquivalent:@""];
        item.target = self;
        item.representedObject = sortId;
        item.state = [self.selectedSortId isEqualToString:sortId] ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem:item];
    }
    [menu popUpMenuPositioningItem:nil
                        atLocation:NSMakePoint(0.0, NSHeight(sender.bounds) + 4.0)
                            inView:sender];
}

- (void)sortMenuItemSelected:(NSMenuItem *)sender {
    NSString *sortId = [sender.representedObject isKindOfClass:NSString.class] ? sender.representedObject : @"last_played";
    self.selectedSortId = sortId;
    self.sortButton.title = sender.title;
    [self requestCatalogBrowse];
}

- (void)filterClicked:(NSButton *)sender {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Filters"];
    BOOL addedAny = NO;
    for (const OPN::CatalogFilterGroup &group : self.catalogFilterGroups) {
        if (group.id != "digital_store" && group.id != "genre" && group.id != "subscriptions") continue;
        if (addedAny) [menu addItem:[NSMenuItem separatorItem]];
        NSString *groupTitle = OPNCatalogString(group.label, @"Filters");
        NSMenuItem *heading = [[NSMenuItem alloc] initWithTitle:groupTitle action:nil keyEquivalent:@""];
        heading.enabled = NO;
        [menu addItem:heading];
        NSInteger limit = group.id == "genre" ? 8 : (NSInteger)group.options.size();
        NSInteger index = 0;
        for (const OPN::CatalogFilterOption &option : group.options) {
            if (index++ >= limit) break;
            NSString *filterId = OPNCatalogString(option.id, @"");
            if (filterId.length == 0) continue;
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:OPNCatalogString(option.label, filterId)
                                                          action:@selector(filterMenuItemSelected:)
                                                   keyEquivalent:@""];
            item.target = self;
            item.representedObject = filterId;
            item.state = [self.selectedFilterIds containsObject:filterId] ? NSControlStateValueOn : NSControlStateValueOff;
            [menu addItem:item];
            addedAny = YES;
        }
    }
    if (!addedAny) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"No filters available" action:nil keyEquivalent:@""];
        [menu addItem:item];
    } else if (self.selectedFilterIds.count > 0) {
        [menu addItem:[NSMenuItem separatorItem]];
        NSMenuItem *clear = [[NSMenuItem alloc] initWithTitle:@"Clear Filters" action:@selector(clearFiltersSelected:) keyEquivalent:@""];
        clear.target = self;
        [menu addItem:clear];
    }
    [menu popUpMenuPositioningItem:nil
                        atLocation:NSMakePoint(0.0, NSHeight(sender.bounds) + 4.0)
                            inView:sender];
}

- (void)filterMenuItemSelected:(NSMenuItem *)sender {
    NSString *filterId = [sender.representedObject isKindOfClass:NSString.class] ? sender.representedObject : nil;
    if (filterId.length == 0) return;
    if ([self.selectedFilterIds containsObject:filterId]) {
        [self.selectedFilterIds removeObject:filterId];
    } else {
        [self.selectedFilterIds addObject:filterId];
    }
    self.filterButton.title = self.selectedFilterIds.count > 0
        ? [NSString stringWithFormat:@"Filters (%lu)", (unsigned long)self.selectedFilterIds.count]
        : @"Filters";
    [self requestCatalogBrowse];
}

- (void)clearFiltersSelected:(NSMenuItem *)sender {
    (void)sender;
    [self.selectedFilterIds removeAllObjects];
    self.filterButton.title = @"Filters";
    [self requestCatalogBrowse];
}

- (void)layout {
    [super layout];
    [self layoutCatalogSubviews];
    if (std::fabs(self.lastLayoutWidth - NSWidth(self.bounds)) > 1.0) {
        self.lastLayoutWidth = NSWidth(self.bounds);
        self.needsGridRenderAfterResize = YES;
    }
}

- (void)viewDidEndLiveResize {
    [super viewDidEndLiveResize];
    if (!self.needsGridRenderAfterResize || self.allGames.empty()) return;
    self.needsGridRenderAfterResize = NO;
    [self renderGrid];
}

- (void)layoutCatalogSubviews {
    CGFloat width = NSWidth(self.bounds);
    CGFloat height = NSHeight(self.bounds);
    BOOL controllerMode = OpnControllerModeEnabled();
    CGFloat controllerNavHeight = 118.0;
    self.scrollView.hasVerticalScroller = !controllerMode;
    self.scrollView.hasHorizontalScroller = NO;
    self.scrollView.verticalScrollElasticity = controllerMode ? NSScrollElasticityNone : NSScrollElasticityAutomatic;
    self.scrollView.drawsBackground = NO;
    self.scrollView.layer.opaque = NO;
    self.scrollView.layer.backgroundColor = NSColor.clearColor.CGColor;
    self.scrollView.contentView.drawsBackground = NO;
    self.scrollView.contentView.backgroundColor = NSColor.clearColor;
    self.scrollView.contentView.layer.opaque = NO;
    self.scrollView.contentView.layer.backgroundColor = NSColor.clearColor.CGColor;
    self.gridContentView.layer.opaque = NO;
    self.gridContentView.layer.backgroundColor = NSColor.clearColor.CGColor;
    BOOL compact = width < 900.0;
    self.searchField.hidden = controllerMode;
    self.filterButton.hidden = controllerMode || compact;
    self.signOutButton.hidden = YES;
    CGFloat filterWidth = 124.0;
    CGFloat sortWidth = 154.0;
    CGFloat controlGap = 12.0;
    CGFloat accountSwitcherWidth = MIN(248.0, MAX(208.0, width * 0.18));
    CGFloat accountSwitcherX = MAX(24.0, width - accountSwitcherWidth - 70.0);
    CGFloat controlsLeftEdge = MAX(440.0, width * 0.34);
    CGFloat controlsRightEdge = compact ? width - 32.0 : accountSwitcherX - 24.0;
    CGFloat buttonsWidth = filterWidth + sortWidth + (controlGap * 2.0);
    CGFloat availableSearchWidth = MAX(260.0, controlsRightEdge - controlsLeftEdge - buttonsWidth);
    CGFloat searchWidth = compact ? MAX(240.0, width - 64.0) : MIN(520.0, availableSearchWidth);
    CGFloat searchX = compact ? floor((width - searchWidth) / 2.0) : controlsLeftEdge;
    self.libraryIconLabel.frame = NSMakeRect(0, 0, 0, 0);
    self.titleLabel.frame = NSMakeRect(0, 0, 0, 0);
    self.userLabel.frame = NSMakeRect(24, kNavHeight + 36, 260, 18);
    self.searchField.frame = NSMakeRect(searchX, compact ? kNavHeight + 62 : kNavHeight + 25, searchWidth, 40);
    self.sortButton.hidden = controllerMode || compact;
    self.filterButton.frame = NSMakeRect(NSMaxX(self.searchField.frame) + controlGap, kNavHeight + 26, filterWidth, 38);
    self.sortButton.frame = NSMakeRect(NSMaxX(self.filterButton.frame) + controlGap, kNavHeight + 26, sortWidth, 38);
    self.gameCountLabel.frame = NSMakeRect(0, 0, 0, 0);
    self.gameCountLabel.hidden = YES;
    self.signOutButton.frame = NSMakeRect(width - 116, kNavHeight + 13, 92, 30);
    BOOL homeSurface = controllerMode && self.controllerSurface == OPNControllerCatalogSurfaceHome;
    OPNControllerLibraryMetrics controllerMetrics = OPNControllerLibraryMetricsForSize(width, height);
    self.controllerBottomPromptBarView.hidden = !controllerMode;
    self.controllerBottomPromptBarView.mode = homeSurface ? OPNControllerPromptModeHome : OPNControllerPromptModeGame;
    self.controllerBottomPromptBarView.includeStore = !homeSurface;
    self.controllerBottomPromptBarView.includeBack = !homeSurface;
    self.controllerBottomPromptBarView.includeCategorySwitch = !homeSurface && self.categoryItems.count > 1;
    self.controllerBottomPromptBarView.frame = NSMakeRect(controllerMetrics.contentInset, height - controllerMetrics.bottomInset + height * (20.0 / 720.0), MAX(0.0, width - controllerMetrics.contentInset * 2.0), height * (32.0 / 720.0));
    if (controllerMode) {
        self.searchField.hidden = YES;
        self.filterButton.hidden = YES;
        self.sortButton.hidden = YES;
        self.categoryBarView.hidden = YES;
        self.controllerSectionLabel.hidden = YES;
        self.controllerDetailView.hidden = YES;
        self.controllerDetailBackgroundView.hidden = YES;
        self.controllerGameHubView.hidden = YES;
        self.controllerPromptBarView.hidden = YES;
        self.scrollView.hasVerticalScroller = NO;
        self.scrollView.hasHorizontalScroller = NO;
        CGFloat gridY = controllerMetrics.topInset;
        self.scrollView.frame = NSMakeRect(0.0, gridY, width, MAX(0.0, height - gridY - controllerMetrics.bottomInset));
        self.statusLabel.frame = NSMakeRect(width * (28.0 / 1280.0), gridY + height * (120.0 / 720.0), width - width * (56.0 / 1280.0), height * (24.0 / 720.0));
        self.loadingView.frame = self.bounds;
        self.detailsOverlayView.frame = self.bounds;
        [self layoutControllerStoreFilterOverlay];
        [self stopControllerDetailBackgroundRotation];
        return;
    }
    self.controllerSectionLabel.hidden = !controllerMode || homeSurface;
    if (homeSurface) {
        self.categoryBarView.hidden = YES;
        self.controllerDetailView.hidden = YES;
        self.controllerDetailBackgroundView.hidden = YES;
        [self stopControllerDetailBackgroundRotation];
        self.controllerGameHubView.hidden = YES;
        self.controllerPromptBarView.hidden = YES;
        self.scrollView.hasVerticalScroller = NO;
        self.scrollView.hasHorizontalScroller = NO;
        CGFloat gridY = controllerNavHeight + 48.0;
        self.scrollView.frame = NSMakeRect(0.0, gridY, width, MAX(0.0, height - gridY - 78.0));
        self.statusLabel.frame = NSMakeRect(28.0, gridY + NSHeight(self.scrollView.frame) + 10.0, width - 56.0, 24.0);
        self.loadingView.frame = self.bounds;
        self.detailsOverlayView.frame = self.bounds;
        [self layoutControllerStoreFilterOverlay];
        return;
    }
    self.categoryBarView.hidden = YES;
    CGFloat cardHeight = [OPNGameCardView cardSize].height;
    CGFloat minimumDetailHeight = 220.0;
    CGFloat desiredCarouselHeight = cardHeight + 96.0;
    CGFloat categoryY = controllerNavHeight + 10.0;
    CGFloat railY = controllerNavHeight + 10.0;
    CGFloat bottomInset = 36.0;
    CGFloat selectorOverlap = controllerMode ? kControllerRailSelectorOverlap : 0.0;
    CGFloat detailOverlap = controllerMode ? kControllerRailDetailOverlap : 0.0;
    CGFloat detailGap = -detailOverlap;
    CGFloat carouselHeight = desiredCarouselHeight;
    CGFloat detailY = railY + carouselHeight + detailGap;
    CGFloat detailHeight = 0.0;
    CGFloat gridY = 0.0;
    if (controllerMode) {
        CGFloat availableContentHeight = MAX(0.0, height - railY - bottomInset);
        carouselHeight = MIN(desiredCarouselHeight, MAX(cardHeight + 62.0, availableContentHeight * 0.32));
        detailY = railY + carouselHeight + detailGap;
        detailHeight = MAX(minimumDetailHeight, height - detailY);
        gridY = railY;
    }
    if (controllerMode && !self.categoryBarView.hidden) {
        self.categoryBarView.frame = NSMakeRect(64.0, categoryY, MAX(240.0, width - 128.0), 30.0);
        CGFloat categoryX = 0.0;
        for (NSButton *button in self.categoryButtons) {
            BOOL selected = [button.identifier isEqualToString:self.selectedCategoryId];
            CGFloat buttonWidth = NSWidth(button.frame);
            button.frame = NSMakeRect(categoryX, 0.0, buttonWidth, 30.0);
            button.contentTintColor = selected ? OpnColor(OPNControllerAccentBlackRGB(0.88)) : OpnColor(kTextSecondary);
            button.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightSemibold];
            button.layer.cornerRadius = 15.0;
            button.layer.backgroundColor = selected ? OpnColor(OPNControllerAccentSoftRGB(), 0.88).CGColor : OpnColor(OPNControllerAccentRGB(), 0.080).CGColor;
            button.layer.borderWidth = selected ? 0.0 : 1.0;
            button.layer.borderColor = OpnColor(0xFFFFFF, 0.12).CGColor;
            categoryX += buttonWidth + 8.0;
        }
    }
    self.controllerDetailView.hidden = !controllerMode || self.cardViews.count == 0;
    self.controllerDetailBackgroundView.hidden = self.controllerDetailView.hidden;
    self.controllerDetailBackgroundView.frame = self.bounds;
    self.controllerSectionLabel.stringValue = [self activeCategoryTitle];
    self.controllerSectionLabel.frame = NSMakeRect(64.0, 42.0, MIN(620.0, width - 128.0), 26.0);
    self.controllerDetailView.frame = NSMakeRect(0.0, detailY, width, detailHeight);
    CGPathRef detailShadowPath = OpnCreateRoundedRectPath(self.controllerDetailView.bounds, 30.0, 30.0);
    self.controllerDetailView.layer.shadowPath = detailShadowPath;
    CGPathRelease(detailShadowPath);
    CGFloat detailWidth = NSWidth(self.controllerDetailView.frame);
    self.controllerDetailGradientLayer.frame = self.controllerDetailView.bounds;
    self.controllerDetailAccentLayer.frame = NSMakeRect(64.0, 18.0, 74.0, 3.0);
    CGFloat heroX = 64.0;
    CGFloat availableGameHubHeight = MAX(0.0, detailHeight - kControllerGameHubVerticalReserve);
    BOOL showGameHub = controllerMode && self.cardViews.count > 0 && detailWidth >= 820.0 && availableGameHubHeight >= 300.0;
    CGFloat gameHubWidth = showGameHub ? MIN(430.0, MAX(340.0, detailWidth * 0.28)) : 0.0;
    CGFloat gameHubHeight = showGameHub ? MIN(kControllerGameHubPreferredHeight, availableGameHubHeight) : 0.0;
    CGFloat gameHubX = detailWidth - gameHubWidth - 64.0;
    CGFloat gameHubY = showGameHub ? MAX(28.0, floor((detailHeight - gameHubHeight) * 0.34)) : 0.0;
    CGFloat rightContextInset = showGameHub ? gameHubWidth + 84.0 : 0.0;
    CGFloat heroWidth = MAX(260.0, detailWidth - 128.0 - rightContextInset);
    self.controllerDetailStatsLabel.hidden = YES;
    self.controllerDetailStatsLabel.frame = NSZeroRect;
    CGFloat featuresY = 42.0;
    self.controllerDetailFeaturesLabel.hidden = NO;
    self.controllerDetailFeaturesLabel.frame = NSMakeRect(heroX + 2.0, featuresY, MIN(900.0, heroWidth), MAX(0.0, detailHeight - featuresY - 94.0));
    self.controllerPromptBarView.frame = NSMakeRect(heroX + 2.0, MAX(188.0, detailHeight - 62.0), heroWidth, 36.0);
    self.controllerGameHubView.hidden = !showGameHub;
    if (showGameHub) {
        self.controllerGameHubView.frame = NSMakeRect(gameHubX, gameHubY, gameHubWidth, gameHubHeight);
    } else {
        self.controllerGameHubView.frame = NSZeroRect;
    }
    CGFloat railFrameY = controllerMode ? MAX(0.0, gridY - selectorOverlap) : gridY;
    CGFloat railHeight = controllerMode ? MIN(carouselHeight + selectorOverlap, MAX(0.0, height - railFrameY)) : MAX(0.0, height - gridY);
    self.scrollView.frame = NSMakeRect(0, railFrameY, width, railHeight);
    self.statusLabel.frame = controllerMode ? NSMakeRect(28.0, MAX(kNavHeight + 30.0, gridY - 42.0), width - 56.0, 24.0) : NSMakeRect(0, height * 0.5, width, 24);
    if (controllerMode && self.cardViews.count > 0) {
        self.statusLabel.stringValue = @"";
        self.statusLabel.textColor = OpnColor(kTextSecondary);
        self.statusLabel.alignment = NSTextAlignmentCenter;
    }
    self.loadingView.frame = self.bounds;
    self.detailsOverlayView.frame = self.bounds;
    [self layoutControllerStoreFilterOverlay];
}

- (void)searchChanged {
    [self requestCatalogBrowse];
}

- (void)controlTextDidChange:(NSNotification *)notification {
    if (notification.object == _searchField) {
        [self requestCatalogBrowse];
    }
}

- (void)requestCatalogBrowse {
    if (!self.onCatalogBrowseRequested) {
        [self renderGrid];
        [self scrollLibraryToTop];
        return;
    }
    std::vector<std::string> filters;
    NSArray<NSString *> *sortedFilters = [[self.selectedFilterIds allObjects] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    for (NSString *filterId in sortedFilters) {
        filters.push_back([filterId UTF8String]);
    }
    self.onCatalogBrowseRequested(self.searchField.stringValue ?: @"", self.selectedSortId ?: @"last_played", filters);
}

- (void)focusCardAtIndex:(NSInteger)index scrollIntoView:(BOOL)scrollIntoView {
    BOOL controllerMode = OpnControllerModeEnabled();
    NSInteger itemCount = controllerMode ? self.controllerDisplayGameCount : MAX(self.desktopDisplayGameCount, (NSInteger)self.cardViews.count);
    if (itemCount == 0) {
        self.focusedCardIndex = -1;
        return;
    }
    NSInteger previousIndex = self.focusedCardIndex;
    NSInteger clamped = MAX(0, MIN(index, itemCount - 1));
    self.focusedCardIndex = clamped;
    if (controllerMode && (clamped < self.controllerLibraryWindowStartIndex || clamped >= self.controllerLibraryWindowStartIndex + (NSInteger)self.cardViews.count)) {
        [self renderControllerLibraryRail];
        [self scrollControllerLibraryRailToCardAtIndex:clamped animated:scrollIntoView];
        [self updateControllerDetailContent];
        return;
    }
    OPNControllerLibraryMetrics metrics = OPNControllerLibraryMetricsForSize(MAX(1.0, NSWidth(self.bounds)), MAX(1.0, NSHeight(self.bounds)));
    if (controllerMode && (clamped < self.controllerLibraryVisibleStartIndex || clamped >= self.controllerLibraryVisibleStartIndex + metrics.visibleCardCount)) {
        [self renderControllerLibraryRail];
    }
    for (NSUInteger i = 0; i < self.cardViews.count; i++) {
        NSInteger globalIndex = controllerMode ? self.controllerLibraryWindowStartIndex + (NSInteger)i : self.desktopRenderStartIndex + (NSInteger)i;
        BOOL selected = controllerMode && globalIndex == clamped;
        self.cardViews[i].controllerFocused = selected;
        self.cardViews[i].alphaValue = 1.0;
    }
    if (controllerMode && scrollIntoView && previousIndex >= 0 && previousIndex != clamped) {
        OpnPlayConsoleTone(OPNConsoleToneMove);
    }
    [self updateControllerDetailContent];
    if (!scrollIntoView) return;
    NSInteger localIndex = controllerMode ? clamped - self.controllerLibraryWindowStartIndex : clamped - self.desktopRenderStartIndex;
    if (localIndex < 0 || localIndex >= (NSInteger)self.cardViews.count) {
        if (!controllerMode) {
            NSInteger columns = MAX(1, self.gridColumnCount);
            NSSize cardSize = [OPNGameCardView cardSize];
            CGFloat pageWidth = MAX(980.0, NSWidth(self.bounds));
            CGFloat contentX = MAX(42.0, MIN(86.0, floor(pageWidth * 0.065)));
            CGFloat contentWidth = MAX(680.0, pageWidth - contentX * 2.0);
            const OPN::GameInfo *heroGame = [self currentLastPlayedGame];
            if (!heroGame && !_allGames.empty()) heroGame = &_allGames.front();
            CGFloat heroHeight = heroGame ? MIN(kDesktopLibraryHeroHeight, MAX(360.0, floor(contentWidth * 0.36))) : 0.0;
            CGFloat gridTop = heroGame ? kDesktopLibraryTopInset + kDesktopLibraryHeroTopOffset + heroHeight + kDesktopLibraryGridTopGap : kDesktopLibraryTopInset + 146.0;
            CGFloat cardStartY = gridTop + 52.0;
            CGFloat availableWidth = contentWidth;
            CGFloat gridSpacing = columns > 1 ? floor((availableWidth - columns * cardSize.width) / (columns - 1)) : kCardSpacing;
            gridSpacing = MAX(kCardSpacing, gridSpacing);
            CGFloat xStart = contentX + (columns > 1 ? 0.0 : floor(MAX(0.0, (contentWidth - cardSize.width) / 2.0)));
            NSInteger row = clamped / columns;
            NSInteger column = clamped % columns;
            NSRect targetRect = NSInsetRect(NSMakeRect(xStart + column * (cardSize.width + gridSpacing),
                                                       cardStartY + row * (cardSize.height + kDesktopLibraryRowSpacing),
                                                       cardSize.width,
                                                       cardSize.height), -24.0, -24.0);
            [self.gridContentView scrollRectToVisible:targetRect];
            [self.scrollView reflectScrolledClipView:self.scrollView.contentView];
            [self renderGrid];
        }
        return;
    }
    OPNGameCardView *card = self.cardViews[(NSUInteger)localIndex];
    NSRect visibleRect = self.scrollView.contentView.bounds;
    NSRect targetRect = NSInsetRect(card.frame, -24.0, -24.0);
    if (controllerMode) {
        [self.scrollView.contentView scrollToPoint:NSMakePoint(0.0, 0.0)];
        [self.scrollView reflectScrolledClipView:self.scrollView.contentView];
        [self scrollControllerLibraryRailToCardAtIndex:clamped animated:YES];
        return;
    }
    if (!NSContainsRect(visibleRect, targetRect)) {
        [self.gridContentView scrollRectToVisible:targetRect];
        [self.scrollView reflectScrolledClipView:self.scrollView.contentView];
    }
}

- (OPNGameCardView *)focusedCard {
    NSInteger localIndex = OpnControllerModeEnabled() ? self.focusedCardIndex - self.controllerLibraryWindowStartIndex : self.focusedCardIndex - self.desktopRenderStartIndex;
    if (localIndex < 0 || localIndex >= (NSInteger)self.cardViews.count) return nil;
    return self.cardViews[(NSUInteger)localIndex];
}

- (void)resetDesktopGridRenderWindow {
    self.desktopRenderStartIndex = 0;
    self.desktopRenderedGameCount = 0;
    self.desktopDisplayGameCount = 0;
}

- (NSInteger)desktopInitialRenderedGameCountForColumns:(NSInteger)columns {
    CGFloat cardHeight = [OPNGameCardView cardSize].height;
    CGFloat availableHeight = NSHeight(self.scrollView.frame) > 1.0 ? NSHeight(self.scrollView.frame) : NSHeight(self.bounds);
    NSInteger visibleRows = (NSInteger)ceil((availableHeight + kDesktopLibraryRowSpacing) / MAX(1.0, cardHeight + kDesktopLibraryRowSpacing));
    return MAX(columns, columns * MAX(1, visibleRows + kDesktopGridRenderBufferRows));
}

- (void)libraryScrollViewBoundsDidChange:(NSNotification *)notification {
    if (notification.object != self.scrollView.contentView || OpnControllerModeEnabled()) return;
    if (self.desktopDisplayGameCount <= 0) return;

    NSClipView *clipView = self.scrollView.contentView;
    NSInteger columns = MAX(1, self.gridColumnCount);
    CGFloat pageWidth = MAX(980.0, NSWidth(self.bounds));
    CGFloat contentX = MAX(42.0, MIN(86.0, floor(pageWidth * 0.065)));
    CGFloat contentWidth = MAX(680.0, pageWidth - contentX * 2.0);
    const OPN::GameInfo *heroGame = self.hasDesktopFeaturedGame ? &_desktopFeaturedGame : [self currentLastPlayedGame];
    if (!heroGame && !_allGames.empty()) heroGame = &_allGames.front();
    CGFloat heroHeight = heroGame ? MIN(kDesktopLibraryHeroHeight, MAX(360.0, floor(contentWidth * 0.36))) : 0.0;
    CGFloat gridTop = heroGame ? kDesktopLibraryTopInset + kDesktopLibraryHeroTopOffset + heroHeight + kDesktopLibraryGridTopGap : kDesktopLibraryTopInset + 146.0;
    CGFloat rowHeight = [OPNGameCardView cardSize].height + kDesktopLibraryRowSpacing;
    CGFloat visibleMinY = MAX(0.0, NSMinY(clipView.bounds) - (gridTop + 52.0));
    NSInteger firstVisibleRow = rowHeight > 0.0 ? MAX(0, (NSInteger)floor(visibleMinY / rowHeight)) : 0;
    NSInteger nextStartIndex = MAX(0, firstVisibleRow - kDesktopGridRenderBufferRows) * columns;
    nextStartIndex = MIN(nextStartIndex, MAX(0, self.desktopDisplayGameCount - 1));
    if (nextStartIndex == self.desktopRenderStartIndex) return;
    [self renderGrid];
}

- (NSInteger)controllerInitialRenderedGameCount {
    CGFloat cardWidth = [OPNGameCardView cardSize].width;
    CGFloat availableWidth = NSWidth(self.scrollView.frame) > 1.0 ? NSWidth(self.scrollView.frame) : NSWidth(self.bounds);
    CGFloat spacing = 26.0;
    CGFloat railInset = 64.0;
    CGFloat usableWidth = MAX(cardWidth, availableWidth - railInset * 2.0);
    NSInteger count = (NSInteger)ceil((usableWidth + spacing) / MAX(1.0, cardWidth + spacing));
    NSInteger result = MAX(1, count + 1);
    OPN::LogInfo(@"[CatalogView] initial render count availableWidth=%.1f usable=%.1f card=%.1f spacing=%.1f result=%ld", availableWidth, usableWidth, cardWidth, spacing, (long)result);
    return result;
}

- (BOOL)appendControllerGameCardAtIndex:(NSInteger)index {
    if (index < 0 || index >= self.controllerDisplayGameCount || index != (NSInteger)self.cardViews.count) {
        OPN::LogInfo(@"[CatalogView] append skipped index=%ld cardCount=%lu display=%ld rendered=%ld", (long)index, (unsigned long)self.cardViews.count, (long)self.controllerDisplayGameCount, (long)self.controllerRenderedGameCount);
        return NO;
    }

    std::vector<OPN::GameInfo> displayGames = [self controllerLibraryDisplayGames];
    if (index >= (NSInteger)displayGames.size()) {
        OPN::LogError(@"[CatalogView] append failed no matching game index=%ld category=%@ display=%ld", (long)index, self.selectedCategoryId, (long)self.controllerDisplayGameCount);
        return NO;
    }
    OPN::GameInfo gameToAppend = displayGames[(size_t)index];
    OPN::LogInfo(@"[CatalogView] append card index=%ld title=%@ id=%@ uuid=%@ desc=%d features=%lu image=%d hero=%d variants=%lu", (long)index, OPNCatalogString(gameToAppend.title, @"<untitled>"), OPNCatalogString(gameToAppend.id, @""), OPNCatalogString(gameToAppend.uuid, @""), !gameToAppend.description.empty(), (unsigned long)gameToAppend.featureLabels.size(), !gameToAppend.imageUrl.empty(), !gameToAppend.heroImageUrl.empty(), (unsigned long)gameToAppend.variants.size());

    CGFloat cardWidth = [OPNGameCardView cardSize].width;
    CGFloat cardHeight = [OPNGameCardView cardSize].height;
    CGFloat gridSpacing = 26.0;
    CGFloat xStart = 64.0;
    CGFloat yPos = 34.0 + kControllerRailSelectorOverlap;
    NSRect cardFrame = NSMakeRect(xStart + index * (cardWidth + gridSpacing), yPos, cardWidth, cardHeight);
    OPNGameCardView *card = [[OPNGameCardView alloc] initWithFrame:cardFrame game:gameToAppend];
    card.imageRevealDelay = 0.08;
    GameInfo gameCopy = gameToAppend;
    __weak __typeof__(self) weakSelf = self;
    __weak OPNGameCardView *weakCard = card;
    card.onPlay = ^{
        __typeof__(self) s = weakSelf;
        OPNGameCardView *c = weakCard;
        if (!s || !c) return;
        NSUInteger cardIndex = [s.cardViews indexOfObject:c];
        if (cardIndex != NSNotFound) [s focusCardAtIndex:(NSInteger)cardIndex scrollIntoView:NO];
        if (OpnControllerModeEnabled()) {
            [s launchFocusedGame];
        } else if (s.onSelectGame) {
            int variantIdx = c.selectedVariantIndex;
            s.onSelectGame(gameCopy, variantIdx >= 0 ? variantIdx : 0);
        }
    };
    [self.gridContentView addSubview:card];
    [self.cardViews addObject:card];
    self.controllerRenderedGameCount = (NSInteger)self.cardViews.count;

    CGFloat totalWidth = xStart * 2.0 + self.cardViews.count * cardWidth + MAX(0, (NSInteger)self.cardViews.count - 1) * gridSpacing;
    CGFloat totalHeight = cardHeight + 104.0;
    self.gridContentView.frame = NSMakeRect(0.0,
                                            0.0,
                                            MAX(totalWidth, NSWidth(self.scrollView.frame)),
                                            MAX(totalHeight, NSHeight(self.scrollView.frame)));
    OPN::LogInfo(@"[CatalogView] append complete cards=%lu rendered=%ld contentWidth=%.1f", (unsigned long)self.cardViews.count, (long)self.controllerRenderedGameCount, NSWidth(self.gridContentView.frame));
    return YES;
}

- (BOOL)preloadControllerGameIfNeededForIndex:(NSInteger)index direction:(NSInteger)direction {
    if (!OpnControllerModeEnabled() || self.controllerSurface != OPNControllerCatalogSurfaceLibrary) return NO;
    if (direction <= 0 || index < (NSInteger)self.cardViews.count || self.controllerRenderedGameCount >= self.controllerDisplayGameCount) {
        OPN::LogInfo(@"[CatalogView] edge preload skipped target=%ld dir=%ld cards=%lu rendered=%ld display=%ld", (long)index, (long)direction, (unsigned long)self.cardViews.count, (long)self.controllerRenderedGameCount, (long)self.controllerDisplayGameCount);
        return NO;
    }
    OPN::LogInfo(@"[CatalogView] edge preload target=%ld dir=%ld", (long)index, (long)direction);
    BOOL appended = NO;
    appended = [self appendControllerGameCardAtIndex:(NSInteger)self.cardViews.count];
    return appended;
}

- (void)preloadControllerNeighborForDirection:(NSInteger)direction {
    if (!OpnControllerModeEnabled() || self.controllerSurface != OPNControllerCatalogSurfaceLibrary || direction <= 0) return;
    NSInteger nextIndex = self.focusedCardIndex + 1;
    OPN::LogInfo(@"[CatalogView] neighbor preload check focused=%ld next=%ld cards=%lu rendered=%ld display=%ld", (long)self.focusedCardIndex, (long)nextIndex, (unsigned long)self.cardViews.count, (long)self.controllerRenderedGameCount, (long)self.controllerDisplayGameCount);
    if (nextIndex >= (NSInteger)self.cardViews.count - 1 && self.controllerRenderedGameCount < self.controllerDisplayGameCount) {
        [self appendControllerGameCardAtIndex:(NSInteger)self.cardViews.count];
    }
}

- (void)moveFocusByRows:(NSInteger)rows columns:(NSInteger)columns {
    if (OpnControllerModeEnabled() && self.controllerSurface == OPNControllerCatalogSurfaceHome) {
        [self moveControllerHomeFocusByRows:rows columns:columns];
        return;
    }
    if (OpnControllerModeEnabled() && rows != 0) {
        return;
    }
    if (OpnControllerModeEnabled()) {
        if (self.controllerDisplayGameCount <= 0) return;
        NSInteger next = self.focusedCardIndex + columns;
        next = MAX(0, MIN(next, self.controllerDisplayGameCount - 1));
        if (next == self.focusedCardIndex) return;
        self.focusedCardIndex = next;
        OPNControllerLibraryMetrics metrics = OPNControllerLibraryMetricsForSize(MAX(1.0, NSWidth(self.bounds)), MAX(1.0, NSHeight(self.bounds)));
        BOOL crossedVisibleWindow = next < self.controllerLibraryVisibleStartIndex || next >= self.controllerLibraryVisibleStartIndex + metrics.visibleCardCount;
        BOOL crossedRenderedWindow = next < self.controllerLibraryWindowStartIndex || next >= self.controllerLibraryWindowStartIndex + (NSInteger)self.cardViews.count;
        if (crossedVisibleWindow || crossedRenderedWindow) {
            [self renderControllerLibraryRail];
        }
        [self focusCardAtIndex:next scrollIntoView:YES];
        return;
    }
    NSInteger next = self.focusedCardIndex + rows * MAX(1, self.gridColumnCount) + columns;
    OPN::LogInfo(@"[CatalogView] moveFocus rows=%ld cols=%ld current=%ld next=%ld cards=%lu rendered=%ld display=%ld", (long)rows, (long)columns, (long)self.focusedCardIndex, (long)next, (unsigned long)self.cardViews.count, (long)self.controllerRenderedGameCount, (long)self.controllerDisplayGameCount);
    if ([self preloadControllerGameIfNeededForIndex:next direction:columns]) {
        next = self.focusedCardIndex + rows * MAX(1, self.gridColumnCount) + columns;
        OPN::LogInfo(@"[CatalogView] moveFocus recalculated after edge preload next=%ld cards=%lu", (long)next, (unsigned long)self.cardViews.count);
    }
    [self focusCardAtIndex:next scrollIntoView:YES];
    [self preloadControllerNeighborForDirection:columns];
}

- (void)cycleFocusedVariant {
    if (OpnControllerModeEnabled() && self.controllerSurface == OPNControllerCatalogSurfaceHome) return;
    OPNGameCardView *card = [self focusedCard];
    if (!card || card.game.variants.size() <= 1) return;
    int next = (card.selectedVariantIndex + 1) % (int)card.game.variants.size();
    [card selectVariantAtIndex:next];
    if (OpnControllerModeEnabled()) OpnPlayConsoleTone(OPNConsoleToneChange);
    [self updateControllerDetailContent];
}

- (void)updateControllerDetailContent {
    if (!OpnControllerModeEnabled()) return;
    if (self.controllerSurface == OPNControllerCatalogSurfaceHome) {
        self.controllerDetailBackgroundView.image = nil;
        self.controllerGameHubView.hidden = YES;
        self.controllerPromptBarView.hidden = YES;
        [self stopControllerDetailBackgroundRotation];
        return;
    }
    OPNGameCardView *card = [self focusedCard];
    NSColor *detailAccentColor = OpnColor(OPNControllerAccentRGB());
    NSColor *detailAccentSoftColor = OpnColor(OPNControllerAccentSoftRGB());
    CATransition *fade = [CATransition animation];
    fade.type = kCATransitionFade;
    fade.duration = 0.18;
    fade.timingFunction = [OPNCoreAnimationCoordinator appleQuinticTimingFunction];
    [self.controllerDetailView.layer addAnimation:fade forKey:@"opn.detail.fade"];
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.32];
    [CATransaction setAnimationTimingFunction:[OPNCoreAnimationCoordinator appleQuinticTimingFunction]];
    self.controllerDetailGradientLayer.colors = @[(id)NSColor.clearColor.CGColor,
                                                   (id)NSColor.clearColor.CGColor,
                                                   (id)NSColor.clearColor.CGColor];
    self.controllerDetailGradientLayer.opacity = 0.0;
    self.controllerDetailAccentLayer.backgroundColor = [detailAccentSoftColor colorWithAlphaComponent:0.90].CGColor;
    self.controllerDetailView.layer.shadowColor = detailAccentColor.CGColor;
    [CATransaction commit];
    if (!card) {
        self.controllerDetailBackgroundView.image = nil;
        self.controllerDetailBackgroundURL = @"";
        self.controllerDetailBackgroundURLs = @[];
        self.controllerDetailBackgroundGameId = @"";
        [self stopControllerDetailBackgroundRotation];
        self.controllerDetailStatsLabel.stringValue = @"";
        self.controllerDetailFeaturesLabel.stringValue = @"";
        self.controllerGameHubView.hidden = YES;
        self.controllerPromptBarView.hidden = YES;
        return;
    }

    const OPN::GameInfo game = card.game;
    [self configureControllerDetailBackgroundForGame:game];

    NSString *genres = OPNCatalogJoinedStrings(game.genres, @"Cloud game");
    NSString *tier = OPNCatalogString(game.membershipTierLabel, @"");

    NSString *store = @"";
    if (card.selectedVariantIndex >= 0 && card.selectedVariantIndex < (int)game.variants.size()) {
        store = OPNCatalogString(game.variants[(size_t)card.selectedVariantIndex].appStore, @"");
    } else if (!game.availableStores.empty()) {
        store = OPNCatalogString(game.availableStores.front(), @"");
    }
    store = store.length > 0 ? OPNStoreCategoryTitle(store) : @"Default store";
    NSString *genreSummary = genres;
    if (tier.length > 0) genreSummary = [genreSummary stringByAppendingFormat:@"  /  %@", tier];

    self.controllerDetailStatsLabel.stringValue = @"";
    NSString *description = OPNCatalogString(game.description, @"");
    if (description.length == 0) description = OPNCatalogJoinedStrings(game.featureLabels, @"");
    if (description.length == 0) description = @"Loading game details...";
    self.controllerDetailFeaturesLabel.attributedStringValue = OPNOutlinedControllerDescriptionText(description);
    NSString *launchStatus = game.playabilityState.empty()
        ? @"Ready"
        : OPNCatalogDisplayString(game.playabilityState, @"Ready");
    NSString *developer = OPNCatalogString(game.developerName, @"");
    NSString *publisher = OPNCatalogString(game.publisherName, @"");
    NSString *studioInfo = @"Studio not listed";
    if (developer.length > 0 && publisher.length > 0 && ![developer isEqualToString:publisher]) {
        studioInfo = [NSString stringWithFormat:@"%@ / %@", developer, publisher];
    } else if (developer.length > 0) {
        studioInfo = developer;
    } else if (publisher.length > 0) {
        studioInfo = publisher;
    }
    NSString *playerInfo = OPNCatalogPlayerCountText(game.maxLocalPlayers, game.maxOnlinePlayers);
    if (playerInfo.length == 0) playerInfo = @"Player count not listed";
    NSString *controlInfo = OPNCatalogCommaJoinedStrings(game.supportedControls, 3);
    if (controlInfo.length == 0) controlInfo = OPNCatalogCommaJoinedStrings(game.featureLabels, 2);
    if (controlInfo.length == 0) controlInfo = @"Controls vary by store";
    NSString *storeInfo = OPNCatalogStoreSummary(game.availableStores, store);
    self.controllerGameHubView.gameTitle = OPNCatalogString(game.title, @"Untitled Game");
    self.controllerGameHubView.genreSummary = genreSummary;
    self.controllerGameHubView.launchStatus = launchStatus;
    self.controllerGameHubView.studioInfo = studioInfo;
    self.controllerGameHubView.playerInfo = playerInfo;
    self.controllerGameHubView.controlInfo = controlInfo;
    self.controllerGameHubView.currentStoreInfo = store;
    self.controllerGameHubView.storeInfo = storeInfo;
    self.controllerPromptBarView.hidden = YES;
    self.controllerPromptBarView.mode = OPNControllerPromptModeGame;
    self.controllerPromptBarView.includeStore = game.variants.size() > 1;
    self.controllerPromptBarView.includeCategorySwitch = self.categoryItems.count > 1;
    self.controllerPromptBarView.includeBack = NO;
}

- (void)configureControllerDetailBackgroundForGame:(const OPN::GameInfo &)game {
    NSArray<NSString *> *candidates = OPNControllerCategoryBackgroundCandidates(game);
    NSString *gameId = OPNCatalogString(game.id, @"");
    if (candidates.count == 0) {
        self.controllerDetailBackgroundView.image = nil;
        self.controllerDetailBackgroundURL = @"";
        self.controllerDetailBackgroundURLs = @[];
        self.controllerDetailBackgroundGameId = gameId;
        [self stopControllerDetailBackgroundRotation];
        return;
    }

    BOOL sameGame = [self.controllerDetailBackgroundGameId isEqualToString:gameId];
    BOOL sameCandidates = [self.controllerDetailBackgroundURLs isEqualToArray:candidates];
    if (!sameGame || !sameCandidates) {
        self.controllerDetailBackgroundGameId = gameId;
        self.controllerDetailBackgroundURLs = candidates;
        self.controllerDetailBackgroundIndex = arc4random_uniform((uint32_t)candidates.count);
        NSString *expectedURL = candidates[(NSUInteger)self.controllerDetailBackgroundIndex];
        self.controllerDetailBackgroundURL = expectedURL;
        [self loadControllerDetailBackgroundFromCandidates:candidates
                                                     index:(NSUInteger)self.controllerDetailBackgroundIndex
                                               expectedURL:expectedURL];
    }

    [self startControllerDetailBackgroundRotationIfNeeded];
}

- (void)startControllerDetailBackgroundRotationIfNeeded {
    if (!self.window || self.controllerDetailView.hidden || self.controllerDetailBackgroundURLs.count <= 1) {
        [self stopControllerDetailBackgroundRotation];
        return;
    }
    if (self.controllerDetailBackgroundTimer) return;
    self.controllerDetailBackgroundTimer = [NSTimer timerWithTimeInterval:3.0
                                                                    target:self
                                                                  selector:@selector(controllerDetailBackgroundTimerFired:)
                                                                  userInfo:nil
                                                                   repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.controllerDetailBackgroundTimer forMode:NSRunLoopCommonModes];
}

- (void)stopControllerDetailBackgroundRotation {
    [self.controllerDetailBackgroundTimer invalidate];
    self.controllerDetailBackgroundTimer = nil;
}

- (void)controllerDetailBackgroundTimerFired:(NSTimer *)timer {
    (void)timer;
    NSArray<NSString *> *candidates = self.controllerDetailBackgroundURLs;
    if (!self.window || self.controllerDetailView.hidden || candidates.count <= 1) {
        [self stopControllerDetailBackgroundRotation];
        return;
    }

    self.controllerDetailBackgroundIndex = (self.controllerDetailBackgroundIndex + 1) % (NSInteger)candidates.count;
    NSString *expectedURL = candidates[(NSUInteger)self.controllerDetailBackgroundIndex];
    self.controllerDetailBackgroundURL = expectedURL;
    [self loadControllerDetailBackgroundFromCandidates:candidates
                                                 index:(NSUInteger)self.controllerDetailBackgroundIndex
                                           expectedURL:expectedURL];
}

- (void)loadControllerDetailBackgroundFromCandidates:(NSArray<NSString *> *)candidates index:(NSUInteger)index expectedURL:(NSString *)expectedURL {
    if (index >= candidates.count || expectedURL.length == 0) return;
    __weak __typeof__(self) weakSelf = self;
    OpnImageLoadToken *token = OPNCatalogLoadImageFromCandidates(candidates, index, ^(NSImage *image, NSString *resolvedURL, NSData *data) {
        (void)resolvedURL;
        (void)data;
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf || !image || ![strongSelf.controllerDetailBackgroundURL isEqualToString:expectedURL]) return;
        CATransition *fade = [CATransition animation];
        fade.type = kCATransitionFade;
        fade.duration = 0.34;
        fade.timingFunction = [OPNCoreAnimationCoordinator appleQuinticTimingFunction];
        [strongSelf.controllerDetailBackgroundView.layer addAnimation:fade forKey:@"opn.detail.background.fade"];
        strongSelf.controllerDetailBackgroundView.image = image;
    });
    [self trackCatalogImageLoadToken:token];
}

- (void)openFocusedGameDetails {
    OPNGameCardView *card = [self focusedCard];
    if (!card) return;
    [self.detailsOverlayView removeFromSuperview];
    NSView *overlay = [[NSView alloc] initWithFrame:self.bounds];
    overlay.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    overlay.wantsLayer = YES;
    overlay.layer.backgroundColor = OpnColor(0x020304, 0.82).CGColor;

    CGFloat panelWidth = MIN(760.0, MAX(420.0, NSWidth(self.bounds) - 96.0));
    CGFloat panelHeight = 390.0;
    NSView *panel = [[OPNFlippedGridDocumentView alloc] initWithFrame:NSMakeRect(floor((NSWidth(self.bounds) - panelWidth) / 2.0),
                                                                                   floor((NSHeight(self.bounds) - panelHeight) / 2.0),
                                                                                   panelWidth,
                                                                                   panelHeight)];
    panel.wantsLayer = YES;
    panel.layer.cornerRadius = 30.0;
    panel.layer.borderWidth = 1.5;
    panel.layer.borderColor = OpnColor(0xFFFFFF, 0.22).CGColor;
    panel.layer.backgroundColor = OpnColor(0x0A0C0F, 0.98).CGColor;
    panel.layer.shadowColor = OpnColor(OPNControllerAccentRGB()).CGColor;
    panel.layer.shadowOpacity = 0.28;
    panel.layer.shadowRadius = 48.0;
    panel.layer.shadowOffset = CGSizeZero;
    [overlay addSubview:panel];

    NSString *title = OPNCatalogString(card.game.title, @"Game Details");
    NSTextField *titleLabel = OpnLabel(title, NSMakeRect(36.0, 34.0, panelWidth - 72.0, 42.0), 30.0, OpnColor(kTextPrimary), NSFontWeightSemibold);
    titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [panel addSubview:titleLabel];

    NSString *store = @"";
    if (card.selectedVariantIndex >= 0 && card.selectedVariantIndex < (int)card.game.variants.size()) {
        store = OPNCatalogString(card.game.variants[(size_t)card.selectedVariantIndex].appStore, @"");
    } else if (!card.game.availableStores.empty()) {
        store = OPNCatalogString(card.game.availableStores.front(), @"");
    }
    store = store.length > 0 ? OPNStoreCategoryTitle(store) : @"Default store";
    NSTextField *storeLabel = OpnLabel(@"",
                                       NSMakeRect(38.0, 92.0, panelWidth - 76.0, 24.0),
                                       15.0,
                                       NSColor.whiteColor,
                                       NSFontWeightSemibold);
    storeLabel.attributedStringValue = OPNOutlinedControllerStoreText([NSString stringWithFormat:@"Selected Store: %@", store]);
    [panel addSubview:storeLabel];

    NSString *body = OPNCatalogString(card.game.description, @"");
    if (body.length == 0) body = OPNCatalogJoinedStrings(card.game.featureLabels, @"");
    if (body.length == 0) body = @"Loading game details...";
    NSTextField *bodyLabel = OpnLabel(body, NSMakeRect(38.0, 136.0, panelWidth - 76.0, 112.0), 14.0, OpnColor(kTextSecondary), NSFontWeightRegular);
    bodyLabel.attributedStringValue = OPNOutlinedControllerDescriptionText(body);
    bodyLabel.maximumNumberOfLines = 6;
    [panel addSubview:bodyLabel];

    NSMutableArray<NSString *> *metadata = [NSMutableArray array];
    NSString *developer = OPNCatalogString(card.game.developerName, @"");
    NSString *publisher = OPNCatalogString(card.game.publisherName, @"");
    NSString *players = OPNCatalogPlayerCountText(card.game.maxLocalPlayers, card.game.maxOnlinePlayers);
    NSString *controls = OPNCatalogCommaJoinedStrings(card.game.supportedControls);
    NSString *ratings = OPNCatalogCommaJoinedStrings(card.game.contentRatings);
    NSString *nvidiaTech = OPNCatalogCommaJoinedStrings(card.game.nvidiaTech);
    if (developer.length > 0) [metadata addObject:[@"Developer: " stringByAppendingString:developer]];
    if (publisher.length > 0) [metadata addObject:[@"Publisher: " stringByAppendingString:publisher]];
    if (players.length > 0) [metadata addObject:[@"Players: " stringByAppendingString:players]];
    if (controls.length > 0) [metadata addObject:[@"Controls: " stringByAppendingString:controls]];
    if (ratings.length > 0) [metadata addObject:[@"Rating: " stringByAppendingString:ratings]];
    if (nvidiaTech.length > 0) [metadata addObject:[@"NVIDIA: " stringByAppendingString:nvidiaTech]];
    NSTextField *metadataLabel = OpnLabel([metadata componentsJoinedByString:@"\n"],
                                          NSMakeRect(38.0, 256.0, panelWidth - 76.0, 72.0),
                                          12.0,
                                          OpnColor(kTextMuted),
                                          NSFontWeightMedium);
    metadataLabel.maximumNumberOfLines = 4;
    [panel addSubview:metadataLabel];

    NSButton *playButton = OpnButton(@"Play", NSMakeRect(38.0, panelHeight - 96.0, 180.0, 52.0), OpnColor(OPNControllerAccentSoftRGB(), 0.96), OpnColor(OPNControllerAccentBlackRGB(0.88)));
    playButton.target = self;
    playButton.action = @selector(detailsPlayClicked:);
    playButton.layer.cornerRadius = 18.0;
    [panel addSubview:playButton];

    NSButton *closeButton = OpnButton(@"Back", NSMakeRect(232.0, panelHeight - 96.0, 132.0, 52.0), OpnColor(0xFFFFFF, 0.08), OpnColor(kTextPrimary), true, OpnColor(0xFFFFFF, 0.16));
    closeButton.target = self;
    closeButton.action = @selector(detailsCloseClicked:);
    closeButton.layer.cornerRadius = 18.0;
    [panel addSubview:closeButton];

    OPNControllerPromptBarView *hints = [[OPNControllerPromptBarView alloc] initWithFrame:NSMakeRect(38.0, panelHeight - 44.0, panelWidth - 76.0, 36.0)];
    hints.mode = OPNControllerPromptModeDetails;
    hints.includeStore = card.game.variants.size() > 1;
    hints.includeBack = YES;
    [panel addSubview:hints];

    self.detailsOverlayView = overlay;
    [self addSubview:overlay];
    [[OPNCoreAnimationCoordinator sharedCoordinator] animateCardLayer:panel.layer
                                                    metadataContainer:self.controllerDetailView
                                                      backgroundLayer:self.controllerDetailBackgroundView.layer
                                                             expanded:YES
                                                          accentColor:OpnColor(OPNControllerAccentRGB())];
}

- (void)closeGameDetails {
    [self.detailsOverlayView removeFromSuperview];
    self.detailsOverlayView = nil;
    [self.window makeFirstResponder:self];
}

- (void)launchFocusedGame {
    if (OpnControllerModeEnabled() && self.controllerSurface == OPNControllerCatalogSurfaceHome) {
        [self activateFocusedControllerHomeItem];
        return;
    }
    OPNGameCardView *card = [self focusedCard];
    if (!card || !self.onSelectGame) return;
    if (OpnControllerModeEnabled()) OpnPlayConsoleTone(OPNConsoleToneSelect);
    int variantIdx = card.selectedVariantIndex >= 0 ? card.selectedVariantIndex : 0;
    self.onSelectGame(card.game, variantIdx);
}

- (void)launchLastPlayedGame {
    const OPN::GameInfo *lastPlayedGame = [self currentLastPlayedGame];
    if (!lastPlayedGame || !self.onSelectGame) return;
    if (!OPNLibraryGameHasAccessibleVariants(*lastPlayedGame)) return;
    if (OpnControllerModeEnabled()) OpnPlayConsoleTone(OPNConsoleToneSelect);
    OPN::GameInfo libraryGame = OPNGameWithLibraryAccessibleVariants(*lastPlayedGame);
    self.onSelectGame(libraryGame, [self preferredVariantIndexForGame:libraryGame]);
}

- (void)detailsPlayClicked:(id)sender {
    (void)sender;
    [self launchFocusedGame];
}

- (void)detailsCloseClicked:(id)sender {
    (void)sender;
    [self closeGameDetails];
}

- (void)keyDown:(NSEvent *)event {
    if (!OpnControllerModeEnabled()) {
        [super keyDown:event];
        return;
    }
    NSString *chars = event.charactersIgnoringModifiers.lowercaseString ?: @"";
    switch (event.keyCode) {
        case 123: [self moveFocusByRows:0 columns:-1]; return;
        case 124: [self moveFocusByRows:0 columns:1]; return;
        case 125:
            if (self.controllerSurface == OPNControllerCatalogSurfaceHome) {
                [self moveFocusByRows:1 columns:0];
            } else {
                [self cycleFocusedVariant];
            }
            return;
        case 126: [self moveFocusByRows:-1 columns:0]; return;
        case 36:
        case 49:
            [self launchFocusedGame];
            return;
        case 53:
            if (self.controllerSurface == OPNControllerCatalogSurfaceLibrary) [self showControllerHome];
            return;
        case 48:
            if (self.controllerSurface == OPNControllerCatalogSurfaceHome) {
                [self activateFocusedControllerHomeItem];
            } else {
                [self cycleCategoryBy:1];
            }
            return;
        case 115:
            if (self.controllerSurface == OPNControllerCatalogSurfaceLibrary) [self showControllerHome];
            return;
        default:
            break;
    }
    if ([chars isEqualToString:@"y"] || [chars isEqualToString:@"f"]) {
        if (self.controllerSurface == OPNControllerCatalogSurfaceHome) return;
        [self toggleFavoriteForFocusedGame];
        return;
    }
    if ([chars isEqualToString:@"x"] || [chars isEqualToString:@"s"] || [chars isEqualToString:@"v"]) {
        if (self.controllerSurface == OPNControllerCatalogSurfaceHome) return;
        [self cycleFocusedVariant];
        return;
    }
    if ([chars isEqualToString:@"b"]) {
        if (self.controllerSurface == OPNControllerCatalogSurfaceLibrary) {
            [self showControllerHome];
        }
        return;
    }
    if ([chars isEqualToString:@"h"]) {
        [self showControllerHome];
        return;
    }
    [super keyDown:event];
}

- (void)startGamepadNavigationIfNeeded {
    if (self.controllerInputSuspended || !OpnControllerModeEnabled() || self.gamepadNavigationTimer || [GCController controllers].count == 0 || !OPNCatalogGamepadNavigationActive(self)) return;
    [self installGamepadValueHandlers];
    self.gamepadNavigationTimer = [NSTimer scheduledTimerWithTimeInterval:0.12
                                                                   target:self
                                                                 selector:@selector(pollGamepadNavigation)
                                                                 userInfo:nil
                                                                  repeats:YES];
}

- (void)installGamepadValueHandlers {
    __weak __typeof__(self) weakSelf = self;
    for (GCController *controller in [GCController controllers]) {
        GCExtendedGamepad *gamepad = controller.extendedGamepad;
        if (!gamepad) continue;
        gamepad.valueChangedHandler = ^(GCExtendedGamepad *, GCControllerElement *) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __typeof__(self) strongSelf = weakSelf;
                if (!strongSelf || !OPNCatalogGamepadNavigationActive(strongSelf)) return;
                [strongSelf pollGamepadNavigation];
            });
        };
    }
}

- (void)stopGamepadNavigation {
    [self.gamepadNavigationTimer invalidate];
    self.gamepadNavigationTimer = nil;
    self.previousGamepadButtons = 0;
    [self hideControllerStoreFilterOverlayApplyingSelection:NO];
}

- (void)controllerDidConnect:(NSNotification *)notification {
    (void)notification;
    [self startGamepadNavigationIfNeeded];
}

- (void)controllerDidDisconnect:(NSNotification *)notification {
    (void)notification;
    if ([GCController controllers].count == 0) {
        [self stopGamepadNavigation];
        return;
    }
    self.previousGamepadButtons = 0;
}

- (void)pollGamepadNavigation {
    if (self.controllerInputSuspended) {
        self.previousGamepadButtons = OPNCatalogGamepadButtons();
        return;
    }
    if (!OpnControllerModeEnabled() || [GCController controllers].count == 0 || !OPNCatalogGamepadNavigationActive(self)) {
        [self stopGamepadNavigation];
        return;
    }
    if (self.window.firstResponder != self.searchField) [self.window makeFirstResponder:self];
    uint16_t buttons = OPNCatalogGamepadButtons();
    uint16_t pressed = buttons & (uint16_t)~self.previousGamepadButtons;
    uint16_t released = self.previousGamepadButtons & (uint16_t)~buttons;
    CFTimeInterval now = CACurrentMediaTime();
    const uint16_t yButton = (1u << 2);
    if (pressed & yButton) {
        self.controllerYPressedAt = now;
        self.controllerYHoldActive = NO;
        self.controllerYConsumedByHold = NO;
    }
    const uint16_t moveMask = (1u << 5) | (1u << 6) | (1u << 7) | (1u << 8);
    uint16_t moves = buttons & moveMask;
    uint16_t pressedMoves = pressed & moveMask;
    BOOL repeatMove = (now - self.lastGamepadMoveTime) > 0.22;
    if (pressedMoves && !repeatMove) {
        pressed &= (uint16_t)~moveMask;
    } else if (moves && repeatMove) {
        pressed = (uint16_t)(pressed | moves);
        self.lastGamepadMoveTime = now;
    }
    if (self.controllerSurface == OPNControllerCatalogSurfaceLibrary && (buttons & yButton) && !self.controllerYHoldActive && !self.controllerYConsumedByHold && (now - self.controllerYPressedAt) >= 0.35) {
        self.controllerYHoldActive = YES;
        self.controllerYConsumedByHold = YES;
        [self showControllerStoreFilterOverlay];
    }
    if (self.controllerStoreFilterOverlayView) {
        if (pressed & (1u << 5)) [self moveControllerStoreFilterFocusBy:-1];
        if (pressed & (1u << 6)) [self moveControllerStoreFilterFocusBy:1];
        if (pressed & (1u << 1)) [self hideControllerStoreFilterOverlayApplyingSelection:NO];
        if (released & yButton) [self hideControllerStoreFilterOverlayApplyingSelection:YES];
        self.previousGamepadButtons = buttons;
        return;
    }
    if (self.controllerSurface == OPNControllerCatalogSurfaceLibrary && (released & yButton) && !self.controllerYConsumedByHold) [self cycleCategoryBy:1];
    if (pressed & (1u << 0)) {
        [self launchFocusedGame];
    }
    if (pressed & (1u << 1)) {
        if (self.controllerSurface == OPNControllerCatalogSurfaceLibrary) {
            [self showControllerHome];
        }
    }
    if (pressed & (1u << 3)) {
        if (self.onPreviousPageRequested) self.onPreviousPageRequested();
        self.previousGamepadButtons = buttons;
        return;
    }
    if (pressed & (1u << 4)) {
        if (self.onNextPageRequested) self.onNextPageRequested();
        self.previousGamepadButtons = buttons;
        return;
    }
    if (pressed & (1u << 5)) [self moveFocusByRows:-1 columns:0];
    if (pressed & (1u << 6)) {
        if (self.controllerSurface == OPNControllerCatalogSurfaceHome) {
            [self moveFocusByRows:1 columns:0];
        } else {
            [self cycleFocusedVariant];
        }
    }
    if (pressed & (1u << 7)) [self moveFocusByRows:0 columns:-1];
    if (pressed & (1u << 8)) [self moveFocusByRows:0 columns:1];
    if ((pressed & (1u << 9)) && self.controllerSurface == OPNControllerCatalogSurfaceLibrary) [self cycleFocusedVariant];
    self.previousGamepadButtons = buttons;
}

- (void)signOutClicked {
    if (self.onSignOut) self.onSignOut();
}

@end
