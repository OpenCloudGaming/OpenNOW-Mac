#import "OPNBackdropView.h"
#import "../common/OPNColorTokens.h"
#import "../common/OPNUIHelpers.h"
#import "../common/OPNAuthTypes.h"
#include <cmath>

@interface OPNBackdropControllerMenuView : NSView
@end

@implementation OPNBackdropControllerMenuView
- (BOOL)isFlipped { return YES; }
@end

static unsigned OPNControllerAccentRGB(void);
static unsigned OPNControllerAccentSoftRGB(void);

@interface OPNBackdropControllerAccountButton : NSButton
@property (nonatomic, copy) NSString *opnTitle;
@property (nonatomic, assign) BOOL opnSelected;
@property (nonatomic, assign) BOOL opnWarning;
@end

@implementation OPNBackdropControllerAccountButton

- (void)setOpnTitle:(NSString *)opnTitle {
    _opnTitle = [opnTitle copy];
    [self setNeedsDisplay:YES];
}

- (void)setOpnSelected:(BOOL)opnSelected {
    _opnSelected = opnSelected;
    [self setNeedsDisplay:YES];
}

- (void)setOpnWarning:(BOOL)opnWarning {
    _opnWarning = opnWarning;
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSString *title = self.opnTitle ?: @"";
    CGFloat chipWidth = self.opnSelected ? 72.0 : 0.0;
    CGFloat titleRightInset = self.opnSelected ? chipWidth + 22.0 : 18.0;
    NSRect titleRect = NSMakeRect(18.0, floor((NSHeight(self.bounds) - 18.0) / 2.0) + 1.0, MAX(0.0, NSWidth(self.bounds) - 18.0 - titleRightInset), 19.0);
    NSMutableParagraphStyle *titleStyle = [[NSMutableParagraphStyle alloc] init];
    titleStyle.lineBreakMode = NSLineBreakByTruncatingMiddle;
    titleStyle.alignment = NSTextAlignmentLeft;
    NSColor *titleColor = self.opnWarning ? OpnColor(0xFF9B9B) : (self.opnSelected ? OpnColor(OPN::kTextPrimary) : OpnColor(OPN::kTextSecondary));
    [title drawInRect:titleRect withAttributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:self.opnSelected ? 14.0 : 13.5 weight:self.opnSelected ? NSFontWeightSemibold : NSFontWeightMedium],
        NSForegroundColorAttributeName: titleColor,
        NSParagraphStyleAttributeName: titleStyle,
    }];
    if (!self.opnSelected) return;
    NSRect chipRect = NSMakeRect(NSWidth(self.bounds) - chipWidth - 14.0, floor((NSHeight(self.bounds) - 24.0) / 2.0), chipWidth, 24.0);
    NSBezierPath *chip = [NSBezierPath bezierPathWithRoundedRect:chipRect xRadius:12.0 yRadius:12.0];
    [OpnColor(OPNControllerAccentSoftRGB(), 0.18) setFill];
    [chip fill];
    [OpnColor(OPNControllerAccentSoftRGB(), 0.42) setStroke];
    chip.lineWidth = 1.0;
    [chip stroke];
    NSMutableParagraphStyle *chipStyle = [[NSMutableParagraphStyle alloc] init];
    chipStyle.alignment = NSTextAlignmentCenter;
    [@"Current" drawInRect:NSMakeRect(NSMinX(chipRect), NSMinY(chipRect) + 5.0, NSWidth(chipRect), 14.0) withAttributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:10.5 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: OpnColor(OPN::kTextPrimary),
        NSParagraphStyleAttributeName: chipStyle,
    }];
}

@end

static unsigned OPNControllerAccentRGB(void) {
    return OPN::kBrandGreen;
}

static unsigned OPNControllerAccentSoftRGB(void) {
    return OpnBlendRGB(OPN::kBrandGreen, 0xFFFFFF, 0.42);
}

static unsigned OPNControllerAccentBlackRGB(CGFloat blackMix) {
    return OpnBlendRGB(OPN::kBrandGreen, 0x000000, blackMix);
}

static NSImage *OPNHeaderLogoImage(void) {
    static NSImage *logo = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *paths = @[
            [NSBundle.mainBundle pathForResource:@"logo-mac" ofType:@"png"] ?: @"",
            [NSBundle.mainBundle pathForResource:@"logo" ofType:@"png"] ?: @"",
            @"assets/logo-mac.png",
            @"assets/logo.png",
        ];
        for (NSString *path in paths) {
            if (path.length == 0) continue;
            logo = [[NSImage alloc] initWithContentsOfFile:path];
            if (logo) break;
        }
    });
    return logo;
}

static NSString *OPNCurrentHeaderTimeText(void) {
    static NSDateFormatter *timeFormatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        timeFormatter = [[NSDateFormatter alloc] init];
        timeFormatter.dateFormat = @"h:mm a";
    });
    return [[timeFormatter stringFromDate:NSDate.date] uppercaseString];
}

static void OPNStrokeRoundedPath(NSBezierPath *path, NSColor *color, CGFloat width) {
    [color setStroke];
    path.lineWidth = width;
    path.lineCapStyle = NSLineCapStyleRound;
    path.lineJoinStyle = NSLineJoinStyleRound;
    [path stroke];
}

