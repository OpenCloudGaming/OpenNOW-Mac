#import "OPNBackdropView.h"
#import "../common/OPNColorTokens.h"
#import "../common/OPNUIHelpers.h"
#import "../common/OPNAuthTypes.h"
#include <cmath>

static unsigned OPNControllerAccentRGB(void);
static const CGFloat OPNControllerNavbarHeight = 118.0;

static unsigned OPNControllerAccentRGB(void) {
    return OPN::kBrandGreen;
}

static CGFloat OPNControllerNavbarPadding(CGFloat width) {
    return MIN(92.0, MAX(26.0, width * 0.024));
}

static CGFloat OPNControllerNavbarGap(CGFloat width) {
    return MIN(42.0, MAX(10.0, width * 0.0145));
}

static NSRect OPNCenteredTextRect(NSString *text, NSDictionary<NSAttributedStringKey, id> *attributes, NSRect bounds) {
    NSSize size = [text sizeWithAttributes:attributes];
    return NSMakeRect(NSMidX(bounds) - ceil(size.width) * 0.5,
                      NSMidY(bounds) - ceil(size.height) * 0.5,
                      ceil(size.width),
                      ceil(size.height));
}

static BOOL OPNBackdropModeShowsControllerChrome(OPNBackdropMode mode) {
    return mode == OPNBackdropModeHome ||
        mode == OPNBackdropModeStore ||
        mode == OPNBackdropModeLibrary ||
        mode == OPNBackdropModeSettings;
}

static NSColor *OPNControllerHintFill(NSString *button) {
    if ([button isEqualToString:@"A"]) return OpnColor(0x31E87D);
    if ([button isEqualToString:@"B"]) return OpnColor(0xFF5353);
    if ([button isEqualToString:@"Y"]) return OpnColor(0xF7D944);
    if ([button isEqualToString:@"X"]) return OpnColor(0x5E98FF);
    return OpnColor(0xE7E7E7);
}

@interface OPNBottomHintsOverlayView : NSView
@end

@implementation OPNBottomHintsOverlayView
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGFloat width = NSWidth(self.bounds);
    CGFloat height = NSHeight(self.bounds);
    CGFloat inset = MIN(96.0, MAX(24.0, width * 0.032));
    CGFloat bottom = MIN(30.0, MAX(12.0, height * 0.016));
    CGFloat buttonSize = MIN(38.0, MAX(26.0, width * 0.0118));
    CGFloat labelFontSize = MIN(16.8, MAX(12.16, width * 0.0068));
    CGFloat buttonFontSize = MIN(14.4, MAX(10.88, width * 0.0048));
    CGFloat gap = MIN(74.0, MAX(18.0, width * 0.024));
    CGFloat labelGap = 10.0;
    CGFloat rowY = height - bottom - buttonSize;
    CGFloat midY = rowY + buttonSize * 0.5;
    [OpnColor(0x000000, 0.96) setFill];
    NSRectFill(NSMakeRect(0.0, rowY, width, height - rowY));

    NSDictionary<NSAttributedStringKey, id> *labelAttributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:labelFontSize weight:850],
        NSForegroundColorAttributeName: OpnColor(0xFFFFFF, 0.74),
    };
    NSMutableParagraphStyle *center = [[NSMutableParagraphStyle alloc] init];
    center.alignment = NSTextAlignmentCenter;
    NSDictionary<NSAttributedStringKey, id> *buttonAttributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:buttonFontSize weight:950],
        NSForegroundColorAttributeName: OpnColor(0x07100B),
        NSParagraphStyleAttributeName: center,
    };

    NSArray<NSDictionary<NSString *, NSString *> *> *items = @[
        @{@"button": @"A", @"title": @"Select"},
        @{@"button": @"B", @"title": @"Back"},
        @{@"button": @"Y", @"title": @"Filter"},
        @{@"button": @"X", @"title": @"Search"},
    ];

    CGFloat x = inset;
    for (NSDictionary<NSString *, NSString *> *item in items) {
        NSString *button = item[@"button"] ?: @"";
        NSString *title = item[@"title"] ?: @"";
        NSRect buttonRect = NSMakeRect(x, rowY, buttonSize, buttonSize);
        NSBezierPath *buttonPath = [NSBezierPath bezierPathWithOvalInRect:buttonRect];
        [OPNControllerHintFill(button) setFill];
        [buttonPath fill];
        [button drawInRect:OPNCenteredTextRect(button, buttonAttributes, buttonRect) withAttributes:buttonAttributes];

        CGFloat titleWidth = ceil([title sizeWithAttributes:labelAttributes].width);
        CGFloat titleY = midY - ceil(labelFontSize * 0.5) - 1.0;
        [title drawInRect:NSMakeRect(NSMaxX(buttonRect) + labelGap, titleY, titleWidth + 4.0, labelFontSize + 2.0)
            withAttributes:labelAttributes];
        x += buttonSize + labelGap + titleWidth + gap;
    }

    NSString *moreTitle = @"More Options";
    CGFloat moreWidth = ceil([moreTitle sizeWithAttributes:labelAttributes].width);
    CGFloat moreX = width - inset - buttonSize - labelGap - moreWidth;
    NSRect menuRect = NSMakeRect(moreX, rowY, buttonSize, buttonSize);
    NSBezierPath *menuCircle = [NSBezierPath bezierPathWithOvalInRect:menuRect];
    [OpnColor(0xE7E7E7) setFill];
    [menuCircle fill];

    CGFloat svgInset = buttonSize * 0.21;
    CGFloat svgWidth = buttonSize - svgInset * 2.0;
    CGFloat lineWidthC = MAX(1.8, buttonSize * 0.072);
    CGFloat lineSpacing = floor((buttonSize - svgInset * 2.0 - lineWidthC * 3.0) / 2.0);
    CGFloat lineStartX = NSMinX(menuRect) + svgInset;
    for (NSInteger i = 0; i < 3; i++) {
        CGFloat lineY2 = NSMinY(menuRect) + svgInset + (CGFloat)i * (lineWidthC + lineSpacing);
        NSBezierPath *line = [NSBezierPath bezierPath];
        [line moveToPoint:NSMakePoint(lineStartX, lineY2)];
        [line lineToPoint:NSMakePoint(lineStartX + svgWidth, lineY2)];
        line.lineWidth = lineWidthC;
        line.lineCapStyle = NSLineCapStyleRound;
        [OpnColor(0x07100B) setStroke];
        [line stroke];
    }

    CGFloat titleY = midY - ceil(labelFontSize * 0.5) - 1.0;
    [moreTitle drawInRect:NSMakeRect(NSMaxX(menuRect) + labelGap, titleY, moreWidth + 4.0, labelFontSize + 2.0)
           withAttributes:labelAttributes];
}
@end

