#include "OPNSessionManagerBridge.h"

namespace OPN {

void OPNSetSessionManagerAccessToken(const std::string &token) {
    SessionManager::Shared().SetAccessToken(token);
}

void OPNSetSessionManagerStreamingBaseUrl(const std::string &url) {
    SessionManager::Shared().SetStreamingBaseUrl(url);
}

void OPNReportSessionAd(const SessionInfo &session,
                        const std::string &adId,
                        const std::string &action,
                        int watchedTimeInMs,
                        int pausedTimeInMs,
                        const std::string &cancelReason,
                        std::function<void(bool, const SessionInfo &, const std::string &)> completion) {
    SessionManager::Shared().ReportSessionAd(session, adId, action, watchedTimeInMs, pausedTimeInMs, cancelReason, completion);
}

void OPNPollSession(const std::string &sessionId,
                   const std::string &serverIp,
                   SessionPollCallback completion) {
    SessionManager::Shared().PollSession(sessionId, serverIp, completion);
}

void OPNStopSession(const std::string &sessionId,
                   const std::string &serverIp,
                   std::function<void(bool, const std::string &)> completion) {
    SessionManager::Shared().StopSession(sessionId, serverIp, completion);
}

void OPNClaimSession(const std::string &sessionId,
                    const std::string &serverIp,
                    const std::string &appId,
                    const StreamSettings &settings,
                    bool recoveryMode,
                    SessionCreateCallback completion) {
    SessionManager::Shared().ClaimSession(sessionId, serverIp, appId, settings, recoveryMode, completion);
}

void OPNGetActiveSessions(std::function<void(bool, const std::vector<ActiveSessionEntry> &, const std::string &)> completion) {
    SessionManager::Shared().GetActiveSessions(completion);
}

void OPNCreateSession(const std::string &appId,
                     const std::string &internalTitle,
                     const StreamSettings &settings,
                     SessionCreateCallback completion) {
    SessionManager::Shared().CreateSession(appId, internalTitle, settings, completion);
}

}
