#include "OPNStreamView.h"
#import "OPNStreamRecordingManager.h"
#import "OPNStreamViewPreferences.h"

#import <GameController/GameController.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>

#include <math.h>
#include <stdbool.h>
#include <string.h>

@interface OPNLogCapture : NSObject
+ (void)appendEvent:(NSString *)message;
@end

static const uint8_t OPN_MOUSE_LEFT = 1;
static const uint8_t OPN_MOUSE_MIDDLE = 2;
static const uint8_t OPN_MOUSE_RIGHT = 3;
static const uint8_t OPN_MOUSE_BACK = 4;
static const uint8_t OPN_MOUSE_FORWARD = 5;

static const uint16_t OPN_GAMEPAD_DPAD_UP = 0x0001;
static const uint16_t OPN_GAMEPAD_DPAD_DOWN = 0x0002;
static const uint16_t OPN_GAMEPAD_DPAD_LEFT = 0x0004;
static const uint16_t OPN_GAMEPAD_DPAD_RIGHT = 0x0008;
static const uint16_t OPN_GAMEPAD_START = 0x0010;
static const uint16_t OPN_GAMEPAD_BACK = 0x0020;
static const uint16_t OPN_GAMEPAD_LS = 0x0040;
static const uint16_t OPN_GAMEPAD_RS = 0x0080;
static const uint16_t OPN_GAMEPAD_LB = 0x0100;
static const uint16_t OPN_GAMEPAD_RB = 0x0200;
static const uint16_t OPN_GAMEPAD_A = 0x1000;
static const uint16_t OPN_GAMEPAD_B = 0x2000;
static const uint16_t OPN_GAMEPAD_X = 0x4000;
static const uint16_t OPN_GAMEPAD_Y = 0x8000;
enum { OPN_GAMEPAD_MAX_CONTROLLERS = 4 };
static const double OPN_GAMEPAD_DEADZONE = 0.15;

typedef struct {
    uint16_t vk;
    uint16_t scancode;
} OPNStreamKeyMapping;

typedef struct {
    uint16_t controllerId;
    uint16_t buttons;
    uint8_t leftTrigger;
    uint8_t rightTrigger;
    int16_t leftStickX;
    int16_t leftStickY;
    int16_t rightStickX;
    int16_t rightStickY;
    bool connected;
    uint64_t timestampUs;
} OPNStreamGamepadState;

typedef struct {
    bool known;
    OPNStreamGamepadState state;
} OPNPadSnapshot;

static uint16_t OPNPushToTalkModifierFlags(NSEvent *event);
static NSString *OPNClipboardString(void);

static void OPNStreamViewLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void OPNStreamViewLog(NSString *format, ...) {
    if (format.length == 0) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    [OPNLogCapture appendEvent:message];
}

static uint64_t OPNStreamInputTimestampUs() {
    static CFTimeInterval start = 0;
    if (start == 0) start = CACurrentMediaTime();
    CFTimeInterval elapsed = CACurrentMediaTime() - start;
    return (uint64_t)llround(elapsed * 1000000.0);
}

static bool OPNMapMacKeyCode(uint16_t key, OPNStreamKeyMapping *mapping) {
    if (!mapping) return false;
    switch (key) {
        case 0: *mapping = (OPNStreamKeyMapping){0x41, 0x001e}; return true;
        case 1: *mapping = (OPNStreamKeyMapping){0x53, 0x001f}; return true;
        case 2: *mapping = (OPNStreamKeyMapping){0x44, 0x0020}; return true;
        case 3: *mapping = (OPNStreamKeyMapping){0x46, 0x0021}; return true;
        case 4: *mapping = (OPNStreamKeyMapping){0x48, 0x0023}; return true;
        case 5: *mapping = (OPNStreamKeyMapping){0x47, 0x0022}; return true;
        case 6: *mapping = (OPNStreamKeyMapping){0x5a, 0x002c}; return true;
        case 7: *mapping = (OPNStreamKeyMapping){0x58, 0x002d}; return true;
        case 8: *mapping = (OPNStreamKeyMapping){0x43, 0x002e}; return true;
        case 9: *mapping = (OPNStreamKeyMapping){0x56, 0x002f}; return true;
        case 11: *mapping = (OPNStreamKeyMapping){0x42, 0x0030}; return true;
        case 12: *mapping = (OPNStreamKeyMapping){0x51, 0x0010}; return true;
        case 13: *mapping = (OPNStreamKeyMapping){0x57, 0x0011}; return true;
        case 14: *mapping = (OPNStreamKeyMapping){0x45, 0x0012}; return true;
        case 15: *mapping = (OPNStreamKeyMapping){0x52, 0x0013}; return true;
        case 16: *mapping = (OPNStreamKeyMapping){0x59, 0x0015}; return true;
        case 17: *mapping = (OPNStreamKeyMapping){0x54, 0x0014}; return true;
        case 18: *mapping = (OPNStreamKeyMapping){0x31, 0x0002}; return true;
        case 19: *mapping = (OPNStreamKeyMapping){0x32, 0x0003}; return true;
        case 20: *mapping = (OPNStreamKeyMapping){0x33, 0x0004}; return true;
        case 21: *mapping = (OPNStreamKeyMapping){0x34, 0x0005}; return true;
        case 22: *mapping = (OPNStreamKeyMapping){0x36, 0x0007}; return true;
        case 23: *mapping = (OPNStreamKeyMapping){0x35, 0x0006}; return true;
        case 24: *mapping = (OPNStreamKeyMapping){0xbb, 0x000d}; return true;
        case 25: *mapping = (OPNStreamKeyMapping){0x39, 0x000a}; return true;
        case 26: *mapping = (OPNStreamKeyMapping){0x37, 0x0008}; return true;
        case 27: *mapping = (OPNStreamKeyMapping){0xbd, 0x000c}; return true;
        case 28: *mapping = (OPNStreamKeyMapping){0x38, 0x0009}; return true;
        case 29: *mapping = (OPNStreamKeyMapping){0x30, 0x000b}; return true;
        case 30: *mapping = (OPNStreamKeyMapping){0xdd, 0x001b}; return true;
        case 31: *mapping = (OPNStreamKeyMapping){0x4f, 0x0018}; return true;
        case 32: *mapping = (OPNStreamKeyMapping){0x55, 0x0016}; return true;
        case 33: *mapping = (OPNStreamKeyMapping){0xdb, 0x001a}; return true;
        case 34: *mapping = (OPNStreamKeyMapping){0x49, 0x0017}; return true;
        case 35: *mapping = (OPNStreamKeyMapping){0x50, 0x0019}; return true;
        case 36: *mapping = (OPNStreamKeyMapping){0x0d, 0x001c}; return true;
        case 37: *mapping = (OPNStreamKeyMapping){0x4c, 0x0026}; return true;
        case 38: *mapping = (OPNStreamKeyMapping){0x4a, 0x0024}; return true;
        case 39: *mapping = (OPNStreamKeyMapping){0xde, 0x0028}; return true;
        case 40: *mapping = (OPNStreamKeyMapping){0x4b, 0x0025}; return true;
        case 41: *mapping = (OPNStreamKeyMapping){0xba, 0x0027}; return true;
        case 42: *mapping = (OPNStreamKeyMapping){0xdc, 0x002b}; return true;
        case 43: *mapping = (OPNStreamKeyMapping){0xbc, 0x0033}; return true;
        case 44: *mapping = (OPNStreamKeyMapping){0xbf, 0x0035}; return true;
        case 45: *mapping = (OPNStreamKeyMapping){0x4e, 0x0031}; return true;
        case 46: *mapping = (OPNStreamKeyMapping){0x4d, 0x0032}; return true;
        case 47: *mapping = (OPNStreamKeyMapping){0xbe, 0x0034}; return true;
        case 48: *mapping = (OPNStreamKeyMapping){0x09, 0x000f}; return true;
        case 49: *mapping = (OPNStreamKeyMapping){0x20, 0x0039}; return true;
        case 50: *mapping = (OPNStreamKeyMapping){0xc0, 0x0029}; return true;
        case 51: *mapping = (OPNStreamKeyMapping){0x08, 0x000e}; return true;
        case 53: *mapping = (OPNStreamKeyMapping){0x1b, 0x0001}; return true;
        case 55: *mapping = (OPNStreamKeyMapping){0x5b, 0xe05b}; return true;
        case 56: *mapping = (OPNStreamKeyMapping){0xa0, 0x002a}; return true;
        case 57: *mapping = (OPNStreamKeyMapping){0x14, 0x003a}; return true;
        case 58: *mapping = (OPNStreamKeyMapping){0xa4, 0x0038}; return true;
        case 59: *mapping = (OPNStreamKeyMapping){0xa2, 0x001d}; return true;
        case 60: *mapping = (OPNStreamKeyMapping){0xa1, 0x0036}; return true;
        case 61: *mapping = (OPNStreamKeyMapping){0xa5, 0xe038}; return true;
        case 62: *mapping = (OPNStreamKeyMapping){0xa3, 0xe01d}; return true;
        case 65: *mapping = (OPNStreamKeyMapping){0x6e, 0x0053}; return true;
        case 67: *mapping = (OPNStreamKeyMapping){0x6a, 0x0037}; return true;
        case 69: *mapping = (OPNStreamKeyMapping){0x6b, 0x004e}; return true;
        case 71: *mapping = (OPNStreamKeyMapping){0x90, 0xe045}; return true;
        case 75: *mapping = (OPNStreamKeyMapping){0x6f, 0xe035}; return true;
        case 76: *mapping = (OPNStreamKeyMapping){0x0d, 0xe01c}; return true;
        case 78: *mapping = (OPNStreamKeyMapping){0x6d, 0x004a}; return true;
        case 81: *mapping = (OPNStreamKeyMapping){0xbb, 0x0059}; return true;
        case 82: *mapping = (OPNStreamKeyMapping){0x60, 0x0052}; return true;
        case 83: *mapping = (OPNStreamKeyMapping){0x61, 0x004f}; return true;
        case 84: *mapping = (OPNStreamKeyMapping){0x62, 0x0050}; return true;
        case 85: *mapping = (OPNStreamKeyMapping){0x63, 0x0051}; return true;
        case 86: *mapping = (OPNStreamKeyMapping){0x64, 0x004b}; return true;
        case 87: *mapping = (OPNStreamKeyMapping){0x65, 0x004c}; return true;
        case 88: *mapping = (OPNStreamKeyMapping){0x66, 0x004d}; return true;
        case 89: *mapping = (OPNStreamKeyMapping){0x67, 0x0047}; return true;
        case 91: *mapping = (OPNStreamKeyMapping){0x68, 0x0048}; return true;
        case 92: *mapping = (OPNStreamKeyMapping){0x69, 0x0049}; return true;
        case 96: *mapping = (OPNStreamKeyMapping){0x74, 0x003f}; return true;
        case 97: *mapping = (OPNStreamKeyMapping){0x75, 0x0040}; return true;
        case 98: *mapping = (OPNStreamKeyMapping){0x76, 0x0041}; return true;
        case 99: *mapping = (OPNStreamKeyMapping){0x72, 0x003d}; return true;
        case 100: *mapping = (OPNStreamKeyMapping){0x77, 0x0042}; return true;
        case 101: *mapping = (OPNStreamKeyMapping){0x78, 0x0043}; return true;
        case 103: *mapping = (OPNStreamKeyMapping){0x7a, 0x0057}; return true;
        case 105: *mapping = (OPNStreamKeyMapping){0x7c, 0x0064}; return true;
        case 106: *mapping = (OPNStreamKeyMapping){0x7f, 0x0067}; return true;
        case 107: *mapping = (OPNStreamKeyMapping){0x7d, 0x0065}; return true;
        case 109: *mapping = (OPNStreamKeyMapping){0x79, 0x0044}; return true;
        case 111: *mapping = (OPNStreamKeyMapping){0x7b, 0x0058}; return true;
        case 113: *mapping = (OPNStreamKeyMapping){0x7e, 0x0066}; return true;
        case 114: *mapping = (OPNStreamKeyMapping){0x2d, 0xe052}; return true;
        case 115: *mapping = (OPNStreamKeyMapping){0x24, 0xe047}; return true;
        case 116: *mapping = (OPNStreamKeyMapping){0x21, 0xe049}; return true;
        case 117: *mapping = (OPNStreamKeyMapping){0x2e, 0xe053}; return true;
        case 118: *mapping = (OPNStreamKeyMapping){0x73, 0x003e}; return true;
        case 119: *mapping = (OPNStreamKeyMapping){0x23, 0xe04f}; return true;
        case 120: *mapping = (OPNStreamKeyMapping){0x71, 0x003c}; return true;
        case 121: *mapping = (OPNStreamKeyMapping){0x22, 0xe051}; return true;
        case 122: *mapping = (OPNStreamKeyMapping){0x70, 0x003b}; return true;
        case 123: *mapping = (OPNStreamKeyMapping){0x25, 0xe04b}; return true;
        case 124: *mapping = (OPNStreamKeyMapping){0x27, 0xe04d}; return true;
        case 125: *mapping = (OPNStreamKeyMapping){0x28, 0xe050}; return true;
        case 126: *mapping = (OPNStreamKeyMapping){0x26, 0xe048}; return true;
        default: return false;
    }
}

