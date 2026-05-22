#import "OPNCloudmatchServerPickerView.h"
#import "../common/OPNColorTokens.h"
#import "../common/OPNUIHelpers.h"
#import <GameController/GameController.h>

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
            ? @"Automatically picks the lowest measured cloudmatch route."
            : @"Automatically picks the best available cloudmatch route.";
    }

    NSURL *endpointURL = [NSURL URLWithString:self.url];
    NSString *host = endpointURL.host.length > 0 ? endpointURL.host : self.url;
    return host.length > 0 ? [NSString stringWithFormat:@"Endpoint: %@", host] : @"Cloudmatch endpoint";
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
@property (nonatomic, strong) NSTextField *detailLabel;
@property (nonatomic, strong) NSTextField *latencyLabel;
@property (nonatomic, strong) NSTextField *selectedLabel;
- (instancetype)initWithFrame:(NSRect)frame option:(OPNCloudmatchServerOption *)option optionIndex:(NSInteger)optionIndex;
@end

@implementation OPNCloudmatchServerRowView

- (instancetype)initWithFrame:(NSRect)frame option:(OPNCloudmatchServerOption *)option optionIndex:(NSInteger)optionIndex {
    self = [super initWithFrame:frame];
    if (self) {
        _option = option;
        _optionIndex = optionIndex;
        self.wantsLayer = YES;
        self.layer.cornerRadius = 17.0;
        self.layer.borderWidth = 1.0;

        _nameLabel = OpnLabel(option.name, NSZeroRect, 16.0, OpnColor(OPN::kTextPrimary), NSFontWeightBold);
        _nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self addSubview:_nameLabel];

        _detailLabel = OpnLabel(option.detailText, NSZeroRect, 12.5, OpnColor(OPN::kTextSecondary), NSFontWeightMedium);
        _detailLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [self addSubview:_detailLabel];

        _latencyLabel = OpnLabel(option.latencyText, NSZeroRect, 13.0, [OPNCloudmatchServerRowView latencyColorForMilliseconds:option.latencyMs], NSFontWeightBold, NSTextAlignmentCenter);
        _latencyLabel.wantsLayer = YES;
        _latencyLabel.layer.cornerRadius = 11.0;
        [self addSubview:_latencyLabel];

        _selectedLabel = OpnLabel(@"", NSZeroRect, 10.5, OpnColor(OPN::kBrandGreen), NSFontWeightBlack, NSTextAlignmentRight);
        [self addSubview:_selectedLabel];

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
    self.layer.backgroundColor = (self.selected ? OpnColor(0x102116, 0.98) : OpnColor(0x0D1013, 0.96)).CGColor;
    self.layer.borderColor = (self.selected ? OpnColor(OPN::kBrandGreen, 0.72) : OpnColor(0xFFFFFF, 0.10)).CGColor;
    self.nameLabel.textColor = self.selected ? OpnColor(0xF4FFF6) : OpnColor(OPN::kTextPrimary);
    self.detailLabel.textColor = self.selected ? OpnColor(0xBDE7C8) : OpnColor(OPN::kTextSecondary);
    self.latencyLabel.textColor = [OPNCloudmatchServerRowView latencyColorForMilliseconds:self.option.latencyMs];
    self.latencyLabel.layer.backgroundColor = (self.selected ? OpnColor(0x06140A, 0.92) : OpnColor(0x171B20, 0.94)).CGColor;
    self.selectedLabel.stringValue = self.selected ? @"SELECTED" : @"";
}

- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds);
    CGFloat contentX = 18.0;
    CGFloat latencyWidth = 110.0;
    CGFloat selectedWidth = 86.0;
    CGFloat labelWidth = MAX(80.0, width - contentX - latencyWidth - selectedWidth - 34.0);
    self.nameLabel.frame = NSMakeRect(contentX, 10.0, labelWidth, 20.0);
    self.detailLabel.frame = NSMakeRect(contentX, 33.0, labelWidth, 18.0);
    self.latencyLabel.frame = NSMakeRect(width - latencyWidth - selectedWidth - 22.0, 17.0, latencyWidth, 24.0);
    self.selectedLabel.frame = NSMakeRect(width - selectedWidth - 18.0, 20.0, selectedWidth, 18.0);
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
@property (nonatomic, strong) NSView *accentBar;
@property (nonatomic, strong) NSTextField *eyebrowLabel;
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSTextField *subtitleLabel;
@property (nonatomic, strong) NSTextField *summaryLabel;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) OPNCloudmatchFlippedView *rowsDocumentView;
@property (nonatomic, strong) NSMutableArray<OPNCloudmatchServerRowView *> *rowViews;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSProgressIndicator *spinner;
@property (nonatomic, strong) NSButton *refreshButton;
@property (nonatomic, strong) NSButton *cancelButton;
@property (nonatomic, strong) NSButton *confirmButton;
@property (nonatomic, strong) NSTimer *controllerTimer;
@property (nonatomic, assign) uint16_t previousControllerButtons;
@end