static void OPNDrawReferenceHeaderIcon(NSString *icon, NSRect rect, BOOL active, CGFloat scale, unsigned accentRGB) {
    NSColor *color = active ? OpnColor(0xF4FFF6, 0.98) : OpnColor(0xEEF0F2, 0.80);
    if ([icon isEqualToString:@"home"]) {
        NSBezierPath *path = [NSBezierPath bezierPath];
        [path moveToPoint:NSMakePoint(NSMidX(rect), NSMinY(rect) + 2.0 * scale)];
        [path lineToPoint:NSMakePoint(NSMinX(rect) + 3.0 * scale, NSMinY(rect) + 10.0 * scale)];
        [path lineToPoint:NSMakePoint(NSMinX(rect) + 3.0 * scale, NSMaxY(rect) - 2.0 * scale)];
        [path lineToPoint:NSMakePoint(NSMaxX(rect) - 3.0 * scale, NSMaxY(rect) - 2.0 * scale)];
        [path lineToPoint:NSMakePoint(NSMaxX(rect) - 3.0 * scale, NSMinY(rect) + 10.0 * scale)];
        [path closePath];
        OPNStrokeRoundedPath(path, color, 2.0 * scale);
        OPNStrokeRoundedPath([NSBezierPath bezierPathWithRect:NSMakeRect(NSMidX(rect) - 3.0 * scale, NSMaxY(rect) - 8.5 * scale, 6.0 * scale, 6.5 * scale)], color, 1.8 * scale);
    } else if ([icon isEqualToString:@"library"]) {
        for (NSInteger column = 0; column < 3; column++) {
            CGFloat x = NSMinX(rect) + (3.0 + column * 7.0) * scale;
            CGFloat top = NSMinY(rect) + (column == 1 ? 1.0 : 4.0) * scale;
            NSBezierPath *line = [NSBezierPath bezierPath];
            [line moveToPoint:NSMakePoint(x, top)];
            [line lineToPoint:NSMakePoint(x, NSMaxY(rect) - 2.0 * scale)];
            OPNStrokeRoundedPath(line, color, 2.2 * scale);
        }
        NSBezierPath *slash = [NSBezierPath bezierPath];
        [slash moveToPoint:NSMakePoint(NSMinX(rect) + 23.0 * scale, NSMaxY(rect) - 3.0 * scale)];
        [slash lineToPoint:NSMakePoint(NSMinX(rect) + 17.0 * scale, NSMinY(rect) + 4.0 * scale)];
        OPNStrokeRoundedPath(slash, color, 2.2 * scale);
    } else if ([icon isEqualToString:@"store"]) {
        OPNStrokeRoundedPath([NSBezierPath bezierPathWithRoundedRect:NSMakeRect(NSMinX(rect) + 3.0 * scale, NSMinY(rect) + 8.0 * scale, 18.0 * scale, 15.0 * scale) xRadius:2.0 * scale yRadius:2.0 * scale], color, 2.0 * scale);
        NSBezierPath *handle = [NSBezierPath bezierPath];
        [handle moveToPoint:NSMakePoint(NSMinX(rect) + 8.0 * scale, NSMinY(rect) + 8.0 * scale)];
        [handle curveToPoint:NSMakePoint(NSMinX(rect) + 16.0 * scale, NSMinY(rect) + 8.0 * scale)
               controlPoint1:NSMakePoint(NSMinX(rect) + 8.0 * scale, NSMinY(rect) + 2.5 * scale)
               controlPoint2:NSMakePoint(NSMinX(rect) + 16.0 * scale, NSMinY(rect) + 2.5 * scale)];
        OPNStrokeRoundedPath(handle, color, 2.0 * scale);
    } else if ([icon isEqualToString:@"search"]) {
        OPNStrokeRoundedPath([NSBezierPath bezierPathWithOvalInRect:NSMakeRect(NSMinX(rect) + 2.0 * scale, NSMinY(rect) + 2.0 * scale, 15.0 * scale, 15.0 * scale)], color, 2.0 * scale);
        NSBezierPath *handle = [NSBezierPath bezierPath];
        [handle moveToPoint:NSMakePoint(NSMinX(rect) + 15.0 * scale, NSMinY(rect) + 15.0 * scale)];
        [handle lineToPoint:NSMakePoint(NSMaxX(rect) - 2.0 * scale, NSMaxY(rect) - 2.0 * scale)];
        OPNStrokeRoundedPath(handle, color, 2.2 * scale);
    } else {
        OPNStrokeRoundedPath([NSBezierPath bezierPathWithOvalInRect:NSInsetRect(rect, 5.0 * scale, 5.0 * scale)], color, 2.0 * scale);
        OPNStrokeRoundedPath([NSBezierPath bezierPathWithOvalInRect:NSInsetRect(rect, 10.0 * scale, 10.0 * scale)], color, 1.8 * scale);
        for (NSInteger i = 0; i < 8; i++) {
            CGFloat angle = (CGFloat)i * (CGFloat)M_PI / 4.0;
            NSBezierPath *tooth = [NSBezierPath bezierPath];
            [tooth moveToPoint:NSMakePoint(NSMidX(rect) + cos(angle) * 9.0 * scale, NSMidY(rect) + sin(angle) * 9.0 * scale)];
            [tooth lineToPoint:NSMakePoint(NSMidX(rect) + cos(angle) * 12.0 * scale, NSMidY(rect) + sin(angle) * 12.0 * scale)];
            OPNStrokeRoundedPath(tooth, color, 2.0 * scale);
        }
    }
    (void)accentRGB;
}

static void OPNDrawReferenceHeaderNavItem(NSString *title, NSString *icon, CGFloat centerX, BOOL active, CGFloat scale, unsigned accentRGB) {
    CGFloat visualScale = scale * 0.82;
    CGFloat itemY = 42.0 * scale;
    if (active) {
        NSGradient *glow = [[NSGradient alloc] initWithColorsAndLocations:
            OpnColor(accentRGB, 0.0), 0.0,
            OpnColor(accentRGB, 0.36), 0.52,
            OpnColor(accentRGB, 0.0), 1.0,
            nil];
        [glow drawInRect:NSMakeRect(centerX - 50.0 * scale, 24.0 * scale, 100.0 * scale, 52.0 * scale) angle:0.0];
    }
    OPNDrawReferenceHeaderIcon(icon, NSMakeRect(centerX - 38.0 * scale, itemY + 2.0 * scale, 25.0 * visualScale, 25.0 * visualScale), active, visualScale, accentRGB);
    NSDictionary<NSAttributedStringKey, id> *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:17.0 * visualScale weight:active ? NSFontWeightSemibold : NSFontWeightRegular],
        NSForegroundColorAttributeName: active ? OpnColor(0xFFFFFF, 0.98) : OpnColor(0xE7E7EA, 0.82),
    };
    NSSize titleSize = [title sizeWithAttributes:attrs];
    [title drawInRect:NSMakeRect(centerX - 7.0 * scale, itemY + 3.0 * scale, titleSize.width + 6.0 * scale, 22.0 * scale) withAttributes:attrs];
    if (active) {
        NSBezierPath *underline = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(centerX - 42.0 * scale, 76.0 * scale, 84.0 * scale, 3.0 * scale) xRadius:1.5 * scale yRadius:1.5 * scale];
        [OpnColor(OpnBlendRGB(accentRGB, 0xFFFFFF, 0.42), 1.0) setFill];
        [underline fill];
    }
}