static void OPNApplyRadialDeadzone(double x, double y, double *outX, double *outY) {
    double magnitude = sqrt(x * x + y * y);
    if (magnitude < OPN_GAMEPAD_DEADZONE) {
        *outX = 0;
        *outY = 0;
        return;
    }
    double scaled = fmin(1.0, (magnitude - OPN_GAMEPAD_DEADZONE) / (1.0 - OPN_GAMEPAD_DEADZONE));
    *outX = (x / magnitude) * scaled;
    *outY = (y / magnitude) * scaled;
}

static int16_t OPNNormalizeAxisToInt16(double value) {
    value = fmax(-1.0, fmin(1.0, value));
    return (int16_t)fmax(-32768.0, fmin(32767.0, round(value * 32767.0)));
}

static uint8_t OPNNormalizeTriggerToUint8(double value) {
    value = fmax(0.0, fmin(1.0, value));
    return (uint8_t)fmax(0.0, fmin(255.0, round(value * 255.0)));
}

static NSString *OPNFormatSidebarPlaytimeSeconds(NSTimeInterval seconds) {
    NSInteger totalSeconds = MAX(0, (NSInteger)ceil(seconds));
    NSInteger hours = totalSeconds / 3600;
    NSInteger minutes = (totalSeconds % 3600) / 60;
    NSInteger secs = totalSeconds % 60;
    if (hours > 0) return [NSString stringWithFormat:@"%ldh %02ldm", (long)hours, (long)minutes];
    return [NSString stringWithFormat:@"%ldm %02lds", (long)minutes, (long)secs];
}

@interface OPNVideoSurfaceView : NSView
@end

@interface OPNStreamView () {
    void *_attachedPipeline;
    BOOL _streamActive;
    dispatch_source_t _gamepadTimer;
    dispatch_source_t _escapeHoldTimer;
    BOOL _cursorCaptured;
    BOOL _cursorHidden;
    uint8_t _mouseButtonsDown;
    uint16_t _gamepadBitmap;
    BOOL _modifierDown[128];
    NSString *_microphoneMode;
    uint16_t _pushToTalkKeyCode;
    uint16_t _pushToTalkModifierMask;
    BOOL _pushToTalkPrimaryKeyDown;
    BOOL _pushToTalkMicEnabled;
    BOOL _microphoneShortcutEnabled;
    BOOL _suppressInputWhenWindowInactive;
    BOOL _streamInputSuppressed;
    BOOL _directMouseInputEnabled;
    BOOL _sidebarOpen;
    double _gameVolume;
    double _microphoneVolumeLevel;
    double _microphoneLevel;
    double _pendingMouseDx;
    double _pendingMouseDy;
    int _maxBitrateMbps;
    NSInteger _videoUpscalingMode;
    NSInteger _videoUpscalingTargetHeight;
    NSInteger _videoUpscalingSharpness;
    NSInteger _videoUpscalingDenoise;
    NSInteger _videoStreamWidth;
    NSInteger _videoStreamHeight;
    BOOL _recordingEnhancedVideoEnabled;
    NSTimeInterval _remainingPlaytimeBaseSeconds;
    CFTimeInterval _remainingPlaytimeStartTime;
    BOOL _remainingPlaytimeUnlimited;
    BOOL _remainingPlaytimeAvailable;
    OPNPadSnapshot _previousPads[OPN_GAMEPAD_MAX_CONTROLLERS];
    CFTimeInterval _startButtonHoldBegan[OPN_GAMEPAD_MAX_CONTROLLERS];
    BOOL _startButtonHoldConsumed[OPN_GAMEPAD_MAX_CONTROLLERS];
    CFTimeInterval _lastGamepadSend[OPN_GAMEPAD_MAX_CONTROLLERS];
}
@property (nonatomic, strong) OPNVideoSurfaceView *videoSurface;
@property (nonatomic, strong) NSView *microphoneActiveOverlay;
@property (nonatomic, strong) NSView *sidebarHUD;
@property (nonatomic, strong) NSTextField *sidebarMicStatusValue;
@property (nonatomic, strong) NSTextField *sidebarPlaytimeValue;
@property (nonatomic, strong) NSTextField *sidebarRecordingStatusValue;
@property (nonatomic, strong) NSTimer *playtimeTimer;
@property (nonatomic, strong) NSPopUpButton *upscalingModePopup;
@property (nonatomic, strong) NSSlider *upscalingSharpnessSlider;
@property (nonatomic, strong) NSSlider *upscalingDenoiseSlider;
@property (nonatomic, strong) NSSlider *gameVolumeSlider;
@property (nonatomic, strong) NSSlider *microphoneVolumeSlider;
@property (nonatomic, strong) NSView *microphoneMeterTrack;
@property (nonatomic, strong) CALayer *microphoneMeterFill;
@property (nonatomic, strong) NSButton *recordingButton;
@property (nonatomic, strong) OPNStreamRecordingManager *recordingManager;
@property (nonatomic, copy) NSString *recordingGameTitle;
@property (nonatomic, assign) CGFloat videoAspectRatio;
- (void)updateEnhancedVideoRecordingPreference;
- (void)setMicrophoneLevel:(double)level;
@end

@implementation OPNStreamView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _attachedPipeline = NULL;
        _streamActive = NO;
        _gamepadTimer = nil;
        _escapeHoldTimer = nil;
        _cursorCaptured = NO;
        _cursorHidden = NO;
        _mouseButtonsDown = 0;
        _gamepadBitmap = 0;
        memset(_modifierDown, 0, sizeof(_modifierDown));
        _microphoneMode = @"disabled";
        _pushToTalkKeyCode = 9;
        _pushToTalkModifierMask = 0;
        _pushToTalkPrimaryKeyDown = NO;
        _pushToTalkMicEnabled = NO;
        _microphoneShortcutEnabled = YES;
        _suppressInputWhenWindowInactive = YES;
        _streamInputSuppressed = NO;
        _directMouseInputEnabled = YES;
        _sidebarOpen = NO;
        OPNStreamViewPreferenceSnapshot *profile = [OPNStreamViewPreferences loadViewPreferenceSnapshot];
        _directMouseInputEnabled = profile.directMouseInput ? YES : NO;
        _microphoneShortcutEnabled = profile.microphoneShortcutEnabled ? YES : NO;
        _gameVolume = profile.gameVolume;
        _microphoneVolumeLevel = profile.microphoneVolume;
        _maxBitrateMbps = (int)profile.maxBitrateMbps;
        _videoUpscalingMode = profile.lowLatencyMode ? 0 : profile.upscalingMode;
        _videoUpscalingTargetHeight = profile.upscalingTargetHeight;
        _videoUpscalingSharpness = profile.upscalingSharpness;
        _videoUpscalingDenoise = profile.upscalingDenoise;
        _videoStreamWidth = profile.streamWidth;
        _videoStreamHeight = profile.streamHeight;
        _recordingEnhancedVideoEnabled = profile.lowLatencyMode ? NO : (profile.recordingEnhancedVideoEnabled ? YES : NO);
        _remainingPlaytimeBaseSeconds = 0.0;
        _remainingPlaytimeStartTime = 0.0;
        _remainingPlaytimeUnlimited = NO;
        _remainingPlaytimeAvailable = NO;
        _microphoneLevel = 0.0;
        _pendingMouseDx = 0;
        _pendingMouseDy = 0;
        _videoAspectRatio = 16.0 / 9.0;
        _recordingGameTitle = @"Stream";
        _recordingManager = [[OPNStreamRecordingManager alloc] init];
        __weak OPNStreamView *weakSelf = self;
        _recordingManager.onStateChanged = ^{
            OPNStreamView *strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf updateEnhancedVideoRecordingPreference];
            [strongSelf updateRecordingControls];
        };
        self.wantsLayer = YES;
        self.layer.backgroundColor = [NSColor blackColor].CGColor;
        _videoSurface = [[OPNVideoSurfaceView alloc] initWithFrame:self.bounds];
        _videoSurface.wantsLayer = YES;
        _videoSurface.layer.backgroundColor = [NSColor blackColor].CGColor;
        [self applyVideoUpscalingFiltersToView:_videoSurface];
        [self addSubview:_videoSurface];
        [self createMicrophoneActiveOverlay];
        [self createSidebarHUDWithProfile:profile];
        [self registerForControllerNotifications];
    }
    return self;
}

