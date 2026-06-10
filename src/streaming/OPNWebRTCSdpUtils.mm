#include "OPNWebRTCSdpUtils.h"
#include "OPNStreamTypes.h"

#import <Foundation/Foundation.h>

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <sstream>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace OPN {
namespace {

bool OPNStartsWith(const std::string &value, const char *prefix) {
    const size_t prefixLen = std::char_traits<char>::length(prefix);
    return value.size() >= prefixLen && value.compare(0, prefixLen, prefix) == 0;
}

std::vector<std::string> OPNSplitSdpLines(const std::string &sdp) {
    std::vector<std::string> lines;
    std::stringstream stream(sdp);
    std::string line;
    while (std::getline(stream, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        lines.push_back(line);
    }
    return lines;
}

std::string OPNJoinSdpLines(const std::vector<std::string> &lines, const std::string &lineEnding) {
    std::string out;
    for (size_t i = 0; i < lines.size(); i++) {
        out += lines[i];
        if (i + 1 < lines.size()) out += lineEnding;
    }
    return out;
}

std::string OPNJoinSdpLinesLike(const std::vector<std::string> &lines, const std::string &originalSdp) {
    const std::string lineEnding = originalSdp.find("\r\n") != std::string::npos ? "\r\n" : "\n";
    std::string out = OPNJoinSdpLines(lines, lineEnding);
    if (!originalSdp.empty() && originalSdp.back() == '\n') {
        out += lineEnding;
    }
    return out;
}

int OPNPayloadTypeFromAttribute(const std::string &line, const char *prefix) {
    if (!OPNStartsWith(line, prefix)) return -1;
    size_t pos = strlen(prefix);
    size_t end = line.find_first_of(" \t:", pos);
    if (end == std::string::npos || end <= pos) return -1;
    std::string payload = line.substr(pos, end - pos);
    for (char c : payload) {
        if (!std::isdigit((unsigned char)c)) return -1;
    }
    return atoi(payload.c_str());
}

int OPNAptFromFmtp(const std::string &line) {
    size_t pos = line.find("apt=");
    if (pos == std::string::npos) return -1;
    pos += strlen("apt=");
    size_t end = pos;
    while (end < line.size() && std::isdigit((unsigned char)line[end])) end++;
    if (end == pos) return -1;
    return atoi(line.substr(pos, end - pos).c_str());
}

bool OPNPayloadVectorContains(const std::vector<int> &payloads, int pt) {
    return std::find(payloads.begin(), payloads.end(), pt) != payloads.end();
}

bool OPNRtpmapMatchesCodec(const std::string &rtpmapLine, const std::string &normalizedCodec) {
    std::string upper = rtpmapLine;
    std::transform(upper.begin(), upper.end(), upper.begin(), [](unsigned char c) { return (char)std::toupper(c); });
    if (normalizedCodec == "H265") {
        return upper.find(" H265/") != std::string::npos || upper.find(" HEVC/") != std::string::npos;
    }
    if (normalizedCodec == "AV1") return upper.find(" AV1/") != std::string::npos;
    if (normalizedCodec == "H264") return upper.find(" H264/") != std::string::npos;
    return false;
}

std::string OPNPayloadVectorToString(const std::vector<int> &payloads) {
    std::ostringstream out;
    for (size_t i = 0; i < payloads.size(); i++) {
        if (i) out << ",";
        out << payloads[i];
    }
    return out.str();
}

std::string OPNTrimAscii(std::string value) {
    while (!value.empty() && std::isspace((unsigned char)value.front())) value.erase(value.begin());
    while (!value.empty() && std::isspace((unsigned char)value.back())) value.pop_back();
    return value;
}

std::string OPNLowerAscii(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) { return (char)std::tolower(c); });
    return value;
}

std::string OPNFmtpParameterText(const std::string &line) {
    size_t pos = line.find_first_of(" \t");
    return pos == std::string::npos ? std::string() : line.substr(pos + 1);
}

std::vector<std::pair<std::string, std::string>> OPNParseFmtpParameters(const std::string &parameters) {
    std::vector<std::pair<std::string, std::string>> parsed;
    std::stringstream stream(parameters);
    std::string token;
    while (std::getline(stream, token, ';')) {
        token = OPNTrimAscii(token);
        if (token.empty()) continue;
        size_t equals = token.find('=');
        if (equals == std::string::npos) {
            parsed.emplace_back(OPNLowerAscii(token), std::string());
            continue;
        }
        parsed.emplace_back(OPNLowerAscii(OPNTrimAscii(token.substr(0, equals))), OPNTrimAscii(token.substr(equals + 1)));
    }
    return parsed;
}

std::string OPNGetFmtpParameter(const std::vector<std::pair<std::string, std::string>> &parameters,
                                const std::string &key) {
    std::string lowerKey = OPNLowerAscii(key);
    for (const auto &parameter : parameters) {
        if (parameter.first == lowerKey) return parameter.second;
    }
    return std::string();
}

int OPNFmtpIntValue(const std::string &value) {
    if (value.empty()) return -1;
    for (char c : value) {
        if (!std::isdigit((unsigned char)c)) return -1;
    }
    return atoi(value.c_str());
}

bool OPNSetFmtpParameter(std::vector<std::pair<std::string, std::string>> &parameters,
                         const std::string &key,
                         const std::string &value) {
    if (value.empty()) return false;
    std::string lowerKey = OPNLowerAscii(key);
    for (auto &parameter : parameters) {
        if (parameter.first != lowerKey) continue;
        if (parameter.second == value) return false;
        parameter.second = value;
        return true;
    }
    parameters.emplace_back(lowerKey, value);
    return true;
}

std::string OPNJoinFmtpParameters(const std::vector<std::pair<std::string, std::string>> &parameters) {
    std::string out;
    for (size_t i = 0; i < parameters.size(); i++) {
        if (i) out += ';';
        out += parameters[i].first;
        if (!parameters[i].second.empty()) {
            out += '=';
            out += parameters[i].second;
        }
    }
    return out;
}

std::unordered_set<int> OPNSdpVideoPayloadsForCodec(const std::string &sdp,
                                                    const std::string &normalizedCodec) {
    std::unordered_set<int> payloads;
    bool inVideo = false;
    for (const std::string &line : OPNSplitSdpLines(sdp)) {
        if (OPNStartsWith(line, "m=")) {
            inVideo = OPNStartsWith(line, "m=video");
            continue;
        }
        if (!inVideo || !OPNStartsWith(line, "a=rtpmap:")) continue;
        int pt = OPNPayloadTypeFromAttribute(line, "a=rtpmap:");
        if (pt >= 0 && OPNRtpmapMatchesCodec(line, normalizedCodec)) payloads.insert(pt);
    }
    return payloads;
}

std::unordered_map<int, std::string> OPNSdpVideoFmtpByPayload(const std::string &sdp) {
    std::unordered_map<int, std::string> fmtpByPayload;
    bool inVideo = false;
    for (const std::string &line : OPNSplitSdpLines(sdp)) {
        if (OPNStartsWith(line, "m=")) {
            inVideo = OPNStartsWith(line, "m=video");
            continue;
        }
        if (!inVideo || !OPNStartsWith(line, "a=fmtp:")) continue;
        int pt = OPNPayloadTypeFromAttribute(line, "a=fmtp:");
        if (pt >= 0) fmtpByPayload[pt] = OPNFmtpParameterText(line);
    }
    return fmtpByPayload;
}

std::string OPNExtractPublicIpImpl(const std::string &hostOrIp) {
    if (hostOrIp.empty()) return "";

    int dots = 0;
    int digits = 0;
    bool dotted = true;
    for (char c : hostOrIp) {
        if (c == '.') {
            if (digits == 0) {
                dotted = false;
                break;
            }
            dots++;
            digits = 0;
        } else if (std::isdigit((unsigned char)c)) {
            digits++;
            if (digits > 3) {
                dotted = false;
                break;
            }
        } else {
            dotted = false;
            break;
        }
    }
    if (dotted && dots == 3 && digits > 0) return hostOrIp;

    std::string firstLabel = hostOrIp.substr(0, hostOrIp.find('.'));
    std::vector<std::string> parts;
    std::stringstream stream(firstLabel);
    std::string part;
    while (std::getline(stream, part, '-')) {
        if (part.empty()) return "";
        for (char c : part) {
            if (!std::isdigit((unsigned char)c)) return "";
        }
        parts.push_back(part);
    }
    if (parts.size() != 4) return "";
    return parts[0] + "." + parts[1] + "." + parts[2] + "." + parts[3];
}

std::string OPNReplaceAll(std::string value, const std::string &from, const std::string &to) {
    if (from.empty()) return value;
    size_t pos = 0;
    while ((pos = value.find(from, pos)) != std::string::npos) {
        value.replace(pos, from.size(), to);
        pos += to.size();
    }
    return value;
}

}