static uint16_t OPNCloudmatchPickerGamepadButtons(void) {
    NSArray<GCController *> *controllers = [GCController controllers];
    if (controllers.count == 0) return 0;
    GCExtendedGamepad *pad = controllers.firstObject.extendedGamepad;
    if (!pad) return 0;

    uint16_t buttons = 0;
    if (pad.buttonA.value > 0.5) buttons |= 1u << 0;
    if (pad.buttonB.value > 0.5) buttons |= 1u << 1;
    if (pad.buttonX.value > 0.5) buttons |= 1u << 2;
    if (pad.dpad.up.value > 0.5 || pad.leftThumbstick.yAxis.value > 0.65) buttons |= 1u << 3;
    if (pad.dpad.down.value > 0.5 || pad.leftThumbstick.yAxis.value < -0.65) buttons |= 1u << 4;
    return buttons;
}

@implementation OPNCloudmatchServerPickerView

- (instancetype)initWithFrame:(NSRect)frame gameTitle:(NSString *)gameTitle {
    self = [super initWithFrame:frame];
    if (self) {
        _gameTitle = [(gameTitle.length > 0 ? gameTitle : @"this game") copy];
        _options = @[];
        _selectedIndex = 0;
        _rowViews = [NSMutableArray array];
        self.wantsLayer = YES;
        self.layer.backgroundColor = OpnColor(0x020304, 0.84).CGColor;

        _panel = [[NSView alloc] initWithFrame:NSZeroRect];
        _panel.wantsLayer = YES;
        _panel.layer.cornerRadius = 30.0;
        _panel.layer.backgroundColor = OpnColor(0x090B0E, 0.99).CGColor;
        _panel.layer.borderWidth = 1.5;
        _panel.layer.borderColor = OpnColor(0xFFFFFF, 0.16).CGColor;
        _panel.layer.shadowColor = NSColor.blackColor.CGColor;
        _panel.layer.shadowOpacity = 0.62;
        _panel.layer.shadowRadius = 52.0;
        _panel.layer.shadowOffset = CGSizeMake(0.0, 22.0);
        [self addSubview:_panel];

        _accentBar = [[NSView alloc] initWithFrame:NSZeroRect];
        _accentBar.wantsLayer = YES;
        _accentBar.layer.cornerRadius = 2.0;
        _accentBar.layer.backgroundColor = OpnColor(OPN::kBrandGreen, 0.92).CGColor;
        [_panel addSubview:_accentBar];

        _eyebrowLabel = OpnLabel(@"CLOUDMATCH ROUTE", NSZeroRect, 12.0, OpnColor(OPN::kBrandGreen), NSFontWeightBlack);
        [_panel addSubview:_eyebrowLabel];

        _titleLabel = OpnLabel(@"Choose Your Server", NSZeroRect, 33.0, OpnColor(OPN::kTextPrimary), NSFontWeightBlack);
        [_panel addSubview:_titleLabel];

        NSString *subtitle = [NSString stringWithFormat:@"Pick a cloudmatch server for %@ before the stream session is allocated.", _gameTitle];
        _subtitleLabel = OpnLabel(subtitle, NSZeroRect, 14.0, OpnColor(OPN::kTextSecondary), NSFontWeightMedium);
        _subtitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [_panel addSubview:_subtitleLabel];

        _summaryLabel = OpnLabel(@"Discovering cloudmatch regions...", NSZeroRect, 12.5, OpnColor(OPN::kTextMuted), NSFontWeightSemibold);
        [_panel addSubview:_summaryLabel];

        _rowsDocumentView = [[OPNCloudmatchFlippedView alloc] initWithFrame:NSZeroRect];
        _scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
        _scrollView.documentView = _rowsDocumentView;
        _scrollView.drawsBackground = NO;
        _scrollView.borderType = NSNoBorder;
        _scrollView.hasVerticalScroller = YES;
        _scrollView.autohidesScrollers = YES;
        [_panel addSubview:_scrollView];

        _statusLabel = OpnLabel(@"Measuring current latency...", NSZeroRect, 12.0, OpnColor(OPN::kTextMuted), NSFontWeightMedium);
        [_panel addSubview:_statusLabel];

        _spinner = OpnSpinner(NSZeroRect);
        [_panel addSubview:_spinner];

        _refreshButton = OpnButton(@"X  Refresh Ping", NSZeroRect, OpnColor(0x12171C, 0.98), OpnColor(OPN::kTextPrimary), true, OpnColor(0xFFFFFF, 0.16));
        _refreshButton.target = self;
        _refreshButton.action = @selector(refreshClicked:);
        [_panel addSubview:_refreshButton];

        _cancelButton = OpnButton(@"B  Cancel", NSZeroRect, OpnColor(0x161113, 0.98), OpnColor(OPN::kErrorRed), true, OpnColor(OPN::kErrorRed, 0.42));
        _cancelButton.target = self;
        _cancelButton.action = @selector(cancelClicked:);
        [_panel addSubview:_cancelButton];

        _confirmButton = OpnButton(@"A  Launch Here", NSZeroRect, OpnColor(0x102116, 0.98), OpnColor(OPN::kBrandGreen), true, OpnColor(OPN::kBrandGreen, 0.58));
        _confirmButton.target = self;
        _confirmButton.action = @selector(confirmClicked:);
        [_panel addSubview:_confirmButton];

        [self updateActions];
    }
    return self;
}

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)canBecomeKeyView { return YES; }