@implementation OPNBackdropView {
    NSRect _storeNavFrame;
    NSRect _libraryNavFrame;
    NSRect _settingsNavFrame;
    NSRect _accountFrame;
    NSButton *_storeButton;
    NSButton *_libraryButton;
    NSButton *_settingsButton;
    NSButton *_accountButton;
    NSView *_controllerAccountMenuView;
}

static NSAttributedString *OPNMenuTitle(NSString *title, NSColor *color, NSFontWeight weight) {
    return [[NSAttributedString alloc] initWithString:title attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:13.0 weight:weight],
        NSForegroundColorAttributeName: color,
    }];
}

static NSMenuItem *OPNStyledMenuItem(NSString *title, SEL action, id target, NSColor *color, NSFontWeight weight) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = target;
    item.attributedTitle = OPNMenuTitle(title, color, weight);
    return item;
}

static CGFloat OPNControllerAccountMenuWidth(NSRect bounds) {
    return MIN(420.0, MAX(320.0, NSWidth(bounds) - 40.0));
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _storeButton = [self navigationHitButtonWithAction:@selector(storeButtonPressed:)];
        _libraryButton = [self navigationHitButtonWithAction:@selector(libraryButtonPressed:)];
        _settingsButton = [self navigationHitButtonWithAction:@selector(settingsButtonPressed:)];
        _accountButton = [self navigationHitButtonWithAction:@selector(accountButtonPressed:)];
        [self addSubview:_storeButton];
        [self addSubview:_libraryButton];
        [self addSubview:_settingsButton];
        [self addSubview:_accountButton];
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

- (NSButton *)navigationHitButtonWithAction:(SEL)action {
    NSButton *button = [[NSButton alloc] initWithFrame:NSZeroRect];
    button.title = @"";
    button.bordered = NO;
    button.target = self;
    button.action = action;
    button.wantsLayer = YES;
    button.layer.backgroundColor = [NSColor clearColor].CGColor;
    return button;
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

- (void)setMode:(OPNBackdropMode)mode {
    _mode = mode;
    [self dismissControllerAccountMenu];
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
    BOOL showNavigation = self.mode != OPNBackdropModeAuth;
    BOOL controllerMode = OpnControllerModeEnabled();
    if (showNavigation && !controllerMode) {
        CGFloat storeWidth = 78.0;
        CGFloat libraryWidth = 82.0;
        CGFloat settingsWidth = 92.0;
        CGFloat spacing = 4.0;
        CGFloat navWidth = storeWidth + libraryWidth + settingsWidth + spacing * 2.0;
        CGFloat x = floor((NSWidth(self.bounds) - navWidth) / 2.0);
        _storeNavFrame = NSMakeRect(x, 18.0, storeWidth, 28.0);
        _libraryNavFrame = NSMakeRect(NSMaxX(_storeNavFrame) + spacing, 18.0, libraryWidth, 28.0);
        _settingsNavFrame = NSMakeRect(NSMaxX(_libraryNavFrame) + spacing, 18.0, settingsWidth, 28.0);
        _accountFrame = NSMakeRect(NSWidth(self.bounds) - 174.0, 9.0, 154.0, 48.0);
    } else if (showNavigation && controllerMode) {
        CGFloat scale = MAX(0.70, MIN(1.0, MIN(NSWidth(self.bounds) / 1280.0, NSHeight(self.bounds) / 720.0)));
        CGFloat navCenter = NSWidth(self.bounds) * 0.470;
        CGFloat navY = 34.0 * scale;
        _libraryNavFrame = NSMakeRect(navCenter - 94.0 * scale, navY, 112.0 * scale, 50.0 * scale);
        _storeNavFrame = NSMakeRect(navCenter + 32.0 * scale, navY, 104.0 * scale, 50.0 * scale);
        _settingsNavFrame = NSMakeRect(navCenter + 292.0 * scale, navY, 120.0 * scale, 50.0 * scale);
        _accountFrame = NSMakeRect(NSWidth(self.bounds) - 278.0 * scale, 36.0 * scale, 258.0 * scale, 40.0 * scale);
    }
    BOOL showTabs = showNavigation;
    BOOL showStore = showTabs;
    _storeButton.frame = showStore && !NSEqualRects(_storeNavFrame, NSZeroRect) ? _storeNavFrame : NSZeroRect;
    _libraryButton.frame = showTabs && !NSEqualRects(_libraryNavFrame, NSZeroRect) ? _libraryNavFrame : NSZeroRect;
    _settingsButton.frame = showTabs && !NSEqualRects(_settingsNavFrame, NSZeroRect) ? _settingsNavFrame : NSZeroRect;
    _accountButton.frame = showNavigation && !NSEqualRects(_accountFrame, NSZeroRect) ? _accountFrame : NSZeroRect;
    _storeButton.hidden = !showStore;
    _libraryButton.hidden = !showTabs;
    _settingsButton.hidden = !showTabs;
    _accountButton.hidden = !showNavigation;
    if (_controllerAccountMenuView) {
        CGFloat menuWidth = OPNControllerAccountMenuWidth(self.bounds);
        _controllerAccountMenuView.frame = NSMakeRect(MAX(20.0, NSWidth(self.bounds) - menuWidth - 20.0), 106.0, menuWidth, NSHeight(_controllerAccountMenuView.frame));
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    using namespace OPN;

    NSRect bounds = self.bounds;
    BOOL controllerMode = OpnControllerModeEnabled();
    [OpnColor(kBackground) setFill];
    NSRectFill(bounds);

    if (controllerMode) {
        [NSColor.blackColor setFill];
        NSRectFill(bounds);
    } else {
        NSGradient *edgeWash = [[NSGradient alloc] initWithColors:@[
            OpnColor(kBackgroundB, 0.94),
            OpnColor(kBackground, 1.0),
            OpnColor(0x0C0D10, 1.0),
        ]];
        [edgeWash drawInRect:bounds angle:270.0];
    }

    if (!controllerMode) {
        NSGradient *spotlight = [[NSGradient alloc] initWithStartingColor:OpnColor(0xFFFFFF, 0.045)
                                                               endingColor:OpnColor(0xFFFFFF, 0.0)];
        NSRect spotlightRect = NSMakeRect(NSWidth(bounds) * 0.5 - 360.0, -300.0, 720.0, 720.0);
        [spotlight drawInBezierPath:[NSBezierPath bezierPathWithOvalInRect:spotlightRect] angle:90.0];

        NSBezierPath *lowerGlow = [NSBezierPath bezierPathWithOvalInRect:
            NSMakeRect(NSWidth(bounds) - 500.0, NSHeight(bounds) - 360.0, 520.0, 520.0)];
        [OpnColor(kBrandGreen, 0.045) setFill];
        [lowerGlow fill];
    }

    if (self.mode == OPNBackdropModeAuth) {
        return;
    }

    CGFloat navHeight = controllerMode ? 118.0 : 64.0;
    NSRect navRect = NSMakeRect(0, 0, NSWidth(bounds), navHeight);
    if (!controllerMode) {
        [OpnColor(0x1C1D21, 0.82) setFill];
        NSRectFill(navRect);
        [OpnColor(0xFFFFFF, 0.08) setFill];
        NSRectFill(NSMakeRect(0, navHeight - 1.0, NSWidth(bounds), 1));
    }

    if (controllerMode) {
        CGFloat scale = MAX(0.70, MIN(1.0, MIN(NSWidth(bounds) / 1280.0, NSHeight(bounds) / 720.0)));
        unsigned accentRGB = [self resolvedControllerAccentRGB];
        NSGradient *headerFade = [[NSGradient alloc] initWithColorsAndLocations:
            OpnColor(0x020304, 0.98), 0.0,
            OpnColor(0x030506, 0.90), 0.68,
            OpnColor(0x030506, 0.0), 1.0,
            nil];
        [headerFade drawInRect:navRect angle:-90.0];

        NSRect logoRect = NSMakeRect(39.0 * scale, 37.0 * scale, 35.0 * scale, 35.0 * scale);
        NSBezierPath *logo = [NSBezierPath bezierPathWithRoundedRect:logoRect xRadius:8.5 * scale yRadius:8.5 * scale];
        [OpnColor(OpnBlendRGB(accentRGB, 0xFFFFFF, 0.42), 1.0) setFill];
        [logo fill];
        NSBezierPath *bolt = [NSBezierPath bezierPath];
        [bolt moveToPoint:NSMakePoint(NSMinX(logoRect) + 20.0 * scale, NSMinY(logoRect) + 8.0 * scale)];
        [bolt lineToPoint:NSMakePoint(NSMinX(logoRect) + 12.0 * scale, NSMinY(logoRect) + 18.0 * scale)];
        [bolt lineToPoint:NSMakePoint(NSMinX(logoRect) + 22.0 * scale, NSMinY(logoRect) + 17.0 * scale)];
        [bolt lineToPoint:NSMakePoint(NSMinX(logoRect) + 14.0 * scale, NSMinY(logoRect) + 28.0 * scale)];
        OPNStrokeRoundedPath(bolt, OpnColor(0x07110A, 0.96), 3.0 * scale);
        [@"OpenNOW" drawInRect:NSMakeRect(85.0 * scale, 39.5 * scale, 170.0 * scale, 34.0 * scale)
                 withAttributes:@{NSFontAttributeName: [NSFont systemFontOfSize:24.0 * scale weight:NSFontWeightBold],
                                  NSForegroundColorAttributeName: OpnColor(0xFFFFFF, 0.98)}];

        CGFloat navCenter = NSWidth(bounds) * 0.470;
        OPNDrawReferenceHeaderNavItem(@"Home", @"home", navCenter - 170.0 * scale, NO, scale, accentRGB);
        OPNDrawReferenceHeaderNavItem(@"Library", @"library", navCenter - 45.0 * scale, self.mode == OPNBackdropModeLibrary, scale, accentRGB);
        OPNDrawReferenceHeaderNavItem(@"Store", @"store", navCenter + 80.0 * scale, self.mode == OPNBackdropModeStore, scale, accentRGB);
        OPNDrawReferenceHeaderNavItem(@"Search", @"search", navCenter + 205.0 * scale, NO, scale, accentRGB);
        OPNDrawReferenceHeaderNavItem(@"Settings", @"settings", navCenter + 340.0 * scale, self.mode == OPNBackdropModeSettings, scale, accentRGB);

        CGFloat chipX = NSWidth(bounds) - 278.0 * scale;
        NSRect chipRect = NSMakeRect(chipX, 41.0 * scale, 122.0 * scale, 27.0 * scale);
        NSBezierPath *chip = [NSBezierPath bezierPathWithRoundedRect:chipRect xRadius:13.5 * scale yRadius:13.5 * scale];
        [OpnColor(0x06120A, 0.52) setFill];
        [chip fill];
        OPNStrokeRoundedPath(chip, OpnColor(accentRGB, 0.86), 1.0 * scale);
        NSRect clockRect = NSMakeRect(chipX + 11.0 * scale, 47.0 * scale, 15.0 * scale, 15.0 * scale);
        OPNStrokeRoundedPath([NSBezierPath bezierPathWithOvalInRect:clockRect], OpnColor(accentRGB, 0.98), 1.8 * scale);
        NSBezierPath *clockHand = [NSBezierPath bezierPath];
        [clockHand moveToPoint:NSMakePoint(NSMidX(clockRect), NSMidY(clockRect))];
        [clockHand lineToPoint:NSMakePoint(NSMidX(clockRect) + 3.0 * scale, NSMidY(clockRect) - 5.0 * scale)];
        OPNStrokeRoundedPath(clockHand, OpnColor(accentRGB, 0.98), 1.6 * scale);
        NSString *remainingText = [self.remainingPlayTime.lowercaseString containsString:@"unlimited"] ? @"Unlimited time" : (self.remainingPlayTime.length > 0 ? self.remainingPlayTime : @"Unlimited time");
        [remainingText drawInRect:NSMakeRect(chipX + 32.0 * scale, 45.0 * scale, 88.0 * scale, 18.0 * scale)
                    withAttributes:@{NSFontAttributeName: [NSFont systemFontOfSize:12.0 * scale weight:NSFontWeightMedium],
                                     NSForegroundColorAttributeName: OpnColor(0xEDEFF0, 0.91)}];

        CGFloat avatarX = NSWidth(bounds) - 135.0 * scale;
        NSRect avatarRect = NSMakeRect(avatarX, 41.0 * scale, 27.0 * scale, 27.0 * scale);
        NSBezierPath *avatar = [NSBezierPath bezierPathWithRoundedRect:avatarRect xRadius:5.0 * scale yRadius:5.0 * scale];
        if (self.accountAvatarImage) {
            [NSGraphicsContext saveGraphicsState];
            [avatar addClip];
            [self.accountAvatarImage drawInRect:avatarRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0 respectFlipped:YES hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
            [NSGraphicsContext restoreGraphicsState];
        } else {
            NSGradient *gold = [[NSGradient alloc] initWithColorsAndLocations:OpnColor(0xFFF6BA), 0.0, OpnColor(0xC19120), 1.0, nil];
            [gold drawInBezierPath:avatar angle:-45.0];
            [OpnColor(0xFFFEE6, 0.95) setStroke];
            for (NSInteger column = 0; column < 3; column++) {
                for (NSInteger row = 0; row < 3; row++) {
                    NSBezierPath *jewel = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(avatarX + (6.0 + column * 5.5) * scale, (46.0 + row * 5.5) * scale, 3.0 * scale, 3.0 * scale) xRadius:0.7 * scale yRadius:0.7 * scale];
                    jewel.lineWidth = 0.9 * scale;
                    [jewel stroke];
                }
            }
        }
        OPNStrokeRoundedPath(avatar, OpnColor(0xFFFFFF, 0.78), 1.0 * scale);
        NSString *name = self.accountName.length > 0 ? self.accountName : @"ZortosMain";
        NSString *status = self.accountStatus.length > 0 ? self.accountStatus.uppercaseString : @"FREE";
        [name drawInRect:NSMakeRect(NSWidth(bounds) - 99.0 * scale, 40.0 * scale, 96.0 * scale, 17.0 * scale)
          withAttributes:@{NSFontAttributeName: [NSFont systemFontOfSize:13.0 * scale weight:NSFontWeightMedium],
                           NSForegroundColorAttributeName: OpnColor(0xFFFFFF, 0.95)}];
        [status drawInRect:NSMakeRect(NSWidth(bounds) - 99.0 * scale, 57.0 * scale, 70.0 * scale, 13.0 * scale)
            withAttributes:@{NSFontAttributeName: [NSFont systemFontOfSize:10.0 * scale weight:NSFontWeightMedium],
                             NSForegroundColorAttributeName: OpnColor(0xFFFFFF, 0.70)}];
        return;
    }

    NSImage *logo = controllerMode ? nil : OPNHeaderLogoImage();
    if (logo) {
        CGFloat logoHeight = controllerMode ? 34.0 : 49.5;
        CGFloat aspect = logo.size.height > 0 ? logo.size.width / logo.size.height : 1.0;
        CGFloat logoWidth = MIN(controllerMode ? 146.0 : 217.8, logoHeight * aspect);
        NSRect logoRect = controllerMode ? NSMakeRect(28.0, 29.0, logoWidth, logoHeight) : NSMakeRect(28.0, 7.25, logoWidth, logoHeight);
        [logo drawInRect:logoRect
                fromRect:NSZeroRect
               operation:NSCompositingOperationSourceOver
                fraction:1.0
          respectFlipped:YES
                   hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
    } else if (!controllerMode) {
        [@"OpenNOW" drawInRect:NSMakeRect(32.0, 21.0, 132, 22)
                withAttributes:OpnTextStyle(16.0, OpnColor(kTextPrimary), NSFontWeightSemibold)];
    }

    if (!controllerMode) {
        NSArray<NSString *> *items = @[@"Store", @"Library", @"Settings"];
        CGFloat widths[] = {82.0, 92.0, 78.0};
        CGFloat navWidth = widths[2] + widths[0] + widths[1] + 8.0;
        CGFloat x = floor((NSWidth(bounds) - navWidth) / 2.0);
        CGFloat navRowY = 15.0;
        NSRect segmentedRect = NSMakeRect(x - 8.0, navRowY, navWidth + 16.0, 34.0);
        NSBezierPath *segmented = [NSBezierPath bezierPathWithRoundedRect:segmentedRect xRadius:10.0 yRadius:10.0];
        [OpnColor(0xFFFFFF, 0.055) setFill];
        [segmented fill];
        for (NSUInteger i = 0; i < items.count; i++) {
            NSString *item = items[i];
            CGFloat itemWidth = [item isEqualToString:@"Store"] ? widths[2] : ([item isEqualToString:@"Library"] ? widths[0] : widths[1]);
            BOOL active = ([item isEqualToString:@"Store"] && self.mode == OPNBackdropModeStore) ||
                          ([item isEqualToString:@"Library"] && self.mode == OPNBackdropModeLibrary) ||
                          ([item isEqualToString:@"Settings"] && self.mode == OPNBackdropModeSettings);
            NSRect itemRect = NSMakeRect(x, 18.0, itemWidth, 28.0);
            if ([item isEqualToString:@"Store"]) _storeNavFrame = itemRect;
            if ([item isEqualToString:@"Library"]) _libraryNavFrame = itemRect;
            if ([item isEqualToString:@"Settings"]) _settingsNavFrame = itemRect;
            if (active) {
                NSBezierPath *pill = [NSBezierPath bezierPathWithRoundedRect:itemRect xRadius:8.0 yRadius:8.0];
                [OpnColor(0xFFFFFF, 0.14) setFill];
                [pill fill];
            }
            NSColor *textColor = active ? OpnColor(kTextPrimary) : OpnColor(kTextMuted);
            NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
            style.alignment = NSTextAlignmentCenter;
            NSMutableDictionary<NSAttributedStringKey, id> *attrs = [OpnTextStyle(13, textColor, active ? NSFontWeightSemibold : NSFontWeightRegular) mutableCopy];
            attrs[NSParagraphStyleAttributeName] = style;
            [item drawInRect:NSInsetRect(itemRect, 0, 6.0) withAttributes:attrs];
            x += itemWidth + 4.0;
        }
    }

    NSString *remaining = self.remainingPlayTime.length > 0 ? self.remainingPlayTime : @"--";
    CGFloat controllerStatsWidth = 252.0;
    CGFloat controllerStatsX = NSWidth(bounds) - controllerStatsWidth - 24.0;
    NSRect planRect = controllerMode ? NSMakeRect(controllerStatsX, 66.0, 116.0, 24.0) : NSMakeRect(NSWidth(bounds) - 294, 11.0, 108, 26);
    NSBezierPath *planPill = [NSBezierPath bezierPathWithRoundedRect:planRect xRadius:14 yRadius:14];
    [controllerMode ? OpnColor([self resolvedControllerAccentRGB], 0.075) : OpnColor(0xFFFFFF, 0.075) setFill];
    [planPill fill];
    if (controllerMode) {
        [OpnColor([self resolvedControllerAccentSoftRGB], 0.24) setStroke];
        planPill.lineWidth = 1.0;
        [planPill stroke];
    }
    NSMutableParagraphStyle *remainingStyle = [[NSMutableParagraphStyle alloc] init];
    remainingStyle.alignment = NSTextAlignmentCenter;
    NSMutableDictionary<NSAttributedStringKey, id> *remainingAttrs = [OpnTextStyle(controllerMode ? 11.0 : 12.0, OpnColor(kTextSecondary), NSFontWeightSemibold) mutableCopy];
    remainingAttrs[NSParagraphStyleAttributeName] = remainingStyle;
    [remaining drawInRect:NSInsetRect(planRect, 0, 5)
              withAttributes:remainingAttrs];

    NSString *gameCount = controllerMode ? OPNCurrentHeaderTimeText() : (self.gameCountText.length > 0 ? self.gameCountText : @"");
    NSMutableParagraphStyle *gameCountStyle = [[NSMutableParagraphStyle alloc] init];
    gameCountStyle.alignment = controllerMode ? NSTextAlignmentRight : NSTextAlignmentCenter;
    NSMutableDictionary<NSAttributedStringKey, id> *gameCountAttrs = [OpnTextStyle(10, OpnColor(kTextMuted), NSFontWeightMedium) mutableCopy];
    gameCountAttrs[NSParagraphStyleAttributeName] = gameCountStyle;
    [gameCount drawInRect:controllerMode ? NSMakeRect(NSMaxX(planRect) + 10.0, 71.0, 112.0, 14.0) : NSMakeRect(NSMinX(planRect), 40.0, NSWidth(planRect), 14)
          withAttributes:gameCountAttrs];

    NSRect avatarRect = controllerMode ? NSMakeRect(controllerStatsX, 18.0, 28.0, 28.0) : NSMakeRect(NSWidth(bounds) - 164, 17.0, 30, 30);
    NSBezierPath *avatar = [NSBezierPath bezierPathWithOvalInRect:avatarRect];

    NSString *name = self.accountName.length > 0 ? self.accountName : @"User";
    if (self.accountAvatarImage) {
        [NSGraphicsContext saveGraphicsState];
        [avatar addClip];
        [self.accountAvatarImage drawInRect:avatarRect
                                   fromRect:NSZeroRect
                                  operation:NSCompositingOperationSourceOver
                                   fraction:1.0
                             respectFlipped:YES
                                      hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
        [NSGraphicsContext restoreGraphicsState];
    } else {
        [OpnColor([self resolvedControllerAccentSoftRGB], 0.90) setFill];
        [avatar fill];
        NSString *initial = name.length > 0 ? [[name substringToIndex:1] uppercaseString] : @"U";
        NSMutableParagraphStyle *avatarStyle = [[NSMutableParagraphStyle alloc] init];
        avatarStyle.alignment = NSTextAlignmentCenter;
        NSMutableDictionary<NSAttributedStringKey, id> *avatarAttrs = [OpnTextStyle(13, OpnColor([self resolvedControllerAccentBlackRGB:0.88]), NSFontWeightBold) mutableCopy];
        avatarAttrs[NSParagraphStyleAttributeName] = avatarStyle;
        [initial drawInRect:NSMakeRect(NSMinX(avatarRect), NSMinY(avatarRect) + 7, NSWidth(avatarRect), 16) withAttributes:avatarAttrs];
    }

    if (controllerMode) {
        NSMutableParagraphStyle *accountTextStyle = [[NSMutableParagraphStyle alloc] init];
        accountTextStyle.alignment = NSTextAlignmentLeft;
        NSMutableDictionary<NSAttributedStringKey, id> *nameAttrs = [OpnTextStyle(12, OpnColor(kTextPrimary), NSFontWeightSemibold) mutableCopy];
        nameAttrs[NSParagraphStyleAttributeName] = accountTextStyle;
        [name drawInRect:NSMakeRect(NSMaxX(avatarRect) + 10.0, 17.0, 164.0, 17.0) withAttributes:nameAttrs];
    } else {
        [name drawInRect:NSMakeRect(NSWidth(bounds) - 124, 16.0, 72, 17)
           withAttributes:OpnTextStyle(12, OpnColor(kTextPrimary), NSFontWeightSemibold)];
    }
    NSString *status = self.accountStatus.length > 0 ? self.accountStatus : @"Signed in";
    if (controllerMode) {
        NSMutableParagraphStyle *statusTextStyle = [[NSMutableParagraphStyle alloc] init];
        statusTextStyle.alignment = NSTextAlignmentLeft;
        NSMutableDictionary<NSAttributedStringKey, id> *statusAttrs = [OpnTextStyle(10, OpnColor(kTextMuted), NSFontWeightRegular) mutableCopy];
        statusAttrs[NSParagraphStyleAttributeName] = statusTextStyle;
        [status drawInRect:NSMakeRect(NSMaxX(avatarRect) + 10.0, 33.0, 164.0, 14.0) withAttributes:statusAttrs];
    } else {
        [status drawInRect:NSMakeRect(NSWidth(bounds) - 124, 32.0, 72, 14)
                withAttributes:OpnTextStyle(10, OpnColor(kTextMuted), NSFontWeightRegular)];
    }

    _accountFrame = controllerMode ? NSMakeRect(controllerStatsX - 8.0, 12.0, controllerStatsWidth + 16.0, 82.0) : NSMakeRect(NSWidth(bounds) - 174, 9.0, 154, 48);
    NSBezierPath *chevron = [NSBezierPath bezierPath];
    CGFloat chevronX = controllerMode ? NSWidth(bounds) - 34.0 : NSWidth(bounds) - 36.0;
    CGFloat chevronY = controllerMode ? 28.0 : 28.0;
    [chevron moveToPoint:NSMakePoint(chevronX - 4.0, chevronY - 2.0)];
    [chevron lineToPoint:NSMakePoint(chevronX, chevronY + 2.0)];
    [chevron lineToPoint:NSMakePoint(chevronX + 4.0, chevronY - 2.0)];
    chevron.lineWidth = 1.5;
    [OpnColor(kTextMuted, 0.82) setStroke];
    [chevron stroke];
}

- (void)storeButtonPressed:(id)sender {
    (void)sender;
    if (OpnControllerModeEnabled()) return;
    if (self.onStoreSelected) self.onStoreSelected();
}

- (void)libraryButtonPressed:(id)sender {
    (void)sender;
    if (OpnControllerModeEnabled()) OpnPlayConsoleTone(OPNConsoleToneSelect);
    if (self.onLibrarySelected) self.onLibrarySelected();
}

- (void)settingsButtonPressed:(id)sender {
    (void)sender;
    if (OpnControllerModeEnabled()) OpnPlayConsoleTone(OPNConsoleToneSelect);
    if (self.onSettingsSelected) self.onSettingsSelected();
}

- (void)dismissControllerAccountMenu {
    [_controllerAccountMenuView removeFromSuperview];
    _controllerAccountMenuView = nil;
}

- (NSButton *)controllerAccountMenuButtonWithTitle:(NSString *)title
                                                y:(CGFloat)y
                                            width:(CGFloat)width
                                           height:(CGFloat)height
                                           action:(SEL)action
                                       identifier:(NSString *)identifier
                                         selected:(BOOL)selected
                                          warning:(BOOL)warning {
    OPNBackdropControllerAccountButton *button = [[OPNBackdropControllerAccountButton alloc] initWithFrame:NSMakeRect(16.0, y, width - 32.0, height)];
    button.bordered = NO;
    button.target = self;
    button.action = action;
    button.identifier = identifier ?: @"";
    button.title = @"";
    button.opnTitle = title;
    button.opnSelected = selected;
    button.opnWarning = warning;
    button.wantsLayer = YES;
    button.layer.cornerRadius = height / 2.0;
    button.layer.backgroundColor = selected ? OpnColor(OPNControllerAccentRGB(), 0.18).CGColor : OpnColor(OPNControllerAccentBlackRGB(0.72), warning ? 0.32 : 0.24).CGColor;
    button.layer.borderWidth = selected ? 1.0 : 0.0;
    button.layer.borderColor = OpnColor(OPNControllerAccentSoftRGB(), 0.52).CGColor;
    return button;
}

- (void)showControllerAccountMenu {
    if (_controllerAccountMenuView) {
        OpnPlayConsoleTone(OPNConsoleToneBack);
        [self dismissControllerAccountMenu];
        return;
    }
    OpnPlayConsoleTone(OPNConsoleToneSelect);

    CGFloat menuWidth = OPNControllerAccountMenuWidth(self.bounds);
    CGFloat accountRowHeight = 52.0;
    CGFloat actionRowHeight = 44.0;
    CGFloat y = 66.0;
    NSInteger accountCount = 0;
    for (NSDictionary<NSString *, NSString *> *account in self.accountMenuItems) {
        NSString *identifier = account[@"identifier"];
        NSString *title = account[@"label"];
        if (identifier.length == 0 || title.length == 0) continue;
        accountCount++;
        y += accountRowHeight + 10.0;
    }
    CGFloat menuHeight = y + 178.0;
    CGFloat menuX = MAX(20.0, NSWidth(self.bounds) - menuWidth - 20.0);

    NSView *menu = [[OPNBackdropControllerMenuView alloc] initWithFrame:NSMakeRect(menuX, 106.0, menuWidth, menuHeight)];
    menu.wantsLayer = YES;
    menu.layer.cornerRadius = 26.0;
    menu.layer.borderWidth = 1.0;
    menu.layer.borderColor = OpnColor(OPNControllerAccentSoftRGB(), 0.30).CGColor;
    menu.layer.backgroundColor = OpnColor(OPNControllerAccentBlackRGB(0.90), 0.97).CGColor;
    menu.layer.shadowColor = OpnColor(OPNControllerAccentRGB()).CGColor;
    menu.layer.shadowOpacity = 0.30;
    menu.layer.shadowRadius = 38.0;
    menu.layer.shadowOffset = CGSizeZero;

    NSTextField *titleLabel = OpnLabel(@"Account", NSMakeRect(20.0, 18.0, menuWidth - 40.0, 24.0), 16.0, OpnColor(OPN::kTextPrimary), NSFontWeightSemibold);
    [menu addSubview:titleLabel];
    NSTextField *subtitleLabel = OpnLabel(@"Profiles and session", NSMakeRect(20.0, 42.0, menuWidth - 40.0, 16.0), 11.0, OpnColor(OPN::kTextMuted), NSFontWeightMedium);
    [menu addSubview:subtitleLabel];

    y = 72.0;
    if (accountCount == 0) {
        NSTextField *emptyLabel = OpnLabel(@"No saved accounts", NSMakeRect(20.0, y, menuWidth - 40.0, 22.0), 13.0, OpnColor(OPN::kTextMuted), NSFontWeightMedium);
        [menu addSubview:emptyLabel];
        y += 34.0;
    } else {
        for (NSDictionary<NSString *, NSString *> *account in self.accountMenuItems) {
            NSString *identifier = account[@"identifier"];
            NSString *title = account[@"label"];
            if (identifier.length == 0 || title.length == 0) continue;
            BOOL selected = [identifier isEqualToString:self.currentAccountIdentifier];
            NSButton *button = [self controllerAccountMenuButtonWithTitle:title
                                                                        y:y
                                                                    width:menuWidth
                                                                   height:accountRowHeight
                                                                   action:@selector(controllerAccountMenuItemPressed:)
                                                               identifier:identifier
                                                                 selected:selected
                                                                   warning:NO];
            [menu addSubview:button];
            y += accountRowHeight + 10.0;
        }
    }

    NSView *divider = [[NSView alloc] initWithFrame:NSMakeRect(20.0, y + 8.0, menuWidth - 40.0, 1.0)];
    divider.wantsLayer = YES;
    divider.layer.backgroundColor = OpnColor(OPNControllerAccentSoftRGB(), 0.10).CGColor;
    [menu addSubview:divider];
    y += 24.0;

    [menu addSubview:[self controllerAccountMenuButtonWithTitle:@"Add Account" y:y width:menuWidth height:actionRowHeight action:@selector(controllerAddAccountPressed:) identifier:nil selected:NO warning:NO]];
    y += actionRowHeight + 8.0;
    [menu addSubview:[self controllerAccountMenuButtonWithTitle:@"Sign Out" y:y width:menuWidth height:actionRowHeight action:@selector(controllerSignOutPressed:) identifier:nil selected:NO warning:NO]];
    y += actionRowHeight + 8.0;
    [menu addSubview:[self controllerAccountMenuButtonWithTitle:@"Exit OpenNOW" y:y width:menuWidth height:actionRowHeight action:@selector(controllerExitPressed:) identifier:nil selected:NO warning:YES]];

    _controllerAccountMenuView = menu;
    [self addSubview:menu positioned:NSWindowAbove relativeTo:nil];
}

- (void)accountButtonPressed:(id)sender {
    (void)sender;
    if (OpnControllerModeEnabled()) {
        [self showControllerAccountMenu];
        return;
    }
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Account"];
    menu.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    menu.autoenablesItems = NO;
    if ([menu respondsToSelector:@selector(setMinimumWidth:)]) {
        menu.minimumWidth = 220.0;
    }
    for (NSDictionary<NSString *, NSString *> *account in self.accountMenuItems) {
        NSString *identifier = account[@"identifier"];
        NSString *title = account[@"label"];
        if (identifier.length == 0 || title.length == 0) continue;
        BOOL selected = [identifier isEqualToString:self.currentAccountIdentifier];
        NSString *displayTitle = selected ? [NSString stringWithFormat:@"%@  Current", title] : title;
        NSMenuItem *accountItem = OPNStyledMenuItem(displayTitle,
                                                    @selector(accountMenuItemPressed:),
                                                    self,
                                                    selected ? OpnColor(OPN::kTextPrimary) : OpnColor(OPN::kTextSecondary),
                                                    selected ? NSFontWeightSemibold : NSFontWeightMedium);
        accountItem.representedObject = identifier;
        accountItem.state = selected ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem:accountItem];
    }
    if (menu.numberOfItems > 0) {
        [menu addItem:[NSMenuItem separatorItem]];
    }
    NSMenuItem *addItem = OPNStyledMenuItem(@"Add Account",
                                            @selector(addAccountMenuItemPressed:),
                                            self,
                                            OpnColor(OPN::kTextPrimary),
                                            NSFontWeightSemibold);
    [menu addItem:addItem];
    NSMenuItem *signOutItem = OPNStyledMenuItem(@"Sign Out",
                                                @selector(signOutMenuItemPressed:),
                                                self,
                                                OpnColor(OPN::kTextSecondary),
                                                NSFontWeightMedium);
    [menu addItem:signOutItem];
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *exitItem = OPNStyledMenuItem(@"Exit OpenNOW",
                                             @selector(exitMenuItemPressed:),
                                             self,
                                             OpnColor(0xFF8A8A),
                                             NSFontWeightSemibold);
    [menu addItem:exitItem];
    [menu popUpMenuPositioningItem:nil
                        atLocation:NSMakePoint(0.0, NSHeight(_accountButton.bounds) + 2.0)
                            inView:_accountButton];
}

- (void)controllerAccountMenuItemPressed:(NSButton *)sender {
    NSString *identifier = sender.identifier;
    OpnPlayConsoleTone(OPNConsoleToneSelect);
    [self dismissControllerAccountMenu];
    if (identifier.length > 0 && self.onAccountSelected) self.onAccountSelected(identifier);
}

- (void)controllerAddAccountPressed:(id)sender {
    (void)sender;
    OpnPlayConsoleTone(OPNConsoleToneSelect);
    [self dismissControllerAccountMenu];
    if (self.onAddAccountSelected) self.onAddAccountSelected();
}

- (void)controllerSignOutPressed:(id)sender {
    (void)sender;
    OpnPlayConsoleTone(OPNConsoleToneBack);
    [self dismissControllerAccountMenu];
    if (self.onSignOutSelected) self.onSignOutSelected();
}

- (void)controllerExitPressed:(id)sender {
    (void)sender;
    OpnPlayConsoleTone(OPNConsoleToneBack);
    [self dismissControllerAccountMenu];
    if (self.onExitSelected) self.onExitSelected();
}

- (void)accountMenuItemPressed:(NSMenuItem *)sender {
    NSString *identifier = [sender.representedObject isKindOfClass:NSString.class] ? sender.representedObject : nil;
    if (identifier.length > 0 && self.onAccountSelected) self.onAccountSelected(identifier);
}

- (void)addAccountMenuItemPressed:(id)sender {
    (void)sender;
    if (self.onAddAccountSelected) self.onAddAccountSelected();
}

- (void)signOutMenuItemPressed:(id)sender {
    (void)sender;
    if (self.onSignOutSelected) self.onSignOutSelected();
}

- (void)exitMenuItemPressed:(id)sender {
    (void)sender;
    if (self.onExitSelected) self.onExitSelected();
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (_controllerAccountMenuView && !NSPointInRect(point, _controllerAccountMenuView.frame) && !NSPointInRect(point, _accountFrame)) {
        [self dismissControllerAccountMenu];
        return;
    }
    if (NSPointInRect(point, _storeNavFrame)) {
        if (self.onStoreSelected) self.onStoreSelected();
        return;
    }
    if (NSPointInRect(point, _libraryNavFrame)) {
        if (self.onLibrarySelected) self.onLibrarySelected();
        return;
    }
    if (NSPointInRect(point, _settingsNavFrame)) {
        if (self.onSettingsSelected) self.onSettingsSelected();
        return;
    }
    if (NSPointInRect(point, _accountFrame)) {
        [self accountButtonPressed:self];
        return;
    }
    [super mouseDown:event];
}

@end
