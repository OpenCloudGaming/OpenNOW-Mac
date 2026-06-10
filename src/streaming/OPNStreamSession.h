#pragma once

#include <string>
#include <functional>
#include <cstddef>
#include <cstdint>

namespace OPN {

namespace Input {
constexpr int GAMEPAD_MAX_CONTROLLERS = 4;

struct GamepadState {
    uint16_t controllerId = 0;
    uint16_t buttons = 0;
    uint8_t leftTrigger = 0;
    uint8_t rightTrigger = 0;
    int16_t leftStickX = 0;
    int16_t leftStickY = 0;
    int16_t rightStickX = 0;
    int16_t rightStickY = 0;
    bool connected = false;
    uint64_t timestampUs = 0;
};
}

struct IceCandidatePayload;
struct SendAnswerRequest;
struct SessionInfo;
struct StreamSettings;
struct StreamStats;

using StreamStateCallback = std::function<void(bool connected, const std::string &error)>;
using MicrophoneLevelCallback = std::function<void(double level)>;
using VideoFrameCallback = std::function<void(void *frame)>;
using GameAudioFrameCallback = std::function<void(const void *audioBufferList, uint32_t frameCount, double sampleRate, uint32_t channels)>;
using ClipboardTextCallback = std::function<void(const std::string &text)>;

class IStreamSession {
public:
    virtual ~IStreamSession() = default;

    virtual void Start(const SessionInfo &session,
                       const std::string &offerSdp,
                       const StreamSettings &settings,
                       StreamStateCallback onState) = 0;
    virtual void Stop() = 0;
    virtual void AddRemoteIceCandidate(const IceCandidatePayload &candidate) = 0;
    virtual void OnAnswerReady(std::function<void(const SendAnswerRequest &)> cb) = 0;
    virtual void OnIceCandidateReady(std::function<void(const IceCandidatePayload &)> cb) = 0;
    virtual void SendInput(const uint8_t *data, size_t len) = 0;
    virtual void SendInputPartiallyReliable(const uint8_t *data, size_t len) = 0;
    virtual void CreateInputChannel() = 0;
    virtual bool InputReady() const = 0;
    virtual void SendKeyEvent(uint16_t keycode, uint16_t scancode, uint16_t modifiers, bool down) = 0;
    virtual void SendMouseMove(int16_t dx, int16_t dy) = 0;
    virtual void SendMouseButton(uint8_t button, bool down) = 0;
    virtual void SendMouseWheel(int16_t delta) = 0;
    virtual void SendGamepadState(const Input::GamepadState &state, uint16_t bitmap) = 0;
    virtual void SendUtf8Text(const std::string &text) = 0;
    virtual void SetMicrophoneEnabled(bool enabled) = 0;
    virtual void SetGameVolume(double volume) = 0;
    virtual void SetMicrophoneVolume(double volume) = 0;
    virtual void SetMaxBitrateMbps(int mbps) = 0;
    virtual void SetLocalVideoEnhancement(int mode, int sharpness, int denoise, int targetHeight) { (void)mode; (void)sharpness; (void)denoise; (void)targetHeight; }
    virtual void SetEnhancedVideoFrameCaptureEnabled(bool enabled) { (void)enabled; }
    virtual void OnMicrophoneLevel(MicrophoneLevelCallback cb) = 0;
    virtual void OnVideoFrame(VideoFrameCallback cb) = 0;
    virtual void OnEnhancedVideoFrame(VideoFrameCallback cb) { (void)cb; }
    virtual void OnGameAudioFrame(GameAudioFrameCallback cb) = 0;
    virtual void OnClipboardText(ClipboardTextCallback cb) = 0;
    virtual void RefreshAudioDevices() = 0;
    virtual void RequestStats() = 0;
    virtual StreamStats GetLatestStats() const = 0;
    virtual void *NativeWindowHandle() const = 0;
    virtual void SetNativeWindow(void *wnd) = 0;
};

}
