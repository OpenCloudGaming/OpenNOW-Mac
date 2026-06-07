#import "OPNGameCatalogView.h"
#import "OPNLoadingView.h"
#import "../common/OPNColorTokens.h"
#include "../common/OPNSentry.h"
#include "../common/OPNGameRemediation.h"
#import "../common/OPNUIHelpers.h"
#include "../streaming/OPNStreamPreferences.h"
#import <GameController/GameController.h>
#include <QuartzCore/QuartzCore.h>
#include <algorithm>
#include <cctype>
#include <cmath>
#include <limits>
#include <memory>

static const CGFloat kStoreTopInset = 0.0;
static const CGFloat kStoreNavigationClearance = 0.0;
static const CGFloat kStoreHeroHeightRatio = 0.3229;
static const CGFloat kStoreRowHeight = 282.0;
static const CGFloat kStoreCardSpacing = 18.0;
static const CGFloat kStoreTileWidth = 268.0;
static const CGFloat kStoreTileHeight = 151.0;
static const CGFloat kStoreHeroMinContentInset = 30.0;
static const CGFloat kStoreHeroMaxContentInset = 106.0;
static const CGFloat kStoreHeroContentInsetRatio = 0.055;
static const CGFloat kStoreFallbackHeroAspect = 1.0 / kStoreHeroHeightRatio;
static const CGFloat kStoreHeroMaxHeight = 820.0;
static const CGFloat kStoreHeroMaxViewportRatio = 0.62;
static const CGFloat kStoreHeroLogoMaxWidth = 520.0;
static const CGFloat kStoreHeroLogoMaxHeight = 180.0;
static const CGFloat kStoreHeroFirstRowSpacing = 64.0;
static const CGFloat kStoreButtonHintPillHeight = 40.0;
static const CGFloat kStoreButtonHintPillBottomInset = 18.0;
static const CGFloat kStoreTopFoldNextRowInset = -100.0;
static const CGFloat kStoreSearchPanelMinWidth = 300.0;
static const CGFloat kStoreSearchPanelMaxWidth = 420.0;
static const CGFloat kStoreRailInertiaMinimumVelocity = 8.0;
static const CGFloat kStoreRailInertiaResistancePerSecond = 0.035;
static const NSInteger kStoreRailImagePreloadCardBuffer = 4;
static const NSTimeInterval kStoreSearchDebounceInterval = 0.18;
static const NSTimeInterval kStoreHeroBackgroundFadeDuration = 0.34;
static const NSTimeInterval kStoreHeroLogoFadeDuration = 0.24;
static const NSTimeInterval kStoreHeroLogoFadeDelay = 0.10;

static CGFloat OPNStoreHeroHeightForWidth(CGFloat width, CGFloat viewportHeight) {
    CGFloat fallbackHeight = MAX(1.0, width) / kStoreFallbackHeroAspect;
    CGFloat viewportHeightLimit = viewportHeight > 0.0 ? viewportHeight * kStoreHeroMaxViewportRatio : fallbackHeight;
    return floor(MIN(kStoreHeroMaxHeight, viewportHeightLimit));
}

static CGFloat OPNStoreNextRowYAfterRow(CGFloat rowY, NSInteger rowIndex, BOOL hasHero, CGFloat viewportHeight) {
    CGFloat nextRowY = rowY + kStoreRowHeight;
    if (hasHero && rowIndex == 0) {
        nextRowY = MAX(nextRowY, floor(MAX(1.0, viewportHeight) + kStoreTopFoldNextRowInset));
    }
    return nextRowY;
}

@interface OPNStoreDocumentView : NSView
@end

@implementation OPNStoreDocumentView
- (BOOL)isFlipped { return YES; }
@end

@interface OPNStoreRailScrollView : NSScrollView
- (void)scrollHorizontallyByDelta:(CGFloat)deltaX;
- (void)beginDragScrollingAtTime:(NSTimeInterval)timestamp;
- (void)dragScrollHorizontallyByDelta:(CGFloat)deltaX timestamp:(NSTimeInterval)timestamp;
- (void)endDragScrollingWithInertia;
@end

@implementation OPNStoreRailScrollView {
    BOOL _dragScrolling;
    NSPoint _lastDragLocation;
    CGFloat _dragScrollVelocity;
    NSTimeInterval _lastDragScrollTimestamp;
    NSTimer *_inertiaTimer;
    NSTimeInterval _lastInertiaTimestamp;
}

- (void)dealloc {
    [_inertiaTimer invalidate];
}

- (void)stopInertia {
    [_inertiaTimer invalidate];
    _inertiaTimer = nil;
    _dragScrollVelocity = 0.0;
}

- (BOOL)canScrollHorizontallyByDelta:(CGFloat)deltaX {
    NSView *documentView = self.documentView;
    if (!documentView) return NO;
    CGFloat maxX = MAX(0.0, NSWidth(documentView.frame) - NSWidth(self.contentView.bounds));
    CGFloat currentX = self.contentView.bounds.origin.x;
    if (maxX <= 0.5) return NO;
    if (deltaX < 0.0) return currentX > 0.5;
    if (deltaX > 0.0) return currentX < maxX - 0.5;
    return NO;
}

- (void)scrollHorizontallyByDelta:(CGFloat)deltaX {
    NSView *documentView = self.documentView;
    if (!documentView) return;
    CGFloat maxX = MAX(0.0, NSWidth(documentView.frame) - NSWidth(self.contentView.bounds));
    NSPoint origin = self.contentView.bounds.origin;
    origin.x = MIN(maxX, MAX(0.0, origin.x + deltaX));
    [self.contentView scrollToPoint:origin];
    [self reflectScrolledClipView:self.contentView];
}

- (void)beginDragScrollingAtTime:(NSTimeInterval)timestamp {
    [self stopInertia];
    _dragScrollVelocity = 0.0;
    _lastDragScrollTimestamp = timestamp;
}

- (void)dragScrollHorizontallyByDelta:(CGFloat)deltaX timestamp:(NSTimeInterval)timestamp {
    NSTimeInterval elapsed = timestamp - _lastDragScrollTimestamp;
    if (elapsed > 0.001) {
        CGFloat sampledVelocity = deltaX / (CGFloat)elapsed;
        _dragScrollVelocity = _dragScrollVelocity == 0.0 ? sampledVelocity : (_dragScrollVelocity * 0.55 + sampledVelocity * 0.45);
    }
    _lastDragScrollTimestamp = timestamp;
    [self scrollHorizontallyByDelta:deltaX];
}

- (void)inertiaTimerFired:(NSTimer *)timer {
    (void)timer;
    NSTimeInterval now = CACurrentMediaTime();
    NSTimeInterval elapsed = MAX(0.001, now - _lastInertiaTimestamp);
    _lastInertiaTimestamp = now;
    if (std::fabs(_dragScrollVelocity) < kStoreRailInertiaMinimumVelocity ||
        ![self canScrollHorizontallyByDelta:_dragScrollVelocity > 0.0 ? 1.0 : -1.0]) {
        [self stopInertia];
        return;
    }

    [self scrollHorizontallyByDelta:_dragScrollVelocity * (CGFloat)elapsed];
    _dragScrollVelocity *= std::pow(kStoreRailInertiaResistancePerSecond, (CGFloat)elapsed);
}

- (void)endDragScrollingWithInertia {
    [_inertiaTimer invalidate];
    _inertiaTimer = nil;
    if (std::fabs(_dragScrollVelocity) < kStoreRailInertiaMinimumVelocity) {
        _dragScrollVelocity = 0.0;
        return;
    }
    _lastInertiaTimestamp = CACurrentMediaTime();
    _inertiaTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60.0
                                                     target:self
                                                   selector:@selector(inertiaTimerFired:)
                                                   userInfo:nil
                                                    repeats:YES];
}

- (void)mouseDown:(NSEvent *)event {
    NSView *documentView = self.documentView;
    CGFloat maxX = documentView ? MAX(0.0, NSWidth(documentView.frame) - NSWidth(self.contentView.bounds)) : 0.0;
    if (maxX <= 0.5) {
        [super mouseDown:event];
        return;
    }
    _dragScrolling = YES;
    _lastDragLocation = [self convertPoint:event.locationInWindow fromView:nil];
    [self beginDragScrollingAtTime:event.timestamp];
}

- (void)mouseDragged:(NSEvent *)event {
    if (!_dragScrolling) {
        [super mouseDragged:event];
        return;
    }
    NSPoint location = [self convertPoint:event.locationInWindow fromView:nil];
    CGFloat deltaX = _lastDragLocation.x - location.x;
    _lastDragLocation = location;
    [self dragScrollHorizontallyByDelta:deltaX timestamp:event.timestamp];
}

- (void)mouseUp:(NSEvent *)event {
    (void)event;
    if (_dragScrolling) [self endDragScrollingWithInertia];
    _dragScrolling = NO;
}

- (void)scrollWheel:(NSEvent *)event {
    CGFloat horizontal = std::fabs(event.scrollingDeltaX);
    CGFloat vertical = std::fabs(event.scrollingDeltaY);
    if (vertical > horizontal) {
        NSScrollView *pageScrollView = self.enclosingScrollView;
        if (pageScrollView && pageScrollView != self) {
            [pageScrollView scrollWheel:event];
            return;
        }
    }
    [super scrollWheel:event];
}

@end

@interface OPNStoreHintFixedView : NSView
@property (nonatomic, assign) NSSize fixedSize;
@end

@implementation OPNStoreHintFixedView
- (NSSize)intrinsicContentSize { return self.fixedSize; }
@end

@interface OPNStoreControllerGlyphView : NSView
@property (nonatomic, copy) NSString *glyph;
@end

@implementation OPNStoreControllerGlyphView

- (BOOL)isFlipped { return YES; }

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSColor *color = OpnColor(OPN::kTextPrimary, 0.92);
    NSString *glyph = self.glyph ?: @"";
    NSRect bounds = NSInsetRect(self.bounds, 1.0, 1.0);
    CGFloat minSide = MIN(NSWidth(bounds), NSHeight(bounds));
    NSRect circleRect = NSMakeRect(NSMidX(bounds) - minSide * 0.42, NSMidY(bounds) - minSide * 0.42, minSide * 0.84, minSide * 0.84);

    if ([glyph isEqualToString:@"dpad"]) {
        [color setFill];
        CGFloat arm = floor(minSide * 0.22);
        CGFloat length = floor(minSide * 0.76);
        NSRect horizontal = NSMakeRect(NSMidX(bounds) - length * 0.5, NSMidY(bounds) - arm * 0.5, length, arm);
        NSRect vertical = NSMakeRect(NSMidX(bounds) - arm * 0.5, NSMidY(bounds) - length * 0.5, arm, length);
        [[NSBezierPath bezierPathWithRoundedRect:horizontal xRadius:arm * 0.38 yRadius:arm * 0.38] fill];
        [[NSBezierPath bezierPathWithRoundedRect:vertical xRadius:arm * 0.38 yRadius:arm * 0.38] fill];
        return;
    }

    if ([glyph isEqualToString:@"stick"]) {
        [color setStroke];
        NSBezierPath *outer = [NSBezierPath bezierPathWithOvalInRect:circleRect];
        outer.lineWidth = 1.8;
        [outer stroke];
        NSRect inner = NSInsetRect(circleRect, minSide * 0.18, minSide * 0.18);
        [[NSBezierPath bezierPathWithOvalInRect:inner] fill];
        return;
    }

    [color setStroke];
    NSBezierPath *button = [NSBezierPath bezierPathWithOvalInRect:circleRect];
    button.lineWidth = 1.8;
    [button stroke];

    if ([glyph isEqualToString:@"triangle"]) {
        NSBezierPath *path = [NSBezierPath bezierPath];
        [path moveToPoint:NSMakePoint(NSMidX(circleRect), NSMinY(circleRect) + NSHeight(circleRect) * 0.25)];
        [path lineToPoint:NSMakePoint(NSMinX(circleRect) + NSWidth(circleRect) * 0.25, NSMaxY(circleRect) - NSHeight(circleRect) * 0.25)];
        [path lineToPoint:NSMakePoint(NSMaxX(circleRect) - NSWidth(circleRect) * 0.25, NSMaxY(circleRect) - NSHeight(circleRect) * 0.25)];
        [path closePath];
        path.lineWidth = 1.7;
        [path stroke];
        return;
    }

    if ([glyph isEqualToString:@"cross"]) {
        NSBezierPath *path = [NSBezierPath bezierPath];
        CGFloat inset = minSide * 0.28;
        [path moveToPoint:NSMakePoint(NSMinX(circleRect) + inset, NSMinY(circleRect) + inset)];
        [path lineToPoint:NSMakePoint(NSMaxX(circleRect) - inset, NSMaxY(circleRect) - inset)];
        [path moveToPoint:NSMakePoint(NSMaxX(circleRect) - inset, NSMinY(circleRect) + inset)];
        [path lineToPoint:NSMakePoint(NSMinX(circleRect) + inset, NSMaxY(circleRect) - inset)];
        path.lineWidth = 2.0;
        [path stroke];
        return;
    }

    if ([glyph isEqualToString:@"square"]) {
        CGFloat inset = minSide * 0.25;
        NSRect squareRect = NSInsetRect(circleRect, inset, inset);
        NSBezierPath *path = [NSBezierPath bezierPathWithRect:squareRect];
        path.lineWidth = 1.8;
        [path stroke];
        return;
    }

    NSString *label = glyph.uppercaseString;
    NSDictionary<NSAttributedStringKey, id> *attributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12.0 weight:NSFontWeightBlack],
        NSForegroundColorAttributeName: color,
    };
    NSSize labelSize = [label sizeWithAttributes:attributes];
    NSRect labelRect = NSMakeRect(floor(NSMidX(circleRect) - labelSize.width * 0.5),
                                  floor(NSMidY(circleRect) - labelSize.height * 0.5) - 0.5,
                                  labelSize.width,
                                  labelSize.height);
    [label drawInRect:labelRect withAttributes:attributes];
}

@end

@interface OPNStoreHintPillView : NSView
@end

@implementation OPNStoreHintPillView
- (BOOL)isFlipped { return YES; }

- (NSView *)hitTest:(NSPoint)point {
    (void)point;
    return nil;
}
@end

typedef NS_ENUM(NSInteger, OPNStoreControllerFamily) {
    OPNStoreControllerFamilyKeyboard = 0,
    OPNStoreControllerFamilyXbox,
    OPNStoreControllerFamilyPlayStation,
    OPNStoreControllerFamilyNintendo,
    OPNStoreControllerFamilyGeneric,
};

struct OPNStoreControllerHintStyle {
    NSString *selectGlyph;
    NSString *variantGlyph;
};

