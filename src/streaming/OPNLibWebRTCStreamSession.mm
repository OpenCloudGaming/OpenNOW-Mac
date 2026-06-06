#include "OPNLibWebRTCStreamSession.h"
#include "OPNVideoEnhancementRenderer.h"
#include "OPNWebRTCDataChannelUtils.h"
#include "common/OPNSentry.h"

#import <CoreAudio/CoreAudio.h>
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <AudioUnit/AudioUnit.h>

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cmath>
#include <climits>
#include <cstdio>
#include <cstdlib>
#include <sstream>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>
#include <objc/message.h>

#if defined(OPN_HAVE_LIBWEBRTC)
#import <WebRTC/WebRTC.h>
#import <WebRTC/RTCAudioDevice.h>
#import <WebRTC/RTCCVPixelBuffer.h>
#import <MetalKit/MetalKit.h>
#endif

@interface OPNAudioDeviceMonitorContext : NSObject
@property(nonatomic, assign) OPN::LibWebRTCStreamSession *owner;
@property(nonatomic, assign, getter=isActive) BOOL active;
@end

@implementation OPNAudioDeviceMonitorContext
@end

namespace OPN {

static constexpr int OPNPartialReliableInputLifetimeMs = 5;
[[maybe_unused]] static constexpr uint64_t OPNPartialReliableInputBacklogLimitBytes = 16 * 1024;

static AudioDeviceID OPNDefaultAudioDevice(AudioObjectPropertySelector selector) {
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    AudioObjectPropertyAddress address = {
        selector,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, nullptr, &size, &device) != noErr) {
        return kAudioObjectUnknown;
    }
    return device;
}

static OSStatus OPNAudioDevicesChanged(AudioObjectID,
                                       UInt32,
                                       const AudioObjectPropertyAddress *,
                                       void *clientData) {
    OPNAudioDeviceMonitorContext *context = (__bridge OPNAudioDeviceMonitorContext *)clientData;
    if (!context.isActive || !context.owner) return noErr;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (!context.isActive || !context.owner) return;
        context.owner->HandleAudioDeviceChange();
    });
    return noErr;
}

[[maybe_unused]] static NSString *OPNStringToNSString(const std::string &value) {
    return [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding] ?: @"";
}

[[maybe_unused]] static std::string OPNNSStringToString(NSString *value) {
    return value ? std::string(value.UTF8String ?: "") : std::string();
}

static void OPNLockRTCAudioSession(id audioSession) {
    SEL selector = NSSelectorFromString(@"lockForConfiguration");
    if ([audioSession respondsToSelector:selector]) {
        ((void (*)(id, SEL))objc_msgSend)(audioSession, selector);
    }
}

static void OPNUnlockRTCAudioSession(id audioSession) {
    SEL selector = NSSelectorFromString(@"unlockForConfiguration");
    if ([audioSession respondsToSelector:selector]) {
        ((void (*)(id, SEL))objc_msgSend)(audioSession, selector);
    }
}

[[maybe_unused]] static void OPNSetRTCAudioSessionActive(id audioSession, BOOL active, NSString *phase) {
    SEL selector = NSSelectorFromString(@"setActive:error:");
    if (![audioSession respondsToSelector:selector]) return;

    NSError *error = nil;
    BOOL ok = ((BOOL (*)(id, SEL, BOOL, NSError **))objc_msgSend)(audioSession, selector, active, &error);
    if (!ok || error) {
        OPN::LogError(@"[LibWebRTC] RTCAudioSession setActive=%d failed during %@: %@", active, phase, error.localizedDescription ?: @"unknown error");
    }
}

[[maybe_unused]] static void OPNResetRTCAudioSessionRouteToDefaults(id audioSession) {
    OPNLockRTCAudioSession(audioSession);

    SEL preferredInputSelector = NSSelectorFromString(@"setPreferredInput:error:");
    if ([audioSession respondsToSelector:preferredInputSelector]) {
        NSError *preferredInputError = nil;
        BOOL ok = ((BOOL (*)(id, SEL, id, NSError **))objc_msgSend)(audioSession, preferredInputSelector, nil, &preferredInputError);
        if (!ok || preferredInputError) {
            OPN::LogError(@"[LibWebRTC] RTCAudioSession clear preferred input failed: %@", preferredInputError.localizedDescription ?: @"unknown error");
        }
    }

    SEL outputOverrideSelector = NSSelectorFromString(@"overrideOutputAudioPort:error:");
    if ([audioSession respondsToSelector:outputOverrideSelector]) {
        NSError *outputOverrideError = nil;
        BOOL ok = ((BOOL (*)(id, SEL, NSInteger, NSError **))objc_msgSend)(audioSession, outputOverrideSelector, 0, &outputOverrideError);
        if (!ok || outputOverrideError) {
            OPN::LogError(@"[LibWebRTC] RTCAudioSession clear output override failed: %@", outputOverrideError.localizedDescription ?: @"unknown error");
        }
    }

    OPNUnlockRTCAudioSession(audioSession);
}

struct OPNLibWebRTCIceCredentials {
    std::string ufrag;
    std::string pwd;
    std::string fingerprint;
};

[[maybe_unused]] static bool OPNStartsWith(const std::string &value, const char *prefix) {
    const size_t prefixLen = std::char_traits<char>::length(prefix);
    return value.size() >= prefixLen && value.compare(0, prefixLen, prefix) == 0;
}

[[maybe_unused]] static OPNLibWebRTCIceCredentials OPNExtractIceCredentials(const std::string &sdp) {
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

[[maybe_unused]] static std::vector<std::string> OPNSplitSdpLines(const std::string &sdp) {
    std::vector<std::string> lines;
    std::stringstream stream(sdp);
    std::string line;
    while (std::getline(stream, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        lines.push_back(line);
    }
    return lines;
}

[[maybe_unused]] static std::string OPNJoinSdpLines(const std::vector<std::string> &lines, const std::string &lineEnding) {
    std::string out;
    for (size_t i = 0; i < lines.size(); i++) {
        out += lines[i];
        if (i + 1 < lines.size()) out += lineEnding;
    }
    return out;
}

[[maybe_unused]] static std::string OPNJoinSdpLinesLike(const std::vector<std::string> &lines, const std::string &originalSdp) {
    const std::string lineEnding = originalSdp.find("\r\n") != std::string::npos ? "\r\n" : "\n";
    std::string out = OPNJoinSdpLines(lines, lineEnding);
    if (!originalSdp.empty() && originalSdp.back() == '\n') {
        out += lineEnding;
    }
    return out;
}

[[maybe_unused]] static int OPNPayloadTypeFromAttribute(const std::string &line, const char *prefix) {
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

[[maybe_unused]] static int OPNAptFromFmtp(const std::string &line) {
    size_t pos = line.find("apt=");
    if (pos == std::string::npos) return -1;
    pos += strlen("apt=");
    size_t end = pos;
    while (end < line.size() && std::isdigit((unsigned char)line[end])) end++;
    if (end == pos) return -1;
    return atoi(line.substr(pos, end - pos).c_str());
}

[[maybe_unused]] static bool OPNPayloadVectorContains(const std::vector<int> &payloads, int pt) {
    return std::find(payloads.begin(), payloads.end(), pt) != payloads.end();
}

[[maybe_unused]] static bool OPNRtpmapMatchesCodec(const std::string &rtpmapLine, const std::string &normalizedCodec) {
    std::string upper = rtpmapLine;
    std::transform(upper.begin(), upper.end(), upper.begin(), [](unsigned char c) { return (char)std::toupper(c); });
    if (normalizedCodec == "H265") {
        return upper.find(" H265/") != std::string::npos || upper.find(" HEVC/") != std::string::npos;
    }
    if (normalizedCodec == "AV1") return upper.find(" AV1/") != std::string::npos;
    if (normalizedCodec == "H264") return upper.find(" H264/") != std::string::npos;
    return false;
}

[[maybe_unused]] static std::string OPNPayloadVectorToString(const std::vector<int> &payloads) {
    std::ostringstream out;
    for (size_t i = 0; i < payloads.size(); i++) {
        if (i) out << ",";
        out << payloads[i];
    }
    return out.str();
}

[[maybe_unused]] static std::string OPNExtractPublicIp(const std::string &hostOrIp) {
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

[[maybe_unused]] static std::string OPNFixServerIpInSdp(const std::string &sdp, const std::string &serverHostOrIp) {
    std::string ip = OPNExtractPublicIp(serverHostOrIp);
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
        OPN::LogInfo(@"[LibWebRTC] Fixed server IP in offer SDP ip=%s c-lines=%d candidates=%d",
              ip.c_str(),
              connectionRewrites,
              candidateRewrites);
    }
    return OPNJoinSdpLines(lines, sdp.find("\r\n") != std::string::npos ? "\r\n" : "\n");
}

[[maybe_unused]] static std::string OPNMungeAnswerSdp(const std::string &sdp, int maxBitrateKbps) {
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
        OPN::LogInfo(@"[LibWebRTC] Munged answer SDP bitrateLines=%d stereoLines=%d videoBitrate=%dkbps",
              bitrateLines,
              stereoLines,
              std::max(1000, maxBitrateKbps));
    }
    return OPNJoinSdpLines(result, sdp.find("\r\n") != std::string::npos ? "\r\n" : "\n");
}

[[maybe_unused]] static void OPNLogVideoSdpSummary(const char *label, const std::string &sdp) {
    bool inVideo = false;
    int logged = 0;
    for (const std::string &line : OPNSplitSdpLines(sdp)) {
        if (OPNStartsWith(line, "m=video")) {
            inVideo = true;
            OPN::LogInfo(@"[LibWebRTC] %s %s", label, line.c_str());
            logged++;
            continue;
        }
        if (OPNStartsWith(line, "m=") && inVideo) break;
        if (!inVideo) continue;
        if (OPNStartsWith(line, "a=rtpmap:") || OPNStartsWith(line, "a=fmtp:") || OPNStartsWith(line, "a=rtcp-fb:")) {
            OPN::LogInfo(@"[LibWebRTC] %s %s", label, line.c_str());
            logged++;
            if (logged >= 64) break;
        }
    }
}

[[maybe_unused]] static bool OPNVideoSdpHasMediaCodec(const std::string &sdp) {
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

[[maybe_unused]] static std::string OPNReplaceAll(std::string value, const std::string &from, const std::string &to) {
    if (from.empty()) return value;
    size_t pos = 0;
    while ((pos = value.find(from, pos)) != std::string::npos) {
        value.replace(pos, from.size(), to);
        pos += to.size();
    }
    return value;
}

[[maybe_unused]] static std::string OPNRewriteH265OfferForReceiver(const std::string &sdp,
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
        OPN::LogInfo(@"[LibWebRTC] Rewrote H265 offer tier for receiver compatibility: tier=%d maxMain=%d maxMain10=%d highTier=%d",
              tierRewrites,
              maxMainLevelId,
              maxMain10LevelId,
              supportsHighTier);
    }
    return OPNJoinSdpLinesLike(lines, sdp);
}

[[maybe_unused]] static std::vector<std::string> OPNSplitResolution(const std::string &resolution) {
    const size_t x = resolution.find('x');
    if (x == std::string::npos) return {"1920", "1080"};
    std::string width = resolution.substr(0, x);
    std::string height = resolution.substr(x + 1);
    if (width.empty() || height.empty()) return {"1920", "1080"};
    return {width, height};
}

[[maybe_unused]] static int OPNStringToPositiveInt(const std::string &value, int fallback) {
    if (value.empty()) return fallback;
    char *end = nullptr;
    long parsed = strtol(value.c_str(), &end, 10);
    if (end == value.c_str() || parsed <= 0 || parsed > INT_MAX) return fallback;
    return (int)parsed;
}

[[maybe_unused]] static uint64_t OPNMonotonicMs() {
    using Clock = std::chrono::steady_clock;
    return (uint64_t)std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now().time_since_epoch()).count();
}

[[maybe_unused]] static bool OPNEnvFlagEnabled(const char *name, bool defaultValue) {
    const char *value = getenv(name);
    if (!value || !*value) return defaultValue;
    std::string normalized(value);
    std::transform(normalized.begin(), normalized.end(), normalized.begin(), [](unsigned char c) { return (char)std::tolower(c); });
    return !(normalized == "0" || normalized == "false" || normalized == "no" || normalized == "off");
}

[[maybe_unused]] static double OPNStatsSecondsToMs(double seconds) {
    return seconds * 1000.0;
}

[[maybe_unused]] static std::string OPNNormalizeStatsCodecName(const std::string &codecId) {
    std::string upper = codecId;
    std::transform(upper.begin(), upper.end(), upper.begin(), [](unsigned char c) { return (char)std::toupper(c); });
    if (upper.find("H264") != std::string::npos) return "H264";
    if (upper.find("H265") != std::string::npos || upper.find("HEVC") != std::string::npos) return "H265";
    if (upper.find("AV1") != std::string::npos) return "AV1";
    if (upper.find("VP9") != std::string::npos || upper.find("VP09") != std::string::npos) return "VP9";
    if (upper.find("VP8") != std::string::npos) return "VP8";
    return codecId;
}

[[maybe_unused]] static std::string OPNNormalizeCodec(std::string codec) {
    std::transform(codec.begin(), codec.end(), codec.begin(), [](unsigned char c) { return (char)std::toupper(c); });
    if (codec == "AUTO") return "H264";
    if (codec == "HEVC") return "H265";
    return codec;
}

[[maybe_unused]] static bool OPNIsSupportedCodecPreference(const std::string &codec) {
    return codec == "H264" || codec == "H265" || codec == "AV1";
}

#if defined(OPN_HAVE_LIBWEBRTC)
[[maybe_unused]] static bool OPNCodecCapabilityMatches(RTCRtpCodecCapability *codec, const std::string &normalizedCodec) {
    NSString *name = codec.name ?: @"";
    NSString *mimeType = codec.mimeType ?: @"";
    NSString *combined = [[NSString stringWithFormat:@"%@ %@", name, mimeType] uppercaseString];
    if (normalizedCodec == "H265") return [combined containsString:@"H265"] || [combined containsString:@"HEVC"];
    if (normalizedCodec == "H264") return [combined containsString:@"H264"];
    if (normalizedCodec == "AV1") return [combined containsString:@"AV1"];
    return false;
}

[[maybe_unused]] static bool OPNCodecCapabilityIsTransportSupport(RTCRtpCodecCapability *codec) {
    NSString *name = [codec.name ?: @"" uppercaseString];
    NSString *mimeType = [codec.mimeType ?: @"" uppercaseString];
    return [name isEqualToString:@"RTX"] || [name isEqualToString:@"RED"] ||
           [name isEqualToString:@"ULPFEC"] || [name isEqualToString:@"FLEXFEC-03"] ||
           [mimeType containsString:@"/RTX"] || [mimeType containsString:@"/RED"] ||
           [mimeType containsString:@"/ULPFEC"] || [mimeType containsString:@"/FLEXFEC-03"];
}
#endif

[[maybe_unused]] static std::string OPNPreferCodecInOffer(const std::string &sdp, const std::string &normalizedCodec) {
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
        OPN::LogInfo(@"[LibWebRTC] Offer %s preference skipped; no matching payload found", normalizedCodec.c_str());
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

    OPN::LogInfo(@"[LibWebRTC] Preferred %s offer payloads (%zu codec=%s, %zu kept=%s), removed %d non-%s payload lines",
          normalizedCodec.c_str(),
          codecPayloads.size(),
          OPNPayloadVectorToString(codecPayloads).c_str(),
          keptPayloads.size(),
          OPNPayloadVectorToString(keptPayloads).c_str(),
          removedPayloadLines,
          normalizedCodec.c_str());
    return OPNJoinSdpLines(filtered, sdp.find("\r\n") != std::string::npos ? "\r\n" : "\n");
}

[[maybe_unused]] static std::string OPNBuildNvstSdp(const StreamSettings &settings, const OPNLibWebRTCIceCredentials &credentials) {
    std::vector<std::string> resolution = OPNSplitResolution(settings.resolution);
    const int width = OPNStringToPositiveInt(resolution[0], 1920);
    const int height = OPNStringToPositiveInt(resolution[1], 1080);
    const int maxBitrateKbps = std::max(1000, settings.maxBitrateMbps * 1000);
    const int minBitrateKbps = std::max(5000, maxBitrateKbps * 35 / 100);
    const int initialBitrateKbps = std::max(minBitrateKbps, maxBitrateKbps * 70 / 100);
    const int bitDepth = OPNStartsWith(settings.colorQuality, "10bit") ? 10 : 8;
    const std::string codec = OPNNormalizeCodec(settings.codec);
    const int prefilterMode = std::max(0, std::min(settings.prefilterMode, 2));
    const int prefilterSharpness = std::max(0, std::min(settings.prefilterSharpness, 10));
    const int prefilterDenoise = std::max(0, std::min(settings.prefilterDenoise, 10));
    const int prefilterModel = std::max(0, settings.prefilterModel);
    const bool isAv1 = codec == "AV1";
    const bool isHighFps = settings.fps >= 90;
    const bool is120Fps = settings.fps == 120;
    const bool is240Fps = settings.fps >= 240;

    std::vector<std::string> lines = {
        "v=0",
        "o=SdpTest test_id_13 14 IN IPv4 127.0.0.1",
        "s=-",
        "t=0 0",
        "a=general.icePassword:" + credentials.pwd,
        "a=general.iceUserNameFragment:" + credentials.ufrag,
        "a=general.dtlsFingerprint:" + credentials.fingerprint,
        "m=video 0 RTP/AVP",
        "a=msid:fbc-video-0",
        "a=vqos.fec.rateDropWindow:10",
        "a=vqos.fec.minRequiredFecPackets:2",
        "a=vqos.fec.repairMinPercent:5",
        "a=vqos.fec.repairPercent:5",
        "a=vqos.fec.repairMaxPercent:35",
        "a=vqos.dynamicStreamingMode:0",
        "a=vqos.drc.enable:0",
        "a=vqos.dfc.enable:0",
        "a=vqos.dfc.adjustResAndFps:0",
        "a=video.dx9EnableNv12:1",
        "a=video.dx9EnableHdr:1",
        "a=vqos.qpg.enable:1",
        "a=vqos.resControl.qp.qpg.featureSetting:7",
        "a=bwe.useOwdCongestionControl:1",
        "a=video.enableRtpNack:1",
        "a=vqos.bw.txRxLag.minFeedbackTxDeltaMs:200",
        "a=vqos.drc.bitrateIirFilterFactor:18",
        "a=video.packetSize:1140",
        "a=packetPacing.minNumPacketsPerGroup:15",
    };

    if (isHighFps) {
        lines.insert(lines.end(), {
            "a=bwe.iirFilterFactor:8",
            "a=video.encoderFeatureSetting:47",
            "a=video.encoderPreset:6",
            "a=vqos.resControl.cpmRtc.badNwSkipFramesCount:600",
            "a=vqos.resControl.cpmRtc.decodeTimeThresholdMs:9",
            std::string("a=video.fbcDynamicFpsGrabTimeoutMs:") + (is120Fps ? "6" : "18"),
            std::string("a=vqos.resControl.cpmRtc.serverResolutionUpdateCoolDownCount:") + (is120Fps ? "6000" : "12000"),
        });
    }

    if (is240Fps) {
        lines.insert(lines.end(), {
            "a=video.enableNextCaptureMode:1",
            "a=vqos.maxStreamFpsEstimate:240",
            "a=video.videoSplitEncodeStripsPerFrame:3",
            "a=video.updateSplitEncodeStateDynamically:1",
        });
    }

    lines.insert(lines.end(), {
        "a=vqos.adjustStreamingFpsDuringOutOfFocus:1",
        "a=vqos.resControl.cpmRtc.ignoreOutOfFocusWindowState:1",
        "a=vqos.resControl.perfHistory.rtcIgnoreOutOfFocusWindowState:1",
        "a=vqos.resControl.cpmRtc.featureMask:0",
        "a=vqos.resControl.cpmRtc.enable:0",
        "a=vqos.resControl.cpmRtc.minResolutionPercent:100",
        "a=vqos.resControl.cpmRtc.resolutionChangeHoldonMs:999999",
        std::string("a=packetPacing.numGroups:") + (is120Fps ? "3" : "5"),
        "a=packetPacing.maxDelayUs:1000",
        "a=packetPacing.minNumPacketsFrame:10",
        "a=video.rtpNackQueueLength:1024",
        "a=video.rtpNackQueueMaxPackets:512",
        "a=video.rtpNackMaxPacketCount:25",
        "a=vqos.drc.qpMaxResThresholdAdj:4",
        "a=vqos.grc.qpMaxResThresholdAdj:4",
        "a=vqos.drc.iirFilterFactor:100",
    });

    if (isAv1) {
        lines.insert(lines.end(), {
            "a=vqos.drc.minQpHeadroom:20",
            "a=vqos.drc.lowerQpThreshold:100",
            "a=vqos.drc.upperQpThreshold:200",
            "a=vqos.drc.minAdaptiveQpThreshold:180",
            "a=vqos.drc.qpCodecThresholdAdj:0",
            "a=vqos.drc.qpMaxResThresholdAdj:20",
            "a=vqos.dfc.minQpHeadroom:20",
            "a=vqos.dfc.qpLowerLimit:100",
            "a=vqos.dfc.qpMaxUpperLimit:200",
            "a=vqos.dfc.qpMinUpperLimit:180",
            "a=vqos.dfc.qpMaxResThresholdAdj:20",
            "a=vqos.dfc.qpCodecThresholdAdj:0",
            "a=vqos.grc.minQpHeadroom:20",
            "a=vqos.grc.lowerQpThreshold:100",
            "a=vqos.grc.upperQpThreshold:200",
            "a=vqos.grc.minAdaptiveQpThreshold:180",
            "a=vqos.grc.qpMaxResThresholdAdj:20",
            "a=vqos.grc.qpCodecThresholdAdj:0",
            "a=video.minQp:25",
            "a=video.enableAv1RcPrecisionFactor:1",
        });
    }

    lines.insert(lines.end(), {
        "a=video.clientViewportWd:" + std::to_string(width),
        "a=video.clientViewportHt:" + std::to_string(height),
        "a=video.maxFPS:" + std::to_string(settings.fps),
        "a=video.initialBitrateKbps:" + std::to_string(initialBitrateKbps),
        "a=video.initialPeakBitrateKbps:" + std::to_string(maxBitrateKbps),
        "a=vqos.bw.maximumBitrateKbps:" + std::to_string(maxBitrateKbps),
        "a=vqos.bw.minimumBitrateKbps:" + std::to_string(minBitrateKbps),
        "a=vqos.bw.peakBitrateKbps:" + std::to_string(maxBitrateKbps),
        "a=vqos.bw.serverPeakBitrateKbps:" + std::to_string(maxBitrateKbps),
        "a=vqos.bw.enableBandwidthEstimation:1",
        "a=vqos.bw.disableBitrateLimit:0",
        "a=vqos.grc.maximumBitrateKbps:" + std::to_string(maxBitrateKbps),
        "a=vqos.grc.enable:0",
        "a=video.maxNumReferenceFrames:4",
        "a=video.mapRtpTimestampsToFrames:1",
        "a=video.encoderCscMode:3",
        "a=video.dynamicRangeMode:0",
        "a=video.bitDepth:" + std::to_string(bitDepth),
        std::string("a=video.scalingFeature1:") + (isAv1 ? "1" : "0"),
        "a=video.prefilterParams.prefilterMode:" + std::to_string(prefilterMode),
        "a=video.prefilterParams.prefilterModel:" + std::to_string(prefilterModel),
        "a=video.prefilterParams.sharpnessLevel:" + std::to_string(prefilterSharpness),
        "a=video.prefilterParams.denoiseLevel:" + std::to_string(prefilterDenoise),
        "m=audio 0 RTP/AVP",
        "a=msid:audio",
        "m=mic 0 RTP/AVP",
        "a=msid:mic",
        "a=rtpmap:0 PCMU/8000",
        "m=application 0 RTP/AVP",
        "a=msid:input_1",
        "a=ri.partialReliableThresholdMs:" + std::to_string(OPNPartialReliableInputLifetimeMs),
        "a=ri.hidDeviceMask:4294967295",
        "a=ri.enablePartiallyReliableTransferGamepad:15",
        "a=ri.enablePartiallyReliableTransferHid:4294967295",
        "",
    });

    std::string result;
    for (const std::string &line : lines) {
        result += line;
        result += '\n';
    }
    return result;
}

#if defined(OPN_HAVE_LIBWEBRTC)
class LibWebRTCStreamSession;
}

