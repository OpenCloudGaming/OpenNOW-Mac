#import "OPNBackdropView.h"
#import "../common/OPNColorTokens.h"
#import "../common/OPNUIHelpers.h"
#import "../common/OPNAuthTypes.h"
#include <cmath>

static NSRect OPNCenteredTextRect(NSString *text, NSDictionary<NSAttributedStringKey, id> *attributes, NSRect bounds) {
    NSSize size = [text sizeWithAttributes:attributes];
    return NSMakeRect(NSMidX(bounds) - ceil(size.width) * 0.5,
                      NSMidY(bounds) - ceil(size.height) * 0.5,
                      ceil(size.width),
                      ceil(size.height));
}

static NSColor *OPNBottomHintFill(NSString *button) {
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
        [OPNBottomHintFill(button) setFill];
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

- (BOOL)isFlipped { return YES; }

- (void)setMode:(OPNBackdropMode)mode {
    _mode = mode;
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
}

- (void)setCurrentAccountIdentifier:(NSString *)currentAccountIdentifier {
    _currentAccountIdentifier = [currentAccountIdentifier copy];
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
}

- (void)mouseDown:(NSEvent *)event {
    [super mouseDown:event];
}

@end
