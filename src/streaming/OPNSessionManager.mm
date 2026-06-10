
#include "OPNSessionManager.h"
#include "OPNStreamTypes.h"
#include "OPNStreamPreferences.h"
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonCrypto.h>
#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <mutex>
#include <unordered_map>

@class OPNParsedNegotiatedStreamProfile;
@class OPNParsedSessionProgress;
@class OPNParsedSessionAdState;

@interface OPNLocale : NSObject
+ (NSString *)currentGFNLocale;
@end

@interface OPNDeviceIdentity : NSObject
+ (NSString *)stableCloudmatchDeviceId;
@end

@interface OPNProtocolDebug : NSObject
+ (void)logJSONObjectWithLabel:(nullable NSString *)label object:(nullable id)object;
+ (void)logJSONDataWithLabel:(nullable NSString *)label data:(nullable NSData *)data;
@end

@interface OPNSessionJSONParser : NSObject
+ (OPNParsedNegotiatedStreamProfile *)parseNegotiatedStreamProfileFromSession:(NSDictionary *)session;
+ (OPNParsedSessionProgress *)parseSessionProgressFromSession:(NSDictionary *)session;
+ (OPNParsedSessionAdState *)parseSessionAdStateFromSession:(NSDictionary *)session;
@end

@interface OPNParsedNegotiatedStreamProfile : NSObject
@property(nonatomic, readonly) NSString *resolution;
@property(nonatomic, readonly) NSInteger fps;
@property(nonatomic, readonly) NSString *codec;
@property(nonatomic, readonly) NSString *colorQuality;
@property(nonatomic, readonly) NSInteger bitDepth;
@property(nonatomic, readonly) NSInteger chromaFormat;
@property(nonatomic, readonly) NSInteger prefilterMode;
@property(nonatomic, readonly) NSInteger prefilterSharpness;
@property(nonatomic, readonly) NSInteger prefilterDenoise;
@property(nonatomic, readonly) NSInteger prefilterModel;
@end

@interface OPNParsedSessionProgress : NSObject
@property(nonatomic, readonly) NSInteger queuePosition;
@property(nonatomic, readonly) NSInteger seatSetupStep;
@property(nonatomic, readonly) NSInteger progressState;
@property(nonatomic, readonly) double remainingPlaytimeHours;
@property(nonatomic, readonly) BOOL remainingPlaytimeAvailable;
@end

@interface OPNParsedSessionAdMediaFile : NSObject
@property(nonatomic, readonly) NSString *mediaFileUrl;
@property(nonatomic, readonly) NSString *encodingProfile;
@end

@interface OPNParsedSessionAd : NSObject
@property(nonatomic, readonly) NSString *adId;
@property(nonatomic, readonly) NSInteger adState;
@property(nonatomic, readonly) NSString *adUrl;
@property(nonatomic, readonly) NSString *mediaUrl;
@property(nonatomic, readonly) NSArray<OPNParsedSessionAdMediaFile *> *adMediaFiles;
@property(nonatomic, readonly) NSString *clickThroughUrl;
@property(nonatomic, readonly) NSInteger adLengthInSeconds;
@property(nonatomic, readonly) NSInteger durationMs;
@property(nonatomic, readonly) NSString *title;
@property(nonatomic, readonly) NSString *adDescription;
@end

@interface OPNParsedSessionAdState : NSObject
@property(nonatomic, readonly) BOOL isAdsRequired;
@property(nonatomic, readonly) BOOL sessionAdsRequired;
@property(nonatomic, readonly) BOOL isQueuePaused;
@property(nonatomic, readonly) BOOL serverSentEmptyAds;
@property(nonatomic, readonly) NSInteger gracePeriodSeconds;
@property(nonatomic, readonly) NSString *message;
@property(nonatomic, readonly) NSArray<OPNParsedSessionAd *> *sessionAds;
@end

namespace OPN {

struct SessionManagerStorage {
    std::string accessToken;
    std::string streamingBaseUrl;
    std::mutex adStateMutex;
    std::unordered_map<std::string, SessionAdState> adStatesBySessionId;
};

}

static NSString *kNvClientId = @"ec7e38d4-03af-4b58-b131-cfb0495903ab";
static NSString *kNvClientVersion = @"2.0.80.173";
static NSString *kPersistedActiveSessionIdKey = @"OpenNOW.Stream.ActiveSessionId";

static NSArray *ArrayValue(id value) {
    return [value isKindOfClass:[NSArray class]] ? (NSArray *)value : @[];
}

static NSDictionary *DictionaryValue(id value) {
    return [value isKindOfClass:[NSDictionary class]] ? (NSDictionary *)value : nil;
}