static NSString *OPNStoreControllerIdentity(GCController *controller) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (controller.vendorName.length > 0) [parts addObject:controller.vendorName];
    if (@available(macOS 11.0, *)) {
        if (controller.productCategory.length > 0) [parts addObject:controller.productCategory];
    }
    return [[parts componentsJoinedByString:@" "] uppercaseString];
}

static OPNStoreControllerFamily OPNStoreConnectedControllerFamily(void) {
    for (GCController *controller in GCController.controllers) {
        if (!controller.extendedGamepad) continue;
        NSString *identity = OPNStoreControllerIdentity(controller);
        if ([identity containsString:@"PLAYSTATION"] ||
            [identity containsString:@"DUALSENSE"] ||
            [identity containsString:@"DUALSHOCK"] ||
            [identity containsString:@"SONY"] ||
            [identity containsString:@"PS4"] ||
            [identity containsString:@"PS5"]) {
            return OPNStoreControllerFamilyPlayStation;
        }
        if ([identity containsString:@"NINTENDO"] ||
            [identity containsString:@"SWITCH"] ||
            [identity containsString:@"JOY-CON"] ||
            [identity containsString:@"JOYCON"] ||
            [identity containsString:@"PRO CONTROLLER"]) {
            return OPNStoreControllerFamilyNintendo;
        }
        if ([identity containsString:@"XBOX"] ||
            [identity containsString:@"MICROSOFT"]) {
            return OPNStoreControllerFamilyXbox;
        }
        return OPNStoreControllerFamilyGeneric;
    }
    return OPNStoreControllerFamilyKeyboard;
}

static OPNStoreControllerHintStyle OPNStoreControllerHintStyleForFamily(OPNStoreControllerFamily family) {
    switch (family) {
        case OPNStoreControllerFamilyPlayStation:
            return {@"cross", @"triangle"};
        case OPNStoreControllerFamilyNintendo:
            return {@"a", @"x"};
        case OPNStoreControllerFamilyXbox:
        case OPNStoreControllerFamilyGeneric:
            return {@"a", @"y"};
        case OPNStoreControllerFamilyKeyboard:
            return {@"", @""};
    }
    return {@"a", @"y"};
}

static NSTextField *OPNStoreHintLabel(NSString *text, CGFloat fontSize, NSFontWeight weight, NSColor *color) {
    NSTextField *label = OpnLabel(text, NSZeroRect, fontSize, color, weight, NSTextAlignmentCenter);
    [label setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [label setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    return label;
}

static OPNStoreHintFixedView *OPNStoreHintKeyView(NSString *symbolName, NSString *fallback, CGFloat width) {
    OPNStoreHintFixedView *keyView = [[OPNStoreHintFixedView alloc] initWithFrame:NSMakeRect(0.0, 0.0, width, 24.0)];
    keyView.fixedSize = NSMakeSize(width, 24.0);
    keyView.wantsLayer = YES;
    keyView.layer.backgroundColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.13].CGColor;
    keyView.layer.borderColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.18].CGColor;
    keyView.layer.borderWidth = 1.0;
    keyView.layer.cornerRadius = 7.0;
    keyView.layer.masksToBounds = YES;

    NSImage *symbolImage = nil;
    if (@available(macOS 11.0, *)) {
        symbolImage = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:fallback];
        [symbolImage setTemplate:YES];
    }

    if (symbolImage) {
        NSImageView *imageView = [[NSImageView alloc] initWithFrame:NSInsetRect(keyView.bounds, 5.0, 4.0)];
        imageView.image = symbolImage;
        imageView.imageScaling = NSImageScaleProportionallyDown;
        if (@available(macOS 10.14, *)) imageView.contentTintColor = OpnColor(OPN::kTextPrimary, 0.92);
        imageView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [keyView addSubview:imageView];
    } else {
        NSTextField *fallbackLabel = OPNStoreHintLabel(fallback, 12.0, NSFontWeightBold, OpnColor(OPN::kTextPrimary, 0.92));
        fallbackLabel.frame = NSInsetRect(keyView.bounds, 4.0, 5.0);
        fallbackLabel.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [keyView addSubview:fallbackLabel];
    }

    return keyView;
}

static OPNStoreHintFixedView *OPNStoreControllerIconKeyView(NSString *glyph, CGFloat width) {
    OPNStoreHintFixedView *keyView = [[OPNStoreHintFixedView alloc] initWithFrame:NSMakeRect(0.0, 0.0, width, 24.0)];
    keyView.fixedSize = NSMakeSize(width, 24.0);
    keyView.wantsLayer = YES;
    keyView.layer.backgroundColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.13].CGColor;
    keyView.layer.borderColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.18].CGColor;
    keyView.layer.borderWidth = 1.0;
    keyView.layer.cornerRadius = 7.0;
    keyView.layer.masksToBounds = YES;

    OPNStoreControllerGlyphView *glyphView = [[OPNStoreControllerGlyphView alloc] initWithFrame:NSInsetRect(keyView.bounds, 4.0, 3.0)];
    glyphView.glyph = glyph;
    glyphView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [keyView addSubview:glyphView];
    return keyView;
}

static NSStackView *OPNStoreHintGroup(NSArray<OPNStoreHintFixedView *> *keys, NSString *title) {
    NSStackView *group = [[NSStackView alloc] initWithFrame:NSZeroRect];
    group.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    group.alignment = NSLayoutAttributeCenterY;
    group.distribution = NSStackViewDistributionGravityAreas;
    group.spacing = 5.0;
    for (OPNStoreHintFixedView *key in keys) [group addArrangedSubview:key];
    NSTextField *label = OPNStoreHintLabel(title, 12.0, NSFontWeightSemibold, OpnColor(OPN::kTextSecondary));
    [group addArrangedSubview:label];
    return group;
}

static CGFloat OPNStoreHeroContentInsetForWidth(CGFloat width) {
    return MIN(kStoreHeroMaxContentInset, MAX(kStoreHeroMinContentInset, width * kStoreHeroContentInsetRatio));
}

static CGFloat OPNStoreTileWidthForRailWidth(CGFloat width) {
    CGFloat idealColumns = MAX(1.0, (width + kStoreCardSpacing) / (kStoreTileWidth + kStoreCardSpacing));
    CGFloat columns = MAX(1.0, std::round(idealColumns));
    return floor((width - kStoreCardSpacing * (columns - 1.0)) / columns);
}

static NSSize OPNStoreTileMetricsForRailWidth(CGFloat width) {
    static NSMutableDictionary<NSNumber *, NSValue *> *metricsByWidth;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        metricsByWidth = [NSMutableDictionary dictionary];
    });
    CGFloat bucketedWidth = floor(MAX(320.0, width));
    NSNumber *key = @(bucketedWidth);
    NSValue *cached = metricsByWidth[key];
    if (cached) return cached.sizeValue;
    CGFloat tileWidth = OPNStoreTileWidthForRailWidth(bucketedWidth);
    CGFloat tileHeight = floor(tileWidth * kStoreTileHeight / kStoreTileWidth);
    NSSize metrics = NSMakeSize(tileWidth, tileHeight);
    metricsByWidth[key] = [NSValue valueWithSize:metrics];
    return metrics;
}

static NSString *OPNStoreString(const std::string &value, NSString *fallback) {
    return value.empty() ? (fallback ?: @"") : [NSString stringWithUTF8String:value.c_str()];
}

static NSString *OPNStoreSearchNormalizedString(NSString *value) {
    NSString *folded = [[value ?: @"" stringByFoldingWithOptions:NSDiacriticInsensitiveSearch | NSCaseInsensitiveSearch locale:NSLocale.currentLocale] lowercaseString];
    NSMutableString *normalized = [NSMutableString stringWithCapacity:folded.length];
    NSCharacterSet *alphanumeric = NSCharacterSet.alphanumericCharacterSet;
    BOOL previousWasSpace = YES;
    for (NSUInteger i = 0; i < folded.length; i++) {
        unichar c = [folded characterAtIndex:i];
        if ([alphanumeric characterIsMember:c]) {
            [normalized appendFormat:@"%C", c];
            previousWasSpace = NO;
        } else if (!previousWasSpace) {
            [normalized appendString:@" "];
            previousWasSpace = YES;
        }
    }
    return [normalized stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSArray<NSString *> *OPNStoreSearchTokens(NSString *normalized) {
    if (normalized.length == 0) return @[];
    NSArray<NSString *> *rawTokens = [normalized componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *token in rawTokens) {
        if (token.length > 0) [tokens addObject:token];
    }
    return tokens;
}

static NSString *OPNStoreSearchAcronym(NSArray<NSString *> *tokens) {
    NSMutableString *acronym = [NSMutableString stringWithCapacity:tokens.count];
    for (NSString *token in tokens) {
        if (token.length > 0) [acronym appendString:[token substringToIndex:1]];
    }
    return acronym;
}

static BOOL OPNStoreSearchIsSubsequence(NSString *needle, NSString *haystack) {
    if (needle.length == 0) return YES;
    NSUInteger needleIndex = 0;
    for (NSUInteger i = 0; i < haystack.length && needleIndex < needle.length; i++) {
        if ([needle characterAtIndex:needleIndex] == [haystack characterAtIndex:i]) needleIndex++;
    }
    return needleIndex == needle.length;
}

static NSInteger OPNStoreSearchEditDistance(NSString *left, NSString *right, NSInteger limit) {
    NSUInteger leftLength = left.length;
    NSUInteger rightLength = right.length;
    if (leftLength == 0) return (NSInteger)rightLength;
    if (rightLength == 0) return (NSInteger)leftLength;
    if (llabs((long long)leftLength - (long long)rightLength) > limit) return limit + 1;

    std::vector<NSInteger> previous(rightLength + 1, 0);
    std::vector<NSInteger> current(rightLength + 1, 0);
    for (NSUInteger j = 0; j <= rightLength; j++) previous[j] = (NSInteger)j;
    for (NSUInteger i = 1; i <= leftLength; i++) {
        current[0] = (NSInteger)i;
        NSInteger best = current[0];
        unichar leftChar = [left characterAtIndex:i - 1];
        for (NSUInteger j = 1; j <= rightLength; j++) {
            NSInteger cost = leftChar == [right characterAtIndex:j - 1] ? 0 : 1;
            current[j] = MIN(MIN(current[j - 1] + 1, previous[j] + 1), previous[j - 1] + cost);
            best = MIN(best, current[j]);
        }
        if (best > limit) return limit + 1;
        std::swap(previous, current);
    }
    return previous[rightLength];
}

static NSInteger OPNStoreSearchTokenScore(NSString *queryToken, NSArray<NSString *> *titleTokens) {
    NSInteger best = 0;
    for (NSString *titleToken in titleTokens) {
        if ([titleToken isEqualToString:queryToken]) best = MAX(best, 120);
        else if ([titleToken hasPrefix:queryToken]) best = MAX(best, 95 - (NSInteger)MIN((NSUInteger)20, titleToken.length - queryToken.length));
        else if ([titleToken containsString:queryToken]) best = MAX(best, 70);
        else if (queryToken.length >= 3 && OPNStoreSearchIsSubsequence(queryToken, titleToken)) best = MAX(best, 48);
        if (queryToken.length >= 4) {
            NSInteger limit = queryToken.length <= 5 ? 1 : 2;
            NSInteger distance = OPNStoreSearchEditDistance(queryToken, titleToken, limit);
            if (distance <= limit) best = MAX(best, 58 - distance * 12);
        }
    }
    return best;
}

static NSInteger OPNStoreSearchScoreForTitle(NSString *title, NSString *query) {
    NSString *normalizedQuery = OPNStoreSearchNormalizedString(query);
    if (normalizedQuery.length == 0) return 1;
    NSString *normalizedTitle = OPNStoreSearchNormalizedString(title);
    if (normalizedTitle.length == 0) return 0;
    NSArray<NSString *> *queryTokens = OPNStoreSearchTokens(normalizedQuery);
    NSArray<NSString *> *titleTokens = OPNStoreSearchTokens(normalizedTitle);
    if (queryTokens.count == 0 || titleTokens.count == 0) return 0;

    NSInteger score = 0;
    if ([normalizedTitle isEqualToString:normalizedQuery]) score += 1200;
    else if ([normalizedTitle hasPrefix:normalizedQuery]) score += 850;
    else if ([normalizedTitle containsString:normalizedQuery]) score += 650;

    NSString *titleAcronym = OPNStoreSearchAcronym(titleTokens);
    NSString *queryAcronym = [normalizedQuery stringByReplacingOccurrencesOfString:@" " withString:@""];
    if (queryAcronym.length > 1 && [titleAcronym hasPrefix:queryAcronym]) score += 420;

    NSInteger tokenScore = 0;
    for (NSString *queryToken in queryTokens) {
        NSInteger best = OPNStoreSearchTokenScore(queryToken, titleTokens);
        if (best <= 0) return score >= 650 ? score : 0;
        tokenScore += best;
    }
    score += tokenScore;
    score += MAX(0, 80 - (NSInteger)normalizedTitle.length);
    return score;
}

static std::vector<OPN::GameInfo> OPNStoreSearchFilteredGames(const std::vector<OPN::GameInfo> &games, NSString *query) {
    if (OPNStoreSearchNormalizedString(query).length == 0) return games;
    std::vector<std::pair<NSInteger, OPN::GameInfo>> scored;
    scored.reserve(games.size());
    for (const OPN::GameInfo &game : games) {
        NSInteger score = OPNStoreSearchScoreForTitle(OPNStoreString(game.title, @""), query);
        if (score > 0) scored.push_back({score, game});
    }
    std::stable_sort(scored.begin(), scored.end(), [](const auto &left, const auto &right) {
        return left.first > right.first;
    });
    std::vector<OPN::GameInfo> result;
    result.reserve(scored.size());
    for (const auto &entry : scored) result.push_back(entry.second);
    return result;
}

static std::vector<OPN::PanelResult> OPNStoreSearchFilteredPanels(const std::vector<OPN::PanelResult> &panels, NSString *query) {
    if (OPNStoreSearchNormalizedString(query).length == 0) return panels;
    std::vector<OPN::PanelResult> filteredPanels;
    for (const OPN::PanelResult &panel : panels) {
        OPN::PanelResult filteredPanel = panel;
        filteredPanel.sections.clear();
        for (const OPN::PanelSection &section : panel.sections) {
            OPN::PanelSection filteredSection = section;
            filteredSection.games = OPNStoreSearchFilteredGames(section.games, query);
            if (!filteredSection.games.empty()) filteredPanel.sections.push_back(filteredSection);
        }
        if (!filteredPanel.sections.empty()) filteredPanels.push_back(filteredPanel);
    }
    return filteredPanels;
}

static NSString *OPNStoreDisplayLabel(NSString *value) {
    NSString *trimmed = [[value ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] uppercaseString];
    if (trimmed.length == 0) return @"";
    NSDictionary<NSString *, NSString *> *specialLabels = @{
        @"FREE_TO_PLAY": @"Free to Play",
        @"MASSIVELY_MULTIPLAYER_ONLINE": @"MMO",
        @"MASSIVELY_MULTIPLAYER": @"MMO",
        @"KEYBOARD_MOUSE": @"Keyboard + Mouse",
        @"GAMEPAD_PARTIAL": @"Partial Gamepad",
    };
    NSString *normalized = [trimmed stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
    NSString *special = specialLabels[normalized];
    if (special.length > 0) return special;

    NSString *spaced = [[trimmed.lowercaseString stringByReplacingOccurrencesOfString:@"_" withString:@" "] stringByReplacingOccurrencesOfString:@"-" withString:@" "];
    NSArray<NSString *> *tokens = [spaced componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSSet<NSString *> *acronyms = [NSSet setWithArray:@[@"ai", @"dlc", @"fps", @"hdr", @"mmo", @"moba", @"pve", @"pvp", @"rpg", @"rtx", @"vr"]];
    NSMutableArray<NSString *> *labels = [NSMutableArray array];
    for (NSString *token in tokens) {
        if (token.length == 0) continue;
        if ([acronyms containsObject:token]) {
            [labels addObject:token.uppercaseString];
            continue;
        }
        NSString *first = [token substringToIndex:1].uppercaseString;
        NSString *rest = token.length > 1 ? [token substringFromIndex:1] : @"";
        [labels addObject:[first stringByAppendingString:rest]];
    }
    return labels.count > 0 ? [labels componentsJoinedByString:@" "] : value;
}

static NSString *OPNStoreDisplayString(const std::string &value, NSString *fallback) {
    NSString *display = OPNStoreDisplayLabel(OPNStoreString(value, @""));
    return display.length > 0 ? display : (fallback ?: @"");
}

static NSString *OPNStoreIconAssetName(NSString *name) {
    NSString *upper = (name ?: @"").uppercaseString;
    if ([upper containsString:@"STEAM"]) return @"steam";
    if ([upper containsString:@"EPIC"] || [upper containsString:@"EGS"]) return @"epic";
    if ([upper containsString:@"UBISOFT"] || [upper containsString:@"UPLAY"]) return @"ubisoft";
    if ([upper containsString:@"BATTLE"]) return @"battlenet";
    if ([upper containsString:@"XBOX"] || [upper containsString:@"MICROSOFT"]) return @"xbox";
    if ([upper containsString:@"EA"] || [upper containsString:@"ORIGIN"]) return @"ea";
    if ([upper containsString:@"GOG"]) return @"gog";
    return @"default";
}

static NSOperationQueue *OPNStoreIconLoaderQueue(void) {
    static NSOperationQueue *queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = [[NSOperationQueue alloc] init];
        queue.name = @"com.opennow.store-icon-loader";
        queue.maxConcurrentOperationCount = 2;
        queue.qualityOfService = NSQualityOfServiceUtility;
    });
    return queue;
}

static NSArray<NSString *> *OPNStoreIconCandidatePaths(NSString *assetName) {
    NSString *safeAssetName = assetName.length > 0 ? assetName : @"default";
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSString *bundlePath = [[NSBundle mainBundle] pathForResource:safeAssetName ofType:@"svg" inDirectory:@"store-icons"];
    if (bundlePath.length > 0) [paths addObject:bundlePath];
    NSString *relativePath = [NSString stringWithFormat:@"assets/store-icons/%@.svg", safeAssetName];
    [paths addObject:[NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:relativePath]];
    [paths addObject:[@"/Volumes/Projects/OpenNOW-Mac" stringByAppendingPathComponent:relativePath]];
    return paths;
}

static void OPNReadStoreIconDataAtPath(NSString *path, void (^completion)(NSData *data)) {
    if (!completion) return;
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    dispatch_io_t channel = dispatch_io_create_with_path(DISPATCH_IO_STREAM, path.fileSystemRepresentation, O_RDONLY, 0, queue, ^(int error) { (void)error; });
    if (!channel) {
        completion(nil);
        return;
    }
    NSMutableData *result = [NSMutableData data];
    dispatch_io_read(channel, 0, SIZE_MAX, queue, ^(bool done, dispatch_data_t data, int error) {
        if (data && error == 0) {
            dispatch_data_apply(data, ^bool(dispatch_data_t region, size_t offset, const void *buffer, size_t size) {
                (void)region;
                (void)offset;
                [result appendBytes:buffer length:size];
                return true;
            });
        }
        if (!done) return;
        dispatch_io_close(channel, 0);
        completion(error == 0 && result.length > 0 ? [result copy] : nil);
    });
}

static void OPNLoadStoreIconDataFromPaths(NSArray<NSString *> *paths, NSUInteger index, void (^completion)(NSData *data)) {
    if (index >= paths.count) {
        completion(nil);
        return;
    }
    OPNReadStoreIconDataAtPath(paths[index], ^(NSData *data) {
        if (data.length > 0) {
            completion(data);
            return;
        }
        OPNLoadStoreIconDataFromPaths(paths, index + 1, completion);
    });
}

static NSImage *OPNStoreIconPlaceholderImage(NSString *name) {
    static NSMutableDictionary<NSString *, NSImage *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ cache = [NSMutableDictionary dictionary]; });
    NSString *assetName = OPNStoreIconAssetName(name);
    NSImage *cached = cache[assetName];
    if (cached) return cached;

    NSDictionary<NSString *, NSString *> *labels = @{
        @"steam": @"ST",
        @"epic": @"EP",
        @"ubisoft": @"UB",
        @"battlenet": @"BN",
        @"xbox": @"XB",
        @"ea": @"EA",
        @"gog": @"GOG",
        @"default": @"CL",
    };
    NSDictionary<NSString *, NSColor *> *fills = @{
        @"steam": OpnColor(0x1B2838, 1.0),
        @"epic": OpnColor(0x202020, 1.0),
        @"ubisoft": OpnColor(0x3D61FF, 1.0),
        @"battlenet": OpnColor(0x149BFF, 1.0),
        @"xbox": OpnColor(0x107C10, 1.0),
        @"ea": OpnColor(0xFF4747, 1.0),
        @"gog": OpnColor(0x6D3DF5, 1.0),
        @"default": OpnColor(OPN::kBrandGreen, 1.0),
    };

    NSSize size = NSMakeSize(64.0, 64.0);
    NSImage *image = [[NSImage alloc] initWithSize:size];
    [image lockFocus];
    NSRect bounds = NSMakeRect(0.0, 0.0, size.width, size.height);
    [(fills[assetName] ?: fills[@"default"]) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:bounds xRadius:14.0 yRadius:14.0] fill];
    NSString *label = labels[assetName] ?: labels[@"default"];
    NSDictionary<NSAttributedStringKey, id> *attributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:label.length > 2 ? 18.0 : 23.0 weight:NSFontWeightBlack],
        NSForegroundColorAttributeName: NSColor.whiteColor,
    };
    NSSize labelSize = [label sizeWithAttributes:attributes];
    [label drawAtPoint:NSMakePoint(floor((size.width - labelSize.width) * 0.5), floor((size.height - labelSize.height) * 0.5) - 1.0) withAttributes:attributes];
    [image unlockFocus];
    cache[assetName] = image;
    return image;
}

