#import "OPNCloudmatchServerPickerView.h"
#import "../common/OPNColorTokens.h"
#import "../common/OPNUIHelpers.h"
#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>

typedef NS_OPTIONS(uint16_t, OPNCloudmatchGamepadButton) {
    OPNCloudmatchGamepadButtonUp = 1u << 0,
    OPNCloudmatchGamepadButtonDown = 1u << 1,
    OPNCloudmatchGamepadButtonA = 1u << 2,
    OPNCloudmatchGamepadButtonB = 1u << 3,
    OPNCloudmatchGamepadButtonY = 1u << 4,
};

static uint16_t OPNCloudmatchGamepadButtons(void) {
    NSArray<GCController *> *controllers = [GCController controllers];
    if (controllers.count == 0) return 0;
    GCExtendedGamepad *pad = controllers.firstObject.extendedGamepad;
    if (!pad) return 0;

    uint16_t buttons = 0;
    CGFloat y = pad.leftThumbstick.yAxis.value;
    if (pad.dpad.up.value > 0.5 || y > 0.55) buttons |= OPNCloudmatchGamepadButtonUp;
    if (pad.dpad.down.value > 0.5 || y < -0.55) buttons |= OPNCloudmatchGamepadButtonDown;
    if (pad.buttonA.value > 0.5) buttons |= OPNCloudmatchGamepadButtonA;
    if (pad.buttonB.value > 0.5) buttons |= OPNCloudmatchGamepadButtonB;
    if (pad.buttonY.value > 0.5) buttons |= OPNCloudmatchGamepadButtonY;
    return buttons;
}

@implementation OPNCloudmatchServerOption

- (instancetype)initWithName:(NSString *)name
                         url:(NSString *)url
                   latencyMs:(NSInteger)latencyMs
                    automatic:(BOOL)automatic {
    self = [super init];
    if (self) {
        _name = [(name.length > 0 ? name : @"Cloudmatch") copy];
        _url = [(url.length > 0 ? url : @"") copy];
        _latencyMs = latencyMs;
        _automatic = automatic;
    }
    return self;
}

- (NSString *)latencyText {
    if (self.latencyMs < 0) return @"Measuring";
    return self.automatic
        ? [NSString stringWithFormat:@"Best %ld ms", (long)self.latencyMs]
        : [NSString stringWithFormat:@"%ld ms", (long)self.latencyMs];
}

- (NSString *)detailText {
    if (self.automatic) {
        return self.latencyMs >= 0
            ? @"Lowest measured region"
            : @"Best available region";
    }

    return self.name.length > 0 ? self.name : @"Cloudmatch region";
}

@end

@interface OPNCloudmatchFlippedView : NSView
@end

@implementation OPNCloudmatchFlippedView
- (BOOL)isFlipped { return YES; }
@end

@interface OPNCloudmatchServerRowView : NSControl
@property (nonatomic, strong) OPNCloudmatchServerOption *option;
@property (nonatomic, assign) NSInteger optionIndex;
@property (nonatomic, assign, getter=isSelected) BOOL selected;
@property (nonatomic, strong) NSTextField *nameLabel;
@property (nonatomic, strong) NSTextField *latencyLabel;
- (instancetype)initWithFrame:(NSRect)frame option:(OPNCloudmatchServerOption *)option optionIndex:(NSInteger)optionIndex;
@end

@implementation OPNCloudmatchServerRowView

- (instancetype)initWithFrame:(NSRect)frame option:(OPNCloudmatchServerOption *)option optionIndex:(NSInteger)optionIndex {
    self = [super initWithFrame:frame];
    if (self) {
        _option = option;
        _optionIndex = optionIndex;
        self.wantsLayer = YES;
        self.layer.cornerRadius = 12.0;
        self.layer.borderWidth = 1.0;

        NSString *rowTitle = option.name.length > 0 ? option.name : @"Cloudmatch region";
        _nameLabel = OpnLabel(rowTitle, NSZeroRect, 13.5, OpnColor(OPN::kTextPrimary), NSFontWeightBold);
        _nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self addSubview:_nameLabel];

        _latencyLabel = OpnLabel(option.latencyText, NSZeroRect, 12.0, [OPNCloudmatchServerRowView latencyColorForMilliseconds:option.latencyMs], NSFontWeightBold, NSTextAlignmentCenter);
        _latencyLabel.wantsLayer = YES;
        _latencyLabel.layer.cornerRadius = 9.0;
        [self addSubview:_latencyLabel];

        [self updateAppearance];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }

