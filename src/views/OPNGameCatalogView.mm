#import "OPNGameCatalogView.h"
#import "OPNGameCardView.h"
#import "OPNLoadingView.h"
#import "../common/OPNColorTokens.h"
#import "../common/OPNCoreAnimationCoordinator.h"
#import "../common/OPNUIHelpers.h"
#include "../games/OPNGameDataCache.h"
#import "../streaming/OPNStreamPreferences.h"
#import <CoreImage/CoreImage.h>
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
static const CGFloat kControllerRailSelectorOverlap = 22.0;
static const CGFloat kControllerRailDetailOverlap = 22.0;
static const CGFloat kControllerGameHubVerticalReserve = 96.0;
static const CGFloat kControllerGameHubPreferredHeight = 430.0;
static const NSInteger kDesktopGridRenderBufferRows = 3;
static NSString *const OPNFavoriteGameIdsDefaultsKey = @"OpenNOW.Library.FavoriteGameIds";

typedef void (^OPNCatalogImageCompletion)(NSImage *image, NSString *urlString, NSData *data);

typedef NS_ENUM(NSInteger, OPNControllerHeroPrimaryAction) {
    OPNControllerHeroPrimaryActionResume = 0,
    OPNControllerHeroPrimaryActionPlay = 1,
    OPNControllerHeroPrimaryActionBuy = 2,
};

static NSCache<NSString *, NSImage *> *OPNCatalogDecodedImageCache(void) {
    static NSCache<NSString *, NSImage *> *decodedImageCache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        decodedImageCache = [[NSCache alloc] init];
        decodedImageCache.countLimit = 160;
    });
    return decodedImageCache;
}

static NSCache<NSString *, NSData *> *OPNCatalogImageDataCache(void) {
    static NSCache<NSString *, NSData *> *imageDataCache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        imageDataCache = [[NSCache alloc] init];
        imageDataCache.countLimit = 160;
        imageDataCache.totalCostLimit = 96 * 1024 * 1024;
    });
    return imageDataCache;
}

static NSURLSession *OPNCatalogImageSession(void) {
    static NSURLSession *session;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        configuration.HTTPMaximumConnectionsPerHost = 6;
        configuration.requestCachePolicy = NSURLRequestReturnCacheDataElseLoad;
        configuration.timeoutIntervalForRequest = 15.0;
        configuration.URLCache = [NSURLCache sharedURLCache];
        session = [NSURLSession sessionWithConfiguration:configuration];
    });
    return session;
}

static NSMutableDictionary<NSString *, NSMutableArray<OPNCatalogImageCompletion> *> *OPNCatalogPendingImageCompletions(void) {
    static NSMutableDictionary<NSString *, NSMutableArray<OPNCatalogImageCompletion> *> *pendingCompletions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pendingCompletions = [NSMutableDictionary dictionary];
    });
    return pendingCompletions;
}

static void OPNCatalogCompleteImageRequest(NSString *urlString, NSImage *image, NSData *data) {
    NSCache<NSString *, NSImage *> *decodedImageCache = OPNCatalogDecodedImageCache();
    NSCache<NSString *, NSData *> *imageDataCache = OPNCatalogImageDataCache();
    NSMutableDictionary<NSString *, NSMutableArray<OPNCatalogImageCompletion> *> *pendingCompletions = OPNCatalogPendingImageCompletions();

    NSArray<OPNCatalogImageCompletion> *completions = nil;
    @synchronized (pendingCompletions) {
        if (image) [decodedImageCache setObject:image forKey:urlString];
        if (data.length > 0) [imageDataCache setObject:data forKey:urlString cost:data.length];
        completions = [pendingCompletions[urlString] copy];
        [pendingCompletions removeObjectForKey:urlString];
    }
    if (image && data.length > 0) OPN::GameDataCache::Shared().SaveImage(urlString, data);
    dispatch_async(dispatch_get_main_queue(), ^{
        for (OPNCatalogImageCompletion completion in completions) completion(image, urlString, data);
    });
}

static void OPNCatalogLoadImageForURL(NSString *urlString, OPNCatalogImageCompletion completion) {
    if (urlString.length == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, nil, nil); });
        return;
    }

    NSCache<NSString *, NSImage *> *decodedImageCache = OPNCatalogDecodedImageCache();
    NSMutableDictionary<NSString *, NSMutableArray<OPNCatalogImageCompletion> *> *pendingCompletions = OPNCatalogPendingImageCompletions();

    NSImage *cachedImage = [decodedImageCache objectForKey:urlString];
    if (cachedImage) {
        NSData *cachedData = [OPNCatalogImageDataCache() objectForKey:urlString];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(cachedImage, urlString, cachedData); });
        return;
    }

    @synchronized (pendingCompletions) {
        NSMutableArray<OPNCatalogImageCompletion> *existing = pendingCompletions[urlString];
        if (existing) {
            [existing addObject:[completion copy]];
            return;
        }
        pendingCompletions[urlString] = [NSMutableArray arrayWithObject:[completion copy]];
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSData *cachedData = OPN::GameDataCache::Shared().LoadImage(urlString);
        if (cachedData.length > 0) {
            NSImage *image = [[NSImage alloc] initWithData:cachedData];
            if (image) {
                OPNCatalogCompleteImageRequest(urlString, image, cachedData);
                return;
            }
        }

        NSURL *url = [NSURL URLWithString:urlString];
        if (!url) {
            OPNCatalogCompleteImageRequest(urlString, nil, nil);
            return;
        }

        [[OPNCatalogImageSession() dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
            if (error || data.length == 0 || (http && http.statusCode >= 400)) {
                OPNCatalogCompleteImageRequest(urlString, nil, nil);
                return;
            }
            NSImage *image = [[NSImage alloc] initWithData:data];
            OPNCatalogCompleteImageRequest(urlString, image, image ? data : nil);
        }] resume];
    });
}

static void OPNCatalogLoadImageFromCandidates(NSArray<NSString *> *candidates, NSUInteger index, OPNCatalogImageCompletion completion) {
    if (index >= candidates.count) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, nil, nil); });
        return;
    }
    NSString *candidate = candidates[index];
    OPNCatalogLoadImageForURL(candidate, ^(NSImage *image, NSString *resolvedURL, NSData *data) {
        if (image) {
            completion(image, resolvedURL, data);
            return;
        }
        OPNCatalogLoadImageFromCandidates(candidates, index + 1, completion);
    });
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
    CGFloat topInset = safeHeight * (120.0 / 720.0);
    CGFloat bottomInset = safeHeight * (72.0 / 720.0);
    CGFloat contentInset = safeWidth * (52.0 / 1280.0);
    CGFloat heroY = safeHeight * (2.0 / 720.0);
    CGFloat heroHeight = safeHeight * (280.0 / 720.0);
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
@class OPNControllerCategoryCardView;

typedef NS_ENUM(NSInteger, OPNControllerPromptMode) {
    OPNControllerPromptModeHome = 0,
    OPNControllerPromptModeGame = 1,
    OPNControllerPromptModeDetails = 2,
};

typedef NS_ENUM(NSInteger, OPNControllerOverviewSpecialTileKind) {
    OPNControllerOverviewSpecialTileNone = 0,
    OPNControllerOverviewSpecialTileLastPlayed = 1,
};

typedef struct {
    NSInteger count;
    std::vector<OPN::GameInfo> thumbnails;
} OPNCategorySample;

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
@property (nonatomic, strong) NSTextField *controllerHomeEyebrowLabel;
@property (nonatomic, strong) NSTextField *controllerHomeTitleLabel;
@property (nonatomic, strong) NSTextField *controllerHomeSubtitleLabel;
@property (nonatomic, strong) NSTextField *controllerSectionLabel;
@property (nonatomic, strong) NSView *controllerLibraryRailView;
@property (nonatomic, strong) NSMutableArray<NSView *> *controllerHeroViews;
@property (nonatomic, strong) NSView *lastPlayedPanelView;
@property (nonatomic, strong) NSImageView *lastPlayedImageView;
@property (nonatomic, strong) NSTextField *lastPlayedEyebrowLabel;
@property (nonatomic, strong) NSTextField *lastPlayedTitleLabel;
@property (nonatomic, strong) NSTextField *lastPlayedMetaLabel;
@property (nonatomic, strong) NSTextField *lastPlayedHintLabel;
@property (nonatomic, copy) NSString *lastPlayedImageURL;
@property (nonatomic, assign, getter=isLastPlayedFocused) BOOL lastPlayedFocused;
@property (nonatomic, assign) CGFloat lastPlayedImageAspectRatio;
@property (nonatomic, strong) CAGradientLayer *controllerDetailGradientLayer;
@property (nonatomic, strong) CALayer *controllerDetailAccentLayer;
@property (nonatomic, strong) NSMutableArray<OPNGameCardView *> *cardViews;
@property (nonatomic, strong) NSMutableArray<OPNControllerCategoryCardView *> *categoryCardViews;
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
@property (nonatomic, assign) NSInteger focusedCategoryIndex;
@property (nonatomic, assign) OPNControllerOverviewSpecialTileKind controllerOverviewSpecialTileKind;
@property (nonatomic, assign) BOOL controllerCategoryOverviewVisible;
@property (nonatomic, assign) NSInteger controllerRenderedGameCount;
@property (nonatomic, assign) NSInteger controllerDisplayGameCount;
@property (nonatomic, assign) NSInteger desktopRenderedGameCount;
@property (nonatomic, assign) NSInteger desktopDisplayGameCount;
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
- (void)scrollLibraryToTop;
- (void)requestCatalogBrowse;
- (void)rebuildCategoryBar;
- (NSString *)activeCategoryTitle;
- (BOOL)game:(const OPN::GameInfo &)game matchesCategory:(NSString *)categoryId;
- (void)cycleCategoryBy:(NSInteger)delta;
- (NSInteger)gameCountForCategory:(NSString *)categoryId;
- (std::vector<OPN::GameInfo>)gamesForCategory:(NSString *)categoryId limit:(NSInteger)limit;
- (OPNCategorySample)sampleForCategory:(NSString *)categoryId limit:(NSInteger)limit;
- (const OPN::GameInfo *)currentLastPlayedGame;
- (int)preferredVariantIndexForGame:(const OPN::GameInfo &)game;
- (void)renderControllerCategoryOverview;
- (void)renderControllerLibrary;
- (void)renderControllerHero;
- (void)renderControllerHeroAnimated:(BOOL)animated;
- (void)renderControllerLibraryRail;
- (void)scrollControllerLibraryRailToCardAtIndex:(NSInteger)index animated:(BOOL)animated;
- (void)addControllerHeroForGame:(const OPN::GameInfo &)game frame:(NSRect)frame activeIndex:(NSInteger)activeIndex totalCount:(NSInteger)totalCount;
- (void)animateControllerHeroIncomingViews:(NSArray<NSView *> *)incomingViews outgoingViews:(NSArray<NSView *> *)outgoingViews frame:(NSRect)frame;
- (void)loadControllerHeroImageForView:(OPNControllerPreviewBackgroundView *)view candidates:(NSArray<NSString *> *)candidates index:(NSUInteger)index;
- (std::vector<OPN::GameInfo>)controllerFeaturedGamesFromDisplayGames:(const std::vector<OPN::GameInfo> &)displayGames;
- (const OPN::GameInfo *)currentControllerHeroGame;
- (OPNControllerHeroPrimaryAction)primaryActionForHeroGame:(const OPN::GameInfo &)game;
- (void)startControllerHeroRotationIfNeeded;
- (void)stopControllerHeroRotation;
- (void)controllerHeroRotationTimerFired:(NSTimer *)timer;
- (void)controllerHeroResumeClicked:(id)sender;
- (void)controllerHeroMoreInfoClicked:(id)sender;
- (void)updateLastPlayedPanel;
- (void)loadLastPlayedImageFromCandidates:(NSArray<NSString *> *)candidates index:(NSUInteger)index expectedURL:(NSString *)expectedURL;
- (void)loadControllerHeroLogoForView:(NSImageView *)view candidates:(NSArray<NSString *> *)candidates index:(NSUInteger)index;
- (void)focusCategoryAtIndex:(NSInteger)index scrollIntoView:(BOOL)scrollIntoView;
- (NSInteger)controllerOverviewItemCount;
- (NSInteger)controllerOverviewCategoryOffset;
- (NSView *)controllerOverviewViewAtIndex:(NSInteger)index;
- (void)moveCategoryFocusByRows:(NSInteger)rows columns:(NSInteger)columns;
- (void)openFocusedCategory;
- (void)returnToControllerCategoryOverview;
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
- (void)setLastPlayedFocused:(BOOL)focused;
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