static NSTextField *OPNSidebarLabel(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color, NSTextAlignment alignment) {
    NSTextField *label = [[NSTextField alloc] initWithFrame:NSZeroRect];
    label.stringValue = text ?: @"";
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.textColor = color ?: NSColor.whiteColor;
    label.alignment = alignment;
    label.drawsBackground = NO;
    label.bordered = NO;
    label.editable = NO;
    label.selectable = NO;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

static NSColor *OPNSidebarColor(CGFloat white, CGFloat alpha) {
    return [NSColor colorWithCalibratedWhite:white alpha:alpha];
}

static NSView *OPNSidebarSection(NSRect frame, CGFloat alpha) {
    NSView *section = [[NSView alloc] initWithFrame:frame];
    section.wantsLayer = YES;
    section.layer.cornerRadius = 14.0;
    section.layer.backgroundColor = [NSColor colorWithCalibratedWhite:1.0 alpha:alpha].CGColor;
    section.layer.borderWidth = 1.0;
    section.layer.borderColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.08].CGColor;
    return section;
}

static NSView *OPNSidebarSeparator(CGFloat x, CGFloat y, CGFloat width) {
    NSView *separator = [[NSView alloc] initWithFrame:NSMakeRect(x, y, width, 1.0)];
    separator.wantsLayer = YES;
    separator.layer.backgroundColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.10].CGColor;
    return separator;
}

- (void)addSidebarRowTo:(NSView *)panel title:(NSString *)title value:(NSTextField *)value y:(CGFloat)y {
    NSTextField *label = OPNSidebarLabel(title, 11.0, NSFontWeightMedium, OPNSidebarColor(0.72, 1.0), NSTextAlignmentLeft);
    label.frame = NSMakeRect(20.0, y, 120.0, 18.0);
    value.frame = NSMakeRect(128.0, y, NSWidth(panel.frame) - 148.0, 18.0);
    [panel addSubview:label];
    [panel addSubview:value];
}

- (NSSlider *)sidebarSliderWithValue:(double)value action:(SEL)action y:(CGFloat)y panel:(NSView *)panel {
    NSSlider *slider = [[NSSlider alloc] initWithFrame:NSMakeRect(20.0, y, NSWidth(panel.frame) - 40.0, 22.0)];
    slider.minValue = 0.0;
    slider.maxValue = 100.0;
    slider.doubleValue = fmax(0.0, fmin(value, 1.0)) * 100.0;
    slider.target = self;
    slider.action = action;
    slider.continuous = YES;
    [panel addSubview:slider];
    return slider;
}

- (void)createSidebarHUDWithProfile:(OPNStreamViewPreferenceSnapshot *)profile {
    NSView *panel = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 332.0, 660.0)];
    panel.wantsLayer = YES;
    panel.layer.cornerRadius = 18.0;
    panel.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.03 alpha:0.88].CGColor;
    panel.layer.borderWidth = 1.0;
    panel.layer.borderColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.12].CGColor;
    panel.hidden = YES;

    NSButton *close = [[NSButton alloc] initWithFrame:NSMakeRect(NSWidth(panel.frame) - 48.0, 14.0, 30.0, 30.0)];
    close.title = @"x";
    close.bordered = NO;
    close.target = self;
    close.action = @selector(closeSidebarHUDClicked:);
    close.contentTintColor = NSColor.whiteColor;
    [panel addSubview:close];

    [panel addSubview:OPNSidebarSection(NSMakeRect(12.0, 56.0, NSWidth(panel.frame) - 24.0, 76.0), 0.045)];
    [panel addSubview:OPNSidebarSection(NSMakeRect(12.0, 144.0, NSWidth(panel.frame) - 24.0, 200.0), 0.060)];
    [panel addSubview:OPNSidebarSection(NSMakeRect(12.0, 356.0, NSWidth(panel.frame) - 24.0, 152.0), 0.045)];
    [panel addSubview:OPNSidebarSection(NSMakeRect(12.0, 520.0, NSWidth(panel.frame) - 24.0, 120.0), 0.060)];

    self.sidebarPlaytimeValue = OPNSidebarLabel(@"--", 12.0, NSFontWeightSemibold, NSColor.whiteColor, NSTextAlignmentRight);
    [self addSidebarRowTo:panel title:@"Playtime" value:self.sidebarPlaytimeValue y:66.0];

    [panel addSubview:OPNSidebarSeparator(20.0, 94.0, NSWidth(panel.frame) - 40.0)];

    self.sidebarMicStatusValue = OPNSidebarLabel(@"--", 12.0, NSFontWeightSemibold, NSColor.whiteColor, NSTextAlignmentRight);
    [self addSidebarRowTo:panel title:@"Mic" value:self.sidebarMicStatusValue y:104.0];

    [panel addSubview:OPNSidebarLabel(@"Resolution Upscaling", 12.0, NSFontWeightMedium, OPNSidebarColor(0.82, 1.0), NSTextAlignmentLeft)];
    panel.subviews.lastObject.frame = NSMakeRect(20.0, 150.0, 190.0, 18.0);
    self.upscalingModePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(20.0, 176.0, NSWidth(panel.frame) - 40.0, 30.0) pullsDown:NO];
    NSArray<NSString *> *upscalingLabels = [OPNStreamViewPreferences upscalingModeLabels];
    for (NSString *label in upscalingLabels) {
        [self.upscalingModePopup addItemWithTitle:label];
    }
    [self.upscalingModePopup selectItemAtIndex:MAX(0, MIN((NSInteger)profile.upscalingModeIndex, (NSInteger)upscalingLabels.count - 1))];
    self.upscalingModePopup.target = self;
    self.upscalingModePopup.action = @selector(upscalingModePopupChanged:);
    [panel addSubview:self.upscalingModePopup];

    [panel addSubview:OPNSidebarSeparator(20.0, 216.0, NSWidth(panel.frame) - 40.0)];

    [panel addSubview:OPNSidebarLabel(@"Local Sharpness", 12.0, NSFontWeightMedium, OPNSidebarColor(0.82, 1.0), NSTextAlignmentLeft)];
    panel.subviews.lastObject.frame = NSMakeRect(20.0, 228.0, 190.0, 18.0);
    self.upscalingSharpnessSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(20.0, 252.0, NSWidth(panel.frame) - 40.0, 22.0)];
    self.upscalingSharpnessSlider.minValue = 0.0;
    self.upscalingSharpnessSlider.maxValue = 40.0;
    self.upscalingSharpnessSlider.doubleValue = profile.upscalingSharpness;
    self.upscalingSharpnessSlider.numberOfTickMarks = 41;
    self.upscalingSharpnessSlider.allowsTickMarkValuesOnly = YES;
    self.upscalingSharpnessSlider.target = self;
    self.upscalingSharpnessSlider.action = @selector(upscalingSharpnessSliderChanged:);
    self.upscalingSharpnessSlider.continuous = YES;
    [panel addSubview:self.upscalingSharpnessSlider];

    [panel addSubview:OPNSidebarSeparator(20.0, 282.0, NSWidth(panel.frame) - 40.0)];

    [panel addSubview:OPNSidebarLabel(@"Denoise", 12.0, NSFontWeightMedium, OPNSidebarColor(0.82, 1.0), NSTextAlignmentLeft)];
    panel.subviews.lastObject.frame = NSMakeRect(20.0, 294.0, 190.0, 18.0);
    self.upscalingDenoiseSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(20.0, 318.0, NSWidth(panel.frame) - 40.0, 22.0)];
    self.upscalingDenoiseSlider.minValue = 0.0;
    self.upscalingDenoiseSlider.maxValue = 20.0;
    self.upscalingDenoiseSlider.doubleValue = profile.upscalingDenoise;
    self.upscalingDenoiseSlider.numberOfTickMarks = 21;
    self.upscalingDenoiseSlider.allowsTickMarkValuesOnly = YES;
    self.upscalingDenoiseSlider.target = self;
    self.upscalingDenoiseSlider.action = @selector(upscalingDenoiseSliderChanged:);
    self.upscalingDenoiseSlider.continuous = YES;
    [panel addSubview:self.upscalingDenoiseSlider];

    NSTextField *audioTitle = OPNSidebarLabel(@"Audio", 14.0, NSFontWeightSemibold, NSColor.whiteColor, NSTextAlignmentLeft);
    audioTitle.frame = NSMakeRect(20.0, 364.0, 180.0, 20.0);
    [panel addSubview:audioTitle];
    [panel addSubview:OPNSidebarLabel(@"Game Volume", 12.0, NSFontWeightMedium, OPNSidebarColor(0.82, 1.0), NSTextAlignmentLeft)];
    panel.subviews.lastObject.frame = NSMakeRect(20.0, 394.0, 180.0, 18.0);
    self.gameVolumeSlider = [self sidebarSliderWithValue:profile.gameVolume action:@selector(gameVolumeSliderChanged:) y:418.0 panel:panel];
    [panel addSubview:OPNSidebarSeparator(20.0, 450.0, NSWidth(panel.frame) - 40.0)];
    [panel addSubview:OPNSidebarLabel(@"Mic Volume", 12.0, NSFontWeightMedium, OPNSidebarColor(0.82, 1.0), NSTextAlignmentLeft)];
    panel.subviews.lastObject.frame = NSMakeRect(20.0, 460.0, 180.0, 18.0);
    self.microphoneVolumeSlider = [self sidebarSliderWithValue:profile.microphoneVolume action:@selector(microphoneVolumeSliderChanged:) y:484.0 panel:panel];

    NSTextField *recordingTitle = OPNSidebarLabel(@"Recording", 14.0, NSFontWeightSemibold, NSColor.whiteColor, NSTextAlignmentLeft);
    recordingTitle.frame = NSMakeRect(20.0, 530.0, 180.0, 20.0);
    [panel addSubview:recordingTitle];

    NSView *meterTrack = [[NSView alloc] initWithFrame:NSMakeRect(20.0, 560.0, NSWidth(panel.frame) - 40.0, 14.0)];
    meterTrack.wantsLayer = YES;
    meterTrack.layer.cornerRadius = 7.0;
    meterTrack.layer.backgroundColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.12].CGColor;
    CALayer *meterFill = [CALayer layer];
    meterFill.frame = NSMakeRect(0.0, 0.0, 0.0, 14.0);
    meterFill.cornerRadius = 7.0;
    meterFill.backgroundColor = [NSColor colorWithCalibratedRed:0.28 green:0.88 blue:0.54 alpha:1.0].CGColor;
    [meterTrack.layer addSublayer:meterFill];
    self.microphoneMeterTrack = meterTrack;
    self.microphoneMeterFill = meterFill;
    [panel addSubview:meterTrack];

    self.sidebarRecordingStatusValue = OPNSidebarLabel(@"", 12.0, NSFontWeightMedium, OPNSidebarColor(0.82, 1.0), NSTextAlignmentLeft);
    self.sidebarRecordingStatusValue.frame = NSMakeRect(20.0, 558.0, NSWidth(panel.frame) - 40.0, 18.0);
    self.sidebarRecordingStatusValue.hidden = YES;
    [panel addSubview:self.sidebarRecordingStatusValue];

    NSButton *recordingButton = [NSButton buttonWithTitle:@"Start Recording" target:self action:@selector(recordingButtonClicked:)];
    recordingButton.frame = NSMakeRect(20.0, 590.0, NSWidth(panel.frame) - 40.0, 38.0);
    recordingButton.bezelStyle = NSBezelStyleRegularSquare;
    recordingButton.bordered = NO;
    recordingButton.wantsLayer = YES;
    recordingButton.layer.cornerRadius = 12.0;
    recordingButton.layer.backgroundColor = [NSColor colorWithCalibratedRed:0.0 green:0.48 blue:1.0 alpha:1.0].CGColor;
    [panel addSubview:recordingButton];
    self.recordingButton = recordingButton;

    self.sidebarHUD = panel;
    [self addSubview:panel positioned:NSWindowAbove relativeTo:self.microphoneActiveOverlay];
    [self updateSidebarMicStatus];
    [self updateSidebarPlaytimeStatus];
    [self updateRecordingControls];
}

