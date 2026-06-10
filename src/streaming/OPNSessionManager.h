#pragma once

#include "OPNStreamTypes.h"
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace OPN {

struct SessionManagerStorage;

class SessionManager {
public:
    static SessionManager &Shared();

    void SetAccessToken(const std::string &token);
    void SetStreamingBaseUrl(const std::string &url);

    void CreateSession(const std::string &appId,
                       const std::string &internalTitle,
                       const StreamSettings &settings,
                       SessionCreateCallback completion);

    void GetActiveSessions(std::function<void(bool, const std::vector<ActiveSessionEntry> &, const std::string &)> completion);

    void ClaimSession(const std::string &sessionId,
                      const std::string &serverIp,
                      const std::string &appId,
                      const StreamSettings &settings,
                      bool recoveryMode,
                      SessionCreateCallback completion);

    void PollSession(const std::string &sessionId,
                     const std::string &serverIp,
                     SessionPollCallback completion);

    void StopSession(const std::string &sessionId,
                       const std::string &serverIp,
                       std::function<void(bool, const std::string &)> completion);

    std::string LoadPersistedActiveSessionId() const;
    void StorePersistedActiveSessionId(const std::string &sessionId);
    void ClearPersistedActiveSessionId(const std::string &sessionId = "");

    void ReportSessionAd(const SessionInfo &session,
                         const std::string &adId,
                         const std::string &action,
                         int watchedTimeInMs,
                         int pausedTimeInMs,
                         const std::string &cancelReason,
                         std::function<void(bool, const SessionInfo &, const std::string &)> completion);

    std::string GetStreamingBaseUrl() const;

private:
    SessionManager();
    ~SessionManager();

    SessionManager(const SessionManager &) = delete;
    SessionManager &operator=(const SessionManager &) = delete;

    void pollClaimSession(std::string sessionId,
                             std::string serverIp,
                             std::string deviceId,
                             std::string clientId,
                             NegotiatedStreamProfile initialStreamProfile,
                             SessionCreateCallback completion);
    void MergeAndStoreAdState(SessionInfo &info);

    std::unique_ptr<SessionManagerStorage> m_storage;
};

}
