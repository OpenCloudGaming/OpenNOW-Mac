#include "OPNDiscordPresence.h"
#include "OPNSentry.h"

#import <Foundation/Foundation.h>
#include <cerrno>
#include <chrono>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <string>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <vector>

namespace OPN {

static NSString *const kDiscordPresenceModeKey = @"OpenNOW.Discord.PresenceMode";
static NSString *const kDiscordClientIdKey = @"OpenNOW.Discord.ClientId";

static int64_t CurrentUnixSeconds() {
    return std::chrono::duration_cast<std::chrono::seconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
}

static std::string NSStringToString(NSString *value) {
    return value.length > 0 ? std::string(value.UTF8String) : std::string();
}

static NSString *StringToNSString(const std::string &value) {
    return [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding] ?: @"";
}

static std::string JSONStringEscape(const std::string &value) {
    std::string escaped;
    escaped.reserve(value.size() + 8);
    for (unsigned char c : value) {
        switch (c) {
            case '\\': escaped += "\\\\"; break;
            case '"': escaped += "\\\""; break;
            case '\b': escaped += "\\b"; break;
            case '\f': escaped += "\\f"; break;
            case '\n': escaped += "\\n"; break;
            case '\r': escaped += "\\r"; break;
            case '\t': escaped += "\\t"; break;
            default:
                if (c < 0x20) {
                    const char *digits = "0123456789abcdef";
                    escaped += "\\u00";
                    escaped += digits[(c >> 4) & 0x0f];
                    escaped += digits[c & 0x0f];
                } else {
                    escaped += (char)c;
                }
                break;
        }
    }
    return escaped;
}

static std::string JSONObjectStringField(const char *name, const std::string &value) {
    return std::string("\"") + name + "\":\"" + JSONStringEscape(value) + "\"";
}

std::string DiscordPresenceActivityPayloadForTesting(const std::string &details,
                                                     const std::string &state,
                                                     int64_t startedAtUnixSeconds,
                                                     int processId) {
    std::string payload = "{\"cmd\":\"SET_ACTIVITY\",\"args\":{\"pid\":" + std::to_string(processId) + ",\"activity\":{";
    payload += JSONObjectStringField("details", details);
    if (!state.empty()) payload += "," + JSONObjectStringField("state", state);
    if (startedAtUnixSeconds > 0) payload += ",\"timestamps\":{\"start\":" + std::to_string(startedAtUnixSeconds) + "}";
    payload += ",\"assets\":{";
    payload += JSONObjectStringField("large_text", "OpenNOW");
    payload += "}";
    payload += "}},\"nonce\":\"" + std::to_string(CurrentUnixSeconds()) + "-" + std::to_string(processId) + "\"}";
    return payload;
}

static std::string DiscordClearActivityPayload(int processId) {
    return "{\"cmd\":\"SET_ACTIVITY\",\"args\":{\"pid\":" + std::to_string(processId) + ",\"activity\":null},\"nonce\":\"clear-" + std::to_string(CurrentUnixSeconds()) + "\"}";
}

static std::vector<std::string> DiscordCandidateSocketPaths() {
    std::vector<std::string> bases;
    auto appendBase = [&bases](const char *value) {
        if (!value || !*value) return;
        std::string base(value);
        while (base.size() > 1 && base.back() == '/') base.pop_back();
        for (const std::string &existing : bases) {
            if (existing == base) return;
        }
        bases.push_back(base);
    };

    appendBase(std::getenv("XDG_RUNTIME_DIR"));
    appendBase(std::getenv("TMPDIR"));
    appendBase("/tmp");
    appendBase("/var/tmp");
    appendBase("/usr/tmp");

    std::vector<std::string> paths;
    for (const std::string &base : bases) {
        for (int i = 0; i < 10; i++) paths.push_back(base + "/discord-ipc-" + std::to_string(i));
    }
    return paths;
}

static bool WriteAll(int fd, const void *bytes, size_t length) {
    const char *cursor = static_cast<const char *>(bytes);
    size_t remaining = length;
    while (remaining > 0) {
        ssize_t written = write(fd, cursor, remaining);
        if (written < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        if (written == 0) return false;
        cursor += written;
        remaining -= (size_t)written;
    }
    return true;
}

static bool ReadAll(int fd, void *bytes, size_t length) {
    char *cursor = static_cast<char *>(bytes);
    size_t remaining = length;
    while (remaining > 0) {
        ssize_t bytesRead = read(fd, cursor, remaining);
        if (bytesRead < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        if (bytesRead == 0) return false;
        cursor += bytesRead;
        remaining -= (size_t)bytesRead;
    }
    return true;
}

static bool SendDiscordFrame(int fd, uint32_t opcode, const std::string &payload) {
    uint32_t header[2] = {opcode, (uint32_t)payload.size()};
    return WriteAll(fd, header, sizeof(header)) && WriteAll(fd, payload.data(), payload.size());
}

static bool ReadDiscordFrame(int fd, uint32_t &opcode, std::string &payload) {
    uint32_t header[2] = {0, 0};
    if (!ReadAll(fd, header, sizeof(header))) return false;
    opcode = header[0];
    uint32_t length = header[1];
    if (length > 1024 * 1024) return false;
    payload.assign(length, '\0');
    return length == 0 || ReadAll(fd, payload.data(), payload.size());
}

static void CloseDiscordSocket(int &fd) {
    if (fd >= 0) {
        close(fd);
        fd = -1;
    }
}

static int ConnectDiscordSocket() {
    for (const std::string &path : DiscordCandidateSocketPaths()) {
        if (path.size() >= sizeof(sockaddr_un::sun_path)) continue;
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) continue;

#ifdef SO_NOSIGPIPE
        int noSigpipe = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, sizeof(noSigpipe));
#endif
        timeval timeout = {};
        timeout.tv_sec = 2;
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));