- (void)createMicrophoneActiveOverlay {
    NSView *overlay = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 46.0, 46.0)];
    overlay.wantsLayer = YES;
    overlay.layer.cornerRadius = 15.0;
    overlay.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.0 alpha:0.68].CGColor;
    overlay.alphaValue = 0.5;
    overlay.hidden = YES;

    NSImage *image = [NSImage imageWithSystemSymbolName:@"mic.fill" accessibilityDescription:@"Microphone active"];
    if (image) {
        NSImageView *icon = [[NSImageView alloc] initWithFrame:NSMakeRect(11.0, 10.0, 24.0, 26.0)];
        icon.image = image;
        icon.contentTintColor = NSColor.whiteColor;
        icon.imageScaling = NSImageScaleProportionallyUpOrDown;
        [overlay addSubview:icon];
    } else {
        NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(6.0, 13.0, 34.0, 18.0)];
        label.stringValue = @"MIC";
        label.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightBold];
        label.textColor = NSColor.whiteColor;
        label.alignment = NSTextAlignmentCenter;
        label.drawsBackground = NO;
        label.bordered = NO;
        label.editable = NO;
        label.selectable = NO;
        [overlay addSubview:label];
    }

    self.microphoneActiveOverlay = overlay;
    [self addSubview:overlay positioned:NSWindowAbove relativeTo:self.videoSurface];
}

- (void)dealloc {
    [self.playtimeTimer invalidate];
    [self stopRecordingIfNeeded];
    [self stopGamepadPolling];
    [self cancelEscapeHoldTimer];
    [self releaseCursorCapture];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setStreamActive:(BOOL)active {
    _streamActive = active;
    if (active) {
        if (self.streamGameVolumeHandler) self.streamGameVolumeHandler(_gameVolume);
        if (self.streamMicrophoneVolumeHandler) self.streamMicrophoneVolumeHandler(_microphoneVolumeLevel);
        if (self.streamMaxBitrateHandler) self.streamMaxBitrateHandler(_maxBitrateMbps);
        if (self.streamVideoEnhancementHandler) self.streamVideoEnhancementHandler(_videoUpscalingMode, _videoUpscalingSharpness, _videoUpscalingDenoise, _videoUpscalingTargetHeight);
        [self updateEnhancedVideoRecordingPreference];
        [self startGamepadPolling];
        [self applyMicrophoneShortcutState];
    } else {
        [self stopGamepadPolling];
        _pendingMouseDx = 0;
        _pendingMouseDy = 0;
        _pushToTalkPrimaryKeyDown = NO;
        _pushToTalkMicEnabled = NO;
        [self setMicrophoneLevel:0.0];
        [self setMicrophoneActive:NO];
        [self cancelEscapeHoldTimer];
        [self releaseCursorCapture];
    }
}

- (void)clearStreamCallbacks {
    self.streamInputReadyProvider = nil;
    self.streamMicrophoneEnabledHandler = nil;
    self.streamGameVolumeHandler = nil;
    self.streamMicrophoneVolumeHandler = nil;
    self.streamMaxBitrateHandler = nil;
    self.streamEnhancedVideoCaptureHandler = nil;
    self.streamVideoEnhancementHandler = nil;
    self.streamUtf8TextHandler = nil;
    self.streamKeyEventHandler = nil;
    self.streamMouseMoveHandler = nil;
    self.streamMouseButtonHandler = nil;
    self.streamMouseWheelHandler = nil;
    self.streamGamepadStateHandler = nil;
}

- (BOOL)streamInputReady {
    return _streamActive && (!self.streamInputReadyProvider || self.streamInputReadyProvider());
}

- (void)receiveMicrophoneLevel:(double)level {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setMicrophoneLevel:level];
    });
}

- (void)receiveVideoFrame:(void *)frame {
    [self.recordingManager appendWebRTCVideoFrame:frame];
}

- (void)receiveEnhancedVideoFrame:(void *)pixelBuffer {
    [self.recordingManager appendEnhancedPixelBuffer:(CVPixelBufferRef)pixelBuffer];
}

- (void)receiveGameAudioFrame:(const void *)audioBufferList frameCount:(uint32_t)frameCount sampleRate:(double)sampleRate channels:(uint32_t)channels {
    [self.recordingManager appendWebRTCAudioBufferList:(const AudioBufferList *)audioBufferList
                                            frameCount:(UInt32)frameCount
                                            sampleRate:sampleRate
                                              channels:(UInt32)channels];
}

- (void)receiveClipboardText:(NSString *)text {
    if (text.length == 0) return;
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    [pasteboard setString:text forType:NSPasteboardTypeString];
    OPNStreamViewLog(@"[StreamView] Remote clipboard copied to macOS pasteboard (%lu chars)", (unsigned long)text.length);
}

- (void)setMaxBitrateMbps:(NSInteger)mbps {
    int clampedMbps = MAX(1, MIN((int)mbps, 250));
    _maxBitrateMbps = clampedMbps;
    if (self.streamMaxBitrateHandler) self.streamMaxBitrateHandler(clampedMbps);
}

- (void)setMicrophoneMode:(NSString *)mode pushToTalkKeyCode:(uint16_t)keyCode modifierMask:(uint16_t)modifierMask {
    _microphoneMode = [(mode.length > 0 ? mode : @"disabled") copy];
    _pushToTalkKeyCode = keyCode;
    _pushToTalkModifierMask = OPNPushToTalkNormalizedModifierMask(keyCode, modifierMask);
    _pushToTalkPrimaryKeyDown = NO;
    _pushToTalkMicEnabled = NO;
    [self applyMicrophoneShortcutState];
}

- (void)applyMicrophoneShortcutState {
    if ([_microphoneMode isEqualToString:@"disabled"]) {
        _pushToTalkMicEnabled = NO;
        [self setMicrophoneActive:NO];
        [self updateSidebarMicStatus];
        return;
    }
    if ([_microphoneMode isEqualToString:@"push-to-talk"]) {
        [self updatePushToTalkMicWithModifierMask:OPNPushToTalkModifierFlags(NSApp.currentEvent)];
        return;
    }
    [self setMicrophoneActive:_microphoneShortcutEnabled];
}

- (void)setMicrophoneActive:(BOOL)active {
    self.microphoneActiveOverlay.hidden = !active;
    if (self.streamMicrophoneEnabledHandler) self.streamMicrophoneEnabledHandler(active);
    if (!active) [self setMicrophoneLevel:0.0];
    [self updateSidebarMicStatus];
}

- (BOOL)toggleMicrophoneEnabledShortcut {
    if ([_microphoneMode isEqualToString:@"disabled"]) {
        OPNStreamViewLog(@"[StreamView] Command-M ignored because microphone is disabled in settings");
        return NO;
    }
    _microphoneShortcutEnabled = !_microphoneShortcutEnabled;
    if (!_microphoneShortcutEnabled) {
        _pushToTalkMicEnabled = NO;
        [self setMicrophoneActive:NO];
    } else {
        [self applyMicrophoneShortcutState];
    }
    [OPNStreamViewPreferences saveMicrophoneShortcutEnabled:_microphoneShortcutEnabled ? YES : NO];
    OPNStreamViewLog(@"[StreamView] Microphone shortcut toggled %@", _microphoneShortcutEnabled ? @"on" : @"off");
    return YES;
}