static NSMutableDictionary<NSString *, NSImage *> *OPNStoreIconImageCache(void) {
    static NSMutableDictionary<NSString *, NSImage *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ cache = [NSMutableDictionary dictionary]; });
    return cache;
}

static NSImage *OPNCachedStoreIconImage(NSString *name) {
    return OPNStoreIconImageCache()[OPNStoreIconAssetName(name)];
}

static NSImage *OPNStoreGreyscaleIconImage(NSImage *image) {
    NSImage *templateImage = image ? [image copy] : nil;
    [templateImage setTemplate:YES];
    return templateImage;
}

static void OPNLoadStoreIconImage(NSString *name, void (^completion)(NSImage *image)) {
    NSString *assetName = OPNStoreIconAssetName(name);
    NSImage *cached = OPNCachedStoreIconImage(name);
    if (cached) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(cached); });
        return;
    }
    NSArray<NSString *> *paths = OPNStoreIconCandidatePaths(assetName);
    [OPNStoreIconLoaderQueue() addOperationWithBlock:^{
        OPNLoadStoreIconDataFromPaths(paths, 0, ^(NSData *data) {
            NSImage *image = data.length > 0 ? [[NSImage alloc] initWithData:data] : nil;
            if (!image && ![assetName isEqualToString:@"default"]) {
                OPNLoadStoreIconDataFromPaths(OPNStoreIconCandidatePaths(@"default"), 0, ^(NSData *defaultData) {
                    NSImage *defaultImage = defaultData.length > 0 ? [[NSImage alloc] initWithData:defaultData] : nil;
                    if (defaultImage) [defaultImage setTemplate:NO];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (defaultImage) OPNStoreIconImageCache()[assetName] = defaultImage;
                        if (completion) completion(defaultImage);
                    });
                });
                return;
            }
            if (image) [image setTemplate:NO];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (image) OPNStoreIconImageCache()[assetName] = image;
                if (completion) completion(image);
            });
        });
    }];
}

static NSImage *OPNStoreFallbackArtworkImage(void) {
    return OpnFallbackHeroArtworkImage();
}

static NSString *OPNStorePrimaryStoreName(const OPN::GameInfo &game) {
    std::string raw;
    if (!game.variants.empty()) raw = game.variants.front().appStore;
    if (raw.empty() && !game.availableStores.empty()) raw = game.availableStores.front();
    NSString *name = raw.empty() ? @"Cloud" : [NSString stringWithUTF8String:raw.c_str()];
    NSString *upper = name.uppercaseString;
    if ([upper containsString:@"STEAM"]) return @"Steam";
    if ([upper containsString:@"BATTLE"]) return @"Battle.net";
    if ([upper containsString:@"UBISOFT"] || [upper containsString:@"UPLAY"]) return @"Ubisoft";
    if ([upper containsString:@"XBOX"]) return @"Xbox";
    if ([upper containsString:@"EPIC"]) return @"Epic";
    if ([upper containsString:@"EA"]) return @"EA";
    return name.capitalizedString;
}

static NSArray<NSString *> *OPNStoreVariantStoreNames(const OPN::GameInfo &game) {
    NSMutableArray<NSString *> *stores = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    void (^appendStore)(NSString *) = ^(NSString *rawStore) {
        NSString *store = OPNStoreDisplayLabel(rawStore ?: @"");
        if (store.length == 0) return;
        NSString *key = store.uppercaseString;
        if ([seen containsObject:key]) return;
        [seen addObject:key];
        [stores addObject:store];
    };

    for (const OPN::GameVariant &variant : game.variants) {
        appendStore(OPNStoreString(variant.appStore, @""));
    }
    for (const std::string &store : game.availableStores) {
        appendStore(OPNStoreString(store, @""));
    }
    if (stores.count == 0) [stores addObject:OPNStorePrimaryStoreName(game)];
    return stores;
}

static bool OPNStoreStringEqualsCaseInsensitive(const std::string &lhs, const std::string &rhs) {
    if (lhs.size() != rhs.size()) return false;
    for (size_t i = 0; i < lhs.size(); i++) {
        if (std::tolower((unsigned char)lhs[i]) != std::tolower((unsigned char)rhs[i])) return false;
    }
    return true;
}

static BOOL OPNStoreIsNumericString(const std::string &value) {
    return !value.empty() && value.find_first_not_of("0123456789") == std::string::npos;
}

static void OPNStoreAppendUniqueURL(NSMutableArray<NSString *> *urls, NSString *urlString) {
    NSString *trimmed = [urlString ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0 || [urls containsObject:trimmed]) return;
    [urls addObject:trimmed];
}

static void OPNStoreAppendImageType(NSMutableArray<NSString *> *urls, const OPN::GameInfo &game, const char *type) {
    auto it = game.imageUrlsByType.find(type);
    if (it == game.imageUrlsByType.end()) return;
    for (const std::string &url : it->second) {
        OPNStoreAppendUniqueURL(urls, OPNStoreString(url, @""));
    }
}

static NSString *OPNStoreSteamArtworkURLForGame(const OPN::GameInfo &game) {
    std::string appId;
    for (const OPN::GameVariant &variant : game.variants) {
        if (OPNStoreIsNumericString(variant.id)) {
            NSString *store = OPNStoreString(variant.appStore, @"");
            if ([store.uppercaseString containsString:@"STEAM"]) {
                appId = variant.id;
                break;
            }
        }
    }
    if (appId.empty() && OPNStoreIsNumericString(game.launchAppId)) appId = game.launchAppId;
    if (appId.empty()) return nil;
    return [NSString stringWithFormat:@"https://cdn.cloudflare.steamstatic.com/steam/apps/%s/header.jpg", appId.c_str()];
}

static NSArray<NSString *> *OPNStoreImageCandidatesForGame(const OPN::GameInfo &game, BOOL prominent) {
    NSMutableArray<NSString *> *urls = [NSMutableArray array];
    NSArray<NSString *> *preferredTypes = prominent
        ? @[@"MARQUEE_HERO_IMAGE", @"HERO_IMAGE", @"TV_BANNER", @"FEATURE_IMAGE", @"KEY_ART", @"KEY_IMAGE", @"GAME_BOX_ART"]
        : @[@"TV_BANNER", @"HERO_IMAGE", @"KEY_IMAGE", @"KEY_ART", @"GAME_BOX_ART", @"FEATURE_IMAGE"];
    for (NSString *type in preferredTypes) {
        OPNStoreAppendImageType(urls, game, type.UTF8String);
    }
    OPNStoreAppendUniqueURL(urls, OPNStoreString(game.heroImageUrl, @""));
    OPNStoreAppendUniqueURL(urls, OPNStoreString(game.imageUrl, @""));
    for (const std::string &screenshot : game.screenshotUrls) {
        OPNStoreAppendUniqueURL(urls, OPNStoreString(screenshot, @""));
        if (!prominent) break;
    }
    OPNStoreAppendUniqueURL(urls, OPNStoreSteamArtworkURLForGame(game));
    return urls;
}

static NSArray<NSString *> *OPNStoreLogoCandidatesForGame(const OPN::GameInfo &game) {
    NSMutableArray<NSString *> *urls = [NSMutableArray array];
    NSArray<NSString *> *preferredTypes = @[@"GAME_LOGO", @"LOGO", @"TITLE_LOGO"];
    for (NSString *type in preferredTypes) {
        OPNStoreAppendImageType(urls, game, type.UTF8String);
    }
    return urls;
}

