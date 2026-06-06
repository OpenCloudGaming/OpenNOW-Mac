#import "OPNSessionReportView.h"
#import "../common/OPNColorTokens.h"
#import "../common/OPNLogCapture.h"
#import "../common/OPNUIHelpers.h"

#include <cmath>
#include <string>

using namespace OPN;

@implementation OPNSessionReportView {
    OPN::SessionHealthReport _report;
    NSTextField *_statusLabel;
}

- (instancetype)initWithFrame:(NSRect)frame report:(const OPN::SessionHealthReport &)report {
    self = [super initWithFrame:frame];
    if (self) {
        _report = report;
        self.wantsLayer = YES;
        self.layer.backgroundColor = OpnColor(0x020304, 0.50).CGColor;
        [self buildContent];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)layout {
    [super layout];
    [self rebuildContentForCurrentBounds];
}

- (void)rebuildContentForCurrentBounds {
    static BOOL rebuilding = NO;
    if (rebuilding) return;
    rebuilding = YES;
    NSArray<NSView *> *subviews = [self.subviews copy];
    for (NSView *subview in subviews) [subview removeFromSuperview];
    [self buildContent];
    rebuilding = NO;
}

- (NSString *)stringFromStdString:(const std::string &)value fallback:(NSString *)fallback {
    if (value.empty()) return fallback ?: @"";
    NSString *text = [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding];
    return text.length > 0 ? text : (fallback ?: @"");
}

- (NSTextField *)metricLabelWithTitle:(NSString *)title value:(NSString *)value frame:(NSRect)frame parent:(NSView *)parent {
    NSView *card = [[NSView alloc] initWithFrame:frame];
    card.wantsLayer = YES;
    card.layer.cornerRadius = 16.0;
    card.layer.backgroundColor = OpnColor(0x0A0D12, 0.50).CGColor;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = OpnColor(0xFFFFFF, 0.08).CGColor;
    [parent addSubview:card];

    NSTextField *titleLabel = OpnLabel(title, NSMakeRect(16.0, 12.0, NSWidth(frame) - 32.0, 18.0), 11.0, OpnColor(kTextMuted), NSFontWeightMedium);
    [card addSubview:titleLabel];
    NSTextField *valueLabel = OpnLabel(value, NSMakeRect(16.0, 34.0, NSWidth(frame) - 32.0, 28.0), 21.0, OpnColor(kTextPrimary), NSFontWeightSemibold);
    valueLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [card addSubview:valueLabel];
    return valueLabel;
}

- (NSString *)durationString:(double)seconds {
    std::string formatted = OPN::FormatSessionHealthDuration(seconds);
    return [self stringFromStdString:formatted fallback:@"Unknown"];
}

- (NSString *)metricDouble:(double)value suffix:(NSString *)suffix digits:(NSInteger)digits {
    if (!std::isfinite(value) || value < 0.0) return @"Unknown";
    NSString *format = digits == 0 ? @"%.0f%@" : @"%.1f%@";
    return [NSString stringWithFormat:format, value, suffix ?: @""];
}

- (void)buildContent {
    CGFloat width = NSWidth(self.bounds);
    CGFloat height = NSHeight(self.bounds);
    CGFloat panelWidth = width < 388.0 ? MAX(300.0, width - 24.0) : MIN(820.0, width - 48.0);
    CGFloat panelHeight = height < 492.0 ? MAX(320.0, height - 24.0) : MIN(640.0, height - 72.0);
    CGFloat panelX = floor((width - panelWidth) / 2.0);
    CGFloat panelY = floor((height - panelHeight) / 2.0);

    NSView *panel = [[NSView alloc] initWithFrame:NSMakeRect(panelX, panelY, panelWidth, panelHeight)];
    panel.wantsLayer = YES;
    panel.layer.cornerRadius = 24.0;
    panel.layer.backgroundColor = OpnColor(0x070A0E, 0.50).CGColor;
    panel.layer.borderWidth = 1.0;
    panel.layer.borderColor = OpnColor(0xFFFFFF, 0.12).CGColor;
    panel.layer.shadowColor = NSColor.blackColor.CGColor;
    panel.layer.shadowOpacity = 0.22;
    panel.layer.shadowRadius = 28.0;
    panel.layer.shadowOffset = CGSizeMake(0.0, -10.0);
    [self addSubview:panel];

    CGFloat margin = panelWidth < 500.0 ? 18.0 : 26.0;
    CGFloat contentWidth = MAX(300.0, panelWidth - margin * 2.0);
    CGFloat y = 24.0;

    NSString *gameTitle = [self stringFromStdString:_report.gameTitle fallback:@"Unknown Game"];
    NSString *result = _report.success ? @"Session ended normally" : @"Session ended with an error";
    NSColor *resultColor = _report.success ? OpnColor(kBrandGreen) : OpnColor(kErrorRed);

    [panel addSubview:OpnLabel(@"Session Report", NSMakeRect(margin, y, contentWidth, 32.0), 25.0, OpnColor(kTextPrimary), NSFontWeightBold)];
    y += 34.0;
    [panel addSubview:OpnLabel(gameTitle, NSMakeRect(margin, y, contentWidth, 20.0), 14.0, OpnColor(kTextSecondary), NSFontWeightMedium)];
    y += 25.0;
    [panel addSubview:OpnLabel(result, NSMakeRect(margin, y, contentWidth, 18.0), 12.0, resultColor, NSFontWeightSemibold)];
    y += 32.0;

    CGFloat gap = 12.0;
    CGFloat cardWidth = floor((contentWidth - gap * 3.0) / 4.0);
    if (cardWidth < 150.0) cardWidth = floor((contentWidth - gap) / 2.0);
    CGFloat cardHeight = 78.0;
    NSInteger columns = cardWidth < 150.0 ? 1 : (contentWidth >= 720.0 ? 4 : 2);
    cardWidth = floor((contentWidth - gap * (columns - 1)) / columns);

    NSArray<NSArray<NSString *> *> *metrics = @[
        @[@"Launch", [self durationString:_report.launchSeconds]],
        @[@"Avg Latency", [self metricDouble:_report.stats.averageLatencyMs suffix:@" ms" digits:0]],
        @[@"Avg Bitrate", [self metricDouble:_report.stats.averageBitrateMbps suffix:@" Mbps" digits:1]],
        @[@"Dropped Frames", [NSString stringWithFormat:@"%llu", (unsigned long long)_report.stats.framesDropped]]
    ];
    for (NSInteger index = 0; index < (NSInteger)metrics.count; index++) {
        NSInteger row = index / columns;
        NSInteger column = index % columns;
        NSRect frame = NSMakeRect(margin + column * (cardWidth + gap), y + row * (cardHeight + gap), cardWidth, cardHeight);
        [self metricLabelWithTitle:metrics[index][0] value:metrics[index][1] frame:frame parent:panel];
    }
    y += ((metrics.count + columns - 1) / columns) * (cardHeight + gap) + 18.0;

    CGFloat buttonWidth = 142.0;
    NSButton *copyButton = OpnButton(@"Copy Diagnostics", NSMakeRect(margin, y, buttonWidth, 38.0), OpnColor(kBrandGreen, 0.50), OpnColor(kAccentOn));
    copyButton.target = self;
    copyButton.action = @selector(copyDiagnosticsClicked);
    [panel addSubview:copyButton];

    NSButton *saveButton = OpnButton(@"Save Report", NSMakeRect(margin + buttonWidth + 10.0, y, 118.0, 38.0), OpnColor(0x151A22, 0.50), OpnColor(kTextPrimary), true, OpnColor(0xFFFFFF, 0.12));
    saveButton.target = self;
    saveButton.action = @selector(saveReportClicked);
    [panel addSubview:saveButton];

    NSButton *doneButton = OpnButton(@"Done", NSMakeRect(panelWidth - margin - 92.0, y, 92.0, 38.0), OpnColor(0x151A22, 0.50), OpnColor(kTextPrimary), true, OpnColor(0xFFFFFF, 0.12));
    doneButton.target = self;
    doneButton.action = @selector(doneClicked);
    [panel addSubview:doneButton];

    _statusLabel = OpnLabel(@"", NSMakeRect(margin, y + 46.0, contentWidth, 18.0), 12.0, OpnColor(kTextMuted), NSFontWeightRegular);
    [panel addSubview:_statusLabel];
    y += 76.0;

    CGFloat reportHeight = MAX(156.0, panelHeight - y - 24.0);
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(margin, y, contentWidth, reportHeight)];
    scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scrollView.hasVerticalScroller = YES;
    scrollView.drawsBackground = NO;
    scrollView.borderType = NSNoBorder;

    NSTextView *textView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, contentWidth, reportHeight)];
    textView.editable = NO;
    textView.selectable = YES;
    textView.drawsBackground = YES;
    textView.backgroundColor = OpnColor(0x070A0E, 0.50);
    textView.textColor = OpnColor(kTextSecondary);
    textView.font = [NSFont monospacedSystemFontOfSize:12.0 weight:NSFontWeightRegular];
    textView.textContainerInset = NSMakeSize(16.0, 14.0);
    std::string markdown = OPN::SessionHealthReportMarkdown(_report);
    textView.string = [self stringFromStdString:markdown fallback:@""];
    scrollView.documentView = textView;
    [panel addSubview:scrollView];
}

