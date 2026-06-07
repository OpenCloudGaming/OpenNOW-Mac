#pragma once

#import <Cocoa/Cocoa.h>

#ifdef __cplusplus
#include <string>
namespace OPN {
class IStreamSession;
}
#endif

@interface OPNStreamView : NSView

#ifdef __cplusplus
- (void)setStreamSession:(OPN::IStreamSession *)session;
- (void)setMicrophoneMode:(const std::string &)mode pushToTalkKeyCode:(uint16_t)keyCode modifierMask:(uint16_t)modifierMask;
#endif
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

@end