static NSString *StringValue(id value) {
    return [value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0 ? (NSString *)value : nil;
}

static NSString *GetUserAgent() {
    return @"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36 NVIDIACEFClient/HEAD/debb5919f6 GFN-PC/2.0.80.173";
}

static std::string StableCloudmatchDeviceIdString() {
    NSString *deviceId = [OPNDeviceIdentity stableCloudmatchDeviceId];
    return deviceId.UTF8String ?: "";
}


static int AdActionCode(const std::string &action) {
    if (action == "start") return 1;
    if (action == "pause") return 2;
    if (action == "resume") return 3;
    if (action == "finish") return 4;
    if (action == "cancel") return 5;
    return 0;
}

static std::string ResolveSessionBaseUrl(const std::string &streamingBaseUrl, const std::string &serverIp) {
    auto normalizedHTTPSBaseUrl = [](const std::string &url) -> std::string {
        if (url.empty()) return std::string();
        NSString *text = [[NSString alloc] initWithBytes:url.data() length:url.size() encoding:NSUTF8StringEncoding];
        NSURLComponents *components = text.length > 0 ? [NSURLComponents componentsWithString:text] : nil;
        NSString *scheme = components.scheme.lowercaseString;
        if (![scheme isEqualToString:@"https"] || components.host.length == 0) return std::string();
        std::string base = url;
        while (!base.empty() && base.back() == '/') base.pop_back();
        return base;
    };

    if (serverIp.empty()) {
        std::string base = normalizedHTTPSBaseUrl(streamingBaseUrl);
        return base.empty() ? "https://prod.cloudmatchbeta.nvidiagrid.net" : base;
    }
    if (serverIp.rfind("https://", 0) == 0 || serverIp.rfind("http://", 0) == 0) {
        std::string base = normalizedHTTPSBaseUrl(serverIp);
        return base.empty() ? "https://prod.cloudmatchbeta.nvidiagrid.net" : base;
    }
    return "https://" + serverIp;
}

static bool IsUsableEndpointHost(NSString *host) {
    return [host isKindOfClass:[NSString class]] && host.length > 0 && ![host hasPrefix:@"."];
}

static NSString *StringFromStdString(const std::string &value, NSString *fallback = @"") {
    if (value.empty()) return fallback ?: @"";
    NSString *string = [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding];
    return string ?: (fallback ?: @"");
}

static bool IsValidSessionIdString(const std::string &sessionId) {
    if (sessionId.empty()) return false;
    return std::all_of(sessionId.begin(), sessionId.end(), [](unsigned char ch) {
        return ch > 0x20 && ch < 0x7f;
    });
}

static std::string EscapedLogString(const std::string &value) {
    if (value.empty()) return "(empty)";
    std::string escaped;
    escaped.reserve(value.size());
    for (unsigned char ch : value) {
        if (ch >= 0x20 && ch < 0x7f) {
            escaped.push_back(static_cast<char>(ch));
            continue;
        }
        char buffer[5] = {0};
        std::snprintf(buffer, sizeof(buffer), "\\x%02X", ch);
        escaped.append(buffer);
    }
    return escaped;
}

static id NetworkTestSessionIdValue(const OPN::StreamSettings &settings) {
    NSString *value = StringFromStdString(settings.networkTestSessionId);
    return value.length > 0 ? value : (id)[NSNull null];
}

static NSString *NetworkTypeValue(const OPN::StreamSettings &settings) {
    NSString *value = StringFromStdString(settings.networkType, @"Unknown");
    return value.length > 0 ? value : @"Unknown";
}

static NSString *NetworkLatencyValue(const OPN::StreamSettings &settings) {
    return settings.networkLatencyMs >= 0 ? [NSString stringWithFormat:@"%d", settings.networkLatencyMs] : @"Unknown";
}

static NSArray *AvailableSupportedControllersValue(const OPN::StreamSettings &settings) {
    if (settings.availableSupportedControllers.empty()) return @[];
    NSMutableArray *controllers = [NSMutableArray arrayWithCapacity:settings.availableSupportedControllers.size()];
    for (const std::string &controller : settings.availableSupportedControllers) {
        NSString *value = StringFromStdString(controller);
        if (value.length > 0) [controllers addObject:value];
    }
    return controllers;
}

static int IntValue(id value, int fallback = 0) {
    if ([value isKindOfClass:[NSNumber class]]) return [(NSNumber *)value intValue];
    if ([value isKindOfClass:[NSString class]]) return [(NSString *)value intValue];
    return fallback;
}

static void ParseRemainingPlaytime(NSDictionary *session, OPN::SessionInfo &info) {
    OPNParsedSessionProgress *parsed = [OPNSessionJSONParser parseSessionProgressFromSession:session];
    if (parsed.remainingPlaytimeAvailable) {
        info.remainingPlaytimeHours = parsed.remainingPlaytimeHours;
        info.remainingPlaytimeAvailable = true;
    }
}

static bool VerboseSessionHttpLoggingEnabled() {
    const char *value = std::getenv("OPN_VERBOSE_SESSION_HTTP");
    return value && std::strcmp(value, "1") == 0;
}

static void StreamColorProfileFields(const OPN::StreamSettings &settings, int &bitDepth, int &chromaFormat) {
    bitDepth = 0;
    chromaFormat = 0;
    if (settings.colorQuality == "10bit_420") {
        bitDepth = 10;
    } else if (settings.colorQuality == "8bit_444") {
        chromaFormat = 2;
    } else if (settings.colorQuality == "10bit_444") {
        bitDepth = 10;
        chromaFormat = 2;
    }
}

static bool RequestedHdrEnabled(const OPN::StreamSettings &settings, const OPN::StreamDeviceCapabilities &capabilities) {
    return settings.enableHdr && capabilities.hdrDisplaySupported;
}

static NSDictionary *ClientDisplayHdrCapabilities(const OPN::StreamDeviceCapabilities &capabilities) {
    NSMutableDictionary *payload = [@{
        @"hdrSupported": @(capabilities.hdrDisplaySupported),
        @"bitDepth": @(capabilities.hdrDisplaySupported ? 10 : 8),
        @"maxDisplayWidth": @(std::max(0, capabilities.maxDisplayWidth)),
        @"maxDisplayHeight": @(std::max(0, capabilities.maxDisplayHeight)),
        @"maxDisplayRefreshRate": @(std::max(0, capabilities.maxDisplayRefreshRate)),
    } mutableCopy];
    if (capabilities.hdrDisplaySupported) payload[@"supportedHdrModes"] = @[@"HDR"];
    else payload[@"supportedHdrModes"] = @[];
    return payload;
}

static id MonitorDisplayData(const OPN::StreamDeviceCapabilities &capabilities, bool hdrEnabled) {
    if (!hdrEnabled || !capabilities.hdrDisplaySupported) return [NSNull null];
    return @{
        @"desiredContentMaxLuminance": @1000,
        @"desiredContentMinLuminance": @0,
        @"desiredContentMaxFrameAverageLuminance": @400,
    };
}

static NSDictionary *MonitorSettings(const OPN::StreamSettings &settings,
                                    const OPN::StreamDeviceCapabilities &capabilities,
                                    bool hdrEnabled) {
    int width = 1920;
    int height = 1080;
    sscanf(settings.resolution.c_str(), "%dx%d", &width, &height);
    width = std::max(640, width);
    height = std::max(360, height);
    return @{
        @"monitorId": @0,
        @"positionX": @0,
        @"positionY": @0,
        @"widthInPixels": @(width),
        @"heightInPixels": @(height),
        @"framesPerSecond": @(settings.fps),
        @"sdrHdrMode": hdrEnabled ? @1 : @0,
        @"displayData": MonitorDisplayData(capabilities, hdrEnabled),
        @"hdr10PlusGamingData": [NSNull null],
        @"dpi": @(std::max(0, capabilities.displayDpi)),
    };
}

static NSDictionary *RequestedStreamingFeatures(const OPN::StreamSettings &settings, bool hdrEnabled) {
    int bitDepth = 0;
    int chromaFormat = 0;
    StreamColorProfileFields(settings, bitDepth, chromaFormat);
    const int prefilterMode = std::max(0, std::min(settings.prefilterMode, 2));
    const int prefilterSharpness = std::max(0, std::min(settings.prefilterSharpness, 10));
    const int prefilterDenoise = std::max(0, std::min(settings.prefilterDenoise, 10));
    return @{
        @"reflex": @(settings.enableReflex),
        @"bitDepth": @(bitDepth),
        @"cloudGsync": @(settings.enableCloudGsync),
        @"enabledL4S": @(settings.enableL4S),
        @"mouseMovementFlags": @0,
        @"trueHdr": @(hdrEnabled),
        @"supportedHidDevices": @((unsigned long long)settings.supportedHidDevices),
        @"profile": @0,
        @"fallbackToLogicalResolution": @NO,
        @"hidDevices": [NSNull null],
        @"chromaFormat": @(chromaFormat),
        @"prefilterMode": @(prefilterMode),
        @"prefilterSharpness": @(prefilterSharpness),
        @"prefilterNoiseReduction": @(prefilterDenoise),
        @"hudStreamingMode": @0,
        @"sdrColorSpace": @2,
        @"hdrColorSpace": @0,
    };
}

static void ParseStreamProfile(NSDictionary *session, OPN::NegotiatedStreamProfile &profile) {
    OPNParsedNegotiatedStreamProfile *parsed = [OPNSessionJSONParser parseNegotiatedStreamProfileFromSession:session];
    profile.resolution = parsed.resolution.UTF8String ?: "";
    profile.codec = parsed.codec.UTF8String ?: "";
    profile.fps = (int)parsed.fps;
    profile.bitDepth = (int)parsed.bitDepth;
    profile.chromaFormat = (int)parsed.chromaFormat;
    profile.colorQuality = parsed.colorQuality.UTF8String ?: "";
    profile.prefilterMode = (int)parsed.prefilterMode;
    profile.prefilterSharpness = (int)parsed.prefilterSharpness;
    profile.prefilterDenoise = (int)parsed.prefilterDenoise;
    profile.prefilterModel = (int)parsed.prefilterModel;
    if (profile.bitDepth >= 0 || profile.chromaFormat >= 0) {
        OPNLogInfo(@"[SessionManager] Finalized stream features bitDepth=%d chromaFormat=%d color=%s",
              profile.bitDepth,
              profile.chromaFormat,
              profile.colorQuality.c_str());
    }
}

static void ParseQueueProgress(NSDictionary *session, OPN::SessionInfo &info) {
    OPNParsedSessionProgress *parsed = [OPNSessionJSONParser parseSessionProgressFromSession:session];
    info.queuePosition = (int)parsed.queuePosition;
    info.seatSetupStep = (int)parsed.seatSetupStep;
    info.progressState = static_cast<OPN::SessionProgressState>(parsed.progressState);
}

static void ParseSessionAds(NSDictionary *session, OPN::SessionAdState &adState) {
    OPNParsedSessionAdState *parsed = [OPNSessionJSONParser parseSessionAdStateFromSession:session];
    adState.isAdsRequired = parsed.isAdsRequired;
    adState.sessionAdsRequired = parsed.sessionAdsRequired;
    adState.isQueuePaused = parsed.isQueuePaused;
    adState.serverSentEmptyAds = parsed.serverSentEmptyAds;
    adState.gracePeriodSeconds = (int)parsed.gracePeriodSeconds;
    adState.message = parsed.message.UTF8String ?: "";
    adState.sessionAds.clear();
    for (OPNParsedSessionAd *ad in parsed.sessionAds) {
        OPN::SessionAdInfo out;
        out.adId = ad.adId.UTF8String ?: "";
        out.adState = (int)ad.adState;
        out.adUrl = ad.adUrl.UTF8String ?: "";
        out.mediaUrl = ad.mediaUrl.UTF8String ?: "";
        out.clickThroughUrl = ad.clickThroughUrl.UTF8String ?: "";
        out.adLengthInSeconds = (int)ad.adLengthInSeconds;
        out.durationMs = (int)ad.durationMs;
        out.title = ad.title.UTF8String ?: "";
        out.description = ad.adDescription.UTF8String ?: "";
        for (OPNParsedSessionAdMediaFile *file in ad.adMediaFiles) {
            OPN::SessionAdMediaFile media;
            media.mediaFileUrl = file.mediaFileUrl.UTF8String ?: "";
            media.encodingProfile = file.encodingProfile.UTF8String ?: "";
            out.adMediaFiles.push_back(media);
        }
        adState.sessionAds.push_back(out);
    }
}

static void MergeSessionAdState(OPN::SessionAdState &target, const OPN::SessionAdState &previous) {
    if (target.isAdsRequired && target.serverSentEmptyAds && target.sessionAds.empty() && !previous.sessionAds.empty()) {
        target.sessionAds = previous.sessionAds;
    }
}

static std::string PollSessionRegionName(const std::string &serverEndpoint) {
    if (serverEndpoint.empty()) return "(pending)";
    std::string host = serverEndpoint;
    size_t scheme = host.find("://");
    if (scheme != std::string::npos) host = host.substr(scheme + 3);
    size_t path = host.find('/');
    if (path != std::string::npos) host = host.substr(0, path);
    size_t port = host.find(':');
    if (port != std::string::npos) host = host.substr(0, port);
    size_t dot = host.find('.');
    std::string label = dot == std::string::npos ? host : host.substr(0, dot);
    return label.empty() ? "(pending)" : label;
}

static std::string TrimmedPollField(std::string value) {
    auto first = std::find_if_not(value.begin(), value.end(), [](unsigned char ch) { return std::isspace(ch); });
    auto last = std::find_if_not(value.rbegin(), value.rend(), [](unsigned char ch) { return std::isspace(ch); }).base();
    if (first >= last) return "";
    return std::string(first, last);
}

static std::string PollSessionShortId(const std::string &sessionId) {
    if (sessionId.empty()) return "(empty)";
    return sessionId.size() <= 8 ? sessionId : sessionId.substr(0, 8);
}

static std::string PollSessionStatusName(const OPN::SessionInfo &info) {
    if (info.status == 6) return "cleanup";
    if (info.status == 3) return "active";
    if (info.status == 2) return "ready";
    if (info.adState.isAdsRequired) return "ads";
    if (info.queuePosition > 0 || info.progressState == OPN::SessionProgressState::InQueue) return "queue";
    if (info.progressState == OPN::SessionProgressState::WaitingForStorage) return "storage";
    if (info.progressState == OPN::SessionProgressState::PreviousSessionCleanup) return "cleanup";
    if (info.progressState == OPN::SessionProgressState::SettingUp || info.seatSetupStep > 0) return "setup";
    if (info.status == 1 || info.progressState == OPN::SessionProgressState::Connecting) return "launching";
    return "status=" + std::to_string(info.status);
}

static std::string PollSessionGpuLabel(const std::string &gpuType) {
    if (gpuType.empty()) return "";
    size_t slash = gpuType.rfind('/');
    return TrimmedPollField(slash == std::string::npos ? gpuType : gpuType.substr(slash + 1));
}

static void LogPollSessionSummary(NSInteger httpStatus, const OPN::SessionInfo &info) {
    std::string region = PollSessionRegionName(info.serverIp);
    std::string summary = "[PollSession] " + PollSessionStatusName(info) + " " + PollSessionShortId(info.sessionId);
    if (httpStatus != 200) summary += " http=" + std::to_string((long)httpStatus);
    if (info.queuePosition > 0) summary += " queue=" + std::to_string(info.queuePosition);
    if (info.seatSetupStep > 0 && info.status != 3) summary += " step=" + std::to_string(info.seatSetupStep);
    summary += " region=" + region;
    std::string gpu = PollSessionGpuLabel(info.gpuType);
    if (!gpu.empty()) summary += " gpu=" + gpu;
    if (!info.negotiatedStreamProfile.colorQuality.empty()) summary += " color=" + info.negotiatedStreamProfile.colorQuality;
    if (info.adState.isAdsRequired) summary += " ads=required";
    OPNLogInfo(@"%s", summary.c_str());
}

static void ApplyCommonCloudMatchHeaders(NSMutableURLRequest *req, const std::string &accessToken, const std::string &deviceId, bool includeOrigin) {
    [req setValue:GetUserAgent() forHTTPHeaderField:@"User-Agent"];
    [req setValue:[NSString stringWithFormat:@"GFNJWT %s", accessToken.c_str()] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:kNvClientId forHTTPHeaderField:@"nv-client-id"];
    [req setValue:@"NATIVE" forHTTPHeaderField:@"nv-client-type"];
    [req setValue:kNvClientVersion forHTTPHeaderField:@"nv-client-version"];
    [req setValue:@"NVIDIA-CLASSIC" forHTTPHeaderField:@"nv-client-streamer"];
    [req setValue:@"MACOS" forHTTPHeaderField:@"nv-device-os"];
    [req setValue:@"DESKTOP" forHTTPHeaderField:@"nv-device-type"];
    [req setValue:@"UNKNOWN" forHTTPHeaderField:@"nv-device-make"];
    [req setValue:@"UNKNOWN" forHTTPHeaderField:@"nv-device-model"];
    [req setValue:@"CHROME" forHTTPHeaderField:@"nv-browser-type"];
    [req setValue:[NSString stringWithUTF8String:deviceId.c_str()] forHTTPHeaderField:@"x-device-id"];
    if (includeOrigin) {
        [req setValue:@"https://play.geforcenow.com" forHTTPHeaderField:@"Origin"];
        [req setValue:@"https://play.geforcenow.com/" forHTTPHeaderField:@"Referer"];
    }
}



static std::string ExtractHostFromUrl(const std::string &url) {
    if (url.empty()) return "";
    const char *prefixes[] = {"rtsps://", "rtsp://", "wss://", "https://"};
    std::string afterProto;
    for (const char *p : prefixes) {
        if (url.find(p) == 0) {
            afterProto = url.substr(strlen(p));
            break;
        }
    }
    if (afterProto.empty()) return "";

    size_t colon = afterProto.find(':');
    size_t slash = afterProto.find('/');
    size_t end = std::min(colon, slash);
    std::string host = afterProto.substr(0, end);
    if (host.empty() || host[0] == '.') return "";
    return host;
}

static bool IsReusableActiveSessionStatus(int status) {
    return status == 1 || status == 2 || status == 3 || status == 6;
}

static bool IsReadyActiveSessionStatus(int status) {
    return status == 2 || status == 3;
}

static bool IsSessionLimitExceededResponse(NSDictionary *json) {
    NSDictionary *requestStatus = DictionaryValue(json[@"requestStatus"]);
    NSNumber *statusCode = [requestStatus[@"statusCode"] isKindOfClass:[NSNumber class]] ? requestStatus[@"statusCode"] : nil;
    NSString *statusDescription = StringValue(requestStatus[@"statusDescription"]);
    return statusCode.integerValue == 11 || (statusDescription && [statusDescription rangeOfString:@"SESSION_LIMIT"].location != NSNotFound);
}

static OPN::ActiveSessionEntry ActiveSessionEntryFromDictionary(NSDictionary *session, const std::string &streamingBaseUrl) {
    OPN::ActiveSessionEntry entry;
    if (![session isKindOfClass:[NSDictionary class]]) return entry;

    NSString *sessionId = StringValue(session[@"sessionId"]);
    if (sessionId) entry.sessionId = sessionId.UTF8String;
    entry.status = IntValue(session[@"status"]);

    NSDictionary *requestData = DictionaryValue(session[@"sessionRequestData"]);
    if (requestData) entry.appId = IntValue(requestData[@"appId"]);

    NSString *gpuType = StringValue(session[@"gpuType"]);
    if (gpuType) entry.gpuType = gpuType.UTF8String;

    NSString *streamingHost = nil;
    for (NSDictionary *connection in ArrayValue(session[@"connectionInfo"])) {
        if (![connection isKindOfClass:[NSDictionary class]]) continue;
        if (IntValue(connection[@"usage"]) != 14) continue;
        NSString *ip = StringValue(connection[@"ip"]);
        if (IsUsableEndpointHost(ip)) {
            streamingHost = ip;
            break;
        }
        NSString *resourcePath = StringValue(connection[@"resourcePath"]);
        if (resourcePath.length > 0) {
            std::string host = ExtractHostFromUrl(resourcePath.UTF8String);
            if (!host.empty()) {
                streamingHost = [NSString stringWithUTF8String:host.c_str()];
                break;
            }
        }
    }

    NSDictionary *controlInfo = DictionaryValue(session[@"sessionControlInfo"]);
    NSString *controlHost = StringValue(controlInfo[@"ip"]);
    NSString *sessionHost = controlHost.length > 0 ? controlHost : streamingHost;
    if (sessionHost.length > 0) entry.serverIp = sessionHost.UTF8String;
    if (streamingHost.length > 0) entry.signalingUrl = [NSString stringWithFormat:@"wss://%@:443/nvst/", streamingHost].UTF8String;
    entry.streamingBaseUrl = streamingBaseUrl;
    return entry;
}

static std::vector<OPN::ActiveSessionEntry> ActiveSessionEntriesFromArray(NSArray *sessions, const std::string &streamingBaseUrl) {
    std::vector<OPN::ActiveSessionEntry> entries;
    for (NSDictionary *session in sessions) {
        OPN::ActiveSessionEntry entry = ActiveSessionEntryFromDictionary(session, streamingBaseUrl);
        if (!entry.sessionId.empty() && !entry.serverIp.empty() && IsReusableActiveSessionStatus(entry.status)) {
            entries.push_back(entry);
        }
    }
    return entries;
}

static bool ResolveResponseSessionId(NSString *responseSessionId, const std::string &requestedSessionId, std::string &resolvedSessionId, std::string &error) {
    std::string parsedSessionId = responseSessionId.length > 0 ? responseSessionId.UTF8String : "";
    if (requestedSessionId.empty()) {
        resolvedSessionId = parsedSessionId;
        return true;
    }
    if (!parsedSessionId.empty() && parsedSessionId != requestedSessionId) {
        error = "SESSION_ID_MISMATCH: requested " + EscapedLogString(requestedSessionId) + " but response contained " + EscapedLogString(parsedSessionId);
        return false;
    }
    resolvedSessionId = parsedSessionId.empty() ? requestedSessionId : parsedSessionId;
    return true;
}

static bool SelectSessionLimitReuseEntry(const std::vector<OPN::ActiveSessionEntry> &sessions,
                                         int requestedAppId,
                                         OPN::ActiveSessionEntry &selected) {
    for (const OPN::ActiveSessionEntry &session : sessions) {
        if (session.appId == requestedAppId && IsReadyActiveSessionStatus(session.status)) {
            selected = session;
            return true;
        }
    }
    for (const OPN::ActiveSessionEntry &session : sessions) {
        if (IsReadyActiveSessionStatus(session.status)) {
            selected = session;
            return true;
        }
    }
    for (const OPN::ActiveSessionEntry &session : sessions) {
        if (session.appId == requestedAppId && session.status == 1) {
            selected = session;
            return true;
        }
    }
    for (const OPN::ActiveSessionEntry &session : sessions) {
        if (session.status == 1) {
            selected = session;
            return true;
        }
    }
    return false;
}

static std::string RandomUUID() {
    uuid_t uuid;
    uuid_generate(uuid);
    char str[37];
    uuid_unparse_lower(uuid, str);
    return std::string(str);
}

static std::string PersistedActiveSessionIdValue() {
    NSString *value = [NSUserDefaults.standardUserDefaults stringForKey:kPersistedActiveSessionIdKey];
    return value.length > 0 ? value.UTF8String : "";
}

static void StorePersistedActiveSessionIdValue(const std::string &sessionId) {
    if (sessionId.empty()) return;
    std::string existing = PersistedActiveSessionIdValue();
    if (existing == sessionId) return;
    [NSUserDefaults.standardUserDefaults setObject:StringFromStdString(sessionId) forKey:kPersistedActiveSessionIdKey];
    [NSUserDefaults.standardUserDefaults synchronize];
    OPNLogInfo(@"[SessionManager] Persisted active sessionId=%s", sessionId.c_str());
}

static void ClearPersistedActiveSessionIdValue(const std::string &sessionId) {
    std::string existing = PersistedActiveSessionIdValue();
    if (existing.empty()) return;
    if (!sessionId.empty() && existing != sessionId) return;
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kPersistedActiveSessionIdKey];
    [NSUserDefaults.standardUserDefaults synchronize];
    OPNLogInfo(@"[SessionManager] Cleared persisted active sessionId=%s", existing.c_str());
}