OPNLibWebRTCIceCredentials OPNExtractIceCredentials(const std::string &sdp) {
    OPNLibWebRTCIceCredentials credentials;
    std::istringstream stream(sdp);
    std::string line;
    while (std::getline(stream, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (OPNStartsWith(line, "a=ice-ufrag:")) {
            credentials.ufrag = line.substr(12);
        } else if (OPNStartsWith(line, "a=ice-pwd:")) {
            credentials.pwd = line.substr(10);
        } else if (OPNStartsWith(line, "a=fingerprint:")) {
            credentials.fingerprint = line.substr(14);
        }
    }
    return credentials;
}

std::string OPNExtractPublicIp(const std::string &hostOrIp) {
    return OPNExtractPublicIpImpl(hostOrIp);
}

std::string OPNAlignH265AnswerFmtpToOffer(const std::string &answerSdp, const std::string &offerSdp) {
    std::unordered_set<int> answerH265Payloads = OPNSdpVideoPayloadsForCodec(answerSdp, "H265");
    if (answerH265Payloads.empty()) return answerSdp;

    std::unordered_set<int> offerH265Payloads = OPNSdpVideoPayloadsForCodec(offerSdp, "H265");
    std::unordered_map<int, std::string> offerFmtpByPayload = OPNSdpVideoFmtpByPayload(offerSdp);
    std::vector<std::string> lines = OPNSplitSdpLines(answerSdp);
    bool inVideo = false;
    int alignedLines = 0;

    for (std::string &line : lines) {
        if (OPNStartsWith(line, "m=")) {
            inVideo = OPNStartsWith(line, "m=video");
            continue;
        }
        if (!inVideo || !OPNStartsWith(line, "a=fmtp:")) continue;
        int pt = OPNPayloadTypeFromAttribute(line, "a=fmtp:");
        if (pt < 0 || answerH265Payloads.find(pt) == answerH265Payloads.end()) continue;
        if (offerH265Payloads.find(pt) == offerH265Payloads.end()) continue;

        auto offerFmtp = offerFmtpByPayload.find(pt);
        if (offerFmtp == offerFmtpByPayload.end()) continue;

        std::vector<std::pair<std::string, std::string>> answerParameters = OPNParseFmtpParameters(OPNFmtpParameterText(line));
        std::vector<std::pair<std::string, std::string>> offerParameters = OPNParseFmtpParameters(offerFmtp->second);
        bool changed = false;

        if (OPNGetFmtpParameter(answerParameters, "profile-id").empty()) {
            changed = OPNSetFmtpParameter(answerParameters, "profile-id", OPNGetFmtpParameter(offerParameters, "profile-id")) || changed;
        }
        if (OPNGetFmtpParameter(answerParameters, "tier-flag").empty()) {
            changed = OPNSetFmtpParameter(answerParameters, "tier-flag", OPNGetFmtpParameter(offerParameters, "tier-flag")) || changed;
        }

        std::string answerLevel = OPNGetFmtpParameter(answerParameters, "level-id");
        std::string offerLevel = OPNGetFmtpParameter(offerParameters, "level-id");
        int answerLevelValue = OPNFmtpIntValue(answerLevel);
        int offerLevelValue = OPNFmtpIntValue(offerLevel);
        if (answerLevel.empty() || (answerLevelValue >= 0 && offerLevelValue > answerLevelValue)) {
            changed = OPNSetFmtpParameter(answerParameters, "level-id", offerLevel) || changed;
        }

        if (!changed) continue;
        line = "a=fmtp:" + std::to_string(pt) + " " + OPNJoinFmtpParameters(answerParameters);
        alignedLines++;
    }

    if (alignedLines > 0) {
        OPNLogInfo(@"[LibWebRTC] Aligned H265 answer fmtp with offer payloads=%d", alignedLines);
    }
    return OPNJoinSdpLinesLike(lines, answerSdp);
}

std::string OPNFixServerIpInSdp(const std::string &sdp, const std::string &serverHostOrIp) {
    std::string ip = OPNExtractPublicIpImpl(serverHostOrIp);
    if (ip.empty()) return sdp;

    std::vector<std::string> lines = OPNSplitSdpLines(sdp);
    int connectionRewrites = 0;
    int candidateRewrites = 0;
    for (std::string &line : lines) {
        if (line == "c=IN IP4 0.0.0.0") {
            line = "c=IN IP4 " + ip;
            connectionRewrites++;
            continue;
        }
        if (!OPNStartsWith(line, "a=candidate:")) continue;

        std::vector<std::string> tokens;
        std::stringstream stream(line);
        std::string token;
        while (stream >> token) tokens.push_back(token);
        if (tokens.size() <= 4 || tokens[4] != "0.0.0.0") continue;
        tokens[4] = ip;
        std::string rewritten;
        for (size_t i = 0; i < tokens.size(); i++) {
            if (i) rewritten += ' ';
            rewritten += tokens[i];
        }
        line = rewritten;
        candidateRewrites++;
    }

    if (connectionRewrites > 0 || candidateRewrites > 0) {
        OPNLogInfo(@"[LibWebRTC] Fixed server IP in offer SDP ip=%s c-lines=%d candidates=%d",
              ip.c_str(),
              connectionRewrites,
              candidateRewrites);
    }
    return OPNJoinSdpLines(lines, sdp.find("\r\n") != std::string::npos ? "\r\n" : "\n");
}

std::string OPNMungeAnswerSdp(const std::string &sdp, int maxBitrateKbps) {
    std::vector<std::string> lines = OPNSplitSdpLines(sdp);
    std::vector<std::string> result;
    result.reserve(lines.size() + 4);
    int bitrateLines = 0;
    int stereoLines = 0;

    for (size_t i = 0; i < lines.size(); i++) {
        std::string line = lines[i];
        if (OPNStartsWith(line, "a=fmtp:") && line.find("minptime=") != std::string::npos && line.find("stereo=1") == std::string::npos) {
            line += ";stereo=1";
            stereoLines++;
        }
        result.push_back(line);

        if (OPNStartsWith(line, "m=video") || OPNStartsWith(line, "m=audio")) {
            const bool nextHasBandwidth = i + 1 < lines.size() && OPNStartsWith(lines[i + 1], "b=");
            if (!nextHasBandwidth) {
                int bitrate = OPNStartsWith(line, "m=video") ? std::max(1000, maxBitrateKbps) : 128;
                result.push_back("b=AS:" + std::to_string(bitrate));
                bitrateLines++;
            }
        }
    }

    if (bitrateLines > 0 || stereoLines > 0) {
        OPNLogInfo(@"[LibWebRTC] Munged answer SDP bitrateLines=%d stereoLines=%d videoBitrate=%dkbps",
              bitrateLines,
              stereoLines,
              std::max(1000, maxBitrateKbps));
    }
    return OPNJoinSdpLines(result, sdp.find("\r\n") != std::string::npos ? "\r\n" : "\n");
}

void OPNLogVideoSdpSummary(const char *label, const std::string &sdp) {
    bool inVideo = false;
    int logged = 0;
    for (const std::string &line : OPNSplitSdpLines(sdp)) {
        if (OPNStartsWith(line, "m=video")) {
            inVideo = true;
            OPNLogInfo(@"[LibWebRTC] %s %s", label, line.c_str());
            logged++;
            continue;
        }
        if (OPNStartsWith(line, "m=") && inVideo) break;
        if (!inVideo) continue;
        if (OPNStartsWith(line, "a=rtpmap:") || OPNStartsWith(line, "a=fmtp:") || OPNStartsWith(line, "a=rtcp-fb:")) {
            OPNLogInfo(@"[LibWebRTC] %s %s", label, line.c_str());
            logged++;
            if (logged >= 64) break;
        }
    }
}

bool OPNVideoSdpHasMediaCodec(const std::string &sdp) {
    bool inVideo = false;
    for (const std::string &line : OPNSplitSdpLines(sdp)) {
        if (OPNStartsWith(line, "m=video")) {
            inVideo = true;
            continue;
        }
        if (OPNStartsWith(line, "m=") && inVideo) break;
        if (!inVideo || !OPNStartsWith(line, "a=rtpmap:")) continue;

        std::string upper = line;
        std::transform(upper.begin(), upper.end(), upper.begin(), [](unsigned char c) { return (char)std::toupper(c); });
        if (upper.find(" H264/") != std::string::npos ||
            upper.find(" H265/") != std::string::npos ||
            upper.find(" HEVC/") != std::string::npos ||
            upper.find(" AV1/") != std::string::npos ||
            upper.find(" VP8/") != std::string::npos ||
            upper.find(" VP9/") != std::string::npos) {
            return true;
        }
    }
    return false;
}

std::string OPNRewriteH265OfferForReceiver(const std::string &sdp,
                                           int maxMainLevelId,
                                           int maxMain10LevelId,
                                           bool supportsHighTier) {
    std::vector<std::string> lines = OPNSplitSdpLines(sdp);
    std::unordered_set<int> h265Payloads;
    bool inVideo = false;

    for (const std::string &line : lines) {
        if (OPNStartsWith(line, "m=")) {
            inVideo = OPNStartsWith(line, "m=video");
            continue;
        }
        if (!inVideo || !OPNStartsWith(line, "a=rtpmap:")) continue;
        int pt = OPNPayloadTypeFromAttribute(line, "a=rtpmap:");
        if (pt >= 0 && OPNRtpmapMatchesCodec(line, "H265")) {
            h265Payloads.insert(pt);
        }
    }

    if (h265Payloads.empty()) return sdp;

    int tierRewrites = 0;
    for (std::string &line : lines) {
        if (!OPNStartsWith(line, "a=fmtp:")) continue;
        int pt = OPNPayloadTypeFromAttribute(line, "a=fmtp:");
        if (pt < 0 || h265Payloads.find(pt) == h265Payloads.end()) continue;

        if (!supportsHighTier && line.find("tier-flag=1") != std::string::npos) {
            line = OPNReplaceAll(line, "tier-flag=1", "tier-flag=0");
            tierRewrites++;
        }
    }

    if (tierRewrites > 0) {
        OPNLogInfo(@"[LibWebRTC] Rewrote H265 offer tier for receiver compatibility: tier=%d maxMain=%d maxMain10=%d highTier=%d",
              tierRewrites,
              maxMainLevelId,
              maxMain10LevelId,
              supportsHighTier);
    }
    return OPNJoinSdpLinesLike(lines, sdp);
}

std::string OPNNormalizeStatsCodecName(const std::string &codecId) {
    std::string upper = codecId;
    std::transform(upper.begin(), upper.end(), upper.begin(), [](unsigned char c) { return (char)std::toupper(c); });
    if (upper.find("H264") != std::string::npos) return "H264";
    if (upper.find("H265") != std::string::npos || upper.find("HEVC") != std::string::npos) return "H265";
    if (upper.find("AV1") != std::string::npos) return "AV1";
    if (upper.find("VP9") != std::string::npos || upper.find("VP09") != std::string::npos) return "VP9";
    if (upper.find("VP8") != std::string::npos) return "VP8";
    return codecId;
}

std::string OPNNormalizeCodec(std::string codec) {
    std::transform(codec.begin(), codec.end(), codec.begin(), [](unsigned char c) { return (char)std::toupper(c); });
    if (codec == "AUTO") return "H264";
    if (codec == "HEVC") return "H265";
    return codec;
}

bool OPNIsSupportedCodecPreference(const std::string &codec) {
    return codec == "H264" || codec == "H265" || codec == "AV1";
}

std::string OPNPreferCodecInOffer(const std::string &sdp, const std::string &normalizedCodec) {
    std::vector<std::string> lines = OPNSplitSdpLines(sdp);
    bool inVideo = false;
    std::vector<int> codecPayloads;
    std::vector<int> keptPayloads;

    for (const std::string &line : lines) {
        if (OPNStartsWith(line, "m=")) {
            inVideo = OPNStartsWith(line, "m=video");
            continue;
        }
        if (!inVideo || !OPNStartsWith(line, "a=rtpmap:")) continue;
        int pt = OPNPayloadTypeFromAttribute(line, "a=rtpmap:");
        if (pt >= 0 && OPNRtpmapMatchesCodec(line, normalizedCodec)) {
            codecPayloads.push_back(pt);
        }
    }

    if (codecPayloads.empty()) {
        OPNLogInfo(@"[LibWebRTC] Offer %s preference skipped; no matching payload found", normalizedCodec.c_str());
        return sdp;
    }

    keptPayloads = codecPayloads;
    inVideo = false;
    for (const std::string &line : lines) {
        if (OPNStartsWith(line, "m=")) {
            inVideo = OPNStartsWith(line, "m=video");
            continue;
        }
        if (!inVideo || !OPNStartsWith(line, "a=fmtp:")) continue;
        int pt = OPNPayloadTypeFromAttribute(line, "a=fmtp:");
        int apt = OPNAptFromFmtp(line);
        if (pt >= 0 && apt >= 0 && OPNPayloadVectorContains(codecPayloads, apt) && !OPNPayloadVectorContains(keptPayloads, pt)) {
            keptPayloads.push_back(pt);
        }
    }

    auto keepPayload = [&keptPayloads](int pt) {
        return std::find(keptPayloads.begin(), keptPayloads.end(), pt) != keptPayloads.end();
    };

    std::vector<std::string> filtered;
    filtered.reserve(lines.size());
    inVideo = false;
    int removedPayloadLines = 0;
    for (const std::string &line : lines) {
        if (OPNStartsWith(line, "m=")) {
            inVideo = OPNStartsWith(line, "m=video");
            if (inVideo) {
                std::stringstream stream(line);
                std::vector<std::string> tokens;
                std::string token;
                while (stream >> token) tokens.push_back(token);
                if (tokens.size() > 3) {
                    std::ostringstream mline;
                    mline << tokens[0] << " " << tokens[1] << " " << tokens[2];
                    for (int pt : keptPayloads) mline << " " << pt;
                    filtered.push_back(mline.str());
                    continue;
                }
            }
            filtered.push_back(line);
            continue;
        }

        if (inVideo && (OPNStartsWith(line, "a=rtpmap:") || OPNStartsWith(line, "a=fmtp:") || OPNStartsWith(line, "a=rtcp-fb:"))) {
            const char *prefix = OPNStartsWith(line, "a=rtpmap:") ? "a=rtpmap:" : OPNStartsWith(line, "a=fmtp:") ? "a=fmtp:" : "a=rtcp-fb:";
            int pt = OPNPayloadTypeFromAttribute(line, prefix);
            if (pt >= 0 && !keepPayload(pt)) {
                removedPayloadLines++;
                continue;
            }
        }
        filtered.push_back(line);
    }

    OPNLogInfo(@"[LibWebRTC] Preferred %s offer payloads (%zu codec=%s, %zu kept=%s), removed %d non-%s payload lines",
          normalizedCodec.c_str(),
          codecPayloads.size(),
          OPNPayloadVectorToString(codecPayloads).c_str(),
          keptPayloads.size(),
          OPNPayloadVectorToString(keptPayloads).c_str(),
          removedPayloadLines,
          normalizedCodec.c_str());
    return OPNJoinSdpLines(filtered, sdp.find("\r\n") != std::string::npos ? "\r\n" : "\n");
}

}