@interface OPNCoreAudioRTCDevice : NSObject <RTCAudioDevice>
@property(nonatomic, assign) OPN::LibWebRTCStreamSession *owner;
- (void)handleDefaultDeviceChange;
@end

@interface OPNCoreAudioRTCDevice () {
    dispatch_queue_t _audioQueue;
    AudioUnit _playoutUnit;
    AudioUnit _recordingUnit;
    AudioDeviceID _outputDevice;
    AudioDeviceID _inputDevice;
    std::vector<uint8_t> _recordingScratch;
}
@property(nonatomic, weak) id<RTCAudioDeviceDelegate> delegate;
@property(nonatomic, assign) double deviceInputSampleRate;
@property(nonatomic, assign) NSTimeInterval inputIOBufferDuration;
@property(nonatomic, assign) NSInteger inputNumberOfChannels;
@property(nonatomic, assign) NSTimeInterval inputLatency;
@property(nonatomic, assign) double deviceOutputSampleRate;
@property(nonatomic, assign) NSTimeInterval outputIOBufferDuration;
@property(nonatomic, assign) NSInteger outputNumberOfChannels;
@property(nonatomic, assign) NSTimeInterval outputLatency;
@property(nonatomic, assign) BOOL isInitialized;
@property(nonatomic, assign) BOOL isPlayoutInitialized;
@property(nonatomic, assign) BOOL isPlaying;
@property(nonatomic, assign) BOOL isRecordingInitialized;
@property(nonatomic, assign) BOOL isRecording;
- (OSStatus)renderPlayoutWithFlags:(AudioUnitRenderActionFlags *)actionFlags
                         timestamp:(const AudioTimeStamp *)timestamp
                         busNumber:(NSInteger)busNumber
                        frameCount:(UInt32)frameCount
                        outputData:(AudioBufferList *)outputData;
- (OSStatus)captureRecordingWithFlags:(AudioUnitRenderActionFlags *)actionFlags
                            timestamp:(const AudioTimeStamp *)timestamp
                            busNumber:(NSInteger)busNumber
                           frameCount:(UInt32)frameCount;
@end

static OSStatus OPNCoreAudioPlayoutCallback(void *refCon,
                                            AudioUnitRenderActionFlags *actionFlags,
                                            const AudioTimeStamp *timestamp,
                                            UInt32 busNumber,
                                            UInt32 frameCount,
                                            AudioBufferList *outputData) {
    return [(__bridge OPNCoreAudioRTCDevice *)refCon renderPlayoutWithFlags:actionFlags
                                                                  timestamp:timestamp
                                                                  busNumber:(NSInteger)busNumber
                                                                 frameCount:frameCount
                                                                 outputData:outputData];
}

static OSStatus OPNCoreAudioRecordingCallback(void *refCon,
                                              AudioUnitRenderActionFlags *actionFlags,
                                              const AudioTimeStamp *timestamp,
                                              UInt32 busNumber,
                                              UInt32 frameCount,
                                              AudioBufferList *) {
    return [(__bridge OPNCoreAudioRTCDevice *)refCon captureRecordingWithFlags:actionFlags
                                                                     timestamp:timestamp
                                                                     busNumber:(NSInteger)busNumber
                                                                    frameCount:frameCount];
}

@implementation OPNCoreAudioRTCDevice

- (instancetype)init {
    self = [super init];
    if (self) {
        _audioQueue = dispatch_queue_create("io.opencg.opennow.webrtc.coreaudio", DISPATCH_QUEUE_SERIAL);
        _playoutUnit = nullptr;
        _recordingUnit = nullptr;
        _outputDevice = kAudioObjectUnknown;
        _inputDevice = kAudioObjectUnknown;
        [self updateDeviceParameters];
    }
    return self;
}

- (void)dealloc {
    [self terminateDevice];
}

- (BOOL)initializeWithDelegate:(id<RTCAudioDeviceDelegate>)delegate {
    dispatch_sync(_audioQueue, ^{
        self.delegate = delegate;
        self.isInitialized = YES;
        [self updateDeviceParameters];
    });
    return YES;
}

- (BOOL)terminateDevice {
    dispatch_sync(_audioQueue, ^{
        [self stopPlayoutLocked];
        [self stopRecordingLocked];
        [self disposePlayoutUnitLocked];
        [self disposeRecordingUnitLocked];
        self.delegate = nil;
        self.isInitialized = NO;
        self.isPlayoutInitialized = NO;
        self.isRecordingInitialized = NO;
    });
    return YES;
}

- (BOOL)initializePlayout {
    __block BOOL ok = NO;
    dispatch_sync(_audioQueue, ^{ ok = [self initializePlayoutLocked]; });
    return ok;
}

- (BOOL)startPlayout {
    __block BOOL ok = NO;
    dispatch_sync(_audioQueue, ^{ ok = [self startPlayoutLocked]; });
    return ok;
}

- (BOOL)stopPlayout {
    dispatch_sync(_audioQueue, ^{ [self stopPlayoutLocked]; });
    return YES;
}

- (BOOL)initializeRecording {
    __block BOOL ok = NO;
    dispatch_sync(_audioQueue, ^{ ok = [self initializeRecordingLocked]; });
    return ok;
}

- (BOOL)startRecording {
    __block BOOL ok = NO;
    dispatch_sync(_audioQueue, ^{ ok = [self startRecordingLocked]; });
    return ok;
}

- (BOOL)stopRecording {
    dispatch_sync(_audioQueue, ^{ [self stopRecordingLocked]; });
    return YES;
}

- (void)handleDefaultDeviceChange {
    dispatch_async(_audioQueue, ^{
        BOOL restartPlayout = self.isPlaying;
        BOOL restartRecording = self.isRecording;
        [self stopPlayoutLocked];
        [self stopRecordingLocked];
        [self disposePlayoutUnitLocked];
        [self disposeRecordingUnitLocked];
        [self updateDeviceParameters];
        id<RTCAudioDeviceDelegate> delegate = self.delegate;
        if (delegate) {
            [delegate dispatchAsync:^{
                [delegate notifyAudioOutputInterrupted];
                [delegate notifyAudioInputInterrupted];
                [delegate notifyAudioOutputParametersChange];
                [delegate notifyAudioInputParametersChange];
            }];
        }
        if (restartPlayout) [self startPlayoutLocked];
        if (restartRecording) [self startRecordingLocked];
        OPN::LogInfo(@"[LibWebRTC] CoreAudio RTC device hot-swapped input=%u output=%u play=%d record=%d",
              _inputDevice,
              _outputDevice,
              self.isPlaying,
              self.isRecording);
    });
}

- (OSStatus)renderPlayoutWithFlags:(AudioUnitRenderActionFlags *)actionFlags
                         timestamp:(const AudioTimeStamp *)timestamp
                         busNumber:(NSInteger)busNumber
                        frameCount:(UInt32)frameCount
                        outputData:(AudioBufferList *)outputData {
    id<RTCAudioDeviceDelegate> delegate = self.delegate;
    if (!delegate || !outputData) {
        [self clearAudioBufferList:outputData];
        return noErr;
    }
    OSStatus status = delegate.getPlayoutData(actionFlags, timestamp, busNumber, frameCount, outputData);
    if (status != noErr) [self clearAudioBufferList:outputData];
    if (status == noErr && self.owner && outputData) {
        self.owner->HandleGameAudioFrame(outputData,
                                         frameCount,
                                         self.deviceOutputSampleRate,
                                         (uint32_t)self.outputNumberOfChannels);
    }
    return status;
}