namespace OPN {

SessionManager &SessionManager::Shared() {
    static SessionManager instance;
    return instance;
}

SessionManager::SessionManager()
    : m_storage(std::make_unique<SessionManagerStorage>()) {}

SessionManager::~SessionManager() = default;

void SessionManager::SetAccessToken(const std::string &token) {
    m_storage->accessToken = token;
}

void SessionManager::SetStreamingBaseUrl(const std::string &url) {
    m_storage->streamingBaseUrl = ResolveSessionBaseUrl(url, "");
}

std::string SessionManager::LoadPersistedActiveSessionId() const {
    return PersistedActiveSessionIdValue();
}

void SessionManager::ClearPersistedActiveSessionId(const std::string &sessionId) {
    ClearPersistedActiveSessionIdValue(sessionId);
}

void SessionManager::StorePersistedActiveSessionId(const std::string &sessionId) {
    StorePersistedActiveSessionIdValue(sessionId);
}

void SessionManager::MergeAndStoreAdState(SessionInfo &info) {
    if (info.sessionId.empty()) return;
    std::lock_guard<std::mutex> lock(m_storage->adStateMutex);
    auto existing = m_storage->adStatesBySessionId.find(info.sessionId);
    if (existing != m_storage->adStatesBySessionId.end()) {
        MergeSessionAdState(info.adState, existing->second);
    }
    m_storage->adStatesBySessionId[info.sessionId] = info.adState;
}

void SessionManager::CreateSession(const std::string &appId,
                                    const std::string &internalTitle,
                                    const StreamSettings &settings,
                                    SessionCreateCallback completion) {
    if (m_storage->accessToken.empty()) {
        completion(false, SessionInfo{}, "No access token");
        return;
    }

    ClearPersistedActiveSessionIdValue("");

    std::string appIdCopy = appId;
    std::string internalTitleCopy = internalTitle;
    StreamSettings settingsCopy = settings;

    std::string baseUrl = m_storage->streamingBaseUrl.empty()
        ? "https://prod.cloudmatchbeta.nvidiagrid.net"
        : m_storage->streamingBaseUrl;

    std::string clientId = RandomUUID();
    std::string deviceId = StableCloudmatchDeviceIdString();

    StreamDeviceCapabilities displayCapabilities = LoadStreamDeviceCapabilities();
    std::string requestedCodec = settingsCopy.codec;
    settingsCopy = StreamSettingsByApplyingCloudVariables(settingsCopy, LoadCachedStreamCloudVariables(), displayCapabilities);
    if (!requestedCodec.empty()) settingsCopy.codec = requestedCodec;
    bool hdrEnabled = RequestedHdrEnabled(settingsCopy, displayCapabilities);

    NSInteger timezoneOffset = -[[NSTimeZone localTimeZone] secondsFromGMT] * 1000;

    OPNLogInfo(@"[SessionManager] CreateSession called with appId=%s codec=%s color=%s bitrate=%dMbps l4s=%s",
          appIdCopy.c_str(),
          settingsCopy.codec.c_str(),
          settingsCopy.colorQuality.c_str(),
          settingsCopy.maxBitrateMbps,
          settingsCopy.enableL4S ? "on" : "off");

    NSString *appIdStr = StringFromStdString(appIdCopy);
    OPNLogInfo(@"[SessionManager] appIdStr=%@", appIdStr);

    NSString *internalTitleStr = StringFromStdString(internalTitleCopy);
    NSString *deviceIdStr = StringFromStdString(deviceId);
    NSString *subSessionIdStr = StringFromStdString(RandomUUID());
    NSString *selectedStoreStr = settingsCopy.selectedStore.empty() ? @"unknown" : StringFromStdString(settingsCopy.selectedStore, @"unknown");


    NSDictionary *sessionRequestData = @{
        @"appId": appIdStr,
        @"internalTitle": internalTitleStr,
        @"availableSupportedControllers": AvailableSupportedControllersValue(settingsCopy),
        @"networkTestSessionId": NetworkTestSessionIdValue(settingsCopy),
        @"parentSessionId": [NSNull null],
        @"clientIdentification": @"GFN-PC",
        @"deviceHashId": deviceIdStr,
        @"clientVersion": @"30.0",
        @"sdkVersion": @"1.0",
        @"streamerVersion": @1,
        @"clientPlatformName": @"windows",
        @"clientRequestMonitorSettings": @[MonitorSettings(settingsCopy, displayCapabilities, hdrEnabled)],
        @"useOps": @YES,
        @"audioMode": @2,
        @"metaData": @[
            @{@"key": @"SubSessionId", @"value": subSessionIdStr},
            @{@"key": @"wssignaling", @"value": @"1"},
            @{@"key": @"GSStreamerType", @"value": @"WebRTC"},
            @{@"key": @"networkType", @"value": NetworkTypeValue(settingsCopy)},
            @{@"key": @"networkLatencyMs", @"value": NetworkLatencyValue(settingsCopy)},
            @{@"key": @"ClientImeSupport", @"value": @"0"},
            @{@"key": @"clientPhysicalResolution", @"value": [NSString stringWithFormat:@"{\"horizontalPixels\":%d,\"verticalPixels\":%d}", std::max(0, displayCapabilities.maxDisplayWidth), std::max(0, displayCapabilities.maxDisplayHeight)]},
            @{@"key": @"surroundAudioInfo", @"value": @"2"},
            @{@"key": @"store", @"value": selectedStoreStr},
        ],
        @"sdrHdrMode": hdrEnabled ? @1 : @0,
        @"clientDisplayHdrCapabilities": ClientDisplayHdrCapabilities(displayCapabilities),
        @"surroundAudioInfo": @0,
        @"remoteControllersBitmap": @((unsigned long long)settingsCopy.remoteControllersBitmap),
        @"clientTimezoneOffset": @(timezoneOffset),
        @"enhancedStreamMode": @1,
        @"appLaunchMode": @1,
        @"secureRTSPSupported": @NO,
        @"partnerCustomData": @"",
        @"accountLinked": @(settingsCopy.accountLinked),
        @"enablePersistingInGameSettings": @YES,
        @"userAge": @26,
        @"requestedStreamingFeatures": RequestedStreamingFeatures(settingsCopy, hdrEnabled),
    };


    NSDictionary *body = @{
        @"sessionRequestData": sessionRequestData,
    };

    NSString *layout = StringFromStdString(settingsCopy.keyboardLayout, @"us");
    NSString *lang = StringFromStdString(settingsCopy.gameLanguage, [OPNLocale currentGFNLocale]);
    NSString *baseUrlString = StringFromStdString(baseUrl);
    NSString *urlStr = [NSString stringWithFormat:@"%@/v2/session?keyboardLayout=%@&languageCode=%@",
                        baseUrlString, layout, lang];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        completion(false, SessionInfo{}, "Invalid session create URL");
        return;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:GetUserAgent() forHTTPHeaderField:@"User-Agent"];
    [req setValue:[NSString stringWithFormat:@"GFNJWT %s", m_storage->accessToken.c_str()] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:kNvClientId forHTTPHeaderField:@"nv-client-id"];
    [req setValue:@"NATIVE" forHTTPHeaderField:@"nv-client-type"];
    [req setValue:kNvClientVersion forHTTPHeaderField:@"nv-client-version"];
    [req setValue:@"NVIDIA-CLASSIC" forHTTPHeaderField:@"nv-client-streamer"];
    [req setValue:@"MACOS" forHTTPHeaderField:@"nv-device-os"];
    [req setValue:@"DESKTOP" forHTTPHeaderField:@"nv-device-type"];
    [req setValue:@"UNKNOWN" forHTTPHeaderField:@"nv-device-make"];
    [req setValue:@"UNKNOWN" forHTTPHeaderField:@"nv-device-model"];
    [req setValue:@"CHROME" forHTTPHeaderField:@"nv-browser-type"];
    [req setValue:deviceIdStr forHTTPHeaderField:@"x-device-id"];
    [req setValue:@"https://play.geforcenow.com" forHTTPHeaderField:@"Origin"];

    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    NSString *bodyStr = [[NSString alloc] initWithData:bodyData encoding:NSUTF8StringEncoding];
    if (VerboseSessionHttpLoggingEnabled()) {
        OPNLogInfo(@"[SessionManager] HTTP Body: %@", bodyStr);
    }
    [OPNProtocolDebug logJSONObjectWithLabel:@"session create request" object:body];
    req.HTTPBody = bodyData;