- (void)setRecordingGameTitle:(NSString *)gameTitle {
    _recordingGameTitle = [gameTitle.length > 0 ? gameTitle : @"Stream" copy];
}

- (BOOL)toggleRecordingShortcut {
    [self.recordingManager toggleRecordingForGameTitle:_recordingGameTitle window:self.window];
    [self updateEnhancedVideoRecordingPreference];
    [self updateRecordingControls];
    return YES;
}

- (void)stopRecordingIfNeeded {
    [self.recordingManager stopRecording];
}

- (void)attachToPipeline:(void *)pipeline {
    _attachedPipeline = pipeline;
}

- (void)detachFromPipeline {
    _attachedPipeline = NULL;
    [self setStreamActive:NO];
}

- (NSView *)nativeVideoView {
    return self.videoSurface ?: self;
}

- (void)setVideoAspectRatio:(CGFloat)aspectRatio {
    if (aspectRatio <= 0.1 || !isfinite((double)aspectRatio)) {
        aspectRatio = 16.0 / 9.0;
    }
    _videoAspectRatio = aspectRatio;
    [self setNeedsLayout:YES];
}

- (void)setVideoUpscalingMode:(NSInteger)mode sharpness:(NSInteger)sharpness denoise:(NSInteger)denoise streamWidth:(NSInteger)streamWidth streamHeight:(NSInteger)streamHeight {
    _videoUpscalingMode = MAX(0, MIN(mode, 4));
    _videoUpscalingSharpness = MAX(0, MIN(sharpness, 40));
    _videoUpscalingDenoise = MAX(0, MIN(denoise, 20));
    _videoStreamWidth = MAX(0, streamWidth);
    _videoStreamHeight = MAX(0, streamHeight);
    if (self.streamVideoEnhancementHandler) self.streamVideoEnhancementHandler(_videoUpscalingMode, _videoUpscalingSharpness, _videoUpscalingDenoise, _videoUpscalingTargetHeight);
    [self updateEnhancedVideoRecordingPreference];
    [self applyVideoUpscalingFiltersToView:self.videoSurface];
    [self setNeedsLayout:YES];
}

- (void)updateEnhancedVideoRecordingPreference {
    BOOL recordingActive = self.recordingManager.isRecording || self.recordingManager.isStarting;
    BOOL prefersEnhanced = recordingActive && _recordingEnhancedVideoEnabled && _videoUpscalingMode > 0;
    [self.recordingManager setPrefersEnhancedVideoCapture:prefersEnhanced];
    if (self.streamEnhancedVideoCaptureHandler) self.streamEnhancedVideoCaptureHandler(prefersEnhanced);
}

- (void)applyVideoUpscalingFiltersToView:(NSView *)view {
    if (!view) return;
    view.wantsLayer = YES;
    CALayer *layer = view.layer;
    if (layer) {
        layer.contentsScale = self.window.backingScaleFactor > 0.0 ? self.window.backingScaleFactor : NSScreen.mainScreen.backingScaleFactor;
        if (layer.contentsScale <= 0.0) layer.contentsScale = 1.0;
        layer.filters = nil;

        if (_videoUpscalingMode <= 0) {
            layer.magnificationFilter = kCAFilterNearest;
            layer.minificationFilter = kCAFilterLinear;
            layer.minificationFilterBias = 0.0;
            layer.allowsEdgeAntialiasing = NO;
        } else {
            layer.magnificationFilter = kCAFilterLinear;
            layer.minificationFilter = kCAFilterLinear;
            layer.minificationFilterBias = 0.0;
            layer.allowsEdgeAntialiasing = YES;
            layer.filters = nil;
        }
    }
    for (NSView *subview in view.subviews) {
        [self applyVideoUpscalingFiltersToView:subview];
    }
}

- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds);
    CGFloat height = NSHeight(self.bounds);
    if (width <= 0 || height <= 0) return;

    CGFloat targetAspect = self.videoAspectRatio > 0.1 ? self.videoAspectRatio : (16.0 / 9.0);
    CGFloat fittedWidth = width;
    CGFloat fittedHeight = floor(width / targetAspect);
    if (fittedHeight > height) {
        fittedHeight = height;
        fittedWidth = floor(height * targetAspect);
    }
    CGFloat x = floor((width - fittedWidth) / 2.0);
    CGFloat y = floor((height - fittedHeight) / 2.0);
    self.videoSurface.frame = NSMakeRect(x, y, fittedWidth, fittedHeight);
    [self applyVideoUpscalingFiltersToView:self.videoSurface];
    CGFloat overlaySize = 46.0;
    self.microphoneActiveOverlay.frame = NSMakeRect(NSMaxX(self.videoSurface.frame) - overlaySize - 18.0,
                                                   NSMinY(self.videoSurface.frame) + 18.0,
                                                   overlaySize,
                                                   overlaySize);
    if (self.sidebarHUD) {
        CGFloat panelWidth = NSWidth(self.sidebarHUD.frame);
        CGFloat panelHeight = MIN(660.0, MAX(580.0, height - 36.0));
        self.sidebarHUD.frame = NSMakeRect(18.0, floor((height - panelHeight) / 2.0), panelWidth, panelHeight);
    }
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (BOOL)canBecomeKeyView {
    return YES;
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [[self window] setAcceptsMouseMovedEvents:YES];
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center removeObserver:self name:NSWindowDidResignKeyNotification object:nil];
    if (self.window) {
        [center addObserver:self selector:@selector(streamWindowDidResignKey:) name:NSWindowDidResignKeyNotification object:self.window];
    }
    [center removeObserver:self name:NSApplicationDidResignActiveNotification object:nil];
    [center addObserver:self selector:@selector(applicationDidResignActive:) name:NSApplicationDidResignActiveNotification object:NSApp];
}

- (void)viewWillMoveToWindow:(NSWindow *)newWindow {
    if (!newWindow) {
        [self releaseCursorCapture];
        [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowDidResignKeyNotification object:self.window];
        [[NSNotificationCenter defaultCenter] removeObserver:self name:NSApplicationDidResignActiveNotification object:NSApp];
    }
    [super viewWillMoveToWindow:newWindow];
}

- (void)streamWindowDidResignKey:(NSNotification *)notification {
    (void)notification;
    [self releaseCursorCapture];
}

- (void)applicationDidResignActive:(NSNotification *)notification {
    (void)notification;
    [self releaseCursorCapture];
}

- (void)setSuppressInputWhenWindowInactive:(BOOL)suppress {
    _suppressInputWhenWindowInactive = suppress;
}

- (void)setDirectMouseInputEnabled:(BOOL)enabled {
    _directMouseInputEnabled = enabled;
    if (!enabled) {
        [self releaseCursorCapture];
    }
}

- (BOOL)streamWindowAcceptsInput {
    if (_streamInputSuppressed) return NO;
    if (_sidebarOpen) return NO;
    if (!_suppressInputWhenWindowInactive) return YES;
    NSWindow *window = self.window;
    return NSApp.isActive && window && (window.isKeyWindow || window.isMainWindow);
}

- (void)setStreamInputSuppressed:(BOOL)suppressed {
    if (_streamInputSuppressed == suppressed) return;
    _streamInputSuppressed = suppressed;
    if (suppressed) {
        [self resetInputStateAfterSuppression];
        [self releaseCursorCapture];
    }
}

- (void)toggleSidebarHUD {
    _sidebarOpen = !_sidebarOpen;
    self.sidebarHUD.hidden = !_sidebarOpen;
    if (_sidebarOpen) {
        [self resetInputStateAfterSuppression];
        [self releaseCursorCapture];
        [self updateSidebarMicStatus];
        [self updateSidebarPlaytimeStatus];
        [self.window makeFirstResponder:self.sidebarHUD];
    } else {
        [self takeFocus];
    }
    [self setNeedsLayout:YES];
    if (self.onSidebarHUDVisibilityChanged) self.onSidebarHUDVisibilityChanged(_sidebarOpen);
}

- (BOOL)isSidebarHUDVisible {
    return _sidebarOpen && self.sidebarHUD && !self.sidebarHUD.hidden;
}

- (void)closeSidebarHUDClicked:(id)sender {
    (void)sender;
    if (!_sidebarOpen) return;
    [self toggleSidebarHUD];
}

- (void)recordingButtonClicked:(id)sender {
    (void)sender;
    [self toggleRecordingShortcut];
}

- (void)gameVolumeSliderChanged:(NSSlider *)slider {
    _gameVolume = fmax(0.0, fmin(slider.doubleValue / 100.0, 1.0));
    if (self.streamGameVolumeHandler) self.streamGameVolumeHandler(_gameVolume);
    [OPNStreamViewPreferences saveGameVolume:_gameVolume];
}

- (void)microphoneVolumeSliderChanged:(NSSlider *)slider {
    _microphoneVolumeLevel = fmax(0.0, fmin(slider.doubleValue / 100.0, 1.0));
    if (self.streamMicrophoneVolumeHandler) self.streamMicrophoneVolumeHandler(_microphoneVolumeLevel);
    [OPNStreamViewPreferences saveMicrophoneVolume:_microphoneVolumeLevel];
}

- (void)upscalingModePopupChanged:(NSPopUpButton *)popup {
    NSInteger index = MAX(0, popup.indexOfSelectedItem);
    NSInteger mode = [OPNStreamViewPreferences upscalingModeValueAtIndex:index];
    [OPNStreamViewPreferences saveUpscalingModeIndex:index];
    [self setVideoUpscalingMode:mode
                      sharpness:_videoUpscalingSharpness
                        denoise:_videoUpscalingDenoise
                    streamWidth:_videoStreamWidth
                   streamHeight:_videoStreamHeight];
}

- (void)upscalingSharpnessSliderChanged:(NSSlider *)slider {
    NSInteger sharpness = MAX(0, MIN((NSInteger)lround(slider.doubleValue), 40));
    slider.doubleValue = sharpness;
    [OPNStreamViewPreferences saveUpscalingSharpness:sharpness];
    [self setVideoUpscalingMode:_videoUpscalingMode
                      sharpness:sharpness
                        denoise:_videoUpscalingDenoise
                    streamWidth:_videoStreamWidth
                   streamHeight:_videoStreamHeight];
}

