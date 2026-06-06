#import "OPNSettingsView.h"
#import "../common/OPNColorTokens.h"
#import "../common/OPNUIHelpers.h"
#include "../games/OPNGameDataCache.h"
#include "../games/OPNGameService.h"
#include "../streaming/OPNLibWebRTCStreamSession.h"
#include "../streaming/OPNStreamBackend.h"
#include "../streaming/OPNStreamPreferences.h"
#include <QuartzCore/QuartzCore.h>
#include <CoreAudio/CoreAudio.h>
#import <Metal/Metal.h>
#if __has_include(<MetalFX/MetalFX.h>)
#import <MetalFX/MetalFX.h>
#define OPN_SETTINGS_HAVE_METALFX 1
#else
#define OPN_SETTINGS_HAVE_METALFX 0
#endif
#include <cmath>

static const CGFloat kSettingsNavHeight = 64.0;
static const CGFloat kSettingsTopInset = 72.0;
static const CGFloat kSettingsSidebarWidth = 300.0;
static const CGFloat kSettingsColumnGap = 28.0;

static NSString *OPNSettingsDisplayName(NSString *section) {
    if ([section isEqualToString:@"Stream"]) return @"Network";
    return section;
}

static NSDictionary<NSString *, NSString *> *OPNWebRTCBackendRuntimeInfo(void) {
    OPN::StreamPreferenceProfile profile = OPN::LoadStreamPreferenceProfile();
    BOOL libWebRTCAvailable = OPN::LibWebRTCStreamSession::IsAvailable() ? YES : NO;
    NSString *active = [NSString stringWithUTF8String:OPN::StreamWebRTCBackendName(OPN::ResolveStreamWebRTCBackend()).c_str()];
    NSString *libDescription = [NSString stringWithUTF8String:OPN::LibWebRTCStreamSession::AvailabilityDescription().c_str()];
    NSString *requestedCodec = [NSString stringWithUTF8String:(profile.codec.value.empty() ? std::string("H264") : profile.codec.value).c_str()];
    NSString *effectiveCodec = [requestedCodec caseInsensitiveCompare:@"auto"] == NSOrderedSame ? @"Hardware-selected at launch" : requestedCodec;
    NSString *status = libWebRTCAvailable ? @"Using libwebrtc" : @"libwebrtc unavailable";

    return @{
        @"status": status,
        @"effective": active,
        @"codec": [NSString stringWithFormat:@"%@ effective (%@ requested)", effectiveCodec, requestedCodec],
        @"libwebrtc": [NSString stringWithFormat:@"%@ (%@)", libWebRTCAvailable ? @"Available" : @"Unavailable", libDescription],
    };
}

static NSDictionary<NSString *, NSString *> *OPNLocalEnhancementRuntimeInfo(void) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    BOOL libWebRTCAvailable = OPN::LibWebRTCStreamSession::IsAvailable() ? YES : NO;
    BOOL metalAvailable = device != nil;
    NSString *gpuName = device.name.length > 0 ? device.name : (metalAvailable ? @"Metal GPU" : @"No Metal device detected");
    NSString *metalSpatial = metalAvailable
        ? [NSString stringWithFormat:@"Supported on %@", gpuName]
        : @"Unavailable: this Mac does not expose a Metal device";

    NSString *metalFX = @"Unavailable: MetalFX headers are not present in this build";
#if OPN_SETTINGS_HAVE_METALFX
    if (!metalAvailable) {
        metalFX = @"Unavailable: this Mac does not expose a Metal device";
    } else if (!NSClassFromString(@"MTLFXSpatialScalerDescriptor")) {
        metalFX = @"Unavailable: MetalFX is not present on this macOS version";
    } else if (@available(macOS 13.0, *)) {
        metalFX = [MTLFXSpatialScalerDescriptor supportsDevice:device]
            ? [NSString stringWithFormat:@"Supported on %@", gpuName]
            : [NSString stringWithFormat:@"Unavailable on %@", gpuName];
    } else {
        metalFX = @"Unavailable: requires macOS 13 or newer";
    }
#endif

    NSString *enhancedRecording = metalAvailable
        ? @"Supported while local upscaling is active; raw recording remains fallback"
        : @"Unavailable: enhanced capture requires Metal; raw recording remains fallback";
    NSString *nativeRenderer = libWebRTCAvailable ? @"Supported" : @"Unavailable: libwebrtc framework is missing";
    NSString *summary = [NSString stringWithFormat:@"Metal spatial upscaling: %@\nMetalFX spatial upscaling: %@\nEnhanced recording output: %@\nNative fallback renderer: %@", metalSpatial, metalFX, enhancedRecording, nativeRenderer];

    return @{
        @"gpu": gpuName,
        @"summary": summary,
    };
}

static NSInteger OPNSelectedPerformanceProfile(const OPN::StreamPreferenceProfile &profile) {
    if (!profile.enableL4S && !profile.enablePowerSaver && profile.codecIndex == 0 && profile.fpsIndex == 1 && profile.bitrateIndex == 2) return 0;
    if (!profile.enableL4S && !profile.enablePowerSaver && profile.codecIndex == 1 && profile.fpsIndex == 1 && profile.bitrateIndex == 4) return 1;
    return -1;
}

@interface OPNSettingsFlippedView : NSView
@end

@implementation OPNSettingsFlippedView
- (BOOL)isFlipped { return YES; }
@end

static uint16_t OPNShortcutModifierMaskFromFlags(NSEventModifierFlags flags) {
    uint16_t out = 0;
    if (flags & NSEventModifierFlagShift) out |= 0x01;
    if (flags & NSEventModifierFlagControl) out |= 0x02;
    if (flags & NSEventModifierFlagOption) out |= 0x04;
    if (flags & NSEventModifierFlagCommand) out |= 0x08;
    if (flags & NSEventModifierFlagCapsLock) out |= 0x10;
    return out;
}

static uint16_t OPNShortcutModifierBitForKeyCode(uint16_t keyCode) {
    switch (keyCode) {
        case 55: return 0x08;
        case 56:
        case 60: return 0x01;
        case 57: return 0x10;
        case 58:
        case 61: return 0x04;
        case 59:
        case 62: return 0x02;
        default: return 0;
    }
}

@interface OPNPushToTalkShortcutField : NSTextField
@property (nonatomic, assign) uint16_t shortcutKeyCode;
@property (nonatomic, assign) uint16_t shortcutModifierMask;
@property (nonatomic, copy) void (^onShortcutChanged)(uint16_t keyCode, uint16_t modifierMask);
- (void)configureWithKeyCode:(uint16_t)keyCode modifierMask:(uint16_t)modifierMask;
@end

@implementation OPNPushToTalkShortcutField

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.editable = NO;
        self.selectable = NO;
        self.bordered = NO;
        self.drawsBackground = NO;
        self.focusRingType = NSFocusRingTypeNone;
        self.font = [NSFont systemFontOfSize:14.0 weight:NSFontWeightMedium];
        self.textColor = OpnColor(OPN::kTextPrimary);
        self.alignment = NSTextAlignmentLeft;
        self.wantsLayer = YES;
        self.layer.backgroundColor = OpnColor(0x090A0C, 0.72).CGColor;
        self.layer.cornerRadius = 11.0;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = OpnColor(OPN::kPanelBorder, 0.78).CGColor;
    }
    return self;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (BOOL)becomeFirstResponder {
    BOOL result = [super becomeFirstResponder];
    self.layer.borderColor = OpnColor(OPN::kBrandGreen, 0.70).CGColor;
    return result;
}

- (BOOL)resignFirstResponder {
    BOOL result = [super resignFirstResponder];
    self.layer.borderColor = OpnColor(OPN::kPanelBorder, 0.78).CGColor;
    return result;
}

- (void)mouseDown:(NSEvent *)event {
    (void)event;
    [self.window makeFirstResponder:self];
}

- (void)configureWithKeyCode:(uint16_t)keyCode modifierMask:(uint16_t)modifierMask {
    self.shortcutKeyCode = keyCode;
    self.shortcutModifierMask = modifierMask & 0x1f;
    std::string label = OPN::StreamMicrophonePushToTalkComboLabel(self.shortcutKeyCode, self.shortcutModifierMask);
    self.stringValue = [NSString stringWithUTF8String:label.c_str()];
}

- (void)captureShortcutFromEvent:(NSEvent *)event {
    if (event.keyCode > 127) return;
    uint16_t keyCode = (uint16_t)event.keyCode;
    uint16_t modifierMask = OPNShortcutModifierMaskFromFlags(event.modifierFlags);
    [self configureWithKeyCode:keyCode modifierMask:modifierMask];
    if (self.onShortcutChanged) self.onShortcutChanged(keyCode, modifierMask);
}

- (void)keyDown:(NSEvent *)event {
    if (event.isARepeat) return;
    [self captureShortcutFromEvent:event];
}

- (void)flagsChanged:(NSEvent *)event {
    if (event.keyCode > 127) return;
    uint16_t modifierBit = OPNShortcutModifierBitForKeyCode((uint16_t)event.keyCode);
    if (modifierBit == 0) return;
    if ((OPNShortcutModifierMaskFromFlags(event.modifierFlags) & modifierBit) == 0) return;
    [self captureShortcutFromEvent:event];
}

@end

