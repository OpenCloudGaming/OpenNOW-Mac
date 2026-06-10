#include "OPNLibWebRTCStreamSession.h"

#include "OPNLibWebRTCStreamSession.h"


#import <Foundation/Foundation.h>

#include <cctype>
#include <cstdlib>
#include <cstring>
#include <sstream>
#include <vector>

@interface OPNInputProtocolEncoder : NSObject
- (instancetype)init;
@end

namespace OPN {

bool LibWebRTCStreamSession::IsAvailable() {
#if defined(OPN_HAVE_LIBWEBRTC)
    return NSClassFromString(@"RTCPeerConnectionFactory") != nil;
#else
    return false;
#endif
}

}

typedef void (^OPNStreamSessionAnswerHandler)(NSString *sdp, NSString *nvstSdp);
typedef void (^OPNStreamSessionLocalIceCandidateHandler)(NSDictionary *candidate);
typedef void (^OPNStreamSessionStateHandler)(BOOL connected, NSString *errorMessage);

static OPN::IStreamSession *OPNRawStreamSession(void *session) {
    return static_cast<OPN::IStreamSession *>(session);
}

static NSString *OPNStreamStatsSnapshotString(const std::string &value) {
    if (value.empty()) return @"";
    NSString *string = [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding];
    return string ?: @"";
}

@interface OPNStreamStatsSnapshot : NSObject
- (instancetype)initWithAvailable:(BOOL)available
                        latencyMs:(double)latencyMs
                         jitterMs:(double)jitterMs
               inboundBitrateMbps:(double)inboundBitrateMbps
                packetLossPercent:(double)packetLossPercent
                     decodeTimeMs:(double)decodeTimeMs
                        renderFps:(double)renderFps
                   framesReceived:(uint64_t)framesReceived
                    framesDropped:(uint64_t)framesDropped
                      packetsLost:(int64_t)packetsLost
                              fps:(NSInteger)fps
                       resolution:(NSString *)resolution
                            codec:(NSString *)codec
       videoEnhancementActiveTier:(NSString *)videoEnhancementActiveTier
   videoEnhancementConfiguredTier:(NSString *)videoEnhancementConfiguredTier
 videoEnhancementSourceResolution:(NSString *)videoEnhancementSourceResolution
videoEnhancementDrawableResolution:(NSString *)videoEnhancementDrawableResolution
   videoEnhancementFallbackReason:(NSString *)videoEnhancementFallbackReason
      videoEnhancementDiagnostics:(NSString *)videoEnhancementDiagnostics
      videoEnhancementFrameTimeMs:(double)videoEnhancementFrameTimeMs
    videoEnhancementDroppedFrames:(uint64_t)videoEnhancementDroppedFrames;
@end

static std::string OPNStreamSessionStdString(id value) {
    if ([value isKindOfClass:[NSString class]]) return ((NSString *)value).UTF8String ?: "";
    if ([value isKindOfClass:[NSNumber class]]) return ((NSNumber *)value).stringValue.UTF8String ?: "";
    return "";
}

static int OPNStreamSessionInt(id value, int fallback = 0) {
    return [value respondsToSelector:@selector(intValue)] ? [value intValue] : fallback;
}

