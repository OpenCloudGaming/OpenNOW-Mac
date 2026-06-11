#pragma once

#include "OPNStreamSession.h"
#include "OPNStreamStats.h"
#include "OPNStreamTypes.h"
#include <memory>
#include <mutex>
#include <string>
#include <atomic>

namespace OPN {

class LibWebRTCStreamSession final : public IStreamSession {
public:
    LibWebRTCStreamSession();
    ~LibWebRTCStreamSession() override;

    static bool IsAvailable();
    static std::string AvailabilityDescription();

    void Start(const SessionInfo &session,
               const std::string &offerSdp,
               const StreamSettings &settings,
               StreamStateCallback onState) override;
    void Stop() override;
    void AddRemoteIceCandidate(const IceCandidatePayload &candidate) override;
    void OnAnswerReady(std::function<void(const SendAnswerRequest &)> cb) override;
    void OnIceCandidateReady(std::function<void(const IceCandidatePayload &)> cb) override;
    void SendInput(const uint8_t *data, size_t len) override;
    void SendInputPartiallyReliable(const uint8_t *data, size_t len) override;
    void CreateInputChannel() override;
    bool InputReady() const override;
    void SendKeyEvent(uint16_t keycode, uint16_t scancode, uint16_t modifiers, bool down) override;
    void SendMouseMove(int16_t dx, int16_t dy) override;
    void SendMouseButton(uint8_t button, bool down) override;
    void SendMouseWheel(int16_t delta) override;
    void SendGamepadState(const Input::GamepadState &state, uint16_t bitmap) override;
    void SendUtf8Text(const std::string &text) override;
    void SetMicrophoneEnabled(bool enabled) override;
    void SetGameVolume(double volume) override;
    void SetMicrophoneVolume(double volume) override;
    void SetMaxBitrateMbps(int mbps) override;
    void SetLocalVideoEnhancement(int mode, int sharpness, int denoise, int targetHeight) override;
    void SetEnhancedVideoFrameCaptureEnabled(bool enabled) override;
    void OnMicrophoneLevel(MicrophoneLevelCallback cb) override;
    void OnVideoFrame(VideoFrameCallback cb) override;
    void OnEnhancedVideoFrame(VideoFrameCallback cb) override;
    void OnGameAudioFrame(GameAudioFrameCallback cb) override;
    void OnClipboardText(ClipboardTextCallback cb) override;
    void RefreshAudioDevices() override;
    void RequestStats() override;
    StreamStats GetLatestStats() const override;
    void *NativeWindowHandle() const override;
    void SetNativeWindow(void *wnd) override;

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