- (void)upscalingDenoiseSliderChanged:(NSSlider *)slider {
    NSInteger denoise = MAX(0, MIN((NSInteger)lround(slider.doubleValue), 20));
    slider.doubleValue = denoise;
    [OPNStreamViewPreferences saveUpscalingDenoise:denoise];
    [self setVideoUpscalingMode:_videoUpscalingMode
                      sharpness:_videoUpscalingSharpness
                        denoise:denoise
                    streamWidth:_videoStreamWidth
                   streamHeight:_videoStreamHeight];
}

- (void)setRemainingPlaytimeHours:(double)hours unlimited:(BOOL)unlimited {
    _remainingPlaytimeUnlimited = unlimited;
    _remainingPlaytimeAvailable = unlimited || (isfinite(hours) && hours >= 0.0);
    _remainingPlaytimeBaseSeconds = _remainingPlaytimeAvailable && !unlimited ? MAX(0.0, hours * 3600.0) : 0.0;
    _remainingPlaytimeStartTime = 0.0;
    [self updateSidebarPlaytimeStatus];
}

- (void)startRemainingPlaytimeCountdown {
    if (!_remainingPlaytimeAvailable || _remainingPlaytimeUnlimited) {
        [self updateSidebarPlaytimeStatus];
        return;
    }
    if (_remainingPlaytimeStartTime <= 0.0) _remainingPlaytimeStartTime = CACurrentMediaTime();
    if (!self.playtimeTimer) {
        self.playtimeTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                              target:self
                                                            selector:@selector(playtimeTimerFired:)
                                                            userInfo:nil
                                                             repeats:YES];
    }
    [self updateSidebarPlaytimeStatus];
}

- (void)playtimeTimerFired:(NSTimer *)timer {
    (void)timer;
    [self updateSidebarPlaytimeStatus];
}

- (void)updateSidebarPlaytimeStatus {
    if (!self.sidebarPlaytimeValue) return;
    if (!_remainingPlaytimeAvailable) {
        self.sidebarPlaytimeValue.stringValue = @"--";
        return;
    }
    if (_remainingPlaytimeUnlimited) {
        self.sidebarPlaytimeValue.stringValue = @"Unlimited";
        return;
    }
    NSTimeInterval elapsed = _remainingPlaytimeStartTime > 0.0 ? CACurrentMediaTime() - _remainingPlaytimeStartTime : 0.0;
    self.sidebarPlaytimeValue.stringValue = OPNFormatSidebarPlaytimeSeconds(MAX(0.0, _remainingPlaytimeBaseSeconds - elapsed));
}

- (void)updateSidebarMicStatus {
    NSString *mode = @"Disabled";
    if ([_microphoneMode isEqualToString:@"push-to-talk"]) {
        mode = self.microphoneActiveOverlay.hidden ? @"PTT muted" : @"PTT live";
    } else if ([_microphoneMode isEqualToString:@"voice-activity"]) {
        mode = _microphoneShortcutEnabled ? @"Open mic live" : @"Open mic muted";
    }
    self.sidebarMicStatusValue.stringValue = mode;
}

- (void)updateRecordingControls {
    NSString *title = @"Start Recording";
    NSColor *buttonColor = [NSColor colorWithCalibratedRed:0.0 green:0.48 blue:1.0 alpha:1.0];
    if (self.recordingManager.isRecording) {
        title = @"Stop Recording";
        buttonColor = [NSColor colorWithCalibratedRed:0.92 green:0.18 blue:0.22 alpha:1.0];
    } else if (self.recordingManager.isStarting) {
        title = @"Starting...";
        buttonColor = [NSColor colorWithCalibratedRed:0.56 green:0.42 blue:0.12 alpha:1.0];
    }
    self.recordingButton.title = title;
    self.recordingButton.layer.backgroundColor = buttonColor.CGColor;
    NSString *status = self.recordingManager.statusText ?: @"";
    BOOL showsRecordingStatus = status.length > 0 && ![status isEqualToString:@"Ready"];
    self.sidebarRecordingStatusValue.stringValue = showsRecordingStatus ? status : @"";
    self.sidebarRecordingStatusValue.hidden = !showsRecordingStatus;
    self.microphoneMeterTrack.hidden = showsRecordingStatus;
}

- (void)setMicrophoneLevel:(double)level {
    _microphoneLevel = fmax(0.0, fmin(level, 1.0));
    if (!self.microphoneMeterTrack || !self.microphoneMeterFill) return;
    CGFloat width = NSWidth(self.microphoneMeterTrack.bounds) * (CGFloat)_microphoneLevel;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.microphoneMeterFill.frame = NSMakeRect(0.0, 0.0, width, NSHeight(self.microphoneMeterTrack.bounds));
    if (_microphoneLevel > 0.72) {
        self.microphoneMeterFill.backgroundColor = [NSColor colorWithCalibratedRed:1.0 green:0.48 blue:0.24 alpha:1.0].CGColor;
    } else if (_microphoneLevel > 0.45) {
        self.microphoneMeterFill.backgroundColor = [NSColor colorWithCalibratedRed:0.95 green:0.78 blue:0.28 alpha:1.0].CGColor;
    } else {
        self.microphoneMeterFill.backgroundColor = [NSColor colorWithCalibratedRed:0.28 green:0.88 blue:0.54 alpha:1.0].CGColor;
    }
    [CATransaction commit];
}

- (void)resetInputStateAfterSuppression {
    [self cancelEscapeHoldTimer];
    _pendingMouseDx = 0;
    _pendingMouseDy = 0;
    _pushToTalkPrimaryKeyDown = NO;
    if (_pushToTalkMicEnabled && _streamActive && [_microphoneMode isEqualToString:@"push-to-talk"]) {
        _pushToTalkMicEnabled = NO;
        [self setMicrophoneActive:NO];
    } else {
        _pushToTalkMicEnabled = NO;
    }
}

- (void)takeFocus {
    [[self window] makeFirstResponder:self];
    [[self window] setAcceptsMouseMovedEvents:YES];
}

static uint16_t OPNModifierFlags(NSEvent *event) {
    NSEventModifierFlags flags = event.modifierFlags;
    uint16_t out = 0;
    if (flags & NSEventModifierFlagShift) out |= 0x01;
    if (flags & NSEventModifierFlagControl) out |= 0x02;
    if (flags & NSEventModifierFlagOption) out |= 0x04;
    if (flags & NSEventModifierFlagCommand) out |= 0x08;
    if (flags & NSEventModifierFlagCapsLock) out |= 0x10;
    if (flags & NSEventModifierFlagNumericPad) out |= 0x20;
    return out;
}

static uint16_t OPNPushToTalkModifierFlags(NSEvent *event) {
    NSEventModifierFlags flags = event.modifierFlags;
    uint16_t out = 0;
    if (flags & NSEventModifierFlagShift) out |= 0x01;
    if (flags & NSEventModifierFlagControl) out |= 0x02;
    if (flags & NSEventModifierFlagOption) out |= 0x04;
    if (flags & NSEventModifierFlagCommand) out |= 0x08;
    if (flags & NSEventModifierFlagCapsLock) out |= 0x10;
    return out;
}

static NSString *OPNClipboardString(void) {
    NSString *value = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
    return [value isKindOfClass:NSString.class] ? value : @"";
}

static BOOL OPNEventIsCommandClipboardShortcut(NSEvent *event, NSString *characters) {
    NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if ((flags & NSEventModifierFlagCommand) == 0) return NO;
    if ((flags & (NSEventModifierFlagControl | NSEventModifierFlagOption)) != 0) return NO;
    NSString *lower = characters.lowercaseString ?: @"";
    return [lower isEqualToString:@"a"] || [lower isEqualToString:@"c"] || [lower isEqualToString:@"v"] || [lower isEqualToString:@"x"];
}

