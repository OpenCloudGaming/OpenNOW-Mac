#pragma once

#include "OPNStreamStats.h"
#include "OPNStreamTypes.h"
#include <memory>
#include <mutex>
#include <string>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <functional>

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

using StreamStateCallback = std::function<void(bool connected, const std::string &error)>;
using MicrophoneLevelCallback = std::function<void(double level)>;
using VideoFrameCallback = std::function<void(void *frame)>;
using GameAudioFrameCallback = std::function<void(const void *audioBufferList, uint32_t frameCount, double sampleRate, uint32_t channels)>;
using ClipboardTextCallback = std::function<void(const std::string &text)>;

class LibWebRTCStreamSession final {
public:
    LibWebRTCStreamSession();
    ~LibWebRTCStreamSession();

    static bool IsAvailable();
    static std::string AvailabilityDescription();

    void Start(const SessionInfo &session,
               const std::string &offerSdp,
               const StreamSettings &settings,
               StreamStateCallback onState);
    void Stop();
    void AddRemoteIceCandidate(const IceCandidatePayload &candidate);
    void OnAnswerReady(std::function<void(const SendAnswerRequest &)> cb);
    void OnIceCandidateReady(std::function<void(const IceCandidatePayload &)> cb);
    void SendInput(const uint8_t *data, size_t len);
    void SendInputPartiallyReliable(const uint8_t *data, size_t len);
    void CreateInputChannel();
    bool InputReady() const;
    void SendKeyEvent(uint16_t keycode, uint16_t scancode, uint16_t modifiers, bool down);
    void SendMouseMove(int16_t dx, int16_t dy);
    void SendMouseButton(uint8_t button, bool down);
    void SendMouseWheel(int16_t delta);
    void SendGamepadState(const Input::GamepadState &state, uint16_t bitmap);
    void SendUtf8Text(const std::string &text);
    void SetMicrophoneEnabled(bool enabled);
    void SetGameVolume(double volume);
    void SetMicrophoneVolume(double volume);
    void SetMaxBitrateMbps(int mbps);
    void SetLocalVideoEnhancement(int mode, int sharpness, int denoise, int targetHeight);
    void SetEnhancedVideoFrameCaptureEnabled(bool enabled);
    void OnMicrophoneLevel(MicrophoneLevelCallback cb);
    void OnVideoFrame(VideoFrameCallback cb);
    void OnEnhancedVideoFrame(VideoFrameCallback cb);
    void OnGameAudioFrame(GameAudioFrameCallback cb);
    void OnClipboardText(ClipboardTextCallback cb);
    void RefreshAudioDevices();
    void RequestStats();
    StreamStats GetLatestStats() const;
    void *NativeWindowHandle() const;
    void SetNativeWindow(void *wnd);

    void HandleLocalIceCandidate(const IceCandidatePayload &candidate);
    void HandleConnectionState(bool connected, const std::string &error);
    void StartDisconnectGraceTimer(const std::string &reason);
    void CancelDisconnectGraceTimer();
    void HandleDataChannelState(const std::string &label, bool open);
    void HandleDataChannelMessage(const std::string &label, const uint8_t *data, size_t len);
    void HandleClipboardText(const std::string &text);
    void HandleMicrophoneLevel(double level);
    void HandleStatsDictionary(void *stats);
    void HandleAudioDeviceChange();
    void HandleVideoFrame(void *frame);
    void HandleEnhancedVideoFrame(void *pixelBuffer);
    bool WantsEnhancedVideoFrames() const;
    void HandleGameAudioFrame(const void *audioBufferList, uint32_t frameCount, double sampleRate, uint32_t channels);
    double GameVolume() const;
    int TargetFps() const;
    bool LowLatencyMode() const;
    void LocalVideoEnhancement(int &mode, int &sharpness, int &denoise, int &targetHeight) const;
    void SetVideoRendererState(const std::string &sink, const std::string &pipelineMode);
    void SetVideoRenderDiagnostics(const std::string &pixelFormat,
                                   const std::string &renderMode,
                                   const std::string &frameSource,
                                   const std::string &renderPath,
                                   const std::string &fallback,
                                   const std::string &enhancementConfiguredTier,
                                   const std::string &enhancementActiveTier,
                                   const std::string &enhancementFallbackReason,
                                   const std::string &enhancementSourceResolution,
                                   const std::string &enhancementDrawableResolution,
                                   const std::string &enhancementDiagnostics,
                                   double enhancementFrameTimeMs,
                                   uint64_t enhancementDroppedFrames);

private:
    void StartStatsPolling();
    void StopStatsPolling();
    void StartMicrophoneLevelPolling();
    void StopMicrophoneLevelPolling();
    void StartAudioDeviceMonitoring();
    void StopAudioDeviceMonitoring();
    void ApplyRuntimeBitrateLimit(int mbps, const char *reason);
    void UpdateAdaptiveBitrate(const StreamStats &stats);

    void *m_impl = nullptr;
    void *m_nativeWindow = nullptr;
    void *m_disconnectGraceTimer = nullptr;
    void *m_statsQueue = nullptr;
    void *m_audioController = nullptr;
    void *m_statsController = nullptr;
    std::shared_ptr<std::atomic_bool> m_callbackLiveness;
    bool m_microphoneEnabled = false;
    double m_gameVolume = 1.0;
    double m_microphoneVolumeLevel = 1.0;
    StreamStats m_latestStats;
    mutable std::mutex m_statsMutex;
    uint64_t m_previousStatsTimestampMs = 0;
    uint64_t m_previousBytesReceived = 0;
    uint64_t m_previousPacketsReceived = 0;
    uint64_t m_previousFramesDecoded = 0;
    int64_t m_previousPacketsLost = 0;
    int m_configuredMaxBitrateMbps = 0;
    int m_localEnhancementMode = 1;
    int m_localEnhancementSharpness = 4;
    int m_localEnhancementDenoise = 0;
    int m_localEnhancementTargetHeight = 2160;
    bool m_enhancedVideoFrameCaptureEnabled = false;
    int m_adaptiveBitrateMbps = 0;
    int m_minAdaptiveBitrateMbps = 0;
    int m_adaptiveCongestionScore = 0;
    int m_adaptiveRecoveryScore = 0;
    uint64_t m_lastAdaptiveBitrateChangeMs = 0;
    StreamSettings m_settings;
    void *m_inputController = nullptr;
    std::function<void(const SendAnswerRequest &)> m_onAnswer;
    std::function<void(const IceCandidatePayload &)> m_onIceCandidate;
    StreamStateCallback m_onState;
    MicrophoneLevelCallback m_onMicrophoneLevel;
    VideoFrameCallback m_onVideoFrame;
    VideoFrameCallback m_onEnhancedVideoFrame;
    GameAudioFrameCallback m_onGameAudioFrame;
    ClipboardTextCallback m_onClipboardText;
};

}
