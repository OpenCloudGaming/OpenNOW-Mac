#include "OPNLibWebRTCStreamSession.h"
#include "OPNLibWebRTCSessionImpl.h"
#include "OPNWebRTCSdpUtils.h"
#include "OPNWebRTCStatsHelpers.h"

#import <Foundation/Foundation.h>

#if defined(OPN_HAVE_LIBWEBRTC)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-umbrella"
#import <WebRTC/WebRTC.h>
#pragma clang diagnostic pop
#endif

#include <algorithm>
#include <chrono>
#include <cctype>
#include <cmath>
#include <cstdlib>
#include <mutex>
#include <string>
#include <unordered_map>

namespace OPN {

#if defined(OPN_HAVE_LIBWEBRTC)
static OPNLibWebRTCSessionImpl *OPNImplFromOpaque(void *opaque) {
    return (__bridge OPNLibWebRTCSessionImpl *)opaque;
}
#endif

static std::string OPNNSStringToString(NSString *value) {
    return value ? std::string(value.UTF8String ?: "") : std::string();
}

static uint64_t OPNMonotonicMs() {
    using Clock = std::chrono::steady_clock;
    return (uint64_t)std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now().time_since_epoch()).count();
}

static double OPNStatsSecondsToMs(double seconds) {
    return seconds * 1000.0;
}

static bool OPNEnvFlagEnabled(const char *name, bool defaultValue) {
    const char *value = getenv(name);
    if (!value || !*value) return defaultValue;
    std::string normalized(value);
    std::transform(normalized.begin(), normalized.end(), normalized.begin(), [](unsigned char c) { return (char)std::tolower(c); });
    return !(normalized == "0" || normalized == "false" || normalized == "no" || normalized == "off");
}

void LibWebRTCStreamSession::RequestStats() {
#if defined(OPN_HAVE_LIBWEBRTC)
    if (!OPNEnvFlagEnabled("OPN_ENABLE_WEBRTC_STATS", true)) {
        return;
    }

    OPNLibWebRTCSessionImpl *impl = OPNImplFromOpaque(m_impl);
    if (!impl.peerConnection) return;
    {
        std::lock_guard<std::mutex> lock(m_statsMutex);
        uint64_t nowMs = OPNMonotonicMs();
        if (m_lastStatsRequestMs > 0 && nowMs - m_lastStatsRequestMs < 900) return;
        if (m_statsRequestInFlight) return;
        m_lastStatsRequestMs = nowMs;
        m_statsRequestInFlight = true;
    }

    dispatch_queue_t statsQueue = m_statsQueue ? (__bridge dispatch_queue_t)m_statsQueue : dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    [impl.peerConnection statisticsWithCompletionHandler:^(RTCStatisticsReport *report) {
        dispatch_async(statsQueue, ^{
            this->HandleStatsReport((__bridge void *)report);
        });
    }];
#endif
}

void LibWebRTCStreamSession::StartStatsPolling() {
#if defined(OPN_HAVE_LIBWEBRTC)
    if (m_statsTimer) return;
    dispatch_queue_t statsQueue = m_statsQueue ? (__bridge dispatch_queue_t)m_statsQueue : dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, statsQueue);
    if (!timer) return;

    m_statsTimer = (__bridge_retained void *)timer;
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              1 * NSEC_PER_SEC,
                              100 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        this->RequestStats();
    });
    dispatch_resume(timer);
    OPNLogInfo(@"[LibWebRTC] stats polling started");
#endif
}

void LibWebRTCStreamSession::StopStatsPolling() {
    if (!m_statsTimer) return;
    dispatch_source_t timer = (__bridge_transfer dispatch_source_t)m_statsTimer;
    m_statsTimer = nullptr;
    dispatch_source_cancel(timer);
    std::lock_guard<std::mutex> lock(m_statsMutex);
    m_statsRequestInFlight = false;
}