@implementation OPNBackdropView
{
    OPNBottomHintsOverlayView *_bottomHintsView;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _bottomHintsView = [[OPNBottomHintsOverlayView alloc] initWithFrame:NSZeroRect];
        _bottomHintsView.wantsLayer = YES;
        _bottomHintsView.layer.opaque = NO;
        _bottomHintsView.layer.backgroundColor = NSColor.clearColor.CGColor;
        _bottomHintsView.hidden = YES;
        [self addSubview:_bottomHintsView];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(interfacePreferencesChanged:)
                                                     name:OPNInterfacePreferencesDidChangeNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)interfacePreferencesChanged:(NSNotification *)notification {
    (void)notification;
    [self setNeedsLayout:YES];
    [self setNeedsDisplay:YES];
}

- (unsigned)resolvedControllerAccentRGB {
    return OPNControllerAccentRGB();
}

- (unsigned)resolvedControllerAccentSoftRGB {
    return OpnBlendRGB([self resolvedControllerAccentRGB], 0xFFFFFF, 0.42);
}

- (unsigned)resolvedControllerAccentBlackRGB:(CGFloat)blackMix {
    return OpnBlendRGB([self resolvedControllerAccentRGB], 0x000000, blackMix);
}

- (BOOL)isFlipped { return YES; }

- (CGFloat)unitHashForSeed:(NSUInteger)seed index:(NSUInteger)index {
    uint32_t value = (uint32_t)(seed * 1103515245u + index * 12345u + 0x9E3779B9u);
    value ^= value >> 16;
    value *= 0x7FEB352Du;
    value ^= value >> 15;
    return (CGFloat)(value % 10000u) / 10000.0;
}