@interface OPNSettingsView ()
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSView *shellView;
@property (nonatomic, strong) NSView *sidebarView;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSView *documentView;
@property (nonatomic, strong) NSMutableArray<NSButton *> *sidebarButtons;
@property (nonatomic, strong) NSArray<NSString *> *sectionNames;
@property (nonatomic, assign) NSInteger selectedSection;
@property (nonatomic, assign) NSInteger selectedAspect;
@property (nonatomic, assign) NSInteger selectedResolution;
@property (nonatomic, assign) NSInteger selectedFps;
@property (nonatomic, assign) NSInteger selectedRegion;
@property (nonatomic, assign) NSInteger selectedCodec;
@property (nonatomic, assign) NSInteger selectedBitrate;
@property (nonatomic, assign) NSInteger selectedColorDepth;
@property (nonatomic, assign) NSInteger selectedPrefilterMode;
@property (nonatomic, assign) NSInteger selectedUpscalingMode;
@property (nonatomic, assign) NSInteger selectedMicrophoneMode;
@property (nonatomic, assign) NSInteger selectedMicrophoneDevice;
@property (nonatomic, assign) BOOL enableL4S;
@property (nonatomic, assign) BOOL enableHdr;
@property (nonatomic, assign) BOOL suppressInputWhenInactive;
@property (nonatomic, assign) BOOL directMouseInput;
@property (nonatomic, assign) BOOL audioDeviceListenerInstalled;
@property (nonatomic, assign) CGFloat contentAreaWidth;
@property (nonatomic, strong) NSTimer *layoutRebuildTimer;
- (void)scheduleLayoutRebuildContent;
- (void)layoutRebuildTimerFired:(NSTimer *)timer;
- (void)applyPerformanceProfile:(NSInteger)index;
- (void)addOptionGroupTo:(NSView *)parent
                   group:(NSInteger)group
                  titles:(NSArray<NSString *> *)titles
                selected:(NSInteger)selected
                       y:(CGFloat)y
                   widths:(NSArray<NSNumber *> *)widths
                  enabled:(NSArray<NSNumber *> *)enabled;
- (void)audioDevicesChanged;
- (void)checkForUpdatesClicked:(NSButton *)sender;
- (void)clearCachesClicked:(NSButton *)sender;
- (void)recordingVideoBitrateSliderChanged:(NSSlider *)sender;
- (void)recordingAudioBitrateSliderChanged:(NSSlider *)sender;
@end

static OSStatus OPNSettingsAudioDevicesChanged(AudioObjectID, UInt32, const AudioObjectPropertyAddress *, void *clientData) {
    OPNSettingsView *view = (__bridge OPNSettingsView *)clientData;
    dispatch_async(dispatch_get_main_queue(), ^{
        [view audioDevicesChanged];
    });
    return noErr;
}

@implementation OPNSettingsView

using namespace OPN;

- (instancetype)initWithFrame:(NSRect)frame {
    return [self initWithFrame:frame selectedSectionName:nil];
}

- (instancetype)initWithFrame:(NSRect)frame selectedSectionName:(NSString *)selectedSectionName {
    self = [super initWithFrame:frame];
    if (self) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = [NSColor clearColor].CGColor;
        _selectedSection = 0;
        OPN::StreamPreferenceProfile profile = OPN::LoadStreamPreferenceProfile();
        _selectedAspect = profile.aspectIndex;
        _selectedResolution = profile.resolutionIndex;
        _selectedFps = profile.fpsIndex;
        _selectedRegion = 0;
        _selectedCodec = profile.codecIndex;
        _selectedBitrate = profile.bitrateIndex;
        _selectedColorDepth = profile.colorQualityIndex;
        _selectedPrefilterMode = profile.prefilterModeIndex;
        _selectedUpscalingMode = profile.upscalingModeIndex;
        _selectedMicrophoneMode = profile.microphoneMode == "push-to-talk" ? 1 : (profile.microphoneMode == "voice-activity" ? 2 : 0);
        _selectedMicrophoneDevice = 0;
        _enableL4S = profile.enableL4S;
        _enableHdr = profile.enableHdr;
        _suppressInputWhenInactive = profile.suppressInputWhenInactive;
        _directMouseInput = profile.directMouseInput;
        _sectionNames = @[@"Stream", @"Video", @"Audio", @"Input", @"Interface", @"About", @"Thanks"];
        _sidebarButtons = [NSMutableArray array];
        NSUInteger requestedSection = selectedSectionName.length > 0 ? [_sectionNames indexOfObject:selectedSectionName] : NSNotFound;
        if (requestedSection != NSNotFound) _selectedSection = (NSInteger)requestedSection;

        _titleLabel = OpnLabel(@"", NSZeroRect, 28.0, OpnColor(kTextPrimary), NSFontWeightSemibold);
        _titleLabel.hidden = YES;
        [self addSubview:_titleLabel];

        _shellView = [[OPNSettingsFlippedView alloc] initWithFrame:NSZeroRect];
        _shellView.wantsLayer = YES;
        _shellView.layer.backgroundColor = OpnColor(0x0F1013, 0.58).CGColor;
        _shellView.layer.cornerRadius = 18.0;
        _shellView.layer.borderWidth = 1.0;
        _shellView.layer.borderColor = OpnColor(0xFFFFFF, 0.08).CGColor;
        [self addSubview:_shellView];

        _sidebarView = [[OPNSettingsFlippedView alloc] initWithFrame:NSZeroRect];
        _sidebarView.wantsLayer = YES;
        _sidebarView.layer.backgroundColor = OpnColor(0x08090B, 0.62).CGColor;
        [_shellView addSubview:_sidebarView];
        self.titleLabel.textColor = OpnColor(kTextPrimary);

        [self buildSidebarButtons];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(streamRegionsUpdated:)
                                                     name:@"OpenNOW.StreamRegionsUpdated"
                                                   object:nil];
        [self startAudioDeviceMonitoring];

        _scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
        _scrollView.hasVerticalScroller = YES;
        _scrollView.hasHorizontalScroller = NO;
        _scrollView.autohidesScrollers = YES;
        _scrollView.drawsBackground = NO;
        _scrollView.borderType = NSNoBorder;
        [_shellView addSubview:_scrollView];

        _documentView = [[OPNSettingsFlippedView alloc] initWithFrame:NSZeroRect];
        _documentView.wantsLayer = YES;
        _scrollView.documentView = _documentView;
        [self rebuildContent];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }

- (BOOL)acceptsFirstResponder { return YES; }

- (void)dealloc {
    [self.layoutRebuildTimer invalidate];
    [self stopAudioDeviceMonitoring];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)startAudioDeviceMonitoring {
    if (self.audioDeviceListenerInstalled) return;
    AudioObjectPropertyAddress devicesAddress = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    AudioObjectPropertyAddress defaultInputAddress = {
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    OSStatus devicesStatus = AudioObjectAddPropertyListener(kAudioObjectSystemObject, &devicesAddress, OPNSettingsAudioDevicesChanged, (__bridge void *)self);
    OSStatus inputStatus = AudioObjectAddPropertyListener(kAudioObjectSystemObject, &defaultInputAddress, OPNSettingsAudioDevicesChanged, (__bridge void *)self);
    self.audioDeviceListenerInstalled = devicesStatus == noErr || inputStatus == noErr;
}

- (void)stopAudioDeviceMonitoring {
    if (!self.audioDeviceListenerInstalled) return;
    AudioObjectPropertyAddress devicesAddress = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    AudioObjectPropertyAddress defaultInputAddress = {
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &devicesAddress, OPNSettingsAudioDevicesChanged, (__bridge void *)self);
    AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &defaultInputAddress, OPNSettingsAudioDevicesChanged, (__bridge void *)self);
    self.audioDeviceListenerInstalled = NO;
}

- (void)audioDevicesChanged {
    if ([self.sectionNames[self.selectedSection] isEqualToString:@"Audio"]) {
        [self rebuildContent];
    }
}

- (void)streamRegionsUpdated:(NSNotification *)notification {
    (void)notification;
    if ([self.sectionNames[self.selectedSection] isEqualToString:@"Stream"]) {
        [self rebuildContent];
    }
}

- (void)buildSidebarButtons {
    for (NSUInteger i = 0; i < self.sectionNames.count; i++) {
        NSButton *button = [[NSButton alloc] initWithFrame:NSZeroRect];
        button.title = OPNSettingsDisplayName(self.sectionNames[i]);
        button.tag = (NSInteger)i;
        button.bordered = NO;
        button.target = self;
        button.action = @selector(sectionClicked:);
        button.wantsLayer = YES;
        [self.sidebarButtons addObject:button];
        [self.sidebarView addSubview:button];
    }
    [self restyleSidebarButtons];
}

- (void)restyleSidebarButtons {
    for (NSButton *button in self.sidebarButtons) {
        BOOL selected = button.tag == self.selectedSection;
        NSString *section = self.sectionNames[(NSUInteger)button.tag];
        button.hidden = NO;
        button.title = OPNSettingsDisplayName(section);
        button.font = [NSFont systemFontOfSize:14.0 weight:selected ? NSFontWeightSemibold : NSFontWeightRegular];
        button.alignment = NSTextAlignmentCenter;
        button.contentTintColor = selected ? OpnColor(kTextPrimary) : OpnColor(kTextSecondary);
        button.layer.cornerRadius = 10.0;
        button.layer.borderWidth = 0.0;
        button.layer.borderColor = (selected ? OpnColor(0xEFC8F7, 0.95) : OpnColor(0xFFFFFF, 0.18)).CGColor;
        button.layer.backgroundColor = selected ? OpnColor(kBrandGreen, 0.12).CGColor : [NSColor clearColor].CGColor;
    }
}

- (void)sectionClicked:(NSButton *)sender {
    self.selectedSection = sender.tag;
    [self restyleSidebarButtons];
    [self rebuildContent];
}

- (void)moveGamepadSelectionBy:(NSInteger)delta {
    if (self.sectionNames.count == 0 || delta == 0) return;
    NSInteger nextSection = MAX(0, MIN((NSInteger)self.sectionNames.count - 1, self.selectedSection + delta));
    if (nextSection == self.selectedSection) return;
    self.selectedSection = nextSection;
    [self restyleSidebarButtons];
    [self rebuildContent];
}

- (void)activateGamepadSelection {
    [self restyleSidebarButtons];
}

- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds);
    self.scrollView.hidden = NO;
    self.titleLabel.font = [NSFont systemFontOfSize:28.0 weight:NSFontWeightSemibold];
    CGFloat outerMargin = width < 900.0 ? 24.0 : 64.0;
    CGFloat contentWidth = MIN(1560.0, MAX(360.0, width - outerMargin * 2.0));
    CGFloat x = floor((width - contentWidth) / 2.0);
    CGFloat navHeight = kSettingsNavHeight;
    CGFloat y = navHeight + kSettingsTopInset;
    self.titleLabel.frame = NSMakeRect(x, y - 48.0, 240.0, 34.0);
    CGFloat shellHeight = MAX(360.0, NSHeight(self.bounds) - y - 34.0);
    self.shellView.frame = NSMakeRect(x, y, contentWidth, shellHeight);
    self.shellView.layer.cornerRadius = 18.0;
    self.shellView.layer.borderWidth = 1.0;
    CGFloat sidebarWidth = width < 900.0 ? 210.0 : MIN(kSettingsSidebarWidth, MAX(240.0, contentWidth * 0.26));
    CGFloat columnGap = width < 900.0 ? 16.0 : kSettingsColumnGap;
    self.sidebarView.frame = NSMakeRect(0, 0, sidebarWidth, shellHeight);

    CGFloat buttonY = 22.0;
    for (NSButton *button in self.sidebarButtons) {
        if (button.hidden) continue;
        button.frame = NSMakeRect(18, buttonY, MAX(160.0, sidebarWidth - 36.0), 44);
        buttonY += 54.0;
    }

    CGFloat scrollX = sidebarWidth + columnGap;
    CGFloat scrollWidth = MAX(260.0, contentWidth - scrollX - 28.0);
    self.scrollView.frame = NSMakeRect(scrollX, 22.0, scrollWidth, shellHeight - 44.0);
    if (std::fabs(self.contentAreaWidth - scrollWidth) > 1.0) {
        self.contentAreaWidth = scrollWidth;
        [self scheduleLayoutRebuildContent];
    }
    self.documentView.frame = NSMakeRect(0, 0, NSWidth(self.scrollView.frame), MAX(NSHeight(self.scrollView.frame), NSHeight(self.documentView.frame)));
    [self layoutContentSubviews];
}

- (void)scheduleLayoutRebuildContent {
    [self.layoutRebuildTimer invalidate];
    self.layoutRebuildTimer = [NSTimer scheduledTimerWithTimeInterval:0.16
                                                               target:self
                                                             selector:@selector(layoutRebuildTimerFired:)
                                                             userInfo:nil
                                                              repeats:NO];
}

- (void)layoutRebuildTimerFired:(NSTimer *)timer {
    (void)timer;
    self.layoutRebuildTimer = nil;
    [self rebuildContent];
}

- (void)layoutContentSubviews {
    CGFloat width = NSWidth(self.documentView.bounds);
    CGFloat y = 0;
    for (NSView *subview in self.documentView.subviews) {
        subview.frame = NSMakeRect(0, y, width, NSHeight(subview.frame));
        y += NSHeight(subview.frame) + 24.0;
    }
    self.documentView.frame = NSMakeRect(0, 0, width, MAX(y, NSHeight(self.scrollView.contentView.bounds)));
}

- (void)rebuildContent {
    for (NSView *view in [self.documentView.subviews copy]) {
        [view removeFromSuperview];
    }
    NSString *section = self.sectionNames[self.selectedSection];
    self.titleLabel.stringValue = @"";
    if ([section isEqualToString:@"Stream"]) {
        [self buildStreamContent];
    } else if ([section isEqualToString:@"Video"]) {
        [self buildVideoContent];
    } else if ([section isEqualToString:@"Audio"]) {
        [self buildAudioContent];
    } else if ([section isEqualToString:@"Input"]) {
        [self buildInputContent];
    } else if ([section isEqualToString:@"Interface"]) {
        [self buildInterfaceContent];
    } else if ([section isEqualToString:@"About"]) {
        [self buildAboutContent];
    } else {
        [self buildSimpleSectionContent:section];
    }
    [self setNeedsLayout:YES];
}

- (NSView *)panelWithTitle:(NSString *)title height:(CGFloat)height {
    CGFloat panelWidth = MAX(320.0, self.contentAreaWidth > 0 ? self.contentAreaWidth : 720.0);
    NSView *panel = [[OPNSettingsFlippedView alloc] initWithFrame:NSMakeRect(0, 0, panelWidth, height)];
    panel.wantsLayer = YES;
    panel.layer.backgroundColor = OpnColor(kSurfaceRaised, 0.66).CGColor;
    panel.layer.cornerRadius = 18.0;
    panel.layer.borderWidth = 1.0;
    panel.layer.borderColor = OpnColor(0xFFFFFF, 0.08).CGColor;
    [panel addSubview:OpnLabel(title, NSMakeRect(24, 26, 260, 28), 19.0, OpnColor(kTextPrimary), NSFontWeightSemibold)];
    NSView *divider = [[NSView alloc] initWithFrame:NSMakeRect(24, 72, MAX(120.0, panelWidth - 48.0), 1)];
    divider.wantsLayer = YES;
    divider.layer.backgroundColor = OpnColor(0xFFFFFF, 0.08).CGColor;
    [panel addSubview:divider];
    return panel;
}

- (void)buildStreamContent {
    CGFloat panelWidth = MAX(320.0, self.contentAreaWidth > 0 ? self.contentAreaWidth : 720.0);
    CGFloat controlX = [self controlXForPanelWidth:panelWidth];
    CGFloat controlWidth = [self controlWidthForPanelWidth:panelWidth];
    NSView *region = [self panelWithTitle:@"Region" height:202.0];
    [region addSubview:[self rowLabel:@"Server" y:112.0]];
    [region addSubview:[self regionPopupWithFrame:NSMakeRect(controlX, 100.0, controlWidth, 42.0)]];
    NSTextField *hint = OpnLabel(@"Automatic uses the lowest measured region when available. Pick a region to override it.",
                                 NSMakeRect(controlX, 152.0, controlWidth, 34.0),
                                 12.0,
                                 OpnColor(kTextMuted),
                                 NSFontWeightRegular);
    hint.maximumNumberOfLines = 2;
    [region addSubview:hint];
    [self.documentView addSubview:region];

    NSView *network = [self panelWithTitle:@"Network" height:292.0];
    OPN::StreamPreferenceProfile profile = OPN::LoadStreamPreferenceProfile();
    [network addSubview:[self rowLabel:@"Profile" y:112.0]];
    [self addOptionGroupTo:network group:9 titles:@[@"Low Latency", @"Quality"] selected:OPNSelectedPerformanceProfile(profile) y:102.0 widths:@[@126.0, @92.0]];
    NSTextField *profileHint = OpnLabel(@"Presets adjust codec, FPS, bitrate, and disable experimental L4S for new sessions. Manual controls can still override them.",
                                         NSMakeRect(controlX, 152.0, controlWidth, 40.0),
                                        12.0,
                                        OpnColor(kTextMuted),
                                        NSFontWeightRegular);
    profileHint.maximumNumberOfLines = 2;
    [network addSubview:profileHint];

    [network addSubview:[self rowLabel:@"L4S Mode" y:224.0]];
    NSButton *l4sToggle = [[NSButton alloc] initWithFrame:NSMakeRect(controlX, 216.0, controlWidth, 28.0)];
    l4sToggle.buttonType = NSButtonTypeSwitch;
    l4sToggle.title = @"Enable experimental L4S requests";
    l4sToggle.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightMedium];
    l4sToggle.contentTintColor = OpnColor(kBrandGreen);
    l4sToggle.state = self.enableL4S ? NSControlStateValueOn : NSControlStateValueOff;
    l4sToggle.target = self;
    l4sToggle.action = @selector(l4sToggleChanged:);
    [network addSubview:l4sToggle];
    NSTextField *l4sHint = OpnLabel(@"May reduce latency on compatible paths, but can destabilize streams on some networks. Leave off unless testing.",
                                    NSMakeRect(controlX, 256.0, controlWidth, 34.0),
                                    12.0,
                                    OpnColor(kTextMuted),
                                    NSFontWeightRegular);
    l4sHint.maximumNumberOfLines = 2;
    [network addSubview:l4sHint];
    [self.documentView addSubview:network];

    [self buildWebRTCBackendDiagnosticsContentWithPanelWidth:panelWidth controlX:controlX controlWidth:controlWidth];
}