StreamStats LibWebRTCStreamSession::GetLatestStats() const {
    std::lock_guard<std::mutex> lock(m_statsMutex);
    return m_latestStats;
}

void LibWebRTCStreamSession::HandleStatsReport(void *report) {
#if defined(OPN_HAVE_LIBWEBRTC)
    RTCStatisticsReport *statsReport = (__bridge RTCStatisticsReport *)report;
    if (!statsReport) {
        std::lock_guard<std::mutex> lock(m_statsMutex);
        m_statsRequestInFlight = false;
        return;
    }

    auto statIsVideo = [&](RTCStatistics *stat) -> bool {
        NSString *mediaType = OPNRTCStatsStringForKey(stat.values, @"mediaType");
        NSString *kind = OPNRTCStatsStringForKey(stat.values, @"kind");
        NSString *trackKind = OPNRTCStatsStringForKey(stat.values, @"trackKind");
        if ([mediaType isEqualToString:@"video"] || [kind isEqualToString:@"video"] || [trackKind isEqualToString:@"video"]) return true;
        return OPNRTCStatsNumberForKey(stat.values, @"framesDecoded") || OPNRTCStatsNumberForKey(stat.values, @"framesReceived");
    };

    std::unordered_map<std::string, std::string> codecs;
    StreamStats parsed;
    {
        std::lock_guard<std::mutex> lock(m_statsMutex);
        parsed = m_latestStats;
    }
    parsed.available = false;
    parsed.latencyMs = -1.0;
    parsed.jitterMs = -1.0;
    parsed.inboundBitrateMbps = -1.0;
    parsed.packetLossPercent = -1.0;
    parsed.decodeTimeMs = -1.0;
    parsed.renderFps = -1.0;
    parsed.bytesReceived = 0;
    parsed.packetsReceived = 0;
    parsed.packetsLost = 0;
    parsed.framesReceived = 0;
    parsed.framesDecoded = 0;
    parsed.framesDropped = 0;
    parsed.timestampMs = OPNMonotonicMs();
    parsed.videoDecoder = "libwebrtc";
    if (parsed.videoSink.empty()) {
        parsed.videoSink = "OPNMetalVideoView";
    }
    if (parsed.videoPipelineMode.empty()) {
        parsed.videoPipelineMode = "libwebrtc Metal display";
    }

    std::string inboundCodecId;
    uint64_t selectedVideoScore = 0;
    for (RTCStatistics *stat in statsReport.statistics.allValues) {
        if ([stat.type isEqualToString:@"codec"]) {
            NSString *mimeType = OPNRTCStatsStringForKey(stat.values, @"mimeType");
            if (mimeType.length > 0) codecs[OPNNSStringToString(stat.id)] = OPNNSStringToString(mimeType);
            continue;
        }

        if ([stat.type isEqualToString:@"candidate-pair"]) {
            NSNumber *nominated = OPNRTCStatsNumberForKey(stat.values, @"nominated");
            NSString *state = OPNRTCStatsStringForKey(stat.values, @"state");
            NSNumber *rtt = OPNRTCStatsNumberForKey(stat.values, @"currentRoundTripTime") ?: OPNRTCStatsNumberForKey(stat.values, @"roundTripTime");
            if ((!nominated || nominated.boolValue) && (!state || [state isEqualToString:@"succeeded"]) && rtt) {
                parsed.latencyMs = OPNStatsSecondsToMs(rtt.doubleValue);
                parsed.available = true;
            }
            continue;
        }

        if (![stat.type isEqualToString:@"inbound-rtp"] || !statIsVideo(stat)) continue;

        NSNumber *jitter = OPNRTCStatsNumberForKey(stat.values, @"jitter");
        NSNumber *packetsReceived = OPNRTCStatsNumberForKey(stat.values, @"packetsReceived");
        NSNumber *packetsLost = OPNRTCStatsNumberForKey(stat.values, @"packetsLost");
        NSNumber *bytesReceived = OPNRTCStatsNumberForKey(stat.values, @"bytesReceived");
        NSNumber *framesReceived = OPNRTCStatsNumberForKey(stat.values, @"framesReceived");
        NSNumber *framesDecoded = OPNRTCStatsNumberForKey(stat.values, @"framesDecoded");
        NSNumber *framesDropped = OPNRTCStatsNumberForKey(stat.values, @"framesDropped");
        NSNumber *framesPerSecond = OPNRTCStatsNumberForKey(stat.values, @"framesPerSecond");
        NSNumber *frameWidth = OPNRTCStatsNumberForKey(stat.values, @"frameWidth") ?: OPNRTCStatsNumberForKey(stat.values, @"width");
        NSNumber *frameHeight = OPNRTCStatsNumberForKey(stat.values, @"frameHeight") ?: OPNRTCStatsNumberForKey(stat.values, @"height");
        NSNumber *totalDecodeTime = OPNRTCStatsNumberForKey(stat.values, @"totalDecodeTime");
        NSString *codecId = OPNRTCStatsStringForKey(stat.values, @"codecId");

        uint64_t videoScore = bytesReceived ? bytesReceived.unsignedLongLongValue : 0;
        if (videoScore == 0 && framesDecoded) videoScore = framesDecoded.unsignedLongLongValue;
        if (videoScore == 0 && framesReceived) videoScore = framesReceived.unsignedLongLongValue;
        if (videoScore < selectedVideoScore) {
            parsed.available = true;
            continue;
        }
        selectedVideoScore = videoScore;

        uint64_t selectedFramesDecoded = framesDecoded ? framesDecoded.unsignedLongLongValue : 0;
        if (jitter) parsed.jitterMs = OPNStatsSecondsToMs(jitter.doubleValue);
        if (packetsReceived) parsed.packetsReceived = packetsReceived.unsignedLongLongValue;
        if (packetsLost) parsed.packetsLost = packetsLost.longLongValue;
        if (bytesReceived) parsed.bytesReceived = bytesReceived.unsignedLongLongValue;
        if (framesReceived) parsed.framesReceived = framesReceived.unsignedLongLongValue;
        if (framesDecoded) parsed.framesDecoded = selectedFramesDecoded;
        if (framesDropped) parsed.framesDropped = framesDropped.unsignedLongLongValue;
        if (frameWidth && frameHeight && frameWidth.intValue > 0 && frameHeight.intValue > 0) {
            parsed.resolution = std::to_string(frameWidth.intValue) + "x" + std::to_string(frameHeight.intValue);
        }
        if (framesPerSecond && framesPerSecond.doubleValue > 0) parsed.renderFps = framesPerSecond.doubleValue;
        if (totalDecodeTime && totalDecodeTime.doubleValue > 0 && selectedFramesDecoded > 0) {
            parsed.decodeTimeMs = OPNStatsSecondsToMs(totalDecodeTime.doubleValue) / (double)selectedFramesDecoded;
        }
        if (codecId.length > 0) inboundCodecId = OPNNSStringToString(codecId);
        parsed.available = true;
    }

    if (!inboundCodecId.empty()) {
        auto codec = codecs.find(inboundCodecId);
        parsed.codec = OPNNormalizeStatsCodecName(codec != codecs.end() ? codec->second : inboundCodecId);
    }

    {
        std::lock_guard<std::mutex> lock(m_statsMutex);
        if (parsed.bytesReceived > 0 && m_previousBytesReceived > 0 && parsed.timestampMs > m_previousStatsTimestampMs) {
            uint64_t deltaBytes = parsed.bytesReceived >= m_previousBytesReceived ? parsed.bytesReceived - m_previousBytesReceived : 0;
            uint64_t deltaFramesDecoded = parsed.framesDecoded >= m_previousFramesDecoded ? parsed.framesDecoded - m_previousFramesDecoded : 0;
            double deltaSeconds = (double)(parsed.timestampMs - m_previousStatsTimestampMs) / 1000.0;
            if (deltaSeconds > 0.0) {
                parsed.inboundBitrateMbps = ((double)deltaBytes * 8.0) / (deltaSeconds * 1000000.0);
                if (parsed.renderFps < 0.0) parsed.renderFps = (double)deltaFramesDecoded / deltaSeconds;
            }
        }
        if (m_previousPacketsReceived > 0 || m_previousPacketsLost > 0) {
            uint64_t packetsDelta = parsed.packetsReceived >= m_previousPacketsReceived ? parsed.packetsReceived - m_previousPacketsReceived : 0;
            int64_t lostDelta = parsed.packetsLost - m_previousPacketsLost;
            if (packetsDelta > 0) {
                double totalPackets = (double)packetsDelta + (double)lostDelta;
                parsed.packetLossPercent = totalPackets > 0.0 ? ((double)lostDelta * 100.0) / totalPackets : 0.0;
            }
        }
        if (parsed.bytesReceived > 0) {
            m_previousBytesReceived = parsed.bytesReceived;
            m_previousStatsTimestampMs = parsed.timestampMs;
        }
        if (parsed.packetsReceived > 0 || parsed.packetsLost > 0) {
            m_previousPacketsReceived = parsed.packetsReceived;
            m_previousPacketsLost = parsed.packetsLost;
        }
        if (parsed.framesDecoded > 0) {
            m_previousFramesDecoded = parsed.framesDecoded;
        }
        m_latestStats = parsed;
        m_statsRequestInFlight = false;
    }
    UpdateAdaptiveBitrate(parsed);
#else
    (void)report;
#endif
}