- (void)drawSparkleAtPoint:(NSPoint)point radius:(CGFloat)radius alpha:(CGFloat)alpha color:(NSColor *)color {
    NSBezierPath *cross = [NSBezierPath bezierPath];
    [cross moveToPoint:NSMakePoint(point.x - radius, point.y)];
    [cross lineToPoint:NSMakePoint(point.x + radius, point.y)];
    [cross moveToPoint:NSMakePoint(point.x, point.y - radius)];
    [cross lineToPoint:NSMakePoint(point.x, point.y + radius)];
    [cross moveToPoint:NSMakePoint(point.x - radius * 0.55, point.y - radius * 0.55)];
    [cross lineToPoint:NSMakePoint(point.x + radius * 0.55, point.y + radius * 0.55)];
    [cross moveToPoint:NSMakePoint(point.x - radius * 0.55, point.y + radius * 0.55)];
    [cross lineToPoint:NSMakePoint(point.x + radius * 0.55, point.y - radius * 0.55)];
    cross.lineCapStyle = NSLineCapStyleRound;
    cross.lineWidth = MAX(0.7, radius * 0.16);
    [[color colorWithAlphaComponent:alpha] setStroke];
    [cross stroke];

    NSBezierPath *core = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(point.x - radius * 0.16,
                                                                            point.y - radius * 0.16,
                                                                            radius * 0.32,
                                                                            radius * 0.32)];
    [[NSColor.whiteColor colorWithAlphaComponent:alpha * 0.72] setFill];
    [core fill];
}

- (void)drawControllerElectricBackgroundInRect:(NSRect)bounds {
    CGFloat phase = 0.0;
    CGFloat tintStrength = OpnBackgroundTintStrength();
    CGFloat baseBlackA = 0.18 + 0.71 * tintStrength;
    CGFloat baseBlackB = 0.10 + 0.71 * tintStrength;
    CGFloat baseBlackC = 0.22 + 0.70 * tintStrength;
    CGFloat vignetteBlack = 0.30 + 0.67 * tintStrength;
    CGFloat vignetteAlpha = 0.04 + 0.26 * tintStrength;
    NSGradient *base = [[NSGradient alloc] initWithColors:@[
        OpnColor([self resolvedControllerAccentBlackRGB:baseBlackA], 1.0),
        OpnColor([self resolvedControllerAccentBlackRGB:baseBlackB], 1.0),
        OpnColor([self resolvedControllerAccentBlackRGB:baseBlackC], 1.0),
    ]];
    [base drawInRect:bounds angle:88.0];

    CGFloat width = NSWidth(bounds);
    CGFloat height = NSHeight(bounds);
    unsigned accentRGB = [self resolvedControllerAccentRGB];
    unsigned accentSoftRGB = [self resolvedControllerAccentSoftRGB];

    for (NSInteger band = 0; band < 9; band++) {
        CGFloat yBase = height * (0.12 + (CGFloat)band * 0.092);
        NSBezierPath *ribbon = [NSBezierPath bezierPath];
        [ribbon moveToPoint:NSMakePoint(-120.0, yBase)];
        for (NSInteger point = 0; point <= 28; point++) {
            CGFloat t = (CGFloat)point / 28.0;
            CGFloat x = t * (width + 240.0) - 120.0;
            CGFloat drift = phase * (0.28 + (CGFloat)band * 0.018);
            CGFloat y = yBase
                + sin(t * 5.8 + (CGFloat)band * 0.72 + drift) * (20.0 + (CGFloat)band * 1.6)
                + sin(t * 13.0 - phase * 0.20 + (CGFloat)band) * 5.0;
            [ribbon lineToPoint:NSMakePoint(x, y)];
        }
        NSColor *stroke = band % 3 == 0 ? OpnColor(accentSoftRGB, 0.032) : OpnColor(accentRGB, 0.035);
        [stroke setStroke];
        ribbon.lineWidth = band == 4 ? 2.4 : 1.1;
        [ribbon stroke];
    }

    CGFloat travelWidth = width + 180.0;
    for (NSInteger i = 0; i < 54; i++) {
        CGFloat seed = (CGFloat)i;
        CGFloat verticalStep = (CGFloat)((i * 17) % 54) / 53.0;
        CGFloat verticalJitter = ([self unitHashForSeed:37 index:(NSUInteger)i] - 0.5) * height * 0.055;
        CGFloat speed = 38.0 + (CGFloat)(i % 5) * 8.0;
        CGFloat x = fmod(seed * 131.0 + phase * speed, MAX(1.0, travelWidth)) - 90.0;
        CGFloat y = height * (0.14 + verticalStep * 0.72)
            + verticalJitter
            + sin(phase * (0.82 + seed * 0.013) + seed * 0.71) * 7.0;
        CGFloat shimmer = 0.5 + 0.5 * sin(phase * (2.2 + (CGFloat)(i % 4) * 0.28) + seed);
        CGFloat radius = 2.0 + (CGFloat)(i % 4) * 0.75 + shimmer * 1.6;
        CGFloat alpha = 0.047 + shimmer * 0.142;
        NSColor *sparkleColor = i % 6 == 0 ? NSColor.whiteColor : OpnColor(accentSoftRGB);
        [self drawSparkleAtPoint:NSMakePoint(x, y) radius:radius alpha:alpha color:sparkleColor];
    }

    NSGradient *vignette = [[NSGradient alloc] initWithStartingColor:OpnColor([self resolvedControllerAccentBlackRGB:vignetteBlack], 0.0)
                                                        endingColor:OpnColor([self resolvedControllerAccentBlackRGB:vignetteBlack], vignetteAlpha)];
    [vignette drawInRect:bounds angle:-90.0];
}

