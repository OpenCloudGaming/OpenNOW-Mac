#include "OPNSessionManager.h"

#import <Foundation/Foundation.h>

typedef void (^OPNSessionManagerCompletion)(BOOL success, NSDictionary *session, NSString *error);
typedef void (^OPNSessionManagerActiveSessionsCompletion)(BOOL success, NSArray<NSDictionary *> *sessions, NSString *error);
typedef void (^OPNSessionManagerStopCompletion)(BOOL success, NSString *error);

static NSString *OPNSessionBridgeString(const std::string &value) {
    if (value.empty()) return @"";
    NSString *string = [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding];
    return string ?: @"";
}

static std::string OPNSessionBridgeStdString(id value) {
    if ([value isKindOfClass:[NSString class]]) return ((NSString *)value).UTF8String ?: "";
    if ([value isKindOfClass:[NSNumber class]]) return ((NSNumber *)value).stringValue.UTF8String ?: "";
    return "";
}

static int OPNSessionBridgeInt(id value, int fallback = 0) {
    return [value respondsToSelector:@selector(intValue)] ? [value intValue] : fallback;
}

static double OPNSessionBridgeDouble(id value, double fallback = 0.0) {
    return [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : fallback;
}

static bool OPNSessionBridgeBool(id value, bool fallback = false) {
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : fallback;
}

static NSArray<NSDictionary *> *OPNSessionBridgeAdMediaFiles(const std::vector<OPN::SessionAdMediaFile> &files) {
    NSMutableArray<NSDictionary *> *result = [NSMutableArray arrayWithCapacity:files.size()];
    for (const auto &file : files) {
        [result addObject:@{
            @"mediaFileUrl": OPNSessionBridgeString(file.mediaFileUrl),
            @"encodingProfile": OPNSessionBridgeString(file.encodingProfile),
        }];
    }
    return result;
}

static NSArray<NSDictionary *> *OPNSessionBridgeAds(const std::vector<OPN::SessionAdInfo> &ads) {
    NSMutableArray<NSDictionary *> *result = [NSMutableArray arrayWithCapacity:ads.size()];
    for (const auto &ad : ads) {
        [result addObject:@{
            @"adId": OPNSessionBridgeString(ad.adId),
            @"adState": @(ad.adState),
            @"adUrl": OPNSessionBridgeString(ad.adUrl),
            @"mediaUrl": OPNSessionBridgeString(ad.mediaUrl),
            @"adMediaFiles": OPNSessionBridgeAdMediaFiles(ad.adMediaFiles),
            @"clickThroughUrl": OPNSessionBridgeString(ad.clickThroughUrl),
            @"adLengthInSeconds": @(ad.adLengthInSeconds),
            @"durationMs": @(ad.durationMs),
            @"title": OPNSessionBridgeString(ad.title),
            @"description": OPNSessionBridgeString(ad.description),
        }];
    }
    return result;
}

static NSDictionary *OPNSessionBridgeDictionary(const OPN::SessionInfo &info) {
    return @{
        @"sessionId": OPNSessionBridgeString(info.sessionId),
        @"status": @(info.status),
        @"queuePosition": @(info.queuePosition),
        @"seatSetupStep": @(info.seatSetupStep),
        @"progressState": @((int)info.progressState),
        @"zone": OPNSessionBridgeString(info.zone),
        @"streamingBaseUrl": OPNSessionBridgeString(info.streamingBaseUrl),
        @"serverIp": OPNSessionBridgeString(info.serverIp),
        @"signalingServer": OPNSessionBridgeString(info.signalingServer),
        @"signalingUrl": OPNSessionBridgeString(info.signalingUrl),
        @"gpuType": OPNSessionBridgeString(info.gpuType),
        @"mediaConnectionInfo": @{
            @"ip": OPNSessionBridgeString(info.mediaConnectionInfo.ip),
            @"port": @(info.mediaConnectionInfo.port),
        },
        @"negotiatedStreamProfile": @{
            @"resolution": OPNSessionBridgeString(info.negotiatedStreamProfile.resolution),
            @"fps": @(info.negotiatedStreamProfile.fps),
            @"codec": OPNSessionBridgeString(info.negotiatedStreamProfile.codec),
            @"colorQuality": OPNSessionBridgeString(info.negotiatedStreamProfile.colorQuality),
            @"bitDepth": @(info.negotiatedStreamProfile.bitDepth),
            @"chromaFormat": @(info.negotiatedStreamProfile.chromaFormat),
            @"prefilterMode": @(info.negotiatedStreamProfile.prefilterMode),
            @"prefilterSharpness": @(info.negotiatedStreamProfile.prefilterSharpness),
            @"prefilterDenoise": @(info.negotiatedStreamProfile.prefilterDenoise),
            @"prefilterModel": @(info.negotiatedStreamProfile.prefilterModel),
        },
        @"adState": @{
            @"isAdsRequired": @(info.adState.isAdsRequired),
            @"sessionAdsRequired": @(info.adState.sessionAdsRequired),
            @"isQueuePaused": @(info.adState.isQueuePaused),
            @"serverSentEmptyAds": @(info.adState.serverSentEmptyAds),
            @"gracePeriodSeconds": @(info.adState.gracePeriodSeconds),
            @"message": OPNSessionBridgeString(info.adState.message),
            @"sessionAds": OPNSessionBridgeAds(info.adState.sessionAds),
        },
        @"remainingPlaytimeHours": @(info.remainingPlaytimeHours),
        @"remainingPlaytimeAvailable": @(info.remainingPlaytimeAvailable),
        @"remainingPlaytimeUnlimited": @(info.remainingPlaytimeUnlimited),
        @"clientId": OPNSessionBridgeString(info.clientId),
        @"deviceId": OPNSessionBridgeString(info.deviceId),
    };
}

static OPN::SessionInfo OPNSessionBridgeSessionInfo(NSDictionary *dictionary) {
    OPN::SessionInfo info;
    if (![dictionary isKindOfClass:[NSDictionary class]]) return info;
    info.sessionId = OPNSessionBridgeStdString(dictionary[@"sessionId"]);
    info.status = OPNSessionBridgeInt(dictionary[@"status"]);
    info.queuePosition = OPNSessionBridgeInt(dictionary[@"queuePosition"]);
    info.seatSetupStep = OPNSessionBridgeInt(dictionary[@"seatSetupStep"]);
    info.progressState = (OPN::SessionProgressState)OPNSessionBridgeInt(dictionary[@"progressState"]);
    info.zone = OPNSessionBridgeStdString(dictionary[@"zone"]);
    info.streamingBaseUrl = OPNSessionBridgeStdString(dictionary[@"streamingBaseUrl"]);
    info.serverIp = OPNSessionBridgeStdString(dictionary[@"serverIp"]);
    info.signalingServer = OPNSessionBridgeStdString(dictionary[@"signalingServer"]);
    info.signalingUrl = OPNSessionBridgeStdString(dictionary[@"signalingUrl"]);
    info.gpuType = OPNSessionBridgeStdString(dictionary[@"gpuType"]);
    NSDictionary *media = [dictionary[@"mediaConnectionInfo"] isKindOfClass:[NSDictionary class]] ? dictionary[@"mediaConnectionInfo"] : nil;
    info.mediaConnectionInfo.ip = OPNSessionBridgeStdString(media[@"ip"]);
    info.mediaConnectionInfo.port = OPNSessionBridgeInt(media[@"port"]);
    NSDictionary *profile = [dictionary[@"negotiatedStreamProfile"] isKindOfClass:[NSDictionary class]] ? dictionary[@"negotiatedStreamProfile"] : nil;
    info.negotiatedStreamProfile.resolution = OPNSessionBridgeStdString(profile[@"resolution"]);
    info.negotiatedStreamProfile.fps = OPNSessionBridgeInt(profile[@"fps"]);
    info.negotiatedStreamProfile.codec = OPNSessionBridgeStdString(profile[@"codec"]);
    info.negotiatedStreamProfile.colorQuality = OPNSessionBridgeStdString(profile[@"colorQuality"]);
    info.negotiatedStreamProfile.bitDepth = OPNSessionBridgeInt(profile[@"bitDepth"], -1);
    info.negotiatedStreamProfile.chromaFormat = OPNSessionBridgeInt(profile[@"chromaFormat"], -1);
    info.negotiatedStreamProfile.prefilterMode = OPNSessionBridgeInt(profile[@"prefilterMode"], -1);
    info.negotiatedStreamProfile.prefilterSharpness = OPNSessionBridgeInt(profile[@"prefilterSharpness"], -1);
    info.negotiatedStreamProfile.prefilterDenoise = OPNSessionBridgeInt(profile[@"prefilterDenoise"], -1);
    info.negotiatedStreamProfile.prefilterModel = OPNSessionBridgeInt(profile[@"prefilterModel"], -1);
    info.remainingPlaytimeHours = OPNSessionBridgeDouble(dictionary[@"remainingPlaytimeHours"]);
    info.remainingPlaytimeAvailable = OPNSessionBridgeBool(dictionary[@"remainingPlaytimeAvailable"]);
    info.remainingPlaytimeUnlimited = OPNSessionBridgeBool(dictionary[@"remainingPlaytimeUnlimited"]);
    info.clientId = OPNSessionBridgeStdString(dictionary[@"clientId"]);
    info.deviceId = OPNSessionBridgeStdString(dictionary[@"deviceId"]);
    return info;
}

static OPN::StreamSettings OPNSessionBridgeStreamSettings(NSDictionary *dictionary) {
    OPN::StreamSettings settings;
    if (![dictionary isKindOfClass:[NSDictionary class]]) return settings;
    settings.resolution = OPNSessionBridgeStdString(dictionary[@"resolution"]);
    settings.fps = OPNSessionBridgeInt(dictionary[@"fps"], settings.fps);
    settings.codec = OPNSessionBridgeStdString(dictionary[@"codec"]);
    settings.colorQuality = OPNSessionBridgeStdString(dictionary[@"colorQuality"]);
    settings.maxBitrateMbps = OPNSessionBridgeInt(dictionary[@"maxBitrateMbps"], settings.maxBitrateMbps);
    settings.prefilterMode = OPNSessionBridgeInt(dictionary[@"prefilterMode"]);
    settings.prefilterSharpness = OPNSessionBridgeInt(dictionary[@"prefilterSharpness"]);
    settings.prefilterDenoise = OPNSessionBridgeInt(dictionary[@"prefilterDenoise"]);
    settings.prefilterModel = OPNSessionBridgeInt(dictionary[@"prefilterModel"]);
    settings.enableCloudGsync = OPNSessionBridgeBool(dictionary[@"enableCloudGsync"]);
    settings.enableL4S = OPNSessionBridgeBool(dictionary[@"enableL4S"]);
    settings.enableReflex = OPNSessionBridgeBool(dictionary[@"enableReflex"], true);
    settings.lowLatencyMode = OPNSessionBridgeBool(dictionary[@"lowLatencyMode"]);
    settings.enableHdr = OPNSessionBridgeBool(dictionary[@"enableHdr"]);
    settings.microphoneMode = OPNSessionBridgeStdString(dictionary[@"microphoneMode"]);
    settings.microphoneDeviceId = OPNSessionBridgeStdString(dictionary[@"microphoneDeviceId"]);
    settings.microphonePushToTalkKeyCode = OPNSessionBridgeInt(dictionary[@"microphonePushToTalkKeyCode"], 9);
    settings.microphonePushToTalkModifierMask = OPNSessionBridgeInt(dictionary[@"microphonePushToTalkModifierMask"]);
    settings.gameVolume = OPNSessionBridgeDouble(dictionary[@"gameVolume"], 1.0);
    settings.microphoneVolume = OPNSessionBridgeDouble(dictionary[@"microphoneVolume"], 1.0);
    settings.keyboardLayout = OPNSessionBridgeStdString(dictionary[@"keyboardLayout"]);
    settings.gameLanguage = OPNSessionBridgeStdString(dictionary[@"gameLanguage"]);
    settings.accountLinked = OPNSessionBridgeBool(dictionary[@"accountLinked"], true);
    settings.selectedStore = OPNSessionBridgeStdString(dictionary[@"selectedStore"]);
    settings.networkTestSessionId = OPNSessionBridgeStdString(dictionary[@"networkTestSessionId"]);
    settings.networkType = OPNSessionBridgeStdString(dictionary[@"networkType"]);
    settings.networkLatencyMs = OPNSessionBridgeInt(dictionary[@"networkLatencyMs"], -1);
    settings.remoteControllersBitmap = (uint32_t)OPNSessionBridgeInt(dictionary[@"remoteControllersBitmap"]);
    settings.supportedHidDevices = (uint32_t)OPNSessionBridgeInt(dictionary[@"supportedHidDevices"]);
    NSArray *controllers = [dictionary[@"availableSupportedControllers"] isKindOfClass:[NSArray class]] ? dictionary[@"availableSupportedControllers"] : nil;
    for (id controller in controllers) settings.availableSupportedControllers.push_back(OPNSessionBridgeStdString(controller));
    return settings;
}

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

extern "C" void OPNSessionManagerBridgeSetAccessToken(NSString *token) {
    OPN::SessionManager::Shared().SetAccessToken(token.UTF8String ?: "");
}

extern "C" void OPNSessionManagerBridgeSetStreamingBaseUrl(NSString *url) {
    OPN::SessionManager::Shared().SetStreamingBaseUrl(url.UTF8String ?: "");
}

extern "C" void OPNSessionManagerBridgeGetActiveSessions(OPNSessionManagerActiveSessionsCompletion completion) {
    OPNSessionManagerActiveSessionsCompletion completionCopy = [completion copy];
    OPN::SessionManager::Shared().GetActiveSessions([completionCopy](bool ok, const std::vector<OPN::ActiveSessionEntry> &sessions, const std::string &error) {
        if (!completionCopy) return;
        NSMutableArray<NSDictionary *> *result = [NSMutableArray arrayWithCapacity:sessions.size()];
        for (const auto &session : sessions) {
            [result addObject:@{
                @"sessionId": OPNSessionBridgeString(session.sessionId),
                @"appId": @(session.appId),
                @"status": @(session.status),
                @"serverIp": OPNSessionBridgeString(session.serverIp),
                @"gpuType": OPNSessionBridgeString(session.gpuType),
                @"streamingBaseUrl": OPNSessionBridgeString(session.streamingBaseUrl),
                @"signalingUrl": OPNSessionBridgeString(session.signalingUrl),
            }];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completionCopy(ok ? YES : NO, result, OPNSessionBridgeString(error));
        });
    });
}

