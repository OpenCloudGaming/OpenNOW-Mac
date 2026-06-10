#include "OPNStreamSessionLaunchBridge.h"

#include "OPNStreamSession.h"
#include "OPNStreamTypes.h"

#include <cctype>
#include <cstdlib>
#include <cstring>
#include <sstream>
#include <vector>

static NSString *OPNLaunchBridgeStringFromStdString(const std::string &value) {
    if (value.empty()) return @"";
    NSString *string = [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding];
    return string ?: @"";
}

static NSDictionary *OPNLaunchBridgeIceCandidateDictionary(const OPN::IceCandidatePayload &candidate) {
    return @{
        @"candidate": OPNLaunchBridgeStringFromStdString(candidate.candidate),
        @"sdpMid": OPNLaunchBridgeStringFromStdString(candidate.sdpMid),
        @"sdpMLineIndex": @(candidate.sdpMLineIndex),
        @"usernameFragment": OPNLaunchBridgeStringFromStdString(candidate.usernameFragment),
    };
}

static bool OPNLaunchBridgeIsDottedIp(const std::string &value) {
    int dots = 0;
    int digits = 0;
    if (value.empty()) return false;
    for (char c : value) {
        if (c == '.') {
            if (digits == 0) return false;
            dots++;
            digits = 0;
        } else if (std::isdigit((unsigned char)c)) {
            digits++;
            if (digits > 3) return false;
        } else {
            return false;
        }
    }
    return dots == 3 && digits > 0;
}

static std::string OPNLaunchBridgeExtractPublicIp(const std::string &hostOrIp) {
    if (OPNLaunchBridgeIsDottedIp(hostOrIp)) return hostOrIp;
    std::string firstLabel = hostOrIp.substr(0, hostOrIp.find('.'));
    std::vector<std::string> parts;
    std::stringstream ss(firstLabel);
    std::string part;
    while (std::getline(ss, part, '-')) {
        if (part.empty()) return "";
        for (char c : part) {
            if (!std::isdigit((unsigned char)c)) return "";
        }
        parts.push_back(part);
    }
    if (parts.size() != 4) return "";
    return parts[0] + "." + parts[1] + "." + parts[2] + "." + parts[3];
}