static double OPNStreamSessionDouble(id value, double fallback = 0.0) {
    return [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : fallback;
}

static bool OPNStreamSessionBool(id value, bool fallback = false) {
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : fallback;
}

static NSString *OPNStreamSessionStringFromStdString(const std::string &value) {
    if (value.empty()) return @"";
    NSString *string = [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding];
    return string ?: @"";
}

static NSDictionary *OPNStreamSessionIceCandidateDictionary(const OPN::IceCandidatePayload &candidate) {
    return @{
        @"candidate": OPNStreamSessionStringFromStdString(candidate.candidate),
        @"sdpMid": OPNStreamSessionStringFromStdString(candidate.sdpMid),
        @"sdpMLineIndex": @(candidate.sdpMLineIndex),
        @"usernameFragment": OPNStreamSessionStringFromStdString(candidate.usernameFragment),
    };
}

static OPN::SessionInfo OPNStreamSessionInfoFromDictionary(NSDictionary *dictionary) {
    OPN::SessionInfo info;
    if (![dictionary isKindOfClass:[NSDictionary class]]) return info;
    info.sessionId = OPNStreamSessionStdString(dictionary[@"sessionId"]);
    info.status = OPNStreamSessionInt(dictionary[@"status"]);
    info.queuePosition = OPNStreamSessionInt(dictionary[@"queuePosition"]);
    info.seatSetupStep = OPNStreamSessionInt(dictionary[@"seatSetupStep"]);
    info.progressState = (OPN::SessionProgressState)OPNStreamSessionInt(dictionary[@"progressState"]);
    info.zone = OPNStreamSessionStdString(dictionary[@"zone"]);
    info.streamingBaseUrl = OPNStreamSessionStdString(dictionary[@"streamingBaseUrl"]);
    info.serverIp = OPNStreamSessionStdString(dictionary[@"serverIp"]);
    info.signalingServer = OPNStreamSessionStdString(dictionary[@"signalingServer"]);
    info.signalingUrl = OPNStreamSessionStdString(dictionary[@"signalingUrl"]);
    info.gpuType = OPNStreamSessionStdString(dictionary[@"gpuType"]);
    NSDictionary *media = [dictionary[@"mediaConnectionInfo"] isKindOfClass:[NSDictionary class]] ? dictionary[@"mediaConnectionInfo"] : nil;
    info.mediaConnectionInfo.ip = OPNStreamSessionStdString(media[@"ip"]);
    info.mediaConnectionInfo.port = OPNStreamSessionInt(media[@"port"]);
    NSDictionary *profile = [dictionary[@"negotiatedStreamProfile"] isKindOfClass:[NSDictionary class]] ? dictionary[@"negotiatedStreamProfile"] : nil;
    info.negotiatedStreamProfile.resolution = OPNStreamSessionStdString(profile[@"resolution"]);
    info.negotiatedStreamProfile.fps = OPNStreamSessionInt(profile[@"fps"]);
    info.negotiatedStreamProfile.codec = OPNStreamSessionStdString(profile[@"codec"]);
    info.negotiatedStreamProfile.colorQuality = OPNStreamSessionStdString(profile[@"colorQuality"]);
    info.negotiatedStreamProfile.prefilterMode = OPNStreamSessionInt(profile[@"prefilterMode"], -1);
    info.negotiatedStreamProfile.prefilterSharpness = OPNStreamSessionInt(profile[@"prefilterSharpness"], -1);
    info.negotiatedStreamProfile.prefilterDenoise = OPNStreamSessionInt(profile[@"prefilterDenoise"], -1);
    info.negotiatedStreamProfile.prefilterModel = OPNStreamSessionInt(profile[@"prefilterModel"], -1);
    return info;
}

static OPN::StreamSettings OPNStreamSettingsFromDictionary(NSDictionary *dictionary) {
    OPN::StreamSettings settings;
    if (![dictionary isKindOfClass:[NSDictionary class]]) return settings;
    settings.resolution = OPNStreamSessionStdString(dictionary[@"resolution"]);
    settings.fps = OPNStreamSessionInt(dictionary[@"fps"], settings.fps);
    settings.codec = OPNStreamSessionStdString(dictionary[@"codec"]);
    settings.colorQuality = OPNStreamSessionStdString(dictionary[@"colorQuality"]);
    settings.maxBitrateMbps = OPNStreamSessionInt(dictionary[@"maxBitrateMbps"], settings.maxBitrateMbps);
    settings.prefilterMode = OPNStreamSessionInt(dictionary[@"prefilterMode"]);
    settings.prefilterSharpness = OPNStreamSessionInt(dictionary[@"prefilterSharpness"]);
    settings.prefilterDenoise = OPNStreamSessionInt(dictionary[@"prefilterDenoise"]);
    settings.prefilterModel = OPNStreamSessionInt(dictionary[@"prefilterModel"]);
    settings.enableL4S = OPNStreamSessionBool(dictionary[@"enableL4S"]);
    settings.enableReflex = OPNStreamSessionBool(dictionary[@"enableReflex"], true);
    settings.lowLatencyMode = OPNStreamSessionBool(dictionary[@"lowLatencyMode"]);
    settings.enableHdr = OPNStreamSessionBool(dictionary[@"enableHdr"]);
    settings.microphoneMode = OPNStreamSessionStdString(dictionary[@"microphoneMode"]);
    settings.microphoneDeviceId = OPNStreamSessionStdString(dictionary[@"microphoneDeviceId"]);
    settings.microphonePushToTalkKeyCode = OPNStreamSessionInt(dictionary[@"microphonePushToTalkKeyCode"], 9);
    settings.microphonePushToTalkModifierMask = OPNStreamSessionInt(dictionary[@"microphonePushToTalkModifierMask"]);
    settings.gameVolume = OPNStreamSessionDouble(dictionary[@"gameVolume"], 1.0);
    settings.microphoneVolume = OPNStreamSessionDouble(dictionary[@"microphoneVolume"], 1.0);
    settings.gameLanguage = OPNStreamSessionStdString(dictionary[@"gameLanguage"]);
    settings.accountLinked = OPNStreamSessionBool(dictionary[@"accountLinked"], true);
    settings.selectedStore = OPNStreamSessionStdString(dictionary[@"selectedStore"]);
    settings.networkTestSessionId = OPNStreamSessionStdString(dictionary[@"networkTestSessionId"]);
    settings.networkType = OPNStreamSessionStdString(dictionary[@"networkType"]);
    settings.networkLatencyMs = OPNStreamSessionInt(dictionary[@"networkLatencyMs"], -1);
    settings.remoteControllersBitmap = (uint32_t)OPNStreamSessionInt(dictionary[@"remoteControllersBitmap"]);
    NSArray *controllers = [dictionary[@"availableSupportedControllers"] isKindOfClass:[NSArray class]] ? dictionary[@"availableSupportedControllers"] : nil;
    for (id controller in controllers) settings.availableSupportedControllers.push_back(OPNStreamSessionStdString(controller));
    return settings;
}

static bool OPNStreamSessionIsDottedIp(const std::string &value) {
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

static std::string OPNStreamSessionExtractPublicIp(const std::string &hostOrIp) {
    if (OPNStreamSessionIsDottedIp(hostOrIp)) return hostOrIp;
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

static std::string OPNStreamSessionExtractIceUfragFromOffer(const std::string &sdp) {
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

struct OPNStreamSessionIceMediaTarget {
    std::string sdpMid;
    int sdpMLineIndex = 0;
};

static OPNStreamSessionIceMediaTarget OPNStreamSessionExtractVideoIceTargetFromOffer(const std::string &sdp) {
    OPNStreamSessionIceMediaTarget target;
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

static void OPNInjectManualStreamSessionIceCandidate(OPN::IStreamSession *session,
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

    std::string ip = OPNStreamSessionExtractPublicIp(sessionInfo.mediaConnectionInfo.ip);
    int port = sessionInfo.mediaConnectionInfo.port;
    if (ip.empty() || port <= 0) {
        OPNLogInfo(@"[StreamVC] No valid mediaConnectionInfo for manual ICE candidate (ip=%s, port=%d)", sessionInfo.mediaConnectionInfo.ip.c_str(), port);
        return;
    }

    OPNStreamSessionIceMediaTarget target = OPNStreamSessionExtractVideoIceTargetFromOffer(offerSdpString);
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

static void OPNStartStreamSession(OPN::IStreamSession *session,
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
        answerHandlerCopy(OPNStreamSessionStringFromStdString(answer.sdp),
                          OPNStreamSessionStringFromStdString(answer.nvstSdp));
    });

    session->OnIceCandidateReady([localIceCandidateHandlerCopy](const OPN::IceCandidatePayload &candidate) {
        if (!localIceCandidateHandlerCopy) return;
        localIceCandidateHandlerCopy(OPNStreamSessionIceCandidateDictionary(candidate));
    });

    session->Start(sessionInfo, offerSdpString, settings, [stateHandlerCopy](bool connected, const std::string &streamError) {
        if (!stateHandlerCopy) return;
        stateHandlerCopy(connected ? YES : NO, OPNStreamSessionStringFromStdString(streamError));
    });
}

extern "C" BOOL OPNStreamSessionHandleBackendAvailable(void) {
    return OPN::LibWebRTCStreamSession::IsAvailable() ? YES : NO;
}

extern "C" NSUInteger OPNStreamSessionHandleMaxGamepadControllers(void) {
    return (NSUInteger)OPN::Input::GAMEPAD_MAX_CONTROLLERS;
}

extern "C" NSString *OPNStreamSessionHandleIceUfragFromOfferSdp(NSString *offerSdp) {
    return OPNStreamSessionStringFromStdString(OPNStreamSessionExtractIceUfragFromOffer(offerSdp.UTF8String ?: ""));
}

extern "C" void OPNStreamSessionInjectManualIceCandidate(void *session,
                                                          NSDictionary *sessionInfo,
                                                          NSString *offerSdp,
                                                          NSString *serverIceUfrag) {
    OPN::SessionInfo info = OPNStreamSessionInfoFromDictionary(sessionInfo);
    OPNInjectManualStreamSessionIceCandidate(OPNRawStreamSession(session), info, offerSdp, serverIceUfrag);
}

extern "C" void OPNStreamSessionStart(void *session,
                                       NSDictionary *sessionInfo,
                                       NSString *offerSdp,
                                       NSDictionary *settings,
                                       OPNStreamSessionAnswerHandler answerHandler,
                                       OPNStreamSessionLocalIceCandidateHandler localIceCandidateHandler,
                                       OPNStreamSessionStateHandler stateHandler) {
    OPN::SessionInfo info = OPNStreamSessionInfoFromDictionary(sessionInfo);
    OPN::StreamSettings streamSettings = OPNStreamSettingsFromDictionary(settings);
    OPNStartStreamSession(OPNRawStreamSession(session), info, offerSdp, streamSettings, answerHandler, localIceCandidateHandler, stateHandler);
}

extern "C" void *OPNStreamSessionHandleCreateRawSession(void) {
    if (!OPN::LibWebRTCStreamSession::IsAvailable()) return nullptr;
    return new OPN::LibWebRTCStreamSession();
}

extern "C" void OPNStreamSessionHandleReleaseRawSession(void *session) {
    OPN::IStreamSession *rawSession = OPNRawStreamSession(session);
    if (!rawSession) return;
    rawSession->Stop();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        delete rawSession;
    });
}

extern "C" BOOL OPNStreamSessionHandleInputReady(void *session) {
    OPN::IStreamSession *rawSession = OPNRawStreamSession(session);
    return rawSession && rawSession->InputReady() ? YES : NO;
}

extern "C" void OPNStreamSessionHandleSetNativeWindow(void *session, void *nativeWindow) {
    OPN::IStreamSession *rawSession = OPNRawStreamSession(session);
    if (!rawSession) return;
    rawSession->SetNativeWindow(nativeWindow);
}

extern "C" void OPNStreamSessionHandleSetMaxBitrateMbps(void *session, NSInteger mbps) {
    OPN::IStreamSession *rawSession = OPNRawStreamSession(session);
    if (!rawSession) return;
    rawSession->SetMaxBitrateMbps((int)mbps);
}

extern "C" void OPNStreamSessionHandleAddRemoteIceCandidatePayload(void *session, NSDictionary *payload) {
    OPN::IStreamSession *rawSession = OPNRawStreamSession(session);
    if (!rawSession) return;
    OPN::IceCandidatePayload candidate;
    NSString *candidateText = [payload[@"candidate"] isKindOfClass:[NSString class]] ? payload[@"candidate"] : @"";
    NSString *sdpMid = [payload[@"sdpMid"] isKindOfClass:[NSString class]] ? payload[@"sdpMid"] : @"";
    NSNumber *sdpMLineIndex = [payload[@"sdpMLineIndex"] isKindOfClass:[NSNumber class]] ? payload[@"sdpMLineIndex"] : nil;
    NSString *usernameFragment = [payload[@"usernameFragment"] isKindOfClass:[NSString class]] ? payload[@"usernameFragment"] : @"";
    candidate.candidate = candidateText.UTF8String ?: "";
    candidate.sdpMid = sdpMid.UTF8String ?: "";
    candidate.sdpMLineIndex = sdpMLineIndex ? sdpMLineIndex.intValue : 0;
    candidate.usernameFragment = usernameFragment.UTF8String ?: "";
    rawSession->AddRemoteIceCandidate(candidate);
}

extern "C" OPNStreamStatsSnapshot *OPNStreamSessionHandleLatestStatsSnapshot(void *session) {
    OPN::IStreamSession *rawSession = OPNRawStreamSession(session);
    OPN::StreamStats stats;
    if (rawSession) {
        rawSession->RequestStats();
        stats = rawSession->GetLatestStats();
    }
    return [[OPNStreamStatsSnapshot alloc] initWithAvailable:stats.available ? YES : NO
                                                  latencyMs:stats.latencyMs
                                                   jitterMs:stats.jitterMs
                                         inboundBitrateMbps:stats.inboundBitrateMbps
                                          packetLossPercent:stats.packetLossPercent
                                               decodeTimeMs:stats.decodeTimeMs
                                                  renderFps:stats.renderFps
                                             framesReceived:stats.framesReceived
                                              framesDropped:stats.framesDropped
                                                packetsLost:stats.packetsLost
                                                        fps:stats.fps
                                                 resolution:OPNStreamStatsSnapshotString(stats.resolution)
                                                      codec:OPNStreamStatsSnapshotString(stats.codec)
                                 videoEnhancementActiveTier:OPNStreamStatsSnapshotString(stats.videoEnhancementActiveTier)
                             videoEnhancementConfiguredTier:OPNStreamStatsSnapshotString(stats.videoEnhancementConfiguredTier)
                           videoEnhancementSourceResolution:OPNStreamStatsSnapshotString(stats.videoEnhancementSourceResolution)
                         videoEnhancementDrawableResolution:OPNStreamStatsSnapshotString(stats.videoEnhancementDrawableResolution)
                             videoEnhancementFallbackReason:OPNStreamStatsSnapshotString(stats.videoEnhancementFallbackReason)
                                videoEnhancementDiagnostics:OPNStreamStatsSnapshotString(stats.videoEnhancementDiagnostics)
                                videoEnhancementFrameTimeMs:stats.videoEnhancementFrameTimeMs
                              videoEnhancementDroppedFrames:stats.videoEnhancementDroppedFrames];
}

extern "C" void OPNStreamSessionHandleSendMouseMove(void *session, int16_t dx, int16_t dy) {
    OPN::IStreamSession *rawSession = OPNRawStreamSession(session);
    if (!rawSession) return;
    rawSession->SendMouseMove(dx, dy);
}

void OPNSendStreamSessionGamepadState(OPN::IStreamSession *session,
                                      uint16_t controllerId,
                                      uint16_t buttons,
                                      uint8_t leftTrigger,
                                      uint8_t rightTrigger,
                                      int16_t leftStickX,
                                      int16_t leftStickY,
                                      int16_t rightStickX,
                                      int16_t rightStickY,
                                      bool connected,
                                      uint16_t bitmap,
                                      uint64_t timestampUs) {
    if (!session) return;
    OPN::Input::GamepadState state;
    state.controllerId = controllerId;
    state.buttons = buttons;
    state.leftTrigger = leftTrigger;
    state.rightTrigger = rightTrigger;
    state.leftStickX = leftStickX;
    state.leftStickY = leftStickY;
    state.rightStickX = rightStickX;
    state.rightStickY = rightStickY;
    state.connected = connected;
    state.timestampUs = timestampUs;
    session->SendGamepadState(state, bitmap);
}

namespace OPN {

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
    OPNInputProtocolEncoder *encoder = [[OPNInputProtocolEncoder alloc] init];
    m_inputEncoder = (__bridge_retained void *)encoder;
    m_callbackLiveness = std::make_shared<std::atomic_bool>(true);
}

LibWebRTCStreamSession::~LibWebRTCStreamSession() {
    Stop();
    if (m_statsQueue) {
        dispatch_queue_t statsQueue = (__bridge_transfer dispatch_queue_t)m_statsQueue;
        m_statsQueue = nullptr;
        (void)statsQueue;
    }
    if (m_inputEncoder) {
        OPNInputProtocolEncoder *encoder = (__bridge_transfer OPNInputProtocolEncoder *)m_inputEncoder;
        m_inputEncoder = nullptr;
        (void)encoder;
    }
}

}