- (void)buildVideoContent {
    CGFloat panelWidth = MAX(320.0, self.contentAreaWidth > 0 ? self.contentAreaWidth : 720.0);
    CGFloat controlX = [self controlXForPanelWidth:panelWidth];
    CGFloat controlWidth = [self controlWidthForPanelWidth:panelWidth];
    OPN::StreamPreferenceProfile profile = OPN::LoadStreamPreferenceProfile();
    OPN::StreamDeviceCapabilities capabilities = OPN::LoadStreamDeviceCapabilities();
    OPN::StreamPreferenceProfile effectiveProfile = OPN::EffectiveStreamPreferenceProfileForCapabilities(profile, capabilities);
    NSView *video = [self panelWithTitle:@"Video" height:1210.0];
    [video addSubview:[self rowLabel:@"Aspect Ratio" y:112.0]];
    NSMutableArray<NSString *> *aspectTitles = [NSMutableArray array];
    for (const OPN::StreamAspectOption &option : OPN::StreamAspectOptions()) {
        [aspectTitles addObject:[NSString stringWithUTF8String:option.label.c_str()]];
    }
    [self addOptionGroupTo:video group:1 titles:aspectTitles selected:self.selectedAspect y:102.0 widths:@[@86.0, @92.0, @86.0, @86.0]];

    [video addSubview:[self rowLabel:@"Resolution" y:188.0]];
    [video addSubview:[self resolutionPopupWithFrame:NSMakeRect(controlX, 176, controlWidth, 42)]];

    NSMutableArray<NSString *> *fpsTitles = [NSMutableArray array];
    NSMutableArray<NSNumber *> *fpsEnabled = [NSMutableArray array];
    for (int fps : OPN::StreamFpsOptions()) {
        [fpsTitles addObject:[NSString stringWithFormat:@"%d", fps]];
        [fpsEnabled addObject:@(OPN::StreamFpsSupportedByCapabilities(fps, capabilities))];
    }
    [video addSubview:[self rowLabel:@"FPS" y:264.0]];
    [self addOptionGroupTo:video group:3 titles:fpsTitles selected:self.selectedFps y:254.0 widths:@[@62.0, @62.0, @62.0, @62.0] enabled:fpsEnabled];
    NSMutableArray<NSString *> *bitrateTitles = [NSMutableArray array];
    for (const OPN::StreamBitrateOption &option : OPN::StreamBitrateOptions()) {
        [bitrateTitles addObject:[NSString stringWithUTF8String:option.label.c_str()]];
    }
    [video addSubview:[self rowLabel:@"Bitrate" y:340.0]];
    [self addOptionGroupTo:video group:8 titles:bitrateTitles selected:self.selectedBitrate y:330.0 widths:@[@86.0, @86.0, @86.0, @86.0, @94.0]];

    [video addSubview:[self rowLabel:@"Recording Video" y:416.0]];
    NSSlider *recordingVideoSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(controlX, 406.0, controlWidth, 24.0)];
    recordingVideoSlider.minValue = 0.0;
    recordingVideoSlider.maxValue = 200.0;
    recordingVideoSlider.doubleValue = profile.recordingVideoBitrateMbps;
    recordingVideoSlider.numberOfTickMarks = 7;
    recordingVideoSlider.allowsTickMarkValuesOnly = NO;
    recordingVideoSlider.continuous = NO;
    recordingVideoSlider.target = self;
    recordingVideoSlider.action = @selector(recordingVideoBitrateSliderChanged:);
    [video addSubview:recordingVideoSlider];
    NSString *recordingVideoText = profile.recordingVideoBitrateMbps <= 0
        ? @"Auto video bitrate (5-60 Mbps by capture resolution), or choose 5-200 Mbps"
        : [NSString stringWithFormat:@"%d Mbps recording video bitrate", profile.recordingVideoBitrateMbps];
    NSTextField *recordingVideoHint = OpnLabel(recordingVideoText,
                                               NSMakeRect(controlX, 438.0, controlWidth, 22.0),
                                               12.0,
                                               OpnColor(kTextMuted),
                                               NSFontWeightRegular);
    recordingVideoHint.lineBreakMode = NSLineBreakByTruncatingTail;
    [video addSubview:recordingVideoHint];

    [video addSubview:[self rowLabel:@"Recording Audio" y:492.0]];
    NSSlider *recordingAudioSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(controlX, 482.0, controlWidth, 24.0)];
    recordingAudioSlider.minValue = 64.0;
    recordingAudioSlider.maxValue = 320.0;
    recordingAudioSlider.doubleValue = profile.recordingAudioBitrateKbps;
    recordingAudioSlider.numberOfTickMarks = 5;
    recordingAudioSlider.allowsTickMarkValuesOnly = NO;
    recordingAudioSlider.continuous = NO;
    recordingAudioSlider.target = self;
    recordingAudioSlider.action = @selector(recordingAudioBitrateSliderChanged:);
    [video addSubview:recordingAudioSlider];
    NSTextField *recordingAudioHint = OpnLabel([NSString stringWithFormat:@"%d kbps recording audio bitrate", profile.recordingAudioBitrateKbps],
                                               NSMakeRect(controlX, 514.0, controlWidth, 22.0),
                                               12.0,
                                               OpnColor(kTextMuted),
                                               NSFontWeightRegular);
    recordingAudioHint.lineBreakMode = NSLineBreakByTruncatingTail;
    [video addSubview:recordingAudioHint];

    NSMutableArray<NSString *> *codecTitles = [NSMutableArray array];
    NSMutableArray<NSNumber *> *codecEnabled = [NSMutableArray array];
    for (const OPN::StreamCodecOption &option : OPN::StreamCodecOptions()) {
        [codecTitles addObject:[NSString stringWithUTF8String:option.label.c_str()]];
        [codecEnabled addObject:@(OPN::StreamCodecSupportedByCapabilities(option, capabilities))];
    }
    [video addSubview:[self rowLabel:@"Codec" y:568.0]];
    [self addOptionGroupTo:video group:4 titles:codecTitles selected:self.selectedCodec y:558.0 widths:@[@142.0, @116.0, @96.0, @70.0] enabled:codecEnabled];
    NSMutableArray<NSString *> *colorDepthTitles = [NSMutableArray array];
    NSMutableArray<NSNumber *> *colorDepthEnabled = [NSMutableArray array];
    OPN::StreamCodecOption colorCapabilityCodec = OPN::StreamCodecSupportedByCapabilities(profile.codec, capabilities)
        ? profile.codec
        : effectiveProfile.codec;
    for (const OPN::StreamColorQualityOption &option : OPN::StreamColorQualityOptions()) {
        [colorDepthTitles addObject:[NSString stringWithUTF8String:option.label.c_str()]];
        [colorDepthEnabled addObject:@(OPN::StreamColorQualitySupportedByCapabilities(option, colorCapabilityCodec, capabilities))];
    }
    [video addSubview:[self rowLabel:@"Color Depth" y:644.0]];
    [self addOptionGroupTo:video group:7 titles:colorDepthTitles selected:self.selectedColorDepth y:634.0 widths:@[@112.0, @112.0, @124.0, @124.0] enabled:colorDepthEnabled];

    NSButton *hdrToggle = [[NSButton alloc] initWithFrame:NSMakeRect(controlX, 700.0, controlWidth, 28.0)];
    hdrToggle.buttonType = NSButtonTypeSwitch;
    hdrToggle.title = capabilities.hdrDisplaySupported ? @"Request HDR when available" : @"Request HDR when available (display unsupported)";
    hdrToggle.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightMedium];
    hdrToggle.contentTintColor = capabilities.hdrDisplaySupported ? OpnColor(kBrandGreen) : OpnColor(kTextMuted);
    hdrToggle.state = self.enableHdr ? NSControlStateValueOn : NSControlStateValueOff;
    hdrToggle.enabled = capabilities.hdrDisplaySupported;
    hdrToggle.target = self;
    hdrToggle.action = @selector(hdrToggleChanged:);
    [video addSubview:hdrToggle];

    NSString *capabilitySummary = [NSString stringWithFormat:@"Hardware decode: H264 %@ · H265 %@ · AV1 %@. Display: %dx%d%@%@.",
                                   capabilities.h264HardwareDecodeSupported ? @"on" : @"off",
                                   capabilities.h265HardwareDecodeSupported ? @"on" : @"off",
                                   capabilities.av1HardwareDecodeSupported ? @"on" : @"off",
                                   capabilities.maxDisplayWidth,
                                   capabilities.maxDisplayHeight,
                                   capabilities.maxDisplayRefreshRate > 0 ? [NSString stringWithFormat:@" @ %dHz", capabilities.maxDisplayRefreshRate] : @"",
                                   capabilities.hdrDisplaySupported ? @" · HDR display" : @""];
    NSTextField *capabilityLabel = OpnLabel(capabilitySummary,
                                            NSMakeRect(controlX, 746.0, controlWidth, 36.0),
                                            12.0,
                                            OpnColor(kTextMuted),
                                            NSFontWeightRegular);
    capabilityLabel.maximumNumberOfLines = 2;
    [video addSubview:capabilityLabel];

    BOOL willAdjustAtLaunch = profile.codec.value != effectiveProfile.codec.value ||
        profile.fps != effectiveProfile.fps ||
        profile.colorQuality.value != effectiveProfile.colorQuality.value;
    NSString *adjustmentText = willAdjustAtLaunch
        ? [NSString stringWithFormat:@"Saved profile will launch as %@, %dfps, %@ on this Mac.",
           [NSString stringWithUTF8String:effectiveProfile.codec.label.c_str()],
           effectiveProfile.fps,
           [NSString stringWithUTF8String:effectiveProfile.colorQuality.label.c_str()]]
        : @"Unsupported codec, color, and FPS options are disabled to match this Mac's playback capabilities.";
    NSTextField *adjustmentLabel = OpnLabel(adjustmentText,
                                            NSMakeRect(controlX, 792.0, controlWidth, 42.0),
                                            12.0,
                                            willAdjustAtLaunch ? OpnColor(0xFFD166) : OpnColor(kTextMuted),
                                            NSFontWeightRegular);
    adjustmentLabel.maximumNumberOfLines = 2;
    [video addSubview:adjustmentLabel];

    NSMutableArray<NSString *> *upscalingTitles = [NSMutableArray array];
    for (const OPN::StreamUpscalingModeOption &option : OPN::StreamUpscalingModeOptions()) {
        [upscalingTitles addObject:[NSString stringWithUTF8String:option.label.c_str()]];
    }
    [video addSubview:[self rowLabel:@"Resolution Upscaling" y:878.0]];
    [self addOptionGroupTo:video group:12 titles:upscalingTitles selected:self.selectedUpscalingMode y:868.0 widths:@[@64.0, @70.0, @84.0, @84.0]];

    [video addSubview:OpnLabel(@"Local Sharpness", NSMakeRect(controlX, 918.0, 160.0, 18.0), 11.0, OpnColor(kTextMuted), NSFontWeightMedium)];
    NSPopUpButton *upscalingSharpnessPopup = [self integerPopupWithFrame:NSMakeRect(controlX, 938.0, MIN(120.0, controlWidth), 38.0)
                                                                  value:profile.upscalingSharpness
                                                               maxValue:20
                                                                 action:@selector(upscalingSharpnessPopupChanged:)];
    [video addSubview:upscalingSharpnessPopup];

    CGFloat upscalingDenoiseX = controlX + MIN(160.0, controlWidth * 0.5);
    [video addSubview:OpnLabel(@"Local Denoise", NSMakeRect(upscalingDenoiseX, 918.0, 160.0, 18.0), 11.0, OpnColor(kTextMuted), NSFontWeightMedium)];
    NSPopUpButton *upscalingDenoisePopup = [self integerPopupWithFrame:NSMakeRect(upscalingDenoiseX, 938.0, MIN(120.0, controlWidth), 38.0)
                                                                value:profile.upscalingDenoise
                                                              maxValue:10
                                                               action:@selector(upscalingDenoisePopupChanged:)];
    [video addSubview:upscalingDenoisePopup];

    NSTextField *upscalingHint = OpnLabel(@"Auto chooses the best available local tier. Spatial fixes the custom Metal scaler. MetalFX requests Apple's scaler and falls back to Spatial when unavailable.",
                                          NSMakeRect(controlX, 986.0, controlWidth, 42.0),
                                          12.0,
                                          OpnColor(kTextMuted),
                                          NSFontWeightRegular);
    upscalingHint.maximumNumberOfLines = 2;
    [video addSubview:upscalingHint];

    NSMutableArray<NSString *> *prefilterTitles = [NSMutableArray array];
    for (const OPN::StreamPrefilterModeOption &option : OPN::StreamPrefilterModeOptions()) {
        [prefilterTitles addObject:[NSString stringWithUTF8String:option.label.c_str()]];
    }
    [video addSubview:[self rowLabel:@"AI Filter" y:1048.0]];
    [self addOptionGroupTo:video group:10 titles:prefilterTitles selected:self.selectedPrefilterMode y:1038.0 widths:@[@72.0, @72.0, @96.0]];

    [video addSubview:[self rowLabel:@"Custom Levels" y:1104.0]];
    [video addSubview:OpnLabel(@"Sharpness", NSMakeRect(controlX, 1072.0, 120.0, 18.0), 11.0, OpnColor(kTextMuted), NSFontWeightMedium)];
    NSPopUpButton *sharpnessPopup = [self integerPopupWithFrame:NSMakeRect(controlX, 1092.0, MIN(120.0, controlWidth), 38.0)
                                                          value:profile.prefilterSharpness
                                                       maxValue:10
                                                         action:@selector(prefilterSharpnessPopupChanged:)];
    [video addSubview:sharpnessPopup];

    CGFloat denoiseX = controlX + MIN(160.0, controlWidth * 0.5);
    [video addSubview:OpnLabel(@"Denoise", NSMakeRect(denoiseX, 1072.0, 120.0, 18.0), 11.0, OpnColor(kTextMuted), NSFontWeightMedium)];
    NSPopUpButton *denoisePopup = [self integerPopupWithFrame:NSMakeRect(denoiseX, 1092.0, MIN(120.0, controlWidth), 38.0)
                                                        value:profile.prefilterDenoise
                                                     maxValue:10
                                                       action:@selector(prefilterDenoisePopupChanged:)];
    [video addSubview:denoisePopup];

    NSTextField *prefilterHint = OpnLabel(@"Auto lets GFN choose supported enhancement. Custom sends the sharpness and denoise levels from 0 to 10.",
                                           NSMakeRect(controlX, 1158.0, controlWidth, 42.0),
                                          12.0,
                                          OpnColor(kTextMuted),
                                          NSFontWeightRegular);
    prefilterHint.maximumNumberOfLines = 2;
    [video addSubview:prefilterHint];

    [self.documentView addSubview:video];
}