static uint16_t OPNPushToTalkModifierBitForKeyCode(uint16_t keyCode) {
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

static uint16_t OPNPushToTalkNormalizedModifierMask(uint16_t keyCode, uint16_t modifierMask) {
    uint16_t normalized = modifierMask & 0x1f;
    uint16_t keyModifierBit = OPNPushToTalkModifierBitForKeyCode(keyCode);
    if (keyModifierBit != 0) normalized |= keyModifierBit;
    return normalized;
}

static int16_t OPNClampI16(double value) {
    value = fmax(-32768.0, fmin(32767.0, round(value)));
    return (int16_t)value;
}

static uint8_t OPNMouseButtonForEvent(NSEvent *event) {
    switch (event.type) {
        case NSEventTypeLeftMouseDown:
        case NSEventTypeLeftMouseUp:
        case NSEventTypeLeftMouseDragged:
            return OPN_MOUSE_LEFT;
        case NSEventTypeRightMouseDown:
        case NSEventTypeRightMouseUp:
        case NSEventTypeRightMouseDragged:
            return OPN_MOUSE_RIGHT;
        case NSEventTypeOtherMouseDown:
        case NSEventTypeOtherMouseUp:
        case NSEventTypeOtherMouseDragged:
            if (event.buttonNumber == 2) return OPN_MOUSE_MIDDLE;
            if (event.buttonNumber == 3) return OPN_MOUSE_BACK;
            if (event.buttonNumber == 4) return OPN_MOUSE_FORWARD;
            return (uint8_t)MIN(5, MAX(1, event.buttonNumber + 1));
        default:
            return 0;
    }
}

static uint8_t OPNMouseButtonMask(uint8_t button) {
    if (button == 0 || button > 7) return 0;
    return (uint8_t)(1u << (button - 1));
}

- (void)updatePushToTalkMicWithModifierMask:(uint16_t)modifierMask {
    if (!_streamActive || ![_microphoneMode isEqualToString:@"push-to-talk"]) return;
    BOOL shouldEnable = _microphoneShortcutEnabled && _pushToTalkPrimaryKeyDown && ((modifierMask & 0x1f) == _pushToTalkModifierMask);
    if (_pushToTalkMicEnabled == shouldEnable) return;
    _pushToTalkMicEnabled = shouldEnable;
    [self setMicrophoneActive:shouldEnable];
}

- (BOOL)handlePushToTalkKeyEvent:(NSEvent *)event down:(BOOL)down {
    if (![_microphoneMode isEqualToString:@"push-to-talk"] || event.keyCode != _pushToTalkKeyCode) return NO;
    if (down && event.isARepeat) return YES;

    _pushToTalkPrimaryKeyDown = down ? YES : NO;
    [self updatePushToTalkMicWithModifierMask:OPNPushToTalkModifierFlags(event)];
    return YES;
}

- (BOOL)handlePushToTalkFlagsChanged:(NSEvent *)event {
    if (![_microphoneMode isEqualToString:@"push-to-talk"]) return NO;

    uint16_t changedModifier = OPNPushToTalkModifierBitForKeyCode((uint16_t)event.keyCode);
    if (changedModifier == 0) return NO;

    uint16_t currentModifiers = OPNPushToTalkModifierFlags(event);
    BOOL isPrimaryKey = event.keyCode == _pushToTalkKeyCode;
    BOOL isConfiguredModifier = (_pushToTalkModifierMask & changedModifier) != 0;
    if (!isPrimaryKey && !isConfiguredModifier && !_pushToTalkMicEnabled) return NO;

    if (isPrimaryKey) {
        _pushToTalkPrimaryKeyDown = (currentModifiers & changedModifier) != 0 ? YES : NO;
    }
    [self updatePushToTalkMicWithModifierMask:currentModifiers];
    return isPrimaryKey || isConfiguredModifier || _pushToTalkMicEnabled;
}

- (void)notifyUserActivity {
    if (self.onUserActivity) self.onUserActivity();
}

- (void)handleKeyEvent:(NSEvent *)event {
    if (!_streamActive) return;
    if (![self streamWindowAcceptsInput]) {
        [self resetInputStateAfterSuppression];
        return;
    }
    [self notifyUserActivity];
    bool down = event.type == NSEventTypeKeyDown;
    if ([self handlePushToTalkKeyEvent:event down:down]) {
        return;
    }

    if (![self streamInputReady]) return;

    NSString *characters = event.charactersIgnoringModifiers ?: @"";
    if (down && !event.isARepeat && OPNEventIsCommandClipboardShortcut(event, characters)) {
        NSString *shortcut = characters.lowercaseString;
        if ([shortcut isEqualToString:@"v"]) {
            NSString *clipboard = OPNClipboardString();
            if (clipboard.length > 0) {
                if (self.streamUtf8TextHandler) self.streamUtf8TextHandler(clipboard);
                OPNStreamViewLog(@"[StreamView] macOS clipboard sent to stream (%lu chars)", (unsigned long)clipboard.length);
                return;
            }
        }

        uint16_t keycode = (uint16_t)([shortcut characterAtIndex:0] - 'a' + 0x41);
        uint16_t scancode = 0;
        OPNStreamKeyMapping shortcutMapping;
        if (OPNMapMacKeyCode((uint16_t)event.keyCode, &shortcutMapping)) scancode = shortcutMapping.scancode;
        if (self.streamKeyEventHandler) {
            self.streamKeyEventHandler(0xa2, 0x001d, 0x02, YES);
            self.streamKeyEventHandler(keycode, scancode, 0x02, YES);
            self.streamKeyEventHandler(keycode, scancode, 0x02, NO);
            self.streamKeyEventHandler(0xa2, 0x001d, 0, NO);
        }
        return;
    }

    OPNStreamKeyMapping mapping;
    if (!OPNMapMacKeyCode((uint16_t)event.keyCode, &mapping)) {
        OPNStreamViewLog(@"[StreamView] No OPN key mapping for mac keyCode=%hu", (unsigned short)event.keyCode);
        return;
    }

    if (event.keyCode == 53) {
        if (down && !event.isARepeat) {
            [self startEscapeHoldTimer];
        } else if (!down) {
            [self cancelEscapeHoldTimer];
        }
    }
    if (self.streamKeyEventHandler) self.streamKeyEventHandler(mapping.vk, mapping.scancode, OPNModifierFlags(event), down ? YES : NO);
}

- (void)handleMouseEvent:(NSEvent *)event {
    if (![self streamInputReady]) return;
    if (![self streamWindowAcceptsInput]) {
        [self resetInputStateAfterSuppression];
        return;
    }
    [self notifyUserActivity];

    switch (event.type) {
        case NSEventTypeMouseMoved:
        case NSEventTypeLeftMouseDragged:
        case NSEventTypeRightMouseDragged:
        case NSEventTypeOtherMouseDragged: {
            if (!_directMouseInputEnabled || !_cursorCaptured) {
                break;
            }
            [self accumulateMouseDx:event.deltaX dy:event.deltaY];
            [self flushPendingMouseMove];
            break;
        }
        case NSEventTypeLeftMouseDown:
        case NSEventTypeRightMouseDown:
        case NSEventTypeOtherMouseDown: {
            [self takeFocus];
            if (!_directMouseInputEnabled) {
                uint8_t button = OPNMouseButtonForEvent(event);
                uint8_t mask = OPNMouseButtonMask(button);
                if (mask) _mouseButtonsDown |= mask;
                if (self.streamMouseButtonHandler) self.streamMouseButtonHandler(button, YES);
                break;
            }
            if (!_cursorCaptured) {
                [self captureCursorIfNeeded];
                break;
            }
            uint8_t button = OPNMouseButtonForEvent(event);
            uint8_t mask = OPNMouseButtonMask(button);
            if (mask) _mouseButtonsDown |= mask;
            [self flushPendingMouseMove];
            if (self.streamMouseButtonHandler) self.streamMouseButtonHandler(button, YES);
            break;
        }
        case NSEventTypeLeftMouseUp:
        case NSEventTypeRightMouseUp:
        case NSEventTypeOtherMouseUp: {
            uint8_t button = OPNMouseButtonForEvent(event);
            uint8_t mask = OPNMouseButtonMask(button);
            if (mask) _mouseButtonsDown &= (uint8_t)~mask;
            if (_cursorCaptured) [self flushPendingMouseMove];
            if (self.streamMouseButtonHandler) self.streamMouseButtonHandler(button, NO);
            break;
        }
        case NSEventTypeScrollWheel: {
            if (_cursorCaptured) [self flushPendingMouseMove];
            double precise = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 120.0;
            if (self.streamMouseWheelHandler) self.streamMouseWheelHandler(OPNClampI16(-precise));
            break;
        }
        default:
            break;
    }
}

- (void)keyDown:(NSEvent *)event {
    [self handleKeyEvent:event];
}

- (void)keyUp:(NSEvent *)event {
    [self handleKeyEvent:event];
}

- (void)mouseMoved:(NSEvent *)event {
    [self handleMouseEvent:event];
}

- (void)mouseDown:(NSEvent *)event {
    [self handleMouseEvent:event];
}

- (void)mouseUp:(NSEvent *)event {
    [self handleMouseEvent:event];
}

- (void)rightMouseDown:(NSEvent *)event {
    [self handleMouseEvent:event];
}

- (void)rightMouseUp:(NSEvent *)event {
    [self handleMouseEvent:event];
}

- (void)otherMouseDown:(NSEvent *)event {
    [self handleMouseEvent:event];
}

- (void)otherMouseUp:(NSEvent *)event {
    [self handleMouseEvent:event];
}

- (void)mouseDragged:(NSEvent *)event {
    [self handleMouseEvent:event];
}

- (void)rightMouseDragged:(NSEvent *)event {
    [self handleMouseEvent:event];
}

- (void)otherMouseDragged:(NSEvent *)event {
    [self handleMouseEvent:event];
}

- (void)scrollWheel:(NSEvent *)event {
    [self handleMouseEvent:event];
}

- (void)flagsChanged:(NSEvent *)event {
    if (!_streamActive) return;
    if (![self streamWindowAcceptsInput]) {
        [self resetInputStateAfterSuppression];
        return;
    }
    OPNStreamKeyMapping mapping;
    if (!OPNMapMacKeyCode((uint16_t)event.keyCode, &mapping) || event.keyCode >= 128) return;

    NSEventModifierFlags flags = event.modifierFlags;
    BOOL down = NO;
    switch (event.keyCode) {
        case 55:
            down = (flags & NSEventModifierFlagCommand) != 0;
            break;
        case 56:
        case 60:
            down = (flags & NSEventModifierFlagShift) != 0;
            break;
        case 57:
            down = (flags & NSEventModifierFlagCapsLock) != 0;
            break;
        case 58:
        case 61:
            down = (flags & NSEventModifierFlagOption) != 0;
            break;
        case 59:
        case 62:
            down = (flags & NSEventModifierFlagControl) != 0;
            break;
        default:
            return;
    }

    if (_modifierDown[event.keyCode] == down) return;
    _modifierDown[event.keyCode] = down;
    [self notifyUserActivity];
    if ([self handlePushToTalkFlagsChanged:event]) {
        return;
    }
    if (![self streamInputReady]) return;
    if (self.streamKeyEventHandler) self.streamKeyEventHandler(mapping.vk, mapping.scancode, OPNModifierFlags(event), down ? YES : NO);
}

- (void)captureCursorIfNeeded {
    if (_cursorCaptured || !_directMouseInputEnabled) return;
    CGAssociateMouseAndMouseCursorPosition(false);
    if (!_cursorHidden) {
        [NSCursor hide];
        _cursorHidden = YES;
    }
    _cursorCaptured = YES;
    OPNStreamViewLog(@"[StreamView] Stream pointer locker active");
}

- (void)releasePressedMouseButtons {
    if (!_mouseButtonsDown) return;
    static const uint8_t buttons[] = {
        OPN_MOUSE_LEFT,
        OPN_MOUSE_MIDDLE,
        OPN_MOUSE_RIGHT,
        OPN_MOUSE_BACK,
        OPN_MOUSE_FORWARD,
    };
    if ([self streamInputReady]) {
        for (NSUInteger index = 0; index < sizeof(buttons) / sizeof(buttons[0]); index++) {
            uint8_t button = buttons[index];
            uint8_t mask = OPNMouseButtonMask(button);
            if (mask && (_mouseButtonsDown & mask)) {
                if (self.streamMouseButtonHandler) self.streamMouseButtonHandler(button, NO);
            }
        }
    }
    _mouseButtonsDown = 0;
}

- (void)releaseCursorCapture {
    if (!_cursorCaptured) return;
    [self releasePressedMouseButtons];
    _pendingMouseDx = 0;
    _pendingMouseDy = 0;
    CGAssociateMouseAndMouseCursorPosition(true);
    if (_cursorHidden) {
        [NSCursor unhide];
        _cursorHidden = NO;
    }
    _cursorCaptured = NO;
    OPNStreamViewLog(@"[StreamView] Stream pointer locker armed");
}

- (void)releasePointerLock {
    [self releaseCursorCapture];
}

- (void)startEscapeHoldTimer {
    if (_escapeHoldTimer) return;
    _escapeHoldTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (!_escapeHoldTimer) return;
    dispatch_source_set_timer(_escapeHoldTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                              DISPATCH_TIME_FOREVER,
                              50 * NSEC_PER_MSEC);
    __weak OPNStreamView *weakSelf = self;
    dispatch_source_set_event_handler(_escapeHoldTimer, ^{
        OPNStreamView *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf releaseCursorCapture];
        [strongSelf cancelEscapeHoldTimer];
        OPNStreamViewLog(@"[StreamView] ESC held for 3s; pointer capture released");
    });
    dispatch_resume(_escapeHoldTimer);
}

