#include "OPNLibWebRTCStreamSession.h"

#import <Foundation/Foundation.h>

#include <algorithm>
#include <mutex>
#include <utility>

namespace OPN {

void LibWebRTCStreamSession::OnAnswerReady(std::function<void(const SendAnswerRequest &)> cb) {
    m_onAnswer = std::move(cb);
}

void LibWebRTCStreamSession::OnIceCandidateReady(std::function<void(const IceCandidatePayload &)> cb) {
    m_onIceCandidate = std::move(cb);
}

void LibWebRTCStreamSession::OnMicrophoneLevel(MicrophoneLevelCallback cb) {
    m_onMicrophoneLevel = std::move(cb);
}

void LibWebRTCStreamSession::OnVideoFrame(VideoFrameCallback cb) {
    m_onVideoFrame = std::move(cb);
}

void LibWebRTCStreamSession::OnEnhancedVideoFrame(VideoFrameCallback cb) {
    m_onEnhancedVideoFrame = std::move(cb);
}

void LibWebRTCStreamSession::OnGameAudioFrame(GameAudioFrameCallback cb) {
    m_onGameAudioFrame = std::move(cb);
}

void LibWebRTCStreamSession::OnClipboardText(ClipboardTextCallback cb) {
    m_onClipboardText = std::move(cb);
}

void LibWebRTCStreamSession::HandleGameAudioFrame(const void *audioBufferList, uint32_t frameCount, double sampleRate, uint32_t channels) {
    if (m_onGameAudioFrame) m_onGameAudioFrame(audioBufferList, frameCount, sampleRate, channels);
}

void *LibWebRTCStreamSession::NativeWindowHandle() const {
    return m_nativeWindow;
}

void LibWebRTCStreamSession::SetNativeWindow(void *wnd) {
    m_nativeWindow = wnd;
}

void LibWebRTCStreamSession::HandleLocalIceCandidate(const IceCandidatePayload &candidate) {
    if (m_onIceCandidate) {
        m_onIceCandidate(candidate);
    }
}

void LibWebRTCStreamSession::HandleConnectionState(bool connected, const std::string &error) {
    if (connected) {
        CancelDisconnectGraceTimer();
        {
            std::lock_guard<std::mutex> lock(m_statsMutex);
            m_latestStats.available = true;
            m_latestStats.videoPipelineMode = "libwebrtc connected";
        }
        StartStatsPolling();
    } else {
        StopStatsPolling();
    }
    if (m_onState) {
        m_onState(connected, error);
    }
}

void LibWebRTCStreamSession::StartDisconnectGraceTimer(const std::string &reason) {
    NSCAssert([NSThread isMainThread], @"disconnect grace timer must be accessed on main thread");
    CancelDisconnectGraceTimer();
    auto callbackLiveness = m_callbackLiveness;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (!timer) {
        HandleConnectionState(false, reason);
        return;
    }

    static constexpr int64_t OPNLibWebRTCDisconnectGraceMs = 3000;
    void *timerToken = (__bridge_retained void *)timer;
    m_disconnectGraceTimer = timerToken;
    std::string reasonCopy = reason;
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, OPNLibWebRTCDisconnectGraceMs * NSEC_PER_MSEC),
                              DISPATCH_TIME_FOREVER,
                              0);
    dispatch_source_set_event_handler(timer, ^{
        if (callbackLiveness && !callbackLiveness->load()) return;
        if (m_disconnectGraceTimer != timerToken) return;
        dispatch_source_t firedTimer = (__bridge_transfer dispatch_source_t)m_disconnectGraceTimer;
        m_disconnectGraceTimer = nullptr;
        dispatch_source_cancel(firedTimer);
        OPNLogInfo(@"[LibWebRTC] disconnect grace expired after %lldms: %s", (long long)OPNLibWebRTCDisconnectGraceMs, reasonCopy.c_str());
        HandleConnectionState(false, reasonCopy);
    });
    dispatch_resume(timer);
}

void LibWebRTCStreamSession::CancelDisconnectGraceTimer() {
    NSCAssert([NSThread isMainThread], @"disconnect grace timer must be accessed on main thread");
    if (!m_disconnectGraceTimer) return;
    dispatch_source_t timer = (__bridge_transfer dispatch_source_t)m_disconnectGraceTimer;
    m_disconnectGraceTimer = nullptr;
    dispatch_source_cancel(timer);
}

int LibWebRTCStreamSession::TargetFps() const {
    return std::max(30, std::min(m_settings.fps > 0 ? m_settings.fps : 60, 240));
}

bool LibWebRTCStreamSession::LowLatencyMode() const {
    return m_settings.lowLatencyMode;
}

}