- (void)addInfoRowToPanel:(NSView *)panel
                    title:(NSString *)title
                    value:(NSString *)value
                        y:(CGFloat)y
               valueWidth:(CGFloat)valueWidth
            monospaceValue:(BOOL)monospaceValue {
    [panel addSubview:[self rowLabel:title y:y]];
    NSTextField *valueLabel = OpnLabel(value ?: @"Unavailable",
                                      NSMakeRect([self controlXForPanelWidth:NSWidth(panel.frame)], y - 2.0, valueWidth, 44.0),
                                      12.0,
                                      OpnColor(kTextSecondary),
                                      NSFontWeightRegular);
    valueLabel.maximumNumberOfLines = 2;
    valueLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    if (monospaceValue) {
        valueLabel.font = [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightRegular];
    }
    [panel addSubview:valueLabel];
}

- (void)buildWebRTCBackendDiagnosticsContentWithPanelWidth:(CGFloat)panelWidth controlX:(CGFloat)controlX controlWidth:(CGFloat)controlWidth {
    (void)controlX;
    NSDictionary<NSString *, NSString *> *runtime = OPNWebRTCBackendRuntimeInfo();
    NSView *panel = [self panelWithTitle:@"WebRTC Backend" height:354.0];
    NSTextField *description = OpnLabel(@"OpenNOW streams through libwebrtc only. New sessions fail fast if the libwebrtc framework is unavailable in this build.",
                                         NSMakeRect(24.0, 92.0, MAX(260.0, NSWidth(panel.frame) - 48.0), 38.0),
                                         12.0,
                                         OpnColor(kTextMuted),
                                        NSFontWeightRegular);
    description.maximumNumberOfLines = 2;
    [panel addSubview:description];

    [self addInfoRowToPanel:panel title:@"Status" value:runtime[@"status"] y:146.0 valueWidth:controlWidth monospaceValue:NO];
    [self addInfoRowToPanel:panel title:@"Active" value:runtime[@"effective"] y:198.0 valueWidth:controlWidth monospaceValue:NO];
    [self addInfoRowToPanel:panel title:@"Codec" value:runtime[@"codec"] y:250.0 valueWidth:controlWidth monospaceValue:NO];
    [self addInfoRowToPanel:panel title:@"libwebrtc" value:runtime[@"libwebrtc"] y:302.0 valueWidth:controlWidth monospaceValue:NO];
    [self.documentView addSubview:panel];
}

- (void)buildAudioContent {
    OPN::StreamPreferenceProfile profile = OPN::LoadStreamPreferenceProfile();
    std::vector<OPN::StreamMicrophoneModeOption> modes = OPN::StreamMicrophoneModeOptions();
    std::vector<OPN::StreamMicrophoneDeviceOption> devices = OPN::LoadMicrophoneDeviceOptions();

    BOOL microphoneEnabled = profile.microphoneMode != "disabled";
    CGFloat shortcutY = microphoneEnabled ? 304.0 : 204.0;
    NSView *panel = [self panelWithTitle:@"Audio" height:microphoneEnabled ? 506.0 : 420.0];
    CGFloat panelWidth = MAX(320.0, NSWidth(panel.frame));
    CGFloat controlX = [self controlXForPanelWidth:panelWidth];
    CGFloat controlWidth = [self controlWidthForPanelWidth:panelWidth];

    [panel addSubview:[self rowLabel:@"Microphone" y:104.0]];
    NSPopUpButton *modePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(controlX, 96.0, controlWidth, 38.0) pullsDown:NO];
    modePopup.target = self;
    modePopup.action = @selector(microphoneModePopupChanged:);
    modePopup.bordered = NO;
    modePopup.font = [NSFont systemFontOfSize:14.0 weight:NSFontWeightRegular];
    modePopup.contentTintColor = OpnColor(kTextPrimary);
    modePopup.wantsLayer = YES;
    modePopup.layer.backgroundColor = OpnColor(0x090A0C, 0.72).CGColor;
    modePopup.layer.cornerRadius = 11.0;
    modePopup.layer.borderWidth = 1.0;
    modePopup.layer.borderColor = OpnColor(kPanelBorder, 0.78).CGColor;
    [modePopup removeAllItems];
    NSInteger selectedMode = 0;
    for (size_t i = 0; i < modes.size(); i++) {
        [modePopup addItemWithTitle:[NSString stringWithUTF8String:modes[i].label.c_str()]];
        if (modes[i].value == profile.microphoneMode) selectedMode = (NSInteger)i;
    }
    [modePopup selectItemAtIndex:selectedMode];
    self.selectedMicrophoneMode = selectedMode;
    [panel addSubview:modePopup];

    NSTextField *modeHint = OpnLabel(@"Open Mic is always live. Push-to-Talk only sends audio while the configured shortcut is held.",
                                    NSMakeRect(controlX, 140.0, controlWidth, 38.0),
                                    12.0,
                                    OpnColor(kTextMuted),
                                    NSFontWeightRegular);
    modeHint.maximumNumberOfLines = 2;
    [panel addSubview:modeHint];

    if (microphoneEnabled) {
        [panel addSubview:[self rowLabel:@"Input Device" y:204.0]];
        NSPopUpButton *devicePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(controlX, 196.0, controlWidth, 38.0) pullsDown:NO];
        devicePopup.target = self;
        devicePopup.action = @selector(microphoneDevicePopupChanged:);
        devicePopup.bordered = NO;
        devicePopup.font = [NSFont systemFontOfSize:14.0 weight:NSFontWeightRegular];
        devicePopup.contentTintColor = OpnColor(kTextPrimary);
        devicePopup.wantsLayer = YES;
        devicePopup.layer.backgroundColor = OpnColor(0x090A0C, 0.72).CGColor;
        devicePopup.layer.cornerRadius = 11.0;
        devicePopup.layer.borderWidth = 1.0;
        devicePopup.layer.borderColor = OpnColor(kPanelBorder, 0.78).CGColor;
        [devicePopup removeAllItems];
        NSInteger selectedDevice = 0;
        for (size_t i = 0; i < devices.size(); i++) {
            [devicePopup addItemWithTitle:[NSString stringWithUTF8String:devices[i].label.c_str()]];
            if (devices[i].uniqueId == profile.microphoneDeviceId) selectedDevice = (NSInteger)i;
        }
        [devicePopup selectItemAtIndex:selectedDevice];
        self.selectedMicrophoneDevice = selectedDevice;
        [panel addSubview:devicePopup];

        NSTextField *deviceHint = OpnLabel(@"macOS may ask for microphone permission the first time a stream starts with mic enabled.",
                                          NSMakeRect(controlX, 240.0, controlWidth, 38.0),
                                          12.0,
                                          OpnColor(kTextMuted),
                                          NSFontWeightRegular);
        deviceHint.maximumNumberOfLines = 2;
        [panel addSubview:deviceHint];
    }

    [panel addSubview:[self rowLabel:@"Push-to-Talk" y:shortcutY + 8.0]];
    OPNPushToTalkShortcutField *shortcutField = [[OPNPushToTalkShortcutField alloc] initWithFrame:NSMakeRect(controlX, shortcutY, controlWidth, 38.0)];
    [shortcutField configureWithKeyCode:(uint16_t)profile.microphonePushToTalkKeyCode
                           modifierMask:(uint16_t)profile.microphonePushToTalkModifierMask];
    shortcutField.onShortcutChanged = ^(uint16_t keyCode, uint16_t modifierMask) {
        OPN::SaveStreamMicrophonePushToTalkKeyCode((int)keyCode);
        OPN::SaveStreamMicrophonePushToTalkModifierMask((int)modifierMask);
    };
    [panel addSubview:shortcutField];

    NSTextField *hint = OpnLabel(@"Click the box, hold any modifiers, then press the final key. Used when Microphone is Push-to-Talk and not sent to the game while streaming.",
                                 NSMakeRect(controlX, shortcutY + 52.0, controlWidth, 54.0),
                                 12.0,
                                 OpnColor(kTextMuted),
                                 NSFontWeightRegular);
    hint.maximumNumberOfLines = 3;
    [panel addSubview:hint];

    CGFloat toggleY = shortcutY + 124.0;
    [panel addSubview:[self rowLabel:@"Mic Toggle" y:toggleY + 8.0]];
    NSTextField *toggleShortcut = OpnLabel(@"Command-M",
                                           NSMakeRect(controlX, toggleY, MIN(180.0, controlWidth), 32.0),
                                           13.0,
                                           OpnColor(kTextPrimary),
                                           NSFontWeightSemibold,
                                           NSTextAlignmentCenter);
    toggleShortcut.wantsLayer = YES;
    toggleShortcut.layer.cornerRadius = 10.0;
    toggleShortcut.layer.borderWidth = 1.0;
    toggleShortcut.layer.borderColor = OpnColor(kPanelBorder, 0.78).CGColor;
    toggleShortcut.layer.backgroundColor = OpnColor(kInputBackground, 0.72).CGColor;
    [panel addSubview:toggleShortcut];

    NSTextField *toggleHint = OpnLabel(@"While streaming, press Command-M to mute or re-enable the microphone without changing this saved microphone mode.",
                                       NSMakeRect(controlX, toggleY + 42.0, controlWidth, 38.0),
                                       12.0,
                                       OpnColor(kTextMuted),
                                       NSFontWeightRegular);
    toggleHint.maximumNumberOfLines = 2;
    [panel addSubview:toggleHint];
    [self.documentView addSubview:panel];
}

