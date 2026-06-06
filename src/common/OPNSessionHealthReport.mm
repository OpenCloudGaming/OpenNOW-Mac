#include "OPNSessionHealthReport.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <sstream>

#import <Foundation/Foundation.h>

namespace OPN {
namespace {

static NSString *const kSessionReportDisplayModeKey = @"OpenNOW.SessionReport.DisplayMode";
static constexpr int kAutomaticReportDisplayScoreThreshold = 40;

static std::string SafeText(const std::string &value, const std::string &fallback) {
    return value.empty() ? fallback : value;
}

static std::string FormatIntegerMetric(int value, const std::string &suffix) {
    if (value < 0) return "Unknown";
    return std::to_string(value) + suffix;
}

static std::string FormatDoubleMetric(double value, const std::string &suffix, int precision = 1) {
    if (!std::isfinite(value) || value < 0.0) return "Unknown";
    char buffer[64] = {0};
    std::snprintf(buffer, sizeof(buffer), precision == 0 ? "%.0f%s" : "%.1f%s", value, suffix.c_str());
    return buffer;
}

static std::string MarkdownEscaped(const std::string &value) {
    std::string escaped;
    escaped.reserve(value.size());
    for (char c : value) {
        if (c == '\n' || c == '\r') {
            escaped += ' ';
        } else {
            escaped += c;
        }
    }
    return escaped;
}

static double ElapsedSince(double startedAtSeconds, double nowSeconds) {
    if (!std::isfinite(startedAtSeconds) || !std::isfinite(nowSeconds) || nowSeconds < startedAtSeconds) return 0.0;
    return nowSeconds - startedAtSeconds;
}

static std::string LowercaseCopy(const std::string &value) {
    std::string lower = value;
    std::transform(lower.begin(), lower.end(), lower.begin(), [](unsigned char c) { return (char)std::tolower(c); });
    return lower;
}

static bool EventMatches(const SessionHealthReport &report, const std::string &needle) {
    const std::string lowerNeedle = LowercaseCopy(needle);
    for (const SessionHealthEvent &event : report.events) {
        std::string title = LowercaseCopy(event.title);
        std::string detail = LowercaseCopy(event.detail);
        if (title.find(lowerNeedle) != std::string::npos || detail.find(lowerNeedle) != std::string::npos) return true;
    }
    return false;
}

static void AddDecisionScore(SessionReportDisplayDecision &decision, int points, const std::string &reason) {
    if (points <= 0) return;
    decision.score += points;
    if (decision.reason.empty()) decision.reason = reason;
}

}

std::string FormatSessionHealthDuration(double seconds) {
    if (!std::isfinite(seconds) || seconds < 0.0) return "Unknown";
    int totalSeconds = (int)std::llround(seconds);
    int minutes = totalSeconds / 60;
    int remainingSeconds = totalSeconds % 60;
    if (minutes <= 0) return std::to_string(remainingSeconds) + "s";
    return std::to_string(minutes) + "m " + std::to_string(remainingSeconds) + "s";
}

void SessionHealthReportBuilder::Reset(const std::string &gameTitle,
                                       const std::string &appId,
                                       const std::string &webRTCBackend,
                                       double nowSeconds) {
    *this = SessionHealthReportBuilder();
    m_started = true;
    m_startedAtSeconds = nowSeconds;
    m_report.gameTitle = gameTitle;
    m_report.appId = appId;
    m_report.webRTCBackend = webRTCBackend;
    MarkPhase("Prepare", nowSeconds);
}

void SessionHealthReportBuilder::MarkPhase(const std::string &label, double nowSeconds) {
    if (!m_started || label.empty()) return;
    if (!m_report.timeline.empty() && m_report.timeline.back().label == label) return;
    m_report.timeline.push_back({label, ElapsedSince(m_startedAtSeconds, nowSeconds)});
}

void SessionHealthReportBuilder::SetRequestedSettings(const StreamSettings &settings) {
    m_report.requestedResolution = settings.resolution;
    m_report.requestedFps = settings.fps;
    m_report.requestedCodec = settings.codec;
    m_report.requestedBitrateMbps = settings.maxBitrateMbps;
}

void SessionHealthReportBuilder::SetFinalSettings(const StreamSettings &settings) {
    m_report.finalResolution = settings.resolution;
    m_report.finalFps = settings.fps;
    m_report.finalCodec = settings.codec;
    m_report.finalBitrateMbps = settings.maxBitrateMbps;
}

void SessionHealthReportBuilder::SetNetworkPreflight(const StreamNetworkPreflightResult &preflight, const std::string &region) {
    m_report.region = region.empty() ? preflight.streamingBaseUrl : region;
    m_report.networkType = preflight.networkType;
    m_report.usedAutomaticRegion = preflight.usedAutomaticRegion;
    m_report.networkLatencyMs = preflight.latencyMs;
    m_report.networkJitterMs = preflight.jitterMs;
    m_report.measuredBandwidthMbps = preflight.measuredBandwidthMbps;
    m_report.networkPacketLossPercent = preflight.packetLossPercent;
}

void SessionHealthReportBuilder::SetSessionInfo(const SessionInfo &sessionInfo) {
    if (!sessionInfo.zone.empty()) m_report.region = sessionInfo.zone;
    if (!sessionInfo.gpuType.empty()) m_report.gpuType = sessionInfo.gpuType;
    if (!sessionInfo.negotiatedStreamProfile.resolution.empty()) m_report.finalResolution = sessionInfo.negotiatedStreamProfile.resolution;
    if (sessionInfo.negotiatedStreamProfile.fps > 0) m_report.finalFps = sessionInfo.negotiatedStreamProfile.fps;
    if (!sessionInfo.negotiatedStreamProfile.codec.empty()) m_report.finalCodec = sessionInfo.negotiatedStreamProfile.codec;
}

void SessionHealthReportBuilder::MarkConnected(double nowSeconds) {
    if (!m_started) return;
    m_report.connected = true;
    m_report.launchSeconds = ElapsedSince(m_startedAtSeconds, nowSeconds);
    MarkPhase("Connected", nowSeconds);
}

void SessionHealthReportBuilder::RecordEvent(const std::string &title, const std::string &detail, double nowSeconds) {
    if (!m_started || title.empty()) return;
    if (title.find("recover") != std::string::npos || title.find("Recovery") != std::string::npos) {
        m_report.recovered = true;
    }
    m_report.events.push_back({title, detail, ElapsedSince(m_startedAtSeconds, nowSeconds)});
}

void SessionHealthReportBuilder::AddStatsSample(const StreamStats &stats) {
    if (!stats.available) return;
    m_report.stats.available = true;
    m_report.stats.sampleCount++;
    if (stats.latencyMs >= 0.0 && std::isfinite(stats.latencyMs)) {
        m_latencyTotal += stats.latencyMs;
        m_latencyCount++;
        m_report.stats.maximumLatencyMs = std::max(m_report.stats.maximumLatencyMs, stats.latencyMs);
    }
    if (stats.jitterMs >= 0.0 && std::isfinite(stats.jitterMs)) {
        m_jitterTotal += stats.jitterMs;
        m_jitterCount++;
    }
    if (stats.inboundBitrateMbps >= 0.0 && std::isfinite(stats.inboundBitrateMbps)) {
        m_bitrateTotal += stats.inboundBitrateMbps;
        m_bitrateCount++;
    }
    if (stats.packetLossPercent >= 0.0 && std::isfinite(stats.packetLossPercent)) {
        m_report.stats.maximumPacketLossPercent = std::max(m_report.stats.maximumPacketLossPercent, stats.packetLossPercent);
    }
    if (stats.renderFps >= 0.0 && std::isfinite(stats.renderFps)) {
        m_renderFpsTotal += stats.renderFps;
        m_renderFpsCount++;
    }
    if (stats.decodeTimeMs >= 0.0 && std::isfinite(stats.decodeTimeMs)) {
        m_decodeTimeTotal += stats.decodeTimeMs;
        m_decodeTimeCount++;
    }
    m_report.stats.framesReceived = std::max(m_report.stats.framesReceived, stats.framesReceived);
    m_report.stats.framesDropped = std::max(m_report.stats.framesDropped, stats.framesDropped);
    m_report.stats.packetsLost = std::max(m_report.stats.packetsLost, stats.packetsLost);
    if (!stats.resolution.empty()) m_report.stats.resolution = stats.resolution;
    if (!stats.codec.empty()) m_report.stats.codec = stats.codec;
    if (stats.fps > 0) m_report.stats.fps = stats.fps;
}

SessionHealthReport SessionHealthReportBuilder::Finalize(bool success, const std::string &terminalError, double nowSeconds) const {
    SessionHealthReport report = m_report;
    report.success = success;
    report.terminalError = success ? std::string() : terminalError;
    report.durationSeconds = m_started ? ElapsedSince(m_startedAtSeconds, nowSeconds) : 0.0;
    report.stats.averageLatencyMs = m_latencyCount > 0 ? m_latencyTotal / (double)m_latencyCount : -1.0;
    report.stats.averageJitterMs = m_jitterCount > 0 ? m_jitterTotal / (double)m_jitterCount : -1.0;
    report.stats.averageBitrateMbps = m_bitrateCount > 0 ? m_bitrateTotal / (double)m_bitrateCount : -1.0;
    report.stats.averageRenderFps = m_renderFpsCount > 0 ? m_renderFpsTotal / (double)m_renderFpsCount : -1.0;
    report.stats.averageDecodeTimeMs = m_decodeTimeCount > 0 ? m_decodeTimeTotal / (double)m_decodeTimeCount : -1.0;
    if (report.finalResolution.empty()) report.finalResolution = report.stats.resolution;
    if (report.finalCodec.empty()) report.finalCodec = report.stats.codec;
    if (report.finalFps <= 0) report.finalFps = report.stats.fps;
    return report;
}

std::string SessionHealthReportSummary(const SessionHealthReport &report) {
    std::string result = report.success ? "Stream ended normally" : "Stream ended with an error";
    result += " · launch " + FormatSessionHealthDuration(report.launchSeconds);
    if (report.stats.available) {
        result += " · avg latency " + FormatDoubleMetric(report.stats.averageLatencyMs, " ms", 0);
    }
    return result;
}

std::string SessionHealthReportMarkdown(const SessionHealthReport &report) {
    std::ostringstream out;
    out << "# OpenNOW Session Report\n\n";
    out << "## Summary\n";
    out << "- Game: " << MarkdownEscaped(SafeText(report.gameTitle, "Unknown")) << "\n";
    out << "- Result: " << (report.success ? "Ended normally" : "Error") << "\n";
    out << "- Duration: " << FormatSessionHealthDuration(report.durationSeconds) << "\n";
    out << "- Launch time: " << FormatSessionHealthDuration(report.launchSeconds) << "\n";
    if (!report.terminalError.empty()) out << "- Error: " << MarkdownEscaped(report.terminalError) << "\n";

    out << "\n## Stream Profile\n";
    out << "- Requested: " << SafeText(report.requestedResolution, "Unknown") << " " << report.requestedFps << " FPS, " << SafeText(report.requestedCodec, "Unknown") << ", " << report.requestedBitrateMbps << " Mbps\n";
    out << "- Final: " << SafeText(report.finalResolution, "Unknown") << " " << report.finalFps << " FPS, " << SafeText(report.finalCodec, "Unknown") << ", " << report.finalBitrateMbps << " Mbps\n";
    out << "- WebRTC backend: " << SafeText(report.webRTCBackend, "Unknown") << "\n";
    out << "- GPU: " << SafeText(report.gpuType, "Unknown") << "\n";

    out << "\n## Network\n";
    out << "- Region: " << MarkdownEscaped(SafeText(report.region, "Automatic")) << (report.usedAutomaticRegion ? " (automatic)" : "") << "\n";
    out << "- Type: " << SafeText(report.networkType, "Unknown") << "\n";
    out << "- Latency: " << FormatIntegerMetric(report.networkLatencyMs, " ms") << "\n";
    out << "- Jitter: " << FormatIntegerMetric(report.networkJitterMs, " ms") << "\n";
    out << "- Bandwidth: " << FormatDoubleMetric(report.measuredBandwidthMbps, " Mbps", 0) << "\n";
    out << "- Packet loss: " << FormatDoubleMetric(report.networkPacketLossPercent, "%") << "\n";

    out << "\n## Stream Stats\n";
    if (report.stats.available) {
        out << "- Samples: " << report.stats.sampleCount << "\n";
        out << "- Average latency: " << FormatDoubleMetric(report.stats.averageLatencyMs, " ms", 0) << "\n";
        out << "- Maximum latency: " << FormatDoubleMetric(report.stats.maximumLatencyMs, " ms", 0) << "\n";
        out << "- Average jitter: " << FormatDoubleMetric(report.stats.averageJitterMs, " ms", 0) << "\n";
        out << "- Average bitrate: " << FormatDoubleMetric(report.stats.averageBitrateMbps, " Mbps") << "\n";
        out << "- Maximum packet loss: " << FormatDoubleMetric(report.stats.maximumPacketLossPercent, "%") << "\n";
        out << "- Average render FPS: " << FormatDoubleMetric(report.stats.averageRenderFps, " FPS", 0) << "\n";
        out << "- Average decode time: " << FormatDoubleMetric(report.stats.averageDecodeTimeMs, " ms") << "\n";
        out << "- Frames dropped: " << report.stats.framesDropped << " / " << report.stats.framesReceived << "\n";
        out << "- Packets lost: " << report.stats.packetsLost << "\n";
    } else {
        out << "- No stream stats were available.\n";
    }

    out << "\n## Timeline\n";
    for (const SessionHealthTimelinePoint &point : report.timeline) {
        out << "- +" << FormatSessionHealthDuration(point.elapsedSeconds) << ": " << MarkdownEscaped(point.label) << "\n";
    }

    out << "\n## Events\n";
    if (report.events.empty()) {
        out << "- No notable recovery or quality events.\n";
    } else {
        for (const SessionHealthEvent &event : report.events) {
            out << "- +" << FormatSessionHealthDuration(event.elapsedSeconds) << ": " << MarkdownEscaped(event.title);
            if (!event.detail.empty()) out << " - " << MarkdownEscaped(event.detail);
            out << "\n";
        }
    }
    return out.str();
}

std::string SessionHealthReportCopyText(const SessionHealthReport &report) {
    return SessionHealthReportMarkdown(report);
}

SessionReportDisplayMode LoadSessionReportDisplayMode() {
    NSInteger stored = [NSUserDefaults.standardUserDefaults integerForKey:kSessionReportDisplayModeKey];
    if (stored == (NSInteger)SessionReportDisplayMode::Always) return SessionReportDisplayMode::Always;
    if (stored == (NSInteger)SessionReportDisplayMode::ImportantOnly) return SessionReportDisplayMode::ImportantOnly;
    if (stored == (NSInteger)SessionReportDisplayMode::Off) return SessionReportDisplayMode::Off;
    return SessionReportDisplayMode::Automatic;
}

void SaveSessionReportDisplayMode(SessionReportDisplayMode mode) {
    [NSUserDefaults.standardUserDefaults setInteger:(NSInteger)mode forKey:kSessionReportDisplayModeKey];
    [NSUserDefaults.standardUserDefaults synchronize];
}

SessionReportDisplayDecision SessionHealthReportDisplayDecisionForReport(const SessionHealthReport &report, SessionReportDisplayMode mode) {
    SessionReportDisplayDecision decision;
    if (mode == SessionReportDisplayMode::Off) {
        decision.reason = "Session reports are disabled";
        return decision;
    }
    if (mode == SessionReportDisplayMode::Always) {
        decision.shouldShow = true;
        decision.score = 100;
        decision.reason = "Session reports are set to always show";
        return decision;
    }

    const bool recoveryEvent = report.recovered || EventMatches(report, "recovery");
    const bool guardrailEvent = EventMatches(report, "guardrail");
    const bool networkWarningEvent = EventMatches(report, "network warning") || EventMatches(report, "launch cancelled");
    const bool inactivityEvent = EventMatches(report, "inactivity timeout");

    if (!report.success) AddDecisionScore(decision, 100, "The stream ended with an error");
    if (!report.connected) AddDecisionScore(decision, 90, "The stream did not reach a connected state");
    if (!report.terminalError.empty()) AddDecisionScore(decision, 80, "A terminal stream error was reported");
    if (recoveryEvent) AddDecisionScore(decision, 45, "Automatic recovery was used");
    if (networkWarningEvent) AddDecisionScore(decision, 45, "A network warning affected launch");
    if (guardrailEvent) AddDecisionScore(decision, 40, "A quality guardrail changed stream settings");
    if (inactivityEvent) AddDecisionScore(decision, 35, "The session ended due to inactivity");

    if (mode == SessionReportDisplayMode::Automatic && report.stats.available) {
        if (report.stats.averageLatencyMs >= 115.0) AddDecisionScore(decision, 35, "Average latency was high");
        if (report.stats.maximumLatencyMs >= 160.0) AddDecisionScore(decision, 30, "Peak latency was high");
        if (report.stats.maximumPacketLossPercent >= 1.0) AddDecisionScore(decision, 30, "Packet loss was elevated");
        if (report.stats.framesDropped >= 60) AddDecisionScore(decision, 25, "Many frames were dropped");
        if (report.finalBitrateMbps > 0 && report.stats.averageBitrateMbps >= 0.0 && report.stats.averageBitrateMbps < (double)report.finalBitrateMbps * 0.55) {
            AddDecisionScore(decision, 20, "Average bitrate was far below the target");
        }
        int targetFps = report.finalFps > 0 ? report.finalFps : report.stats.fps;
        if (targetFps > 0 && report.stats.averageRenderFps >= 0.0 && report.stats.averageRenderFps < (double)targetFps * 0.82) {
            AddDecisionScore(decision, 25, "Render FPS was below target");
        }
    }

    decision.shouldShow = decision.score >= kAutomaticReportDisplayScoreThreshold;
    if (decision.reason.empty()) {
        decision.reason = decision.shouldShow ? "Session report score exceeded threshold" : "Session ended normally with healthy metrics";
    }
    return decision;
}

bool SessionHealthReportShouldShow(const SessionHealthReport &report) {
    return SessionHealthReportDisplayDecisionForReport(report, LoadSessionReportDisplayMode()).shouldShow;
}

}