- (OSStatus)captureRecordingWithFlags:(AudioUnitRenderActionFlags *)actionFlags
                            timestamp:(const AudioTimeStamp *)timestamp
                            busNumber:(NSInteger)busNumber
                           frameCount:(UInt32)frameCount {
    id<RTCAudioDeviceDelegate> delegate = self.delegate;
    if (!delegate || !_recordingUnit) return noErr;
    AudioStreamBasicDescription format = [self streamFormatWithSampleRate:self.deviceInputSampleRate channels:(UInt32)self.inputNumberOfChannels];
    size_t requiredBytes = (size_t)frameCount * format.mBytesPerFrame;
    if (_recordingScratch.size() < requiredBytes) _recordingScratch.resize(requiredBytes);
    AudioBufferList inputData;
    inputData.mNumberBuffers = 1;
    inputData.mBuffers[0].mNumberChannels = (UInt32)self.inputNumberOfChannels;
    inputData.mBuffers[0].mDataByteSize = (UInt32)requiredBytes;
    inputData.mBuffers[0].mData = _recordingScratch.data();
    OSStatus status = AudioUnitRender(_recordingUnit, actionFlags, timestamp, 1, frameCount, &inputData);
    if (status != noErr) return status;
    return delegate.deliverRecordedData(actionFlags, timestamp, busNumber, frameCount, &inputData, nil, nil);
}

- (BOOL)startPlayoutLocked {
    if (![self initializePlayoutLocked]) return NO;
    OSStatus status = AudioOutputUnitStart(_playoutUnit);
    self.isPlaying = status == noErr;
    if (status != noErr) OPN::LogError(@"[LibWebRTC] CoreAudio playout start failed status=%d", status);
    return self.isPlaying;
}

- (BOOL)startRecordingLocked {
    if (![self initializeRecordingLocked]) return NO;
    OSStatus status = AudioOutputUnitStart(_recordingUnit);
    self.isRecording = status == noErr;
    if (status != noErr) OPN::LogError(@"[LibWebRTC] CoreAudio recording start failed status=%d", status);
    return self.isRecording;
}

- (void)stopPlayoutLocked {
    if (_playoutUnit && self.isPlaying) AudioOutputUnitStop(_playoutUnit);
    self.isPlaying = NO;
}

- (void)stopRecordingLocked {
    if (_recordingUnit && self.isRecording) AudioOutputUnitStop(_recordingUnit);
    self.isRecording = NO;
}

- (BOOL)initializePlayoutLocked {
    if (self.isPlayoutInitialized && _playoutUnit) return YES;
    [self updateDeviceParameters];
    if (_outputDevice == kAudioObjectUnknown) return NO;
    _playoutUnit = [self createHALOutputUnit];
    if (!_playoutUnit) return NO;
    UInt32 enable = 1;
    UInt32 disable = 0;
    AudioUnitSetProperty(_playoutUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enable, sizeof(enable));
    AudioUnitSetProperty(_playoutUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &disable, sizeof(disable));
    OSStatus status = AudioUnitSetProperty(_playoutUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &_outputDevice, sizeof(_outputDevice));
    if (status != noErr) OPN::LogError(@"[LibWebRTC] CoreAudio set output device failed status=%d device=%u", status, _outputDevice);
    AudioStreamBasicDescription format = [self streamFormatWithSampleRate:self.deviceOutputSampleRate channels:(UInt32)self.outputNumberOfChannels];
    AudioUnitSetProperty(_playoutUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sizeof(format));
    AURenderCallbackStruct callback = { OPNCoreAudioPlayoutCallback, (__bridge void *)self };
    AudioUnitSetProperty(_playoutUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof(callback));
    status = AudioUnitInitialize(_playoutUnit);
    if (status != noErr) {
        OPN::LogError(@"[LibWebRTC] CoreAudio playout initialize failed status=%d", status);
        [self disposePlayoutUnitLocked];
        return NO;
    }
    self.isPlayoutInitialized = YES;
    return YES;
}

- (BOOL)initializeRecordingLocked {
    if (self.isRecordingInitialized && _recordingUnit) return YES;
    [self updateDeviceParameters];
    if (_inputDevice == kAudioObjectUnknown) return NO;
    _recordingUnit = [self createHALOutputUnit];
    if (!_recordingUnit) return NO;
    UInt32 enable = 1;
    UInt32 disable = 0;
    AudioUnitSetProperty(_recordingUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable, sizeof(disable));
    AudioUnitSetProperty(_recordingUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, sizeof(enable));
    OSStatus status = AudioUnitSetProperty(_recordingUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &_inputDevice, sizeof(_inputDevice));
    if (status != noErr) OPN::LogError(@"[LibWebRTC] CoreAudio set input device failed status=%d device=%u", status, _inputDevice);
    AudioStreamBasicDescription format = [self streamFormatWithSampleRate:self.deviceInputSampleRate channels:(UInt32)self.inputNumberOfChannels];
    AudioUnitSetProperty(_recordingUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, sizeof(format));
    AURenderCallbackStruct callback = { OPNCoreAudioRecordingCallback, (__bridge void *)self };
    AudioUnitSetProperty(_recordingUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, sizeof(callback));
    status = AudioUnitInitialize(_recordingUnit);
    if (status != noErr) {
        OPN::LogError(@"[LibWebRTC] CoreAudio recording initialize failed status=%d", status);
        [self disposeRecordingUnitLocked];
        return NO;
    }
    self.isRecordingInitialized = YES;
    return YES;
}

- (AudioUnit)createHALOutputUnit {
    AudioComponentDescription desc = {};
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_HALOutput;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    AudioComponent component = AudioComponentFindNext(nullptr, &desc);
    if (!component) return nullptr;
    AudioUnit unit = nullptr;
    OSStatus status = AudioComponentInstanceNew(component, &unit);
    if (status != noErr) {
        OPN::LogError(@"[LibWebRTC] CoreAudio HAL unit creation failed status=%d", status);
        return nullptr;
    }
    return unit;
}

- (void)disposePlayoutUnitLocked {
    if (!_playoutUnit) return;
    AudioUnitUninitialize(_playoutUnit);
    AudioComponentInstanceDispose(_playoutUnit);
    _playoutUnit = nullptr;
    self.isPlayoutInitialized = NO;
}

- (void)disposeRecordingUnitLocked {
    if (!_recordingUnit) return;
    AudioUnitUninitialize(_recordingUnit);
    AudioComponentInstanceDispose(_recordingUnit);
    _recordingUnit = nullptr;
    self.isRecordingInitialized = NO;
}

- (void)updateDeviceParameters {
    _inputDevice = OPN::OPNDefaultAudioDevice(kAudioHardwarePropertyDefaultInputDevice);
    _outputDevice = OPN::OPNDefaultAudioDevice(kAudioHardwarePropertyDefaultOutputDevice);
    self.deviceInputSampleRate = [self nominalSampleRateForDevice:_inputDevice fallback:self.delegate.preferredInputSampleRate > 0.0 ? self.delegate.preferredInputSampleRate : 48000.0];
    self.deviceOutputSampleRate = [self nominalSampleRateForDevice:_outputDevice fallback:self.delegate.preferredOutputSampleRate > 0.0 ? self.delegate.preferredOutputSampleRate : 48000.0];
    self.inputNumberOfChannels = std::max<NSInteger>(1, std::min<NSInteger>(2, [self channelCountForDevice:_inputDevice scope:kAudioDevicePropertyScopeInput fallback:1]));
    self.outputNumberOfChannels = std::max<NSInteger>(1, std::min<NSInteger>(2, [self channelCountForDevice:_outputDevice scope:kAudioDevicePropertyScopeOutput fallback:2]));
    self.inputIOBufferDuration = self.delegate.preferredInputIOBufferDuration > 0.0 ? self.delegate.preferredInputIOBufferDuration : 0.01;
    self.outputIOBufferDuration = self.delegate.preferredOutputIOBufferDuration > 0.0 ? self.delegate.preferredOutputIOBufferDuration : 0.01;
    self.inputLatency = [self latencyForDevice:_inputDevice scope:kAudioDevicePropertyScopeInput];
    self.outputLatency = [self latencyForDevice:_outputDevice scope:kAudioDevicePropertyScopeOutput];
}

- (double)nominalSampleRateForDevice:(AudioDeviceID)device fallback:(double)fallback {
    if (device == kAudioObjectUnknown) return fallback;
    Float64 rate = fallback;
    UInt32 size = sizeof(rate);
    AudioObjectPropertyAddress address = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, &rate) != noErr || rate <= 0.0) return fallback;
    return rate;
}

- (NSInteger)channelCountForDevice:(AudioDeviceID)device scope:(AudioObjectPropertyScope)scope fallback:(NSInteger)fallback {
    if (device == kAudioObjectUnknown) return fallback;
    AudioObjectPropertyAddress address = { kAudioDevicePropertyStreamConfiguration, scope, kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &address, 0, nullptr, &size) != noErr || size < sizeof(AudioBufferList)) return fallback;
    std::vector<uint8_t> storage(size);
    AudioBufferList *bufferList = reinterpret_cast<AudioBufferList *>(storage.data());
    if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, bufferList) != noErr) return fallback;
    UInt32 channels = 0;
    for (UInt32 i = 0; i < bufferList->mNumberBuffers; ++i) channels += bufferList->mBuffers[i].mNumberChannels;
    return channels > 0 ? (NSInteger)channels : fallback;
}

- (NSTimeInterval)latencyForDevice:(AudioDeviceID)device scope:(AudioObjectPropertyScope)scope {
    if (device == kAudioObjectUnknown) return 0.0;
    UInt32 latencyFrames = 0;
    UInt32 size = sizeof(latencyFrames);
    AudioObjectPropertyAddress address = { kAudioDevicePropertyLatency, scope, kAudioObjectPropertyElementMain };
    if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, &latencyFrames) != noErr) return 0.0;
    double rate = scope == kAudioDevicePropertyScopeInput ? self.deviceInputSampleRate : self.deviceOutputSampleRate;
    return rate > 0.0 ? (NSTimeInterval)((double)latencyFrames / rate) : 0.0;
}

- (AudioStreamBasicDescription)streamFormatWithSampleRate:(double)sampleRate channels:(UInt32)channels {
    AudioStreamBasicDescription format = {};
    format.mSampleRate = sampleRate > 0.0 ? sampleRate : 48000.0;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    format.mBitsPerChannel = 16;
    format.mChannelsPerFrame = std::max<UInt32>(1, channels);
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = format.mChannelsPerFrame * sizeof(int16_t);
    format.mBytesPerPacket = format.mBytesPerFrame;
    return format;
}

- (void)clearAudioBufferList:(AudioBufferList *)bufferList {
    if (!bufferList) return;
    for (UInt32 i = 0; i < bufferList->mNumberBuffers; ++i) {
        if (bufferList->mBuffers[i].mData && bufferList->mBuffers[i].mDataByteSize > 0) {
            std::memset(bufferList->mBuffers[i].mData, 0, bufferList->mBuffers[i].mDataByteSize);
        }
    }
}

@end

@interface OPNLibWebRTCSessionImpl : NSObject <RTCPeerConnectionDelegate, RTCDataChannelDelegate>
- (instancetype)initWithOwner:(OPN::LibWebRTCStreamSession *)owner;
@property(nonatomic, assign) OPN::LibWebRTCStreamSession *owner;
@property(nonatomic, strong) RTCPeerConnectionFactory *factory;
@property(nonatomic, strong) OPNCoreAudioRTCDevice *audioDevice;
@property(nonatomic, strong) RTCPeerConnection *peerConnection;
@property(nonatomic, strong) RTCDataChannel *reliableInputChannel;
@property(nonatomic, strong) RTCDataChannel *partialInputChannel;
@property(nonatomic, strong) RTCVideoTrack *remoteVideoTrack;
@property(nonatomic, strong) NSView *remoteVideoView;
@property(nonatomic, strong) id<RTCVideoRenderer> remoteVideoRenderer;
@property(nonatomic, strong) RTCAudioTrack *remoteAudioTrack;
@property(nonatomic, strong) RTCAudioTrack *localMicrophoneTrack;
@property(nonatomic, strong) RTCRtpSender *localMicrophoneSender;
@end

@protocol OPNRTCMetalRenderer <NSObject>
- (BOOL)addRenderingDestination:(__kindof MTKView *)view;
- (void)drawFrame:(RTCVideoFrame *)frame;
@end

@interface OPNMetalVideoView : NSView <RTCVideoRenderer, MTKViewDelegate>
- (instancetype)initWithFrame:(NSRect)frame targetFps:(int)targetFps owner:(OPN::LibWebRTCStreamSession *)owner;
@end

@interface OPNMetalVideoView ()
@property(nonatomic, strong) MTKView *metalView;
@property(nonatomic, strong) RTCVideoFrame *videoFrame;
@property(nonatomic, strong) id<OPNRTCMetalRenderer> rendererNV12;
@property(nonatomic, strong) id<OPNRTCMetalRenderer> rendererRGB;
@property(nonatomic, strong) id<OPNRTCMetalRenderer> rendererI420;
@property(nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property(nonatomic, strong) OPNVideoEnhancementRenderer *enhancementRenderer;
@property(nonatomic, assign) CGSize sourceFrameSize;
@property(nonatomic, assign) int targetFps;
@property(nonatomic, assign) uint64_t frameSerial;
@property(nonatomic, assign) uint64_t lastDrawnFrameSerial;
@property(nonatomic, assign) uint64_t enhancementDroppedFrameCount;
@property(nonatomic, assign) double lastEnhancementFrameTimeMs;
@property(nonatomic, assign) CFTimeInterval lastDiagnosticsUpdateTime;
@property(nonatomic, assign) BOOL drawScheduled;
@property(nonatomic, assign) OPN::LibWebRTCStreamSession *owner;
- (void)updateDrawableSizeForCurrentBackingScale;
- (CGSize)enhancementDrawableSizeForBoundsSize:(CGSize)boundsSize scale:(CGFloat)scale;
- (void)scheduleDraw;
- (id<OPNRTCMetalRenderer>)newRendererNamed:(NSString *)className fallback:(NSString **)fallback;
- (id<OPNRTCMetalRenderer>)i420RendererWithFallback:(NSString **)fallback;
- (id<OPNRTCMetalRenderer>)rendererForFrame:(RTCVideoFrame *)frame
                                 pixelFormat:(NSString **)pixelFormat
                                  renderMode:(NSString **)renderMode
                                 frameSource:(NSString **)frameSource
                                  renderPath:(NSString **)renderPath
                                     fallback:(NSString **)fallback;
@end

static NSString *OPNVideoResolutionString(CGSize size) {
    int width = (int)std::llround(std::max<CGFloat>(0.0, size.width));
    int height = (int)std::llround(std::max<CGFloat>(0.0, size.height));
    return width > 0 && height > 0 ? [NSString stringWithFormat:@"%dx%d", width, height] : @"unknown";
}

@implementation OPNMetalVideoView

- (instancetype)initWithFrame:(NSRect)frame targetFps:(int)targetFps owner:(OPN::LibWebRTCStreamSession *)owner {
    self = [super initWithFrame:frame];
    if (self) {
        _owner = owner;
        _targetFps = MAX(30, MIN(targetFps, 240));
        _sourceFrameSize = CGSizeZero;
        _frameSerial = 0;
        _lastDrawnFrameSerial = 0;
        _enhancementDroppedFrameCount = 0;
        _lastEnhancementFrameTimeMs = -1.0;
        _lastDiagnosticsUpdateTime = 0.0;
        _drawScheduled = NO;
        self.wantsLayer = YES;
        self.layer.backgroundColor = NSColor.blackColor.CGColor;

        _metalView = [[MTKView alloc] initWithFrame:self.bounds device:MTLCreateSystemDefaultDevice()];
        _metalView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        _metalView.framebufferOnly = NO;
        _metalView.autoResizeDrawable = NO;
        _metalView.paused = YES;
        _metalView.enableSetNeedsDisplay = NO;
        _metalView.preferredFramesPerSecond = _targetFps;
        _metalView.delegate = self;
        _metalView.layerContentsPlacement = NSViewLayerContentsPlacementScaleProportionallyToFit;
        if ([_metalView.layer isKindOfClass:CAMetalLayer.class]) {
            CAMetalLayer *metalLayer = (CAMetalLayer *)_metalView.layer;
            metalLayer.presentsWithTransaction = NO;
            metalLayer.allowsNextDrawableTimeout = NO;
            if (@available(macOS 10.13, *)) {
                metalLayer.maximumDrawableCount = 3;
            }
        }
        [self addSubview:_metalView];
        if (_metalView.device) {
            _commandQueue = [_metalView.device newCommandQueue];
            _enhancementRenderer = [[OPNVideoEnhancementRenderer alloc] initWithDevice:_metalView.device commandQueue:_commandQueue];
        }
    }
    return self;
}

- (void)layout {
    [super layout];
    self.metalView.frame = self.bounds;
    [self updateDrawableSizeForCurrentBackingScale];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self updateDrawableSizeForCurrentBackingScale];
}