static NSImage *OPNStoreVisibleLogoImage(NSImage *image) {
    if (!image || image.size.width <= 0.0 || image.size.height <= 0.0) return image;
    NSRect proposedRect = NSMakeRect(0.0, 0.0, image.size.width, image.size.height);
    CGImageRef source = [image CGImageForProposedRect:&proposedRect context:nil hints:nil];
    if (!source) return image;

    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithCGImage:source];
    NSInteger width = bitmap.pixelsWide;
    NSInteger height = bitmap.pixelsHigh;
    if (width <= 0 || height <= 0) return image;

    NSInteger minX = width;
    NSInteger minY = height;
    NSInteger maxX = -1;
    NSInteger maxY = -1;
    for (NSInteger y = 0; y < height; y++) {
        for (NSInteger x = 0; x < width; x++) {
            NSColor *color = [bitmap colorAtX:x y:y];
            if (color.alphaComponent <= 0.04) continue;
            minX = MIN(minX, x);
            minY = MIN(minY, y);
            maxX = MAX(maxX, x);
            maxY = MAX(maxY, y);
        }
    }
    if (maxX < minX || maxY < minY) return image;

    NSInteger padding = MAX((NSInteger)8, (NSInteger)ceil(MAX(maxX - minX + 1, maxY - minY + 1) * 0.04));
    minX = MAX((NSInteger)0, minX - padding);
    minY = MAX((NSInteger)0, minY - padding);
    maxX = MIN(width - 1, maxX + padding);
    maxY = MIN(height - 1, maxY + padding);

    NSInteger cropWidth = maxX - minX + 1;
    NSInteger cropHeight = maxY - minY + 1;
    if (cropWidth <= 0 || cropHeight <= 0) return image;
    if (cropWidth >= width * 0.92 && cropHeight >= height * 0.92) return image;

    CGImageRef cropped = CGImageCreateWithImageInRect(source, CGRectMake((CGFloat)minX, (CGFloat)minY, (CGFloat)cropWidth, (CGFloat)cropHeight));
    if (!cropped) return image;
    NSImage *croppedImage = [[NSImage alloc] initWithCGImage:cropped size:NSMakeSize((CGFloat)cropWidth, (CGFloat)cropHeight)];
    CGImageRelease(cropped);
    return croppedImage ?: image;
}

static NSRect OPNStoreHeroVisibleArtworkRectForImage(NSImage *image, NSRect bounds) {
    if (!image || image.size.width <= 0.0 || image.size.height <= 0.0) return bounds;
    return bounds;
}

static NSRect OPNStoreHeroLogoFrameForImage(NSImage *image, NSRect bounds, NSImage *artworkImage) {
    NSRect artworkRect = OPNStoreHeroVisibleArtworkRectForImage(artworkImage, bounds);
    CGFloat horizontalInset = MIN(OPNStoreHeroContentInsetForWidth(NSWidth(bounds)), MAX(24.0, NSWidth(artworkRect) * 0.08));
    CGFloat maxWidth = MIN(kStoreHeroLogoMaxWidth, MAX(120.0, NSWidth(artworkRect) - horizontalInset * 2.0));
    CGFloat maxHeight = MIN(kStoreHeroLogoMaxHeight, NSHeight(artworkRect) * 0.44);
    CGFloat width = maxWidth;
    CGFloat height = maxHeight;
    if (image.size.width > 0.0 && image.size.height > 0.0) {
        CGFloat aspect = image.size.width / image.size.height;
        if (maxWidth / MAX(1.0, maxHeight) > aspect) {
            height = maxHeight;
            width = floor(height * aspect);
        } else {
            width = maxWidth;
            height = floor(width / aspect);
        }
    }
    CGFloat x = NSMinX(artworkRect) + horizontalInset;
    CGFloat y = NSMinY(artworkRect) + floor((NSHeight(artworkRect) - height) * 0.5);
    return NSMakeRect(x, y, width, height);
}

static NSRect OPNStoreHeroLogoFallbackFrame(NSRect bounds, NSImage *artworkImage) {
    NSRect artworkRect = OPNStoreHeroVisibleArtworkRectForImage(artworkImage, bounds);
    CGFloat horizontalInset = MIN(OPNStoreHeroContentInsetForWidth(NSWidth(bounds)), MAX(24.0, NSWidth(artworkRect) * 0.08));
    CGFloat width = MIN(kStoreHeroLogoMaxWidth, MAX(160.0, NSWidth(artworkRect) - horizontalInset * 2.0));
    CGFloat height = MIN(108.0, MAX(56.0, NSHeight(artworkRect) * 0.22));
    CGFloat x = NSMinX(artworkRect) + horizontalInset;
    CGFloat y = NSMinY(artworkRect) + floor((NSHeight(artworkRect) - height) * 0.5);
    return NSMakeRect(x, y, width, height);
}

static void OPNStoreHeroBringLogoToFront(NSView *container, NSTextField *titleFallback, NSImageView *logoView) {
    if (!container) return;
    if (titleFallback.superview == container) [container addSubview:titleFallback positioned:NSWindowAbove relativeTo:nil];
    if (logoView.superview == container) [container addSubview:logoView positioned:NSWindowAbove relativeTo:nil];
}

static void OPNStoreConfigureHeroLogoImageView(NSImageView *logoView, CGFloat zPosition) {
    logoView.imageScaling = NSImageScaleProportionallyDown;
    logoView.imageAlignment = NSImageAlignLeft;
    logoView.wantsLayer = YES;
    logoView.layer.zPosition = zPosition;
    logoView.layer.shadowColor = OpnColor(OPN::kBlack, 0.90).CGColor;
    logoView.layer.shadowOpacity = 1.0;
    logoView.layer.shadowRadius = 18.0;
    logoView.layer.shadowOffset = CGSizeMake(0.0, -2.0);
}

static BOOL OPNStoreHeroImageHasVisibleContent(NSImage *image) {
    if (!image || image.size.width <= 0.0 || image.size.height <= 0.0) return NO;
    if (image.size.width < 900.0 || image.size.height < 300.0) return NO;
    if (image.size.width / MAX(1.0, image.size.height) < 1.65) return NO;
    NSRect proposedRect = NSMakeRect(0.0, 0.0, image.size.width, image.size.height);
    CGImageRef source = [image CGImageForProposedRect:&proposedRect context:nil hints:nil];
    if (!source) return YES;

    static const size_t sampleWidth = 24;
    static const size_t sampleHeight = 24;
    static const size_t bytesPerPixel = 4;
    static const size_t bytesPerRow = sampleWidth * bytesPerPixel;
    std::vector<unsigned char> pixels(sampleHeight * bytesPerRow, 0);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGBitmapInfo bitmapInfo = (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big;
    CGContextRef context = CGBitmapContextCreate(pixels.data(), sampleWidth, sampleHeight, 8, bytesPerRow, colorSpace, bitmapInfo);
    CGColorSpaceRelease(colorSpace);
    if (!context) return YES;
    CGContextDrawImage(context, CGRectMake(0.0, 0.0, sampleWidth, sampleHeight), source);
    CGContextRelease(context);

    NSUInteger visiblePixels = 0;
    NSUInteger opaquePixels = 0;
    for (size_t offset = 0; offset + 3 < pixels.size(); offset += bytesPerPixel) {
        CGFloat alpha = pixels[offset + 3];
        if (alpha > 24.0) visiblePixels++;
        if (alpha > 180.0) opaquePixels++;
    }
    NSUInteger totalPixels = sampleWidth * sampleHeight;
    return visiblePixels >= totalPixels / 3 && opaquePixels >= totalPixels / 5;
}

static NSString *OPNStorePrimaryGenre(const OPN::GameInfo &game) {
    if (!game.genres.empty()) return OPNStoreDisplayString(game.genres.front(), @"Cloud Game");
    if (!game.playType.empty()) return OPNStoreDisplayString(game.playType, @"Cloud Game");
    return @"Cloud Game";
}

static NSString *OPNStoreFeatureSummary(const OPN::GameInfo &game) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (game.maxOnlinePlayers > 1) [parts addObject:[NSString stringWithFormat:@"%d online", game.maxOnlinePlayers]];
    if (game.maxLocalPlayers > 1) [parts addObject:[NSString stringWithFormat:@"%d local", game.maxLocalPlayers]];
    for (const std::string &feature : game.featureLabels) {
        NSString *label = OPNStoreDisplayString(feature, @"");
        if (label.length > 0) [parts addObject:label];
        if (parts.count >= 2) break;
    }
    if (parts.count == 0 && !game.supportedControls.empty()) {
        NSString *control = OPNStoreDisplayString(game.supportedControls.front(), @"");
        if (control.length > 0) [parts addObject:control];
    }
    return parts.count > 0 ? [parts componentsJoinedByString:@" · "] : @"Ready to stream";
}

static bool OPNStoreGameMatchesLibraryGame(const OPN::GameInfo &storeGame, const OPN::GameInfo &libraryGame) {
    if (!storeGame.uuid.empty() && storeGame.uuid == libraryGame.uuid) return true;
    if (!storeGame.id.empty() && storeGame.id == libraryGame.id) return true;
    if (!storeGame.launchAppId.empty() && storeGame.launchAppId == libraryGame.launchAppId) return true;
    if (!storeGame.title.empty() && OPNStoreStringEqualsCaseInsensitive(storeGame.title, libraryGame.title)) return true;
    return false;
}

static bool OPNStoreVariantMatchesMetadata(const OPN::GameVariant &target, const OPN::GameVariant &source) {
    if (!target.id.empty() && !source.id.empty() && target.id == source.id) return true;
    if (!target.appStore.empty() && !source.appStore.empty() && OPNStoreStringEqualsCaseInsensitive(target.appStore, source.appStore)) return true;
    return false;
}

static bool OPNStoreContainsStoreName(const std::vector<std::string> &stores, const std::string &store) {
    for (const std::string &entry : stores) {
        if (OPNStoreStringEqualsCaseInsensitive(entry, store)) return true;
    }
    return false;
}

static bool OPNStoreServiceStatusOwnedForLaunch(const std::string &status) {
    return status == "MANUAL" || status == "PLATFORM_SYNC" || status == "IN_LIBRARY";
}

static bool OPNStoreClearGameOwnershipMetadata(OPN::GameInfo &game) {
    bool changed = false;
    if (game.isInLibrary) {
        game.isInLibrary = false;
        changed = true;
    }
    for (OPN::GameVariant &variant : game.variants) {
        if (variant.inLibrary) {
            variant.inLibrary = false;
            changed = true;
        }
        if (variant.librarySelected) {
            variant.librarySelected = false;
            changed = true;
        }
        if (OPNStoreServiceStatusOwnedForLaunch(variant.serviceStatus)) {
            variant.serviceStatus.clear();
            changed = true;
        }
    }
    return changed;
}

static bool OPNStoreMergeGameStoreMetadata(OPN::GameInfo &target, const OPN::GameInfo &source) {
    bool changed = false;
    if (target.launchAppId.empty() && !source.launchAppId.empty()) {
        target.launchAppId = source.launchAppId;
        changed = true;
    }
    for (const std::string &store : source.availableStores) {
        if (!store.empty() && !OPNStoreContainsStoreName(target.availableStores, store)) {
            target.availableStores.push_back(store);
            changed = true;
        }
    }
    for (const OPN::GameVariant &sourceVariant : source.variants) {
        if (sourceVariant.appStore.empty()) continue;
        bool merged = false;
        for (OPN::GameVariant &targetVariant : target.variants) {
            if (!OPNStoreVariantMatchesMetadata(targetVariant, sourceVariant)) continue;
            if (targetVariant.id.empty() && !sourceVariant.id.empty()) {
                targetVariant.id = sourceVariant.id;
                changed = true;
            }
            if (targetVariant.appStore.empty()) {
                targetVariant.appStore = sourceVariant.appStore;
                changed = true;
            }
            if (targetVariant.storeUrl.empty() && !sourceVariant.storeUrl.empty()) {
                targetVariant.storeUrl = sourceVariant.storeUrl;
                changed = true;
            }
            if (targetVariant.serviceStatus.empty() && !sourceVariant.serviceStatus.empty()) {
                targetVariant.serviceStatus = sourceVariant.serviceStatus;
                changed = true;
            }
            if (!targetVariant.librarySelected && sourceVariant.librarySelected) {
                targetVariant.librarySelected = true;
                changed = true;
            }
            if (!targetVariant.inLibrary && sourceVariant.inLibrary) {
                targetVariant.inLibrary = true;
                changed = true;
            }
            merged = true;
            break;
        }
        if (!merged && !sourceVariant.storeUrl.empty()) {
            target.variants.push_back(sourceVariant);
            if (!OPNStoreContainsStoreName(target.availableStores, sourceVariant.appStore)) {
                target.availableStores.push_back(sourceVariant.appStore);
            }
            changed = true;
        }
    }
    return changed;
}

static void OPNStoreAppendFingerprintField(std::string &fingerprint, const std::string &value) {
    fingerprint.append(std::to_string(value.size()));
    fingerprint.push_back(':');
    fingerprint.append(value);
    fingerprint.push_back('|');
}

static std::string OPNStorePanelsFingerprint(const std::vector<OPN::PanelResult> &panels) {
    std::string fingerprint;
    fingerprint.reserve(panels.size() * 64);
    for (const OPN::PanelResult &panel : panels) {
        OPNStoreAppendFingerprintField(fingerprint, panel.id);
        OPNStoreAppendFingerprintField(fingerprint, panel.title);
        for (const OPN::PanelSection &section : panel.sections) {
            OPNStoreAppendFingerprintField(fingerprint, section.id);
            OPNStoreAppendFingerprintField(fingerprint, section.title);
            for (const OPN::GameInfo &game : section.games) {
                OPNStoreAppendFingerprintField(fingerprint, game.id);
                OPNStoreAppendFingerprintField(fingerprint, game.title);
                OPNStoreAppendFingerprintField(fingerprint, game.imageUrl);
                OPNStoreAppendFingerprintField(fingerprint, game.heroImageUrl);
                fingerprint.append(game.isInLibrary ? "1" : "0");
                fingerprint.push_back('|');
                for (const OPN::GameVariant &variant : game.variants) {
                    OPNStoreAppendFingerprintField(fingerprint, variant.id);
                    OPNStoreAppendFingerprintField(fingerprint, variant.appStore);
                    OPNStoreAppendFingerprintField(fingerprint, variant.storeUrl);
                    OPNStoreAppendFingerprintField(fingerprint, variant.serviceStatus);
                    fingerprint.append(variant.inLibrary ? "1" : "0");
                    fingerprint.append(variant.librarySelected ? "1" : "0");
                    fingerprint.push_back('|');
                }
            }
        }
    }
    return fingerprint;
}

static bool OPNCatalogGameHasAccessibleVariants(const OPN::GameInfo &game);
static OPN::GameInfo OPNCatalogGameWithAccessibleVariants(const OPN::GameInfo &game);