+ (NSColor *)latencyColorForMilliseconds:(NSInteger)latencyMs {
    if (latencyMs < 0) return OpnColor(OPN::kTextMuted);
    if (latencyMs <= 50) return OpnColor(OPN::kBrandGreen);
    if (latencyMs <= 85) return OpnColor(0xFFD166);
    return OpnColor(OPN::kErrorRed);
}

- (void)setSelected:(BOOL)selected {
    if (_selected == selected) return;
    _selected = selected;
    [self updateAppearance];
}

- (void)updateAppearance {
    self.layer.backgroundColor = (self.selected ? OpnColor(0x102116, 0.50) : OpnColor(0x0D1013, 0.50)).CGColor;
    self.layer.borderColor = (self.selected ? OpnColor(OPN::kBrandGreen, 0.72) : OpnColor(0xFFFFFF, 0.10)).CGColor;
    self.nameLabel.textColor = self.selected ? OpnColor(0xF4FFF6) : OpnColor(OPN::kTextPrimary);
    self.latencyLabel.textColor = [OPNCloudmatchServerRowView latencyColorForMilliseconds:self.option.latencyMs];
    self.latencyLabel.layer.backgroundColor = (self.selected ? OpnColor(0x06140A, 0.50) : OpnColor(0x171B20, 0.50)).CGColor;
}

- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds);
    CGFloat contentX = 12.0;
    CGFloat latencyWidth = 86.0;
    CGFloat labelWidth = MAX(80.0, width - contentX - latencyWidth - 24.0);
    self.nameLabel.frame = NSMakeRect(contentX, 8.0, labelWidth, 19.0);
    self.latencyLabel.frame = NSMakeRect(width - latencyWidth - 12.0, 7.0, latencyWidth, 20.0);
}

- (void)mouseDown:(NSEvent *)event {
    (void)event;
    if (!self.enabled) return;
    [self sendAction:self.action to:self.target];
}

@end

@interface OPNCloudmatchServerPickerView ()
@property (nonatomic, copy) NSString *gameTitle;
@property (nonatomic, copy) NSArray<OPNCloudmatchServerOption *> *options;
@property (nonatomic, assign) NSInteger selectedIndex;
@property (nonatomic, assign) BOOL selectionWasChangedByUser;
@property (nonatomic, assign) BOOL refreshing;
@property (nonatomic, strong) NSView *panel;
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) OPNCloudmatchFlippedView *rowsDocumentView;
@property (nonatomic, strong) NSMutableArray<OPNCloudmatchServerRowView *> *rowViews;
@property (nonatomic, strong) NSButton *refreshButton;
@property (nonatomic, strong) NSButton *cancelButton;
@property (nonatomic, strong) NSButton *confirmButton;
@property (nonatomic, strong) NSTimer *controllerTimer;
@property (nonatomic, assign) uint16_t previousControllerButtons;
@property (nonatomic, assign) uint16_t heldControllerDirections;
@property (nonatomic, assign) CFTimeInterval lastControllerRepeatTime;
- (void)startControllerPolling;
- (void)stopControllerPolling;
- (void)pollController:(NSTimer *)timer;
@end

@implementation OPNCloudmatchServerPickerView