- (void)setSize:(CGSize)size {
    if (size.width <= 0.0 || size.height <= 0.0) return;
    @synchronized (self) {
        self.sourceFrameSize = size;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateDrawableSizeForCurrentBackingScale];
    });
}

- (void)updateDrawableSizeForCurrentBackingScale {
    if (!self.metalView) return;
    CGFloat scale = self.window.backingScaleFactor;
    if (scale <= 0.0) scale = self.metalView.window.backingScaleFactor;
    if (scale <= 0.0) scale = NSScreen.mainScreen.backingScaleFactor;
    if (scale <= 0.0) scale = 1.0;

    CGSize boundsSize = self.metalView.bounds.size;
    if (boundsSize.width <= 0.0 || boundsSize.height <= 0.0) return;

    CGSize drawableSize = CGSizeMake(std::max<CGFloat>(1.0, floor(boundsSize.width * scale)),
                                     std::max<CGFloat>(1.0, floor(boundsSize.height * scale)));
    int enhancementMode = 0;
    int enhancementSharpness = 0;
    int enhancementDenoise = 0;
    if (self.owner) self.owner->LocalVideoEnhancement(enhancementMode, enhancementSharpness, enhancementDenoise);
    if (enhancementMode > 0) {
        drawableSize = [self enhancementDrawableSizeForBoundsSize:boundsSize scale:scale];
    }
    CGSize currentSize = self.metalView.drawableSize;
    if ((int)std::llround(currentSize.width) != (int)std::llround(drawableSize.width) ||
        (int)std::llround(currentSize.height) != (int)std::llround(drawableSize.height)) {
        self.metalView.drawableSize = drawableSize;
    }
}

- (CGSize)enhancementDrawableSizeForBoundsSize:(CGSize)boundsSize scale:(CGFloat)scale {
    CGSize backingSize = CGSizeMake(std::max<CGFloat>(1.0, floor(boundsSize.width * scale)),
                                    std::max<CGFloat>(1.0, floor(boundsSize.height * scale)));
    CGFloat aspect = boundsSize.height > 0.0 ? boundsSize.width / boundsSize.height : 16.0 / 9.0;
    if (aspect <= 0.1 || !std::isfinite((double)aspect)) aspect = 16.0 / 9.0;
    CGFloat targetWidth = aspect >= 1.0 ? 3840.0 : 2160.0 * aspect;
    CGFloat targetHeight = targetWidth / aspect;
    return CGSizeMake(std::max<CGFloat>(backingSize.width, floor(targetWidth)),
                      std::max<CGFloat>(backingSize.height, floor(targetHeight)));
}

- (void)renderFrame:(RTCVideoFrame *)frame {
    if (frame && self.owner) {
        self.owner->HandleVideoFrame((__bridge void *)frame);
    }
    if (!frame) return;
    BOOL shouldScheduleDraw = NO;
    @synchronized (self) {
        self.videoFrame = frame;
        self.frameSerial++;
        shouldScheduleDraw = !self.drawScheduled;
        self.drawScheduled = YES;
    }
    if (shouldScheduleDraw) {
        [self scheduleDraw];
    }
}

- (void)scheduleDraw {
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            @synchronized (self) {
                self.drawScheduled = NO;
            }
            if (self.metalView) {
                [self.metalView draw];
            }
        }
    });
}

- (void)drawInMTKView:(MTKView *)view {
    if (view != self.metalView) return;
    [self updateDrawableSizeForCurrentBackingScale];

    RTCVideoFrame *frame = nil;
    uint64_t drawSerial = 0;
    CGSize sourceSize = CGSizeZero;
    @synchronized (self) {
        frame = self.videoFrame;
        drawSerial = self.frameSerial;
        sourceSize = self.sourceFrameSize;
    }
    if (!frame || frame.width <= 0 || frame.height <= 0 || drawSerial == 0 || drawSerial == self.lastDrawnFrameSerial) return;
    if (sourceSize.width <= 0.0 || sourceSize.height <= 0.0) sourceSize = CGSizeMake(frame.width, frame.height);

    NSString *pixelFormat = @"unknown";
    NSString *renderMode = @"I420";
    NSString *frameSource = @"unknown";
    NSString *renderPath = @"RTCMTLI420Renderer";
    NSString *fallback = @"";
    NSString *enhancementConfiguredTier = @"Off";
    NSString *enhancementActiveTier = @"Native";
    NSString *enhancementFallbackReason = @"";
    NSString *enhancementSourceResolution = OPNVideoResolutionString(sourceSize);
    NSString *enhancementDrawableResolution = OPNVideoResolutionString(self.metalView.drawableSize);
    double enhancementFrameTimeMs = -1.0;
    int enhancementMode = 0;
    int enhancementSharpness = 0;
    int enhancementDenoise = 0;
    if (self.owner) self.owner->LocalVideoEnhancement(enhancementMode, enhancementSharpness, enhancementDenoise);
    [self updateDrawableSizeForCurrentBackingScale];
    if (enhancementMode > 0) {
        OPNVideoEnhancementSettings *settings = [[OPNVideoEnhancementSettings alloc] init];
        if (enhancementMode == 3) {
            settings.configuredTier = OPNVideoEnhancementTierMetalFX;
        } else if (enhancementMode == 2) {
            settings.configuredTier = OPNVideoEnhancementTierSpatial;
        } else {
            settings.configuredTier = [self.enhancementRenderer isMetalFXAvailable] ? OPNVideoEnhancementTierMetalFX : OPNVideoEnhancementTierSpatial;
        }
        settings.sharpness = enhancementSharpness;
        settings.denoise = enhancementDenoise;
        settings.sourceSize = sourceSize;
        settings.drawableSize = self.metalView.drawableSize;
        settings.targetFrameTimeMs = 1000.0 / (double)std::max(1, self.targetFps);
        settings.captureEnhancedPixelBuffer = self.owner ? self.owner->WantsEnhancedVideoFrames() : NO;
        OPNVideoEnhancementResult *result = [[OPNVideoEnhancementResult alloc] init];
        if ([self.enhancementRenderer renderFrame:frame toView:self.metalView settings:settings result:result]) {
            pixelFormat = result.pixelFormat ?: @"unknown";
            renderMode = result.renderMode ?: @"Upscaler";
            frameSource = result.frameSource ?: @"processed frame";
            renderPath = result.renderPath ?: @"OPNVideoEnhancementRenderer";
            fallback = result.fallbackReason ?: @"";
            enhancementConfiguredTier = result.configuredTier ?: @"Upscaler";
            enhancementActiveTier = result.activeTier ?: @"Enhanced";
            enhancementFallbackReason = result.tierFallbackReason ?: @"";
            enhancementSourceResolution = result.sourceResolution ?: enhancementSourceResolution;
            enhancementDrawableResolution = result.drawableResolution ?: enhancementDrawableResolution;
            enhancementFrameTimeMs = result.frameTimeMs;
            self.enhancementDroppedFrameCount = result.droppedFrames;
            self.lastDrawnFrameSerial = drawSerial;
            if (result.enhancedPixelBuffer && self.owner) {
                self.owner->HandleEnhancedVideoFrame(result.enhancedPixelBuffer);
                CVPixelBufferRelease(result.enhancedPixelBuffer);
                result.enhancedPixelBuffer = nil;
            }
        } else {
            fallback = result.fallbackReason.length > 0 ? result.fallbackReason : @"processed renderer unavailable; using WebRTC renderer";
            enhancementConfiguredTier = result.configuredTier ?: @"Upscaler";
            enhancementActiveTier = @"Native fallback";
            enhancementFallbackReason = result.tierFallbackReason.length > 0 ? result.tierFallbackReason : fallback;
            enhancementSourceResolution = result.sourceResolution ?: enhancementSourceResolution;
            enhancementDrawableResolution = result.drawableResolution ?: enhancementDrawableResolution;
            self.enhancementDroppedFrameCount = result.droppedFrames;
        }
        if (self.lastDrawnFrameSerial != drawSerial) {
            enhancementActiveTier = @"Native fallback";
            enhancementFallbackReason = fallback.length > 0 ? fallback : @"processed renderer failed";
        }
    }
    if (self.lastDrawnFrameSerial == drawSerial) {
        self.lastEnhancementFrameTimeMs = enhancementFrameTimeMs;
        CFTimeInterval now = CACurrentMediaTime();
        if (self.owner && (self.lastDiagnosticsUpdateTime <= 0.0 || now - self.lastDiagnosticsUpdateTime >= 1.0 || fallback.length > 0)) {
            self.lastDiagnosticsUpdateTime = now;
            self.owner->SetVideoRenderDiagnostics(OPN::OPNNSStringToString(pixelFormat),
                                                  OPN::OPNNSStringToString(renderMode),
                                                  OPN::OPNNSStringToString(frameSource),
                                                  OPN::OPNNSStringToString(renderPath),
                                                  OPN::OPNNSStringToString(fallback),
                                                  OPN::OPNNSStringToString(enhancementConfiguredTier),
                                                  OPN::OPNNSStringToString(enhancementActiveTier),
                                                  OPN::OPNNSStringToString(enhancementFallbackReason),
                                                  OPN::OPNNSStringToString(enhancementSourceResolution),
                                                  OPN::OPNNSStringToString(enhancementDrawableResolution),
                                                  enhancementFrameTimeMs,
                                                  self.enhancementDroppedFrameCount);
        }
        return;
    }
    id<OPNRTCMetalRenderer> renderer = [self rendererForFrame:frame
                                                   pixelFormat:&pixelFormat
                                                   renderMode:&renderMode
                                                  frameSource:&frameSource
                                                   renderPath:&renderPath
                                                     fallback:&fallback];
    if (!renderer) {
        fallback = @"renderer unavailable";
    } else {
        [renderer drawFrame:frame];
        self.lastDrawnFrameSerial = drawSerial;
    }
    self.lastEnhancementFrameTimeMs = enhancementFrameTimeMs;
    CFTimeInterval now = CACurrentMediaTime();
    if (self.owner && (self.lastDiagnosticsUpdateTime <= 0.0 || now - self.lastDiagnosticsUpdateTime >= 1.0 || fallback.length > 0)) {
        self.lastDiagnosticsUpdateTime = now;
        self.owner->SetVideoRenderDiagnostics(OPN::OPNNSStringToString(pixelFormat),
                                              OPN::OPNNSStringToString(renderMode),
                                              OPN::OPNNSStringToString(frameSource),
                                              OPN::OPNNSStringToString(renderPath),
                                              OPN::OPNNSStringToString(fallback),
                                              OPN::OPNNSStringToString(enhancementConfiguredTier),
                                              OPN::OPNNSStringToString(enhancementActiveTier),
                                              OPN::OPNNSStringToString(enhancementFallbackReason),
                                              OPN::OPNNSStringToString(enhancementSourceResolution),
                                              OPN::OPNNSStringToString(enhancementDrawableResolution),
                                              enhancementFrameTimeMs,
                                              self.enhancementDroppedFrameCount);
    }
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    (void)view;
    (void)size;
}

- (id<OPNRTCMetalRenderer>)newRendererNamed:(NSString *)className fallback:(NSString **)fallback {
    Class rendererClass = NSClassFromString(className);
    if (!rendererClass) {
        if (fallback) *fallback = [NSString stringWithFormat:@"%@ unavailable", className];
        return nil;
    }
    id<OPNRTCMetalRenderer> renderer = (id<OPNRTCMetalRenderer>)[[rendererClass alloc] init];
    if (![renderer addRenderingDestination:self.metalView]) {
        if (fallback) *fallback = [NSString stringWithFormat:@"%@ rejected MTKView", className];
        return nil;
    }
    self.metalView.paused = YES;
    self.metalView.enableSetNeedsDisplay = NO;
    self.metalView.preferredFramesPerSecond = self.targetFps;
    return renderer;
}

- (id<OPNRTCMetalRenderer>)i420RendererWithFallback:(NSString **)fallback {
    if (!self.rendererI420) {
        self.rendererI420 = [self newRendererNamed:@"RTCMTLI420Renderer" fallback:fallback];
    }
    return self.rendererI420;
}

- (id<OPNRTCMetalRenderer>)rendererForFrame:(RTCVideoFrame *)frame
                                pixelFormat:(NSString **)pixelFormat
                                 renderMode:(NSString **)renderMode
                                frameSource:(NSString **)frameSource
                                 renderPath:(NSString **)renderPath
                                   fallback:(NSString **)fallback {
    if ([frame.buffer isKindOfClass:RTCCVPixelBuffer.class]) {
        if (frameSource) *frameSource = @"CVPixelBuffer";
        RTCCVPixelBuffer *buffer = (RTCCVPixelBuffer *)frame.buffer;
        OSType format = CVPixelBufferGetPixelFormatType(buffer.pixelBuffer);
        BOOL isNV12 = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
        BOOL isRGB = format == kCVPixelFormatType_32BGRA || format == kCVPixelFormatType_32ARGB;
        if (pixelFormat) {
            if (format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) *pixelFormat = @"420v/NV12";
            else if (format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) *pixelFormat = @"420f/NV12";
            else if (format == kCVPixelFormatType_32BGRA) *pixelFormat = @"BGRA";
            else if (format == kCVPixelFormatType_32ARGB) *pixelFormat = @"ARGB";
            else *pixelFormat = [NSString stringWithFormat:@"0x%08x", (unsigned int)format];
        }
        if (isNV12) {
            NSString *localFallback = @"";
            if (!self.rendererNV12) self.rendererNV12 = [self newRendererNamed:@"RTCMTLNV12Renderer" fallback:&localFallback];
            if (self.rendererNV12) {
                if (renderMode) *renderMode = @"NV12";
                if (renderPath) *renderPath = @"RTCMTLNV12Renderer";
                return self.rendererNV12;
            }
            if (fallback) *fallback = localFallback.length > 0 ? localFallback : @"NV12 unavailable; using I420";
        } else if (isRGB) {
            NSString *localFallback = @"";
            if (!self.rendererRGB) self.rendererRGB = [self newRendererNamed:@"RTCMTLRGBRenderer" fallback:&localFallback];
            if (self.rendererRGB) {
                if (renderMode) *renderMode = @"RGB";
                if (renderPath) *renderPath = @"RTCMTLRGBRenderer";
                return self.rendererRGB;
            }
            if (fallback) *fallback = localFallback.length > 0 ? localFallback : @"RGB unavailable; using I420";
        } else if (fallback) {
            *fallback = @"unsupported CVPixelBuffer; using I420";
        }
    } else {
        if (frameSource) *frameSource = NSStringFromClass([frame.buffer class]) ?: @"unknown";
        if (pixelFormat) *pixelFormat = @"I420";
    }
    if (renderMode) *renderMode = @"I420";
    if (renderPath) *renderPath = @"RTCMTLI420Renderer";
    return [self i420RendererWithFallback:fallback];
}