static std::vector<OPN::PanelResult> OPNCatalogPanelsForGames(const std::vector<OPN::GameInfo> &sourceGames) {
    std::vector<OPN::PanelResult> panels;
    OPN::PanelResult panel;
    panel.id = "catalog";
    panel.title = "Library";
    panel.__typename = "CatalogPanel";

    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    OPN::PanelSection currentSection;
    currentSection.id = "catalog-section-1";
    currentSection.title = "Library";
    currentSection.__typename = "CatalogSection";

    NSInteger sectionIndex = 1;
    for (const OPN::GameInfo &game : sourceGames) {
        if (!OPNCatalogGameHasAccessibleVariants(game)) continue;
        OPN::GameInfo catalogGame = OPNCatalogGameWithAccessibleVariants(game);
        NSString *identity = OpnGameIdentityForHero(catalogGame);
        if (identity.length > 0 && [seen containsObject:identity]) continue;
        if (identity.length > 0) [seen addObject:identity];

        if (currentSection.games.size() >= 24) {
            panel.sections.push_back(currentSection);
            sectionIndex++;
            currentSection = OPN::PanelSection();
            currentSection.id = "catalog-section-" + std::to_string((long)sectionIndex);
            currentSection.title = "Library";
            currentSection.__typename = "CatalogSection";
        }
        currentSection.games.push_back(catalogGame);
    }

    if (!currentSection.games.empty()) panel.sections.push_back(currentSection);
    if (!panel.sections.empty()) panels.push_back(panel);
    return panels;
}

static OPN::PanelSection OPNCatalogSingleLibrarySectionForGames(const std::vector<OPN::GameInfo> &sourceGames) {
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    OPN::PanelSection section;
    section.id = "owned-library";
    section.title = "Library";
    section.__typename = "CatalogSection";
    for (const OPN::GameInfo &game : sourceGames) {
        if (!OPNCatalogGameHasAccessibleVariants(game)) continue;
        OPN::GameInfo catalogGame = OPNCatalogGameWithAccessibleVariants(game);
        NSString *identity = OpnGameIdentityForHero(catalogGame);
        if (identity.length > 0 && [seen containsObject:identity]) continue;
        if (identity.length > 0) [seen addObject:identity];
        section.games.push_back(catalogGame);
    }
    return section;
}

static bool OPNStoreVariantIsLibrarySelected(const OPN::GameVariant &variant) {
    return variant.librarySelected || variant.inLibrary || OPNStoreServiceStatusOwnedForLaunch(variant.serviceStatus);
}

static bool OPNCatalogGameHasAccessibleVariants(const OPN::GameInfo &game) {
    if (game.isInLibrary) return true;
    for (const OPN::GameVariant &variant : game.variants) {
        if (OPNStoreVariantIsLibrarySelected(variant)) return true;
    }
    return game.variants.empty();
}

static OPN::GameInfo OPNCatalogGameWithAccessibleVariants(const OPN::GameInfo &game) {
    OPN::GameInfo catalogGame = game;
    catalogGame.isInLibrary = true;
    std::vector<OPN::GameVariant> variants;
    for (OPN::GameVariant variant : game.variants) {
        if (!OPNStoreVariantIsLibrarySelected(variant)) continue;
        variant.inLibrary = true;
        variants.push_back(variant);
    }
    if (!variants.empty()) catalogGame.variants = variants;
    return catalogGame;
}

static int OPNStoreSelectedLibraryVariantIndex(const OPN::GameInfo &libraryGame) {
    for (size_t i = 0; i < libraryGame.variants.size(); i++) {
        if (libraryGame.variants[i].librarySelected) return (int)i;
    }
    for (size_t i = 0; i < libraryGame.variants.size(); i++) {
        if (OPNStoreVariantIsLibrarySelected(libraryGame.variants[i])) return (int)i;
    }
    return libraryGame.variants.empty() ? -1 : 0;
}

static bool OPNStoreVariantIsOwned(const OPN::GameVariant &variant) {
    return OPN::GameVariantOwnedForLaunch(variant);
}

static bool OPNStoreVariantIsNotOwned(const OPN::GameVariant &variant) {
    return !OPNStoreVariantIsOwned(variant);
}

static const OPN::GameVariant *OPNStoreVariantAtIndex(const OPN::GameInfo &game, int variantIndex) {
    if (variantIndex < 0 || variantIndex >= (int)game.variants.size()) return nullptr;
    return &game.variants[(size_t)variantIndex];
}

static bool OPNStoreVariantCanBeMarkedUnowned(const OPN::GameInfo &game, int variantIndex) {
    const OPN::GameVariant *variant = OPNStoreVariantAtIndex(game, variantIndex);
    return variant && !variant->id.empty() && OPNStoreVariantIsOwned(*variant);
}

static bool OPNStoreGameNeedsPurchase(const OPN::GameInfo &game, int variantIndex) {
    const OPN::GameVariant *selectedVariant = OPNStoreVariantAtIndex(game, variantIndex);
    if (selectedVariant) return OPNStoreVariantIsNotOwned(*selectedVariant);
    for (const OPN::GameVariant &variant : game.variants) {
        if (OPNStoreVariantIsNotOwned(variant)) return true;
    }
    return false;
}

static NSString *OPNStorePrimaryActionTitle(const OPN::GameInfo &game, int variantIndex, BOOL prominent) {
    if (OPNStoreGameNeedsPurchase(game, variantIndex)) {
        return prominent ? @"Add to Library" : @"ADD";
    }
    return prominent ? @"Play Now" : @"PLAY";
}

static std::string OPNStoreGameProfileAppId(const OPN::GameInfo &game, int variantIndex) {
    const OPN::GameVariant *variant = OPNStoreVariantAtIndex(game, variantIndex);
    if (variant && !variant->id.empty()) return variant->id;
    if (!game.launchAppId.empty()) return game.launchAppId;
    return game.id;
}

static NSString *OPNStoreAvailabilityTitle(const OPN::GameInfo &game, int variantIndex) {
    if (OPNStoreGameNeedsPurchase(game, variantIndex)) return @"Not owned";
    std::string appId = OPNStoreGameProfileAppId(game, variantIndex);
    if (!appId.empty() && OPN::StreamPreferenceProfileEnabledForGame(appId)) return @"Profile active";
    NSInteger storeCount = MAX((NSInteger)game.availableStores.size(), (NSInteger)game.variants.size());
    return storeCount > 1 ? [NSString stringWithFormat:@"%ld stores", (long)storeCount] : @"Cloud ready";
}

@interface OPNStoreGameTile : NSView
@property (nonatomic, readonly) OPN::GameInfo game;
@property (nonatomic, assign) int selectedVariantIndex;
@property (nonatomic, assign) NSTimeInterval imageRevealDelay;
@property (nonatomic, copy) void (^onSelect)(void);
@property (nonatomic, copy) void (^onBuy)(NSString *purchaseURL);
@property (nonatomic, copy) void (^onMarkUnowned)(void);
@property (nonatomic, copy) void (^onHover)(void);
- (instancetype)initWithFrame:(NSRect)frame game:(const OPN::GameInfo &)game prominent:(BOOL)prominent;
- (void)setStoreFocused:(BOOL)focused;
- (void)activate;
- (void)cycleSelectedVariant;
- (void)ensureImageLoaded;
@end

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
- (void)updateStoreIconSelection;
- (void)saveCurrentStreamSettingsAsProfilePressed:(id)sender;
- (void)togglePerGameStreamProfilePressed:(id)sender;
- (void)deletePerGameStreamProfilePressed:(id)sender;
@end

@implementation OPNStoreGameTile

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
    OpnLoadImageForURL(urlString, maxPixelDimension, ^(NSImage *image, NSString *resolvedURL, NSData *data) {
        (void)resolvedURL;
        (void)data;
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (generation != strongSelf.imageLoadGeneration) return;
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

@interface OPNStoreRowLayout : NSObject
@property (nonatomic, strong) NSView *glowView;
@property (nonatomic, strong) NSTextField *indexLabel;
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSTextField *hintLabel;
@property (nonatomic, strong) OPNStoreRailScrollView *scrollView;
@property (nonatomic, strong) OPNStoreDocumentView *documentView;
@property (nonatomic, strong) NSMutableArray<OPNStoreGameTile *> *cards;
@property (nonatomic, assign) CGFloat y;
@property (nonatomic, assign) BOOL mounted;
@end

@implementation OPNStoreRowLayout
@end

@interface OPNGameCatalogView () <NSSearchFieldDelegate>
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) OPNStoreDocumentView *documentView;
@property (nonatomic, strong) OPNLoadingView *loadingView;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) OPNStoreHintPillView *buttonHintPillView;
@property (nonatomic, strong) NSStackView *buttonHintStackView;
@property (nonatomic, strong) NSView *searchPanelView;
@property (nonatomic, strong) NSSearchField *searchField;
@property (nonatomic, copy) NSString *searchQuery;
@property (nonatomic, copy) NSString *completedSearchQuery;
@property (nonatomic, assign) NSInteger searchGeneration;
@property (nonatomic, assign) BOOL searchInFlight;
@property (nonatomic, strong) NSTimer *searchDebounceTimer;
@property (nonatomic, strong) dispatch_queue_t searchQueue;
@property (nonatomic, assign) std::shared_ptr<const std::vector<OPN::GameInfo>> searchLibrarySnapshot;
@property (nonatomic, assign) std::shared_ptr<const std::vector<OPN::PanelResult>> searchPanelsSnapshot;
@property (nonatomic, assign) std::vector<OPN::GameInfo> filteredLibraryGames;
@property (nonatomic, assign) std::vector<OPN::PanelResult> filteredPanels;
@property (nonatomic, assign) std::vector<OPN::PanelResult> panels;
@property (nonatomic, assign) std::vector<OPN::GameInfo> libraryGames;
@property (nonatomic, assign) std::vector<OPN::GameInfo> ownedLibraryGames;
@property (nonatomic, assign) std::vector<OPN::GameInfo> featuredGames;
@property (nonatomic, assign) BOOL hasLibraryState;
@property (nonatomic, strong) NSMutableArray<NSMutableArray<OPNStoreGameTile *> *> *rowCards;
@property (nonatomic, strong) NSMutableArray<OPNStoreRowLayout *> *rowLayouts;
@property (nonatomic, strong) NSMutableArray<OpnImageLoadToken *> *heroImageLoadTokens;
@property (nonatomic, strong) NSTimer *heroRotationTimer;
@property (nonatomic, strong) NSMutableArray<NSView *> *desktopFeaturedHeroViews;
@property (nonatomic, strong) NSView *desktopHeroContainer;
@property (nonatomic, strong) OPNHeroArtworkView *desktopHeroArtworkView;
@property (nonatomic, strong) OPNHeroArtworkView *desktopHeroArtworkTransitionView;
@property (nonatomic, strong) NSTextField *desktopHeroTitleFallback;
@property (nonatomic, strong) NSImageView *desktopHeroLogoView;
@property (nonatomic, strong) NSImageView *desktopHeroLogoTransitionView;
@property (nonatomic, copy) NSString *desktopHeroIdentity;
@property (nonatomic, assign) NSInteger desktopHeroGeneration;
@property (nonatomic, strong) NSImage *initialHeroImage;
@property (nonatomic, copy) NSString *initialHeroIdentity;
@property (nonatomic, assign) NSRect desktopFeaturedHeroFrame;
@property (nonatomic, assign) NSInteger currentHeroIndex;
@property (nonatomic, assign) NSInteger focusedRowIndex;
@property (nonatomic, assign) NSInteger focusedColumnIndex;
@property (nonatomic, assign) CGFloat lastLayoutWidth;
@property (nonatomic, assign) CGFloat lastLayoutHeight;
@property (nonatomic, assign) BOOL renderStoreScheduled;
@property (nonatomic, strong) NSTimer *resizeRenderTimer;
@property (nonatomic, assign) BOOL initialHeroPreloadInFlight;
@property (nonatomic, assign) BOOL initialHeroReady;
@property (nonatomic, assign) NSInteger initialHeroPreloadGeneration;
@property (nonatomic, assign) std::string panelsFingerprint;
@property (nonatomic, assign) OPNStoreControllerFamily buttonHintControllerFamily;
- (void)loadFeaturedHeroImageForView:(OPNHeroArtworkView *)view gameIdentity:(NSString *)gameIdentity candidates:(NSArray<NSString *> *)candidates index:(NSUInteger)index animated:(BOOL)animated completion:(void (^)(BOOL loaded))completion;
- (void)renderStoreWhenInitialHeroReady;
- (void)scheduleRenderStoreAfterResize;
- (void)resizeRenderTimerFired:(NSTimer *)timer;
- (void)preloadInitialHeroThenRender;
- (const OPN::GameInfo *)fallbackHeroGame;
- (void)addDesktopHeroStageForGame:(const OPN::GameInfo &)game y:(CGFloat)y contentX:(CGFloat)contentX width:(CGFloat)width height:(CGFloat)height;
- (void)addDesktopHeroLogoForGame:(const OPN::GameInfo &)game toContainer:(NSView *)container;
- (void)updateDesktopHeroElementsForGame:(const OPN::GameInfo &)game animated:(BOOL)animated;
- (void)updateDesktopHeroFrameForCurrentBounds;
- (void)updateRowFramesForCurrentBounds;
- (void)updateRowVirtualizationForVisibleBounds;
- (void)updateImagePreloadingForRowLayout:(OPNStoreRowLayout *)rowLayout;
- (void)updateImagePreloadingForMountedRows;
- (void)updateButtonHintPillFrame;
- (void)updateSearchPanelFrame;
- (void)rebuildButtonHintPillForCurrentController;
- (void)updateDesktopHeroLogoFrame;
- (void)setDesktopHeroArtworkImage:(NSImage *)image animated:(BOOL)animated;
- (void)setDesktopHeroLogoImage:(NSImage *)image animated:(BOOL)animated;
- (NSImageView *)newDesktopHeroLogoTransitionViewWithImage:(NSImage *)image frame:(NSRect)frame;
- (void)loadDesktopHeroLogoForGame:(const OPN::GameInfo &)game generation:(NSInteger)generation animated:(BOOL)animated;
- (void)cancelHeroImageLoads;
- (void)trackHeroImageLoadToken:(OpnImageLoadToken *)token;
- (void)updateDesktopFeaturedHeroOnly;
- (void)addEmptyStoreStateWithY:(CGFloat)y contentX:(CGFloat)contentX width:(CGFloat)width;
- (void)scheduleRenderStore;
- (BOOL)mergeKnownStoreMetadataIntoPanels;
- (void)refreshLibrarySelections;
- (void)updateFocusedTiles;
- (void)updateHeroTileOnly;
- (void)scheduleAsyncSearchForCurrentQuery;
- (void)performAsyncSearchTimerFired:(NSTimer *)timer;
@end

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
}

