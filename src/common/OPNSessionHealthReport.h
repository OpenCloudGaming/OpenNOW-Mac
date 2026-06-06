#pragma once

#include "streaming/OPNStreamPreferences.h"
#include "streaming/OPNStreamSession.h"
#include "streaming/OPNStreamTypes.h"
#include <cstdint>
#include <string>
#include <vector>

namespace OPN {

enum class SessionReportDisplayMode {
    Automatic = 0,
    Always = 1,
    ImportantOnly = 2,
    Off = 3,
};

struct SessionReportDisplayDecision {
    bool shouldShow = false;
    int score = 0;
    std::string reason;
};

struct SessionHealthTimelinePoint {
    std::string label;
    double elapsedSeconds = 0.0;
};

struct SessionHealthEvent {
    std::string title;
    std::string detail;
    double elapsedSeconds = 0.0;
};

struct SessionHealthStatsSummary {
    bool available = false;
    uint64_t sampleCount = 0;
    double averageLatencyMs = -1.0;
    double maximumLatencyMs = -1.0;
    double averageJitterMs = -1.0;
    double averageBitrateMbps = -1.0;
    double maximumPacketLossPercent = -1.0;
    double averageRenderFps = -1.0;
    double averageDecodeTimeMs = -1.0;
    uint64_t framesReceived = 0;
    uint64_t framesDropped = 0;
    int64_t packetsLost = 0;
    std::string resolution;
    std::string codec;
    int fps = 0;
};

struct SessionHealthReport {
    std::string gameTitle;
    std::string appId;
    std::string webRTCBackend;
    std::string region;
    std::string networkType;
    std::string gpuType;
    bool usedAutomaticRegion = false;
    int networkLatencyMs = -1;
    int networkJitterMs = -1;
    double measuredBandwidthMbps = 0.0;
    double networkPacketLossPercent = -1.0;
    int requestedBitrateMbps = 0;
    int finalBitrateMbps = 0;
    int requestedFps = 0;
    int finalFps = 0;
    std::string requestedResolution;
    std::string finalResolution;
    std::string requestedCodec;
    std::string finalCodec;
    bool success = false;
    bool connected = false;
    bool recovered = false;
    std::string terminalError;
    double durationSeconds = 0.0;
    double launchSeconds = -1.0;
    SessionHealthStatsSummary stats;
    std::vector<SessionHealthTimelinePoint> timeline;
    std::vector<SessionHealthEvent> events;
};

class SessionHealthReportBuilder final {
public:
    void Reset(const std::string &gameTitle,
               const std::string &appId,
               const std::string &webRTCBackend,
               double nowSeconds);

    void MarkPhase(const std::string &label, double nowSeconds);
    void SetRequestedSettings(const StreamSettings &settings);
    void SetFinalSettings(const StreamSettings &settings);
    void SetNetworkPreflight(const StreamNetworkPreflightResult &preflight, const std::string &region);
    void SetSessionInfo(const SessionInfo &sessionInfo);
    void MarkConnected(double nowSeconds);
    void RecordEvent(const std::string &title, const std::string &detail, double nowSeconds);
    void AddStatsSample(const StreamStats &stats);
    SessionHealthReport Finalize(bool success, const std::string &terminalError, double nowSeconds) const;

private:
    SessionHealthReport m_report;
    double m_startedAtSeconds = 0.0;
    bool m_started = false;
    double m_latencyTotal = 0.0;
    uint64_t m_latencyCount = 0;
    double m_jitterTotal = 0.0;
    uint64_t m_jitterCount = 0;
    double m_bitrateTotal = 0.0;
    uint64_t m_bitrateCount = 0;
    double m_renderFpsTotal = 0.0;
    uint64_t m_renderFpsCount = 0;
    double m_decodeTimeTotal = 0.0;
    uint64_t m_decodeTimeCount = 0;
};

std::string SessionHealthReportMarkdown(const SessionHealthReport &report);
std::string SessionHealthReportCopyText(const SessionHealthReport &report);
std::string SessionHealthReportSummary(const SessionHealthReport &report);
std::string FormatSessionHealthDuration(double seconds);
SessionReportDisplayMode LoadSessionReportDisplayMode();
void SaveSessionReportDisplayMode(SessionReportDisplayMode mode);
SessionReportDisplayDecision SessionHealthReportDisplayDecisionForReport(const SessionHealthReport &report, SessionReportDisplayMode mode);
bool SessionHealthReportShouldShow(const SessionHealthReport &report);

}