- (instancetype)initWithFrame:(NSRect)frame gameTitle:(NSString *)gameTitle {
    self = [super initWithFrame:frame];
    if (self) {
        _gameTitle = [(gameTitle.length > 0 ? gameTitle : @"this game") copy];
        _options = @[];
        _selectedIndex = 0;
        _rowViews = [NSMutableArray array];
        self.wantsLayer = YES;
        self.layer.backgroundColor = OpnColor(0x020304, 0.50).CGColor;

        _panel = [[NSView alloc] initWithFrame:NSZeroRect];
        _panel.wantsLayer = YES;
        _panel.layer.cornerRadius = 18.0;
        _panel.layer.backgroundColor = OpnColor(0x090B0E, 0.50).CGColor;
        _panel.layer.borderWidth = 1.0;
        _panel.layer.borderColor = OpnColor(0xFFFFFF, 0.12).CGColor;
        _panel.layer.shadowColor = NSColor.blackColor.CGColor;
        _panel.layer.shadowOpacity = 0.22;
        _panel.layer.shadowRadius = 20.0;
        _panel.layer.shadowOffset = CGSizeMake(0.0, 10.0);
        [self addSubview:_panel];

        _titleLabel = OpnLabel(@"Route", NSZeroRect, 18.0, OpnColor(OPN::kTextPrimary), NSFontWeightBlack);
        [_panel addSubview:_titleLabel];

        _rowsDocumentView = [[OPNCloudmatchFlippedView alloc] initWithFrame:NSZeroRect];
        _scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
        _scrollView.documentView = _rowsDocumentView;
        _scrollView.drawsBackground = NO;
        _scrollView.borderType = NSNoBorder;
        _scrollView.hasVerticalScroller = YES;
        _scrollView.autohidesScrollers = YES;
        [_panel addSubview:_scrollView];

        _refreshButton = OpnButton(@"Refresh", NSZeroRect, OpnColor(0x12171C, 0.50), OpnColor(OPN::kTextPrimary), true, OpnColor(0xFFFFFF, 0.14));
        _refreshButton.target = self;
        _refreshButton.action = @selector(refreshClicked:);
        [_panel addSubview:_refreshButton];

        _cancelButton = OpnButton(@"Cancel", NSZeroRect, OpnColor(0x161113, 0.50), OpnColor(OPN::kErrorRed), true, OpnColor(OPN::kErrorRed, 0.30));
        _cancelButton.target = self;
        _cancelButton.action = @selector(cancelClicked:);
        [_panel addSubview:_cancelButton];

        _confirmButton = OpnButton(@"Launch", NSZeroRect, OpnColor(0x102116, 0.50), OpnColor(OPN::kBrandGreen), true, OpnColor(OPN::kBrandGreen, 0.42));
        _confirmButton.target = self;
        _confirmButton.action = @selector(confirmClicked:);
        [_panel addSubview:_confirmButton];

        [self updateActions];
    }
    return self;
}

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)canBecomeKeyView { return YES; }

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window) {
        [self.window makeFirstResponder:self];
        [self startControllerPolling];
    } else {
        [self stopControllerPolling];
    }
}

- (void)dealloc {
    [self stopControllerPolling];
}

- (void)layout {
    [super layout];
    CGFloat hostWidth = NSWidth(self.bounds);
    CGFloat hostHeight = NSHeight(self.bounds);
    CGFloat panelWidth = MIN(460.0, MAX(340.0, hostWidth - 80.0));
    CGFloat panelHeight = MIN(420.0, MAX(360.0, hostHeight - 64.0));
    if (hostWidth < 390.0) panelWidth = MAX(300.0, hostWidth - 32.0);
    if (hostHeight < 440.0) panelHeight = MAX(300.0, hostHeight - 32.0);

    self.panel.frame = NSMakeRect(floor((hostWidth - panelWidth) / 2.0),
                                  floor((hostHeight - panelHeight) / 2.0),
                                  panelWidth,
                                  panelHeight);
    CGFloat contentX = 18.0;
    CGFloat contentWidth = panelWidth - 36.0;
    self.titleLabel.frame = NSMakeRect(contentX, panelHeight - 40.0, contentWidth, 22.0);

    CGFloat buttonY = 18.0;
    CGFloat buttonHeight = 34.0;
    CGFloat buttonGap = 8.0;
    CGFloat refreshWidth = 88.0;
    CGFloat confirmWidth = 108.0;
    CGFloat cancelWidth = 92.0;
    if (refreshWidth + cancelWidth + confirmWidth + buttonGap * 2.0 > contentWidth) {
        refreshWidth = floor((contentWidth - buttonGap * 2.0) / 3.0);
        cancelWidth = refreshWidth;
        confirmWidth = refreshWidth;
    }
    self.refreshButton.frame = NSMakeRect(contentX, buttonY, refreshWidth, buttonHeight);
    self.confirmButton.frame = NSMakeRect(contentX + contentWidth - confirmWidth, buttonY, confirmWidth, buttonHeight);
    self.cancelButton.frame = NSMakeRect(NSMinX(self.confirmButton.frame) - buttonGap - cancelWidth, buttonY, cancelWidth, buttonHeight);

    CGFloat scrollY = 64.0;
    CGFloat scrollHeight = MAX(110.0, panelHeight - 116.0);
    self.scrollView.frame = NSMakeRect(contentX, scrollY, contentWidth, scrollHeight);
    [self layoutRows];
}