- (void)interfacePreferencesChanged:(NSNotification *)notification {
    (void)notification;
    [self renderStore];
}

- (void)controllerConfigurationChanged:(NSNotification *)notification {
    (void)notification;
    [self rebuildButtonHintPillForCurrentController];
}

- (void)controlTextDidChange:(NSNotification *)notification {
    if (notification.object != self.searchField) return;
    self.searchQuery = self.searchField.stringValue ?: @"";
    self.searchGeneration++;
    [self.searchDebounceTimer invalidate];
    self.searchDebounceTimer = nil;
    if (OPNStoreSearchNormalizedString(self.searchQuery).length > 0) {
        self.searchDebounceTimer = [NSTimer scheduledTimerWithTimeInterval:kStoreSearchDebounceInterval
                                                                     target:self
                                                                   selector:@selector(performAsyncSearchTimerFired:)
                                                                   userInfo:nil
                                                                    repeats:NO];
        return;
    }
    [self scheduleAsyncSearchForCurrentQuery];
}

- (void)removeButtonHintGroups {
    NSArray<NSView *> *arrangedSubviews = self.buttonHintStackView.arrangedSubviews.copy;
    for (NSView *view in arrangedSubviews) {
        [self.buttonHintStackView removeArrangedSubview:view];
        [view removeFromSuperview];
    }
}

- (void)rebuildButtonHintPillForCurrentController {
    if (!self.buttonHintStackView) return;
    OPNStoreControllerFamily family = OPNStoreConnectedControllerFamily();
    if (family == self.buttonHintControllerFamily && self.buttonHintStackView.arrangedSubviews.count > 0) return;
    self.buttonHintControllerFamily = family;
    [self removeButtonHintGroups];

    if (family == OPNStoreControllerFamilyKeyboard) {
        [self.buttonHintStackView addArrangedSubview:OPNStoreHintGroup(@[
            OPNStoreHintKeyView(@"arrow.up", @"Up", 24.0),
            OPNStoreHintKeyView(@"arrow.down", @"Dn", 24.0),
            OPNStoreHintKeyView(@"arrow.left", @"Lt", 24.0),
            OPNStoreHintKeyView(@"arrow.right", @"Rt", 24.0)
        ], @"Move")];
        [self.buttonHintStackView addArrangedSubview:OPNStoreHintGroup(@[
            OPNStoreHintKeyView(@"return", @"Ent", 30.0),
            OPNStoreHintKeyView(@"space", @"Space", 46.0)
        ], @"Select")];
        [self.buttonHintStackView addArrangedSubview:OPNStoreHintGroup(@[
            OPNStoreHintKeyView(@"v.circle", @"V", 26.0)
        ], @"Variant")];
    } else {
        OPNStoreControllerHintStyle style = OPNStoreControllerHintStyleForFamily(family);
        [self.buttonHintStackView addArrangedSubview:OPNStoreHintGroup(@[
            OPNStoreControllerIconKeyView(@"dpad", 28.0),
            OPNStoreControllerIconKeyView(@"stick", 28.0)
        ], @"Move")];
        [self.buttonHintStackView addArrangedSubview:OPNStoreHintGroup(@[
            OPNStoreControllerIconKeyView(style.selectGlyph, 28.0)
        ], @"Select")];
        [self.buttonHintStackView addArrangedSubview:OPNStoreHintGroup(@[
            OPNStoreControllerIconKeyView(style.variantGlyph, 28.0)
        ], @"Variant")];
    }

    [self.buttonHintStackView setNeedsLayout:YES];
    [self updateButtonHintPillFrame];
}

- (void)setLoading:(BOOL)loading {
    BOOL showBlockingLoader = loading && !self.hasContent;
    self.loadingView.hidden = !showBlockingLoader;
    self.buttonHintPillView.hidden = showBlockingLoader;
    self.statusLabel.stringValue = @"";
    if (showBlockingLoader) {
        [self.loadingView startAnimating];
    } else {
        [self.loadingView stopAnimating];
    }
}

- (void)setError:(NSString *)message {
    [self.heroRotationTimer invalidate];
    self.heroRotationTimer = nil;
    [self setLoading:NO];
    self.statusLabel.stringValue = message ?: @"";
}

- (void)setGames:(const std::vector<OPN::GameInfo> &)games {
    _libraryGames = games;
    _ownedLibraryGames = games;
    self.hasLibraryState = YES;
    std::vector<PanelResult> catalogPanels = OPNCatalogPanelsForGames(games);
    NSInteger gameCount = 0;
    for (const PanelResult &panel : catalogPanels) {
        for (const PanelSection &section : panel.sections) {
            gameCount += (NSInteger)section.games.size();
        }
    }
    if (self.onGameCountChanged) self.onGameCountChanged(gameCount);
    [self setPanels:catalogPanels];
}

- (void)setCatalogBrowseResult:(const OPN::CatalogBrowseResult &)result {
    [self setPanels:OPNCatalogPanelsForGames(result.games)];
    if (self.onGameCountChanged) {
        NSInteger count = result.totalCount > 0 ? result.totalCount : (NSInteger)result.games.size();
        self.onGameCountChanged(count);
    }
}

- (void)setActiveSessionAppIds:(const std::vector<int> &)appIds {
    (void)appIds;
}

- (void)setUserName:(NSString *)name {
    (void)name;
}

- (void)setPanels:(const std::vector<OPN::PanelResult> &)panels {
    std::string fingerprint = OPNStorePanelsFingerprint(panels);
    if (self.hasContent && fingerprint == self.panelsFingerprint) {
        _panels = panels;
        [self mergeKnownStoreMetadataIntoPanels];
        _searchPanelsSnapshot = std::make_shared<const std::vector<PanelResult>>(_panels);
        if (OPNStoreSearchNormalizedString(self.searchQuery).length > 0) [self scheduleAsyncSearchForCurrentQuery];
        [self refreshLibrarySelections];
        return;
    }
    _panels = panels;
    self.panelsFingerprint = fingerprint;
    [self mergeKnownStoreMetadataIntoPanels];
    _searchPanelsSnapshot = std::make_shared<const std::vector<PanelResult>>(_panels);
    if (OPNStoreSearchNormalizedString(self.searchQuery).length > 0) [self scheduleAsyncSearchForCurrentQuery];
    self.currentHeroIndex = 0;
    self.initialHeroReady = NO;
    self.initialHeroPreloadInFlight = NO;
    self.initialHeroPreloadGeneration++;
    self.initialHeroImage = nil;
    self.initialHeroIdentity = nil;
    [self configureHeroRotationTimer];
    [self renderStoreWhenInitialHeroReady];
}

- (void)setFeaturedGames:(const std::vector<OPN::GameInfo> &)games {
    _featuredGames = games;
    self.currentHeroIndex = 0;
    self.initialHeroReady = NO;
    self.initialHeroPreloadInFlight = NO;
    self.initialHeroPreloadGeneration++;
    self.initialHeroImage = nil;
    self.initialHeroIdentity = nil;
    [self configureHeroRotationTimer];
    [self renderStoreWhenInitialHeroReady];
}

- (void)setLibraryGames:(const std::vector<OPN::GameInfo> &)games {
    _libraryGames = games;
    _ownedLibraryGames = games;
    self.hasLibraryState = YES;
    [self mergeKnownStoreMetadataIntoPanels];
    _searchLibrarySnapshot = std::make_shared<const std::vector<GameInfo>>(_ownedLibraryGames);
    _searchPanelsSnapshot = std::make_shared<const std::vector<PanelResult>>(_panels);
    if (OPNStoreSearchNormalizedString(self.searchQuery).length > 0) [self scheduleAsyncSearchForCurrentQuery];
    if (self.rowCards.count > 0 || self.desktopFeaturedHeroViews.count > 0) {
        [self refreshLibrarySelections];
        [self scheduleRenderStore];
    } else if (!_panels.empty()) {
        [self renderStoreWhenInitialHeroReady];
    }
}

- (BOOL)mergeKnownStoreMetadataIntoPanels {
    if (_panels.empty()) return NO;
    BOOL changed = NO;
    for (PanelResult &panel : _panels) {
        for (PanelSection &section : panel.sections) {
            for (GameInfo &storeGame : section.games) {
                if (self.hasLibraryState && OPNStoreClearGameOwnershipMetadata(storeGame)) changed = YES;
                for (const GameInfo &knownGame : _libraryGames) {
                    if (!OPNStoreGameMatchesLibraryGame(storeGame, knownGame)) continue;
                    if (OPNStoreMergeGameStoreMetadata(storeGame, knownGame)) changed = YES;
                }
            }
        }
    }
    return changed;
}

- (int)selectedVariantIndexForStoreGame:(const GameInfo &)storeGame {
    for (const GameInfo &libraryGame : _libraryGames) {
        if (!OPNStoreGameMatchesLibraryGame(storeGame, libraryGame)) continue;
        int libraryVariantIndex = OPNStoreSelectedLibraryVariantIndex(libraryGame);
        if (libraryVariantIndex < 0 || libraryVariantIndex >= (int)libraryGame.variants.size()) return storeGame.variants.empty() ? -1 : 0;

        const GameVariant &libraryVariant = libraryGame.variants[(size_t)libraryVariantIndex];
        for (size_t i = 0; i < storeGame.variants.size(); i++) {
            const GameVariant &storeVariant = storeGame.variants[i];
            if (!libraryVariant.id.empty() && storeVariant.id == libraryVariant.id) return (int)i;
        }
        for (size_t i = 0; i < storeGame.variants.size(); i++) {
            const GameVariant &storeVariant = storeGame.variants[i];
            if (!libraryVariant.appStore.empty() && OPNStoreStringEqualsCaseInsensitive(storeVariant.appStore, libraryVariant.appStore)) return (int)i;
        }
    }
    return storeGame.variants.empty() ? -1 : 0;
}

- (NSInteger)heroCandidateCount {
    return MIN((NSInteger)6, (NSInteger)_featuredGames.size());
}

- (const GameInfo *)currentHeroGame {
    NSInteger candidateCount = [self heroCandidateCount];
    if (candidateCount > 0) {
        NSInteger target = ((self.currentHeroIndex % candidateCount) + candidateCount) % candidateCount;
        return &_featuredGames[(size_t)target];
    }
    return [self fallbackHeroGame];
}

- (const GameInfo *)fallbackHeroGame {
    const GameInfo *firstGame = nullptr;
    auto inspectGame = [&firstGame](const GameInfo &game) -> const GameInfo * {
        if (!firstGame) firstGame = &game;
        return OpnHeroImageCandidatesForGame(game).count > 0 ? &game : nullptr;
    };

    for (const PanelResult &panel : _panels) {
        for (const PanelSection &section : panel.sections) {
            for (const GameInfo &game : section.games) {
                if (const GameInfo *candidate = inspectGame(game)) return candidate;
            }
        }
    }
    for (const GameInfo &game : _ownedLibraryGames) {
        if (const GameInfo *candidate = inspectGame(game)) return candidate;
    }
    for (const GameInfo &game : _libraryGames) {
        if (const GameInfo *candidate = inspectGame(game)) return candidate;
    }
    return firstGame;
}

- (void)configureHeroRotationTimer {
    [self.heroRotationTimer invalidate];
    self.heroRotationTimer = nil;
    if ([self heroCandidateCount] < 2) return;

    self.heroRotationTimer = [NSTimer scheduledTimerWithTimeInterval:7.0
                                                              target:self
                                                            selector:@selector(heroRotationTimerFired:)
                                                            userInfo:nil
                                                             repeats:YES];
}

- (void)heroRotationTimerFired:(NSTimer *)timer {
    (void)timer;
    NSInteger candidateCount = [self heroCandidateCount];
    if (candidateCount < 2) return;
    self.currentHeroIndex = (self.currentHeroIndex + 1) % candidateCount;
    [self updateHeroTileOnly];
}

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

- (void)renderStoreWhenInitialHeroReady {
    const GameInfo *heroGame = [self currentHeroGame];
    if (!heroGame || self.initialHeroReady) {
        [self renderStore];
        return;
    }
    [self preloadInitialHeroThenRender];
}

- (void)preloadInitialHeroThenRender {
    if (self.initialHeroPreloadInFlight) return;
    const GameInfo *heroGame = [self currentHeroGame];
    if (!heroGame) {
        self.initialHeroReady = YES;
        [self renderStore];
        return;
    }

    NSString *gameIdentity = OpnGameIdentityForHero(*heroGame);
    NSArray<NSString *> *candidates = OpnHeroImageCandidatesForGame(*heroGame);
    NSImage *cachedImage = OpnCachedImageFromCandidates(candidates, 1600.0, nil);
    if (OPNStoreHeroImageHasVisibleContent(cachedImage)) {
        self.initialHeroImage = cachedImage;
        self.initialHeroIdentity = gameIdentity;
        self.initialHeroReady = YES;
        [self renderStore];
        return;
    }

    if (candidates.count == 0) {
        self.initialHeroImage = OpnFallbackHeroArtworkImage();
        self.initialHeroIdentity = gameIdentity;
        self.initialHeroReady = YES;
        [self renderStore];
        return;
    }

    self.initialHeroPreloadInFlight = YES;
    NSInteger preloadGeneration = self.initialHeroPreloadGeneration;
    __weak __typeof__(self) weakSelf = self;
    __block BOOL completed = NO;
    __block NSInteger remainingLoads = (NSInteger)candidates.count;
    for (NSString *candidateURL in candidates) {
        OpnImageLoadToken *token = OpnLoadImageForURLCancellable(candidateURL, 1600.0, ^(NSImage *image, NSString *resolvedURL, NSData *data) {
            (void)resolvedURL;
            (void)data;
            __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf || completed || preloadGeneration != strongSelf.initialHeroPreloadGeneration) return;
            if (!OPNStoreHeroImageHasVisibleContent(image)) {
                remainingLoads--;
                if (remainingLoads > 0) return;
                completed = YES;
                strongSelf.initialHeroImage = OpnFallbackHeroArtworkImage();
            } else {
                completed = YES;
                strongSelf.initialHeroImage = image;
            }
            strongSelf.initialHeroIdentity = gameIdentity;
            strongSelf.initialHeroReady = YES;
            strongSelf.initialHeroPreloadInFlight = NO;
            [strongSelf renderStore];
        });
        [self trackHeroImageLoadToken:token];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf || completed || preloadGeneration != strongSelf.initialHeroPreloadGeneration) return;
        completed = YES;
        strongSelf.initialHeroImage = OpnFallbackHeroArtworkImage();
        strongSelf.initialHeroIdentity = gameIdentity;
        strongSelf.initialHeroReady = YES;
        strongSelf.initialHeroPreloadInFlight = NO;
        [strongSelf renderStore];
    });
}

