
#include "OPNSessionManager.h"
#include "common/OPNSentry.h"
#include "common/OPNLocale.h"
#include "common/OPNDeviceIdentity.h"
#include "common/OPNProtocolDebug.h"
#include "OPNStreamTypes.h"
#include "OPNStreamPreferences.h"
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonCrypto.h>
#include <algorithm>
#include <cstdlib>
#include <cstring>

static NSString *kNvClientId = @"ec7e38d4-03af-4b58-b131-cfb0495903ab";
static NSString *kNvClientVersion = @"2.0.80.173";

static NSString *GetUserAgent() {
    return @"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36 NVIDIACEFClient/HEAD/debb5919f6 GFN-PC/2.0.80.173";
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
    if (serverIp.empty()) {
        return streamingBaseUrl.empty() ? "https://prod.cloudmatchbeta.nvidiagrid.net" : streamingBaseUrl;
    }
    if (serverIp.rfind("https://", 0) == 0 || serverIp.rfind("http://", 0) == 0) {
        std::string base = serverIp;
        while (!base.empty() && base.back() == '/') base.pop_back();
        return base;
    }
    return "https://" + serverIp;
}

static bool IsUsableEndpointHost(NSString *host) {
    return [host isKindOfClass:[NSString class]] && host.length > 0 && ![host hasPrefix:@"."];
}

static NSArray *ArrayValue(id value) {
    return [value isKindOfClass:[NSArray class]] ? (NSArray *)value : @[];
}

static NSDictionary *DictionaryValue(id value) {
    return [value isKindOfClass:[NSDictionary class]] ? (NSDictionary *)value : nil;
}