- (void)setOptions:(NSArray<OPNCloudmatchServerOption *> *)options
 selectedRegionUrl:(NSString *)selectedRegionUrl
        refreshing:(BOOL)refreshing {
    OPNCloudmatchServerOption *previousSelection = nil;
    if (self.selectionWasChangedByUser && self.selectedIndex >= 0 && self.selectedIndex < (NSInteger)self.options.count) {
        previousSelection = self.options[(NSUInteger)self.selectedIndex];
    }

    self.options = [options copy] ?: @[];
    _refreshing = refreshing;
    NSString *preferredUrl = previousSelection ? previousSelection.url : (selectedRegionUrl ?: @"");
    self.selectedIndex = [self indexForRegionUrl:preferredUrl];
    if (self.selectedIndex < 0 && self.options.count > 0) self.selectedIndex = 0;
    [self renderRows];
    [self setRefreshing:refreshing];
}

- (void)setRefreshing:(BOOL)refreshing {
    _refreshing = refreshing;
    [self updateActions];
}

- (void)setStatusMessage:(NSString *)statusMessage isError:(BOOL)isError {
    (void)statusMessage;
    (void)isError;
}

- (NSInteger)indexForRegionUrl:(NSString *)regionUrl {
    NSString *target = regionUrl ?: @"";
    for (NSUInteger index = 0; index < self.options.count; index++) {
        OPNCloudmatchServerOption *option = self.options[index];
        if ([option.url isEqualToString:target]) return (NSInteger)index;
    }
    return -1;
}

- (void)renderRows {
    for (NSView *subview in self.rowsDocumentView.subviews) [subview removeFromSuperview];
    [self.rowViews removeAllObjects];

    for (NSUInteger index = 0; index < self.options.count; index++) {
        OPNCloudmatchServerRowView *row = [[OPNCloudmatchServerRowView alloc] initWithFrame:NSZeroRect option:self.options[index] optionIndex:(NSInteger)index];
        row.target = self;
        row.action = @selector(rowClicked:);
        row.selected = (NSInteger)index == self.selectedIndex;
        [self.rowsDocumentView addSubview:row];
        [self.rowViews addObject:row];
    }
    [self layoutRows];
}

- (void)layoutRows {
    CGFloat rowHeight = 34.0;
    CGFloat rowGap = 6.0;
    CGFloat visibleWidth = MAX(100.0, NSWidth(self.scrollView.contentView.bounds) - 2.0);
    CGFloat visibleHeight = MAX(1.0, NSHeight(self.scrollView.contentView.bounds));
    CGFloat totalHeight = self.rowViews.count == 0 ? visibleHeight : self.rowViews.count * rowHeight + (self.rowViews.count - 1) * rowGap;
    CGFloat documentHeight = MAX(visibleHeight, totalHeight + 2.0);
    self.rowsDocumentView.frame = NSMakeRect(0.0, 0.0, visibleWidth, documentHeight);
    for (NSUInteger index = 0; index < self.rowViews.count; index++) {
        OPNCloudmatchServerRowView *row = self.rowViews[index];
        row.frame = NSMakeRect(1.0, index * (rowHeight + rowGap), visibleWidth - 2.0, rowHeight);
        [row setNeedsLayout:YES];
    }
}

- (void)updateActions {
    BOOL hasSelection = self.selectedIndex >= 0 && self.selectedIndex < (NSInteger)self.options.count;
    self.confirmButton.enabled = hasSelection;
    self.confirmButton.alphaValue = hasSelection ? 1.0 : 0.48;
    self.refreshButton.enabled = !self.refreshing;
    self.refreshButton.alphaValue = self.refreshing ? 0.55 : 1.0;
    self.refreshButton.title = self.refreshing ? @"Pinging" : @"Refresh";
}

