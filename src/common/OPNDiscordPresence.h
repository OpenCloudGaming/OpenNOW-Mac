#pragma once

#include <cstdint>
#include <string>

namespace OPN {

enum class DiscordPresenceMode : int {
    Off = 0,
    StatusOnly = 1,
    FullDetails = 2,
};

class DiscordPresence {
public:
    static DiscordPresence &Shared();

    void UpdateBrowsing();
    void UpdateLaunching(const std::string &gameTitle);
    void UpdatePlaying(const std::string &gameTitle,
                       const std::string &resolution,
                       int fps,
                       int bitrateMbps,
                       const std::string &codec);
    void Clear();

private:
    DiscordPresence();
    void SetActivity(const std::string &details,
                     const std::string &state,
                     bool includeStartTimestamp);
    void SendPayload(const std::string &payload, bool closeAfterSend);

    int64_t m_startedAtUnixSeconds = 0;
};

DiscordPresenceMode LoadDiscordPresenceMode();
void SaveDiscordPresenceMode(DiscordPresenceMode mode);
std::string LoadDiscordClientId();
std::string DiscordPresenceModeName(DiscordPresenceMode mode);
std::string DiscordPresenceActivityPayloadForTesting(const std::string &details,
                                                     const std::string &state,
                                                     int64_t startedAtUnixSeconds,
                                                     int processId);

}