- (void)cancelHeroImageLoads {
    for (OpnImageLoadToken *token in self.heroImageLoadTokens) [token cancel];
    [self.heroImageLoadTokens removeAllObjects];
}

- (void)trackHeroImageLoadToken:(OpnImageLoadToken *)token {
    if (!token) return;
    [self.heroImageLoadTokens addObject:token];
    if (self.heroImageLoadTokens.count > 12) [self.heroImageLoadTokens removeObjectsInRange:NSMakeRange(0, self.heroImageLoadTokens.count - 8)];
}

- (void)scheduleAsyncSearchForCurrentQuery {
    [self.searchDebounceTimer invalidate];
    self.searchDebounceTimer = nil;
    NSString *query = self.searchQuery ?: @"";
    NSString *normalizedQuery = OPNStoreSearchNormalizedString(query);
    self.searchGeneration++;
    NSInteger generation = self.searchGeneration;

    if (normalizedQuery.length == 0) {
        self.searchInFlight = NO;
        self.completedSearchQuery = @"";
        _filteredLibraryGames.clear();
        _filteredPanels.clear();
        self.currentHeroIndex = 0;
        self.initialHeroReady = NO;
        self.initialHeroPreloadInFlight = NO;
        self.initialHeroPreloadGeneration++;
        self.initialHeroImage = nil;
        self.initialHeroIdentity = nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.searchGeneration) return;
            [self renderStoreWhenInitialHeroReady];
        });
        return;
    }

    self.searchInFlight = YES;
    std::shared_ptr<const std::vector<GameInfo>> libraryGames = _searchLibrarySnapshot ?: std::make_shared<const std::vector<GameInfo>>(_ownedLibraryGames);
    std::shared_ptr<const std::vector<PanelResult>> panels = _searchPanelsSnapshot ?: std::make_shared<const std::vector<PanelResult>>(_panels);
    __weak __typeof__(self) weakSelf = self;
    dispatch_async(self.searchQueue, ^{
        std::vector<GameInfo> filteredLibraryGames = OPNStoreSearchFilteredGames(*libraryGames, query);
        std::vector<PanelResult> filteredPanels = OPNStoreSearchFilteredPanels(*panels, query);
        dispatch_async(dispatch_get_main_queue(), ^{
            __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf || generation != strongSelf.searchGeneration) return;
            strongSelf.searchInFlight = NO;
            strongSelf.completedSearchQuery = query;
            strongSelf->_filteredLibraryGames = filteredLibraryGames;
            strongSelf->_filteredPanels = filteredPanels;
            strongSelf.currentHeroIndex = 0;
            strongSelf.initialHeroReady = NO;
            strongSelf.initialHeroPreloadInFlight = NO;
            strongSelf.initialHeroPreloadGeneration++;
            strongSelf.initialHeroImage = nil;
            strongSelf.initialHeroIdentity = nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != strongSelf.searchGeneration) return;
                [strongSelf renderStoreWhenInitialHeroReady];
            });
        });
    });
}

- (void)performAsyncSearchTimerFired:(NSTimer *)timer {
    (void)timer;
    self.searchDebounceTimer = nil;
    [self scheduleAsyncSearchForCurrentQuery];
}

- (void)refreshLibrarySelections {
    for (NSMutableArray<OPNStoreGameTile *> *row in self.rowCards) {
        for (OPNStoreGameTile *card in row) {
            card.selectedVariantIndex = [self selectedVariantIndexForStoreGame:card.game];
        }
    }
    [self updateFocusedTiles];
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

- (void)addDesktopHeroStageForGame:(const GameInfo &)game y:(CGFloat)y contentX:(CGFloat)contentX width:(CGFloat)width height:(CGFloat)height {
    self.desktopFeaturedHeroFrame = NSMakeRect(contentX, y, width, height);

    NSView *container = [[NSView alloc] initWithFrame:self.desktopFeaturedHeroFrame];
    container.autoresizingMask = NSViewWidthSizable;
    container.wantsLayer = YES;
    container.layer.backgroundColor = [NSColor clearColor].CGColor;
    container.layer.masksToBounds = YES;
    [self.documentView addSubview:container];
    self.desktopHeroContainer = container;

    OPNHeroArtworkView *artwork = [[OPNHeroArtworkView alloc] initWithFrame:container.bounds];
    artwork.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    artwork.image = OpnFallbackHeroArtworkImage();
    [container addSubview:artwork positioned:NSWindowBelow relativeTo:nil];
    self.desktopHeroArtworkView = artwork;

    [self addDesktopHeroLogoForGame:game toContainer:container];
    [self updateDesktopHeroElementsForGame:game animated:NO];
    [self.desktopFeaturedHeroViews addObject:container];
}

- (void)addDesktopHeroLogoForGame:(const GameInfo &)game toContainer:(NSView *)container {
    if (!container) return;
    (void)game;

    NSShadow *textShadow = [[NSShadow alloc] init];
    textShadow.shadowBlurRadius = 18.0;
    textShadow.shadowOffset = NSMakeSize(0.0, -2.0);
    textShadow.shadowColor = OpnColor(OPN::kBlack, 0.82);

    NSTextField *titleFallback = OpnLabel(@"", OPNStoreHeroLogoFallbackFrame(container.bounds, OpnFallbackHeroArtworkImage()), 42.0, OpnColor(OPN::kTextPrimary), NSFontWeightBlack);
    titleFallback.maximumNumberOfLines = 2;
    titleFallback.lineBreakMode = NSLineBreakByWordWrapping;
    titleFallback.shadow = textShadow;
    titleFallback.wantsLayer = YES;
    titleFallback.layer.zPosition = 1000.0;
    [container addSubview:titleFallback positioned:NSWindowAbove relativeTo:nil];
    self.desktopHeroTitleFallback = titleFallback;

    NSImageView *logoView = [[NSImageView alloc] initWithFrame:OPNStoreHeroLogoFallbackFrame(container.bounds, OpnFallbackHeroArtworkImage())];
    logoView.hidden = YES;
    OPNStoreConfigureHeroLogoImageView(logoView, 1001.0);
    [container addSubview:logoView positioned:NSWindowAbove relativeTo:nil];
    self.desktopHeroLogoView = logoView;
}

- (void)setDesktopHeroArtworkImage:(NSImage *)image animated:(BOOL)animated {
    if (!image || !self.desktopHeroContainer || !self.desktopHeroArtworkView) return;
    if (!animated || !self.desktopHeroArtworkView.image || !self.desktopHeroArtworkView.superview) {
        [self.desktopHeroArtworkTransitionView removeFromSuperview];
        self.desktopHeroArtworkTransitionView = nil;
        self.desktopHeroArtworkView.image = image;
        self.desktopHeroArtworkView.alphaValue = 1.0;
        [self updateDesktopHeroLogoFrame];
        return;
    }
    if (self.desktopHeroArtworkView.image == image && !self.desktopHeroArtworkTransitionView) {
        [self updateDesktopHeroLogoFrame];
        return;
    }
    if (self.desktopHeroArtworkTransitionView.image == image) return;

    [self.desktopHeroArtworkTransitionView removeFromSuperview];
    OPNHeroArtworkView *transitionView = [[OPNHeroArtworkView alloc] initWithFrame:self.desktopHeroArtworkView.frame];
    transitionView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    transitionView.image = image;
    transitionView.alphaValue = 0.0;
    [self.desktopHeroContainer addSubview:transitionView positioned:NSWindowAbove relativeTo:self.desktopHeroArtworkView];
    self.desktopHeroArtworkTransitionView = transitionView;
    OPNStoreHeroBringLogoToFront(self.desktopHeroContainer, self.desktopHeroTitleFallback, self.desktopHeroLogoView);
    if (self.desktopHeroLogoTransitionView.superview == self.desktopHeroContainer) {
        [self.desktopHeroContainer addSubview:self.desktopHeroLogoTransitionView positioned:NSWindowAbove relativeTo:nil];
    }

    __weak __typeof__(self) weakSelf = self;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = kStoreHeroBackgroundFadeDuration;
        context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        transitionView.animator.alphaValue = 1.0;
    } completionHandler:^{
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.desktopHeroArtworkTransitionView != transitionView) return;
        strongSelf.desktopHeroArtworkView.image = image;
        strongSelf.desktopHeroArtworkView.alphaValue = 1.0;
        [transitionView removeFromSuperview];
        strongSelf.desktopHeroArtworkTransitionView = nil;
        [strongSelf updateDesktopHeroLogoFrame];
    }];
}

- (NSImageView *)newDesktopHeroLogoTransitionViewWithImage:(NSImage *)image frame:(NSRect)frame {
    NSImageView *transitionView = [[NSImageView alloc] initWithFrame:frame];
    transitionView.image = image;
    transitionView.alphaValue = 0.0;
    transitionView.hidden = NO;
    OPNStoreConfigureHeroLogoImageView(transitionView, 1002.0);
    return transitionView;
}

- (void)setDesktopHeroLogoImage:(NSImage *)image animated:(BOOL)animated {
    if (!self.desktopHeroContainer || !self.desktopHeroLogoView || !self.desktopHeroTitleFallback) return;
    [self.desktopHeroLogoTransitionView removeFromSuperview];
    self.desktopHeroLogoTransitionView = nil;

    if (!animated) {
        self.desktopHeroLogoView.image = image;
        self.desktopHeroLogoView.frame = image ? OPNStoreHeroLogoFrameForImage(image, self.desktopHeroContainer.bounds, self.desktopHeroArtworkView.image) : OPNStoreHeroLogoFallbackFrame(self.desktopHeroContainer.bounds, self.desktopHeroArtworkView.image);
        self.desktopHeroLogoView.alphaValue = 1.0;
        self.desktopHeroLogoView.hidden = image == nil;
        self.desktopHeroTitleFallback.hidden = image != nil;
        self.desktopHeroTitleFallback.alphaValue = 1.0;
        OPNStoreHeroBringLogoToFront(self.desktopHeroContainer, self.desktopHeroTitleFallback, self.desktopHeroLogoView);
        return;
    }

    if (!image) {
        NSInteger generation = self.desktopHeroGeneration;
        self.desktopHeroTitleFallback.alphaValue = 0.0;
        self.desktopHeroTitleFallback.hidden = NO;
        __weak __typeof__(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kStoreHeroLogoFadeDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.desktopHeroContainer || strongSelf.desktopHeroGeneration != generation) return;
            [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
                context.duration = kStoreHeroLogoFadeDuration;
                context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
                strongSelf.desktopHeroLogoView.animator.alphaValue = 0.0;
                strongSelf.desktopHeroTitleFallback.animator.alphaValue = 1.0;
            } completionHandler:^{
                if (!strongSelf || strongSelf.desktopHeroGeneration != generation) return;
                strongSelf.desktopHeroLogoView.image = nil;
                strongSelf.desktopHeroLogoView.hidden = YES;
                strongSelf.desktopHeroLogoView.alphaValue = 1.0;
            }];
        });
        return;
    }

    NSRect logoFrame = OPNStoreHeroLogoFrameForImage(image, self.desktopHeroContainer.bounds, self.desktopHeroArtworkView.image);
    NSImageView *transitionView = [self newDesktopHeroLogoTransitionViewWithImage:image frame:logoFrame];
    [self.desktopHeroContainer addSubview:transitionView positioned:NSWindowAbove relativeTo:nil];
    self.desktopHeroLogoTransitionView = transitionView;
    OPNStoreHeroBringLogoToFront(self.desktopHeroContainer, self.desktopHeroTitleFallback, self.desktopHeroLogoView);
    [self.desktopHeroContainer addSubview:transitionView positioned:NSWindowAbove relativeTo:nil];

    __weak __typeof__(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kStoreHeroLogoFadeDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.desktopHeroLogoTransitionView != transitionView) return;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = kStoreHeroLogoFadeDuration;
            context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
            transitionView.animator.alphaValue = 1.0;
            strongSelf.desktopHeroLogoView.animator.alphaValue = 0.0;
            strongSelf.desktopHeroTitleFallback.animator.alphaValue = 0.0;
        } completionHandler:^{
            if (!strongSelf || strongSelf.desktopHeroLogoTransitionView != transitionView) return;
            strongSelf.desktopHeroLogoView.frame = logoFrame;
            strongSelf.desktopHeroLogoView.image = image;
            strongSelf.desktopHeroLogoView.hidden = NO;
            strongSelf.desktopHeroLogoView.alphaValue = 1.0;
            strongSelf.desktopHeroTitleFallback.hidden = YES;
            strongSelf.desktopHeroTitleFallback.alphaValue = 1.0;
            [transitionView removeFromSuperview];
            strongSelf.desktopHeroLogoTransitionView = nil;
            OPNStoreHeroBringLogoToFront(strongSelf.desktopHeroContainer, strongSelf.desktopHeroTitleFallback, strongSelf.desktopHeroLogoView);
        }];
    });
}

- (void)updateDesktopHeroElementsForGame:(const GameInfo &)game animated:(BOOL)animated {
    if (!self.desktopHeroContainer || !self.desktopHeroArtworkView || !self.desktopHeroTitleFallback || !self.desktopHeroLogoView) return;
    self.desktopHeroGeneration++;
    NSInteger generation = self.desktopHeroGeneration;
    NSString *gameIdentity = OpnGameIdentityForHero(game);
    self.desktopHeroIdentity = gameIdentity;
    OPNStoreHeroBringLogoToFront(self.desktopHeroContainer, self.desktopHeroTitleFallback, self.desktopHeroLogoView);

    self.desktopHeroTitleFallback.stringValue = OPNStoreString(game.title, @"");
    self.desktopHeroTitleFallback.frame = OPNStoreHeroLogoFallbackFrame(self.desktopHeroContainer.bounds, self.desktopHeroArtworkView.image);
    if (!animated) {
        self.desktopHeroTitleFallback.hidden = NO;
        self.desktopHeroTitleFallback.alphaValue = 1.0;
        [self setDesktopHeroLogoImage:nil animated:NO];
    }

    NSArray<NSString *> *heroCandidates = OpnHeroImageCandidatesForGame(game);
    NSImage *cachedImage = ([self.initialHeroIdentity isEqualToString:gameIdentity] && OPNStoreHeroImageHasVisibleContent(self.initialHeroImage))
        ? self.initialHeroImage
        : OpnCachedImageFromCandidates(heroCandidates, 1600.0, nil);
    if (OPNStoreHeroImageHasVisibleContent(cachedImage)) {
        [self setDesktopHeroArtworkImage:cachedImage animated:animated];
        [self updateDesktopHeroLogoFrame];
    } else if (!animated) {
        [self setDesktopHeroArtworkImage:OpnFallbackHeroArtworkImage() animated:NO];
        [self updateDesktopHeroLogoFrame];
    }

    __weak __typeof__(self) weakSelf = self;
    [self loadFeaturedHeroImageForView:self.desktopHeroArtworkView gameIdentity:gameIdentity candidates:heroCandidates index:0 animated:animated completion:^(BOOL loaded) {
        (void)loaded;
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf.desktopHeroGeneration) return;
    }];
    [self loadDesktopHeroLogoForGame:game generation:generation animated:animated];
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
    for (OPNStoreGameTile *card in rowLayout.cards) {
        if (NSIntersectsRect(card.frame, preloadRect)) [card ensureImageLoaded];
    }
}