- (void)buildInputContent {
    OPN::StreamPreferenceProfile profile = OPN::LoadStreamPreferenceProfile();
    self.suppressInputWhenInactive = profile.suppressInputWhenInactive;

    NSView *panel = [self panelWithTitle:@"Input" height:252.0];
    CGFloat panelWidth = MAX(320.0, NSWidth(panel.frame));
    CGFloat controlX = [self controlXForPanelWidth:panelWidth];
    CGFloat controlWidth = [self controlWidthForPanelWidth:panelWidth];

    [panel addSubview:[self rowLabel:@"Window Focus" y:104.0]];
    NSButton *focusToggle = [[NSButton alloc] initWithFrame:NSMakeRect(controlX, 96.0, controlWidth, 28.0)];
    focusToggle.buttonType = NSButtonTypeSwitch;
    focusToggle.title = @"Block game input when OpenNOW is inactive";
    focusToggle.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightMedium];
    focusToggle.contentTintColor = OpnColor(kBrandGreen);
    focusToggle.state = self.suppressInputWhenInactive ? NSControlStateValueOn : NSControlStateValueOff;
    focusToggle.target = self;
    focusToggle.action = @selector(suppressInputWhenInactiveToggleChanged:);
    [panel addSubview:focusToggle];

    NSTextField *hint = OpnLabel(@"When enabled, keyboard, mouse, push-to-talk, and gamepad events are ignored unless the stream window is active.",
                                 NSMakeRect(controlX, 136.0, controlWidth, 54.0),
                                 12.0,
                                 OpnColor(kTextMuted),
                                 NSFontWeightRegular);
    hint.maximumNumberOfLines = 3;
    [panel addSubview:hint];
    [self.documentView addSubview:panel];
}

- (void)buildInterfaceContent {
    OPN::StreamPreferenceProfile profile = OPN::LoadStreamPreferenceProfile();
    self.directMouseInput = profile.directMouseInput;

    NSView *panel = [self panelWithTitle:@"Interface" height:396.0];
    CGFloat panelWidth = MAX(320.0, NSWidth(panel.frame));
    CGFloat controlX = [self controlXForPanelWidth:panelWidth];
    CGFloat controlWidth = [self controlWidthForPanelWidth:panelWidth];

    [panel addSubview:[self rowLabel:@"App Icon" y:104.0]];
    OPNAppIconTheme appIconTheme = OpnAppIconThemePreference();
    NSInteger selectedIconIndex = appIconTheme == OPNAppIconThemeGreen ? 1 : (appIconTheme == OPNAppIconThemeBlue ? 2 : 0);
    [self addOptionGroupTo:panel group:11 titles:@[@"Black", @"GFN Green", @"Sky Blue"] selected:selectedIconIndex y:96.0 widths:@[@82.0, @112.0, @94.0]];
    NSTextField *iconHint = OpnLabel(@"Changes the Dock icon and OpenNOW logo immediately. Black is the default app icon.",
                                     NSMakeRect(controlX, 146.0, controlWidth, 36.0),
                                     12.0,
                                     OpnColor(kTextMuted),
                                     NSFontWeightRegular);
    iconHint.maximumNumberOfLines = 2;
    [panel addSubview:iconHint];

    [panel addSubview:[self rowLabel:@"Direct Mouse Input" y:216.0]];
    NSButton *directMouseToggle = [[NSButton alloc] initWithFrame:NSMakeRect(controlX, 208.0, controlWidth, 28.0)];
    directMouseToggle.buttonType = NSButtonTypeSwitch;
    directMouseToggle.title = @"Use raw relative mouse movement while streaming";
    directMouseToggle.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightMedium];
    directMouseToggle.contentTintColor = OpnColor(kBrandGreen);
    directMouseToggle.state = self.directMouseInput ? NSControlStateValueOn : NSControlStateValueOff;
    directMouseToggle.target = self;
    directMouseToggle.action = @selector(directMouseInputToggleChanged:);
    [panel addSubview:directMouseToggle];

    NSTextField *directMouseHint = OpnLabel(@"Bypasses desktop cursor position and acceleration by locking the pointer and sending hardware-relative deltas to the stream.",
                                            NSMakeRect(controlX, 244.0, controlWidth, 50.0),
                                            12.0,
                                            OpnColor(kTextMuted),
                                            NSFontWeightRegular);
    directMouseHint.maximumNumberOfLines = 3;
    [panel addSubview:directMouseHint];

    [panel addSubview:[self rowLabel:@"Auto Full Screen" y:334.0]];
    NSButton *autoFullScreenToggle = [[NSButton alloc] initWithFrame:NSMakeRect(controlX, 326.0, controlWidth, 28.0)];
    autoFullScreenToggle.buttonType = NSButtonTypeSwitch;
    autoFullScreenToggle.title = @"Enter full screen automatically when a stream starts";
    autoFullScreenToggle.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightMedium];
    autoFullScreenToggle.contentTintColor = OpnColor(kBrandGreen);
    autoFullScreenToggle.state = OpnAutoFullScreenEnabled() ? NSControlStateValueOn : NSControlStateValueOff;
    autoFullScreenToggle.target = self;
    autoFullScreenToggle.action = @selector(autoFullScreenToggleChanged:);
    [panel addSubview:autoFullScreenToggle];

    [self.documentView addSubview:panel];
}

- (void)buildAboutContent {
    NSView *panel = [self panelWithTitle:@"About" height:596.0];
    CGFloat panelWidth = MAX(320.0, NSWidth(panel.frame));
    CGFloat controlX = [self controlXForPanelWidth:panelWidth];
    CGFloat controlWidth = [self controlWidthForPanelWidth:panelWidth];
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSString *version = [info[@"CFBundleShortVersionString"] isKindOfClass:NSString.class] ? info[@"CFBundleShortVersionString"] : @"0.0.0";
    NSString *build = [info[@"CFBundleVersion"] isKindOfClass:NSString.class] ? info[@"CFBundleVersion"] : @"0";
    NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier ?: @"Unavailable";
    NSDictionary<NSString *, NSString *> *enhancements = OPNLocalEnhancementRuntimeInfo();

    NSTextField *summary = OpnLabel(@"OpenNOW is an open-source macOS client for launching and streaming cloud games.",
                                    NSMakeRect(24.0, 92.0, MAX(260.0, panelWidth - 48.0), 38.0),
                                    13.0,
                                    OpnColor(kTextSecondary),
                                    NSFontWeightRegular);
    summary.maximumNumberOfLines = 2;
    [panel addSubview:summary];

    [self addInfoRowToPanel:panel title:@"Version" value:[NSString stringWithFormat:@"%@ (%@)", version, build] y:154.0 valueWidth:controlWidth monospaceValue:NO];
    [self addInfoRowToPanel:panel title:@"Bundle ID" value:bundleIdentifier y:206.0 valueWidth:controlWidth monospaceValue:YES];
    [self addInfoRowToPanel:panel title:@"System GPU" value:enhancements[@"gpu"] y:258.0 valueWidth:controlWidth monospaceValue:NO];

    [panel addSubview:[self rowLabel:@"Compatible Enhancements" y:318.0]];
    NSTextField *enhancementLabel = OpnLabel(enhancements[@"summary"] ?: @"Unavailable",
                                             NSMakeRect(controlX, 316.0, controlWidth, 94.0),
                                             12.0,
                                             OpnColor(kTextSecondary),
                                             NSFontWeightRegular);
    enhancementLabel.maximumNumberOfLines = 4;
    enhancementLabel.lineBreakMode = NSLineBreakByWordWrapping;
    [panel addSubview:enhancementLabel];

    NSButton *updateButton = OpnButton(@"Check for Updates", NSMakeRect(controlX, 434.0, MIN(210.0, controlWidth), 40.0), OpnColor(kBrandGreen, 0.18), OpnColor(kBrandGreen), true, OpnColor(kBrandGreen, 0.45));
    updateButton.target = self;
    updateButton.action = @selector(checkForUpdatesClicked:);
    [panel addSubview:updateButton];

    [self addInfoRowToPanel:panel title:@"Cache" value:@"Catalog data, downloaded artwork, image memory cache, and URL cache" y:492.0 valueWidth:controlWidth monospaceValue:NO];
    NSButton *clearCachesButton = OpnButton(@"Clear All Caches", NSMakeRect(controlX, 532.0, MIN(210.0, controlWidth), 40.0), OpnColor(kErrorRed, 0.14), OpnColor(kErrorRed), true, OpnColor(kErrorRed, 0.42));
    clearCachesButton.target = self;
    clearCachesButton.action = @selector(clearCachesClicked:);
    [panel addSubview:clearCachesButton];

    [self.documentView addSubview:panel];
}

