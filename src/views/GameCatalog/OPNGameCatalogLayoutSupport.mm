#import "OPNGameCatalogPrivate.h"

extern const CGFloat kStoreTopInset = 0.0;
extern const CGFloat kStoreNavigationClearance = 0.0;
extern const CGFloat kStoreHeroHeightRatio = 0.3229;
extern const CGFloat kStoreRowHeight = 282.0;
extern const CGFloat kStoreCardSpacing = 18.0;
extern const CGFloat kStoreTileWidth = 268.0;
extern const CGFloat kStoreTileHeight = 151.0;
extern const CGFloat kStoreHeroMinContentInset = 30.0;
extern const CGFloat kStoreHeroMaxContentInset = 106.0;
extern const CGFloat kStoreHeroContentInsetRatio = 0.055;
extern const CGFloat kStoreFallbackHeroAspect = 1.0 / kStoreHeroHeightRatio;
extern const CGFloat kStoreHeroMaxHeight = 820.0;
extern const CGFloat kStoreHeroMaxViewportRatio = 0.62;
extern const CGFloat kStoreHeroLogoMaxWidth = 520.0;
extern const CGFloat kStoreHeroLogoMaxHeight = 180.0;
extern const CGFloat kStoreHeroFirstRowSpacing = 64.0;
extern const CGFloat kStoreButtonHintPillHeight = 40.0;
extern const CGFloat kStoreButtonHintPillBottomInset = 18.0;
extern const CGFloat kStoreTopFoldNextRowInset = -100.0;
extern const CGFloat kStoreSearchPanelMinWidth = 300.0;
extern const CGFloat kStoreSearchPanelMaxWidth = 420.0;
extern const CGFloat kStoreRailInertiaMinimumVelocity = 8.0;
extern const CGFloat kStoreRailInertiaResistancePerSecond = 0.035;
extern const NSInteger kStoreRailImagePreloadCardBuffer = 4;
extern const NSTimeInterval kStoreSearchDebounceInterval = 0.18;
extern const NSTimeInterval kStoreHeroBackgroundFadeDuration = 0.34;
extern const NSTimeInterval kStoreHeroLogoFadeDuration = 0.24;
extern const NSTimeInterval kStoreHeroLogoFadeDelay = 0.10;

CGFloat OPNStoreHeroHeightForWidth(CGFloat width, CGFloat viewportHeight) {
    CGFloat fallbackHeight = MAX(1.0, width) / kStoreFallbackHeroAspect;
    CGFloat viewportHeightLimit = viewportHeight > 0.0 ? viewportHeight * kStoreHeroMaxViewportRatio : fallbackHeight;
    return floor(MIN(kStoreHeroMaxHeight, viewportHeightLimit));
}

CGFloat OPNStoreNextRowYAfterRow(CGFloat rowY, NSInteger rowIndex, BOOL hasHero, CGFloat viewportHeight) {
    CGFloat nextRowY = rowY + kStoreRowHeight;
    if (hasHero && rowIndex == 0) {
        nextRowY = MAX(nextRowY, floor(MAX(1.0, viewportHeight) + kStoreTopFoldNextRowInset));
    }
    return nextRowY;
}


@implementation OPNStoreDocumentView
- (BOOL)isFlipped { return YES; }
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


@implementation OPNStoreHintPillView
- (BOOL)isFlipped { return YES; }

- (NSView *)hitTest:(NSPoint)point {
    return [self mouse:point inRect:self.bounds] ? self : nil;
}
@end


NSString *OPNStoreControllerIdentity(GCController *controller) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (controller.vendorName.length > 0) [parts addObject:controller.vendorName];
    if (@available(macOS 11.0, *)) {
        if (controller.productCategory.length > 0) [parts addObject:controller.productCategory];
    }
    return [[parts componentsJoinedByString:@" "] uppercaseString];
}

OPNStoreControllerFamily OPNStoreConnectedControllerFamily(void) {
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

OPNStoreControllerHintStyle OPNStoreControllerHintStyleForFamily(OPNStoreControllerFamily family) {
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

NSTextField *OPNStoreHintLabel(NSString *text, CGFloat fontSize, NSFontWeight weight, NSColor *color) {
    NSTextField *label = OpnLabel(text, NSZeroRect, fontSize, color, weight, NSTextAlignmentCenter);
    [label setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [label setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    return label;
}

OPNStoreHintFixedView *OPNStoreHintKeyView(NSString *symbolName, NSString *fallback, CGFloat width) {
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

OPNStoreHintFixedView *OPNStoreControllerIconKeyView(NSString *glyph, CGFloat width) {
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

NSStackView *OPNStoreHintGroup(NSArray<OPNStoreHintFixedView *> *keys, NSString *title) {
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

CGFloat OPNStoreHeroContentInsetForWidth(CGFloat width) {
    return MIN(kStoreHeroMaxContentInset, MAX(kStoreHeroMinContentInset, width * kStoreHeroContentInsetRatio));
}

CGFloat OPNStoreTileWidthForRailWidth(CGFloat width) {
    CGFloat idealColumns = MAX(1.0, (width + kStoreCardSpacing) / (kStoreTileWidth + kStoreCardSpacing));
    CGFloat columns = MAX(1.0, std::round(idealColumns));
    return floor((width - kStoreCardSpacing * (columns - 1.0)) / columns);
}

NSSize OPNStoreTileMetricsForRailWidth(CGFloat width) {
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

NSString *OPNStoreString(const std::string &value, NSString *fallback) {
    return value.empty() ? (fallback ?: @"") : [NSString stringWithUTF8String:value.c_str()];
}