static NSString *StringValue(id value) {
    return [value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0 ? (NSString *)value : nil;
}

static NSString *StringFromStdString(const std::string &value, NSString *fallback = @"") {
    if (value.empty()) return fallback ?: @"";
    NSString *string = [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding];
    return string ?: (fallback ?: @"");
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

static int PositiveIntValue(id value) {
    if ([value isKindOfClass:[NSNumber class]]) {
        int parsed = [(NSNumber *)value intValue];
        return parsed > 0 ? parsed : 0;
    }
    if ([value isKindOfClass:[NSString class]]) {
        int parsed = [(NSString *)value intValue];
        return parsed > 0 ? parsed : 0;
    }
    return 0;
}

static int IntValue(id value, int fallback = 0) {
    if ([value isKindOfClass:[NSNumber class]]) return [(NSNumber *)value intValue];
    if ([value isKindOfClass:[NSString class]]) return [(NSString *)value intValue];
    return fallback;
}

static OPN::SessionProgressState ProgressStateForSeatSetupStep(int seatSetupStep, int queuePosition) {
    switch (seatSetupStep) {
        case 0:
            return queuePosition > 0 ? OPN::SessionProgressState::InQueue : OPN::SessionProgressState::Connecting;
        case 1:
            return OPN::SessionProgressState::InQueue;
        case 5:
            return OPN::SessionProgressState::PreviousSessionCleanup;
        case 6:
            return OPN::SessionProgressState::WaitingForStorage;
        default:
            return OPN::SessionProgressState::SettingUp;
    }
}

static bool BoolValue(id value, bool fallback = false) {
    if ([value isKindOfClass:[NSNumber class]]) return [(NSNumber *)value boolValue];
    if ([value isKindOfClass:[NSString class]]) {
        NSString *lower = [(NSString *)value lowercaseString];
        if ([lower isEqualToString:@"true"] || [lower isEqualToString:@"1"] || [lower isEqualToString:@"yes"]) return true;
        if ([lower isEqualToString:@"false"] || [lower isEqualToString:@"0"] || [lower isEqualToString:@"no"]) return false;
    }
    return fallback;
}

static bool VerboseSessionHttpLoggingEnabled() {
    const char *value = std::getenv("OPN_VERBOSE_SESSION_HTTP");
    return value && std::strcmp(value, "1") == 0;
}

static std::string NormalizeCloudMatchBaseUrl(const std::string &url) {
    std::string normalized = url;
    while (!normalized.empty() && normalized.back() == '/') {
        normalized.pop_back();
    }
    return normalized;
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

static std::string ColorQualityFromFeatures(int bitDepth, int chromaFormat) {
    const bool tenBit = bitDepth >= 10;
    const bool fourFourFour = chromaFormat == 2;
    if (tenBit && fourFourFour) return "10bit_444";
    if (tenBit) return "10bit_420";
    if (fourFourFour) return "8bit_444";
    return "8bit_420";
}

static void ParseStreamProfile(NSDictionary *session, OPN::NegotiatedStreamProfile &profile) {
    NSDictionary *negotiated = DictionaryValue(session[@"negotiatedStreamProfile"]);
    if (negotiated) {
        NSString *res = [negotiated[@"resolution"] isKindOfClass:[NSString class]] ? negotiated[@"resolution"] : nil;
        if (res) profile.resolution = [res UTF8String];
        NSString *codec = [negotiated[@"codec"] isKindOfClass:[NSString class]] ? negotiated[@"codec"] : nil;
        if (codec) profile.codec = [codec UTF8String];
        NSNumber *fpsNum = [negotiated[@"fps"] isKindOfClass:[NSNumber class]] ? negotiated[@"fps"] : nil;
        if (fpsNum) profile.fps = [fpsNum intValue];
    }

    NSDictionary *features = DictionaryValue(session[@"finalizedStreamingFeatures"]);
    if (!features) return;

    NSNumber *bitDepth = [features[@"bitDepth"] isKindOfClass:[NSNumber class]] ? features[@"bitDepth"] : nil;
    NSNumber *chromaFormat = [features[@"chromaFormat"] isKindOfClass:[NSNumber class]] ? features[@"chromaFormat"] : nil;
    if (bitDepth) profile.bitDepth = [bitDepth intValue];
    if (chromaFormat) profile.chromaFormat = [chromaFormat intValue];
    if (profile.bitDepth >= 0 || profile.chromaFormat >= 0) {
        profile.colorQuality = ColorQualityFromFeatures(profile.bitDepth, profile.chromaFormat);
        OPN::LogInfo(@"[SessionManager] Finalized stream features bitDepth=%d chromaFormat=%d color=%s",
              profile.bitDepth,
              profile.chromaFormat,
              profile.colorQuality.c_str());
    }

    NSNumber *prefilterMode = [features[@"prefilterMode"] isKindOfClass:[NSNumber class]] ? features[@"prefilterMode"] : nil;
    NSNumber *prefilterSharpness = [features[@"prefilterSharpness"] isKindOfClass:[NSNumber class]] ? features[@"prefilterSharpness"] : nil;
    NSNumber *prefilterDenoise = [features[@"prefilterNoiseReduction"] isKindOfClass:[NSNumber class]] ? features[@"prefilterNoiseReduction"] : nil;
    NSNumber *prefilterModel = [features[@"prefilterModel"] isKindOfClass:[NSNumber class]] ? features[@"prefilterModel"] : nil;
    if (prefilterMode) profile.prefilterMode = std::max(0, std::min([prefilterMode intValue], 2));
    if (prefilterSharpness) profile.prefilterSharpness = std::max(0, std::min([prefilterSharpness intValue], 10));
    if (prefilterDenoise) profile.prefilterDenoise = std::max(0, std::min([prefilterDenoise intValue], 10));
    if (prefilterModel) profile.prefilterModel = std::max(0, [prefilterModel intValue]);
}

static void ParseQueueProgress(NSDictionary *session, OPN::SessionInfo &info) {
    int queuePosition = PositiveIntValue(session[@"queuePosition"]);
    NSDictionary *seatSetupInfo = DictionaryValue(session[@"seatSetupInfo"]);
    if (queuePosition == 0 && seatSetupInfo) queuePosition = PositiveIntValue(seatSetupInfo[@"queuePosition"]);
    NSDictionary *sessionProgress = DictionaryValue(session[@"sessionProgress"]);
    if (queuePosition == 0 && sessionProgress) queuePosition = PositiveIntValue(sessionProgress[@"queuePosition"]);
    NSDictionary *progressInfo = DictionaryValue(session[@"progressInfo"]);
    if (queuePosition == 0 && progressInfo) queuePosition = PositiveIntValue(progressInfo[@"queuePosition"]);
    info.queuePosition = queuePosition;

    if (seatSetupInfo) {
        info.seatSetupStep = IntValue(seatSetupInfo[@"seatSetupStep"]);
    }
    if (info.seatSetupStep == 0 && sessionProgress) {
        info.seatSetupStep = IntValue(sessionProgress[@"seatSetupStep"]);
    }
    if (info.seatSetupStep == 0 && progressInfo) {
        info.seatSetupStep = IntValue(progressInfo[@"seatSetupStep"]);
    }
    info.progressState = ProgressStateForSeatSetupStep(info.seatSetupStep, info.queuePosition);
}

static int AdMediaProfileRank(const std::string &profile) {
    if (profile == "mp4deinterlaced720p") return 0;
    if (profile == "hlsadaptive") return 1;
    if (profile == "webm") return 2;
    return 100;
}

static bool IsTerminalAdState(int adState) {
    return adState == 5 || adState == 6;
}

static OPN::SessionAdInfo ParseSessionAd(NSDictionary *ad, NSUInteger index) {
    OPN::SessionAdInfo out;
    NSString *adId = StringValue(ad[@"adId"]);
    out.adId = adId ? adId.UTF8String : ("ad-" + std::to_string((unsigned long)index + 1));
    out.adState = [ad[@"adState"] isKindOfClass:[NSNumber class]] ? [ad[@"adState"] intValue] : -1;
    if (NSString *value = StringValue(ad[@"adUrl"])) out.adUrl = value.UTF8String;
    if (NSString *value = StringValue(ad[@"mediaUrl"])) out.mediaUrl = value.UTF8String;
    if (out.mediaUrl.empty()) {
        if (NSString *value = StringValue(ad[@"videoUrl"])) out.mediaUrl = value.UTF8String;
    }
    if (out.mediaUrl.empty()) {
        if (NSString *value = StringValue(ad[@"url"])) out.mediaUrl = value.UTF8String;
    }
    if (NSString *value = StringValue(ad[@"clickThroughUrl"])) out.clickThroughUrl = value.UTF8String;
    if (NSString *value = StringValue(ad[@"title"])) out.title = value.UTF8String;
    if (NSString *value = StringValue(ad[@"description"])) out.description = value.UTF8String;
    out.adLengthInSeconds = PositiveIntValue(ad[@"adLengthInSeconds"]);
    out.durationMs = out.adLengthInSeconds > 0 ? out.adLengthInSeconds * 1000 : PositiveIntValue(ad[@"durationMs"]);
    if (out.durationMs == 0) out.durationMs = PositiveIntValue(ad[@"durationInMs"]);

    for (NSDictionary *file in ArrayValue(ad[@"adMediaFiles"])) {
        if (![file isKindOfClass:[NSDictionary class]]) continue;
        OPN::SessionAdMediaFile media;
        if (NSString *value = StringValue(file[@"mediaFileUrl"])) media.mediaFileUrl = value.UTF8String;
        if (NSString *value = StringValue(file[@"encodingProfile"])) media.encodingProfile = value.UTF8String;
        if (!media.mediaFileUrl.empty() || !media.encodingProfile.empty()) {
            out.adMediaFiles.push_back(media);
        }
    }
    std::sort(out.adMediaFiles.begin(), out.adMediaFiles.end(), [](const OPN::SessionAdMediaFile &left, const OPN::SessionAdMediaFile &right) {
        return AdMediaProfileRank(left.encodingProfile) < AdMediaProfileRank(right.encodingProfile);
    });
    if (out.mediaUrl.empty()) {
        for (const OPN::SessionAdMediaFile &file : out.adMediaFiles) {
            if (!file.mediaFileUrl.empty()) {
                out.mediaUrl = file.mediaFileUrl;
                break;
            }
        }
    }
    if (out.mediaUrl.empty() && !out.adUrl.empty()) out.mediaUrl = out.adUrl;
    return out;
}

static void ParseSessionAds(NSDictionary *session, OPN::SessionAdState &adState) {
    NSDictionary *progress = DictionaryValue(session[@"sessionProgress"]);
    NSDictionary *progressInfo = DictionaryValue(session[@"progressInfo"]);
    bool required = BoolValue(session[@"sessionAdsRequired"], false) ||
                    BoolValue(session[@"isAdsRequired"], false) ||
                    BoolValue(progress[@"isAdsRequired"], false) ||
                    BoolValue(progressInfo[@"isAdsRequired"], false);
    NSArray *ads = ArrayValue(session[@"sessionAds"]);
    adState.sessionAdsRequired = required;
    adState.serverSentEmptyAds = session[@"sessionAds"] == nil || [session[@"sessionAds"] isKindOfClass:[NSNull class]];
    adState.sessionAds.clear();

    NSUInteger index = 0;
    for (NSDictionary *ad in ads) {
        if (![ad isKindOfClass:[NSDictionary class]]) continue;
        OPN::SessionAdInfo parsed = ParseSessionAd(ad, index++);
        if (IsTerminalAdState(parsed.adState)) continue;
        if (!parsed.adId.empty() || !parsed.mediaUrl.empty() || !parsed.title.empty() || !parsed.description.empty()) {
            adState.sessionAds.push_back(parsed);
        }
    }

    NSDictionary *opportunity = DictionaryValue(session[@"opportunity"]);
    if (opportunity) {
        adState.isQueuePaused = BoolValue(opportunity[@"queuePaused"], adState.isQueuePaused);
        adState.gracePeriodSeconds = PositiveIntValue(opportunity[@"gracePeriodSeconds"]);
        NSString *message = StringValue(opportunity[@"message"]) ?: StringValue(opportunity[@"description"]);
        if (message) adState.message = message.UTF8String;
        NSString *state = StringValue(opportunity[@"state"]);
        if (state && [[state lowercaseString] isEqualToString:@"graceperiodstart"]) adState.isQueuePaused = true;
    }

    adState.isAdsRequired = required || !adState.sessionAds.empty() || adState.isQueuePaused;
    if (adState.message.empty() && adState.isAdsRequired) {
        adState.message = adState.isQueuePaused ? "Resume ads to stay in queue." : "Finish ads to stay in queue.";
    }
}

static void MergeSessionAdState(OPN::SessionAdState &target, const OPN::SessionAdState &previous) {
    if (target.isAdsRequired && target.serverSentEmptyAds && target.sessionAds.empty() && !previous.sessionAds.empty()) {
        target.sessionAds = previous.sessionAds;
    }
}

static void LogPollSessionSummary(NSInteger httpStatus, const OPN::SessionInfo &info) {
    OPN::LogInfo(@"[PollSession] HTTP %ld session=%s status=%d queue=%d step=%d server=%s signaling=%s gpu=%s color=%s ads=%s",
          (long)httpStatus,
          info.sessionId.empty() ? "(empty)" : info.sessionId.c_str(),
          info.status,
          info.queuePosition,
          info.seatSetupStep,
          info.serverIp.empty() ? "(pending)" : info.serverIp.c_str(),
          info.signalingServer.empty() ? "(pending)" : info.signalingServer.c_str(),
          info.gpuType.empty() ? "(pending)" : info.gpuType.c_str(),
          info.negotiatedStreamProfile.colorQuality.empty() ? "(pending)" : info.negotiatedStreamProfile.colorQuality.c_str(),
          info.adState.isAdsRequired ? "required" : "none");
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

namespace OPN {

SessionManager &SessionManager::Shared() {
    static SessionManager instance;
    return instance;
}

void SessionManager::SetAccessToken(const std::string &token) {
    m_accessToken = token;
}

void SessionManager::SetStreamingBaseUrl(const std::string &url) {
    m_streamingBaseUrl = NormalizeCloudMatchBaseUrl(url);
}

void SessionManager::MergeAndStoreAdState(SessionInfo &info) {
    if (info.sessionId.empty()) return;
    std::lock_guard<std::mutex> lock(m_adStateMutex);
    auto existing = m_adStatesBySessionId.find(info.sessionId);
    if (existing != m_adStatesBySessionId.end()) {
        MergeSessionAdState(info.adState, existing->second);
    }
    m_adStatesBySessionId[info.sessionId] = info.adState;
}

void SessionManager::CreateSession(const std::string &appId,
                                    const std::string &internalTitle,
                                    const StreamSettings &settings,
                                    SessionCreateCallback completion) {
    if (m_accessToken.empty()) {
        completion(false, SessionInfo{}, "No access token");
        return;
    }

    std::string appIdCopy = appId;
    std::string internalTitleCopy = internalTitle;
    StreamSettings settingsCopy = settings;

    std::string baseUrl = m_streamingBaseUrl.empty()
        ? "https://prod.cloudmatchbeta.nvidiagrid.net"
        : m_streamingBaseUrl;

    std::string clientId = RandomUUID();
    std::string deviceId = StableCloudmatchDeviceId();

    StreamDeviceCapabilities displayCapabilities = LoadStreamDeviceCapabilities();
    settingsCopy = StreamSettingsByApplyingCloudVariables(settingsCopy, LoadCachedStreamCloudVariables(), displayCapabilities);
    bool hdrEnabled = RequestedHdrEnabled(settingsCopy, displayCapabilities);

    NSInteger timezoneOffset = -[[NSTimeZone localTimeZone] secondsFromGMT] * 1000;

    OPN::LogInfo(@"[SessionManager] CreateSession called with appId=%s codec=%s color=%s bitrate=%dMbps l4s=%s",
          appIdCopy.c_str(),
          settingsCopy.codec.c_str(),
          settingsCopy.colorQuality.c_str(),
          settingsCopy.maxBitrateMbps,
          settingsCopy.enableL4S ? "on" : "off");

    NSString *appIdStr = StringFromStdString(appIdCopy);
    OPN::LogInfo(@"[SessionManager] appIdStr=%@", appIdStr);

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
    NSString *lang = StringFromStdString(settingsCopy.gameLanguage, [NSString stringWithUTF8String:OPN::CurrentGFNLocale().c_str()]);
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
    [req setValue:[NSString stringWithFormat:@"GFNJWT %s", m_accessToken.c_str()] forHTTPHeaderField:@"Authorization"];
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
        OPN::LogInfo(@"[SessionManager] HTTP Body: %@", bodyStr);
    }
    LogProtocolJSONObject(@"session create request", body);
    req.HTTPBody = bodyData;

    SessionCreateCallback cb = completion;
    NSString *baseUrlStr = baseUrlString;

        [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error || !data) {
                cb(false, SessionInfo{}, [[error localizedDescription] UTF8String]);
                return;
            }
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            LogProtocolJSONData(@"session create response", data);
            if (http.statusCode != 200) {
                NSString *responseBody = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
                NSString *originalErrorString = [NSString stringWithFormat:@"HTTP %ld: %@", (long)http.statusCode, responseBody];
                std::string originalError = originalErrorString.UTF8String ? originalErrorString.UTF8String : "";
                NSDictionary *errorJson = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if (IsSessionLimitExceededResponse(errorJson)) {
                    std::vector<ActiveSessionEntry> sessions = ActiveSessionEntriesFromArray(ArrayValue(errorJson[@"otherUserSessions"]), baseUrl);
                    ActiveSessionEntry selectedSession;
                    if (SelectSessionLimitReuseEntry(sessions, appIdCopy.empty() ? 0 : atoi(appIdCopy.c_str()), selectedSession)) {
                        OPN::LogInfo(@"[SessionManager] Reusing embedded active session after session limit sessionId=%s appId=%d status=%d server=%s",
                                     selectedSession.sessionId.c_str(),
                                     selectedSession.appId,
                                     selectedSession.status,
                                     selectedSession.serverIp.c_str());
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
                cb(false, SessionInfo{}, originalError);
                return;
            }

            NSString *createBody = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (VerboseSessionHttpLoggingEnabled()) {
                OPN::LogInfo(@"[SessionManager] CreateSession response: %@", createBody);
            }

            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (!json) {
                cb(false, SessionInfo{}, "Failed to parse session response");
                return;
            }

            NSDictionary *reqStatus = DictionaryValue(json[@"requestStatus"]);
            NSNumber *statusCode = reqStatus[@"statusCode"];
            if (!statusCode || statusCode.integerValue != 1) {
                NSString *desc = reqStatus[@"statusDescription"] ?: @"unknown";
                cb(false, SessionInfo{}, [[NSString stringWithFormat:@"API error %@: %@", statusCode, desc] UTF8String]);
                return;
            }

            NSDictionary *session = DictionaryValue(json[@"session"]);
            if (!session) {
                cb(false, SessionInfo{}, "No session in response");
                return;
            }

            SessionInfo info;
            NSString *sid = [session[@"sessionId"] isKindOfClass:[NSString class]] ? session[@"sessionId"] : nil;
            info.sessionId = [sid UTF8String] ?: "";
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
        MergeAndStoreAdState(info);


        NSDictionary *ctrlInfo = DictionaryValue(session[@"sessionControlInfo"]);
        NSString *ctrlIp = [ctrlInfo[@"ip"] isKindOfClass:[NSString class]] ? ctrlInfo[@"ip"] : nil;
        if (ctrlIp.length > 0 && info.serverIp.empty()) {
            info.serverIp = [ctrlIp UTF8String];
            OPN::LogInfo(@"[SessionManager] Using sessionControlInfo zone: %s", info.serverIp.c_str());
        }

        info.clientId = clientId;
        info.deviceId = deviceId;

        cb(true, info, "");
    }] resume];
}

void SessionManager::PollSession(const std::string &sessionId,
                                  const std::string &serverIp,
                                  SessionPollCallback completion) {
    if (m_accessToken.empty()) {
        completion(false, SessionInfo{}, "No access token");
        return;
    }


    std::string base = ResolveSessionBaseUrl(m_streamingBaseUrl, serverIp);
    NSString *urlStr = [NSString stringWithFormat:@"%@/v2/session/%s",
                        [NSString stringWithUTF8String:base.c_str()],
                        sessionId.c_str()];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    [req setValue:GetUserAgent() forHTTPHeaderField:@"User-Agent"];
    [req setValue:[NSString stringWithFormat:@"GFNJWT %s", m_accessToken.c_str()] forHTTPHeaderField:@"Authorization"];
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
    [req setValue:[NSString stringWithUTF8String:StableCloudmatchDeviceId().c_str()] forHTTPHeaderField:@"x-device-id"];

    SessionPollCallback cb = completion;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            cb(false, SessionInfo{}, [[error localizedDescription] UTF8String]);
            return;
        }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSString *rawBody = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (VerboseSessionHttpLoggingEnabled()) {
            OPN::LogInfo(@"[PollSession] Raw response: HTTP %ld body=%@", (long)http.statusCode, rawBody);
        }
        if (http.statusCode != 200) {
            cb(false, SessionInfo{}, [[NSString stringWithFormat:@"HTTP %ld: %@", (long)http.statusCode, rawBody] UTF8String]);
            return;
        }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (!json) {
            cb(false, SessionInfo{}, [[NSString stringWithFormat:@"Failed to parse poll response: %@", rawBody] UTF8String]);
            return;
        }
        NSDictionary *session = DictionaryValue(json[@"session"]);
        if (!session) {
            cb(false, SessionInfo{}, "No session in poll response");
            return;
        }

        SessionInfo info;
        NSString *sid = [session[@"sessionId"] isKindOfClass:[NSString class]] ? session[@"sessionId"] : nil;
        info.sessionId = [sid UTF8String] ?: "";
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
        MergeAndStoreAdState(info);

        LogPollSessionSummary(http.statusCode, info);

        cb(true, info, "");
    }] resume];
}