- (void)rowClicked:(OPNCloudmatchServerRowView *)sender {
    self.selectionWasChangedByUser = YES;
    self.selectedIndex = sender.optionIndex;
    [self updateRowSelection];
}

- (void)updateRowSelection {
    for (OPNCloudmatchServerRowView *row in self.rowViews) {
        row.selected = row.optionIndex == self.selectedIndex;
    }
    [self updateActions];
}

- (void)moveSelectionBy:(NSInteger)delta {
    if (self.options.count == 0) return;
    NSInteger nextIndex = MAX(0, MIN((NSInteger)self.options.count - 1, self.selectedIndex + delta));
    if (nextIndex == self.selectedIndex) return;
    self.selectionWasChangedByUser = YES;
    self.selectedIndex = nextIndex;
    [self updateRowSelection];
    [self scrollSelectedRowIntoView];
}

- (void)scrollSelectedRowIntoView {
    if (self.selectedIndex < 0 || self.selectedIndex >= (NSInteger)self.rowViews.count) return;
    OPNCloudmatchServerRowView *row = self.rowViews[(NSUInteger)self.selectedIndex];
    [self.rowsDocumentView scrollRectToVisible:NSInsetRect(row.frame, 0.0, -10.0)];
}

- (void)confirmClicked:(id)sender {
    (void)sender;
    if (self.selectedIndex < 0 || self.selectedIndex >= (NSInteger)self.options.count) return;
    if (self.onConfirm) self.onConfirm(self.options[(NSUInteger)self.selectedIndex]);
}

- (void)cancelClicked:(id)sender {
    (void)sender;
    if (self.onCancel) self.onCancel();
}

- (void)refreshClicked:(id)sender {
    (void)sender;
    if (self.refreshing) return;
    if (self.onRefresh) self.onRefresh();
}

- (void)startControllerPolling {
    if (self.controllerTimer) return;
    self.previousControllerButtons = OPNCloudmatchGamepadButtons();
    self.heldControllerDirections = 0;
    self.lastControllerRepeatTime = 0.0;
    self.controllerTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 30.0
                                                            target:self
                                                          selector:@selector(pollController:)
                                                          userInfo:nil
                                                           repeats:YES];
}

- (void)stopControllerPolling {
    [self.controllerTimer invalidate];
    self.controllerTimer = nil;
    self.previousControllerButtons = 0;
    self.heldControllerDirections = 0;
    self.lastControllerRepeatTime = 0.0;
}

- (void)pollController:(NSTimer *)timer {
    (void)timer;
    uint16_t buttons = OPNCloudmatchGamepadButtons();
    uint16_t pressed = buttons & ~self.previousControllerButtons;
    uint16_t directions = buttons & (OPNCloudmatchGamepadButtonUp | OPNCloudmatchGamepadButtonDown);
    CFTimeInterval now = CACurrentMediaTime();
    if (directions == 0) {
        self.heldControllerDirections = 0;
        self.lastControllerRepeatTime = 0.0;
    } else if (directions != self.heldControllerDirections || now - self.lastControllerRepeatTime >= 0.18) {
        self.heldControllerDirections = directions;
        self.lastControllerRepeatTime = now;
        if (directions & OPNCloudmatchGamepadButtonUp) [self moveSelectionBy:-1];
        if (directions & OPNCloudmatchGamepadButtonDown) [self moveSelectionBy:1];
    }

    if (pressed & OPNCloudmatchGamepadButtonA) [self confirmClicked:nil];
    if (pressed & OPNCloudmatchGamepadButtonB) [self cancelClicked:nil];
    if (pressed & OPNCloudmatchGamepadButtonY) [self refreshClicked:nil];
    self.previousControllerButtons = buttons;
}

- (void)keyDown:(NSEvent *)event {
    switch (event.keyCode) {
        case 36:
        case 76:
            [self confirmClicked:nil];
            return;
        case 53:
            [self cancelClicked:nil];
            return;
        case 125:
            [self moveSelectionBy:1];
            return;
        case 126:
            [self moveSelectionBy:-1];
            return;
        default:
            break;
    }

    NSString *characters = event.charactersIgnoringModifiers.lowercaseString;
    if ([characters isEqualToString:@"r"]) {
        [self refreshClicked:nil];
        return;
    }
    [super keyDown:event];
}

@end