static bool OPNGameIsOwned(const OPN::GameInfo &game) {
    if (game.isInLibrary) return true;
    for (const OPN::GameVariant &variant : game.variants) {
        if (variant.librarySelected || variant.inLibrary || OPNGameVariantStatusIsOwned(variant.serviceStatus)) return true;
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

@interface OPNControllerCategoryCardView : NSView
@property (nonatomic, copy) NSString *categoryId;
@property (nonatomic, copy) NSString *categoryTitle;
@property (nonatomic, assign) NSInteger gameCount;
@property (nonatomic, assign, getter=isControllerFocused) BOOL controllerFocused;
@property (nonatomic, copy) void (^onSelect)(void);
- (instancetype)initWithFrame:(NSRect)frame title:(NSString *)title categoryId:(NSString *)categoryId gameCount:(NSInteger)gameCount games:(const std::vector<OPN::GameInfo> &)games;
@end

@interface OPNControllerCategoryCardView ()
@property (nonatomic, strong) NSMutableArray<NSImageView *> *thumbnailViews;
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSTextField *countLabel;
@property (nonatomic, strong) NSTextField *kindLabel;
@property (nonatomic, strong) NSTrackingArea *trackingArea;
@end

@implementation OPNControllerCategoryCardView

- (instancetype)initWithFrame:(NSRect)frame title:(NSString *)title categoryId:(NSString *)categoryId gameCount:(NSInteger)gameCount games:(const std::vector<OPN::GameInfo> &)games {
    self = [super initWithFrame:frame];
    if (self) {
        _categoryTitle = [title copy] ?: @"Category";
        _categoryId = [categoryId copy] ?: @"all";
        _gameCount = gameCount;
        _thumbnailViews = [NSMutableArray arrayWithCapacity:6];
        self.wantsLayer = YES;
        self.layer.cornerRadius = 16.0;
        self.layer.masksToBounds = NO;
        self.layer.backgroundColor = OpnColor(OPNControllerAccentBlackRGB(0.90), 0.76).CGColor;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = OpnColor(0xFFFFFF, 0.12).CGColor;
        self.layer.shadowColor = NSColor.blackColor.CGColor;
        self.layer.shadowOpacity = 0.24;
        self.layer.shadowRadius = 16.0;
        self.layer.shadowOffset = CGSizeMake(0.0, 10.0);

        for (NSInteger i = 0; i < 6; i++) {
            NSImageView *thumbnail = [[NSImageView alloc] initWithFrame:NSZeroRect];
            thumbnail.imageScaling = NSImageScaleProportionallyUpOrDown;
            thumbnail.wantsLayer = YES;
            thumbnail.layer.cornerRadius = 6.0;
            thumbnail.layer.masksToBounds = YES;
            thumbnail.layer.backgroundColor = OpnColor(OPNControllerAccentBlackRGB(0.82), 0.78).CGColor;
            thumbnail.layer.borderWidth = 1.0;
            thumbnail.layer.borderColor = OpnColor(0xFFFFFF, 0.11).CGColor;
            [self addSubview:thumbnail];
            [self.thumbnailViews addObject:thumbnail];
        }

        _titleLabel = OpnLabel(_categoryTitle, NSZeroRect, 15.0, OpnColor(OPN::kTextPrimary), NSFontWeightBold);
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self addSubview:_titleLabel];

        NSString *countText = [_categoryId hasPrefix:@"system:"] ? @"Open" : [NSString stringWithFormat:@"%ld", (long)_gameCount];
        _countLabel = OpnLabel(countText, NSZeroRect, 12.0, OpnColor(OPN::kTextSecondary), NSFontWeightSemibold, NSTextAlignmentCenter);
        _countLabel.wantsLayer = YES;
        _countLabel.layer.cornerRadius = 11.0;
        _countLabel.layer.backgroundColor = OpnColor(0xFFFFFF, 0.070).CGColor;
        _countLabel.layer.borderWidth = 1.0;
        _countLabel.layer.borderColor = OpnColor(0xFFFFFF, 0.13).CGColor;
        [self addSubview:_countLabel];

        NSString *kindText = [_categoryId isEqualToString:@"system:exit"] ? @"EXIT" : ([_categoryId isEqualToString:@"system:restart"] ? @"RESTART" : ([_categoryId hasPrefix:@"system:"] ? @"SETTINGS" : @"STORE"));
        _kindLabel = OpnLabel(kindText, NSZeroRect, 10.0, OpnColor(OPN::kBrandGreen), NSFontWeightBold, NSTextAlignmentCenter);
        _kindLabel.hidden = ![_categoryId hasPrefix:@"store:"] && ![_categoryId hasPrefix:@"system:"];
        _kindLabel.wantsLayer = YES;
        _kindLabel.layer.cornerRadius = 9.0;
        _kindLabel.layer.backgroundColor = OpnColor(OPN::kBrandGreen, 0.12).CGColor;
        _kindLabel.layer.borderWidth = 1.0;
        _kindLabel.layer.borderColor = OpnColor(OPN::kBrandGreen, 0.26).CGColor;
        [self addSubview:_kindLabel];

        [self loadThumbnailsFromGames:games];
        [self updateTrackingAreas];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)setControllerFocused:(BOOL)controllerFocused {
    if (_controllerFocused == controllerFocused) return;
    _controllerFocused = controllerFocused;
    [self applyFocusStyle];
}

- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds);
    CGFloat thumbWidth = floor((width - 42.0) / 3.0);
    CGFloat thumbHeight = floor(thumbWidth * 9.0 / 16.0);
    CGFloat startX = 16.0;
    CGFloat startY = 14.0;
    for (NSUInteger i = 0; i < self.thumbnailViews.count; i++) {
        NSInteger column = (NSInteger)i % 3;
        NSInteger row = (NSInteger)i / 3;
        self.thumbnailViews[i].frame = NSMakeRect(startX + column * (thumbWidth + 5.0), startY + row * (thumbHeight + 6.0), thumbWidth, thumbHeight);
    }
    CGFloat labelY = startY + thumbHeight * 2.0 + 18.0;
    self.titleLabel.frame = NSMakeRect(16.0, labelY, width - 32.0, 22.0);
    CGFloat countWidth = [self.categoryId hasPrefix:@"system:"] ? 58.0 : 42.0;
    self.countLabel.frame = NSMakeRect(16.0, labelY + 28.0, countWidth, 22.0);
    self.kindLabel.frame = NSMakeRect(width - 72.0, labelY + 30.0, 56.0, 18.0);
}

- (void)mouseDown:(NSEvent *)event {
    (void)event;
    if (self.onSelect) self.onSelect();
}

- (void)mouseEntered:(NSEvent *)event {
    (void)event;
    if (!self.controllerFocused) self.layer.borderColor = OpnColor(0xFFFFFF, 0.22).CGColor;
}

- (void)mouseExited:(NSEvent *)event {
    (void)event;
    if (!self.controllerFocused) self.layer.borderColor = OpnColor(0xFFFFFF, 0.12).CGColor;
}

- (void)updateTrackingAreas {
    if (self.trackingArea && [self.trackingAreas containsObject:self.trackingArea]) {
        [self removeTrackingArea:self.trackingArea];
    }
    self.trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                     options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInActiveApp
                                                       owner:self
                                                    userInfo:nil];
    [self addTrackingArea:self.trackingArea];
}

- (void)applyFocusStyle {
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.20];
    [CATransaction setAnimationTimingFunction:[OPNCoreAnimationCoordinator appleQuinticTimingFunction]];
    self.layer.zPosition = self.controllerFocused ? 24.0 : 0.0;
    self.layer.borderWidth = self.controllerFocused ? 3.0 : 1.0;
    self.layer.borderColor = (self.controllerFocused ? OpnColor(0xFFFFFF, 0.94) : OpnColor(0xFFFFFF, 0.12)).CGColor;
    self.layer.shadowColor = (self.controllerFocused ? OpnColor(OPNControllerAccentSoftRGB()) : NSColor.blackColor).CGColor;
    self.layer.shadowOpacity = self.controllerFocused ? 0.42 : 0.24;
    self.layer.shadowRadius = self.controllerFocused ? 26.0 : 16.0;
    CATransform3D transform = CATransform3DIdentity;
    if (self.controllerFocused) transform = CATransform3DScale(transform, 1.045, 1.045, 1.0);
    self.layer.transform = transform;
    self.countLabel.textColor = self.controllerFocused ? OpnColor(OPNControllerAccentBlackRGB(0.88)) : OpnColor(OPN::kTextSecondary);
    self.countLabel.layer.backgroundColor = (self.controllerFocused ? OpnColor(OPNControllerAccentSoftRGB(), 0.92) : OpnColor(0xFFFFFF, 0.070)).CGColor;
    [CATransaction commit];
}

- (void)loadThumbnailsFromGames:(const std::vector<OPN::GameInfo> &)games {
    NSInteger thumbnailIndex = 0;
    for (const OPN::GameInfo &game : games) {
        if (thumbnailIndex >= (NSInteger)self.thumbnailViews.count) break;
        NSArray<NSString *> *candidates = OPNControllerCategoryArtworkCandidates(game);
        if (candidates.count == 0) continue;
        [self loadImageForThumbnail:self.thumbnailViews[(NSUInteger)thumbnailIndex] candidates:candidates index:0];
        thumbnailIndex++;
    }
}