- (void)updateDesktopHeroLogoFrame {
    if (!self.desktopHeroContainer || !self.desktopHeroArtworkView || !self.desktopHeroTitleFallback || !self.desktopHeroLogoView) return;
    NSImage *artworkImage = self.desktopHeroArtworkView.image;
    self.desktopHeroTitleFallback.frame = OPNStoreHeroLogoFallbackFrame(self.desktopHeroContainer.bounds, artworkImage);
    if (self.desktopHeroLogoView.image) {
        self.desktopHeroLogoView.frame = OPNStoreHeroLogoFrameForImage(self.desktopHeroLogoView.image, self.desktopHeroContainer.bounds, artworkImage);
    } else {
        self.desktopHeroLogoView.frame = OPNStoreHeroLogoFallbackFrame(self.desktopHeroContainer.bounds, artworkImage);
    }
    if (self.desktopHeroLogoTransitionView.image) {
        self.desktopHeroLogoTransitionView.frame = OPNStoreHeroLogoFrameForImage(self.desktopHeroLogoTransitionView.image, self.desktopHeroContainer.bounds, artworkImage);
    }
    OPNStoreHeroBringLogoToFront(self.desktopHeroContainer, self.desktopHeroTitleFallback, self.desktopHeroLogoView);
    if (self.desktopHeroLogoTransitionView.superview == self.desktopHeroContainer) {
        [self.desktopHeroContainer addSubview:self.desktopHeroLogoTransitionView positioned:NSWindowAbove relativeTo:nil];
    }
}

- (void)loadDesktopHeroLogoForGame:(const GameInfo &)game generation:(NSInteger)generation animated:(BOOL)animated {
    NSArray<NSString *> *candidates = OPNStoreLogoCandidatesForGame(game);
    NSImage *cachedLogo = OpnCachedImageFromCandidates(candidates, 720.0, nil);
    if (cachedLogo) {
        NSImage *visibleLogo = OPNStoreVisibleLogoImage(cachedLogo);
        [self setDesktopHeroLogoImage:visibleLogo animated:animated];
        return;
    }

    __weak __typeof__(self) weakSelf = self;
    OpnImageLoadToken *token = OpnLoadImageFromCandidatesCancellable(candidates, 720.0, ^(NSImage *image, NSString *resolvedURL, NSData *data) {
        (void)resolvedURL;
        (void)data;
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (generation != strongSelf.desktopHeroGeneration || !strongSelf.desktopHeroContainer.superview) {
            return;
        }
        if (!image) {
            [strongSelf setDesktopHeroLogoImage:nil animated:animated];
            return;
        }
        NSImage *visibleLogo = OPNStoreVisibleLogoImage(image);
        [strongSelf setDesktopHeroLogoImage:visibleLogo animated:animated];
    });
    [self trackHeroImageLoadToken:token];
}

- (void)loadFeaturedHeroImageForView:(OPNHeroArtworkView *)view gameIdentity:(NSString *)gameIdentity candidates:(NSArray<NSString *> *)candidates index:(NSUInteger)index animated:(BOOL)animated completion:(void (^)(BOOL loaded))completion {
    if (!view) return;
    if (index >= candidates.count) {
        if (view == self.desktopHeroArtworkView) {
            [self setDesktopHeroArtworkImage:OpnFallbackHeroArtworkImage() animated:animated];
        } else {
            view.image = OpnFallbackHeroArtworkImage();
        }
        view.alphaValue = 1.0;
        if (view == self.desktopHeroArtworkView) [self updateDesktopHeroLogoFrame];
        if (completion) completion(view.image != nil);
        return;
    }
    NSString *urlString = candidates[index];
    if (urlString.length == 0) {
        [self loadFeaturedHeroImageForView:view gameIdentity:gameIdentity candidates:candidates index:index + 1 animated:animated completion:completion];
        return;
    }

    NSArray<NSString *> *remainingCandidates = [candidates subarrayWithRange:NSMakeRange(index, candidates.count - index)];
    NSImage *cachedImage = OpnCachedImageFromCandidates(remainingCandidates, 1600.0, nil);
    if (OPNStoreHeroImageHasVisibleContent(cachedImage)) {
        if (view == self.desktopHeroArtworkView) {
            [self setDesktopHeroArtworkImage:cachedImage animated:animated];
        } else {
            view.image = cachedImage;
        }
        view.alphaValue = 1.0;
        if (view == self.desktopHeroArtworkView) {
            CGFloat expectedHeroHeight = OPNStoreHeroHeightForWidth(NSWidth(self.bounds), NSHeight(self.bounds));
            if (std::fabs(expectedHeroHeight - NSHeight(self.desktopFeaturedHeroFrame)) > 1.0) {
                [self scheduleRenderStore];
                if (completion) completion(YES);
                return;
            }
            [self updateDesktopHeroLogoFrame];
        }
        if (completion) completion(YES);
        return;
    }

    __weak OPNHeroArtworkView *weakView = view;
    __weak __typeof__(self) weakSelf = self;
    __block BOOL completed = NO;
    __block NSInteger remainingLoads = (NSInteger)remainingCandidates.count;
    for (NSString *candidateURL in remainingCandidates) {
        OpnImageLoadToken *token = OpnLoadImageForURLCancellable(candidateURL, 1600.0, ^(NSImage *image, NSString *resolvedURL, NSData *data) {
            (void)resolvedURL;
            (void)data;
            __typeof__(self) strongSelf = weakSelf;
            OPNHeroArtworkView *strongView = weakView;
            if (!strongSelf || !strongView.superview || completed) return;
            if (strongView == strongSelf.desktopHeroArtworkView && ![strongSelf.desktopHeroIdentity isEqualToString:gameIdentity]) return;
            if (!OPNStoreHeroImageHasVisibleContent(image)) {
                remainingLoads--;
                if (remainingLoads <= 0) {
                    completed = YES;
                    if (strongView == strongSelf.desktopHeroArtworkView) {
                        [strongSelf setDesktopHeroArtworkImage:OpnFallbackHeroArtworkImage() animated:animated];
                    } else {
                        strongView.image = OpnFallbackHeroArtworkImage();
                    }
                    strongView.alphaValue = 1.0;
                    if (strongView == strongSelf.desktopHeroArtworkView) [strongSelf updateDesktopHeroLogoFrame];
                    if (completion) completion(strongView.image != nil);
                }
                return;
            }
            completed = YES;
            if (strongView == strongSelf.desktopHeroArtworkView) {
                [strongSelf setDesktopHeroArtworkImage:image animated:animated];
            } else {
                strongView.image = image;
            }
            strongView.alphaValue = 1.0;
            if (strongView == strongSelf.desktopHeroArtworkView) {
                CGFloat expectedHeroHeight = OPNStoreHeroHeightForWidth(NSWidth(strongSelf.bounds), NSHeight(strongSelf.bounds));
                if (std::fabs(expectedHeroHeight - NSHeight(strongSelf.desktopFeaturedHeroFrame)) > 1.0) {
                    [strongSelf scheduleRenderStore];
                    if (completion) completion(YES);
                    return;
                }
                [strongSelf updateDesktopHeroLogoFrame];
            }
            if (completion) completion(YES);
        });
        [self trackHeroImageLoadToken:token];
    }
}

- (void)updateHeroTileOnly {
    [self updateDesktopFeaturedHeroOnly];
}

- (void)updateDesktopFeaturedHeroOnly {
    const GameInfo *heroGame = [self currentHeroGame];
    if (!heroGame || !self.desktopHeroContainer || !self.desktopHeroArtworkView || NSIsEmptyRect(self.desktopFeaturedHeroFrame)) {
        [self renderStore];
        return;
    }
    CGFloat expectedHeroHeight = OPNStoreHeroHeightForWidth(NSWidth(self.bounds), NSHeight(self.bounds));
    if (std::fabs(expectedHeroHeight - NSHeight(self.desktopFeaturedHeroFrame)) > 1.0) {
        [self renderStore];
        return;
    }
    [self updateDesktopHeroElementsForGame:*heroGame animated:YES];
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
            if (!strongSelf) return;
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
    rowLayout.mounted = YES;
    [self.rowLayouts addObject:rowLayout];
    [self updateRowVirtualizationForVisibleBounds];
    [self updateImagePreloadingForRowLayout:rowLayout];
}

- (void)updateFocusedTiles {
    if (self.rowCards.count == 0) return;
    self.focusedRowIndex = MAX(0, MIN((NSInteger)self.rowCards.count - 1, self.focusedRowIndex));
    NSMutableArray<OPNStoreGameTile *> *focusedRow = self.rowCards[(NSUInteger)self.focusedRowIndex];
    if (focusedRow.count == 0) return;
    self.focusedColumnIndex = MAX(0, MIN((NSInteger)focusedRow.count - 1, self.focusedColumnIndex));
    for (NSUInteger rowIndex = 0; rowIndex < self.rowCards.count; rowIndex++) {
        NSMutableArray<OPNStoreGameTile *> *row = self.rowCards[rowIndex];
        for (NSUInteger columnIndex = 0; columnIndex < row.count; columnIndex++) {
            [row[columnIndex] setStoreFocused:(NSInteger)rowIndex == self.focusedRowIndex && (NSInteger)columnIndex == self.focusedColumnIndex];
        }
    }
}

- (void)scrollFocusedTileIntoView {
    if (self.focusedRowIndex < 0 || self.focusedRowIndex >= (NSInteger)self.rowCards.count) return;
    NSMutableArray<OPNStoreGameTile *> *row = self.rowCards[(NSUInteger)self.focusedRowIndex];
    if (self.focusedColumnIndex < 0 || self.focusedColumnIndex >= (NSInteger)row.count) return;
    OPNStoreGameTile *tile = row[(NSUInteger)self.focusedColumnIndex];
    NSRect tileInDocument = [tile convertRect:tile.bounds toView:self.documentView];
    [self.documentView scrollRectToVisible:NSInsetRect(tileInDocument, -28.0, -46.0)];
    [tile scrollRectToVisible:NSInsetRect(tile.bounds, -24.0, -12.0)];
}

- (void)moveGamepadFocusByRows:(NSInteger)rowDelta columns:(NSInteger)columnDelta {
    if (self.rowCards.count == 0) return;
    NSInteger nextRow = MAX(0, MIN((NSInteger)self.rowCards.count - 1, self.focusedRowIndex + rowDelta));
    NSMutableArray<OPNStoreGameTile *> *row = self.rowCards[(NSUInteger)nextRow];
    if (row.count == 0) return;
    NSInteger nextColumn = self.focusedColumnIndex + columnDelta;
    if (nextRow != self.focusedRowIndex && columnDelta == 0) nextColumn = MIN(nextColumn, (NSInteger)row.count - 1);
    nextColumn = MAX(0, MIN((NSInteger)row.count - 1, nextColumn));
    if (nextRow == self.focusedRowIndex && nextColumn == self.focusedColumnIndex) return;
    self.focusedRowIndex = nextRow;
    self.focusedColumnIndex = nextColumn;
    [self updateFocusedTiles];
    [self scrollFocusedTileIntoView];
}

- (void)moveGamepadFocusBy:(NSInteger)delta {
    [self moveGamepadFocusByRows:0 columns:delta];
}

- (void)activateGamepadFocus {
    if (self.focusedRowIndex < 0 || self.focusedRowIndex >= (NSInteger)self.rowCards.count) return;
    NSMutableArray<OPNStoreGameTile *> *row = self.rowCards[(NSUInteger)self.focusedRowIndex];
    if (self.focusedColumnIndex < 0 || self.focusedColumnIndex >= (NSInteger)row.count) return;
    [row[(NSUInteger)self.focusedColumnIndex] activate];
}

- (void)cycleFocusedGamepadVariant {
    if (self.focusedRowIndex < 0 || self.focusedRowIndex >= (NSInteger)self.rowCards.count) return;
    NSMutableArray<OPNStoreGameTile *> *row = self.rowCards[(NSUInteger)self.focusedRowIndex];
    if (self.focusedColumnIndex < 0 || self.focusedColumnIndex >= (NSInteger)row.count) return;
    [row[(NSUInteger)self.focusedColumnIndex] cycleSelectedVariant];
}

- (void)keyDown:(NSEvent *)event {
    NSString *characters = event.charactersIgnoringModifiers ?: @"";
    unichar key = characters.length > 0 ? [characters characterAtIndex:0] : 0;
    switch (key) {
        case NSLeftArrowFunctionKey:
        case 'a':
        case 'A':
            [self moveGamepadFocusByRows:0 columns:-1];
            return;
        case NSRightArrowFunctionKey:
        case 'd':
        case 'D':
            [self moveGamepadFocusByRows:0 columns:1];
            return;
        case NSUpArrowFunctionKey:
        case 'w':
        case 'W':
            [self moveGamepadFocusByRows:-1 columns:0];
            return;
        case NSDownArrowFunctionKey:
            [self moveGamepadFocusByRows:1 columns:0];
            return;
        case NSTabCharacter:
            [self moveGamepadFocusByRows:0 columns:(event.modifierFlags & NSEventModifierFlagShift) ? -1 : 1];
            return;
        case NSCarriageReturnCharacter:
        case NSEnterCharacter:
        case ' ':
            [self activateGamepadFocus];
            return;
        case 'v':
        case 'V':
            [self cycleFocusedGamepadVariant];
            return;
        default:
            [super keyDown:event];
            return;
    }
}

- (void)storeScrollViewBoundsDidChange:(NSNotification *)notification {
    if (notification.object != self.scrollView.contentView) return;
    [self updateRowVirtualizationForVisibleBounds];
    [self updateImagePreloadingForMountedRows];
    for (NSMutableArray<OPNStoreGameTile *> *row in self.rowCards) {
        for (OPNStoreGameTile *tile in row) {
            [tile resetMouseTrackingIfOutside];
        }
    }
}

- (void)rowScrollViewBoundsDidChange:(NSNotification *)notification {
    for (OPNStoreRowLayout *rowLayout in self.rowLayouts) {
        if (notification.object != rowLayout.scrollView.contentView) continue;
        [self updateImagePreloadingForRowLayout:rowLayout];
        return;
    }
}

@end