void SessionManager::StopSession(const std::string &sessionId,
                                 const std::string &serverIp,
                                 std::function<void(bool, const std::string &)> completion) {
    if (m_accessToken.empty()) {
        completion(false, "No access token");
        return;
    }

    std::string base = ResolveSessionBaseUrl(m_streamingBaseUrl, serverIp);
    NSString *urlStr = [NSString stringWithFormat:@"%@/v2/session/%s",
                        StringFromStdString(base), sessionId.c_str()];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    req.HTTPMethod = @"DELETE";
    ApplyCommonCloudMatchHeaders(req, m_accessToken, StableCloudmatchDeviceId(), true);

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            completion(false, [[error localizedDescription] UTF8String]);
            return;
        }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (http.statusCode != 200) {
            NSString *bodyStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            completion(false, [[NSString stringWithFormat:@"HTTP %ld: %@", (long)http.statusCode, bodyStr] UTF8String]);
            return;
        }
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
    if (m_accessToken.empty()) {
        completion(false, SessionInfo{}, "No access token");
        return;
    }
    int actionCode = AdActionCode(action);
    if (session.sessionId.empty() || adId.empty() || actionCode == 0) {
        completion(false, SessionInfo{}, "Invalid ad update request");
        return;
    }

    std::string base = ResolveSessionBaseUrl(session.streamingBaseUrl.empty() ? m_streamingBaseUrl : session.streamingBaseUrl, session.serverIp);
    NSString *urlStr = [NSString stringWithFormat:@"%@/v2/session/%s",
                        [NSString stringWithUTF8String:base.c_str()],
                        session.sessionId.c_str()];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    req.HTTPMethod = @"PUT";
    ApplyCommonCloudMatchHeaders(req, m_accessToken, session.deviceId.empty() ? StableCloudmatchDeviceId() : session.deviceId, true);

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
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            cb(false, SessionInfo{}, error ? [[error localizedDescription] UTF8String] : "No ad update response");
            return;
        }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSString *bodyStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (http.statusCode != 200) {
            cb(false, SessionInfo{}, [[NSString stringWithFormat:@"HTTP %ld: %@", (long)http.statusCode, bodyStr] UTF8String]);
            return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSDictionary *requestStatus = DictionaryValue(json[@"requestStatus"]);
        NSNumber *statusCode = [requestStatus[@"statusCode"] isKindOfClass:[NSNumber class]] ? requestStatus[@"statusCode"] : nil;
        if (!json || !statusCode || statusCode.integerValue != 1) {
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
        cb(true, updated, "");
    }] resume];
}