    SessionCreateCallback cb = completion;
    NSString *baseUrlStr = baseUrlString;
    OPNSentryTransaction *trace = [OPNSentry traceHTTPRequest:req name:@"Cloudmatch create session"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        void (^finishTrace)(BOOL) = ^(BOOL success) {
            [trace setStatus:success];
            [trace finish];
        };
        if (error || !data) {
            finishTrace(NO);
            cb(false, SessionInfo{}, [[error localizedDescription] UTF8String]);
            return;
        }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        [OPNProtocolDebug logJSONDataWithLabel:@"session create response" data:data];
        if (http.statusCode != 200) {
            NSString *responseBody = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
            NSString *originalErrorString = [NSString stringWithFormat:@"HTTP %ld: %@", (long)http.statusCode, responseBody];
            std::string originalError = originalErrorString.UTF8String ? originalErrorString.UTF8String : "";
            NSDictionary *errorJson = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (IsSessionLimitExceededResponse(errorJson)) {
                std::vector<ActiveSessionEntry> sessions = ActiveSessionEntriesFromArray(ArrayValue(errorJson[@"otherUserSessions"]), baseUrl);
                ActiveSessionEntry selectedSession;
                if (SelectSessionLimitReuseEntry(sessions, appIdCopy.empty() ? 0 : atoi(appIdCopy.c_str()), selectedSession)) {
                    OPNLogInfo(@"[SessionManager] Reusing embedded active session after session limit sessionId=%s appId=%d status=%d server=%s",
                                 selectedSession.sessionId.c_str(),
                                 selectedSession.appId,
                                 selectedSession.status,
                                 selectedSession.serverIp.c_str());
                    finishTrace(YES);
                    SessionCreateCallback reuseCompletion = [cb](bool reuseSuccess, const SessionInfo &reuseInfo, const std::string &reuseError) {
                        cb(reuseSuccess, reuseInfo, reuseError);
                    };
                    if (IsReadyActiveSessionStatus(selectedSession.status)) {
                        std::string selectedAppId = selectedSession.appId > 0 ? std::to_string(selectedSession.appId) : appIdCopy;
                        this->ClaimSession(selectedSession.sessionId, selectedSession.serverIp, selectedAppId, settingsCopy, true, reuseCompletion);
                    } else {
                        this->pollClaimSession(selectedSession.sessionId, selectedSession.serverIp, deviceId, clientId, NegotiatedStreamProfile{}, reuseCompletion);
                    }
                    return;
                }
            }
            finishTrace(NO);
            cb(false, SessionInfo{}, originalError);
            return;
        }

        NSString *createBody = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (VerboseSessionHttpLoggingEnabled()) {
            OPNLogInfo(@"[SessionManager] CreateSession response: %@", createBody);
        }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (!json) {
            finishTrace(NO);
            cb(false, SessionInfo{}, "Failed to parse session response");
            return;
        }

        NSDictionary *reqStatus = DictionaryValue(json[@"requestStatus"]);
        NSNumber *statusCode = reqStatus[@"statusCode"];
        if (!statusCode || statusCode.integerValue != 1) {
            NSString *desc = reqStatus[@"statusDescription"] ?: @"unknown";
            finishTrace(NO);
            cb(false, SessionInfo{}, [[NSString stringWithFormat:@"API error %@: %@", statusCode, desc] UTF8String]);
            return;
        }

        NSDictionary *session = DictionaryValue(json[@"session"]);
        if (!session) {
            finishTrace(NO);
            cb(false, SessionInfo{}, "No session in response");
            return;
        }

        SessionInfo info;
        NSString *sid = [session[@"sessionId"] isKindOfClass:[NSString class]] ? session[@"sessionId"] : nil;
        info.sessionId = [sid UTF8String] ?: "";
        StorePersistedActiveSessionIdValue(info.sessionId);
        info.status = [session[@"status"] intValue];
        info.zone = [baseUrlStr UTF8String];
        info.streamingBaseUrl = [baseUrlStr UTF8String];
        NSString *gpu = [session[@"gpuType"] isKindOfClass:[NSString class]] ? session[@"gpuType"] : nil;
        info.gpuType = [gpu UTF8String] ?: "";

        ParseQueueProgress(session, info);

        NSArray *connections = ArrayValue(session[@"connectionInfo"]);
        for (NSDictionary *conn in connections) {
            if (![conn isKindOfClass:[NSDictionary class]]) continue;
            int usage = [conn[@"usage"] intValue];
            NSString *ip = [conn[@"ip"] isKindOfClass:[NSString class]] ? conn[@"ip"] : nil;
            int port = [conn[@"port"] intValue];
            NSString *resourcePath = [conn[@"resourcePath"] isKindOfClass:[NSString class]] ? conn[@"resourcePath"] : nil;

            if (usage == 14) {
                NSString *serverIp = nil;
                if (IsUsableEndpointHost(ip)) {
                    serverIp = ip;
                }

                if (!serverIp && resourcePath.length > 0) {
                    std::string host = ExtractHostFromUrl([resourcePath UTF8String]);
                    if (!host.empty()) {
                        serverIp = [NSString stringWithUTF8String:host.c_str()];
                    }
                }
                if (serverIp) {
                    info.serverIp = [serverIp UTF8String];
                    info.signalingServer = [NSString stringWithFormat:@"%@:%d", serverIp, port > 0 ? port : 443].UTF8String;
                    if (resourcePath.length > 0) {
                        if ([resourcePath hasPrefix:@"rtsps://"]) {
                            NSString *host = [[resourcePath substringFromIndex:8] componentsSeparatedByString:@":"].firstObject;
                            info.signalingUrl = [NSString stringWithFormat:@"wss://%@/nvst/", host].UTF8String;
                        } else if ([resourcePath hasPrefix:@"wss://"]) {
                            info.signalingUrl = [resourcePath UTF8String];
                        } else {
                            info.signalingUrl = [NSString stringWithFormat:@"wss://%s:443%@", info.serverIp.c_str(), resourcePath.length > 0 ? resourcePath : @"/nvst/"].UTF8String;
                        }
                    } else {
                        info.signalingUrl = [NSString stringWithFormat:@"wss://%s:443/nvst/", info.serverIp.c_str()].UTF8String;
                    }
                    if (port > 0) {
                        info.mediaConnectionInfo.ip = [serverIp UTF8String];
                        info.mediaConnectionInfo.port = port;
                    }
                }
            }

            if (usage == 2) {
                NSString *mediaIp = nil;
                if (IsUsableEndpointHost(ip)) {
                    mediaIp = ip;
                } else if (resourcePath.length > 0) {
                    std::string host = ExtractHostFromUrl([resourcePath UTF8String]);
                    if (!host.empty()) {
                        mediaIp = [NSString stringWithUTF8String:host.c_str()];
                    }
                }
                if (mediaIp && port > 0) {
                    info.mediaConnectionInfo.ip = [mediaIp UTF8String];
                    info.mediaConnectionInfo.port = port;
                }
            }
        }

        NSArray *iceServers = ArrayValue(session[@"iceServers"]);
        for (NSDictionary *ice in iceServers) {
            if (![ice isKindOfClass:[NSDictionary class]]) continue;
            IceServer is;
            NSArray *urls = ArrayValue(ice[@"urls"]);
            for (NSString *u in urls) {
                if ([u isKindOfClass:[NSString class]])
                    is.urls.push_back([u UTF8String]);
            }
            NSString *un = [ice[@"username"] isKindOfClass:[NSString class]] ? ice[@"username"] : nil;
            if (un) is.username = [un UTF8String];
            NSString *cred = [ice[@"credential"] isKindOfClass:[NSString class]] ? ice[@"credential"] : nil;
            if (cred) is.credential = [cred UTF8String];
            info.iceServers.push_back(is);
        }

        ParseStreamProfile(session, info.negotiatedStreamProfile);
        ParseSessionAds(session, info.adState);
        ParseRemainingPlaytime(session, info);
        MergeAndStoreAdState(info);

        NSDictionary *ctrlInfo = DictionaryValue(session[@"sessionControlInfo"]);
        NSString *ctrlIp = [ctrlInfo[@"ip"] isKindOfClass:[NSString class]] ? ctrlInfo[@"ip"] : nil;
        if (ctrlIp.length > 0 && info.serverIp.empty()) {
            info.serverIp = [ctrlIp UTF8String];
            OPNLogInfo(@"[SessionManager] Using sessionControlInfo zone: %s", info.serverIp.c_str());
        }

        info.clientId = clientId;
        info.deviceId = deviceId;

        finishTrace(YES);
        cb(true, info, "");
    }] resume];
}