- (NSString *)reportTextForExport {
    std::string text = OPN::SessionHealthReportCopyText(_report);
    NSString *reportText = [self stringFromStdString:text fallback:@""];
    NSString *logPath = OPN::CapturedLogPath();
    if (logPath.length > 0) {
        reportText = [reportText stringByAppendingFormat:@"\n\nCaptured log: %@\n", logPath];
    }
    return reportText;
}

- (void)copyDiagnosticsClicked {
    NSString *reportText = [self reportTextForExport];
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    [pasteboard setString:reportText forType:NSPasteboardTypeString];
    _statusLabel.stringValue = @"Session report copied to clipboard.";
    OPN::AppendLogEvent(@"[SessionReport] Copied session report diagnostics");
}

- (void)saveReportClicked {
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = @"OpenNOW-Session-Report.md";
    panel.allowedFileTypes = @[@"md"];
    panel.canCreateDirectories = YES;
    __weak __typeof__(self) weakSelf = self;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf || result != NSModalResponseOK || !panel.URL) return;
        NSError *error = nil;
        BOOL ok = [[strongSelf reportTextForExport] writeToURL:panel.URL atomically:YES encoding:NSUTF8StringEncoding error:&error];
        strongSelf->_statusLabel.stringValue = ok ? @"Session report saved." : (error.localizedDescription ?: @"Unable to save session report.");
        OPN::AppendLogEvent(ok ? @"[SessionReport] Saved session report" : @"[SessionReport] Failed to save session report");
    }];
}

- (void)doneClicked {
    if (self.onDone) self.onDone();
}

@end
