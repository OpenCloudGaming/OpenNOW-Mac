#pragma once

#include "OPNSessionManager.h"

namespace OPN {

void OPNSetSessionManagerAccessToken(const std::string &token);
void OPNSetSessionManagerStreamingBaseUrl(const std::string &url);
void OPNReportSessionAd(const SessionInfo &session,
                        const std::string &adId,
                        const std::string &action,
                        int watchedTimeInMs,
                        int pausedTimeInMs,
                        const std::string &cancelReason,
                        std::function<void(bool, const SessionInfo &, const std::string &)> completion);
void OPNPollSession(const std::string &sessionId,
                   const std::string &serverIp,
                   SessionPollCallback completion);
void OPNStopSession(const std::string &sessionId,
                   const std::string &serverIp,
                   std::function<void(bool, const std::string &)> completion);
void OPNClaimSession(const std::string &sessionId,
                    const std::string &serverIp,
                    const std::string &appId,
                    const StreamSettings &settings,
                    bool recoveryMode,
                    SessionCreateCallback completion);
void OPNGetActiveSessions(std::function<void(bool, const std::vector<ActiveSessionEntry> &, const std::string &)> completion);
void OPNCreateSession(const std::string &appId,
                     const std::string &internalTitle,
                     const StreamSettings &settings,
                     SessionCreateCallback completion);

}