void SessionManager::PollSession(const std::string &sessionId,
                                   const std::string &serverIp,
                                   SessionPollCallback completion) {
    const std::string requestedSessionId = sessionId;
    const std::string requestedServerIp = serverIp;
    if (m_storage->accessToken.empty()) {
        completion(false, SessionInfo{}, "No access token");
        return;
    }
    if (!IsValidSessionIdString(requestedSessionId)) {
        completion(false, SessionInfo{}, "Invalid session id for poll: " + EscapedLogString(requestedSessionId));
        return;
    }


    std::string base = ResolveSessionBaseUrl(m_storage->streamingBaseUrl, requestedServerIp);
    NSString *urlStr = [NSString stringWithFormat:@"%@/v2/session/%s",
                        [NSString stringWithUTF8String:base.c_str()],
                        requestedSessionId.c_str()];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    [req setValue:GetUserAgent() forHTTPHeaderField:@"User-Agent"];
    [req setValue:[NSString stringWithFormat:@"GFNJWT %s", m_storage->accessToken.c_str()] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:kNvClientId forHTTPHeaderField:@"nv-client-id"];
    [req setValue:@"NATIVE" forHTTPHeaderField:@"nv-client-type"];
    [req setValue:kNvClientVersion forHTTPHeaderField:@"nv-client-version"];
    [req setValue:@"NVIDIA-CLASSIC" forHTTPHeaderField:@"nv-client-streamer"];
    [req setValue:@"MACOS" forHTTPHeaderField:@"nv-device-os"];
    [req setValue:@"DESKTOP" forHTTPHeaderField:@"nv-device-type"];
    [req setValue:@"UNKNOWN" forHTTPHeaderField:@"nv-device-make"];
    [req setValue:@"UNKNOWN" forHTTPHeaderField:@"nv-device-model"];
    [req setValue:@"CHROME" forHTTPHeaderField:@"nv-browser-type"];
    [req setValue:[OPNDeviceIdentity stableCloudmatchDeviceId] forHTTPHeaderField:@"x-device-id"];

    SessionPollCallback cb = completion;
    OPNSentryTransaction *trace = [OPNSentry traceHTTPRequest:req name:@"Cloudmatch poll session"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        void (^finishTrace)(BOOL) = ^(BOOL success) {
            [trace setStatus:success];
            [trace finish];
        };
        if (error || !data) {
            finishTrace(NO);
            cb(false, SessionInfo{}, [[error localizedDescription] UTF8String]);
            return;
        }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSString *rawBody = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (VerboseSessionHttpLoggingEnabled()) {
            OPNLogInfo(@"[PollSession] Raw response: HTTP %ld body=%@", (long)http.statusCode, rawBody);
        }
        if (http.statusCode != 200) {
            finishTrace(NO);
            cb(false, SessionInfo{}, [[NSString stringWithFormat:@"HTTP %ld: %@", (long)http.statusCode, rawBody] UTF8String]);
            return;
        }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (!json) {
            finishTrace(NO);
            cb(false, SessionInfo{}, [[NSString stringWithFormat:@"Failed to parse poll response: %@", rawBody] UTF8String]);
            return;
        }
        NSDictionary *session = DictionaryValue(json[@"session"]);
        if (!session) {
            finishTrace(NO);
            cb(false, SessionInfo{}, "No session in poll response");
            return;
        }

        SessionInfo info;
        NSString *sid = [session[@"sessionId"] isKindOfClass:[NSString class]] ? session[@"sessionId"] : nil;
        std::string sessionIdError;
        if (!ResolveResponseSessionId(sid, requestedSessionId, info.sessionId, sessionIdError)) {
            finishTrace(NO);
            cb(false, SessionInfo{}, sessionIdError);
            return;
        }
        StorePersistedActiveSessionIdValue(info.sessionId);
        info.status = [session[@"status"] intValue];
        info.zone = [NSString stringWithUTF8String:base.c_str()].UTF8String;
        info.streamingBaseUrl = [NSString stringWithUTF8String:base.c_str()].UTF8String;
        NSString *gpu = [session[@"gpuType"] isKindOfClass:[NSString class]] ? session[@"gpuType"] : nil;
        info.gpuType = [gpu UTF8String] ?: "";

        ParseQueueProgress(session, info);





        NSArray *connections = ArrayValue(session[@"connectionInfo"]);
        for (NSDictionary *conn in connections) {
            if (![conn isKindOfClass:[NSDictionary class]]) continue;
            int usage = [conn[@"usage"] intValue];
            NSString *ip = [conn[@"ip"] isKindOfClass:[NSString class]] ? conn[@"ip"] : nil;
            int port = [conn[@"port"] intValue];
            NSString *resourcePath = [conn[@"resourcePath"] isKindOfClass:[NSString class]] ? conn[@"resourcePath"] : nil;

            if (usage == 14) {

                NSString *serverIp = nil;
                if (IsUsableEndpointHost(ip)) {
                    serverIp = ip;
                }

                if (!serverIp && resourcePath.length > 0) {
                    std::string host = ExtractHostFromUrl([resourcePath UTF8String]);
                    if (!host.empty()) {
                        serverIp = [NSString stringWithUTF8String:host.c_str()];
                    }
                }
                if (serverIp) {
                    info.serverIp = [serverIp UTF8String];
                    info.signalingServer = [NSString stringWithFormat:@"%@:%d", serverIp, port > 0 ? port : 443].UTF8String;
                    if (resourcePath.length > 0) {
                        if ([resourcePath hasPrefix:@"rtsps://"]) {
                            NSString *host = [[resourcePath substringFromIndex:8] componentsSeparatedByString:@":"].firstObject;
                            info.signalingUrl = [NSString stringWithFormat:@"wss://%@/nvst/", host].UTF8String;
                        } else if ([resourcePath hasPrefix:@"wss://"]) {
                            info.signalingUrl = [resourcePath UTF8String];
                        } else {
                            info.signalingUrl = [NSString stringWithFormat:@"wss://%s:443%@", info.serverIp.c_str(), resourcePath.length > 0 ? resourcePath : @"/nvst/"].UTF8String;
                        }
                    } else {
                        info.signalingUrl = [NSString stringWithFormat:@"wss://%s:443/nvst/", info.serverIp.c_str()].UTF8String;
                    }
                    if (port > 0) {
                        info.mediaConnectionInfo.ip = [serverIp UTF8String];
                        info.mediaConnectionInfo.port = port;
                    }
                }
            }


            if (usage == 2) {
                NSString *mediaIp = nil;
                if (IsUsableEndpointHost(ip)) {
                    mediaIp = ip;
                } else if (resourcePath.length > 0) {
                    std::string host = ExtractHostFromUrl([resourcePath UTF8String]);
                    if (!host.empty()) {
                        mediaIp = [NSString stringWithUTF8String:host.c_str()];
                    }
                }
                if (mediaIp && port > 0) {
                    info.mediaConnectionInfo.ip = [mediaIp UTF8String];
                    info.mediaConnectionInfo.port = port;
                }
            }
        }

        if (info.serverIp.empty()) {
            NSDictionary *ctrlInfo = DictionaryValue(session[@"sessionControlInfo"]);
            NSString *ctrlIp = [ctrlInfo[@"ip"] isKindOfClass:[NSString class]] ? ctrlInfo[@"ip"] : nil;
            if (ctrlIp.length > 0) {

                info.serverIp = [ctrlIp UTF8String];
            }
        }

        NSArray *iceServers = ArrayValue(session[@"iceServers"]);
        for (NSDictionary *ice in iceServers) {
            if (![ice isKindOfClass:[NSDictionary class]]) continue;
            IceServer is;
            NSArray *urls = ArrayValue(ice[@"urls"]);
            for (NSString *u in urls) {
                if ([u isKindOfClass:[NSString class]])
                    is.urls.push_back([u UTF8String]);
            }
            NSString *un = [ice[@"username"] isKindOfClass:[NSString class]] ? ice[@"username"] : nil;
            if (un) is.username = [un UTF8String];
            NSString *cred = [ice[@"credential"] isKindOfClass:[NSString class]] ? ice[@"credential"] : nil;
            if (cred) is.credential = [cred UTF8String];
            info.iceServers.push_back(is);
        }

        ParseStreamProfile(session, info.negotiatedStreamProfile);
        ParseSessionAds(session, info.adState);
        ParseRemainingPlaytime(session, info);
        MergeAndStoreAdState(info);

        LogPollSessionSummary(http.statusCode, info);

        finishTrace(YES);
        cb(true, info, "");
    }] resume];
}