- (void)drawControllerReferenceBackgroundInRect:(NSRect)bounds {
    NSGradient *base = [[NSGradient alloc] initWithStartingColor:OpnColor(0x020303)
                                                     endingColor:OpnColor(0x030303)];
    [base drawInRect:bounds angle:90.0];

    CGFloat width = NSWidth(bounds);
    CGFloat height = NSHeight(bounds);
    NSGradient *accent = [[NSGradient alloc] initWithStartingColor:OpnColor([self resolvedControllerAccentRGB], 0.12)
                                                       endingColor:OpnColor([self resolvedControllerAccentRGB], 0.0)];
    [accent drawInBezierPath:[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(width * -0.20, height * 0.40, 1200.0, 520.0)] angle:0.0];
}

- (NSArray<NSDictionary<NSString *, id> *> *)controllerNavbarItemsForWidth:(CGFloat)width {
    CGFloat itemWidth = width < 1180.0 ? 72.0 : 118.0;
    CGFloat gap = OPNControllerNavbarGap(width);
    CGFloat totalWidth = itemWidth * 3.0 + gap * 2.0;
    CGFloat x = floor((width - totalWidth) * 0.5);
    return @[
        @{ @"title": @"Store", @"mode": @(OPNBackdropModeHome), @"symbol": @"storefront", @"rect": [NSValue valueWithRect:NSMakeRect(x, 20.0, itemWidth, 76.0)] },
        @{ @"title": @"Library", @"mode": @(OPNBackdropModeLibrary), @"symbol": @"books.vertical", @"rect": [NSValue valueWithRect:NSMakeRect(x + itemWidth + gap, 20.0, itemWidth, 76.0)] },
        @{ @"title": @"Settings", @"mode": @(OPNBackdropModeSettings), @"symbol": @"gearshape", @"rect": [NSValue valueWithRect:NSMakeRect(x + (itemWidth + gap) * 2.0, 20.0, itemWidth, 76.0)] },
    ];
}

- (void)drawControllerNavbarIcon:(NSString *)symbolName inRect:(NSRect)rect color:(NSColor *)color {
    [color setStroke];
    [color setFill];
    if ([symbolName isEqualToString:@"storefront"]) {
        NSBezierPath *awning = [NSBezierPath bezierPath];
        [awning moveToPoint:NSMakePoint(NSMinX(rect) + 4.0, NSMinY(rect) + 10.0)];
        [awning lineToPoint:NSMakePoint(NSMinX(rect) + 9.0, NSMinY(rect) + 4.0)];
        [awning lineToPoint:NSMakePoint(NSMaxX(rect) - 9.0, NSMinY(rect) + 4.0)];
        [awning lineToPoint:NSMakePoint(NSMaxX(rect) - 4.0, NSMinY(rect) + 10.0)];
        awning.lineWidth = 2.2;
        [awning stroke];
        NSBezierPath *body = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(NSMinX(rect) + 6.0, NSMinY(rect) + 12.0, NSWidth(rect) - 12.0, NSHeight(rect) - 14.0) xRadius:2.5 yRadius:2.5];
        body.lineWidth = 2.2;
        [body stroke];
        NSBezierPath *door = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(NSMidX(rect) - 4.0, NSMinY(rect) + 19.0, 8.0, 9.0) xRadius:1.5 yRadius:1.5];
        door.lineWidth = 1.8;
        [door stroke];
        return;
    }
    if ([symbolName isEqualToString:@"books.vertical"]) {
        CGFloat bookWidth = 6.0;
        for (NSInteger index = 0; index < 3; index++) {
            NSRect bookRect = NSMakeRect(NSMinX(rect) + 5.0 + index * 8.0, NSMinY(rect) + 4.0 + index, bookWidth, NSHeight(rect) - 8.0 - index);
            NSBezierPath *book = [NSBezierPath bezierPathWithRoundedRect:bookRect xRadius:2.0 yRadius:2.0];
            book.lineWidth = 2.0;
            [book stroke];
        }
        return;
    }
    if ([symbolName isEqualToString:@"gearshape"]) {
        NSPoint center = NSMakePoint(NSMidX(rect), NSMidY(rect));
        for (NSInteger index = 0; index < 8; index++) {
            CGFloat angle = ((CGFloat)index / 8.0) * (CGFloat)M_PI * 2.0;
            NSBezierPath *spoke = [NSBezierPath bezierPath];
            [spoke moveToPoint:NSMakePoint(center.x + cos(angle) * 8.0, center.y + sin(angle) * 8.0)];
            [spoke lineToPoint:NSMakePoint(center.x + cos(angle) * 13.0, center.y + sin(angle) * 13.0)];
            spoke.lineWidth = 2.2;
            spoke.lineCapStyle = NSLineCapStyleRound;
            [spoke stroke];
        }
        NSBezierPath *outer = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(rect, 7.0, 7.0)];
        outer.lineWidth = 2.2;
        [outer stroke];
        NSBezierPath *inner = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(rect, 13.0, 13.0)];
        inner.lineWidth = 2.0;
        [inner stroke];
    }
}