void LibWebRTCStreamSession::HandleMicrophoneLevelReport(void *report) {
#if defined(OPN_HAVE_LIBWEBRTC)
    RTCStatisticsReport *statsReport = (__bridge RTCStatisticsReport *)report;
    double level = statsReport ? OPNMicrophoneLevelFromStatsReport(statsReport) : -1.0;
    m_microphoneLevelRequestInFlight = false;
    if (level >= 0.0 && m_onMicrophoneLevel) {
        m_onMicrophoneLevel(level * m_microphoneVolumeLevel);
    }
#else
    (void)report;
#endif
}

void LibWebRTCStreamSession::ApplyRuntimeBitrateLimit(int mbps, const char *reason) {
    (void)reason;
    int clampedMbps = std::max(1, std::min(mbps, 250));
    {
        std::lock_guard<std::mutex> lock(m_statsMutex);
        m_latestStats.videoPipelineMode = "libwebrtc bitrate " + std::to_string(clampedMbps) + " Mbps";
    }
#if defined(OPN_HAVE_LIBWEBRTC)
    OPNLibWebRTCSessionImpl *impl = OPNImplFromOpaque(m_impl);
    if (!impl.peerConnection) return;
    NSNumber *maxBitrateBps = @(clampedMbps * 1000 * 1000);
    NSNumber *currentBitrateBps = @(std::max(1, clampedMbps * 7 / 10) * 1000 * 1000);
    NSNumber *minBitrateBps = @(std::max(1, clampedMbps * 35 / 100) * 1000 * 1000);
    BOOL ok = [impl.peerConnection setBweMinBitrateBps:minBitrateBps
                                       currentBitrateBps:currentBitrateBps
                                           maxBitrateBps:maxBitrateBps];
    OPNLogInfo(@"[LibWebRTC] Runtime bitrate limit %d Mbps applied=%d reason=%s", clampedMbps, ok, reason ? reason : "manual");
#endif
}