void SessionManager::StopSession(const std::string &sessionId,
                                 const std::string &serverIp,
                                 std::function<void(bool, const std::string &)> completion) {
    if (m_storage->accessToken.empty()) {
        completion(false, "No access token");
        return;
    }

    ClearPersistedActiveSessionIdValue(sessionId);

    std::string base = ResolveSessionBaseUrl(m_storage->streamingBaseUrl, serverIp);
    NSString *urlStr = [NSString stringWithFormat:@"%@/v2/session/%s",
                        StringFromStdString(base), sessionId.c_str()];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    req.HTTPMethod = @"DELETE";
    ApplyCommonCloudMatchHeaders(req, m_storage->accessToken, StableCloudmatchDeviceIdString(), true);
    OPNSentryTransaction *trace = [OPNSentry traceHTTPRequest:req name:@"Cloudmatch stop session"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        void (^finishTrace)(BOOL) = ^(BOOL success) {
            [trace setStatus:success];
            [trace finish];
        };
        if (error || !data) {
            finishTrace(NO);
            completion(false, [[error localizedDescription] UTF8String]);
            return;
        }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (http.statusCode != 200) {
            NSString *bodyStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            finishTrace(NO);
            completion(false, [[NSString stringWithFormat:@"HTTP %ld: %@", (long)http.statusCode, bodyStr] UTF8String]);
            return;
        }
        finishTrace(YES);
        completion(true, "");
    }] resume];
}

void SessionManager::ReportSessionAd(const SessionInfo &session,
                                     const std::string &adId,
                                     const std::string &action,
                                     int watchedTimeInMs,
                                     int pausedTimeInMs,
                                     const std::string &cancelReason,
                                     std::function<void(bool, const SessionInfo &, const std::string &)> completion) {
    if (m_storage->accessToken.empty()) {
        completion(false, SessionInfo{}, "No access token");
        return;
    }
    int actionCode = AdActionCode(action);
    if (session.sessionId.empty() || adId.empty() || actionCode == 0) {
        completion(false, SessionInfo{}, "Invalid ad update request");
        return;
    }

    std::string base = ResolveSessionBaseUrl(session.streamingBaseUrl.empty() ? m_storage->streamingBaseUrl : session.streamingBaseUrl, session.serverIp);
    NSString *urlStr = [NSString stringWithFormat:@"%@/v2/session/%s",
                        [NSString stringWithUTF8String:base.c_str()],
                        session.sessionId.c_str()];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    req.HTTPMethod = @"PUT";
    ApplyCommonCloudMatchHeaders(req, m_storage->accessToken, session.deviceId.empty() ? StableCloudmatchDeviceIdString() : session.deviceId, true);

    NSMutableDictionary *adUpdate = [@{
        @"adId": [NSString stringWithUTF8String:adId.c_str()],
        @"adAction": @(actionCode),
        @"clientTimestamp": @((NSInteger)[[NSDate date] timeIntervalSince1970]),
    } mutableCopy];
    if (watchedTimeInMs >= 0) adUpdate[@"watchedTimeInMs"] = @(watchedTimeInMs);
    if (pausedTimeInMs >= 0) adUpdate[@"pausedTimeInMs"] = @(pausedTimeInMs);
    if (!cancelReason.empty()) adUpdate[@"cancelReason"] = [NSString stringWithUTF8String:cancelReason.c_str()];

    NSDictionary *body = @{
        @"action": @6,
        @"adUpdates": @[adUpdate],
    };
    NSError *jsonError = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonError];
    if (!bodyData || jsonError) {
        completion(false, SessionInfo{}, "Failed to encode ad update request");
        return;
    }
    req.HTTPBody = bodyData;

    auto cb = completion;
    SessionInfo sessionCopy = session;
    OPNSentryTransaction *trace = [OPNSentry traceHTTPRequest:req name:@"Cloudmatch report session ad"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        void (^finishTrace)(BOOL) = ^(BOOL success) {
            [trace setStatus:success];
            [trace finish];
        };
        if (error || !data) {
            finishTrace(NO);
            cb(false, SessionInfo{}, error ? [[error localizedDescription] UTF8String] : "No ad update response");
            return;
        }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSString *bodyStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (http.statusCode != 200) {
            finishTrace(NO);
            cb(false, SessionInfo{}, [[NSString stringWithFormat:@"HTTP %ld: %@", (long)http.statusCode, bodyStr] UTF8String]);
            return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSDictionary *requestStatus = DictionaryValue(json[@"requestStatus"]);
        NSNumber *statusCode = [requestStatus[@"statusCode"] isKindOfClass:[NSNumber class]] ? requestStatus[@"statusCode"] : nil;
        if (!json || !statusCode || statusCode.integerValue != 1) {
            finishTrace(NO);
            cb(false, SessionInfo{}, [[NSString stringWithFormat:@"Ad update API error: %@", bodyStr] UTF8String]);
            return;
        }

        SessionInfo updated = sessionCopy;
        NSDictionary *sessionJson = DictionaryValue(json[@"session"]);
        if (sessionJson) {
            updated.status = [sessionJson[@"status"] intValue];
            ParseQueueProgress(sessionJson, updated);
            ParseStreamProfile(sessionJson, updated.negotiatedStreamProfile);
            ParseSessionAds(sessionJson, updated.adState);
            this->MergeAndStoreAdState(updated);
        }
        finishTrace(YES);
        cb(true, updated, "");
    }] resume];
}

void SessionManager::GetActiveSessions(std::function<void(bool, const std::vector<ActiveSessionEntry> &, const std::string &)> completion) {
    if (m_storage->accessToken.empty()) {
        completion(false, {}, "No access token");
        return;
    }

    std::string base = m_storage->streamingBaseUrl.empty()
        ? "https://prod.cloudmatchbeta.nvidiagrid.net"
        : m_storage->streamingBaseUrl;

    NSString *urlStr = [NSString stringWithFormat:@"%@/v2/session", [NSString stringWithUTF8String:base.c_str()]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    [req setValue:GetUserAgent() forHTTPHeaderField:@"User-Agent"];
    [req setValue:[NSString stringWithFormat:@"GFNJWT %s", m_storage->accessToken.c_str()] forHTTPHeaderField:@"Authorization"];
    [req setValue:kNvClientId forHTTPHeaderField:@"nv-client-id"];
    [req setValue:@"NATIVE" forHTTPHeaderField:@"nv-client-type"];
    [req setValue:kNvClientVersion forHTTPHeaderField:@"nv-client-version"];
    [req setValue:@"NVIDIA-CLASSIC" forHTTPHeaderField:@"nv-client-streamer"];
    [req setValue:@"MACOS" forHTTPHeaderField:@"nv-device-os"];
    [req setValue:@"DESKTOP" forHTTPHeaderField:@"nv-device-type"];
    [req setValue:@"UNKNOWN" forHTTPHeaderField:@"nv-device-make"];
    [req setValue:@"UNKNOWN" forHTTPHeaderField:@"nv-device-model"];
    [req setValue:@"CHROME" forHTTPHeaderField:@"nv-browser-type"];
    [req setValue:[OPNDeviceIdentity stableCloudmatchDeviceId] forHTTPHeaderField:@"x-device-id"];

    auto cb = completion;
    OPNSentryTransaction *trace = [OPNSentry traceHTTPRequest:req name:@"Cloudmatch active sessions"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        void (^finishTrace)(BOOL) = ^(BOOL success) {
            [trace setStatus:success];
            [trace finish];
        };
        if (error || !data) {
            finishTrace(NO);
            cb(false, {}, [[error localizedDescription] UTF8String]);
            return;
        }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (http.statusCode != 200) {
            finishTrace(NO);
            cb(false, {}, [[NSString stringWithFormat:@"HTTP %ld", (long)http.statusCode] UTF8String]);
            return;
        }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (!json) {
            finishTrace(NO);
            cb(false, {}, "Failed to parse sessions response");
            return;
        }

        NSDictionary *reqStatus = DictionaryValue(json[@"requestStatus"]);
        NSNumber *sc = reqStatus[@"statusCode"];
        if (!sc || sc.integerValue != 1) {
            finishTrace(NO);
            cb(false, {}, "API error from sessions endpoint");
            return;
        }

        NSArray *sessions = ArrayValue(json[@"sessions"]);
        if (![sessions isKindOfClass:[NSArray class]]) {
            finishTrace(YES);
            cb(true, {}, "");
            return;
        }

        std::vector<ActiveSessionEntry> result = ActiveSessionEntriesFromArray(sessions, base);

        finishTrace(YES);
        cb(true, result, "");
    }] resume];
}