@end

namespace OPN {
static OPNLibWebRTCSessionImpl *OPNImplFromOpaque(void *opaque) {
    return (__bridge OPNLibWebRTCSessionImpl *)opaque;
}

static bool OPNLibWebRTCSupportsCodec(RTCPeerConnectionFactory *factory, const std::string &normalizedCodec) {
    if (!factory || !OPNIsSupportedCodecPreference(normalizedCodec)) return false;
    RTCRtpCapabilities *capabilities = [factory rtpReceiverCapabilitiesForKind:kRTCMediaStreamTrackKindVideo];
    if (!capabilities) return false;

    NSMutableArray<NSString *> *codecNames = [NSMutableArray array];
    for (RTCRtpCodecCapability *codec in capabilities.codecs) {
        NSString *name = codec.name ?: @"";
        NSString *mimeType = codec.mimeType ?: @"";
        NSString *combined = [[NSString stringWithFormat:@"%@ %@", name, mimeType] uppercaseString];
        if (combined.length > 1) [codecNames addObject:combined];
        if (OPNCodecCapabilityMatches(codec, normalizedCodec)) return true;
    }

    OPN::LogInfo(@"[LibWebRTC] Receiver codec capabilities do not include %s; available=%@", normalizedCodec.c_str(), [codecNames componentsJoinedByString:@", "]);
    return false;
}

static bool OPNLibWebRTCH265ReceiverSupport(RTCPeerConnectionFactory *factory,
                                            int &maxMainLevelId,
                                            int &maxMain10LevelId,
                                            bool &supportsHighTier) {
    maxMainLevelId = 0;
    maxMain10LevelId = 0;
    supportsHighTier = false;
    if (!factory) return false;

    RTCRtpCapabilities *capabilities = [factory rtpReceiverCapabilitiesForKind:kRTCMediaStreamTrackKindVideo];
    if (!capabilities) return false;

    bool hasH265 = false;
    for (RTCRtpCodecCapability *codec in capabilities.codecs) {
        if (!OPNCodecCapabilityMatches(codec, "H265")) continue;
        hasH265 = true;
        NSDictionary<NSString *, NSString *> *parameters = codec.parameters ?: @{};
        NSString *tierFlag = parameters[@"tier-flag"];
        if (tierFlag && tierFlag.integerValue == 1) supportsHighTier = true;

        NSInteger profileId = parameters[@"profile-id"].integerValue;
        NSInteger levelId = parameters[@"level-id"].integerValue;
        if (levelId <= 0) continue;
        if (profileId == 2) {
            maxMain10LevelId = std::max(maxMain10LevelId, (int)levelId);
        } else {
            maxMainLevelId = std::max(maxMainLevelId, (int)levelId);
        }
    }
    return hasH265;
}

static bool OPNApplyVideoCodecPreference(RTCPeerConnectionFactory *factory,
                                         RTCPeerConnection *peerConnection,
                                         const std::string &normalizedCodec) {
    if (!factory || !peerConnection || !OPNIsSupportedCodecPreference(normalizedCodec)) return false;

    RTCRtpCapabilities *capabilities = [factory rtpReceiverCapabilitiesForKind:kRTCMediaStreamTrackKindVideo];
    if (!capabilities) return false;

    NSMutableArray<RTCRtpCodecCapability *> *preferredCodecs = [NSMutableArray array];
    for (RTCRtpCodecCapability *codec in capabilities.codecs) {
        if (OPNCodecCapabilityMatches(codec, normalizedCodec)) {
            [preferredCodecs addObject:codec];
        }
    }
    if (preferredCodecs.count == 0) return false;
    for (RTCRtpCodecCapability *codec in capabilities.codecs) {
        if (OPNCodecCapabilityIsTransportSupport(codec)) {
            [preferredCodecs addObject:codec];
        }
    }

    bool applied = false;
    for (RTCRtpTransceiver *transceiver in peerConnection.transceivers) {
        if (transceiver.mediaType != RTCRtpMediaTypeVideo || transceiver.isStopped) continue;
        NSError *codecError = nil;
        if ([transceiver setCodecPreferences:preferredCodecs error:&codecError]) {
            applied = true;
            OPN::LogInfo(@"[LibWebRTC] Applied %s codec preference to video transceiver mid=%@ (%lu codecs)",
                  normalizedCodec.c_str(),
                  transceiver.mid ?: @"(none)",
                  (unsigned long)preferredCodecs.count);
        } else {
            OPN::LogInfo(@"[LibWebRTC] Failed to apply %s codec preference to video transceiver mid=%@: %@",
                  normalizedCodec.c_str(),
                  transceiver.mid ?: @"(none)",
                  codecError.localizedDescription ?: @"unknown error");
        }
    }
    return applied;
}

static NSNumber *OPNRTCStatsNumberForKey(NSDictionary<NSString *, NSObject *> *values, NSString *key) {
    NSObject *value = values[key];
    return [value isKindOfClass:NSNumber.class] ? (NSNumber *)value : nil;
}

static NSString *OPNRTCStatsStringForKey(NSDictionary<NSString *, NSObject *> *values, NSString *key) {
    NSObject *value = values[key];
    return [value isKindOfClass:NSString.class] ? (NSString *)value : nil;
}

static bool OPNRTCStatsIsAudio(RTCStatistics *stat) {
    NSString *mediaType = OPNRTCStatsStringForKey(stat.values, @"mediaType");
    NSString *kind = OPNRTCStatsStringForKey(stat.values, @"kind");
    NSString *trackKind = OPNRTCStatsStringForKey(stat.values, @"trackKind");
    if ([mediaType isEqualToString:@"audio"] || [kind isEqualToString:@"audio"] || [trackKind isEqualToString:@"audio"]) return true;
    NSString *idString = [stat.id lowercaseString];
    return [idString containsString:@"audio"] || [idString containsString:@"mic"];
}

static double OPNMicrophoneLevelFromStatsReport(RTCStatisticsReport *report) {
    double bestLevel = -1.0;
    for (RTCStatistics *stat in report.statistics.allValues) {
        if (!OPNRTCStatsIsAudio(stat)) continue;
        NSNumber *audioLevel = OPNRTCStatsNumberForKey(stat.values, @"audioLevel");
        if (!audioLevel) audioLevel = OPNRTCStatsNumberForKey(stat.values, @"totalAudioEnergy");
        if (!audioLevel) continue;
        double level = audioLevel.doubleValue;
        if (level > 1.0) level = sqrt(level);
        bestLevel = std::max(bestLevel, std::max(0.0, std::min(level, 1.0)));
    }
    return bestLevel;
}

static const char *OPNRTCRtpTransceiverDirectionName(RTCRtpTransceiverDirection direction) {
    switch (direction) {
        case RTCRtpTransceiverDirectionSendRecv: return "sendrecv";
        case RTCRtpTransceiverDirectionSendOnly: return "sendonly";
        case RTCRtpTransceiverDirectionRecvOnly: return "recvonly";
        case RTCRtpTransceiverDirectionInactive: return "inactive";
        case RTCRtpTransceiverDirectionStopped: return "stopped";
    }
    return "unknown";
}

static RTCRtpTransceiver *OPNFindMicrophoneTransceiver(RTCPeerConnection *peerConnection) {
    RTCRtpTransceiver *firstAvailableAudio = nil;
    RTCRtpTransceiver *firstSendableAudio = nil;
    for (RTCRtpTransceiver *transceiver in peerConnection.transceivers) {
        if (transceiver.mediaType != RTCRtpMediaTypeAudio || transceiver.isStopped) continue;
        if ([transceiver.mid isEqualToString:@"3"]) return transceiver;
        if (!firstAvailableAudio && !transceiver.sender.track) firstAvailableAudio = transceiver;
        if (!firstSendableAudio &&
            (transceiver.direction == RTCRtpTransceiverDirectionSendRecv ||
             transceiver.direction == RTCRtpTransceiverDirectionRecvOnly ||
             transceiver.direction == RTCRtpTransceiverDirectionInactive)) {
            firstSendableAudio = transceiver;
        }
    }
    return firstAvailableAudio ?: firstSendableAudio;
}

static bool OPNAttachMicrophoneTrack(OPNLibWebRTCSessionImpl *impl, RTCAudioTrack *audioTrack) {
    if (!impl.peerConnection || !audioTrack) return false;

    RTCRtpTransceiver *transceiver = OPNFindMicrophoneTransceiver(impl.peerConnection);
    if (transceiver) {
        NSError *directionError = nil;
        RTCRtpTransceiverDirection targetDirection = transceiver.direction;
        if (transceiver.direction == RTCRtpTransceiverDirectionRecvOnly) {
            targetDirection = RTCRtpTransceiverDirectionSendRecv;
        } else if (transceiver.direction == RTCRtpTransceiverDirectionInactive) {
            targetDirection = RTCRtpTransceiverDirectionSendOnly;
        }
        if (targetDirection != transceiver.direction) {
            [transceiver setDirection:targetDirection error:&directionError];
            if (directionError) {
                OPN::LogError(@"[LibWebRTC] failed to set microphone transceiver direction: %@", directionError.localizedDescription);
            }
        }
        transceiver.sender.track = audioTrack;
        transceiver.sender.streamIds = @[@"mic"];
        impl.localMicrophoneSender = transceiver.sender;
        OPN::LogInfo(@"[LibWebRTC] local microphone track attached to transceiver mid=%@ direction=%s target=%s enabled=%d volume=%.2f",
              transceiver.mid ?: @"(none)",
              OPNRTCRtpTransceiverDirectionName(transceiver.direction),
              OPNRTCRtpTransceiverDirectionName(targetDirection),
              audioTrack.isEnabled,
              audioTrack.source.volume);
        return true;
    }

    RTCRtpSender *sender = [impl.peerConnection addTrack:audioTrack streamIds:@[@"mic"]];
    if (!sender) return false;
    impl.localMicrophoneSender = sender;
    OPN::LogInfo(@"[LibWebRTC] local microphone track added without negotiated transceiver; renegotiation may be required");
    return true;
}
#endif

bool LibWebRTCStreamSession::IsAvailable() {
#if defined(OPN_HAVE_LIBWEBRTC)
    return NSClassFromString(@"RTCPeerConnectionFactory") != nil;
#else
    return false;
#endif
}

std::string LibWebRTCStreamSession::AvailabilityDescription() {
#if defined(OPN_HAVE_LIBWEBRTC)
    return IsAvailable() ? "WebRTC.framework loaded" : "WebRTC.framework linked but RTCPeerConnectionFactory missing";
#else
    return "build without OPN_HAVE_LIBWEBRTC";
#endif
}

LibWebRTCStreamSession::LibWebRTCStreamSession() {
    dispatch_queue_t statsQueue = dispatch_queue_create("io.opencg.opennow.webrtc.stats", DISPATCH_QUEUE_SERIAL);
    m_statsQueue = (__bridge_retained void *)statsQueue;
    m_callbackLiveness = std::make_shared<std::atomic_bool>(true);
}

LibWebRTCStreamSession::~LibWebRTCStreamSession() {
    Stop();
    if (m_statsQueue) {
        dispatch_queue_t statsQueue = (__bridge_transfer dispatch_queue_t)m_statsQueue;
        m_statsQueue = nullptr;
        (void)statsQueue;
    }
}

void LibWebRTCStreamSession::Start(const SessionInfo &session,
                                   const std::string &offerSdp,
                                   const StreamSettings &settings,
                                   StreamStateCallback onState) {
    Stop();
    m_callbackLiveness = std::make_shared<std::atomic_bool>(true);
    auto callbackLiveness = m_callbackLiveness;
    m_settings = settings;
    m_configuredMaxBitrateMbps = std::max(1, settings.maxBitrateMbps);
    m_adaptiveBitrateMbps = m_configuredMaxBitrateMbps;
    m_minAdaptiveBitrateMbps = std::min(m_configuredMaxBitrateMbps, std::max(8, m_configuredMaxBitrateMbps * 35 / 100));
    m_adaptiveCongestionScore = 0;
    m_adaptiveRecoveryScore = 0;
    m_lastAdaptiveBitrateChangeMs = 0;
    m_onState = std::move(onState);
    {
        std::lock_guard<std::mutex> lock(m_statsMutex);
        m_latestStats = StreamStats{};
        m_latestStats.gpuType = session.gpuType;
        m_latestStats.zone = session.zone;
        m_latestStats.resolution = settings.resolution;
        m_latestStats.codec = settings.codec;
        m_latestStats.fps = settings.fps;
        m_latestStats.videoDecoder = "libwebrtc";
        m_latestStats.videoSink = "OPNMetalVideoView";
        m_latestStats.videoPipelineMode = "libwebrtc Metal display";
        m_latestStats.videoPixelFormat = "pending";
        m_latestStats.videoRenderMode = "pending";
        m_latestStats.videoFrameSource = "pending";
        m_latestStats.videoRenderPath = "pending";
        m_latestStats.videoRendererFallback = "";
        m_latestStats.videoEnhancementConfiguredTier = "pending";
        m_latestStats.videoEnhancementActiveTier = "pending";
        m_latestStats.videoEnhancementFallbackReason = "";
        m_latestStats.videoEnhancementSourceResolution = "pending";
        m_latestStats.videoEnhancementDrawableResolution = "pending";
        m_latestStats.videoEnhancementFrameTimeMs = -1.0;
        m_latestStats.videoEnhancementDroppedFrames = 0;
        m_statsRequestInFlight = false;
        m_previousStatsTimestampMs = 0;
        m_lastStatsRequestMs = 0;
        m_previousBytesReceived = 0;
        m_previousPacketsReceived = 0;
        m_previousFramesDecoded = 0;
        m_previousPacketsLost = 0;
    }
    if (settings.microphoneMode != "disabled" && !m_microphoneEnabled) {
        m_microphoneEnabled = settings.microphoneMode == "voice-activity";
    }

#if defined(OPN_HAVE_LIBWEBRTC)
    if (!IsAvailable()) {
        const std::string error = AvailabilityDescription();
        if (m_onState) m_onState(false, error);
        return;
    }

    auto *impl = [[OPNLibWebRTCSessionImpl alloc] initWithOwner:this];
    impl.audioDevice = [[OPNCoreAudioRTCDevice alloc] init];
    impl.audioDevice.owner = this;
    RTCDefaultVideoEncoderFactory *encoderFactory = [[RTCDefaultVideoEncoderFactory alloc] init];
    RTCDefaultVideoDecoderFactory *decoderFactory = [[RTCDefaultVideoDecoderFactory alloc] init];
    impl.factory = [[RTCPeerConnectionFactory alloc] initWithEncoderFactory:encoderFactory
                                                              decoderFactory:decoderFactory
                                                                 audioDevice:impl.audioDevice];
    if (!impl.factory) {
        OPN::LogError(@"[LibWebRTC] CoreAudio RTC device factory failed; falling back to default WebRTC audio device");
        impl.audioDevice = nil;
        impl.factory = [[RTCPeerConnectionFactory alloc] init];
    } else {
        OPN::LogInfo(@"[LibWebRTC] CoreAudio RTC audio device enabled");
    }

    RTCConfiguration *configuration = [[RTCConfiguration alloc] init];
    NSMutableArray<RTCIceServer *> *iceServers = [NSMutableArray array];
    for (const IceServer &server : session.iceServers) {
        NSMutableArray<NSString *> *urls = [NSMutableArray array];
        for (const std::string &url : server.urls) {
            [urls addObject:OPNStringToNSString(url)];
        }
        if (urls.count == 0) continue;
        RTCIceServer *iceServer = [[RTCIceServer alloc] initWithURLStrings:urls
                                                                  username:server.username.empty() ? nil : OPNStringToNSString(server.username)
                                                                credential:server.credential.empty() ? nil : OPNStringToNSString(server.credential)];
        [iceServers addObject:iceServer];
    }
    configuration.iceServers = iceServers;
    configuration.sdpSemantics = RTCSdpSemanticsUnifiedPlan;
    configuration.bundlePolicy = RTCBundlePolicyMaxBundle;
    configuration.rtcpMuxPolicy = RTCRtcpMuxPolicyRequire;
    configuration.tcpCandidatePolicy = RTCTcpCandidatePolicyDisabled;
    configuration.continualGatheringPolicy = RTCContinualGatheringPolicyGatherOnce;
    configuration.iceConnectionReceivingTimeout = 30000;

    RTCMediaConstraints *constraints = [[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil optionalConstraints:nil];
    impl.peerConnection = [impl.factory peerConnectionWithConfiguration:configuration constraints:constraints delegate:impl];
    if (!impl.peerConnection) {
        const std::string error = "failed to create libwebrtc peer connection";
        if (m_onState) m_onState(false, error);
        return;
    }

    m_impl = (__bridge_retained void *)impl;
    StartAudioDeviceMonitoring();
    CreateInputChannel();

    std::string processedOfferSdp = offerSdp;
    if (offerSdp.find("0.0.0.0") != std::string::npos) {
        std::string mediaIp = OPNExtractPublicIp(!session.mediaConnectionInfo.ip.empty() ? session.mediaConnectionInfo.ip : session.serverIp);
        OPN::LogInfo(@"[LibWebRTC] Offer contains 0.0.0.0 placeholders; leaving SDP unchanged for native parser compatibility (mediaIp=%s)",
              mediaIp.empty() ? "unknown" : mediaIp.c_str());
    }
    std::string requestedCodec = OPNNormalizeCodec(settings.codec);
    bool requestedCodecSupported = OPNLibWebRTCSupportsCodec(impl.factory, requestedCodec);
    if (requestedCodec == "H265" && requestedCodecSupported && OPNEnvFlagEnabled("OPN_ENABLE_LIBWEBRTC_H265_OFFER_REWRITE", true)) {
        int maxMainLevelId = 0;
        int maxMain10LevelId = 0;
        bool supportsHighTier = false;
        if (OPNLibWebRTCH265ReceiverSupport(impl.factory, maxMainLevelId, maxMain10LevelId, supportsHighTier)) {
            processedOfferSdp = OPNRewriteH265OfferForReceiver(processedOfferSdp, maxMainLevelId, maxMain10LevelId, supportsHighTier);
        }
    } else if (requestedCodec == "H265" && requestedCodecSupported) {
        OPN::LogInfo(@"[LibWebRTC] OPN_ENABLE_LIBWEBRTC_H265_OFFER_REWRITE=0; retaining original H265 offer parameters");
    }
    if (OPNIsSupportedCodecPreference(requestedCodec) && requestedCodecSupported && OPNEnvFlagEnabled("OPN_ENABLE_LIBWEBRTC_CODEC_FILTER", false)) {
        processedOfferSdp = OPNPreferCodecInOffer(processedOfferSdp, requestedCodec);
    } else if (OPNIsSupportedCodecPreference(requestedCodec) && !requestedCodecSupported) {
        OPN::LogInfo(@"[LibWebRTC] Requested codec %s is not supported by this WebRTC.framework; retaining full offer so libwebrtc can negotiate a supported fallback", requestedCodec.c_str());
    } else if (OPNIsSupportedCodecPreference(requestedCodec)) {
        OPN::LogInfo(@"[LibWebRTC] OPN_ENABLE_LIBWEBRTC_CODEC_FILTER=0; retaining all video payloads for requested codec %s", requestedCodec.c_str());
    } else {
        OPN::LogInfo(@"[LibWebRTC] Unsupported requested codec preference '%s'; retaining all video payloads", settings.codec.c_str());
    }
    OPNLogVideoSdpSummary("offer-video", processedOfferSdp);

    __weak OPNLibWebRTCSessionImpl *weakImpl = impl;
    NSString *processedOfferString = OPNStringToNSString(processedOfferSdp);
    NSString *originalOfferString = OPNStringToNSString(offerSdp);
    const bool canRetryOriginalOffer = processedOfferSdp != offerSdp;
    void (^handleRemoteDescriptionSet)(void) = ^{
        if (!callbackLiveness->load()) return;
        OPNLibWebRTCSessionImpl *strongImpl = weakImpl;
        if (!strongImpl) return;

        std::string answerCodecPreference = OPNNormalizeCodec(this->m_settings.codec);
        if (OPNIsSupportedCodecPreference(answerCodecPreference)) {
            if (!OPNApplyVideoCodecPreference(strongImpl.factory, strongImpl.peerConnection, answerCodecPreference)) {
                OPN::LogInfo(@"[LibWebRTC] No video transceiver accepted %s codec preference before answer", answerCodecPreference.c_str());
            }
        }

        if (this->m_settings.microphoneMode != "disabled" && !strongImpl.localMicrophoneTrack) {
            RTCMediaConstraints *audioConstraints = [[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil optionalConstraints:nil];
            RTCAudioSource *audioSource = [strongImpl.factory audioSourceWithConstraints:audioConstraints];
            audioSource.volume = this->m_microphoneVolumeLevel;
            RTCAudioTrack *audioTrack = [strongImpl.factory audioTrackWithSource:audioSource trackId:@"opennow-microphone"];
            audioTrack.isEnabled = this->m_microphoneEnabled;
            if (OPNAttachMicrophoneTrack(strongImpl, audioTrack)) {
                strongImpl.localMicrophoneTrack = audioTrack;
                this->StartMicrophoneLevelPolling();
            } else {
                OPN::LogError(@"[LibWebRTC] failed to attach local microphone track");
            }
        }

        RTCMediaConstraints *answerConstraints = [[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil optionalConstraints:nil];
        [strongImpl.peerConnection answerForConstraints:answerConstraints completionHandler:^(RTCSessionDescription *answer, NSError *answerError) {
            if (!callbackLiveness->load()) return;
            OPNLibWebRTCSessionImpl *answerImpl = weakImpl;
            if (!answerImpl) return;
            if (answerError || !answer) {
                const std::string message = "createAnswer failed: " + OPNNSStringToString(answerError.localizedDescription);
                this->HandleConnectionState(false, message);
                return;
            }

            const std::string rawAnswerSdp = OPNNSStringToString(answer.sdp);
            OPNLogVideoSdpSummary("answer-raw-video", rawAnswerSdp);
            const bool enableAnswerMunging = OPNEnvFlagEnabled("OPN_ENABLE_LIBWEBRTC_ANSWER_MUNGE", false);
            const std::string localAnswerSdp = enableAnswerMunging
                ? OPNMungeAnswerSdp(rawAnswerSdp, std::max(1000, this->m_settings.maxBitrateMbps * 1000))
                : rawAnswerSdp;
            if (!enableAnswerMunging) {
                OPN::LogInfo(@"[LibWebRTC] OPN_ENABLE_LIBWEBRTC_ANSWER_MUNGE=0; using raw local answer SDP");
            }
            OPNLogVideoSdpSummary("answer-video", localAnswerSdp);
            if (!OPNVideoSdpHasMediaCodec(localAnswerSdp)) {
                const std::string message = "createAnswer produced no negotiated video media codec";
                this->HandleConnectionState(false, message);
                return;
            }
            RTCSessionDescription *localAnswer = [[RTCSessionDescription alloc] initWithType:RTCSdpTypeAnswer sdp:OPNStringToNSString(localAnswerSdp)];

            [answerImpl.peerConnection setLocalDescription:localAnswer completionHandler:^(NSError *localError) {
                if (!callbackLiveness->load()) return;
                if (localError) {
                    const std::string message = "setLocalDescription failed: " + OPNNSStringToString(localError.localizedDescription);
                    this->HandleConnectionState(false, message);
                    return;
                }

                const std::string localSdp = localAnswerSdp;
                SendAnswerRequest request;
                request.sdp = localSdp;
                request.nvstSdp = OPNBuildNvstSdp(this->m_settings, OPNExtractIceCredentials(localSdp));
                {
                    std::lock_guard<std::mutex> lock(this->m_statsMutex);
                    this->m_latestStats.videoPipelineMode = "libwebrtc answer sent";
                }
                if (this->m_onAnswer) this->m_onAnswer(request);
            }];
        }];
    };

    RTCSessionDescription *offer = [[RTCSessionDescription alloc] initWithType:RTCSdpTypeOffer sdp:processedOfferString];
    [impl.peerConnection setRemoteDescription:offer completionHandler:^(NSError *error) {
        if (!callbackLiveness->load()) return;
        OPNLibWebRTCSessionImpl *strongImpl = weakImpl;
        if (!strongImpl) return;
        if (!error) {
            handleRemoteDescriptionSet();
            return;
        }
        if (!canRetryOriginalOffer) {
            const std::string message = "setRemoteDescription failed: " + OPNNSStringToString(error.localizedDescription);
            this->HandleConnectionState(false, message);
            return;
        }

        OPN::LogInfo(@"[LibWebRTC] filtered offer rejected (%@); retrying original GFN offer", error.localizedDescription);
        RTCSessionDescription *originalOffer = [[RTCSessionDescription alloc] initWithType:RTCSdpTypeOffer sdp:originalOfferString];
        [strongImpl.peerConnection setRemoteDescription:originalOffer completionHandler:^(NSError *retryError) {
            if (!callbackLiveness->load()) return;
            if (retryError) {
                const std::string message = "setRemoteDescription failed: " + OPNNSStringToString(retryError.localizedDescription);
                this->HandleConnectionState(false, message);
                return;
            }
            handleRemoteDescriptionSet();
        }];
    }];
#else
    (void)offerSdp;
    const std::string error = "libwebrtc backend requested in a build without WebRTC.framework";
    if (m_onState) m_onState(false, error);
#endif
}

void LibWebRTCStreamSession::Stop() {
    if (m_callbackLiveness) m_callbackLiveness->store(false);
    StopAudioDeviceMonitoring();
    StopStatsPolling();
    StopMicrophoneLevelPolling();
    {
        std::lock_guard<std::mutex> lock(m_statsMutex);
        m_statsRequestInFlight = false;
    }
#if defined(OPN_HAVE_LIBWEBRTC)
    if (m_impl) {
        OPNLibWebRTCSessionImpl *impl = (__bridge_transfer OPNLibWebRTCSessionImpl *)m_impl;
        impl.owner = nullptr;
        impl.reliableInputChannel.delegate = nil;
        impl.partialInputChannel.delegate = nil;
        impl.peerConnection.delegate = nil;
        if (impl.remoteVideoTrack && impl.remoteVideoRenderer) {
            [impl.remoteVideoTrack removeRenderer:impl.remoteVideoRenderer];
        }
        impl.remoteAudioTrack.isEnabled = NO;
        impl.localMicrophoneTrack.isEnabled = NO;
        [impl.remoteVideoView removeFromSuperview];
        [impl.reliableInputChannel close];
        [impl.partialInputChannel close];
        [impl.peerConnection close];
        m_impl = nullptr;
    }
#else
    m_impl = nullptr;
#endif
    StopInputHeartbeat();
    m_inputReady = false;
    m_reliableOpen = false;
    m_partialOpen = false;
}

void LibWebRTCStreamSession::AddRemoteIceCandidate(const IceCandidatePayload &candidate) {
#if defined(OPN_HAVE_LIBWEBRTC)
    OPNLibWebRTCSessionImpl *impl = OPNImplFromOpaque(m_impl);
    if (!impl.peerConnection || candidate.candidate.empty()) return;
    OPN::LogInfo(@"[LibWebRTC] Adding remote ICE candidate mid=%s mline=%d length=%zu",
          candidate.sdpMid.empty() ? "(none)" : candidate.sdpMid.c_str(),
          candidate.sdpMLineIndex,
          candidate.candidate.size());
    RTCIceCandidate *rtcCandidate = [[RTCIceCandidate alloc] initWithSdp:OPNStringToNSString(candidate.candidate)
                                                            sdpMLineIndex:candidate.sdpMLineIndex
                                                                   sdpMid:candidate.sdpMid.empty() ? nil : OPNStringToNSString(candidate.sdpMid)];
    [impl.peerConnection addIceCandidate:rtcCandidate completionHandler:^(NSError *error) {
        if (error) {
            OPN::LogError(@"[LibWebRTC] addIceCandidate failed: %@", error.localizedDescription);
        } else {
            OPN::LogInfo(@"[LibWebRTC] addIceCandidate succeeded mid=%s mline=%d",
                  candidate.sdpMid.empty() ? "(none)" : candidate.sdpMid.c_str(),
                  candidate.sdpMLineIndex);
        }
    }];
#else
    (void)candidate;
#endif
}

void LibWebRTCStreamSession::OnAnswerReady(std::function<void(const SendAnswerRequest &)> cb) {
    m_onAnswer = std::move(cb);
}

void LibWebRTCStreamSession::OnIceCandidateReady(std::function<void(const IceCandidatePayload &)> cb) {
    m_onIceCandidate = std::move(cb);
}

void LibWebRTCStreamSession::SendInput(const uint8_t *data, size_t len) {
#if defined(OPN_HAVE_LIBWEBRTC)
    OPNLibWebRTCSessionImpl *impl = OPNImplFromOpaque(m_impl);
    if (!impl.reliableInputChannel || impl.reliableInputChannel.readyState != RTCDataChannelStateOpen || !data || len == 0) return;
    NSData *payload = [NSData dataWithBytes:data length:len];
    RTCDataBuffer *buffer = [[RTCDataBuffer alloc] initWithData:payload isBinary:YES];
    [impl.reliableInputChannel sendData:buffer];
#else
    (void)data;
    (void)len;
#endif
}

void LibWebRTCStreamSession::SendInputPartiallyReliable(const uint8_t *data, size_t len) {
#if defined(OPN_HAVE_LIBWEBRTC)
    OPNLibWebRTCSessionImpl *impl = OPNImplFromOpaque(m_impl);
    if (!impl.partialInputChannel || impl.partialInputChannel.readyState != RTCDataChannelStateOpen || !data || len == 0) return;
    if (impl.partialInputChannel.bufferedAmount > OPNPartialReliableInputBacklogLimitBytes) return;
    NSData *payload = [NSData dataWithBytes:data length:len];
    RTCDataBuffer *buffer = [[RTCDataBuffer alloc] initWithData:payload isBinary:YES];
    [impl.partialInputChannel sendData:buffer];
#else
    (void)data;
    (void)len;
#endif
}

void LibWebRTCStreamSession::CreateInputChannel() {
#if defined(OPN_HAVE_LIBWEBRTC)
    OPNLibWebRTCSessionImpl *impl = OPNImplFromOpaque(m_impl);
    if (!impl.peerConnection || impl.reliableInputChannel || impl.partialInputChannel) return;

    RTCDataChannelConfiguration *reliableConfig = [[RTCDataChannelConfiguration alloc] init];
    reliableConfig.isOrdered = YES;
    reliableConfig.maxRetransmits = -1;
    reliableConfig.maxPacketLifeTime = -1;
    impl.reliableInputChannel = [impl.peerConnection dataChannelForLabel:@"input_channel_v1" configuration:reliableConfig];
    impl.reliableInputChannel.delegate = impl;

    RTCDataChannelConfiguration *partialConfig = [[RTCDataChannelConfiguration alloc] init];
    partialConfig.isOrdered = NO;
    partialConfig.maxRetransmits = -1;
    partialConfig.maxPacketLifeTime = OPNPartialReliableInputLifetimeMs;
    impl.partialInputChannel = [impl.peerConnection dataChannelForLabel:@"input_channel_partially_reliable" configuration:partialConfig];
    impl.partialInputChannel.delegate = impl;
#endif
}

bool LibWebRTCStreamSession::InputReady() const {
    return m_inputReady;
}

void LibWebRTCStreamSession::SendKeyEvent(uint16_t keycode, uint16_t scancode, uint16_t modifiers, bool down) {
    Input::KeyboardPayload payload;
    payload.keycode = keycode;
    payload.scancode = scancode;
    payload.modifiers = modifiers;
    payload.timestampUs = Input::TimestampUs();
    const std::vector<uint8_t> encoded = down ? m_inputEncoder.EncodeKeyDown(payload) : m_inputEncoder.EncodeKeyUp(payload);
    SendInput(encoded.data(), encoded.size());
}

void LibWebRTCStreamSession::SendMouseMove(int16_t dx, int16_t dy) {
    Input::MouseMovePayload payload;
    payload.dx = dx;
    payload.dy = dy;
    payload.timestampUs = Input::TimestampUs();
    const std::vector<uint8_t> encoded = m_inputEncoder.EncodeMouseMove(payload);
    SendInputPartiallyReliable(encoded.data(), encoded.size());
}

void LibWebRTCStreamSession::SendMouseButton(uint8_t button, bool down) {
    Input::MouseButtonPayload payload;
    payload.button = button;
    payload.timestampUs = Input::TimestampUs();
    const std::vector<uint8_t> encoded = down ? m_inputEncoder.EncodeMouseButtonDown(payload) : m_inputEncoder.EncodeMouseButtonUp(payload);
    SendInput(encoded.data(), encoded.size());
}

void LibWebRTCStreamSession::SendMouseWheel(int16_t delta) {
    Input::MouseWheelPayload payload;
    payload.delta = delta;
    payload.timestampUs = Input::TimestampUs();
    const std::vector<uint8_t> encoded = m_inputEncoder.EncodeMouseWheel(payload);
    SendInput(encoded.data(), encoded.size());
}

void LibWebRTCStreamSession::SendUtf8Text(const std::string &text) {
    const std::vector<uint8_t> encoded = m_inputEncoder.EncodeUtf8Text(text);
    if (!encoded.empty()) SendInput(encoded.data(), encoded.size());
}

void LibWebRTCStreamSession::SendGamepadState(const Input::GamepadState &state, uint16_t bitmap) {
    const std::vector<uint8_t> encoded = m_inputEncoder.EncodeGamepadState(state, bitmap, true);
    SendInputPartiallyReliable(encoded.data(), encoded.size());
}

void LibWebRTCStreamSession::SetMicrophoneEnabled(bool enabled) {
    m_microphoneEnabled = enabled;
#if defined(OPN_HAVE_LIBWEBRTC)
    OPNLibWebRTCSessionImpl *impl = OPNImplFromOpaque(m_impl);
    if (impl.localMicrophoneTrack) {
        impl.localMicrophoneTrack.isEnabled = enabled ? YES : NO;
    }
    if (enabled && impl.localMicrophoneTrack) {
        StartMicrophoneLevelPolling();
    } else if (!enabled && m_onMicrophoneLevel) {
        m_onMicrophoneLevel(0.0);
    }
#endif
}

void LibWebRTCStreamSession::SetGameVolume(double volume) {
    m_gameVolume = std::max(0.0, std::min(volume, 1.0));
#if defined(OPN_HAVE_LIBWEBRTC)
    OPNLibWebRTCSessionImpl *impl = OPNImplFromOpaque(m_impl);
    if (impl.remoteAudioTrack) {
        impl.remoteAudioTrack.source.volume = m_gameVolume;
    }
#endif
}

void LibWebRTCStreamSession::SetMicrophoneVolume(double volume) {
    m_microphoneVolumeLevel = std::max(0.0, std::min(volume, 1.0));
#if defined(OPN_HAVE_LIBWEBRTC)
    OPNLibWebRTCSessionImpl *impl = OPNImplFromOpaque(m_impl);
    if (impl.localMicrophoneTrack) {
        impl.localMicrophoneTrack.source.volume = m_microphoneVolumeLevel;
    }
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
    OPN::LogInfo(@"[LibWebRTC] Runtime bitrate limit %d Mbps applied=%d reason=%s", clampedMbps, ok, reason ? reason : "manual");
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

void LibWebRTCStreamSession::SetLocalVideoEnhancement(int mode, int sharpness, int denoise) {
    std::lock_guard<std::mutex> lock(m_statsMutex);
    m_localEnhancementMode = std::max(0, std::min(mode, 3));
    m_localEnhancementSharpness = std::max(0, std::min(sharpness, 20));
    m_localEnhancementDenoise = std::max(0, std::min(denoise, 10));
}

void LibWebRTCStreamSession::SetEnhancedVideoFrameCaptureEnabled(bool enabled) {
    std::lock_guard<std::mutex> lock(m_statsMutex);
    m_enhancedVideoFrameCaptureEnabled = enabled;
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

void LibWebRTCStreamSession::OnMicrophoneLevel(MicrophoneLevelCallback cb) {
    m_onMicrophoneLevel = std::move(cb);
}

void LibWebRTCStreamSession::OnVideoFrame(VideoFrameCallback cb) {
    m_onVideoFrame = std::move(cb);
}

void LibWebRTCStreamSession::OnEnhancedVideoFrame(VideoFrameCallback cb) {
    m_onEnhancedVideoFrame = std::move(cb);
}

void LibWebRTCStreamSession::OnGameAudioFrame(GameAudioFrameCallback cb) {
    m_onGameAudioFrame = std::move(cb);
}

void LibWebRTCStreamSession::OnClipboardText(ClipboardTextCallback cb) {
    m_onClipboardText = std::move(cb);
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

void LibWebRTCStreamSession::HandleGameAudioFrame(const void *audioBufferList, uint32_t frameCount, double sampleRate, uint32_t channels) {
    if (m_onGameAudioFrame) m_onGameAudioFrame(audioBufferList, frameCount, sampleRate, channels);
}

void LibWebRTCStreamSession::RefreshAudioDevices() {
#if defined(OPN_HAVE_LIBWEBRTC)
    OPNAudioDeviceMonitorContext *monitorContext = (__bridge OPNAudioDeviceMonitorContext *)m_audioDeviceMonitorContext;
    if (!monitorContext.isActive || !monitorContext.owner) {
        OPN::LogInfo(@"[LibWebRTC] audio device refresh skipped: monitor inactive");
        return;
    }

    OPNLibWebRTCSessionImpl *impl = OPNImplFromOpaque(m_impl);
    if (!impl.peerConnection) {
        OPN::LogInfo(@"[LibWebRTC] audio device refresh skipped: peer connection missing");
        return;
    }

    if (impl.audioDevice) {
        [impl.audioDevice handleDefaultDeviceChange];
        OPN::LogInfo(@"[LibWebRTC] audio device refresh delegated to CoreAudio RTC device input=%u output=%u",
              m_defaultInputDevice,
              m_defaultOutputDevice);
        return;
    }

    Class audioSessionClass = NSClassFromString(@"RTCAudioSession");
    id audioSession = audioSessionClass ? [audioSessionClass performSelector:@selector(sharedInstance)] : nil;
    if (!audioSession) {
        OPN::LogInfo(@"[LibWebRTC] audio device refresh unavailable: RTCAudioSession missing on this platform");
        return;
    }

    SEL useManualAudioSelector = NSSelectorFromString(@"useManualAudio");
    SEL isAudioEnabledSelector = NSSelectorFromString(@"isAudioEnabled");
    SEL setUseManualAudioSelector = NSSelectorFromString(@"setUseManualAudio:");
    SEL setIsAudioEnabledSelector = NSSelectorFromString(@"setIsAudioEnabled:");

    const uint64_t refreshGeneration = m_audioDeviceChangeGeneration;
    const BOOL wasManualAudio = [audioSession respondsToSelector:useManualAudioSelector] ? ((BOOL (*)(id, SEL))objc_msgSend)(audioSession, useManualAudioSelector) : NO;
    const BOOL wasAudioEnabled = [audioSession respondsToSelector:isAudioEnabledSelector] ? ((BOOL (*)(id, SEL))objc_msgSend)(audioSession, isAudioEnabledSelector) : YES;

    const BOOL shouldRestoreMicrophone = impl.localMicrophoneTrack ? (impl.localMicrophoneTrack.isEnabled ? YES : NO) : NO;
    if (impl.remoteAudioTrack) impl.remoteAudioTrack.isEnabled = NO;
    if (impl.localMicrophoneTrack) impl.localMicrophoneTrack.isEnabled = NO;

    if ([audioSession respondsToSelector:setUseManualAudioSelector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(audioSession, setUseManualAudioSelector, YES);
    }
    if ([audioSession respondsToSelector:setIsAudioEnabledSelector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(audioSession, setIsAudioEnabledSelector, NO);
    }
    OPNResetRTCAudioSessionRouteToDefaults(audioSession);
    OPNSetRTCAudioSessionActive(audioSession, NO, @"audio route refresh");
    OPN::LogInfo(@"[LibWebRTC] audio device refresh scheduled input=%u output=%u rtcAudioSession=1",
          m_defaultInputDevice,
          m_defaultOutputDevice);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (!monitorContext.isActive || !monitorContext.owner) return;
        LibWebRTCStreamSession *owner = monitorContext.owner;
        if (!owner->m_impl) return;
        if (owner->m_audioDeviceChangeGeneration != refreshGeneration) {
            OPN::LogInfo(@"[LibWebRTC] audio device refresh superseded generation=%llu current=%llu",
                  (unsigned long long)refreshGeneration,
                  (unsigned long long)owner->m_audioDeviceChangeGeneration);
            return;
        }

        id activeAudioSession = audioSessionClass ? [audioSessionClass performSelector:@selector(sharedInstance)] : nil;
        if (activeAudioSession) {
            OPNResetRTCAudioSessionRouteToDefaults(activeAudioSession);
            OPNSetRTCAudioSessionActive(activeAudioSession, YES, @"audio route refresh");
            if ([activeAudioSession respondsToSelector:setIsAudioEnabledSelector]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(activeAudioSession, setIsAudioEnabledSelector, YES);
            }
            if ([activeAudioSession respondsToSelector:setUseManualAudioSelector]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(activeAudioSession, setUseManualAudioSelector, wasManualAudio);
            }
            if (wasManualAudio && !wasAudioEnabled) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(activeAudioSession, setIsAudioEnabledSelector, NO);
            }
        }

        OPNLibWebRTCSessionImpl *activeImpl = OPNImplFromOpaque(owner->m_impl);
        if (activeImpl.remoteAudioTrack) {
            activeImpl.remoteAudioTrack.isEnabled = YES;
            activeImpl.remoteAudioTrack.source.volume = owner->m_gameVolume;
        }
        if (activeImpl.localMicrophoneTrack) {
            activeImpl.localMicrophoneTrack.isEnabled = (owner->m_microphoneEnabled && shouldRestoreMicrophone) ? YES : NO;
            activeImpl.localMicrophoneTrack.source.volume = owner->m_microphoneVolumeLevel;
        }
        OPN::LogInfo(@"[LibWebRTC] audio device refresh applied input=%u output=%u remoteTrack=%d micTrack=%d micEnabled=%d",
              owner->m_defaultInputDevice,
              owner->m_defaultOutputDevice,
              activeImpl.remoteAudioTrack ? 1 : 0,
              activeImpl.localMicrophoneTrack ? 1 : 0,
              activeImpl.localMicrophoneTrack && activeImpl.localMicrophoneTrack.isEnabled ? 1 : 0);
    });
#endif
}

void LibWebRTCStreamSession::StartAudioDeviceMonitoring() {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    bool expected = false;
    if (!m_audioDeviceMonitoringActive.compare_exchange_strong(expected, true)) {
#pragma clang diagnostic pop
        return;
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    m_defaultInputDevice = OPNDefaultAudioDevice(kAudioHardwarePropertyDefaultInputDevice);
    m_defaultOutputDevice = OPNDefaultAudioDevice(kAudioHardwarePropertyDefaultOutputDevice);

    OPNAudioDeviceMonitorContext *context = [[OPNAudioDeviceMonitorContext alloc] init];
    context.owner = this;
    context.active = YES;
    m_audioDeviceMonitorContext = (__bridge_retained void *)context;

    AudioObjectPropertyAddress devicesAddress = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    AudioObjectPropertyAddress defaultInputAddress = {
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    AudioObjectPropertyAddress defaultOutputAddress = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };

    OSStatus devicesStatus = AudioObjectAddPropertyListener(kAudioObjectSystemObject, &devicesAddress, OPNAudioDevicesChanged, m_audioDeviceMonitorContext);
    OSStatus inputStatus = AudioObjectAddPropertyListener(kAudioObjectSystemObject, &defaultInputAddress, OPNAudioDevicesChanged, m_audioDeviceMonitorContext);
    OSStatus outputStatus = AudioObjectAddPropertyListener(kAudioObjectSystemObject, &defaultOutputAddress, OPNAudioDevicesChanged, m_audioDeviceMonitorContext);
    OPN::LogInfo(@"[LibWebRTC] audio device monitoring started devices=%d input=%d output=%d currentInput=%u currentOutput=%u",
          devicesStatus,
          inputStatus,
          outputStatus,
          m_defaultInputDevice,
          m_defaultOutputDevice);
#pragma clang diagnostic pop
}

void LibWebRTCStreamSession::StopAudioDeviceMonitoring() {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    bool expected = true;
    if (!m_audioDeviceMonitoringActive.compare_exchange_strong(expected, false)) {
#pragma clang diagnostic pop
        return;
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    AudioObjectPropertyAddress devicesAddress = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    AudioObjectPropertyAddress defaultInputAddress = {
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    AudioObjectPropertyAddress defaultOutputAddress = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };

    OPNAudioDeviceMonitorContext *context = (__bridge OPNAudioDeviceMonitorContext *)m_audioDeviceMonitorContext;
    context.active = NO;
    context.owner = nullptr;

    AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &devicesAddress, OPNAudioDevicesChanged, m_audioDeviceMonitorContext);
    AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &defaultInputAddress, OPNAudioDevicesChanged, m_audioDeviceMonitorContext);
    AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &defaultOutputAddress, OPNAudioDevicesChanged, m_audioDeviceMonitorContext);
    if (m_audioDeviceMonitorContext) {
        OPNAudioDeviceMonitorContext *releasedContext = (__bridge_transfer OPNAudioDeviceMonitorContext *)m_audioDeviceMonitorContext;
        (void)releasedContext;
        m_audioDeviceMonitorContext = nullptr;
    }
    m_defaultInputDevice = kAudioObjectUnknown;
    m_defaultOutputDevice = kAudioObjectUnknown;
    OPN::LogInfo(@"[LibWebRTC] audio device monitoring stopped");
#pragma clang diagnostic pop
}

void LibWebRTCStreamSession::HandleAudioDeviceChange() {
    if (!m_audioDeviceMonitoringActive.load()) return;

    const AudioDeviceID inputDevice = OPNDefaultAudioDevice(kAudioHardwarePropertyDefaultInputDevice);
    const AudioDeviceID outputDevice = OPNDefaultAudioDevice(kAudioHardwarePropertyDefaultOutputDevice);
    if (outputDevice == kAudioObjectUnknown) {
        const uint64_t generation = ++m_audioDeviceChangeGeneration;
        OPNAudioDeviceMonitorContext *monitorContext = (__bridge OPNAudioDeviceMonitorContext *)m_audioDeviceMonitorContext;
        if (m_audioDeviceUnavailableRetryCount < 10) {
            m_audioDeviceUnavailableRetryCount++;
            OPN::LogInfo(@"[LibWebRTC] default output device unavailable during hotplug input=%u output=%u retry=%d", inputDevice, outputDevice, m_audioDeviceUnavailableRetryCount);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                if (!monitorContext.isActive || !monitorContext.owner) return;
                if (monitorContext.owner->m_audioDeviceChangeGeneration != generation) return;
                monitorContext.owner->HandleAudioDeviceChange();
            });
        } else {
            OPN::LogError(@"[LibWebRTC] default output device remained unavailable after headset hotplug retries");
        }
        return;
    }

    m_audioDeviceUnavailableRetryCount = 0;

    const bool inputChanged = inputDevice != m_defaultInputDevice;
    const bool outputChanged = outputDevice != m_defaultOutputDevice;
    if (!inputChanged && !outputChanged) return;

    OPN::LogInfo(@"[LibWebRTC] default audio device changed input=%u->%u output=%u->%u",
          m_defaultInputDevice,
              inputDevice,
              m_defaultOutputDevice,
              outputDevice);
    m_defaultInputDevice = inputDevice;
    m_defaultOutputDevice = outputDevice;
    RefreshAudioDevices();
#if defined(OPN_HAVE_LIBWEBRTC)
    const uint64_t generation = ++m_audioDeviceChangeGeneration;
    OPNLibWebRTCSessionImpl *impl = OPNImplFromOpaque(m_impl);
    const bool customAudioDeviceActive = impl.audioDevice != nil;
    if (!customAudioDeviceActive && OPNEnvFlagEnabled("OPN_ENABLE_WEBRTC_AUDIO_HOTSWAP_RECOVERY", true)) {
        OPNAudioDeviceMonitorContext *monitorContext = (__bridge OPNAudioDeviceMonitorContext *)m_audioDeviceMonitorContext;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 700 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (!monitorContext.isActive || !monitorContext.owner) return;
            if (monitorContext.owner->m_audioDeviceChangeGeneration != generation) return;
            if (!monitorContext.owner->m_impl) return;
            OPN::LogInfo(@"[LibWebRTC] forcing stream recovery after audio device change input=%u output=%u",
                  monitorContext.owner->m_defaultInputDevice,
                  monitorContext.owner->m_defaultOutputDevice);
            monitorContext.owner->HandleConnectionState(false, "webrtc audio device changed");
        });
    }
#endif
}

void LibWebRTCStreamSession::StartMicrophoneLevelPolling() {
#if defined(OPN_HAVE_LIBWEBRTC)
    if (m_microphoneLevelTimer) return;
    dispatch_queue_t statsQueue = m_statsQueue ? (__bridge dispatch_queue_t)m_statsQueue : dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, statsQueue);
    if (!timer) return;