static std::string OPNLaunchBridgeExtractIceUfragFromOffer(const std::string &sdp) {
    std::stringstream ss(sdp);
    std::string line;
    while (std::getline(ss, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        const char *prefix = "a=ice-ufrag:";
        if (line.rfind(prefix, 0) == 0) {
            return line.substr(strlen(prefix));
        }
    }
    return "";
}

struct OPNLaunchBridgeIceMediaTarget {
    std::string sdpMid;
    int sdpMLineIndex = 0;
};

static OPNLaunchBridgeIceMediaTarget OPNLaunchBridgeExtractVideoIceTargetFromOffer(const std::string &sdp) {
    OPNLaunchBridgeIceMediaTarget target;
    std::stringstream ss(sdp);
    std::string line;
    bool inVideoSection = false;
    int mediaIndex = -1;
    while (std::getline(ss, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.rfind("m=", 0) == 0) {
            mediaIndex++;
            inVideoSection = line.rfind("m=video ", 0) == 0;
            if (inVideoSection) {
                target.sdpMLineIndex = mediaIndex;
                target.sdpMid = std::to_string(mediaIndex);
            }
            continue;
        }
        if (inVideoSection && line.rfind("a=mid:", 0) == 0) {
            target.sdpMid = line.substr(strlen("a=mid:"));
            break;
        }
    }
    return target;
}

NSString *OPNStreamSessionIceUfragFromOffer(NSString *offerSdp) {
    return OPNLaunchBridgeStringFromStdString(OPNLaunchBridgeExtractIceUfragFromOffer(offerSdp.UTF8String ?: ""));
}

void OPNInjectManualStreamSessionIceCandidate(OPN::IStreamSession *session,
                                              const OPN::SessionInfo &sessionInfo,
                                              NSString *offerSdp,
                                              NSString *serverIceUfrag) {
    if (!session) return;
    std::string offerSdpString = offerSdp.UTF8String ?: "";
    std::string serverIceUfragString = serverIceUfrag.UTF8String ?: "";
    const char *manualIce = getenv("OPN_INJECT_MANUAL_ICE");
    if (manualIce && strcmp(manualIce, "0") == 0) {
        OPNLogInfo(@"[StreamVC] Manual ICE candidate injection disabled by OPN_INJECT_MANUAL_ICE=0");
        return;
    }
    const bool offerHasPlaceholders = offerSdpString.find("0.0.0.0") != std::string::npos;
    const bool forceManualIce = manualIce && strcmp(manualIce, "1") == 0;
    if (!offerHasPlaceholders && !forceManualIce) return;

    std::string ip = OPNLaunchBridgeExtractPublicIp(sessionInfo.mediaConnectionInfo.ip);
    int port = sessionInfo.mediaConnectionInfo.port;
    if (ip.empty() || port <= 0) {
        OPNLogInfo(@"[StreamVC] No valid mediaConnectionInfo for manual ICE candidate (ip=%s, port=%d)",
              sessionInfo.mediaConnectionInfo.ip.c_str(), port);
        return;
    }

    OPNLaunchBridgeIceMediaTarget target = OPNLaunchBridgeExtractVideoIceTargetFromOffer(offerSdpString);
    OPN::IceCandidatePayload payload;
    payload.candidate = "candidate:1 1 udp 2130706431 " + ip + " " + std::to_string(port) + " typ host";
    payload.sdpMid = target.sdpMid;
    payload.sdpMLineIndex = target.sdpMLineIndex;
    payload.usernameFragment = serverIceUfragString;
    OPNLogInfo(@"[StreamVC] Injecting fallback ICE candidate: %s:%d (sdpMid=%s mline=%d ufrag=%s placeholders=%d forced=%d)",
          ip.c_str(),
          port,
          payload.sdpMid.empty() ? "(none)" : payload.sdpMid.c_str(),
          payload.sdpMLineIndex,
          serverIceUfragString.empty() ? "(none)" : serverIceUfragString.c_str(),
          offerHasPlaceholders ? 1 : 0,
          forceManualIce ? 1 : 0);
    session->AddRemoteIceCandidate(payload);
}

void OPNStartStreamSession(OPN::IStreamSession *session,
                           const OPN::SessionInfo &sessionInfo,
                           NSString *offerSdp,
                           const OPN::StreamSettings &settings,
                           OPNStreamSessionAnswerHandler answerHandler,
                           OPNStreamSessionLocalIceCandidateHandler localIceCandidateHandler,
                           OPNStreamSessionStateHandler stateHandler) {
    if (!session) {
        if (stateHandler) stateHandler(NO, @"libwebrtc stream session is unavailable");
        return;
    }

    OPNStreamSessionAnswerHandler answerHandlerCopy = [answerHandler copy];
    OPNStreamSessionLocalIceCandidateHandler localIceCandidateHandlerCopy = [localIceCandidateHandler copy];
    OPNStreamSessionStateHandler stateHandlerCopy = [stateHandler copy];
    std::string offerSdpString = offerSdp.UTF8String ?: "";

    session->OnAnswerReady([answerHandlerCopy](const OPN::SendAnswerRequest &answer) {
        if (!answerHandlerCopy) return;
        answerHandlerCopy(OPNLaunchBridgeStringFromStdString(answer.sdp),
                          OPNLaunchBridgeStringFromStdString(answer.nvstSdp));
    });

    session->OnIceCandidateReady([localIceCandidateHandlerCopy](const OPN::IceCandidatePayload &candidate) {
        if (!localIceCandidateHandlerCopy) return;
        localIceCandidateHandlerCopy(OPNLaunchBridgeIceCandidateDictionary(candidate));
    });

    session->Start(sessionInfo, offerSdpString, settings, [stateHandlerCopy](bool connected, const std::string &streamError) {
        if (!stateHandlerCopy) return;
        stateHandlerCopy(connected ? YES : NO, OPNLaunchBridgeStringFromStdString(streamError));
    });
}