- (void)drawControllerNavbarInRect:(NSRect)bounds {
    CGFloat width = NSWidth(bounds);
    CGFloat padding = OPNControllerNavbarPadding(width);
    NSRect navbarRect = NSMakeRect(0.0, 0.0, width, OPNControllerNavbarHeight);
    NSGradient *navbarGradient = [[NSGradient alloc] initWithStartingColor:OpnColor(0x000000, 0.98)
                                                               endingColor:OpnColor(0x000000, 0.92)];
    [navbarGradient drawInRect:navbarRect angle:-90.0];

    NSRect logoRect = NSMakeRect(padding, 35.0, 46.0, 46.0);
    NSBezierPath *logoPath = [NSBezierPath bezierPathWithRoundedRect:logoRect xRadius:13.0 yRadius:13.0];
    [OpnColor(0x98E7B0) setFill];
    [logoPath fill];
    NSDictionary<NSAttributedStringKey, id> *logoAttributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:15.0 weight:NSFontWeightBlack],
        NSForegroundColorAttributeName: OpnColor(0x061008, 0.96),
    };
    [@"ON" drawInRect:OPNCenteredTextRect(@"ON", logoAttributes, logoRect) withAttributes:logoAttributes];

    if (width >= 1500.0) {
        NSDictionary<NSAttributedStringKey, id> *brandAttributes = @{
            NSFontAttributeName: [NSFont systemFontOfSize:20.0 weight:NSFontWeightBlack],
            NSForegroundColorAttributeName: OpnColor(0xF8F8F8),
        };
        [@"OpenNOW" drawInRect:NSMakeRect(NSMaxX(logoRect) + 16.0, 46.0, 160.0, 26.0) withAttributes:brandAttributes];
    }

    NSDictionary<NSAttributedStringKey, id> *itemAttributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:width < 1180.0 ? 13.0 : 16.0 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: OpnColor(0xFFFFFF, 0.72),
    };
    NSDictionary<NSAttributedStringKey, id> *selectedItemAttributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:width < 1180.0 ? 13.0 : 16.0 weight:NSFontWeightHeavy],
        NSForegroundColorAttributeName: OpnColor(0xFFFFFF, 1.0),
    };
    for (NSDictionary<NSString *, id> *item in [self controllerNavbarItemsForWidth:width]) {
        NSString *title = item[@"title"] ?: @"";
        NSString *symbolName = item[@"symbol"] ?: @"circle";
        NSRect itemRect = [item[@"rect"] rectValue];
        BOOL selected = (OPNBackdropMode)[item[@"mode"] integerValue] == self.mode;
        if (selected) {
            NSGradient *activeGradient = [[NSGradient alloc] initWithColors:@[
                OpnColor([self resolvedControllerAccentRGB], 0.0),
                OpnColor([self resolvedControllerAccentRGB], 0.15),
                OpnColor([self resolvedControllerAccentRGB], 0.0),
            ]];
            [activeGradient drawInRect:itemRect angle:0.0];
            NSRect indicatorRect = NSMakeRect(NSMinX(itemRect) + 16.0, NSMaxY(itemRect) - 6.0, NSWidth(itemRect) - 32.0, 6.0);
            NSBezierPath *indicator = [NSBezierPath bezierPathWithRoundedRect:indicatorRect xRadius:3.0 yRadius:3.0];
            [OpnColor(0x9BEFB7) setFill];
            [indicator fill];
        }
        NSDictionary<NSAttributedStringKey, id> *attributes = selected ? selectedItemAttributes : itemAttributes;
        NSColor *itemColor = selected ? OpnColor(0xFFFFFF, 1.0) : OpnColor(0xFFFFFF, 0.72);
        [self drawControllerNavbarIcon:symbolName inRect:NSMakeRect(NSMidX(itemRect) - 15.0, NSMinY(itemRect) + 14.0, 30.0, 30.0) color:itemColor];
        [title drawInRect:OPNCenteredTextRect(title, attributes, NSMakeRect(NSMinX(itemRect), NSMinY(itemRect) + 48.0, NSWidth(itemRect), 20.0)) withAttributes:attributes];
    }

    NSString *playtime = [self.remainingPlayTime ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    CGFloat rightX = width - padding;
    if (playtime.length > 0 && ![playtime isEqualToString:@"--"]) {
        NSString *playtimeText = [@"Playtime: " stringByAppendingString:playtime];
        NSDictionary<NSAttributedStringKey, id> *playtimeAttributes = @{
            NSFontAttributeName: [NSFont systemFontOfSize:12.0 weight:NSFontWeightHeavy],
            NSForegroundColorAttributeName: OpnColor(0xEAFFF1),
        };
        CGFloat chipWidth = MIN(168.0, MAX(122.0, ceil([playtimeText sizeWithAttributes:playtimeAttributes].width) + 24.0));
        NSRect chipRect = NSMakeRect(rightX - chipWidth, 39.0, chipWidth, 34.0);
        NSBezierPath *chipPath = [NSBezierPath bezierPathWithRoundedRect:chipRect xRadius:17.0 yRadius:17.0];
        [OpnColor(0x081C11, 0.60) setFill];
        [chipPath fill];
        [OpnColor(0x26D067) setStroke];
        chipPath.lineWidth = 1.5;
        [chipPath stroke];
        [playtimeText drawInRect:OPNCenteredTextRect(playtimeText, playtimeAttributes, chipRect) withAttributes:playtimeAttributes];
        rightX = NSMinX(chipRect) - 10.0;
    }

    NSRect avatarRect = NSMakeRect(rightX - 34.0, 39.0, 34.0, 34.0);
    NSBezierPath *avatarPath = [NSBezierPath bezierPathWithRoundedRect:avatarRect xRadius:9.0 yRadius:9.0];
    [NSGraphicsContext saveGraphicsState];
    [avatarPath addClip];
    if (self.accountAvatarImage) {
        [self.accountAvatarImage drawInRect:avatarRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0 respectFlipped:YES hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
    } else {
        [OpnColor([self resolvedControllerAccentRGB], 0.72) setFill];
        [avatarPath fill];
    }
    [NSGraphicsContext restoreGraphicsState];
    [OpnColor(0xFFFFFF, 0.72) setStroke];
    avatarPath.lineWidth = 1.5;
    [avatarPath stroke];

    if (width >= 1500.0) {
        NSString *name = self.accountName.length > 0 ? self.accountName : @"Account";
        NSString *tier = self.accountStatus.length > 0 ? self.accountStatus : @"";
        NSDictionary<NSAttributedStringKey, id> *nameAttributes = @{
            NSFontAttributeName: [NSFont systemFontOfSize:12.0 weight:NSFontWeightHeavy],
            NSForegroundColorAttributeName: OpnColor(0xF5F5F5),
        };
        NSDictionary<NSAttributedStringKey, id> *tierAttributes = @{
            NSFontAttributeName: [NSFont systemFontOfSize:10.0 weight:NSFontWeightSemibold],
            NSForegroundColorAttributeName: OpnColor(0xFFFFFF, 0.66),
        };
        [name drawInRect:NSMakeRect(NSMinX(avatarRect) - 122.0, 39.0, 112.0, 16.0) withAttributes:nameAttributes];
        [tier drawInRect:NSMakeRect(NSMinX(avatarRect) - 122.0, 56.0, 112.0, 14.0) withAttributes:tierAttributes];
    }
}



- (void)drawIsometricBlockAtCenter:(NSPoint)center size:(CGFloat)size height:(CGFloat)height color:(NSColor *)color alpha:(CGFloat)alpha {
    CGFloat halfWidth = size;
    CGFloat halfDepth = size * 0.48;
    NSPoint top = NSMakePoint(center.x, center.y - height);
    NSPoint left = NSMakePoint(center.x - halfWidth, center.y - height + halfDepth);
    NSPoint right = NSMakePoint(center.x + halfWidth, center.y - height + halfDepth);
    NSPoint bottom = NSMakePoint(center.x, center.y - height + halfDepth * 2.0);
    NSPoint baseLeft = NSMakePoint(left.x, left.y + height);
    NSPoint baseRight = NSMakePoint(right.x, right.y + height);
    NSPoint baseBottom = NSMakePoint(bottom.x, bottom.y + height);

    NSBezierPath *topFace = [NSBezierPath bezierPath];
    [topFace moveToPoint:top];
    [topFace lineToPoint:right];
    [topFace lineToPoint:bottom];
    [topFace lineToPoint:left];
    [topFace closePath];

    NSBezierPath *leftFace = [NSBezierPath bezierPath];
    [leftFace moveToPoint:left];
    [leftFace lineToPoint:bottom];
    [leftFace lineToPoint:baseBottom];
    [leftFace lineToPoint:baseLeft];
    [leftFace closePath];

    NSBezierPath *rightFace = [NSBezierPath bezierPath];
    [rightFace moveToPoint:right];
    [rightFace lineToPoint:bottom];
    [rightFace lineToPoint:baseBottom];
    [rightFace lineToPoint:baseRight];
    [rightFace closePath];

    [[color colorWithAlphaComponent:alpha * 0.26] setFill];
    [leftFace fill];
    [[color colorWithAlphaComponent:alpha * 0.34] setFill];
    [rightFace fill];
    [[color colorWithAlphaComponent:alpha * 0.52] setFill];
    [topFace fill];

    [[NSColor.whiteColor colorWithAlphaComponent:alpha * 0.16] setStroke];
    topFace.lineWidth = 1.0;
    [topFace stroke];
}

- (void)drawThreeDimensionalBackgroundInRect:(NSRect)bounds {
    CGFloat width = NSWidth(bounds);
    CGFloat height = NSHeight(bounds);
    if (width <= 0.0 || height <= 0.0) return;

    unsigned accentRGB = [self resolvedControllerAccentRGB];
    unsigned accentSoftRGB = [self resolvedControllerAccentSoftRGB];
    CGFloat tintStrength = OpnBackgroundTintStrength();
    NSGradient *base = [[NSGradient alloc] initWithColors:@[
        OpnColor([self resolvedControllerAccentBlackRGB:0.86], 1.0),
        OpnColor([self resolvedControllerAccentBlackRGB:0.72], 1.0),
        OpnColor(0x05070A, 1.0),
    ]];
    [base drawInRect:bounds angle:72.0];

    NSGradient *horizon = [[NSGradient alloc] initWithStartingColor:OpnColor(accentRGB, 0.16 - tintStrength * 0.08)
                                                       endingColor:OpnColor(accentRGB, 0.0)];
    [horizon drawInBezierPath:[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(width * 0.10, height * 0.08, width * 0.86, height * 0.62)] angle:-24.0];

    NSColor *gridColor = OpnColor(accentSoftRGB, 0.070);
    [gridColor setStroke];
    CGFloat horizonY = height * 0.56;
    CGFloat vanishingX = width * 0.58;
    for (NSInteger i = -18; i <= 18; i++) {
        CGFloat startX = width * 0.5 + (CGFloat)i * 58.0;
        NSBezierPath *ray = [NSBezierPath bezierPath];
        [ray moveToPoint:NSMakePoint(startX, height + 30.0)];
        [ray lineToPoint:NSMakePoint(vanishingX + (CGFloat)i * 3.0, horizonY)];
        ray.lineWidth = 0.8;
        [ray stroke];
    }
    for (NSInteger row = 0; row < 16; row++) {
        CGFloat t = (CGFloat)row / 15.0;
        CGFloat y = horizonY + pow(t, 1.85) * (height - horizonY + 60.0);
        CGFloat inset = (1.0 - t) * width * 0.34;
        NSBezierPath *line = [NSBezierPath bezierPath];
        [line moveToPoint:NSMakePoint(inset, y)];
        [line lineToPoint:NSMakePoint(width - inset, y)];
        line.lineWidth = 0.7 + t * 0.7;
        [[gridColor colorWithAlphaComponent:0.035 + t * 0.06] setStroke];
        [line stroke];
    }

    NSArray<NSValue *> *centers = @[
        [NSValue valueWithPoint:NSMakePoint(width * 0.18, height * 0.68)],
        [NSValue valueWithPoint:NSMakePoint(width * 0.34, height * 0.82)],
        [NSValue valueWithPoint:NSMakePoint(width * 0.66, height * 0.72)],
        [NSValue valueWithPoint:NSMakePoint(width * 0.84, height * 0.88)],
    ];
    CGFloat sizes[] = {68.0, 92.0, 78.0, 114.0};
    CGFloat blockHeights[] = {96.0, 136.0, 110.0, 158.0};
    for (NSUInteger i = 0; i < centers.count; i++) {
        NSPoint center = centers[i].pointValue;
        CGFloat scale = MAX(0.72, MIN(1.14, width / 1280.0));
        [self drawIsometricBlockAtCenter:center
                                    size:sizes[i] * scale
                                  height:blockHeights[i] * scale
                                   color:OpnColor(i % 2 == 0 ? accentRGB : accentSoftRGB)
                                   alpha:0.38];
    }

    NSGradient *orb = [[NSGradient alloc] initWithStartingColor:OpnColor(accentSoftRGB, 0.22)
                                                   endingColor:OpnColor(accentSoftRGB, 0.0)];
    [orb drawInBezierPath:[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(width * 0.58, height * 0.18, 360.0, 360.0)] angle:45.0];

    NSGradient *vignette = [[NSGradient alloc] initWithStartingColor:OpnColor(0x000000, 0.0)
                                                        endingColor:OpnColor(0x000000, 0.56 + tintStrength * 0.24)];
    [vignette drawInRect:bounds angle:-90.0];
}

- (void)setMode:(OPNBackdropMode)mode {
    _mode = mode;
    [self dismissControllerAccountMenu];
    _bottomHintsView.hidden = (mode != OPNBackdropModeLibrary);
    [self setNeedsLayout:YES];
    [self setNeedsDisplay:YES];
}

- (void)setAccountName:(NSString *)accountName {
    _accountName = [accountName copy];
    [self setNeedsDisplay:YES];
}

- (void)setAccountStatus:(NSString *)accountStatus {
    _accountStatus = [accountStatus copy];
    [self setNeedsDisplay:YES];
}

- (void)setAccountAvatarImage:(NSImage *)accountAvatarImage {
    _accountAvatarImage = accountAvatarImage;
    [self setNeedsDisplay:YES];
}

- (void)setRemainingPlayTime:(NSString *)remainingPlayTime {
    _remainingPlayTime = [remainingPlayTime copy];
    [self setNeedsDisplay:YES];
}

- (void)setGameCountText:(NSString *)gameCountText {
    _gameCountText = [gameCountText copy];
    [self setNeedsDisplay:YES];
}

- (void)setAccountMenuItems:(NSArray<NSDictionary<NSString *,NSString *> *> *)accountMenuItems {
    _accountMenuItems = [accountMenuItems copy];
    [self dismissControllerAccountMenu];
}

- (void)setCurrentAccountIdentifier:(NSString *)currentAccountIdentifier {
    _currentAccountIdentifier = [currentAccountIdentifier copy];
    [self dismissControllerAccountMenu];
}

- (void)layout {
    [super layout];
    if (!_bottomHintsView) return;
    _bottomHintsView.frame = self.bounds;
    [self addSubview:_bottomHintsView positioned:NSWindowAbove relativeTo:nil];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    (void)dirtyRect;
    if (OpnControllerModeEnabled() && OPNBackdropModeShowsControllerChrome(self.mode)) {
        [self drawControllerReferenceBackgroundInRect:self.bounds];
        [self drawControllerNavbarInRect:self.bounds];
    }
}

- (void)mouseDown:(NSEvent *)event {
    if (!OpnControllerModeEnabled()) {
        [super mouseDown:event];
        return;
    }

    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (point.y > OPNControllerNavbarHeight) {
        [super mouseDown:event];
        return;
    }

    for (NSDictionary<NSString *, id> *item in [self controllerNavbarItemsForWidth:NSWidth(self.bounds)]) {
        if (!NSPointInRect(point, [item[@"rect"] rectValue])) continue;
        OPNBackdropMode targetMode = (OPNBackdropMode)[item[@"mode"] integerValue];
        if (targetMode == OPNBackdropModeHome && self.onHomeSelected) self.onHomeSelected();
        if (targetMode == OPNBackdropModeLibrary && self.onLibrarySelected) self.onLibrarySelected();
        if (targetMode == OPNBackdropModeSettings && self.onSettingsSelected) self.onSettingsSelected();
        return;
    }

    [super mouseDown:event];
}

- (void)dismissControllerAccountMenu {
}

@end