- (void)buildSimpleSectionContent:(NSString *)section {
    NSView *panel = [self panelWithTitle:section height:220.0];
    NSDictionary<NSString *, NSString *> *messages = @{
        @"Input": @"Keyboard, mouse, and gamepad input are detected automatically while streaming.",
        @"Interface": @"OpenNOW adapts spacing as the window resizes.",
        @"About": @"OpenNOW is an open-source macOS client for launching and streaming cloud games.",
        @"Thanks": @"Thanks to the open-source projects and contributors that make this client possible.",
    };
    NSString *message = messages[section] ?: @"Settings are managed automatically for this section.";
    NSTextField *label = OpnLabel(message, NSMakeRect(24, 104, 560, 44), 14.0, OpnColor(kTextSecondary), NSFontWeightRegular);
    label.maximumNumberOfLines = 2;
    [panel addSubview:label];
    [self.documentView addSubview:panel];
}

- (void)checkForUpdatesClicked:(NSButton *)sender {
    (void)sender;
    if (self.onCheckForUpdatesRequested) self.onCheckForUpdatesRequested();
}

- (void)clearCachesClicked:(NSButton *)sender {
    sender.enabled = NO;
    OpnClearImageCaches();
    bool clearedDiskCaches = OPN::GameDataCache::Shared().ClearAllCaches();
    sender.enabled = YES;

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = clearedDiskCaches ? @"Caches Cleared" : @"Some Caches Could Not Be Cleared";
    alert.informativeText = clearedDiskCaches
        ? @"OpenNOW cleared cached catalog data, artwork, decoded images, and URL responses. Restart or refresh the catalog to re-download fresh assets."
        : @"OpenNOW cleared memory caches, but one or more disk cache files could not be removed. Check the logs for details.";
    [alert addButtonWithTitle:@"OK"];
    if (self.window) {
        [alert beginSheetModalForWindow:self.window completionHandler:nil];
    } else {
        [alert runModal];
    }
}

- (NSTextField *)rowLabel:(NSString *)text y:(CGFloat)y {
    return OpnLabel(text, NSMakeRect(24, y, 160, 24), 14.0, OpnColor(kTextSecondary), NSFontWeightMedium);
}

- (CGFloat)controlXForPanelWidth:(CGFloat)panelWidth {
    return panelWidth < 620.0 ? 150.0 : 220.0;
}

- (CGFloat)controlWidthForPanelWidth:(CGFloat)panelWidth {
    CGFloat controlX = [self controlXForPanelWidth:panelWidth];
    return MAX(120.0, panelWidth - controlX - 24.0);
}

- (NSView *)selectField:(NSString *)title detail:(NSString *)detail frame:(NSRect)frame {
    NSView *view = [[OPNSettingsFlippedView alloc] initWithFrame:frame];
    view.wantsLayer = YES;
    view.layer.backgroundColor = OpnColor(0x090A0C, 0.72).CGColor;
    view.layer.cornerRadius = 11.0;
    view.layer.borderWidth = 1.0;
    view.layer.borderColor = OpnColor(kPanelBorder, 0.78).CGColor;
    [view addSubview:OpnLabel(title, NSMakeRect(14, 11, NSWidth(frame) - 138, 20), 14.0, OpnColor(kTextPrimary), NSFontWeightRegular)];
    if (detail.length > 0) {
        NSTextField *detailLabel = OpnLabel(detail, NSMakeRect(NSWidth(frame) - 104, 11, 62, 20), 12.0, OpnColor(kErrorRed), NSFontWeightSemibold, NSTextAlignmentCenter);
        detailLabel.wantsLayer = YES;
        detailLabel.layer.backgroundColor = OpnColor(kErrorRed, 0.12).CGColor;
        detailLabel.layer.cornerRadius = 6.0;
        [view addSubview:detailLabel];
    }
    [view addSubview:OpnLabel(@"v", NSMakeRect(NSWidth(frame) - 30, 10, 16, 20), 13.0, OpnColor(kTextMuted), NSFontWeightRegular, NSTextAlignmentCenter)];
    return view;
}

- (NSPopUpButton *)resolutionPopupWithFrame:(NSRect)frame {
    OPN::StreamPreferenceProfile profile = OPN::LoadStreamPreferenceProfile();
    std::vector<OPN::StreamResolutionOption> resolutions = OPN::StreamResolutionOptionsForAspect(profile.aspectIndex);

    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:frame pullsDown:NO];
    popup.target = self;
    popup.action = @selector(resolutionPopupChanged:);
    popup.bordered = NO;
    popup.font = [NSFont systemFontOfSize:14.0 weight:NSFontWeightRegular];
    popup.contentTintColor = OpnColor(kTextPrimary);
    popup.wantsLayer = YES;
    popup.layer.backgroundColor = OpnColor(0x090A0C, 0.72).CGColor;
    popup.layer.cornerRadius = 11.0;
    popup.layer.borderWidth = 1.0;
    popup.layer.borderColor = OpnColor(kPanelBorder, 0.78).CGColor;
    [popup removeAllItems];
    for (const OPN::StreamResolutionOption &resolution : resolutions) {
        [popup addItemWithTitle:[NSString stringWithUTF8String:resolution.Label().c_str()]];
    }
    if (!resolutions.empty()) {
        [popup selectItemAtIndex:MAX(0, MIN((NSInteger)profile.resolutionIndex, (NSInteger)resolutions.size() - 1))];
    }
    return popup;
}

- (NSPopUpButton *)regionPopupWithFrame:(NSRect)frame {
    std::vector<OPN::StreamRegionOption> regions = OPN::LoadCachedStreamRegions();
    std::string selectedUrl = OPN::LoadSelectedStreamRegionUrl();
    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:frame pullsDown:NO];
    popup.target = self;
    popup.action = @selector(regionPopupChanged:);
    popup.bordered = NO;
    popup.font = [NSFont systemFontOfSize:14.0 weight:NSFontWeightRegular];
    popup.contentTintColor = OpnColor(kTextPrimary);
    popup.wantsLayer = YES;
    popup.layer.backgroundColor = OpnColor(0x090A0C, 0.72).CGColor;
    popup.layer.cornerRadius = 11.0;
    popup.layer.borderWidth = 1.0;
    popup.layer.borderColor = OpnColor(kPanelBorder, 0.78).CGColor;
    [popup removeAllItems];
    [popup addItemWithTitle:@"Automatic (lowest latency)"];
    NSInteger selectedIndex = 0;
    for (size_t i = 0; i < regions.size(); i++) {
        [popup addItemWithTitle:[NSString stringWithUTF8String:regions[i].Label().c_str()]];
        if (!selectedUrl.empty() && regions[i].url == selectedUrl) {
            selectedIndex = (NSInteger)i + 1;
        }
    }
    if (regions.empty()) {
        [popup addItemWithTitle:@"Discovering regions..."];
        [[popup itemAtIndex:1] setEnabled:NO];
    }
    [popup selectItemAtIndex:selectedIndex];
    self.selectedRegion = selectedIndex;
    return popup;
}

- (NSPopUpButton *)integerPopupWithFrame:(NSRect)frame value:(NSInteger)value maxValue:(NSInteger)maxValue action:(SEL)action {
    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:frame pullsDown:NO];
    popup.target = self;
    popup.action = action;
    popup.bordered = NO;
    popup.font = [NSFont systemFontOfSize:14.0 weight:NSFontWeightRegular];
    popup.contentTintColor = OpnColor(kTextPrimary);
    popup.wantsLayer = YES;
    popup.layer.backgroundColor = OpnColor(0x090A0C, 0.72).CGColor;
    popup.layer.cornerRadius = 11.0;
    popup.layer.borderWidth = 1.0;
    popup.layer.borderColor = OpnColor(kPanelBorder, 0.78).CGColor;
    [popup removeAllItems];
    NSInteger clampedMaxValue = MAX(0, maxValue);
    for (NSInteger i = 0; i <= clampedMaxValue; i++) {
        [popup addItemWithTitle:[NSString stringWithFormat:@"%ld", (long)i]];
    }
    NSInteger selected = MAX(0, MIN(value, clampedMaxValue));
    [popup selectItemAtIndex:selected];
    return popup;
}

- (void)addOptionGroupTo:(NSView *)parent
                   group:(NSInteger)group
                  titles:(NSArray<NSString *> *)titles
                selected:(NSInteger)selected
                        y:(CGFloat)y
                    widths:(NSArray<NSNumber *> *)widths {
    [self addOptionGroupTo:parent group:group titles:titles selected:selected y:y widths:widths enabled:nil];
}