- (void)loadImageForThumbnail:(NSImageView *)thumbnail candidates:(NSArray<NSString *> *)candidates index:(NSUInteger)index {
    __weak NSImageView *weakThumbnail = thumbnail;
    OPNCatalogLoadImageFromCandidates(candidates, index, ^(NSImage *image, NSString *resolvedURL, NSData *data) {
        (void)resolvedURL;
        (void)data;
        NSImageView *strongThumbnail = weakThumbnail;
        if (strongThumbnail && image) strongThumbnail.image = image;
    });
}

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
        _categoryCardViews = [NSMutableArray array];
        _controllerHeroViews = [NSMutableArray array];
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
        _focusedCategoryIndex = 0;
        _controllerOverviewSpecialTileKind = OPNControllerOverviewSpecialTileNone;
        _controllerCategoryOverviewVisible = YES;
        _controllerRenderedGameCount = 0;
        _controllerDisplayGameCount = 0;
        _controllerLibraryRailContentWidth = 0.0;
        _controllerLibraryRailOffsetX = 0.0;
        _controllerLibraryWindowStartIndex = 0;
        _controllerLibraryVisibleStartIndex = 0;
        _controllerHeroIndex = 0;
        _controllerHeroImageAspectRatio = 16.0 / 9.0;
        _focusedControllerStoreFilterIndex = 0;
        _lastPlayedImageAspectRatio = 16.0 / 9.0;
        _gridColumnCount = 1;
        self.wantsLayer = YES;
        self.layer.opaque = NO;
        self.layer.backgroundColor = [NSColor clearColor].CGColor;

        _controllerDetailBackgroundView = [[OPNControllerPreviewBackgroundView alloc] initWithFrame:self.bounds];
        _controllerDetailBackgroundView.hidden = YES;
        _controllerDetailBackgroundView.wantsLayer = YES;
        _controllerDetailBackgroundView.layer.masksToBounds = YES;
        CIFilter *detailBackgroundBlur = [CIFilter filterWithName:@"CIGaussianBlur"];
        [detailBackgroundBlur setValue:@8.4 forKey:kCIInputRadiusKey];
        _controllerDetailBackgroundView.layer.filters = @[detailBackgroundBlur];
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

        _controllerHomeEyebrowLabel = OpnLabel(@"CONSOLE HOME", NSZeroRect, 12.0, OpnColor(kBrandGreen), NSFontWeightBold);
        _controllerHomeEyebrowLabel.hidden = YES;
        [self addSubview:_controllerHomeEyebrowLabel];

        _controllerHomeTitleLabel = OpnLabel(@"OpenNOW Home", NSZeroRect, 42.0, OpnColor(kTextPrimary), NSFontWeightBold);
        _controllerHomeTitleLabel.hidden = YES;
        [self addSubview:_controllerHomeTitleLabel];

        _controllerHomeSubtitleLabel = OpnLabel(@"Continue playing, jump into favorites, or browse your library by category.", NSZeroRect, 16.0, OpnColor(kTextSecondary), NSFontWeightMedium);
        _controllerHomeSubtitleLabel.hidden = YES;
        [self addSubview:_controllerHomeSubtitleLabel];

        _controllerSectionLabel = OpnLabel(@"", NSZeroRect, 18.0, OpnColor(kTextPrimary), NSFontWeightBold);
        _controllerSectionLabel.hidden = YES;
        [self addSubview:_controllerSectionLabel];

        _lastPlayedPanelView = [[NSView alloc] initWithFrame:NSZeroRect];
        _lastPlayedPanelView.hidden = YES;
        _lastPlayedPanelView.wantsLayer = YES;
        _lastPlayedPanelView.layer.cornerRadius = 22.0;
        _lastPlayedPanelView.layer.masksToBounds = NO;
        _lastPlayedPanelView.layer.backgroundColor = OpnColor(OPNControllerAccentBlackRGB(0.90), 0.78).CGColor;
        _lastPlayedPanelView.layer.borderWidth = 1.0;
        _lastPlayedPanelView.layer.borderColor = OpnColor(0xFFFFFF, 0.16).CGColor;
        _lastPlayedPanelView.layer.shadowColor = NSColor.blackColor.CGColor;
        _lastPlayedPanelView.layer.shadowOpacity = 0.30;
        _lastPlayedPanelView.layer.shadowRadius = 24.0;
        _lastPlayedPanelView.layer.shadowOffset = CGSizeMake(0.0, 12.0);

        _lastPlayedImageView = [[NSImageView alloc] initWithFrame:NSZeroRect];
        _lastPlayedImageView.imageScaling = NSImageScaleProportionallyUpOrDown;
        _lastPlayedImageView.wantsLayer = YES;
        _lastPlayedImageView.layer.cornerRadius = 16.0;
        _lastPlayedImageView.layer.masksToBounds = YES;
        _lastPlayedImageView.layer.backgroundColor = OpnColor(OPNControllerAccentBlackRGB(0.82), 0.86).CGColor;
        [_lastPlayedPanelView addSubview:_lastPlayedImageView];

        _lastPlayedEyebrowLabel = OpnLabel(@"LAST PLAYED", NSZeroRect, 11.0, OpnColor(kBrandGreen), NSFontWeightBold);
        [_lastPlayedPanelView addSubview:_lastPlayedEyebrowLabel];

        _lastPlayedTitleLabel = OpnLabel(@"", NSZeroRect, 21.0, OpnColor(kTextPrimary), NSFontWeightBold);
        _lastPlayedTitleLabel.maximumNumberOfLines = 2;
        _lastPlayedTitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [_lastPlayedPanelView addSubview:_lastPlayedTitleLabel];

        _lastPlayedMetaLabel = OpnLabel(@"", NSZeroRect, 12.0, OpnColor(kTextSecondary), NSFontWeightSemibold);
        _lastPlayedMetaLabel.maximumNumberOfLines = 2;
        [_lastPlayedPanelView addSubview:_lastPlayedMetaLabel];

        _lastPlayedHintLabel = OpnLabel(@"Press A to play again", NSZeroRect, 12.0, OpnColor(kTextSecondary), NSFontWeightMedium, NSTextAlignmentRight);
        [_lastPlayedPanelView addSubview:_lastPlayedHintLabel];
        [self addSubview:_lastPlayedPanelView];

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
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopGamepadNavigation];
    [self stopControllerDetailBackgroundRotation];
    [self stopControllerHeroRotation];
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
    if (OpnControllerModeEnabled() && !self.controllerCategoryOverviewVisible) {
        [self renderControllerHero];
        [self startControllerHeroRotationIfNeeded];
    }
}

- (void)setActiveSessionAppIds:(const std::vector<int> &)appIds {
    _activeSessionAppIds = appIds;
    if (OpnControllerModeEnabled() && !self.controllerCategoryOverviewVisible) [self renderControllerHero];
}