    m_microphoneLevelTimer = (__bridge_retained void *)timer;
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              100 * NSEC_PER_MSEC,
                              20 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        OPNLibWebRTCSessionImpl *impl = OPNImplFromOpaque(this->m_impl);
        if (!impl.peerConnection || !impl.localMicrophoneTrack) return;
        if (!this->m_microphoneEnabled || !impl.localMicrophoneTrack.isEnabled) {
            if (this->m_onMicrophoneLevel) this->m_onMicrophoneLevel(0.0);
            return;
        }
        if (this->m_microphoneLevelRequestInFlight) return;
        this->m_microphoneLevelRequestInFlight = true;
        [impl.peerConnection statisticsWithCompletionHandler:^(RTCStatisticsReport *report) {
            this->HandleMicrophoneLevelReport((__bridge void *)report);
        }];
    });
    dispatch_resume(timer);
    OPN::LogInfo(@"[LibWebRTC] microphone level polling started");
#endif
}

void LibWebRTCStreamSession::StopMicrophoneLevelPolling() {
    if (!m_microphoneLevelTimer) return;
    dispatch_source_t timer = (__bridge_transfer dispatch_source_t)m_microphoneLevelTimer;
    m_microphoneLevelTimer = nullptr;
    dispatch_source_cancel(timer);
    m_microphoneLevelRequestInFlight = false;
    if (m_onMicrophoneLevel) m_onMicrophoneLevel(0.0);
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
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
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
    OPN::LogInfo(@"[LibWebRTC] stats polling started");
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

void *LibWebRTCStreamSession::NativeWindowHandle() const {
    return m_nativeWindow;
}

void LibWebRTCStreamSession::SetNativeWindow(void *wnd) {
    m_nativeWindow = wnd;
}

void LibWebRTCStreamSession::HandleLocalIceCandidate(const IceCandidatePayload &candidate) {
    if (m_onIceCandidate) {
        m_onIceCandidate(candidate);
    }
}

void LibWebRTCStreamSession::HandleConnectionState(bool connected, const std::string &error) {
    if (connected) {
        {
            std::lock_guard<std::mutex> lock(m_statsMutex);
            m_latestStats.available = true;
            m_latestStats.videoPipelineMode = "libwebrtc connected";
        }
        StartStatsPolling();
    } else {
        StopStatsPolling();
    }
    if (m_onState) {
        m_onState(connected, error);
    }
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

void LibWebRTCStreamSession::HandleDataChannelState(const std::string &label, bool open) {
    if (label == "input_channel_v1") {
        m_reliableOpen = open;
    } else if (label == "input_channel_partially_reliable") {
        m_partialOpen = open;
    }
    if (!open) {
        m_inputReady = false;
        StopInputHeartbeat();
    }
}

void LibWebRTCStreamSession::HandleDataChannelMessage(const std::string &label, const uint8_t *data, size_t len) {
    if (label != "input_channel_v1" || !data || len < 2) return;

    if (m_inputReady) {
        std::string clipboardText;
        const uint8_t *payload = data;
        size_t payloadLength = len;
        if (len > 10 && data[0] == 0x23 && data[9] == 0x22) {
            payload = data + 10;
            payloadLength = len - 10;
        } else if (len > 12 && data[0] == 0x23 && data[9] == 0x21) {
            uint16_t wrappedLength = ((uint16_t)data[10] << 8) | (uint16_t)data[11];
            if (wrappedLength > 0 && wrappedLength <= len - 12) {
                payload = data + 12;
                payloadLength = wrappedLength;
            }
        }
        if (payloadLength >= 8 && OPNReadU32LE(payload) == Input::INPUT_UTF8_TEXT) {
            uint32_t textLength = OPNReadU32LE(payload + 4);
            if (textLength > 0 && textLength <= payloadLength - 8) {
                clipboardText = OPNValidUtf8StringFromBytes(payload + 8, textLength);
            }
        }
        if (clipboardText.empty() && payloadLength > 0 && (payload[0] == '{' || payload[0] == '[')) {
            NSData *jsonData = [NSData dataWithBytes:payload length:payloadLength];
            clipboardText = OPNClipboardTextFromJsonData(jsonData);
        }
        if (!clipboardText.empty() && m_onClipboardText) {
            m_onClipboardText(clipboardText);
            OPN::LogInfo(@"[LibWebRTC] remote clipboard text received bytes=%zu", len);
        }
        return;
    }

    const uint16_t firstWord = (uint16_t)data[0] | ((uint16_t)data[1] << 8);
    uint16_t version = 2;
    if (firstWord == 526) {
        if (len >= 4) version = (uint16_t)data[2] | ((uint16_t)data[3] << 8);
        OPN::LogInfo(@"[LibWebRTC] input handshake detected firstWord=526 version=%u", version);
    } else if (data[0] == 0x0e) {
        version = firstWord;
        OPN::LogInfo(@"[LibWebRTC] input handshake detected byte[0]=0x0e version=%u", version);
    } else {
        OPN::LogInfo(@"[LibWebRTC] input channel message before handshake len=%zu firstWord=0x%04x", len, firstWord);
        return;
    }

    m_inputEncoder.SetProtocolVersion(version);
    m_inputReady = m_reliableOpen && m_partialOpen;
    SendInput(data, len);
    StartInputHeartbeat();
    OPN::LogInfo(@"[LibWebRTC] input handshake complete protocol=v%u inputReady=%d", version, m_inputReady);
}

double LibWebRTCStreamSession::GameVolume() const {
    return m_gameVolume;
}

int LibWebRTCStreamSession::TargetFps() const {
    return std::max(30, std::min(m_settings.fps > 0 ? m_settings.fps : 60, 240));
}

void LibWebRTCStreamSession::LocalVideoEnhancement(int &mode, int &sharpness, int &denoise) const {
    std::lock_guard<std::mutex> lock(m_statsMutex);
    mode = m_localEnhancementMode;
    sharpness = m_localEnhancementSharpness;
    denoise = m_localEnhancementDenoise;
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
    m_latestStats.videoEnhancementFrameTimeMs = enhancementFrameTimeMs;
    m_latestStats.videoEnhancementDroppedFrames = enhancementDroppedFrames;
}

void LibWebRTCStreamSession::StartInputHeartbeat() {
    if (m_inputHeartbeat) return;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (!timer) return;
    m_inputHeartbeat = (__bridge_retained void *)timer;
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        if (!m_inputReady) return;
        std::vector<uint8_t> heartbeat = m_inputEncoder.EncodeHeartbeat();
        SendInput(heartbeat.data(), heartbeat.size());
    });
    dispatch_resume(timer);
}

