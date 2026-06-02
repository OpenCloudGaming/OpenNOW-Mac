#import "OPNBackdropView.h"
#import "../common/OPNColorTokens.h"
#import "../common/OPNUIHelpers.h"
#import "../common/OPNAuthTypes.h"
#include <cmath>

static unsigned OPNControllerAccentRGB(void);

static unsigned OPNControllerAccentRGB(void) {
    return OPN::kBrandGreen;
}

@implementation OPNBackdropView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
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
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    (void)dirtyRect;
}

- (void)dismissControllerAccountMenu {
}

@end