extern "C" void OPNSessionManagerBridgePollSession(NSString *sessionId, NSString *serverIp, OPNSessionManagerCompletion completion) {
    OPNSessionManagerCompletion completionCopy = [completion copy];
    OPN::SessionManager::Shared().PollSession(sessionId.UTF8String ?: "", serverIp.UTF8String ?: "", [completionCopy](bool ok, const OPN::SessionInfo &info, const std::string &error) {
        if (!completionCopy) return;
        NSDictionary *session = OPNSessionBridgeDictionary(info);
        dispatch_async(dispatch_get_main_queue(), ^{
            completionCopy(ok ? YES : NO, session, OPNSessionBridgeString(error));
        });
    });
}

extern "C" void OPNSessionManagerBridgeStopSession(NSString *sessionId, NSString *serverIp, OPNSessionManagerStopCompletion completion) {
    OPNSessionManagerStopCompletion completionCopy = [completion copy];
    OPN::SessionManager::Shared().StopSession(sessionId.UTF8String ?: "", serverIp.UTF8String ?: "", [completionCopy](bool ok, const std::string &error) {
        if (!completionCopy) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            completionCopy(ok ? YES : NO, OPNSessionBridgeString(error));
        });
    });
}

extern "C" void OPNSessionManagerBridgeClaimSession(NSString *sessionId,
                                                     NSString *serverIp,
                                                     NSString *appId,
                                                     NSDictionary *settings,
                                                     BOOL recoveryMode,
                                                     OPNSessionManagerCompletion completion) {
    OPNSessionManagerCompletion completionCopy = [completion copy];
    OPN::StreamSettings streamSettings = OPNSessionBridgeStreamSettings(settings);
    OPN::SessionManager::Shared().ClaimSession(sessionId.UTF8String ?: "", serverIp.UTF8String ?: "", appId.UTF8String ?: "", streamSettings, recoveryMode == YES, [completionCopy](bool ok, const OPN::SessionInfo &info, const std::string &error) {
        if (!completionCopy) return;
        NSDictionary *session = OPNSessionBridgeDictionary(info);
        dispatch_async(dispatch_get_main_queue(), ^{
            completionCopy(ok ? YES : NO, session, OPNSessionBridgeString(error));
        });
    });
}