- (void)cancelEscapeHoldTimer {
    if (!_escapeHoldTimer) return;
    dispatch_source_cancel(_escapeHoldTimer);
    _escapeHoldTimer = nil;
}

- (void)accumulateMouseDx:(double)dx dy:(double)dy {
    _pendingMouseDx += dx;
    _pendingMouseDy += dy;
}

- (void)flushPendingMouseMove {
    if (![self streamInputReady] || ![self streamWindowAcceptsInput]) {
        _pendingMouseDx = 0;
        _pendingMouseDy = 0;
        return;
    }
    if (fabs(_pendingMouseDx) < 0.5 && fabs(_pendingMouseDy) < 0.5) {
        return;
    }

    double sendDx = round(_pendingMouseDx);
    double sendDy = round(_pendingMouseDy);
    if (sendDx == 0 && sendDy == 0) {
        return;
    }
    _pendingMouseDx -= sendDx;
    _pendingMouseDy -= sendDy;
    if (self.streamMouseMoveHandler) self.streamMouseMoveHandler(OPNClampI16(sendDx), OPNClampI16(sendDy));
}

- (void)registerForControllerNotifications {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(controllerDidConnect:) name:GCControllerDidConnectNotification object:nil];
    [center addObserver:self selector:@selector(controllerDidDisconnect:) name:GCControllerDidDisconnectNotification object:nil];
}

- (void)controllerDidConnect:(NSNotification *)notification {
    (void)notification;
    OPNStreamViewLog(@"[StreamView] GameController connected");
    [self startGamepadPolling];
}

- (void)handleStartButtonHeldForController:(NSUInteger)index now:(CFTimeInterval)now down:(BOOL)down {
    if (index >= (NSUInteger)OPN_GAMEPAD_MAX_CONTROLLERS) return;
    if (!down) {
        _startButtonHoldBegan[index] = 0;
        _startButtonHoldConsumed[index] = NO;
        return;
    }
    if (_startButtonHoldBegan[index] <= 0) {
        _startButtonHoldBegan[index] = now;
        return;
    }
    if (_startButtonHoldConsumed[index] || now - _startButtonHoldBegan[index] < 3.0) return;
    _startButtonHoldConsumed[index] = YES;
    if (self.onDashboardToggleRequested) self.onDashboardToggleRequested();
    [self notifyUserActivity];
}

- (void)controllerDidDisconnect:(NSNotification *)notification {
    (void)notification;
    OPNStreamViewLog(@"[StreamView] GameController disconnected");
    [self pollGamepads];
    if (GCController.controllers.count == 0) {
        [self stopGamepadPolling];
    }
}

- (void)startGamepadPolling {
    if (_gamepadTimer) return;
    if (!_streamActive || GCController.controllers.count == 0) return;
    _gamepadTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (!_gamepadTimer) return;
    dispatch_source_set_timer(_gamepadTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              8 * NSEC_PER_MSEC,
                              1 * NSEC_PER_MSEC);
    __weak OPNStreamView *weakSelf = self;
    dispatch_source_set_event_handler(_gamepadTimer, ^{
        OPNStreamView *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf pollGamepads];
    });
    dispatch_resume(_gamepadTimer);
}

- (void)stopGamepadPolling {
    if (_gamepadTimer) {
        dispatch_source_cancel(_gamepadTimer);
    }
    _gamepadTimer = nil;
}

static bool OPNStateEquals(const OPNStreamGamepadState *a, const OPNStreamGamepadState *b) {
    return a->connected == b->connected
        && a->buttons == b->buttons
        && a->leftTrigger == b->leftTrigger
        && a->rightTrigger == b->rightTrigger
        && a->leftStickX == b->leftStickX
        && a->leftStickY == b->leftStickY
        && a->rightStickX == b->rightStickX
        && a->rightStickY == b->rightStickY;
}

- (void)pollGamepads {
    if (![self streamInputReady]) return;
    BOOL streamAcceptsInput = [self streamWindowAcceptsInput];

    NSArray<GCController *> *controllers = [GCController controllers];
    if (controllers.count == 0) {
        [self stopGamepadPolling];
    }
    BOOL seen[OPN_GAMEPAD_MAX_CONTROLLERS] = {NO, NO, NO, NO};

    NSUInteger count = MIN((NSUInteger)OPN_GAMEPAD_MAX_CONTROLLERS, controllers.count);
    for (NSUInteger i = 0; i < count; i++) {
        GCController *controller = controllers[i];
        GCExtendedGamepad *pad = controller.extendedGamepad;
        if (!pad) continue;
        seen[i] = YES;

        _gamepadBitmap |= (uint16_t)(1u << i);
        _gamepadBitmap |= (uint16_t)(1u << (i + 8));

        double lx = pad.leftThumbstick.xAxis.value;
        double ly = pad.leftThumbstick.yAxis.value;
        double rx = pad.rightThumbstick.xAxis.value;
        double ry = pad.rightThumbstick.yAxis.value;
        double dlx = 0, dly = 0, drx = 0, dry = 0;
        OPNApplyRadialDeadzone(lx, ly, &dlx, &dly);
        OPNApplyRadialDeadzone(rx, ry, &drx, &dry);

        uint16_t buttons = 0;
        if (pad.buttonA.value > 0) buttons |= OPN_GAMEPAD_A;
        if (pad.buttonB.value > 0) buttons |= OPN_GAMEPAD_B;
        if (pad.buttonX.value > 0) buttons |= OPN_GAMEPAD_X;
        if (pad.buttonY.value > 0) buttons |= OPN_GAMEPAD_Y;
        if (pad.leftShoulder.value > 0) buttons |= OPN_GAMEPAD_LB;
        if (pad.rightShoulder.value > 0) buttons |= OPN_GAMEPAD_RB;
        if (pad.dpad.up.value > 0) buttons |= OPN_GAMEPAD_DPAD_UP;
        if (pad.dpad.down.value > 0) buttons |= OPN_GAMEPAD_DPAD_DOWN;
        if (pad.dpad.left.value > 0) buttons |= OPN_GAMEPAD_DPAD_LEFT;
        if (pad.dpad.right.value > 0) buttons |= OPN_GAMEPAD_DPAD_RIGHT;
        if (@available(macOS 10.15, *)) {
            if (pad.buttonOptions.value > 0) buttons |= OPN_GAMEPAD_BACK;
            if (pad.buttonMenu.value > 0) buttons |= OPN_GAMEPAD_START;
            if (pad.leftThumbstickButton.value > 0) buttons |= OPN_GAMEPAD_LS;
            if (pad.rightThumbstickButton.value > 0) buttons |= OPN_GAMEPAD_RS;
        }
        CFTimeInterval now = CACurrentMediaTime();
        [self handleStartButtonHeldForController:i now:now down:(buttons & OPN_GAMEPAD_START) != 0];
        if (!streamAcceptsInput) continue;

        OPNStreamGamepadState state = {0};
        state.controllerId = (uint16_t)i;
        state.connected = true;
        state.buttons = buttons;
        state.leftTrigger = OPNNormalizeTriggerToUint8(pad.leftTrigger.value);
        state.rightTrigger = OPNNormalizeTriggerToUint8(pad.rightTrigger.value);
        state.leftStickX = OPNNormalizeAxisToInt16(dlx);
        state.leftStickY = OPNNormalizeAxisToInt16(dly);
        state.rightStickX = OPNNormalizeAxisToInt16(drx);
        state.rightStickY = OPNNormalizeAxisToInt16(dry);
        state.timestampUs = OPNStreamInputTimestampUs();

        BOOL changed = !_previousPads[i].known || !OPNStateEquals(&_previousPads[i].state, &state);
        BOOL keepalive = (now - _lastGamepadSend[i]) >= 1.0;
        if (changed || keepalive) {
            if (self.streamGamepadStateHandler) {
                self.streamGamepadStateHandler(state.controllerId, state.buttons, state.leftTrigger, state.rightTrigger, state.leftStickX, state.leftStickY, state.rightStickX, state.rightStickY, state.connected ? YES : NO, _gamepadBitmap, state.timestampUs);
            }
            if (changed) [self notifyUserActivity];
            _previousPads[i].known = true;
            _previousPads[i].state = state;
            _lastGamepadSend[i] = now;
        }
    }

    for (NSUInteger i = 0; i < (NSUInteger)OPN_GAMEPAD_MAX_CONTROLLERS; i++) {
        if (seen[i] || !_previousPads[i].known || !_previousPads[i].state.connected) continue;
        _gamepadBitmap &= (uint16_t)~(1u << i);
        _gamepadBitmap &= (uint16_t)~(1u << (i + 8));

        OPNStreamGamepadState state = {0};
        state.controllerId = (uint16_t)i;
        state.connected = false;
        state.timestampUs = OPNStreamInputTimestampUs();
        if (self.streamGamepadStateHandler) {
            self.streamGamepadStateHandler(state.controllerId, state.buttons, state.leftTrigger, state.rightTrigger, state.leftStickX, state.leftStickY, state.rightStickX, state.rightStickY, state.connected ? YES : NO, _gamepadBitmap, state.timestampUs);
        }
        _startButtonHoldBegan[i] = 0;
        _startButtonHoldConsumed[i] = NO;
        _previousPads[i].state = state;
        _lastGamepadSend[i] = CACurrentMediaTime();
    }
}

@end