        sockaddr_un addr = {};
        addr.sun_family = AF_UNIX;
        std::strncpy(addr.sun_path, path.c_str(), sizeof(addr.sun_path) - 1);
        if (connect(fd, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) == 0) return fd;
        close(fd);
    }
    return -1;
}

static dispatch_queue_t DiscordPresenceQueue() {
    static dispatch_queue_t queue = dispatch_queue_create("io.opencg.opennow.discord-presence", DISPATCH_QUEUE_SERIAL);
    return queue;
}

static int &DiscordConnectionFd() {
    static int fd = -1;
    return fd;
}

static std::string &DiscordConnectionClientId() {
    static std::string clientId;
    return clientId;
}

static bool EnsureDiscordConnection(const std::string &clientId) {
    int &fd = DiscordConnectionFd();
    std::string &connectedClientId = DiscordConnectionClientId();
    if (fd >= 0 && connectedClientId == clientId) return true;

    CloseDiscordSocket(fd);
    connectedClientId.clear();

    fd = ConnectDiscordSocket();
    if (fd < 0) {
        OPN::LogInfo(@"[DiscordPresence] Discord IPC socket not available");
        return false;
    }

    std::string handshake = "{\"v\":1,\"client_id\":\"" + JSONStringEscape(clientId) + "\"}";
    if (!SendDiscordFrame(fd, 0, handshake)) {
        OPN::LogInfo(@"[DiscordPresence] Failed to write Discord handshake");
        CloseDiscordSocket(fd);
        return false;
    }

    uint32_t opcode = 0;
    std::string response;
    if (!ReadDiscordFrame(fd, opcode, response) || opcode != 1 || response.find("READY") == std::string::npos) {
        NSString *payload = StringToNSString(response);
        OPN::LogInfo(@"[DiscordPresence] Discord handshake did not return READY opcode=%u response=%@", opcode, payload);
        CloseDiscordSocket(fd);
        return false;
    }

    connectedClientId = clientId;
    return true;
}

static void DisconnectDiscordPresence() {
    int &fd = DiscordConnectionFd();
    CloseDiscordSocket(fd);
    DiscordConnectionClientId().clear();
}

DiscordPresenceMode LoadDiscordPresenceMode() {
    NSInteger stored = [NSUserDefaults.standardUserDefaults integerForKey:kDiscordPresenceModeKey];
    if (stored == (NSInteger)DiscordPresenceMode::StatusOnly) return DiscordPresenceMode::StatusOnly;
    if (stored == (NSInteger)DiscordPresenceMode::FullDetails) return DiscordPresenceMode::FullDetails;
    return DiscordPresenceMode::Off;
}

void SaveDiscordPresenceMode(DiscordPresenceMode mode) {
    [NSUserDefaults.standardUserDefaults setInteger:(NSInteger)mode forKey:kDiscordPresenceModeKey];
    [NSUserDefaults.standardUserDefaults synchronize];
    if (mode == DiscordPresenceMode::Off) DiscordPresence::Shared().Clear();
}