- (void)dealloc {
    [self stopControllerPolling];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window) {
        [self.window makeFirstResponder:self];
        [self startControllerPolling];
    } else {
        [self stopControllerPolling];
    }
}

- (void)layout {
    [super layout];
    CGFloat hostWidth = NSWidth(self.bounds);
    CGFloat hostHeight = NSHeight(self.bounds);
    CGFloat panelWidth = MIN(780.0, MAX(520.0, hostWidth - 96.0));
    CGFloat panelHeight = MIN(620.0, MAX(520.0, hostHeight - 72.0));
    if (hostWidth < 560.0) panelWidth = MAX(320.0, hostWidth - 32.0);
    if (hostHeight < 560.0) panelHeight = MAX(440.0, hostHeight - 32.0);

    self.panel.frame = NSMakeRect(floor((hostWidth - panelWidth) / 2.0),
                                  floor((hostHeight - panelHeight) / 2.0),
                                  panelWidth,
                                  panelHeight);
    CGFloat contentX = 36.0;
    CGFloat contentWidth = panelWidth - 72.0;
    self.accentBar.frame = NSMakeRect(contentX, panelHeight - 42.0, 92.0, 4.0);
    self.eyebrowLabel.frame = NSMakeRect(contentX, panelHeight - 78.0, contentWidth, 18.0);
    self.titleLabel.frame = NSMakeRect(contentX - 1.0, panelHeight - 128.0, contentWidth, 42.0);
    self.subtitleLabel.frame = NSMakeRect(contentX, panelHeight - 164.0, contentWidth, 21.0);
    self.summaryLabel.frame = NSMakeRect(contentX, panelHeight - 196.0, contentWidth, 20.0);

    CGFloat buttonY = 34.0;
    CGFloat buttonHeight = 48.0;
    CGFloat buttonGap = 12.0;
    CGFloat buttonWidth = floor((contentWidth - buttonGap * 2.0) / 3.0);
    self.refreshButton.frame = NSMakeRect(contentX, buttonY, buttonWidth, buttonHeight);
    self.cancelButton.frame = NSMakeRect(NSMaxX(self.refreshButton.frame) + buttonGap, buttonY, buttonWidth, buttonHeight);
    self.confirmButton.frame = NSMakeRect(NSMaxX(self.cancelButton.frame) + buttonGap, buttonY, buttonWidth, buttonHeight);

    self.spinner.frame = NSMakeRect(contentX, 96.0, 18.0, 18.0);
    self.statusLabel.frame = NSMakeRect(contentX + 26.0, 94.0, contentWidth - 26.0, 22.0);
    CGFloat scrollY = 128.0;
    CGFloat scrollHeight = MAX(180.0, panelHeight - 346.0);
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
    [self updateSummary];
    [self setRefreshing:refreshing];
}

- (void)setRefreshing:(BOOL)refreshing {
    _refreshing = refreshing;
    if (refreshing) {
        [self.spinner startAnimation:nil];
    } else {
        [self.spinner stopAnimation:nil];
    }
    [self updateSummary];
    [self updateActions];
}

