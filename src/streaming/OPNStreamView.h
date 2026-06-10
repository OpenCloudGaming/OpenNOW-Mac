#pragma once

#import <Cocoa/Cocoa.h>

typedef BOOL (^OPNStreamInputReadyProvider)(void);
typedef void (^OPNStreamBooleanHandler)(BOOL enabled);
typedef void (^OPNStreamIntegerHandler)(NSInteger value);
typedef void (^OPNStreamDoubleHandler)(double value);
typedef void (^OPNStreamTextHandler)(NSString *text);
typedef void (^OPNStreamKeyEventHandler)(uint16_t keycode, uint16_t scancode, uint16_t modifiers, BOOL down);
typedef void (^OPNStreamMouseMoveHandler)(int16_t dx, int16_t dy);
typedef void (^OPNStreamMouseButtonHandler)(uint8_t button, BOOL down);
typedef void (^OPNStreamMouseWheelHandler)(int16_t delta);
typedef void (^OPNStreamGamepadStateHandler)(uint16_t controllerId,
                                             uint16_t buttons,
                                             uint8_t leftTrigger,
                                             uint8_t rightTrigger,
                                             int16_t leftStickX,
                                             int16_t leftStickY,
                                             int16_t rightStickX,
                                             int16_t rightStickY,
                                             BOOL connected,
                                             uint16_t bitmap,
                                             uint64_t timestampUs);
typedef void (^OPNStreamVideoFrameHandler)(void *frame);
typedef void (^OPNStreamAudioFrameHandler)(const void *audioBufferList, uint32_t frameCount, double sampleRate, uint32_t channels);
typedef void (^OPNStreamVideoEnhancementHandler)(NSInteger mode, NSInteger sharpness, NSInteger denoise, NSInteger targetHeight);

@interface OPNStreamView : NSView

- (void)setMicrophoneMode:(NSString *)mode pushToTalkKeyCode:(uint16_t)keyCode modifierMask:(uint16_t)modifierMask;
- (void)setStreamActive:(BOOL)active;
- (void)setMaxBitrateMbps:(NSInteger)mbps;
- (BOOL)toggleMicrophoneEnabledShortcut;
- (BOOL)toggleRecordingShortcut;
- (void)toggleSidebarHUD;
- (void)setRecordingGameTitle:(NSString *)gameTitle;
- (void)setRemainingPlaytimeHours:(double)hours unlimited:(BOOL)unlimited;
- (void)startRemainingPlaytimeCountdown;
- (void)stopRecordingIfNeeded;
- (void)setSuppressInputWhenWindowInactive:(BOOL)suppress;
- (void)setStreamInputSuppressed:(BOOL)suppressed;
- (void)setDirectMouseInputEnabled:(BOOL)enabled;
- (void)attachToPipeline:(void *)pipeline;
- (void)detachFromPipeline;
- (void)handleKeyEvent:(NSEvent *)event;
- (void)handleMouseEvent:(NSEvent *)event;
- (NSView *)nativeVideoView;
- (void)setVideoAspectRatio:(CGFloat)aspectRatio;
- (void)setVideoUpscalingMode:(NSInteger)mode sharpness:(NSInteger)sharpness denoise:(NSInteger)denoise streamWidth:(NSInteger)streamWidth streamHeight:(NSInteger)streamHeight;
- (void)takeFocus;
- (void)releasePointerLock;
- (BOOL)isSidebarHUDVisible;

@property (nonatomic, copy) void (^onUserActivity)(void);
@property (nonatomic, copy) void (^onDashboardToggleRequested)(void);
@property (nonatomic, copy) void (^onSidebarHUDVisibilityChanged)(BOOL visible);
@property (nonatomic, copy) OPNStreamInputReadyProvider streamInputReadyProvider;
@property (nonatomic, copy) OPNStreamBooleanHandler streamMicrophoneEnabledHandler;
@property (nonatomic, copy) OPNStreamDoubleHandler streamGameVolumeHandler;
@property (nonatomic, copy) OPNStreamDoubleHandler streamMicrophoneVolumeHandler;
@property (nonatomic, copy) OPNStreamIntegerHandler streamMaxBitrateHandler;
@property (nonatomic, copy) OPNStreamBooleanHandler streamEnhancedVideoCaptureHandler;
@property (nonatomic, copy) OPNStreamVideoEnhancementHandler streamVideoEnhancementHandler;
@property (nonatomic, copy) OPNStreamTextHandler streamUtf8TextHandler;
@property (nonatomic, copy) OPNStreamKeyEventHandler streamKeyEventHandler;
@property (nonatomic, copy) OPNStreamMouseMoveHandler streamMouseMoveHandler;
@property (nonatomic, copy) OPNStreamMouseButtonHandler streamMouseButtonHandler;
@property (nonatomic, copy) OPNStreamMouseWheelHandler streamMouseWheelHandler;
@property (nonatomic, copy) OPNStreamGamepadStateHandler streamGamepadStateHandler;

- (void)clearStreamCallbacks;
- (void)receiveMicrophoneLevel:(double)level;
- (void)receiveVideoFrame:(void *)frame;
- (void)receiveEnhancedVideoFrame:(void *)pixelBuffer;
- (void)receiveGameAudioFrame:(const void *)audioBufferList frameCount:(uint32_t)frameCount sampleRate:(double)sampleRate channels:(uint32_t)channels;
- (void)receiveClipboardText:(NSString *)text;

@end