void SessionManager::pollClaimSession(std::string sessionId,
                                        std::string serverIp,
                                        std::string deviceId,
                                        std::string clientId,
                                        NegotiatedStreamProfile initialStreamProfile,
                                        SessionCreateCallback completion) {
    __block int retryCount = 0;
    const int maxRetries = 60;


    NSString *baseUrl = [NSString stringWithUTF8String:ResolveSessionBaseUrl(m_storage->streamingBaseUrl, serverIp).c_str()];

    __block void (^pollBlock)(void);

    void (^poller)(NSData *, NSError *) = ^(NSData *data, NSError *error) {
        if (error || !data) {
            uint64_t delayNs = retryCount <= 12 ? 300 * NSEC_PER_MSEC : (retryCount <= 20 ? 500 * NSEC_PER_MSEC : 1 * NSEC_PER_SEC);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)delayNs), dispatch_get_main_queue(), pollBlock);
            return;
        }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSDictionary *session = DictionaryValue(json[@"session"]);
        if (!session) {
            uint64_t delayNs = retryCount <= 12 ? 300 * NSEC_PER_MSEC : (retryCount <= 20 ? 500 * NSEC_PER_MSEC : 1 * NSEC_PER_SEC);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)delayNs), dispatch_get_main_queue(), pollBlock);
            return;
        }

        int status = [session[@"status"] intValue];

        if (status == 2 || status == 3) {
            SessionInfo info;
            NSString *sid = [session[@"sessionId"] isKindOfClass:[NSString class]] ? session[@"sessionId"] : nil;
            std::string sessionIdError;
            if (!ResolveResponseSessionId(sid, sessionId, info.sessionId, sessionIdError)) {
                completion(false, SessionInfo{}, sessionIdError);
                return;
            }
            StorePersistedActiveSessionIdValue(info.sessionId);
            info.status = status;
            info.zone = [baseUrl UTF8String];
            info.streamingBaseUrl = [baseUrl UTF8String];
            NSString *gpu = [session[@"gpuType"] isKindOfClass:[NSString class]] ? session[@"gpuType"] : nil;
            info.gpuType = [gpu UTF8String] ?: "";


            NSArray *connections = ArrayValue(session[@"connectionInfo"]);
            for (NSDictionary *conn in connections) {
                if (![conn isKindOfClass:[NSDictionary class]]) continue;
                int usage = [conn[@"usage"] intValue];
                NSString *ip = [conn[@"ip"] isKindOfClass:[NSString class]] ? conn[@"ip"] : nil;
                int port = [conn[@"port"] intValue];
                NSString *resourcePath = [conn[@"resourcePath"] isKindOfClass:[NSString class]] ? conn[@"resourcePath"] : nil;

                if (usage == 14) {
                    NSString *serverIp = nil;
                    if (IsUsableEndpointHost(ip)) {
                        serverIp = ip;
                    }
                    if (!serverIp && resourcePath.length > 0) {
                        std::string host = ExtractHostFromUrl([resourcePath UTF8String]);
                        if (!host.empty()) {
                            serverIp = [NSString stringWithUTF8String:host.c_str()];
                        }
                    }
                    if (serverIp) {
                        info.serverIp = [serverIp UTF8String];
                        info.signalingServer = [NSString stringWithFormat:@"%@:%d", serverIp, port > 0 ? port : 443].UTF8String;
                        if (resourcePath.length > 0) {
                            if ([resourcePath hasPrefix:@"rtsps://"]) {
                                NSString *host = [[resourcePath substringFromIndex:8] componentsSeparatedByString:@":"].firstObject;
                                info.signalingUrl = [NSString stringWithFormat:@"wss://%@/nvst/", host].UTF8String;
                            } else if ([resourcePath hasPrefix:@"wss://"]) {
                                info.signalingUrl = [resourcePath UTF8String];
                            } else {
                                info.signalingUrl = [NSString stringWithFormat:@"wss://%s:443%@", info.serverIp.c_str(), resourcePath.length > 0 ? resourcePath : @"/nvst/"].UTF8String;
                            }
                        } else {
                            info.signalingUrl = [NSString stringWithFormat:@"wss://%s:443/nvst/", info.serverIp.c_str()].UTF8String;
                        }
                        if (port > 0) {
                            info.mediaConnectionInfo.ip = [serverIp UTF8String];
                            info.mediaConnectionInfo.port = port;
                        }
                    }
                }
                if (usage == 2) {
                    NSString *mediaIp = nil;
                    if (IsUsableEndpointHost(ip)) {
                        mediaIp = ip;
                    } else if (resourcePath.length > 0) {
                        std::string host = ExtractHostFromUrl([resourcePath UTF8String]);
                        if (!host.empty()) {
                            mediaIp = [NSString stringWithUTF8String:host.c_str()];
                        }
                    }
                    if (mediaIp && port > 0) {
                        info.mediaConnectionInfo.ip = [mediaIp UTF8String];
                        info.mediaConnectionInfo.port = port;
                    }
                }
            }

            NSArray *iceServers = ArrayValue(session[@"iceServers"]);
            for (NSDictionary *ice in iceServers) {
                if (![ice isKindOfClass:[NSDictionary class]]) continue;
                IceServer is;
                NSArray *urls = ArrayValue(ice[@"urls"]);
                for (NSString *u in urls) {
                    if ([u isKindOfClass:[NSString class]])
                        is.urls.push_back([u UTF8String]);
                }
                NSString *un = [ice[@"username"] isKindOfClass:[NSString class]] ? ice[@"username"] : nil;
                if (un) is.username = [un UTF8String];
                NSString *cred = [ice[@"credential"] isKindOfClass:[NSString class]] ? ice[@"credential"] : nil;
                if (cred) is.credential = [cred UTF8String];
                info.iceServers.push_back(is);
            }

            info.clientId = clientId;
            info.deviceId = deviceId;
            info.negotiatedStreamProfile = initialStreamProfile;
            ParseStreamProfile(session, info.negotiatedStreamProfile);
            ParseRemainingPlaytime(session, info);

            completion(true, info, "");
        } else if (status == 1 || status == 6) {

            uint64_t delayNs = retryCount <= 12 ? 300 * NSEC_PER_MSEC : (retryCount <= 20 ? 500 * NSEC_PER_MSEC : 1 * NSEC_PER_SEC);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)delayNs), dispatch_get_main_queue(), pollBlock);
        } else {

            completion(false, SessionInfo{}, "Session in terminal error state");
        }
    };

    pollBlock = ^{
        if (retryCount >= maxRetries) {
            completion(false, SessionInfo{}, "Timeout polling for session ready");
            return;
        }
        retryCount++;

        NSString *urlStr = [NSString stringWithFormat:@"%@/v2/session/%s", baseUrl, sessionId.c_str()];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
        [req setValue:GetUserAgent() forHTTPHeaderField:@"User-Agent"];
        [req setValue:[NSString stringWithFormat:@"GFNJWT %s", m_storage->accessToken.c_str()] forHTTPHeaderField:@"Authorization"];
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [req setValue:kNvClientId forHTTPHeaderField:@"nv-client-id"];
        [req setValue:@"NATIVE" forHTTPHeaderField:@"nv-client-type"];
        [req setValue:kNvClientVersion forHTTPHeaderField:@"nv-client-version"];
        [req setValue:@"NVIDIA-CLASSIC" forHTTPHeaderField:@"nv-client-streamer"];
        [req setValue:@"MACOS" forHTTPHeaderField:@"nv-device-os"];
        [req setValue:@"DESKTOP" forHTTPHeaderField:@"nv-device-type"];
        [req setValue:[NSString stringWithUTF8String:deviceId.c_str()] forHTTPHeaderField:@"x-device-id"];
        OPNSentryTransaction *trace = [OPNSentry traceHTTPRequest:req name:@"Cloudmatch poll claim session"];

        [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            (void)response;
            [trace setStatus:!error && data];
            [trace finish];
            poller(data, error);
        }] resume];
    };

    pollBlock();
}