void LibWebRTCStreamSession::SetMaxBitrateMbps(int mbps) {
    int clampedMbps = std::max(1, std::min(mbps, 250));
    {
        std::lock_guard<std::mutex> lock(m_statsMutex);
        m_settings.maxBitrateMbps = clampedMbps;
        m_configuredMaxBitrateMbps = clampedMbps;
        m_adaptiveBitrateMbps = clampedMbps;
        m_minAdaptiveBitrateMbps = std::min(clampedMbps, std::max(8, clampedMbps * 35 / 100));
        m_adaptiveCongestionScore = 0;
        m_adaptiveRecoveryScore = 0;
    }
    ApplyRuntimeBitrateLimit(clampedMbps, "manual");
}

void LibWebRTCStreamSession::UpdateAdaptiveBitrate(const StreamStats &stats) {
    if (!stats.available) return;

    int bitrateToApply = 0;
    const char *reason = nullptr;
    {
        std::lock_guard<std::mutex> lock(m_statsMutex);
        const int configuredMax = std::max(1, m_configuredMaxBitrateMbps > 0 ? m_configuredMaxBitrateMbps : m_settings.maxBitrateMbps);
        if (m_adaptiveBitrateMbps <= 0) m_adaptiveBitrateMbps = configuredMax;
        if (m_minAdaptiveBitrateMbps <= 0) m_minAdaptiveBitrateMbps = std::min(configuredMax, std::max(8, configuredMax * 35 / 100));

        const double targetFps = m_settings.fps > 0 ? (double)m_settings.fps : 60.0;
        const double frameBudgetMs = 1000.0 / targetFps;
        const bool lossHigh = stats.packetLossPercent >= 1.0;
        const bool jitterHigh = stats.jitterMs >= 25.0;
        const bool latencyHigh = stats.latencyMs >= 110.0;
        const bool decodeSlow = stats.decodeTimeMs >= frameBudgetMs * 0.90;
        const bool renderSlow = stats.renderFps > 0.0 && stats.renderFps < targetFps * 0.82;
        const bool congested = lossHigh || jitterHigh || latencyHigh || decodeSlow || renderSlow;
        const uint64_t nowMs = stats.timestampMs > 0 ? stats.timestampMs : OPNMonotonicMs();

        if (congested) {
            m_adaptiveCongestionScore = std::min(m_adaptiveCongestionScore + 1, 6);
            m_adaptiveRecoveryScore = 0;
        } else {
            m_adaptiveCongestionScore = std::max(0, m_adaptiveCongestionScore - 1);
            m_adaptiveRecoveryScore = std::min(m_adaptiveRecoveryScore + 1, 20);
        }

        const bool downCooldownElapsed = m_lastAdaptiveBitrateChangeMs == 0 || nowMs - m_lastAdaptiveBitrateChangeMs >= 2500;
        const bool upCooldownElapsed = m_lastAdaptiveBitrateChangeMs == 0 || nowMs - m_lastAdaptiveBitrateChangeMs >= 10000;
        if (m_adaptiveCongestionScore >= 2 && downCooldownElapsed && m_adaptiveBitrateMbps > m_minAdaptiveBitrateMbps) {
            int reduced = std::max(m_minAdaptiveBitrateMbps, (int)std::floor((double)m_adaptiveBitrateMbps * 0.82));
            if (reduced < m_adaptiveBitrateMbps) {
                m_adaptiveBitrateMbps = reduced;
                m_lastAdaptiveBitrateChangeMs = nowMs;
                m_adaptiveCongestionScore = 0;
                bitrateToApply = reduced;
                reason = "adaptive-congestion";
            }
        } else if (m_adaptiveRecoveryScore >= 10 && upCooldownElapsed && m_adaptiveBitrateMbps < configuredMax) {
            int increased = std::min(configuredMax, std::max(m_adaptiveBitrateMbps + 1, (int)std::ceil((double)m_adaptiveBitrateMbps * 1.10)));
            if (increased > m_adaptiveBitrateMbps) {
                m_adaptiveBitrateMbps = increased;
                m_lastAdaptiveBitrateChangeMs = nowMs;
                m_adaptiveRecoveryScore = 0;
                bitrateToApply = increased;
                reason = "adaptive-recovery";
            }
        }
    }

    if (bitrateToApply > 0) {
        ApplyRuntimeBitrateLimit(bitrateToApply, reason);
    }
}