- (void)addOptionGroupTo:(NSView *)parent
                   group:(NSInteger)group
                  titles:(NSArray<NSString *> *)titles
                selected:(NSInteger)selected
                       y:(CGFloat)y
                   widths:(NSArray<NSNumber *> *)widths
                  enabled:(NSArray<NSNumber *> *)enabled {
    CGFloat panelWidth = MAX(320.0, NSWidth(parent.frame));
    CGFloat x = [self controlXForPanelWidth:panelWidth];
    CGFloat availableWidth = MAX(80.0, panelWidth - x - 24.0);
    CGFloat requestedWidth = 0;
    for (NSNumber *width in widths) {
        requestedWidth += width.doubleValue;
    }
    requestedWidth += MAX(0, (NSInteger)titles.count - 1) * 8.0;
    CGFloat scale = requestedWidth > availableWidth ? availableWidth / requestedWidth : 1.0;
    for (NSUInteger i = 0; i < titles.count; i++) {
        CGFloat width = MAX(48.0, floor(widths[i].doubleValue * scale));
        NSButton *button = [[NSButton alloc] initWithFrame:NSMakeRect(x, y, width, 38.0)];
        button.title = titles[i];
        button.tag = group * 100 + (NSInteger)i;
        button.target = self;
        button.action = @selector(optionClicked:);
        button.bordered = NO;
        button.wantsLayer = YES;
        BOOL optionEnabled = !enabled || i >= enabled.count || enabled[i].boolValue;
        button.enabled = optionEnabled;
        [self styleOptionButton:button selected:(NSInteger)i == selected enabled:optionEnabled];
        [parent addSubview:button];
        x += width + 8.0;
    }
}

- (void)styleOptionButton:(NSButton *)button selected:(BOOL)selected enabled:(BOOL)enabled {
    button.font = [NSFont systemFontOfSize:13.0 weight:selected ? NSFontWeightSemibold : NSFontWeightRegular];
    button.contentTintColor = enabled ? (selected ? OpnColor(kBrandGreen) : OpnColor(kTextMuted)) : OpnColor(kTextMuted, 0.42);
    button.layer.cornerRadius = 10.0;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = (enabled
                                ? (selected ? OpnColor(kBrandGreen, 0.50) : OpnColor(kPanelBorder, 0.72))
                                : OpnColor(kPanelBorder, 0.34)).CGColor;
    button.layer.backgroundColor = (enabled
                                    ? (selected ? OpnColor(kBrandGreen, 0.16) : OpnColor(kInputBackground, 0.58))
                                    : OpnColor(kInputBackground, 0.26)).CGColor;
}

- (void)styleOptionButton:(NSButton *)button selected:(BOOL)selected {
    [self styleOptionButton:button selected:selected enabled:YES];
}

- (void)optionClicked:(NSButton *)sender {
    NSInteger group = sender.tag / 100;
    NSInteger index = sender.tag % 100;
    switch (group) {
        case 1: OPN::SaveStreamAspectIndex((int)index); break;
        case 3: OPN::SaveStreamFpsIndex((int)index); break;
        case 4: OPN::SaveStreamCodecIndex((int)index); break;
        case 7: OPN::SaveStreamColorQualityIndex((int)index); break;
        case 8: OPN::SaveStreamBitrateIndex((int)index); break;
        case 9: [self applyPerformanceProfile:index]; break;
        case 10: OPN::SaveStreamPrefilterModeIndex((int)index); break;
        case 11: OpnSetAppIconThemePreference(index == 1 ? OPNAppIconThemeGreen : (index == 2 ? OPNAppIconThemeBlue : OPNAppIconThemeBlack)); break;
        case 12: OPN::SaveStreamUpscalingModeIndex((int)index); break;
        default: break;
    }
    OPN::StreamPreferenceProfile profile = OPN::LoadStreamPreferenceProfile();
    self.selectedAspect = profile.aspectIndex;
    self.selectedResolution = profile.resolutionIndex;
    self.selectedFps = profile.fpsIndex;
    self.selectedCodec = profile.codecIndex;
    self.selectedBitrate = profile.bitrateIndex;
    self.selectedColorDepth = profile.colorQualityIndex;
    self.selectedPrefilterMode = profile.prefilterModeIndex;
    self.selectedUpscalingMode = profile.upscalingModeIndex;
    self.enableL4S = profile.enableL4S;
    self.enableHdr = profile.enableHdr;
    [self rebuildContent];
}

- (void)applyPerformanceProfile:(NSInteger)index {
    switch (index) {
        case 0:
            OPN::SaveStreamCodecIndex(0);
            OPN::SaveStreamFpsIndex(1);
            OPN::SaveStreamBitrateIndex(2);
            OPN::SaveStreamPowerSaverEnabled(false);
            OPN::SaveStreamL4SEnabled(false);
            break;
        case 1:
            OPN::SaveStreamCodecIndex(1);
            OPN::SaveStreamFpsIndex(1);
            OPN::SaveStreamBitrateIndex(4);
            OPN::SaveStreamPowerSaverEnabled(false);
            OPN::SaveStreamL4SEnabled(false);
            break;
        case 2:
            break;
        default:
            break;
    }
}

- (void)resolutionPopupChanged:(NSPopUpButton *)sender {
    OPN::SaveStreamResolutionIndex((int)sender.indexOfSelectedItem);
    OPN::StreamPreferenceProfile profile = OPN::LoadStreamPreferenceProfile();
    self.selectedResolution = profile.resolutionIndex;
    [self rebuildContent];
}

- (void)regionPopupChanged:(NSPopUpButton *)sender {
    std::vector<OPN::StreamRegionOption> regions = OPN::LoadCachedStreamRegions();
    NSInteger index = sender.indexOfSelectedItem;
    if (index <= 0) {
        OPN::SaveSelectedStreamRegionUrl("");
    } else {
        size_t regionIndex = (size_t)(index - 1);
        if (regionIndex < regions.size()) {
            OPN::SaveSelectedStreamRegionUrl(regions[regionIndex].url);
        }
    }
    OPN::GameService::Shared().SetStreamingBaseUrl(OPN::LoadSelectedStreamingBaseUrl());
    self.selectedRegion = index;
    [self rebuildContent];
}

- (void)l4sToggleChanged:(NSButton *)sender {
    self.enableL4S = sender.state == NSControlStateValueOn;
    OPN::SaveStreamL4SEnabled(self.enableL4S);
    [self rebuildContent];
}

- (void)hdrToggleChanged:(NSButton *)sender {
    self.enableHdr = sender.state == NSControlStateValueOn;
    OPN::SaveStreamHDREnabled(self.enableHdr);
    [self rebuildContent];
}

- (void)prefilterSharpnessPopupChanged:(NSPopUpButton *)sender {
    OPN::SaveStreamPrefilterSharpness((int)sender.indexOfSelectedItem);
    [self rebuildContent];
}

- (void)prefilterDenoisePopupChanged:(NSPopUpButton *)sender {
    OPN::SaveStreamPrefilterDenoise((int)sender.indexOfSelectedItem);
    [self rebuildContent];
}

- (void)upscalingSharpnessPopupChanged:(NSPopUpButton *)sender {
    OPN::SaveStreamUpscalingSharpness((int)sender.indexOfSelectedItem);
    [self rebuildContent];
}

- (void)upscalingDenoisePopupChanged:(NSPopUpButton *)sender {
    OPN::SaveStreamUpscalingDenoise((int)sender.indexOfSelectedItem);
    [self rebuildContent];
}

- (void)recordingVideoBitrateSliderChanged:(NSSlider *)sender {
    int bitrateMbps = (int)std::llround(sender.doubleValue);
    if (bitrateMbps > 0) bitrateMbps = std::max(5, bitrateMbps);
    OPN::SaveStreamRecordingVideoBitrateMbps(bitrateMbps);
    [self rebuildContent];
}

- (void)recordingAudioBitrateSliderChanged:(NSSlider *)sender {
    OPN::SaveStreamRecordingAudioBitrateKbps((int)std::llround(sender.doubleValue));
    [self rebuildContent];
}

- (void)suppressInputWhenInactiveToggleChanged:(NSButton *)sender {
    self.suppressInputWhenInactive = sender.state == NSControlStateValueOn;
    OPN::SaveStreamSuppressInputWhenInactive(self.suppressInputWhenInactive);
    [self rebuildContent];
}

- (void)directMouseInputToggleChanged:(NSButton *)sender {
    self.directMouseInput = sender.state == NSControlStateValueOn;
    OPN::SaveStreamDirectMouseInputEnabled(self.directMouseInput);
    [self rebuildContent];
}

- (void)autoFullScreenToggleChanged:(NSButton *)sender {
    OpnSetAutoFullScreenEnabled(sender.state == NSControlStateValueOn);
}

- (void)microphoneModePopupChanged:(NSPopUpButton *)sender {
    std::vector<OPN::StreamMicrophoneModeOption> modes = OPN::StreamMicrophoneModeOptions();
    NSInteger index = MAX(0, MIN(sender.indexOfSelectedItem, (NSInteger)modes.size() - 1));
    if (!modes.empty()) {
        OPN::SaveStreamMicrophoneMode(modes[(size_t)index].value);
    }
    self.selectedMicrophoneMode = index;
    [self rebuildContent];
}

- (void)microphoneDevicePopupChanged:(NSPopUpButton *)sender {
    std::vector<OPN::StreamMicrophoneDeviceOption> devices = OPN::LoadMicrophoneDeviceOptions();
    NSInteger index = MAX(0, MIN(sender.indexOfSelectedItem, (NSInteger)devices.size() - 1));
    if (!devices.empty()) {
        OPN::SaveStreamMicrophoneDeviceId(devices[(size_t)index].uniqueId);
    }
    self.selectedMicrophoneDevice = index;
    [self rebuildContent];
}

@end