void SessionManager::ClaimSession(const std::string &sessionId,
                                    const std::string &serverIp,
                                    const std::string &appId,
                                    const StreamSettings &settings,
                                    bool recoveryMode,
                                    SessionCreateCallback completion) {
    if (m_storage->accessToken.empty()) {
        completion(false, SessionInfo{}, "No access token");
        return;
    }

    std::string deviceId = StableCloudmatchDeviceIdString();
    std::string clientId = RandomUUID();


    NSString *sid = StringFromStdString(sessionId);
    NSString *sip = StringFromStdString(serverIp);

    OPNLogInfo(@"[ClaimSession] Starting claim sessionId=%@ serverIp=%@ appId=%s codec=%s color=%s bitrate=%dMbps l4s=%s recovery=%d",
          sid,
          sip,
          appId.c_str(),
          settings.codec.c_str(),
          settings.colorQuality.c_str(),
          settings.maxBitrateMbps,
          settings.enableL4S ? "on" : "off",
          recoveryMode);

    NSInteger timezoneOffset = -[[NSTimeZone localTimeZone] secondsFromGMT] * 1000;
    NSString *subSessionId = StringFromStdString(RandomUUID());
    NSString *deviceIdString = StringFromStdString(deviceId);
    NSString *selectedStore = settings.selectedStore.empty() ? @"unknown" : StringFromStdString(settings.selectedStore, @"unknown");
    NSString *appIdString = StringFromStdString(appId);
    StreamDeviceCapabilities displayCapabilities = LoadStreamDeviceCapabilities();
    bool hdrEnabled = RequestedHdrEnabled(settings, displayCapabilities);

    NSDictionary *payload = @{
        @"action": @2,
        @"data": @"MANUAL",
        @"sessionRequestData": @{
            @"audioMode": @2,
            @"remoteControllersBitmap": @((unsigned long long)settings.remoteControllersBitmap),
            @"sdrHdrMode": hdrEnabled ? @1 : @0,
            @"networkTestSessionId": NetworkTestSessionIdValue(settings),
            @"availableSupportedControllers": AvailableSupportedControllersValue(settings),
            @"clientVersion": @"30.0",
            @"deviceHashId": deviceIdString,
            @"internalTitle": [NSNull null],
            @"clientPlatformName": @"windows",
            @"clientRequestMonitorSettings": @[MonitorSettings(settings, displayCapabilities, hdrEnabled)],
            @"metaData": @[
                @{@"key": @"SubSessionId", @"value": subSessionId},
                @{@"key": @"wssignaling", @"value": @"1"},
                @{@"key": @"GSStreamerType", @"value": @"WebRTC"},
                @{@"key": @"networkType", @"value": NetworkTypeValue(settings)},
                @{@"key": @"networkLatencyMs", @"value": NetworkLatencyValue(settings)},
                @{@"key": @"ClientImeSupport", @"value": @"0"},
                @{@"key": @"surroundAudioInfo", @"value": @"2"},
                @{@"key": @"store", @"value": selectedStore},
            ],
            @"surroundAudioInfo": @0,
            @"clientTimezoneOffset": @(timezoneOffset),
            @"clientIdentification": @"GFN-PC",
            @"parentSessionId": [NSNull null],
            @"appId": @(appIdString.intValue),
            @"streamerVersion": @1,
            @"appLaunchMode": @1,
            @"sdkVersion": @"1.0",
            @"enhancedStreamMode": @1,
            @"useOps": @YES,
            @"clientDisplayHdrCapabilities": ClientDisplayHdrCapabilities(displayCapabilities),
            @"accountLinked": @(settings.accountLinked),
            @"partnerCustomData": @"",
            @"enablePersistingInGameSettings": @YES,
            @"secureRTSPSupported": @NO,
            @"userAge": @26,
            @"requestedStreamingFeatures": RequestedStreamingFeatures(settings, hdrEnabled),
        },
        @"metaData": @[],
    };

    NSString *layout = StringFromStdString(settings.keyboardLayout, @"us");
    NSString *lang = StringFromStdString(settings.gameLanguage, [OPNLocale currentGFNLocale]);

    NSString *claimUrl = [NSString stringWithFormat:@"https://%@/v2/session/%@?keyboardLayout=%@&languageCode=%@",
                          sip, sid, layout, lang];

    if (sip.length == 0) {
        OPNLogError(@"[ClaimSession] ERROR: serverIp is empty, cannot construct URL");
        completion(false, SessionInfo{}, "No server IP for claim");
        return;
    }

    __block int preClaimStatus = 0;
    NSString *validationUrlStr = [NSString stringWithFormat:@"https://%@/v2/session/%@", sip, sid];
    OPNLogInfo(@"[ClaimSession] Validation GET %@", validationUrlStr);

    NSURL *validationURL = [NSURL URLWithString:validationUrlStr];
    if (!validationURL) {
        OPNLogError(@"[ClaimSession] ERROR: invalid validation URL: %@", validationUrlStr);
        completion(false, SessionInfo{}, "Invalid validation URL");
        return;
    }

    NSMutableURLRequest *validationReq = [NSMutableURLRequest requestWithURL:validationURL];
    validationReq.timeoutInterval = 30;
    [validationReq setValue:GetUserAgent() forHTTPHeaderField:@"User-Agent"];
    [validationReq setValue:[NSString stringWithFormat:@"GFNJWT %s", m_storage->accessToken.c_str()] forHTTPHeaderField:@"Authorization"];
    [validationReq setValue:kNvClientId forHTTPHeaderField:@"nv-client-id"];
    [validationReq setValue:@"NATIVE" forHTTPHeaderField:@"nv-client-type"];
    [validationReq setValue:kNvClientVersion forHTTPHeaderField:@"nv-client-version"];
    [validationReq setValue:@"NVIDIA-CLASSIC" forHTTPHeaderField:@"nv-client-streamer"];
    [validationReq setValue:@"MACOS" forHTTPHeaderField:@"nv-device-os"];
    [validationReq setValue:@"DESKTOP" forHTTPHeaderField:@"nv-device-type"];
    [validationReq setValue:deviceIdString forHTTPHeaderField:@"x-device-id"];

    SessionCreateCallback cb = completion;
    OPNSentryTransaction *validationTrace = [OPNSentry traceHTTPRequest:validationReq name:@"Cloudmatch validate session claim"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:validationReq completionHandler:^(NSData *vData, NSURLResponse *vResp, NSError *vErr) {
        void (^finishValidationTrace)(BOOL) = ^(BOOL success) {
            [validationTrace setStatus:success];
            [validationTrace finish];
        };
        NSHTTPURLResponse *validationHttp = (NSHTTPURLResponse *)vResp;
        if (vErr) {
            OPNLogError(@"[ClaimSession] Validation request failed: %@", vErr.localizedDescription);
            finishValidationTrace(NO);
        } else if (vData) {
            NSDictionary *vJson = [NSJSONSerialization JSONObjectWithData:vData options:0 error:nil];
            NSDictionary *vSession = DictionaryValue(vJson[@"session"]);
            if (vSession) {
                preClaimStatus = [vSession[@"status"] intValue];
                OPNLogInfo(@"[ClaimSession] Pre-claim validation status=%d", preClaimStatus);
            }
            NSDictionary *vReqStatus = DictionaryValue(vJson[@"requestStatus"]);
            NSNumber *vStatusCode = [vReqStatus[@"statusCode"] isKindOfClass:[NSNumber class]] ? vReqStatus[@"statusCode"] : nil;
            if (validationHttp.statusCode >= 400 || (vStatusCode && vStatusCode.integerValue != 1 && preClaimStatus == 0)) {
                NSString *validationBody = [[NSString alloc] initWithData:vData encoding:NSUTF8StringEncoding] ?: @"";
                finishValidationTrace(NO);
                cb(false, SessionInfo{}, [[NSString stringWithFormat:@"STALE_ACTIVE_SESSION: validation HTTP %ld: %@", (long)validationHttp.statusCode, validationBody] UTF8String]);
                return;
            }
            finishValidationTrace(YES);
        } else {
            OPNLogError(@"[ClaimSession] Validation request returned no data and no error");
            finishValidationTrace(NO);
        }

        if (preClaimStatus == 1) {
            this->pollClaimSession([sid UTF8String], [sip UTF8String], deviceId, clientId, NegotiatedStreamProfile{}, cb);
            return;
        }

        if (IsReadyActiveSessionStatus(preClaimStatus)) {
            OPNLogInfo(@"[ClaimSession] Ready session status=%d; skipping redundant RESUME PUT", preClaimStatus);
            this->pollClaimSession([sid UTF8String], [sip UTF8String], deviceId, clientId, NegotiatedStreamProfile{}, cb);
            return;
        }

        OPNLogInfo(@"[ClaimSession] Sending RESUME PUT to %@", claimUrl);
        [OPNProtocolDebug logJSONObjectWithLabel:@"session claim request" object:payload];
        NSURL *claimURL = [NSURL URLWithString:claimUrl];
        if (!claimURL) {
            cb(false, SessionInfo{}, "Invalid claim URL");
            return;
        }
        NSMutableURLRequest *claimReq = [NSMutableURLRequest requestWithURL:claimURL];
        claimReq.timeoutInterval = 15;
        claimReq.HTTPMethod = @"PUT";
        [claimReq setValue:GetUserAgent() forHTTPHeaderField:@"User-Agent"];
        [claimReq setValue:[NSString stringWithFormat:@"GFNJWT %s", m_storage->accessToken.c_str()] forHTTPHeaderField:@"Authorization"];
        [claimReq setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [claimReq setValue:@"https://play.geforcenow.com" forHTTPHeaderField:@"Origin"];
        [claimReq setValue:@"https://play.geforcenow.com/" forHTTPHeaderField:@"Referer"];
        [claimReq setValue:kNvClientId forHTTPHeaderField:@"nv-client-id"];
        [claimReq setValue:@"NVIDIA-CLASSIC" forHTTPHeaderField:@"nv-client-streamer"];
        [claimReq setValue:@"NATIVE" forHTTPHeaderField:@"nv-client-type"];
        [claimReq setValue:kNvClientVersion forHTTPHeaderField:@"nv-client-version"];
        [claimReq setValue:@"MACOS" forHTTPHeaderField:@"nv-device-os"];
        [claimReq setValue:@"DESKTOP" forHTTPHeaderField:@"nv-device-type"];
        [claimReq setValue:deviceIdString forHTTPHeaderField:@"x-device-id"];
        claimReq.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
        OPNSentryTransaction *claimTrace = [OPNSentry traceHTTPRequest:claimReq name:@"Cloudmatch claim session"];

        [[[NSURLSession sharedSession] dataTaskWithRequest:claimReq completionHandler:^(NSData *cData, NSURLResponse *cResp, NSError *cErr) {
            void (^finishClaimTrace)(BOOL) = ^(BOOL success) {
                [claimTrace setStatus:success];
                [claimTrace finish];
            };
            if (cErr || !cData) {
                NSString *errDesc = cErr ? [cErr localizedDescription] : @"No data";
                OPNLogError(@"[ClaimSession] PUT failed: %@", errDesc);
                finishClaimTrace(NO);
                cb(false, SessionInfo{}, [errDesc UTF8String]);
                return;
            }
            NSHTTPURLResponse *cHttp = (NSHTTPURLResponse *)cResp;
            [OPNProtocolDebug logJSONDataWithLabel:@"session claim response" data:cData];
            NSString *cBody = [[NSString alloc] initWithData:cData encoding:NSUTF8StringEncoding];
            if (VerboseSessionHttpLoggingEnabled()) {
                OPNLogInfo(@"[ClaimSession] PUT response HTTP %ld body=%@", (long)cHttp.statusCode, cBody);
            } else {
                OPNLogInfo(@"[ClaimSession] PUT response HTTP %ld", (long)cHttp.statusCode);
            }
            if (cHttp.statusCode != 200) {
                if ([cBody rangeOfString:@"SESSION_NOT_PAUSED"].location != NSNotFound || [cBody rangeOfString:@"\"statusCode\":34"].location != NSNotFound) {
                    OPNLogInfo(@"[ClaimSession] Session is not paused; polling current active session instead of issuing another launch");
                    finishClaimTrace(NO);
                    this->pollClaimSession([sid UTF8String], [sip UTF8String], deviceId, clientId, NegotiatedStreamProfile{}, cb);
                    return;
                }
                finishClaimTrace(NO);
                cb(false, SessionInfo{}, [[NSString stringWithFormat:@"Claim HTTP %ld: %@", (long)cHttp.statusCode, cBody] UTF8String]);
                return;
            }
            finishClaimTrace(YES);

            NSDictionary *cJson = [NSJSONSerialization JSONObjectWithData:cData options:0 error:nil];
            NSDictionary *cReqStatus = DictionaryValue(cJson[@"requestStatus"]);
            NSNumber *cSc = cReqStatus[@"statusCode"];
            if (!cSc || cSc.integerValue != 1) {
                NSString *desc = cReqStatus[@"statusDescription"] ?: @"unknown";
                if ([desc rangeOfString:@"SESSION_NOT_PAUSED"].location != NSNotFound || cSc.integerValue == 34) {
                    OPNLogInfo(@"[ClaimSession] Session is not paused; polling current active session instead of issuing another launch");
                    this->pollClaimSession([sid UTF8String], [sip UTF8String], deviceId, clientId, NegotiatedStreamProfile{}, cb);
                    return;
                }
                OPNLogError(@"[ClaimSession] PUT API error: %@: %@", cSc, desc);
                cb(false, SessionInfo{}, [[NSString stringWithFormat:@"Claim API error %@: %@", cSc, desc] UTF8String]);
                return;
            }

            NegotiatedStreamProfile claimStreamProfile;
            NSDictionary *cSession = DictionaryValue(cJson[@"session"]);
            if (cSession) {
                ParseStreamProfile(cSession, claimStreamProfile);
            }
            this->pollClaimSession([sid UTF8String], [sip UTF8String], deviceId, clientId, claimStreamProfile, cb);
        }] resume];
    }] resume];
}

}