void LibWebRTCStreamSession::SetLocalVideoEnhancement(int mode, int sharpness, int denoise, int targetHeight) {
    std::lock_guard<std::mutex> lock(m_statsMutex);
    m_localEnhancementMode = std::max(0, std::min(mode, 4));
    m_localEnhancementSharpness = std::max(0, std::min(sharpness, 40));
    m_localEnhancementDenoise = std::max(0, std::min(denoise, 20));
    m_localEnhancementTargetHeight = std::max(1440, std::min(targetHeight, 2160));
}

void LibWebRTCStreamSession::SetEnhancedVideoFrameCaptureEnabled(bool enabled) {
    std::lock_guard<std::mutex> lock(m_statsMutex);
    m_enhancedVideoFrameCaptureEnabled = enabled;
}

void LibWebRTCStreamSession::HandleVideoFrame(void *frame) {
#if defined(OPN_HAVE_LIBWEBRTC)
    RTCVideoFrame *videoFrame = (__bridge RTCVideoFrame *)frame;
    if (videoFrame && videoFrame.width > 0 && videoFrame.height > 0) {
        std::string frameResolution = std::to_string(videoFrame.width) + "x" + std::to_string(videoFrame.height);
        std::lock_guard<std::mutex> lock(m_statsMutex);
        m_latestStats.resolution = frameResolution;
    }
#else
    (void)frame;
#endif
    if (m_onVideoFrame) m_onVideoFrame(frame);
}