std::string LoadDiscordClientId() {
    NSString *defaultsValue = [NSUserDefaults.standardUserDefaults stringForKey:kDiscordClientIdKey];
    if (defaultsValue.length > 0) return NSStringToString(defaultsValue);

    NSString *plistValue = [NSBundle.mainBundle objectForInfoDictionaryKey:@"OPNDiscordClientID"];
    if ([plistValue isKindOfClass:NSString.class] && plistValue.length > 0) return NSStringToString(plistValue);

    const char *envValue = std::getenv("OPN_DISCORD_CLIENT_ID");
    return envValue && *envValue ? std::string(envValue) : std::string();
}

std::string DiscordPresenceModeName(DiscordPresenceMode mode) {
    switch (mode) {
        case DiscordPresenceMode::StatusOnly: return "Status Only";
        case DiscordPresenceMode::FullDetails: return "Full Details";
        case DiscordPresenceMode::Off:
        default: return "Off";
    }
}

DiscordPresence &DiscordPresence::Shared() {
    static DiscordPresence shared;
    return shared;
}

DiscordPresence::DiscordPresence() = default;

void DiscordPresence::UpdateBrowsing() {
    DiscordPresenceMode mode = LoadDiscordPresenceMode();
    if (mode == DiscordPresenceMode::Off) return;
    SetActivity("Browsing cloud games", "OpenNOW", false);
}

void DiscordPresence::UpdateLaunching(const std::string &gameTitle) {
    DiscordPresenceMode mode = LoadDiscordPresenceMode();
    if (mode == DiscordPresenceMode::Off) return;
    std::string details = mode == DiscordPresenceMode::FullDetails && !gameTitle.empty()
        ? "Launching " + gameTitle
        : "Launching a cloud game";
    SetActivity(details, "OpenNOW", true);
}

void DiscordPresence::UpdatePlaying(const std::string &gameTitle,
                                    const std::string &resolution,
                                    int fps,
                                    int bitrateMbps,
                                    const std::string &codec) {
    DiscordPresenceMode mode = LoadDiscordPresenceMode();
    if (mode == DiscordPresenceMode::Off) return;
    std::string details = mode == DiscordPresenceMode::FullDetails && !gameTitle.empty()
        ? "Playing " + gameTitle
        : "Playing a cloud game";

    std::string state = "Streaming via OpenNOW";
    if (mode == DiscordPresenceMode::FullDetails) {
        std::string quality;
        if (!resolution.empty()) quality += resolution;
        if (fps > 0) quality += (quality.empty() ? "" : " ") + std::to_string(fps) + " FPS";
        if (!codec.empty()) quality += (quality.empty() ? "" : " · ") + codec;
        if (bitrateMbps > 0) quality += (quality.empty() ? "" : " · ") + std::to_string(bitrateMbps) + " Mbps";
        if (!quality.empty()) state = quality;
    }
    SetActivity(details, state, true);
}

void DiscordPresence::Clear() {
    if (LoadDiscordClientId().empty()) return;
    SendPayload(DiscordClearActivityPayload((int)getpid()), true);
    m_startedAtUnixSeconds = 0;
}

void DiscordPresence::SetActivity(const std::string &details,
                                  const std::string &state,
                                  bool includeStartTimestamp) {
    if (LoadDiscordClientId().empty()) return;
    if (includeStartTimestamp && m_startedAtUnixSeconds <= 0) m_startedAtUnixSeconds = CurrentUnixSeconds();
    int64_t startedAt = includeStartTimestamp ? m_startedAtUnixSeconds : 0;
    SendPayload(DiscordPresenceActivityPayloadForTesting(details, state, startedAt, (int)getpid()), false);
}

void DiscordPresence::SendPayload(const std::string &payload, bool closeAfterSend) {
    std::string clientId = LoadDiscordClientId();
    if (clientId.empty() || payload.empty()) return;

    NSString *clientIdString = StringToNSString(clientId);
    NSString *payloadString = StringToNSString(payload);
    dispatch_async(DiscordPresenceQueue(), ^{
        std::string capturedClientId = NSStringToString(clientIdString);
        if (!EnsureDiscordConnection(capturedClientId)) return;

        int &fd = DiscordConnectionFd();
        bool ok = SendDiscordFrame(fd, 1, NSStringToString(payloadString));
        uint32_t opcode = 0;
        std::string response;
        if (ok) ok = ReadDiscordFrame(fd, opcode, response) && opcode == 1;
        if (!ok) {
            NSString *responseString = StringToNSString(response);
            OPN::LogInfo(@"[DiscordPresence] Failed Discord SET_ACTIVITY opcode=%u response=%@", opcode, responseString);
            DisconnectDiscordPresence();
            return;
        }
        if (closeAfterSend) DisconnectDiscordPresence();
    });
}

}