void LibWebRTCStreamSession::StopInputHeartbeat() {
    if (!m_inputHeartbeat) return;
    dispatch_source_t timer = (__bridge_transfer dispatch_source_t)m_inputHeartbeat;
    dispatch_source_cancel(timer);
    m_inputHeartbeat = nullptr;
}

}

#if defined(OPN_HAVE_LIBWEBRTC)
@implementation OPNLibWebRTCSessionImpl

- (instancetype)initWithOwner:(OPN::LibWebRTCStreamSession *)owner {
    self = [super init];
    if (self) {
        _owner = owner;
    }
    return self;
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeSignalingState:(RTCSignalingState)stateChanged {
    (void)peerConnection;
    OPN::LogInfo(@"[LibWebRTC] signaling state=%ld", (long)stateChanged);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didAddStream:(RTCMediaStream *)stream {
    (void)peerConnection;
    (void)stream;
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveStream:(RTCMediaStream *)stream {
    (void)peerConnection;
    (void)stream;
}

- (void)peerConnectionShouldNegotiate:(RTCPeerConnection *)peerConnection {
    (void)peerConnection;
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceConnectionState:(RTCIceConnectionState)newState {
    (void)peerConnection;
    OPN::LogInfo(@"[LibWebRTC] ICE state=%ld", (long)newState);
    if (!_owner) return;
    if (newState == RTCIceConnectionStateConnected || newState == RTCIceConnectionStateCompleted) {
        _owner->HandleConnectionState(true, "");
    } else if (newState == RTCIceConnectionStateFailed || newState == RTCIceConnectionStateClosed) {
        _owner->HandleConnectionState(false, "libwebrtc ICE failed");
    }
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceGatheringState:(RTCIceGatheringState)newState {
    (void)peerConnection;
    OPN::LogInfo(@"[LibWebRTC] ICE gathering state=%ld", (long)newState);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didGenerateIceCandidate:(RTCIceCandidate *)candidate {
    (void)peerConnection;
    if (!_owner || !candidate) return;
    OPN::IceCandidatePayload payload;
    payload.candidate = OPN::OPNNSStringToString(candidate.sdp);
    payload.sdpMid = OPN::OPNNSStringToString(candidate.sdpMid);
    payload.sdpMLineIndex = candidate.sdpMLineIndex;
    _owner->HandleLocalIceCandidate(payload);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveIceCandidates:(NSArray<RTCIceCandidate *> *)candidates {
    (void)peerConnection;
    (void)candidates;
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didOpenDataChannel:(RTCDataChannel *)dataChannel {
    (void)peerConnection;
    dataChannel.delegate = self;
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeConnectionState:(RTCPeerConnectionState)newState {
    (void)peerConnection;
    OPN::LogInfo(@"[LibWebRTC] peer state=%ld", (long)newState);
    if (!_owner) return;
    if (newState == RTCPeerConnectionStateConnected) {
        _owner->HandleConnectionState(true, "");
    } else if (newState == RTCPeerConnectionStateFailed || newState == RTCPeerConnectionStateClosed) {
        _owner->HandleConnectionState(false, "libwebrtc peer connection failed");
    }
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didAddReceiver:(RTCRtpReceiver *)rtpReceiver streams:(NSArray<RTCMediaStream *> *)mediaStreams {
    (void)peerConnection;
    (void)mediaStreams;
    if ([rtpReceiver.track.kind isEqualToString:kRTCMediaStreamTrackKindVideo]) {
        OPN::LogInfo(@"[LibWebRTC] remote video receiver added: %@", rtpReceiver.track.trackId);
        RTCVideoTrack *videoTrack = (RTCVideoTrack *)rtpReceiver.track;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!_owner) return;
            NSView *parentView = (__bridge NSView *)_owner->NativeWindowHandle();
            if (!parentView) {
                OPN::LogError(@"[LibWebRTC] Cannot attach remote video: native view is missing");
                return;
            }
            if (![RTCMTLNSVideoView isMetalAvailable]) {
                OPN::LogError(@"[LibWebRTC] Cannot attach remote video: Metal renderer is unavailable");
                return;
            }

            if (self.remoteVideoTrack && self.remoteVideoRenderer) {
                [self.remoteVideoTrack removeRenderer:self.remoteVideoRenderer];
            }
            [self.remoteVideoView removeFromSuperview];

            OPNMetalVideoView *metalView = [[OPNMetalVideoView alloc] initWithFrame:parentView.bounds
                                                                          targetFps:_owner->TargetFps()
                                                                              owner:_owner];
            NSView *videoView = metalView;
            id<RTCVideoRenderer> videoRenderer = metalView;
            _owner->SetVideoRendererState("OPNMetalVideoView", "libwebrtc Metal display");
            videoView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            videoView.wantsLayer = YES;
            videoView.layer.backgroundColor = NSColor.blackColor.CGColor;
            [parentView addSubview:videoView positioned:NSWindowBelow relativeTo:nil];
            [videoTrack addRenderer:videoRenderer];

            self.remoteVideoTrack = videoTrack;
            self.remoteVideoView = videoView;
            self.remoteVideoRenderer = videoRenderer;
            OPN::LogInfo(@"[LibWebRTC] Remote video renderer attached to native view=%p metal=1 targetFps=%d", (__bridge void *)parentView, _owner->TargetFps());
        });
    } else if ([rtpReceiver.track.kind isEqualToString:kRTCMediaStreamTrackKindAudio]) {
        RTCAudioTrack *audioTrack = (RTCAudioTrack *)rtpReceiver.track;
        audioTrack.isEnabled = YES;
        audioTrack.source.volume = _owner ? _owner->GameVolume() : 1.0;
        self.remoteAudioTrack = audioTrack;
        OPN::LogInfo(@"[LibWebRTC] remote audio track enabled: %@ volume=%.2f", audioTrack.trackId, audioTrack.source.volume);
    }
}

- (void)dataChannelDidChangeState:(RTCDataChannel *)dataChannel {
    if (!_owner || !dataChannel) return;
    const bool open = dataChannel.readyState == RTCDataChannelStateOpen;
    _owner->HandleDataChannelState(OPN::OPNNSStringToString(dataChannel.label), open);
    OPN::LogInfo(@"[LibWebRTC] data channel %@ state=%ld inputReady=%d", dataChannel.label, (long)dataChannel.readyState, _owner->InputReady());
}

- (void)dataChannel:(RTCDataChannel *)dataChannel didReceiveMessageWithBuffer:(RTCDataBuffer *)buffer {
    if (!_owner || !dataChannel || !buffer) return;
    _owner->HandleDataChannelMessage(OPN::OPNNSStringToString(dataChannel.label), static_cast<const uint8_t *>(buffer.data.bytes), buffer.data.length);
}

@end
#endif