void LibWebRTCStreamSession::HandleEnhancedVideoFrame(void *pixelBuffer) {
    if (m_onEnhancedVideoFrame) m_onEnhancedVideoFrame(pixelBuffer);
}

bool LibWebRTCStreamSession::WantsEnhancedVideoFrames() const {
    std::lock_guard<std::mutex> lock(m_statsMutex);
    return m_enhancedVideoFrameCaptureEnabled && (bool)m_onEnhancedVideoFrame;
}

void LibWebRTCStreamSession::LocalVideoEnhancement(int &mode, int &sharpness, int &denoise, int &targetHeight) const {
    std::lock_guard<std::mutex> lock(m_statsMutex);
    mode = m_localEnhancementMode;
    sharpness = m_localEnhancementSharpness;
    denoise = m_localEnhancementDenoise;
    targetHeight = m_localEnhancementTargetHeight;
}

void LibWebRTCStreamSession::SetVideoRendererState(const std::string &sink, const std::string &pipelineMode) {
    std::lock_guard<std::mutex> lock(m_statsMutex);
    m_latestStats.videoSink = sink;
    if (!pipelineMode.empty()) {
        m_latestStats.videoPipelineMode = pipelineMode;
    }
}

void LibWebRTCStreamSession::SetVideoRenderDiagnostics(const std::string &pixelFormat,
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
                                                       uint64_t enhancementDroppedFrames) {
    std::lock_guard<std::mutex> lock(m_statsMutex);
    m_latestStats.videoPixelFormat = pixelFormat;
    m_latestStats.videoRenderMode = renderMode;
    m_latestStats.videoFrameSource = frameSource;
    m_latestStats.videoRenderPath = renderPath;
    m_latestStats.videoRendererFallback = fallback;
    m_latestStats.videoEnhancementConfiguredTier = enhancementConfiguredTier;
    m_latestStats.videoEnhancementActiveTier = enhancementActiveTier;
    m_latestStats.videoEnhancementFallbackReason = enhancementFallbackReason;
    m_latestStats.videoEnhancementSourceResolution = enhancementSourceResolution;
    m_latestStats.videoEnhancementDrawableResolution = enhancementDrawableResolution;
    m_latestStats.videoEnhancementDiagnostics = enhancementDiagnostics;
    m_latestStats.videoEnhancementFrameTimeMs = enhancementFrameTimeMs;
    m_latestStats.videoEnhancementDroppedFrames = enhancementDroppedFrames;
}

}