void SessionManager::GetActiveSessions(std::function<void(bool, const std::vector<ActiveSessionEntry> &, const std::string &)> completion) {
    if (m_accessToken.empty()) {
        completion(false, {}, "No access token");
        return;
    }

    std::string base = m_streamingBaseUrl.empty()
        ? "https://prod.cloudmatchbeta.nvidiagrid.net"
        : m_streamingBaseUrl;

    NSString *urlStr = [NSString stringWithFormat:@"%@/v2/session", [NSString stringWithUTF8String:base.c_str()]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    [req setValue:GetUserAgent() forHTTPHeaderField:@"User-Agent"];
    [req setValue:[NSString stringWithFormat:@"GFNJWT %s", m_accessToken.c_str()] forHTTPHeaderField:@"Authorization"];
    [req setValue:kNvClientId forHTTPHeaderField:@"nv-client-id"];
    [req setValue:@"NATIVE" forHTTPHeaderField:@"nv-client-type"];
    [req setValue:kNvClientVersion forHTTPHeaderField:@"nv-client-version"];
    [req setValue:@"NVIDIA-CLASSIC" forHTTPHeaderField:@"nv-client-streamer"];
    [req setValue:@"MACOS" forHTTPHeaderField:@"nv-device-os"];
    [req setValue:@"DESKTOP" forHTTPHeaderField:@"nv-device-type"];
    [req setValue:@"UNKNOWN" forHTTPHeaderField:@"nv-device-make"];
    [req setValue:@"UNKNOWN" forHTTPHeaderField:@"nv-device-model"];
    [req setValue:@"CHROME" forHTTPHeaderField:@"nv-browser-type"];
    [req setValue:[NSString stringWithUTF8String:StableCloudmatchDeviceId().c_str()] forHTTPHeaderField:@"x-device-id"];

    auto cb = completion;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            cb(false, {}, [[error localizedDescription] UTF8String]);
            return;
        }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (http.statusCode != 200) {
            cb(false, {}, [[NSString stringWithFormat:@"HTTP %ld", (long)http.statusCode] UTF8String]);
            return;
        }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (!json) {
            cb(false, {}, "Failed to parse sessions response");
            return;
        }

        NSDictionary *reqStatus = DictionaryValue(json[@"requestStatus"]);
        NSNumber *sc = reqStatus[@"statusCode"];
        if (!sc || sc.integerValue != 1) {
            cb(false, {}, "API error from sessions endpoint");
            return;
        }

        NSArray *sessions = ArrayValue(json[@"sessions"]);
        if (![sessions isKindOfClass:[NSArray class]]) {
            cb(true, {}, "");
            return;
        }

        std::vector<ActiveSessionEntry> result = ActiveSessionEntriesFromArray(sessions, base);

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


    NSString *baseUrl = [NSString stringWithUTF8String:ResolveSessionBaseUrl(m_streamingBaseUrl, serverIp).c_str()];

    __block void (^pollBlock)(void);

    void (^poller)(NSData *, NSError *) = ^(NSData *data, NSError *error) {
        if (error || !data) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), pollBlock);
            return;
        }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSDictionary *session = DictionaryValue(json[@"session"]);
        if (!session) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), pollBlock);
            return;
        }

        int status = [session[@"status"] intValue];

        if (status == 2 || status == 3) {
            SessionInfo info;
            NSString *sid = [session[@"sessionId"] isKindOfClass:[NSString class]] ? session[@"sessionId"] : nil;
            info.sessionId = [sid UTF8String] ?: "";
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

            completion(true, info, "");
        } else if (status == 1 || status == 6) {

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), pollBlock);
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
        [req setValue:[NSString stringWithFormat:@"GFNJWT %s", m_accessToken.c_str()] forHTTPHeaderField:@"Authorization"];
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [req setValue:kNvClientId forHTTPHeaderField:@"nv-client-id"];
        [req setValue:@"NATIVE" forHTTPHeaderField:@"nv-client-type"];
        [req setValue:kNvClientVersion forHTTPHeaderField:@"nv-client-version"];
        [req setValue:@"NVIDIA-CLASSIC" forHTTPHeaderField:@"nv-client-streamer"];
        [req setValue:@"MACOS" forHTTPHeaderField:@"nv-device-os"];
        [req setValue:@"DESKTOP" forHTTPHeaderField:@"nv-device-type"];
        [req setValue:[NSString stringWithUTF8String:deviceId.c_str()] forHTTPHeaderField:@"x-device-id"];

        [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            (void)response;
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
    if (m_accessToken.empty()) {
        completion(false, SessionInfo{}, "No access token");
        return;
    }

    std::string deviceId = StableCloudmatchDeviceId();
    std::string clientId = RandomUUID();


    NSString *sid = StringFromStdString(sessionId);
    NSString *sip = StringFromStdString(serverIp);

    OPN::LogInfo(@"[ClaimSession] Starting claim sessionId=%@ serverIp=%@ appId=%s codec=%s color=%s bitrate=%dMbps l4s=%s recovery=%d",
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
        @"data": @"RESUME",
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
    NSString *lang = StringFromStdString(settings.gameLanguage, [NSString stringWithUTF8String:OPN::CurrentGFNLocale().c_str()]);

    NSString *claimUrl = [NSString stringWithFormat:@"https://%@/v2/session/%@?keyboardLayout=%@&languageCode=%@",
                          sip, sid, layout, lang];

    if (sip.length == 0) {
        OPN::LogError(@"[ClaimSession] ERROR: serverIp is empty, cannot construct URL");
        completion(false, SessionInfo{}, "No server IP for claim");
        return;
    }

    __block int preClaimStatus = 0;
    NSString *validationUrlStr = [NSString stringWithFormat:@"https://%@/v2/session/%@", sip, sid];
    OPN::LogInfo(@"[ClaimSession] Validation GET %@", validationUrlStr);

    NSURL *validationURL = [NSURL URLWithString:validationUrlStr];
    if (!validationURL) {
        OPN::LogError(@"[ClaimSession] ERROR: invalid validation URL: %@", validationUrlStr);
        completion(false, SessionInfo{}, "Invalid validation URL");
        return;
    }

    NSMutableURLRequest *validationReq = [NSMutableURLRequest requestWithURL:validationURL];
    validationReq.timeoutInterval = 30;
    [validationReq setValue:GetUserAgent() forHTTPHeaderField:@"User-Agent"];
    [validationReq setValue:[NSString stringWithFormat:@"GFNJWT %s", m_accessToken.c_str()] forHTTPHeaderField:@"Authorization"];
    [validationReq setValue:kNvClientId forHTTPHeaderField:@"nv-client-id"];
    [validationReq setValue:@"NATIVE" forHTTPHeaderField:@"nv-client-type"];
    [validationReq setValue:kNvClientVersion forHTTPHeaderField:@"nv-client-version"];
    [validationReq setValue:@"NVIDIA-CLASSIC" forHTTPHeaderField:@"nv-client-streamer"];
    [validationReq setValue:@"MACOS" forHTTPHeaderField:@"nv-device-os"];
    [validationReq setValue:@"DESKTOP" forHTTPHeaderField:@"nv-device-type"];
    [validationReq setValue:deviceIdString forHTTPHeaderField:@"x-device-id"];

    SessionCreateCallback cb = completion;

    [[[NSURLSession sharedSession] dataTaskWithRequest:validationReq completionHandler:^(NSData *vData, NSURLResponse *vResp, NSError *vErr) {
        NSHTTPURLResponse *validationHttp = (NSHTTPURLResponse *)vResp;
        if (vErr) {
            OPN::LogError(@"[ClaimSession] Validation request failed: %@", vErr.localizedDescription);
        } else if (vData) {
            NSDictionary *vJson = [NSJSONSerialization JSONObjectWithData:vData options:0 error:nil];
            NSDictionary *vSession = DictionaryValue(vJson[@"session"]);
            if (vSession) {
                preClaimStatus = [vSession[@"status"] intValue];
                OPN::LogInfo(@"[ClaimSession] Pre-claim validation status=%d", preClaimStatus);
            }
            NSDictionary *vReqStatus = DictionaryValue(vJson[@"requestStatus"]);
            NSNumber *vStatusCode = [vReqStatus[@"statusCode"] isKindOfClass:[NSNumber class]] ? vReqStatus[@"statusCode"] : nil;
            if (validationHttp.statusCode >= 400 || (vStatusCode && vStatusCode.integerValue != 1 && preClaimStatus == 0)) {
                NSString *validationBody = [[NSString alloc] initWithData:vData encoding:NSUTF8StringEncoding] ?: @"";
                cb(false, SessionInfo{}, [[NSString stringWithFormat:@"STALE_ACTIVE_SESSION: validation HTTP %ld: %@", (long)validationHttp.statusCode, validationBody] UTF8String]);
                return;
            }
        } else {
            OPN::LogError(@"[ClaimSession] Validation request returned no data and no error");
        }

        if (preClaimStatus == 1) {
            this->pollClaimSession([sid UTF8String], [sip UTF8String], deviceId, clientId, NegotiatedStreamProfile{}, cb);
            return;
        }

        if (IsReadyActiveSessionStatus(preClaimStatus)) {
            OPN::LogInfo(@"[ClaimSession] Ready session status=%d; skipping redundant RESUME PUT", preClaimStatus);
            this->pollClaimSession([sid UTF8String], [sip UTF8String], deviceId, clientId, NegotiatedStreamProfile{}, cb);
            return;
        }

        OPN::LogInfo(@"[ClaimSession] Sending RESUME PUT to %@", claimUrl);
        LogProtocolJSONObject(@"session claim request", payload);
        NSURL *claimURL = [NSURL URLWithString:claimUrl];
        if (!claimURL) {
            cb(false, SessionInfo{}, "Invalid claim URL");
            return;
        }
        NSMutableURLRequest *claimReq = [NSMutableURLRequest requestWithURL:claimURL];
        claimReq.timeoutInterval = 15;
        claimReq.HTTPMethod = @"PUT";
        [claimReq setValue:GetUserAgent() forHTTPHeaderField:@"User-Agent"];
        [claimReq setValue:[NSString stringWithFormat:@"GFNJWT %s", m_accessToken.c_str()] forHTTPHeaderField:@"Authorization"];
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

        [[[NSURLSession sharedSession] dataTaskWithRequest:claimReq completionHandler:^(NSData *cData, NSURLResponse *cResp, NSError *cErr) {
            if (cErr || !cData) {
                NSString *errDesc = cErr ? [cErr localizedDescription] : @"No data";
                OPN::LogError(@"[ClaimSession] PUT failed: %@", errDesc);
                cb(false, SessionInfo{}, [errDesc UTF8String]);
                return;
            }
            NSHTTPURLResponse *cHttp = (NSHTTPURLResponse *)cResp;
            LogProtocolJSONData(@"session claim response", cData);
            NSString *cBody = [[NSString alloc] initWithData:cData encoding:NSUTF8StringEncoding];
            if (VerboseSessionHttpLoggingEnabled()) {
                OPN::LogInfo(@"[ClaimSession] PUT response HTTP %ld body=%@", (long)cHttp.statusCode, cBody);
            } else {
                OPN::LogInfo(@"[ClaimSession] PUT response HTTP %ld", (long)cHttp.statusCode);
            }
            if (cHttp.statusCode != 200) {
                if ([cBody rangeOfString:@"SESSION_NOT_PAUSED"].location != NSNotFound || [cBody rangeOfString:@"\"statusCode\":34"].location != NSNotFound) {
                    OPN::LogInfo(@"[ClaimSession] Session is not paused; polling current active session instead of issuing another launch");
                    this->pollClaimSession([sid UTF8String], [sip UTF8String], deviceId, clientId, NegotiatedStreamProfile{}, cb);
                    return;
                }
                cb(false, SessionInfo{}, [[NSString stringWithFormat:@"Claim HTTP %ld: %@", (long)cHttp.statusCode, cBody] UTF8String]);
                return;
            }

            NSDictionary *cJson = [NSJSONSerialization JSONObjectWithData:cData options:0 error:nil];
            NSDictionary *cReqStatus = DictionaryValue(cJson[@"requestStatus"]);
            NSNumber *cSc = cReqStatus[@"statusCode"];
            if (!cSc || cSc.integerValue != 1) {
                NSString *desc = cReqStatus[@"statusDescription"] ?: @"unknown";
                if ([desc rangeOfString:@"SESSION_NOT_PAUSED"].location != NSNotFound || cSc.integerValue == 34) {
                    OPN::LogInfo(@"[ClaimSession] Session is not paused; polling current active session instead of issuing another launch");
                    this->pollClaimSession([sid UTF8String], [sip UTF8String], deviceId, clientId, NegotiatedStreamProfile{}, cb);
                    return;
                }
                OPN::LogError(@"[ClaimSession] PUT API error: %@: %@", cSc, desc);
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
