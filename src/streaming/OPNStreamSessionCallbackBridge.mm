#include "OPNStreamSessionCallbackBridge.h"

#import "OPNStreamView.h"
#include "OPNStreamSession.h"
#include "OPNStreamSessionInputBridge.h"

#include <string>

void OPNClearStreamSessionCallbacks(OPN::IStreamSession *session) {
    if (!session) return;
    session->OnVideoFrame(OPN::VideoFrameCallback{});
    session->OnEnhancedVideoFrame(OPN::VideoFrameCallback{});
    session->OnGameAudioFrame(OPN::GameAudioFrameCallback{});
    session->OnMicrophoneLevel(OPN::MicrophoneLevelCallback{});
    session->OnClipboardText(OPN::ClipboardTextCallback{});
}

void OPNConfigureStreamViewSessionCallbacks(OPN::IStreamSession *session, OPNStreamView *streamView) {
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
    session->OnGameAudioFrame([weakView](const void *audioBufferList, uint32_t frameCount, double sampleRate, uint32_t channels) {
        OPNStreamView *view = weakView;
        if (!view) return;
        [view receiveGameAudioFrame:audioBufferList frameCount:frameCount sampleRate:sampleRate channels:channels];
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
