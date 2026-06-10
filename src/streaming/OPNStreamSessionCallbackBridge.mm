#import <Cocoa/Cocoa.h>
#import <AudioToolbox/AudioToolbox.h>

#include "OPNStreamSession.h"
#include "OPNStreamSessionInputBridge.h"
#include <string>

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
typedef void (^OPNStreamVideoEnhancementHandler)(NSInteger mode, NSInteger sharpness, NSInteger denoise, NSInteger targetHeight);

@class OPNStreamRecordingManager;

@interface OPNStreamRecordingManager : NSObject
- (void)appendWebRTCAudioBufferList:(const AudioBufferList *)audioBufferList frameCount:(UInt32)frameCount sampleRate:(double)sampleRate channels:(UInt32)channels;
@end

@interface OPNStreamView : NSView
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
- (void)receiveClipboardText:(NSString *)text;
@end

void OPNClearStreamSessionCallbacks(OPN::IStreamSession *session) {
    if (!session) return;
    session->OnVideoFrame(OPN::VideoFrameCallback{});
    session->OnEnhancedVideoFrame(OPN::VideoFrameCallback{});
    session->OnGameAudioFrame(OPN::GameAudioFrameCallback{});
    session->OnMicrophoneLevel(OPN::MicrophoneLevelCallback{});
    session->OnClipboardText(OPN::ClipboardTextCallback{});
}

void OPNConfigureStreamViewSessionCallbacks(OPN::IStreamSession *session, OPNStreamView *streamView, OPNStreamRecordingManager *recordingManager) {
    if (!streamView) return;
    [streamView clearStreamCallbacks];
    if (!session) return;

    __weak OPNStreamView *weakView = streamView;
    OPN::IStreamSession *capturedSession = session;

    streamView.streamInputReadyProvider = ^BOOL{
        return capturedSession && capturedSession->InputReady();
    };
    streamView.streamMicrophoneEnabledHandler = ^(BOOL enabled) {
        if (capturedSession) capturedSession->SetMicrophoneEnabled(enabled ? true : false);
    };
    streamView.streamGameVolumeHandler = ^(double volume) {
        if (capturedSession) capturedSession->SetGameVolume(volume);
    };
    streamView.streamMicrophoneVolumeHandler = ^(double volume) {
        if (capturedSession) capturedSession->SetMicrophoneVolume(volume);
    };
    streamView.streamMaxBitrateHandler = ^(NSInteger mbps) {
        if (capturedSession) capturedSession->SetMaxBitrateMbps((int)mbps);
    };
    streamView.streamEnhancedVideoCaptureHandler = ^(BOOL enabled) {
        if (capturedSession) capturedSession->SetEnhancedVideoFrameCaptureEnabled(enabled ? true : false);
    };
    streamView.streamVideoEnhancementHandler = ^(NSInteger mode, NSInteger sharpness, NSInteger denoise, NSInteger targetHeight) {
        if (capturedSession) capturedSession->SetLocalVideoEnhancement((int)mode, (int)sharpness, (int)denoise, (int)targetHeight);
    };
    streamView.streamUtf8TextHandler = ^(NSString *text) {
        if (capturedSession) capturedSession->SendUtf8Text(std::string(text.UTF8String ?: ""));
    };
    streamView.streamKeyEventHandler = ^(uint16_t keycode, uint16_t scancode, uint16_t modifiers, BOOL down) {
        if (capturedSession) capturedSession->SendKeyEvent(keycode, scancode, modifiers, down ? true : false);
    };
    streamView.streamMouseMoveHandler = ^(int16_t dx, int16_t dy) {
        if (capturedSession) capturedSession->SendMouseMove(dx, dy);
    };
    streamView.streamMouseButtonHandler = ^(uint8_t button, BOOL down) {
        if (capturedSession) capturedSession->SendMouseButton(button, down ? true : false);
    };
    streamView.streamMouseWheelHandler = ^(int16_t delta) {
        if (capturedSession) capturedSession->SendMouseWheel(delta);
    };
    streamView.streamGamepadStateHandler = ^(uint16_t controllerId, uint16_t buttons, uint8_t leftTrigger, uint8_t rightTrigger, int16_t leftStickX, int16_t leftStickY, int16_t rightStickX, int16_t rightStickY, BOOL connected, uint16_t bitmap, uint64_t timestampUs) {
        OPNSendStreamSessionGamepadState(capturedSession,
                                         controllerId,
                                         buttons,
                                         leftTrigger,
                                         rightTrigger,
                                         leftStickX,
                                         leftStickY,
                                         rightStickX,
                                         rightStickY,
                                         connected ? true : false,
                                         bitmap,
                                         timestampUs);
    };
    session->OnMicrophoneLevel([weakView](double level) {
        dispatch_async(dispatch_get_main_queue(), ^{
            OPNStreamView *view = weakView;
            if (!view) return;
            [view receiveMicrophoneLevel:level];
        });
    });
    session->OnVideoFrame([weakView](void *frame) {
        OPNStreamView *view = weakView;
        if (!view) return;
        [view receiveVideoFrame:frame];
    });
    session->OnEnhancedVideoFrame([weakView](void *pixelBuffer) {
        OPNStreamView *view = weakView;
        if (!view) return;
        [view receiveEnhancedVideoFrame:pixelBuffer];
    });
    session->OnGameAudioFrame([weakView, recordingManager](const void *audioBufferList, uint32_t frameCount, double sampleRate, uint32_t channels) {
        OPNStreamView *view = weakView;
        if (!view || !audioBufferList) return;
        [recordingManager appendWebRTCAudioBufferList:static_cast<const AudioBufferList *>(audioBufferList) frameCount:frameCount sampleRate:sampleRate channels:channels];
    });
    session->OnClipboardText([weakView](const std::string &text) {
        std::string textCopy = text;
        dispatch_async(dispatch_get_main_queue(), ^{
            OPNStreamView *view = weakView;
            if (!view) return;
            NSString *clipboardText = [[NSString alloc] initWithBytes:textCopy.data() length:textCopy.size() encoding:NSUTF8StringEncoding];
            [view receiveClipboardText:clipboardText ?: @""];
        });
    });
}