- (void)setStatusMessage:(NSString *)statusMessage isError:(BOOL)isError {
    self.statusLabel.stringValue = statusMessage.length > 0 ? statusMessage : @"";
    self.statusLabel.textColor = isError ? OpnColor(OPN::kErrorRed) : OpnColor(OPN::kTextMuted);
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
    CGFloat rowHeight = 58.0;
    CGFloat rowGap = 10.0;
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

- (void)updateSummary {
    NSInteger regionCount = MAX(0, (NSInteger)self.options.count - 1);
    NSInteger measuredCount = 0;
    NSInteger bestLatency = NSIntegerMax;
    for (OPNCloudmatchServerOption *option in self.options) {
        if (option.automatic) continue;
        if (option.latencyMs >= 0) {
            measuredCount++;
            bestLatency = MIN(bestLatency, option.latencyMs);
        }
    }

    if (regionCount == 0) {
        self.summaryLabel.stringValue = self.refreshing ? @"Finding available cloudmatch regions..." : @"Automatic will use the default cloudmatch route.";
        return;
    }
    if (measuredCount == 0) {
        self.summaryLabel.stringValue = [NSString stringWithFormat:@"%ld cloudmatch %@ found. Measuring ping...", (long)regionCount, regionCount == 1 ? @"server" : @"servers"];
        return;
    }
    self.summaryLabel.stringValue = [NSString stringWithFormat:@"%ld cloudmatch %@ measured. Fastest route: %ld ms.",
                                     (long)measuredCount,
                                     measuredCount == 1 ? @"server" : @"servers",
                                     (long)bestLatency];
}

- (void)updateActions {
    BOOL hasSelection = self.selectedIndex >= 0 && self.selectedIndex < (NSInteger)self.options.count;
    self.confirmButton.enabled = hasSelection;
    self.confirmButton.alphaValue = hasSelection ? 1.0 : 0.48;
    self.refreshButton.enabled = !self.refreshing;
    self.refreshButton.alphaValue = self.refreshing ? 0.55 : 1.0;
    self.refreshButton.title = self.refreshing ? @"Pinging..." : @"X  Refresh Ping";
}

- (void)rowClicked:(OPNCloudmatchServerRowView *)sender {
    self.selectionWasChangedByUser = YES;
    self.selectedIndex = sender.optionIndex;
    [self updateRowSelection];
    OpnPlayConsoleTone(OPNConsoleToneMove);
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
    OpnPlayConsoleTone(OPNConsoleToneMove);
}

- (void)scrollSelectedRowIntoView {
    if (self.selectedIndex < 0 || self.selectedIndex >= (NSInteger)self.rowViews.count) return;
    OPNCloudmatchServerRowView *row = self.rowViews[(NSUInteger)self.selectedIndex];
    [self.rowsDocumentView scrollRectToVisible:NSInsetRect(row.frame, 0.0, -10.0)];
}

- (void)confirmClicked:(id)sender {
    (void)sender;
    if (self.selectedIndex < 0 || self.selectedIndex >= (NSInteger)self.options.count) return;
    OpnPlayConsoleTone(OPNConsoleToneSelect);
    if (self.onConfirm) self.onConfirm(self.options[(NSUInteger)self.selectedIndex]);
}

- (void)cancelClicked:(id)sender {
    (void)sender;
    OpnPlayConsoleTone(OPNConsoleToneBack);
    if (self.onCancel) self.onCancel();
}

- (void)refreshClicked:(id)sender {
    (void)sender;
    if (self.refreshing) return;
    OpnPlayConsoleTone(OPNConsoleToneChange);
    if (self.onRefresh) self.onRefresh();
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

- (void)startControllerPolling {
    if (self.controllerTimer || !OpnControllerModeEnabled()) return;
    self.previousControllerButtons = OPNCloudmatchPickerGamepadButtons();
    self.controllerTimer = [NSTimer scheduledTimerWithTimeInterval:(1.0 / 30.0)
                                                            target:self
                                                          selector:@selector(pollController)
                                                          userInfo:nil
                                                           repeats:YES];
}

- (void)stopControllerPolling {
    [self.controllerTimer invalidate];
    self.controllerTimer = nil;
    self.previousControllerButtons = 0;
}

- (void)pollController {
    if (!self.window) {
        [self stopControllerPolling];
        return;
    }

    uint16_t buttons = OPNCloudmatchPickerGamepadButtons();
    uint16_t pressed = buttons & (uint16_t)~self.previousControllerButtons;
    self.previousControllerButtons = buttons;
    if (pressed & (1u << 0)) {
        [self confirmClicked:nil];
        return;
    }
    if (pressed & (1u << 1)) {
        [self cancelClicked:nil];
        return;
    }
    if (pressed & (1u << 2)) {
        [self refreshClicked:nil];
        return;
    }
    if (pressed & (1u << 3)) [self moveSelectionBy:-1];
    if (pressed & (1u << 4)) [self moveSelectionBy:1];
}

@end