extern "C" void OPNSessionManagerBridgeCreateSession(NSString *appId,
                                                      NSString *internalTitle,
                                                      NSDictionary *settings,
                                                      OPNSessionManagerCompletion completion) {
    OPNSessionManagerCompletion completionCopy = [completion copy];
    OPN::StreamSettings streamSettings = OPNSessionBridgeStreamSettings(settings);
    OPN::SessionManager::Shared().CreateSession(appId.UTF8String ?: "", internalTitle.UTF8String ?: "", streamSettings, [completionCopy](bool ok, const OPN::SessionInfo &info, const std::string &error) {
        if (!completionCopy) return;
        NSDictionary *session = OPNSessionBridgeDictionary(info);
        dispatch_async(dispatch_get_main_queue(), ^{
            completionCopy(ok ? YES : NO, session, OPNSessionBridgeString(error));
        });
    });
}

extern "C" void OPNSessionManagerBridgeReportSessionAd(NSDictionary *session,
                                                        NSString *adId,
                                                        NSString *action,
                                                        NSInteger watchedTimeInMs,
                                                        NSInteger pausedTimeInMs,
                                                        NSString *cancelReason,
                                                        OPNSessionManagerCompletion completion) {
    OPNSessionManagerCompletion completionCopy = [completion copy];
    OPN::SessionInfo sessionInfo = OPNSessionBridgeSessionInfo(session);
    OPN::SessionManager::Shared().ReportSessionAd(sessionInfo,
                                                  adId.UTF8String ?: "",
                                                  action.UTF8String ?: "",
                                                  (int)watchedTimeInMs,
                                                  (int)pausedTimeInMs,
                                                  cancelReason.UTF8String ?: "",
                                                  [completionCopy](bool ok, const OPN::SessionInfo &info, const std::string &error) {
        if (!completionCopy) return;
        NSDictionary *updatedSession = OPNSessionBridgeDictionary(info);
        dispatch_async(dispatch_get_main_queue(), ^{
            completionCopy(ok ? YES : NO, updatedSession, OPNSessionBridgeString(error));
        });
    });
}