- (void)rebuildCategoryBar {
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *items = [NSMutableArray array];
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

- (std::vector<OPN::GameInfo>)gamesForCategory:(NSString *)categoryId limit:(NSInteger)limit {
    std::vector<OPN::GameInfo> games;
    std::vector<OPN::GameInfo> matchingGames;
    if (limit <= 0) return games;
    for (const OPN::GameInfo &game : self.allGames) {
        if (![self game:game matchesCategory:categoryId]) continue;
        matchingGames.push_back(game);
    }

    std::stable_sort(matchingGames.begin(), matchingGames.end(), [](const OPN::GameInfo &lhs, const OPN::GameInfo &rhs) {
        if (lhs.isInLibrary != rhs.isInLibrary) return lhs.isInLibrary;
        return false;
    });

    NSInteger thumbnailCount = MIN(limit, (NSInteger)matchingGames.size());
    for (NSInteger i = 0; i < thumbnailCount; i++) {
        games.push_back(matchingGames[(size_t)i]);
    }
    return games;
}

- (OPNCategorySample)sampleForCategory:(NSString *)categoryId limit:(NSInteger)limit {
    OPNCategorySample sample = {0, {}};
    std::vector<OPN::GameInfo> libraryThumbnails;
    std::vector<OPN::GameInfo> otherThumbnails;
    NSInteger thumbnailLimit = MAX(0, limit);
    for (const OPN::GameInfo &game : self.allGames) {
        if (![self game:game matchesCategory:categoryId]) continue;
        sample.count++;
        if (game.isInLibrary) {
            if ((NSInteger)libraryThumbnails.size() < thumbnailLimit) libraryThumbnails.push_back(game);
        } else {
            if ((NSInteger)otherThumbnails.size() < thumbnailLimit) otherThumbnails.push_back(game);
        }
    }
    for (const OPN::GameInfo &game : libraryThumbnails) {
        if ((NSInteger)sample.thumbnails.size() >= thumbnailLimit) return sample;
        sample.thumbnails.push_back(game);
    }
    for (const OPN::GameInfo &game : otherThumbnails) {
        if ((NSInteger)sample.thumbnails.size() >= thumbnailLimit) return sample;
        sample.thumbnails.push_back(game);
    }
    return sample;
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
    BOOL categoryFiltered = self.selectedCategoryId.length > 0 && ![self.selectedCategoryId isEqualToString:@"all"] && ![self.selectedCategoryId isEqualToString:@"library"];
    for (const OPN::GameInfo &game : _allGames) {
        if (!game.isInLibrary) continue;
        if (categoryFiltered && ![self game:game matchesCategory:self.selectedCategoryId]) continue;
        displayGames.push_back(game);
    }
    if (displayGames.empty() && !categoryFiltered) {
        for (const OPN::GameInfo &game : _allGames) {
            if ([self game:game matchesCategory:self.selectedCategoryId]) displayGames.push_back(game);
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
    OPN::LogInfo(@"[CatalogView] renderGrid begin controller=%d overview=%d category=%@ allGames=%lu renderedLimit=%ld focused=%ld", OpnControllerModeEnabled(), self.controllerCategoryOverviewVisible, self.selectedCategoryId, (unsigned long)self.allGames.size(), (long)self.controllerRenderedGameCount, (long)self.focusedCardIndex);
    NSArray<OPNGameCardView *> *reusableCards = [self.cardViews copy];
    NSUInteger reusableCardIndex = 0;
    for (NSView *view in [self.gridContentView.subviews copy]) { [view removeFromSuperview]; }
    [_cardViews removeAllObjects];
    [self.categoryCardViews removeAllObjects];

    BOOL controllerMode = OpnControllerModeEnabled();
    if (controllerMode) {
        [self renderControllerLibrary];
        return;
    }

    CGFloat cardWidth = [OPNGameCardView cardSize].width;
    CGFloat cardHeight = [OPNGameCardView cardSize].height;
    CGFloat availableWidth = _scrollView.frame.size.width;
    NSInteger cols = controllerMode ? 1 : MAX(1, (NSInteger)((availableWidth + kCardSpacing) / (cardWidth + kCardSpacing)));
    self.gridColumnCount = cols;
    CGFloat gridSpacing = controllerMode ? 26.0 : (cols > 1 ? floor((availableWidth - cols * cardWidth) / (cols - 1)) : kCardSpacing);
    gridSpacing = MAX(kCardSpacing, gridSpacing);
    CGFloat xStart = controllerMode ? 64.0 : (cols > 1 ? 0.0 : floor(MAX(0.0, (_scrollView.frame.size.width - cardWidth) / 2.0)));
    CGFloat yPos = controllerMode ? 34.0 + kControllerRailSelectorOverlap : kGridPadding;

    std::vector<OPN::GameInfo> displayGames;
    for (const OPN::GameInfo &game : _allGames) {
        if ([self game:game matchesCategory:self.selectedCategoryId]) displayGames.push_back(game);
    }
    self.controllerDisplayGameCount = controllerMode ? (NSInteger)displayGames.size() : 0;
    NSInteger renderLimit = (NSInteger)displayGames.size();
    if (controllerMode) {
        if (self.controllerRenderedGameCount <= 0) self.controllerRenderedGameCount = [self controllerInitialRenderedGameCount];
        renderLimit = MIN((NSInteger)displayGames.size(), MAX([self controllerInitialRenderedGameCount], self.controllerRenderedGameCount));
        OPN::LogInfo(@"[CatalogView] controller render window category=%@ display=%lu initial=%ld renderLimit=%ld scrollWidth=%.1f", self.selectedCategoryId, (unsigned long)displayGames.size(), (long)[self controllerInitialRenderedGameCount], (long)renderLimit, NSWidth(self.scrollView.frame));
    } else {
        self.desktopDisplayGameCount = (NSInteger)displayGames.size();
        NSInteger initialRenderCount = [self desktopInitialRenderedGameCountForColumns:cols];
        if (self.desktopRenderedGameCount <= 0) self.desktopRenderedGameCount = initialRenderCount;
        renderLimit = MIN((NSInteger)displayGames.size(), MAX(initialRenderCount, self.desktopRenderedGameCount));
    }

    NSInteger col = 0;
    NSInteger visibleCount = 0;
    for (auto it = displayGames.begin(); it != displayGames.end(); ++it) {
        if (visibleCount >= renderLimit) break;
        auto &game = *it;
        CGFloat x = controllerMode ? xStart + visibleCount * (cardWidth + gridSpacing) : xStart + col * (cardWidth + gridSpacing);
        NSRect cardFrame = NSMakeRect(x, yPos, cardWidth, cardHeight);
        OPNGameCardView *card = reusableCardIndex < reusableCards.count ? reusableCards[reusableCardIndex++] : nil;
        if (card) {
            card.frame = cardFrame;
            [card updateGame:game];
        } else {
            card = [[OPNGameCardView alloc] initWithFrame:cardFrame game:game];
            OPN::LogInfo(@"[CatalogView] create card index=%ld title=%@ id=%@ uuid=%@ desc=%d features=%lu image=%d hero=%d variants=%lu", (long)visibleCount, OPNCatalogString(game.title, @"<untitled>"), OPNCatalogString(game.id, @""), OPNCatalogString(game.uuid, @""), !game.description.empty(), (unsigned long)game.featureLabels.size(), !game.imageUrl.empty(), !game.heroImageUrl.empty(), (unsigned long)game.variants.size());
        }
        GameInfo gameCopy = game;
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
        [_gridContentView addSubview:card];
        [_cardViews addObject:card];

        col++;
        visibleCount++;
        if (!controllerMode && col >= cols) {
            col = 0;
            yPos += cardHeight + kCardSpacing;
        }
    }

    CGFloat totalHeight = controllerMode ? cardHeight + 104.0 : yPos + cardHeight + kGridPadding;
    if (!controllerMode) {
        NSInteger totalRows = displayGames.empty() ? 0 : (NSInteger)ceil((double)displayGames.size() / MAX(1.0, (double)cols));
        totalHeight = totalRows > 0 ? kGridPadding + totalRows * cardHeight + MAX(0, totalRows - 1) * kCardSpacing + kGridPadding : _scrollView.frame.size.height;
    }
    CGFloat totalWidth = controllerMode
        ? xStart * 2.0 + visibleCount * cardWidth + MAX(0, visibleCount - 1) * gridSpacing
        : _scrollView.frame.size.width;
    _gridContentView.frame = NSMakeRect(0, 0,
        MAX(totalWidth, _scrollView.frame.size.width),
        MAX(totalHeight, _scrollView.frame.size.height));

    NSInteger totalVisibleCount = (NSInteger)displayGames.size();
    _gameCountLabel.stringValue = [NSString stringWithFormat:@"%ld %@", (long)totalVisibleCount, totalVisibleCount == 1 ? @"game" : @"games"];
    if (self.onGameCountChanged) self.onGameCountChanged(totalVisibleCount);
    _statusLabel.stringValue = totalVisibleCount == 0 ? @"No games found." : @"";
    if (self.focusedCardIndex >= (NSInteger)self.cardViews.count) self.focusedCardIndex = (NSInteger)self.cardViews.count - 1;
    if (self.focusedCardIndex < 0 && self.cardViews.count > 0) self.focusedCardIndex = 0;
    [self focusCardAtIndex:self.focusedCardIndex scrollIntoView:NO];
    [self updateControllerDetailContent];
    [self layoutCatalogSubviews];
    OPN::LogInfo(@"[CatalogView] renderGrid end cards=%lu totalDisplay=%ld contentWidth=%.1f focused=%ld", (unsigned long)self.cardViews.count, (long)totalVisibleCount, NSWidth(self.gridContentView.frame), (long)self.focusedCardIndex);
}

- (void)renderControllerCategoryOverview {
    [self updateLastPlayedPanel];

    BOOL showLastPlayedTile = !self.lastPlayedPanelView.hidden;
    self.controllerOverviewSpecialTileKind = showLastPlayedTile ? OPNControllerOverviewSpecialTileLastPlayed : OPNControllerOverviewSpecialTileNone;

    CGFloat scale = 1.0;
    CGFloat spacing = floor(34.0 * scale);
    CGFloat cardWidth = floor(164.0 * scale);
    CGFloat cardHeight = floor(cardWidth * 178.0 / 220.0);
    CGFloat railInset = floor(34.0 * scale);
    CGFloat railY = floor(42.0 * scale);
    self.gridColumnCount = 1;

    NSView *specialTileView = nil;
    if (self.controllerOverviewSpecialTileKind == OPNControllerOverviewSpecialTileLastPlayed) {
        specialTileView = self.lastPlayedPanelView;
        self.lastPlayedPanelView.hidden = NO;
    } else {
        self.lastPlayedPanelView.hidden = YES;
    }

    CGFloat nextX = railInset;
    CGFloat railHeight = cardHeight;
    if (specialTileView) {
        [self.gridContentView addSubview:specialTileView];
        CGFloat tileWidth = floor(cardWidth * 1.92);
        CGFloat tileHeight = floor(cardHeight * 1.74);
        NSRect tileFrame = NSMakeRect(nextX, 0.0, tileWidth, tileHeight);
        specialTileView.frame = tileFrame;
        railHeight = MAX(railHeight, tileHeight);
        nextX = NSMaxX(tileFrame) + spacing;
        CGFloat contentWidth = tileWidth - 32.0;
        CGFloat imageMaxHeight = MAX(64.0, MIN(tileHeight * 0.54, tileHeight - 132.0));
        CGFloat aspectRatio = self.lastPlayedImageAspectRatio > 0.1 ? self.lastPlayedImageAspectRatio : 16.0 / 9.0;
        CGFloat imageWidth = MIN(contentWidth, floor(imageMaxHeight * aspectRatio));
        CGFloat imageHeight = floor(imageWidth / aspectRatio);
        if (imageHeight > imageMaxHeight) {
            imageHeight = imageMaxHeight;
            imageWidth = floor(imageHeight * aspectRatio);
        }
        CGFloat imageX = floor((tileWidth - imageWidth) * 0.5);
        self.lastPlayedImageView.frame = NSMakeRect(imageX, 12.0, imageWidth, imageHeight);
        CGFloat labelY = NSMaxY(self.lastPlayedImageView.frame) + 12.0;
        CGFloat labelWidth = tileWidth - 32.0;
        CGFloat hintY = tileHeight - 26.0;
        CGFloat titleY = labelY + 18.0;
        CGFloat titleHeight = MIN(46.0, MAX(24.0, hintY - titleY - 40.0));
        CGFloat metaY = titleY + titleHeight + 4.0;
        CGFloat metaHeight = MIN(32.0, MAX(0.0, hintY - metaY - 4.0));
        self.lastPlayedEyebrowLabel.frame = NSMakeRect(16.0, labelY, labelWidth, 16.0);
        self.lastPlayedTitleLabel.frame = NSMakeRect(16.0, titleY, labelWidth, titleHeight);
        self.lastPlayedMetaLabel.frame = NSMakeRect(16.0, metaY, labelWidth, metaHeight);
        self.lastPlayedHintLabel.frame = NSMakeRect(16.0, hintY, labelWidth, 18.0);
    }

    CGFloat cardY = floor((railHeight - cardHeight) * 0.5);
    for (NSDictionary<NSString *, NSString *> *item in self.categoryItems) {
        NSString *categoryId = item[@"id"] ?: @"all";
        NSString *title = item[@"title"] ?: @"Category";
        if ([categoryId isEqualToString:@"all"]) title = @"All Games";
        if ([categoryId hasPrefix:@"store:"] && ![title hasPrefix:@"Store:"]) title = [@"Store: " stringByAppendingString:title];
        OPNCategorySample sample = [self sampleForCategory:categoryId limit:6];
        if (sample.count <= 0 && ![categoryId isEqualToString:@"favorites"]) continue;
        OPNControllerCategoryCardView *card = [[OPNControllerCategoryCardView alloc] initWithFrame:NSMakeRect(nextX, cardY, cardWidth, cardHeight)
                                                                                                title:title
                                                                                           categoryId:categoryId
                                                                                            gameCount:sample.count
                                                                                               games:sample.thumbnails];
        __weak __typeof__(self) weakSelf = self;
        __weak OPNControllerCategoryCardView *weakCard = card;
        card.onSelect = ^{
            __typeof__(self) strongSelf = weakSelf;
            OPNControllerCategoryCardView *strongCard = weakCard;
            if (!strongSelf || !strongCard) return;
            NSUInteger cardIndex = [strongSelf.categoryCardViews indexOfObject:strongCard];
            if (cardIndex != NSNotFound) [strongSelf focusCategoryAtIndex:(NSInteger)cardIndex + [strongSelf controllerOverviewCategoryOffset] scrollIntoView:NO];
            [strongSelf openFocusedCategory];
        };
        [self.gridContentView addSubview:card];
        [self.categoryCardViews addObject:card];
        nextX = NSMaxX(card.frame) + spacing;
    }

    {
        std::vector<OPN::GameInfo> emptyGames;
        OPNControllerCategoryCardView *settingsCard = [[OPNControllerCategoryCardView alloc] initWithFrame:NSMakeRect(nextX, cardY, cardWidth, cardHeight)
                                                                                                       title:@"Settings"
                                                                                                  categoryId:@"system:interface-settings"
                                                                                                   gameCount:1
                                                                                                      games:emptyGames];
        __weak __typeof__(self) weakSelf = self;
        __weak OPNControllerCategoryCardView *weakCard = settingsCard;
        settingsCard.onSelect = ^{
            __typeof__(self) strongSelf = weakSelf;
            OPNControllerCategoryCardView *strongCard = weakCard;
            if (!strongSelf || !strongCard) return;
            NSUInteger cardIndex = [strongSelf.categoryCardViews indexOfObject:strongCard];
            if (cardIndex != NSNotFound) [strongSelf focusCategoryAtIndex:(NSInteger)cardIndex + [strongSelf controllerOverviewCategoryOffset] scrollIntoView:NO];
            [strongSelf openFocusedCategory];
        };
        [self.gridContentView addSubview:settingsCard];
        [self.categoryCardViews addObject:settingsCard];
        nextX = NSMaxX(settingsCard.frame) + spacing;

        OPNControllerCategoryCardView *restartCard = [[OPNControllerCategoryCardView alloc] initWithFrame:NSMakeRect(nextX, cardY, cardWidth, cardHeight)
                                                                                                     title:@"Restart"
                                                                                                categoryId:@"system:restart"
                                                                                                 gameCount:1
                                                                                                    games:emptyGames];
        __weak OPNControllerCategoryCardView *weakRestartCard = restartCard;
        restartCard.onSelect = ^{
            __typeof__(self) strongSelf = weakSelf;
            OPNControllerCategoryCardView *strongCard = weakRestartCard;
            if (!strongSelf || !strongCard) return;
            NSUInteger cardIndex = [strongSelf.categoryCardViews indexOfObject:strongCard];
            if (cardIndex != NSNotFound) [strongSelf focusCategoryAtIndex:(NSInteger)cardIndex + [strongSelf controllerOverviewCategoryOffset] scrollIntoView:NO];
            [strongSelf openFocusedCategory];
        };
        [self.gridContentView addSubview:restartCard];
        [self.categoryCardViews addObject:restartCard];
        nextX = NSMaxX(restartCard.frame) + spacing;

        OPNControllerCategoryCardView *exitCard = [[OPNControllerCategoryCardView alloc] initWithFrame:NSMakeRect(nextX, cardY, cardWidth, cardHeight)
                                                                                                  title:@"Exit"
                                                                                             categoryId:@"system:exit"
                                                                                              gameCount:1
                                                                                                 games:emptyGames];
        __weak OPNControllerCategoryCardView *weakExitCard = exitCard;
        exitCard.onSelect = ^{
            __typeof__(self) strongSelf = weakSelf;
            OPNControllerCategoryCardView *strongCard = weakExitCard;
            if (!strongSelf || !strongCard) return;
            NSUInteger cardIndex = [strongSelf.categoryCardViews indexOfObject:strongCard];
            if (cardIndex != NSNotFound) [strongSelf focusCategoryAtIndex:(NSInteger)cardIndex + [strongSelf controllerOverviewCategoryOffset] scrollIntoView:NO];
            [strongSelf openFocusedCategory];
        };
        [self.gridContentView addSubview:exitCard];
        [self.categoryCardViews addObject:exitCard];
        nextX = NSMaxX(exitCard.frame) + spacing;
    }

    self.gridContentView.frame = NSMakeRect(0.0,
                                             0.0,
                                             MAX(self.scrollView.frame.size.width, nextX + railInset),
                                             MAX(self.scrollView.frame.size.height, railHeight + railY));
    NSInteger itemCount = [self controllerOverviewItemCount];
    if (self.focusedCategoryIndex >= itemCount) self.focusedCategoryIndex = itemCount - 1;
    if (self.focusedCategoryIndex < 0 && itemCount > 0) self.focusedCategoryIndex = 0;
    [self focusCategoryAtIndex:self.focusedCategoryIndex scrollIntoView:NO];
    NSInteger totalCount = [self gameCountForCategory:@"all"];
    self.gameCountLabel.stringValue = [NSString stringWithFormat:@"%ld %@", (long)totalCount, totalCount == 1 ? @"game" : @"games"];
    if (self.onGameCountChanged) self.onGameCountChanged(totalCount);
    self.statusLabel.stringValue = self.categoryCardViews.count == 0 ? @"No game categories found." : @"";
    [self layoutCatalogSubviews];
}

- (void)renderControllerLibrary {
    self.controllerCategoryOverviewVisible = NO;
    self.controllerOverviewSpecialTileKind = OPNControllerOverviewSpecialTileNone;
    self.lastPlayedPanelView.hidden = YES;

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
    NSArray<NSView *> *outgoingViews = [self.controllerHeroViews copy];
    for (NSView *view in outgoingViews) {
        if (animated && view.superview) continue;
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
    CGFloat heroWidth = MIN(availableHeroWidth, MAX(metrics.heroHeight, metrics.heroHeight * MAX(0.1, self.controllerHeroImageAspectRatio)));
    NSRect heroFrame = NSMakeRect(contentInset + (availableHeroWidth - heroWidth) * 0.5, metrics.heroY, heroWidth, metrics.heroHeight);
    [self addControllerHeroForGame:featuredGames[(size_t)heroIndex]
                             frame:heroFrame
                      activeIndex:heroIndex
                      totalCount:(NSInteger)featuredGames.size()];
    if (animated && outgoingViews.count > 0) {
        [self animateControllerHeroIncomingViews:[self.controllerHeroViews copy] outgoingViews:outgoingViews frame:heroFrame];
    }
}

- (void)animateControllerHeroIncomingViews:(NSArray<NSView *> *)incomingViews outgoingViews:(NSArray<NSView *> *)outgoingViews frame:(NSRect)frame {
    CGFloat heroWidth = MAX(1.0, NSWidth(frame));
    CGFloat travel = MIN(heroWidth * 0.18, 150.0);
    CFTimeInterval speedScale = 2.0;
    CFTimeInterval now = CACurrentMediaTime();
    CAMediaTimingFunction *ease = [OPNCoreAnimationCoordinator appleQuinticTimingFunction];

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    for (NSView *view in outgoingViews) {
        if (!view.layer) continue;
        CALayer *layer = view.layer;
        CALayer *presentationLayer = layer.presentationLayer;
        CATransform3D currentTransform = presentationLayer ? presentationLayer.transform : layer.transform;
        CGFloat currentOpacity = presentationLayer ? presentationLayer.opacity : layer.opacity;
        CATransform3D exitTransform = CATransform3DIdentity;
        exitTransform.m34 = -1.0 / 900.0;
        exitTransform = CATransform3DTranslate(exitTransform, -travel, 0.0, -70.0);
        exitTransform = CATransform3DScale(exitTransform, 0.965, 0.965, 1.0);
        exitTransform = CATransform3DRotate(exitTransform, -0.045, 0.0, 1.0, 0.0);
        layer.opacity = 0.0;
        layer.transform = exitTransform;

        CABasicAnimation *opacity = [CABasicAnimation animationWithKeyPath:@"opacity"];
        opacity.fromValue = @(currentOpacity);
        opacity.toValue = @0.0;

        CABasicAnimation *transform = [CABasicAnimation animationWithKeyPath:@"transform"];
        transform.fromValue = [NSValue valueWithCATransform3D:currentTransform];
        transform.toValue = [NSValue valueWithCATransform3D:exitTransform];

        CAAnimationGroup *group = [CAAnimationGroup animation];
        group.animations = @[opacity, transform];
        group.duration = 0.42 * speedScale;
        group.beginTime = now;
        group.timingFunction = ease;
        group.removedOnCompletion = YES;
        [layer addAnimation:group forKey:@"opn.hero.deck.exit"];
    }

    for (NSUInteger index = 0; index < incomingViews.count; index++) {
        NSView *view = incomingViews[index];
        if (!view.layer) continue;
        CALayer *layer = view.layer;
        BOOL isActionElement = index >= 2;
        CFTimeInterval delay = (isActionElement ? 0.06 + MIN((CGFloat)(index - 2), 3.0) * 0.035 : index * 0.025) * speedScale;
        CATransform3D startTransform = CATransform3DIdentity;
        startTransform.m34 = -1.0 / 900.0;
        startTransform = CATransform3DTranslate(startTransform, travel, isActionElement ? 10.0 : 0.0, 82.0);
        startTransform = CATransform3DScale(startTransform, isActionElement ? 1.035 : 1.055, isActionElement ? 1.035 : 1.055, 1.0);
        startTransform = CATransform3DRotate(startTransform, 0.040, 0.0, 1.0, 0.0);
        layer.opacity = 1.0;
        layer.transform = CATransform3DIdentity;

        CABasicAnimation *opacity = [CABasicAnimation animationWithKeyPath:@"opacity"];
        opacity.fromValue = @0.0;
        opacity.toValue = @1.0;

        CABasicAnimation *transform = [CABasicAnimation animationWithKeyPath:@"transform"];
        transform.fromValue = [NSValue valueWithCATransform3D:startTransform];
        transform.toValue = [NSValue valueWithCATransform3D:CATransform3DIdentity];

        CAAnimationGroup *group = [CAAnimationGroup animation];
        group.animations = @[opacity, transform];
        group.duration = (isActionElement ? 0.55 : 0.62) * speedScale;
        group.beginTime = now + delay;
        group.timingFunction = ease;
        group.removedOnCompletion = YES;
        [layer addAnimation:group forKey:@"opn.hero.deck.enter"];
    }

    NSView *sweepView = [[NSView alloc] initWithFrame:NSMakeRect(NSMinX(frame) - heroWidth * 0.20, NSMinY(frame) - NSHeight(frame) * 0.20, heroWidth * 0.16, NSHeight(frame) * 1.40)];
    sweepView.wantsLayer = YES;
    sweepView.layer.anchorPoint = CGPointMake(0.5, 0.5);
    sweepView.layer.position = CGPointMake(NSMidX(sweepView.frame), NSMidY(sweepView.frame));
    sweepView.layer.transform = CATransform3DMakeRotation(-0.22, 0.0, 0.0, 1.0);
    sweepView.layer.opacity = 0.0;
    CAGradientLayer *sweepLayer = [CAGradientLayer layer];
    sweepLayer.frame = sweepView.bounds;
    sweepLayer.startPoint = CGPointMake(0.0, 0.5);
    sweepLayer.endPoint = CGPointMake(1.0, 0.5);
    sweepLayer.colors = @[(id)OpnColor(0x45F27C, 0.0).CGColor,
                          (id)OpnColor(0x45F27C, 0.22).CGColor,
                          (id)OpnColor(0xFFFFFF, 0.34).CGColor,
                          (id)OpnColor(0x45F27C, 0.0).CGColor];
    sweepLayer.locations = @[@0.0, @0.38, @0.52, @1.0];
    [sweepView.layer addSublayer:sweepLayer];
    [self.gridContentView addSubview:sweepView positioned:NSWindowAbove relativeTo:nil];

    CABasicAnimation *sweepPosition = [CABasicAnimation animationWithKeyPath:@"position.x"];
    sweepPosition.fromValue = @(NSMinX(frame) - heroWidth * 0.16);
    sweepPosition.toValue = @(NSMaxX(frame) + heroWidth * 0.18);
    CAKeyframeAnimation *sweepPulse = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
    sweepPulse.values = @[@0.0, @1.0, @0.68, @0.0];
    sweepPulse.keyTimes = @[@0.0, @0.18, @0.72, @1.0];
    CAAnimationGroup *sweepGroup = [CAAnimationGroup animation];
    sweepGroup.animations = @[sweepPosition, sweepPulse];
    sweepGroup.duration = 0.50 * speedScale;
    sweepGroup.beginTime = now + 0.10 * speedScale;
    sweepGroup.timingFunction = ease;
    sweepGroup.removedOnCompletion = YES;
    [sweepView.layer addAnimation:sweepGroup forKey:@"opn.hero.sweep"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.72 * speedScale * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [sweepView removeFromSuperview];
        for (NSView *view in outgoingViews) [view removeFromSuperview];
    });

    [CATransaction commit];
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

    [self.controllerLibraryRailView removeFromSuperview];
    [self.cardViews removeAllObjects];
    NSView *railView = [[OPNFlippedGridDocumentView alloc] initWithFrame:NSMakeRect(0.0, 0.0, width, metrics.contentHeight)];
    railView.wantsLayer = YES;
    railView.layer.backgroundColor = NSColor.clearColor.CGColor;
    self.controllerLibraryRailView = railView;
    [self.gridContentView addSubview:railView];

    for (NSInteger index = renderStart; index < renderEnd; index++) {
        const OPN::GameInfo &game = displayGames[(size_t)index];
        CGFloat x = contentInset + index * (cardWidth + metrics.cardSpacing);
        OPNGameCardView *card = [[OPNGameCardView alloc] initWithFrame:NSMakeRect(x, metrics.cardY, cardWidth, cardHeight) game:game];
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
    if (!OpnControllerModeEnabled() || self.controllerCategoryOverviewVisible || !self.controllerLibraryRailView || self.cardViews.count == 0) return;
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

- (std::vector<OPN::GameInfo>)controllerFeaturedGamesFromDisplayGames:(const std::vector<OPN::GameInfo> &)displayGames {
    std::vector<OPN::GameInfo> featuredGames;
    NSInteger limit = MIN((NSInteger)displayGames.size(), 6);
    for (NSInteger index = 0; index < limit; index++) {
        featuredGames.push_back(displayGames[(size_t)index]);
    }
    return featuredGames;
}

- (const OPN::GameInfo *)currentControllerHeroGame {
    std::vector<OPN::GameInfo> featuredGames = [self controllerFeaturedGamesFromDisplayGames:_featuredGames];
    if (featuredGames.empty()) return nullptr;
    NSInteger heroIndex = MAX(0, MIN(self.controllerHeroIndex, (NSInteger)featuredGames.size() - 1));
    return &_featuredGames[(size_t)heroIndex];
}

- (OPNControllerHeroPrimaryAction)primaryActionForHeroGame:(const OPN::GameInfo &)game {
    if (OPNGameHasActiveSession(game, _activeSessionAppIds)) return OPNControllerHeroPrimaryActionResume;
    if (OPNGameIsOwned(game)) return OPNControllerHeroPrimaryActionPlay;
    return OPNControllerHeroPrimaryActionBuy;
}

- (void)addControllerHeroForGame:(const OPN::GameInfo &)game frame:(NSRect)frame activeIndex:(NSInteger)activeIndex totalCount:(NSInteger)totalCount {
    OPNControllerPreviewBackgroundView *hero = [[OPNControllerPreviewBackgroundView alloc] initWithFrame:frame];
    CGFloat heroHeight = MAX(1.0, NSHeight(frame));
    CGFloat heroWidth = MAX(1.0, NSWidth(frame));
    CGFloat cornerRadius = heroHeight * (18.0 / 270.0);
    CGFloat leftInset = heroWidth * (68.0 / 1176.0);
    CGFloat logoWidth = heroWidth * (340.0 / 1176.0);
    CGFloat logoHeight = heroHeight * (84.0 / 270.0);
    CGFloat resumeButtonWidth = heroWidth * (136.0 / 1176.0);
    CGFloat secondaryButtonWidth = heroWidth * (136.0 / 1176.0);
    CGFloat moreButtonWidth = heroWidth * (50.0 / 1176.0);
    CGFloat buttonHeight = heroHeight * (42.0 / 270.0);
    CGFloat buttonGap = heroWidth * (14.0 / 1176.0);
    CGFloat actionFontSize = heroHeight * (14.5 / 270.0);

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
    hero.rightAlignImageToHeight = YES;
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

    CGFloat dotSpacing = heroWidth * (24.0 / 1176.0);
    CGFloat activeDotWidth = heroWidth * (22.0 / 1176.0);
    CGFloat inactiveDotWidth = heroWidth * (14.0 / 1176.0);
    CGFloat dotHeight = heroHeight * (5.0 / 270.0);
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
    OPNCatalogLoadImageFromCandidates(candidates, index, ^(NSImage *image, NSString *resolvedURL, NSData *data) {
        (void)resolvedURL;
        OPNControllerPreviewBackgroundView *strongView = weakView;
        if (strongView.superview && image) [strongView setImage:image metadataData:data];
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf || !image || image.size.width <= 0.0 || image.size.height <= 0.0) return;
        CGFloat aspectRatio = image.size.width / image.size.height;
        if (fabs(strongSelf.controllerHeroImageAspectRatio - aspectRatio) <= 0.01) return;
        strongSelf.controllerHeroImageAspectRatio = aspectRatio;
        [strongSelf renderControllerHero];
        [strongSelf layoutCatalogSubviews];
    });
}

- (void)loadControllerHeroLogoForView:(NSImageView *)view candidates:(NSArray<NSString *> *)candidates index:(NSUInteger)index {
    if (!view || index >= candidates.count) return;
    __weak NSImageView *weakView = view;
    OPNCatalogLoadImageFromCandidates(candidates, index, ^(NSImage *image, NSString *resolvedURL, NSData *data) {
        (void)resolvedURL;
        (void)data;
        NSImageView *strongView = weakView;
        if (strongView.superview && image) strongView.image = image;
    });
}

- (void)startControllerHeroRotationIfNeeded {
    std::vector<OPN::GameInfo> featuredGames = [self controllerFeaturedGamesFromDisplayGames:_featuredGames];
    if (!self.window || !OpnControllerModeEnabled() || featuredGames.size() <= 1) {
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
    std::vector<OPN::GameInfo> featuredGames = [self controllerFeaturedGamesFromDisplayGames:_featuredGames];
    if (!self.window || !OpnControllerModeEnabled() || featuredGames.size() <= 1) {
        [self stopControllerHeroRotation];
        return;
    }
    NSInteger featuredCount = (NSInteger)featuredGames.size();
    if (featuredCount <= 1) return;
    self.controllerHeroIndex = (self.controllerHeroIndex + 1) % featuredCount;
    [self renderControllerHeroAnimated:YES];
}

- (void)controllerHeroResumeClicked:(id)sender {
    (void)sender;
    const OPN::GameInfo *heroGame = [self currentControllerHeroGame];
    if (!heroGame) return;
    if ([self primaryActionForHeroGame:*heroGame] == OPNControllerHeroPrimaryActionBuy) {
        [self controllerHeroMoreInfoClicked:nil];
        return;
    }
    if (!self.onSelectGame) return;
    if (OpnControllerModeEnabled()) OpnPlayConsoleTone(OPNConsoleToneSelect);
    self.onSelectGame(*heroGame, [self preferredVariantIndexForGame:*heroGame]);
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
    CGFloat searchWidth = compact ? MAX(240.0, width - 64.0) : MIN(520.0, MAX(360.0, width * 0.38));
    CGFloat searchX = floor((width - searchWidth) / 2.0);
    self.libraryIconLabel.frame = NSMakeRect(0, 0, 0, 0);
    self.titleLabel.frame = NSMakeRect(0, 0, 0, 0);
    self.userLabel.frame = NSMakeRect(24, kNavHeight + 36, 260, 18);
    self.searchField.frame = NSMakeRect(searchX, compact ? kNavHeight + 62 : kNavHeight + 25, searchWidth, 40);
    self.sortButton.hidden = controllerMode || compact;
    self.filterButton.frame = NSMakeRect(NSMaxX(self.searchField.frame) + 14, kNavHeight + 26, 124, 38);
    self.sortButton.frame = NSMakeRect(NSMaxX(self.filterButton.frame) + 10, kNavHeight + 26, 154, 38);
    self.gameCountLabel.frame = NSMakeRect(0, 0, 0, 0);
    self.gameCountLabel.hidden = YES;
    self.signOutButton.frame = NSMakeRect(width - 116, kNavHeight + 13, 92, 30);
    BOOL categoryOverview = NO;
    OPNControllerLibraryMetrics controllerMetrics = OPNControllerLibraryMetricsForSize(width, height);
    self.controllerBottomPromptBarView.hidden = !controllerMode;
    self.controllerBottomPromptBarView.mode = categoryOverview ? OPNControllerPromptModeHome : OPNControllerPromptModeGame;
    self.controllerBottomPromptBarView.includeStore = !categoryOverview;
    self.controllerBottomPromptBarView.includeBack = !categoryOverview;
    self.controllerBottomPromptBarView.includeCategorySwitch = !categoryOverview && self.categoryItems.count > 1;
    self.controllerBottomPromptBarView.frame = NSMakeRect(controllerMetrics.contentInset, height - controllerMetrics.bottomInset + height * (20.0 / 720.0), MAX(0.0, width - controllerMetrics.contentInset * 2.0), height * (32.0 / 720.0));
    if (controllerMode) {
        self.searchField.hidden = YES;
        self.filterButton.hidden = YES;
        self.sortButton.hidden = YES;
        self.categoryBarView.hidden = YES;
        self.controllerHomeEyebrowLabel.hidden = YES;
        self.controllerHomeTitleLabel.hidden = YES;
        self.controllerHomeSubtitleLabel.hidden = YES;
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
    self.controllerHomeEyebrowLabel.hidden = !categoryOverview;
    self.controllerHomeTitleLabel.hidden = !categoryOverview;
    self.controllerHomeSubtitleLabel.hidden = !categoryOverview;
    self.controllerSectionLabel.hidden = !controllerMode || categoryOverview;
    if (categoryOverview) {
        self.controllerHomeEyebrowLabel.frame = NSMakeRect(64.0, 34.0, 220.0, 18.0);
        self.controllerHomeTitleLabel.frame = NSMakeRect(62.0, 56.0, MIN(560.0, width - 128.0), 52.0);
        self.controllerHomeSubtitleLabel.frame = NSMakeRect(64.0, 111.0, MIN(680.0, width - 128.0), 24.0);
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
    if (self.lastPlayedPanelView.superview != self) [self addSubview:self.lastPlayedPanelView];
    self.lastPlayedPanelView.hidden = YES;
    [self setLastPlayedFocused:NO];
    self.categoryBarView.hidden = controllerMode || self.categoryButtons.count <= 1;
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
    CGFloat gridY = kNavHeight + (compact ? 116.0 : kToolbarHeight);
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
    self.statusLabel.frame = controllerMode ? NSMakeRect(28.0, MAX(kNavHeight + 30.0, gridY - 42.0), width - 56.0, 24.0) : NSMakeRect(0, gridY + 100, width, 24);
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
    NSInteger controllerItemCount = OpnControllerModeEnabled() ? self.controllerDisplayGameCount : (NSInteger)self.cardViews.count;
    if (controllerItemCount == 0) {
        self.focusedCardIndex = -1;
        return;
    }
    NSInteger previousIndex = self.focusedCardIndex;
    NSInteger clamped = MAX(0, MIN(index, controllerItemCount - 1));
    self.focusedCardIndex = clamped;
    if (OpnControllerModeEnabled() && (clamped < self.controllerLibraryWindowStartIndex || clamped >= self.controllerLibraryWindowStartIndex + (NSInteger)self.cardViews.count)) {
        [self renderControllerLibraryRail];
        [self scrollControllerLibraryRailToCardAtIndex:clamped animated:scrollIntoView];
        [self updateControllerDetailContent];
        return;
    }
    OPNControllerLibraryMetrics metrics = OPNControllerLibraryMetricsForSize(MAX(1.0, NSWidth(self.bounds)), MAX(1.0, NSHeight(self.bounds)));
    if (OpnControllerModeEnabled() && (clamped < self.controllerLibraryVisibleStartIndex || clamped >= self.controllerLibraryVisibleStartIndex + metrics.visibleCardCount)) {
        [self renderControllerLibraryRail];
    }
    for (NSUInteger i = 0; i < self.cardViews.count; i++) {
        NSInteger globalIndex = OpnControllerModeEnabled() ? self.controllerLibraryWindowStartIndex + (NSInteger)i : (NSInteger)i;
        BOOL selected = OpnControllerModeEnabled() && globalIndex == clamped;
        self.cardViews[i].controllerFocused = selected;
        self.cardViews[i].alphaValue = 1.0;
    }
    if (OpnControllerModeEnabled() && scrollIntoView && previousIndex >= 0 && previousIndex != clamped) {
        OpnPlayConsoleTone(OPNConsoleToneMove);
    }
    [self updateControllerDetailContent];
    if (!scrollIntoView) return;
    NSInteger localIndex = OpnControllerModeEnabled() ? clamped - self.controllerLibraryWindowStartIndex : clamped;
    if (localIndex < 0 || localIndex >= (NSInteger)self.cardViews.count) return;
    OPNGameCardView *card = self.cardViews[(NSUInteger)localIndex];
    NSRect visibleRect = self.scrollView.contentView.bounds;
    NSRect targetRect = NSInsetRect(card.frame, -24.0, -24.0);
    if (OpnControllerModeEnabled()) {
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

- (void)focusCategoryAtIndex:(NSInteger)index scrollIntoView:(BOOL)scrollIntoView {
    NSInteger itemCount = [self controllerOverviewItemCount];
    if (itemCount == 0) {
        self.focusedCategoryIndex = -1;
        [self setLastPlayedFocused:NO];
        return;
    }
    NSInteger previousIndex = self.focusedCategoryIndex;
    NSInteger clamped = MAX(0, MIN(index, itemCount - 1));
    self.focusedCategoryIndex = clamped;
    NSInteger categoryOffset = [self controllerOverviewCategoryOffset];
    BOOL specialFocused = categoryOffset > 0 && clamped == 0;
    [self setLastPlayedFocused:specialFocused && self.controllerOverviewSpecialTileKind == OPNControllerOverviewSpecialTileLastPlayed];
    for (NSUInteger i = 0; i < self.categoryCardViews.count; i++) {
        self.categoryCardViews[i].controllerFocused = (NSInteger)i == clamped - categoryOffset;
    }
    if (OpnControllerModeEnabled() && scrollIntoView && previousIndex >= 0 && previousIndex != clamped) {
        OpnPlayConsoleTone(OPNConsoleToneMove);
    }
    if (!scrollIntoView) return;
    NSView *targetView = nil;
    if (specialFocused) {
        targetView = self.lastPlayedPanelView;
    } else {
        NSInteger categoryIndex = clamped - categoryOffset;
        if (categoryIndex >= 0 && categoryIndex < (NSInteger)self.categoryCardViews.count) {
            targetView = self.categoryCardViews[(NSUInteger)categoryIndex];
        }
    }
    if (targetView) {
        [self.gridContentView scrollRectToVisible:NSInsetRect(targetView.frame, -18.0, -18.0)];
        if (OpnControllerModeEnabled()) [self.scrollView.contentView scrollToPoint:NSMakePoint(self.scrollView.contentView.bounds.origin.x, 0.0)];
        [self.scrollView reflectScrolledClipView:self.scrollView.contentView];
    }
}

- (NSInteger)controllerOverviewCategoryOffset {
    return self.controllerOverviewSpecialTileKind == OPNControllerOverviewSpecialTileNone ? 0 : 1;
}

- (NSInteger)controllerOverviewItemCount {
    return [self controllerOverviewCategoryOffset] + (NSInteger)self.categoryCardViews.count;
}

- (NSView *)controllerOverviewViewAtIndex:(NSInteger)index {
    NSInteger categoryOffset = [self controllerOverviewCategoryOffset];
    if (categoryOffset > 0 && index == 0) {
        return self.lastPlayedPanelView;
    }
    NSInteger categoryIndex = index - categoryOffset;
    if (categoryIndex < 0 || categoryIndex >= (NSInteger)self.categoryCardViews.count) return nil;
    return self.categoryCardViews[(NSUInteger)categoryIndex];
}

- (void)updateLastPlayedPanel {
    const OPN::GameInfo *lastPlayedGame = [self currentLastPlayedGame];
    self.lastPlayedPanelView.hidden = lastPlayedGame == nullptr;
    if (!lastPlayedGame) {
        [self setLastPlayedFocused:NO];
        self.lastPlayedTitleLabel.stringValue = @"";
        self.lastPlayedMetaLabel.stringValue = @"";
        self.lastPlayedImageView.image = nil;
        self.lastPlayedImageURL = @"";
        return;
    }

    const OPN::GameInfo &game = *lastPlayedGame;
    self.lastPlayedTitleLabel.stringValue = OPNCatalogString(game.title, @"Untitled Game");
    NSString *store = @"";
    int variantIndex = [self preferredVariantIndexForGame:game];
    if (variantIndex >= 0 && variantIndex < (int)game.variants.size()) {
        store = OPNCatalogString(game.variants[(size_t)variantIndex].appStore, @"");
    } else if (!game.availableStores.empty()) {
        store = OPNCatalogString(game.availableStores.front(), @"");
    }
    NSString *genres = OPNCatalogJoinedStrings(game.genres, @"");
    NSString *features = OPNCatalogJoinedStrings(game.featureLabels, @"");
    NSString *playability = OPNCatalogDisplayString(game.playabilityState, @"");
    NSMutableArray<NSString *> *meta = [NSMutableArray array];
    if (store.length > 0) [meta addObject:OPNStoreCategoryTitle(store)];
    if (genres.length > 0) [meta addObject:genres];
    if (features.length > 0 && meta.count < 3) [meta addObject:features];
    if (playability.length > 0 && meta.count < 3) [meta addObject:playability];
    self.lastPlayedMetaLabel.stringValue = meta.count > 0 ? [meta componentsJoinedByString:@"  /  "] : @"Ready to launch";

    NSArray<NSString *> *candidates = OPNControllerCategoryArtworkCandidates(game);
    NSString *expectedURL = candidates.count > 0 ? candidates.firstObject : @"";
    if ([self.lastPlayedImageURL isEqualToString:expectedURL]) return;
    self.lastPlayedImageURL = expectedURL;
    self.lastPlayedImageAspectRatio = 16.0 / 9.0;
    self.lastPlayedImageView.image = nil;
    [self loadLastPlayedImageFromCandidates:candidates index:0 expectedURL:expectedURL];
}

- (void)loadLastPlayedImageFromCandidates:(NSArray<NSString *> *)candidates index:(NSUInteger)index expectedURL:(NSString *)expectedURL {
    if (index >= candidates.count || expectedURL.length == 0) return;
    __weak __typeof__(self) weakSelf = self;
    OPNCatalogLoadImageFromCandidates(candidates, index, ^(NSImage *image, NSString *resolvedURL, NSData *data) {
        (void)resolvedURL;
        (void)data;
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf || !image || ![strongSelf.lastPlayedImageURL isEqualToString:expectedURL]) return;
        if (image.size.width > 0.0 && image.size.height > 0.0) {
            strongSelf.lastPlayedImageAspectRatio = image.size.width / image.size.height;
        }
        strongSelf.lastPlayedImageView.image = image;
        [strongSelf layoutCatalogSubviews];
    });
}

- (void)moveCategoryFocusByRows:(NSInteger)rows columns:(NSInteger)columns {
    NSInteger itemCount = [self controllerOverviewItemCount];
    if (itemCount == 0 || (rows == 0 && columns == 0)) return;
    NSView *currentView = [self controllerOverviewViewAtIndex:self.focusedCategoryIndex];
    if (!currentView) return;

    NSRect currentFrame = currentView.frame;
    CGFloat currentX = NSMidX(currentFrame);
    CGFloat currentY = NSMidY(currentFrame);
    CGFloat bestScore = CGFLOAT_MAX;
    NSInteger bestIndex = NSNotFound;

    for (NSInteger index = 0; index < itemCount; index++) {
        if (index == self.focusedCategoryIndex) continue;
        NSView *candidateView = [self controllerOverviewViewAtIndex:index];
        if (!candidateView || candidateView.hidden) continue;
        NSRect candidateFrame = candidateView.frame;
        CGFloat dx = NSMidX(candidateFrame) - currentX;
        CGFloat dy = NSMidY(candidateFrame) - currentY;
        CGFloat score = CGFLOAT_MAX;
        if (rows > 0 && dy > 1.0) {
            score = fabs(dx) * 3.0 + dy;
        } else if (rows < 0 && dy < -1.0) {
            score = fabs(dx) * 3.0 + fabs(dy);
        } else if (columns > 0 && dx > 1.0) {
            score = fabs(dy) * 3.0 + dx;
        } else if (columns < 0 && dx < -1.0) {
            score = fabs(dy) * 3.0 + fabs(dx);
        }
        if (score < bestScore) {
            bestScore = score;
            bestIndex = index;
        }
    }

    if (bestIndex != NSNotFound) [self focusCategoryAtIndex:bestIndex scrollIntoView:YES];
}

- (void)openFocusedCategory {
    NSInteger categoryOffset = [self controllerOverviewCategoryOffset];
    if (categoryOffset > 0 && self.focusedCategoryIndex == 0) {
        if (self.controllerOverviewSpecialTileKind == OPNControllerOverviewSpecialTileLastPlayed) {
            [self launchLastPlayedGame];
        }
        return;
    }
    NSInteger categoryIndex = self.focusedCategoryIndex - categoryOffset;
    if (categoryIndex < 0 || categoryIndex >= (NSInteger)self.categoryCardViews.count) return;
    OPNControllerCategoryCardView *card = self.categoryCardViews[(NSUInteger)categoryIndex];
    if ([card.categoryId isEqualToString:@"system:interface-settings"]) {
        if (OpnControllerModeEnabled()) OpnPlayConsoleTone(OPNConsoleToneSelect);
        if (self.onInterfaceSettingsRequested) self.onInterfaceSettingsRequested();
        return;
    }
    if ([card.categoryId isEqualToString:@"system:restart"]) {
        if (OpnControllerModeEnabled()) OpnPlayConsoleTone(OPNConsoleToneSelect);
        if (self.onRestartRequested) self.onRestartRequested();
        return;
    }
    if ([card.categoryId isEqualToString:@"system:exit"]) {
        if (OpnControllerModeEnabled()) OpnPlayConsoleTone(OPNConsoleToneBack);
        if (self.onExitRequested) self.onExitRequested();
        return;
    }
    self.selectedCategoryId = card.categoryId.length > 0 ? card.categoryId : @"all";
    self.controllerCategoryOverviewVisible = NO;
    self.focusedCardIndex = 0;
    self.controllerRenderedGameCount = [self controllerInitialRenderedGameCount];
    [self resetDesktopGridRenderWindow];
    if (OpnControllerModeEnabled()) OpnPlayConsoleTone(OPNConsoleToneSelect);
    [self renderGrid];
    [self scrollLibraryToTop];
}

- (void)returnToControllerCategoryOverview {
    if (self.controllerCategoryOverviewVisible) return;
    self.controllerCategoryOverviewVisible = YES;
    self.focusedCardIndex = -1;
    if (OpnControllerModeEnabled()) OpnPlayConsoleTone(OPNConsoleToneBack);
    [self renderGrid];
    [self scrollLibraryToTop];
}

- (void)setLastPlayedFocused:(BOOL)focused {
    if (focused && self.lastPlayedPanelView.hidden) focused = NO;
    _lastPlayedFocused = focused;
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.20];
    [CATransaction setAnimationTimingFunction:[OPNCoreAnimationCoordinator appleQuinticTimingFunction]];
    self.lastPlayedPanelView.layer.borderWidth = focused ? 3.0 : 1.0;
    self.lastPlayedPanelView.layer.borderColor = (focused ? OpnColor(0xFFFFFF, 0.92) : OpnColor(0xFFFFFF, 0.16)).CGColor;
    self.lastPlayedPanelView.layer.shadowColor = (focused ? OpnColor(OPNControllerAccentSoftRGB()) : NSColor.blackColor).CGColor;
    self.lastPlayedPanelView.layer.shadowOpacity = focused ? 0.48 : 0.30;
    self.lastPlayedPanelView.layer.shadowRadius = focused ? 38.0 : 24.0;
    CATransform3D transform = CATransform3DIdentity;
    if (focused) transform = CATransform3DScale(transform, 1.035, 1.035, 1.0);
    self.lastPlayedPanelView.layer.transform = transform;
    self.lastPlayedHintLabel.textColor = focused ? OpnColor(OPNControllerAccentSoftRGB()) : OpnColor(kTextSecondary);
    [CATransaction commit];
}

- (OPNGameCardView *)focusedCard {
    NSInteger localIndex = OpnControllerModeEnabled() ? self.focusedCardIndex - self.controllerLibraryWindowStartIndex : self.focusedCardIndex;
    if (localIndex < 0 || localIndex >= (NSInteger)self.cardViews.count) return nil;
    return self.cardViews[(NSUInteger)localIndex];
}

- (void)resetDesktopGridRenderWindow {
    self.desktopRenderedGameCount = 0;
    self.desktopDisplayGameCount = 0;
}

- (NSInteger)desktopInitialRenderedGameCountForColumns:(NSInteger)columns {
    CGFloat cardHeight = [OPNGameCardView cardSize].height;
    CGFloat availableHeight = NSHeight(self.scrollView.frame) > 1.0 ? NSHeight(self.scrollView.frame) : NSHeight(self.bounds);
    NSInteger visibleRows = (NSInteger)ceil((availableHeight + kCardSpacing) / MAX(1.0, cardHeight + kCardSpacing));
    return MAX(columns, columns * MAX(1, visibleRows + kDesktopGridRenderBufferRows));
}

- (void)libraryScrollViewBoundsDidChange:(NSNotification *)notification {
    if (notification.object != self.scrollView.contentView || OpnControllerModeEnabled()) return;
    if (self.desktopDisplayGameCount <= 0 || self.desktopRenderedGameCount >= self.desktopDisplayGameCount) return;

    NSClipView *clipView = self.scrollView.contentView;
    CGFloat viewportBottom = NSMaxY(clipView.bounds);
    CGFloat remaining = NSHeight(self.gridContentView.frame) - viewportBottom;
    CGFloat preloadDistance = MAX(NSHeight(clipView.bounds), [OPNGameCardView cardSize].height * 2.0);
    if (remaining > preloadDistance) return;

    NSInteger columns = MAX(1, self.gridColumnCount);
    NSInteger increment = columns * MAX(1, kDesktopGridRenderBufferRows);
    NSInteger nextCount = MIN(self.desktopDisplayGameCount, self.desktopRenderedGameCount + increment);
    if (nextCount <= self.desktopRenderedGameCount) return;
    self.desktopRenderedGameCount = nextCount;
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

    NSInteger currentIndex = 0;
    OPN::GameInfo gameToAppend;
    BOOL foundGameToAppend = NO;
    for (const OPN::GameInfo &game : _allGames) {
        if (![self game:game matchesCategory:self.selectedCategoryId]) continue;
        if (currentIndex == index) {
            gameToAppend = game;
            foundGameToAppend = YES;
            break;
        }
        currentIndex++;
    }
    if (!foundGameToAppend) {
        OPN::LogError(@"[CatalogView] append failed no matching game index=%ld category=%@ display=%ld", (long)index, self.selectedCategoryId, (long)self.controllerDisplayGameCount);
        return NO;
    }
    OPN::LogInfo(@"[CatalogView] append card index=%ld title=%@ id=%@ uuid=%@ desc=%d features=%lu image=%d hero=%d variants=%lu", (long)index, OPNCatalogString(gameToAppend.title, @"<untitled>"), OPNCatalogString(gameToAppend.id, @""), OPNCatalogString(gameToAppend.uuid, @""), !gameToAppend.description.empty(), (unsigned long)gameToAppend.featureLabels.size(), !gameToAppend.imageUrl.empty(), !gameToAppend.heroImageUrl.empty(), (unsigned long)gameToAppend.variants.size());

    CGFloat cardWidth = [OPNGameCardView cardSize].width;
    CGFloat cardHeight = [OPNGameCardView cardSize].height;
    CGFloat gridSpacing = 26.0;
    CGFloat xStart = 64.0;
    CGFloat yPos = 34.0 + kControllerRailSelectorOverlap;
    NSRect cardFrame = NSMakeRect(xStart + index * (cardWidth + gridSpacing), yPos, cardWidth, cardHeight);
    OPNGameCardView *card = [[OPNGameCardView alloc] initWithFrame:cardFrame game:gameToAppend];
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
    if (!OpnControllerModeEnabled() || self.controllerCategoryOverviewVisible) return NO;
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
    if (!OpnControllerModeEnabled() || self.controllerCategoryOverviewVisible || direction <= 0) return;
    NSInteger nextIndex = self.focusedCardIndex + 1;
    OPN::LogInfo(@"[CatalogView] neighbor preload check focused=%ld next=%ld cards=%lu rendered=%ld display=%ld", (long)self.focusedCardIndex, (long)nextIndex, (unsigned long)self.cardViews.count, (long)self.controllerRenderedGameCount, (long)self.controllerDisplayGameCount);
    if (nextIndex >= (NSInteger)self.cardViews.count - 1 && self.controllerRenderedGameCount < self.controllerDisplayGameCount) {
        [self appendControllerGameCardAtIndex:(NSInteger)self.cardViews.count];
    }
}

- (void)moveFocusByRows:(NSInteger)rows columns:(NSInteger)columns {
    if (OpnControllerModeEnabled() && self.controllerCategoryOverviewVisible) {
        [self moveCategoryFocusByRows:rows columns:columns];
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
    OPNGameCardView *card = [self focusedCard];
    if (!card || card.game.variants.size() <= 1) return;
    int next = (card.selectedVariantIndex + 1) % (int)card.game.variants.size();
    [card selectVariantAtIndex:next];
    if (OpnControllerModeEnabled()) OpnPlayConsoleTone(OPNConsoleToneChange);
    [self updateControllerDetailContent];
}

- (void)updateControllerDetailContent {
    if (!OpnControllerModeEnabled()) return;
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
    OPNCatalogLoadImageFromCandidates(candidates, index, ^(NSImage *image, NSString *resolvedURL, NSData *data) {
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
    if (self.isLastPlayedFocused) {
        [self launchLastPlayedGame];
        return;
    }
    if (OpnControllerModeEnabled() && self.controllerCategoryOverviewVisible) {
        [self openFocusedCategory];
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
    if (OpnControllerModeEnabled()) OpnPlayConsoleTone(OPNConsoleToneSelect);
    self.onSelectGame(*lastPlayedGame, [self preferredVariantIndexForGame:*lastPlayedGame]);
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
        case 125: [self cycleFocusedVariant]; return;
        case 126: [self moveFocusByRows:-1 columns:0]; return;
        case 36:
        case 49:
            [self launchFocusedGame];
            return;
        case 53:
            if (self.isLastPlayedFocused) [self setLastPlayedFocused:NO];
            if (!self.controllerCategoryOverviewVisible) [self returnToControllerCategoryOverview];
            return;
        case 48:
            if (self.controllerCategoryOverviewVisible) {
                [self openFocusedCategory];
            } else {
                [self cycleCategoryBy:1];
            }
            return;
        case 115:
            if (self.isLastPlayedFocused) [self setLastPlayedFocused:NO];
            if (!self.controllerCategoryOverviewVisible) [self returnToControllerCategoryOverview];
            return;
        default:
            break;
    }
    if ([chars isEqualToString:@"y"] || [chars isEqualToString:@"f"]) {
        [self toggleFavoriteForFocusedGame];
        return;
    }
    if ([chars isEqualToString:@"x"] || [chars isEqualToString:@"s"] || [chars isEqualToString:@"v"]) {
        [self cycleFocusedVariant];
        return;
    }
    if ([chars isEqualToString:@"b"]) {
        if (self.isLastPlayedFocused) [self setLastPlayedFocused:NO];
        if (!self.controllerCategoryOverviewVisible) [self returnToControllerCategoryOverview];
        return;
    }
    if ([chars isEqualToString:@"h"]) {
        if (self.isLastPlayedFocused) [self setLastPlayedFocused:NO];
        if (!self.controllerCategoryOverviewVisible) [self returnToControllerCategoryOverview];
        return;
    }
    [super keyDown:event];
}

- (void)startGamepadNavigationIfNeeded {
    if (!OpnControllerModeEnabled() || self.gamepadNavigationTimer || !OPNCatalogGamepadNavigationActive(self)) return;
    self.gamepadNavigationTimer = [NSTimer scheduledTimerWithTimeInterval:(1.0 / 30.0)
                                                                   target:self
                                                                 selector:@selector(pollGamepadNavigation)
                                                                 userInfo:nil
                                                                  repeats:YES];
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
    self.previousGamepadButtons = 0;
}

- (void)pollGamepadNavigation {
    if (!OpnControllerModeEnabled() || !OPNCatalogGamepadNavigationActive(self)) {
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
    if ((buttons & yButton) && !self.controllerYHoldActive && !self.controllerYConsumedByHold && (now - self.controllerYPressedAt) >= 0.35) {
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
    if ((released & yButton) && !self.controllerYConsumedByHold && !self.controllerCategoryOverviewVisible) [self cycleCategoryBy:1];
    if (pressed & (1u << 0)) {
        [self launchFocusedGame];
    }
    if (pressed & (1u << 1)) {
        if (self.isLastPlayedFocused) {
            [self setLastPlayedFocused:NO];
        } else if (!self.controllerCategoryOverviewVisible) {
            [self returnToControllerCategoryOverview];
        }
    }
    if ((pressed & (1u << 3)) && !self.controllerCategoryOverviewVisible) [self cycleCategoryBy:-1];
    if ((pressed & (1u << 4)) && !self.controllerCategoryOverviewVisible) [self cycleCategoryBy:1];
    if (pressed & (1u << 5)) [self moveFocusByRows:-1 columns:0];
    if (pressed & (1u << 6)) [self cycleFocusedVariant];
    if (pressed & (1u << 7)) [self moveFocusByRows:0 columns:-1];
    if (pressed & (1u << 8)) [self moveFocusByRows:0 columns:1];
    if (pressed & (1u << 9)) [self cycleFocusedVariant];
    self.previousGamepadButtons = buttons;
}

- (void)signOutClicked {
    if (self.onSignOut) self.onSignOut();
}

@end
