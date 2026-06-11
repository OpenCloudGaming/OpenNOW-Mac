#include "OPNLibWebRTCStreamSession.h"

#include "OPNLibWebRTCStreamSession.h"


#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

#include <cctype>
#include <cstdlib>
#include <cstring>
#include <sstream>
#include <vector>

@class OPNLibWebRTCSessionImpl;

@interface OPNLibWebRTCInput : NSObject
- (instancetype)initWithOwner:(void *)owner;
- (void)sendInputData:(NSData *)data partiallyReliable:(BOOL)partiallyReliable lowLatencyMode:(BOOL)lowLatencyMode sessionImpl:(OPNLibWebRTCSessionImpl *)sessionImpl;
- (void)createInputChannelWithSessionImpl:(OPNLibWebRTCSessionImpl *)sessionImpl;
- (BOOL)isInputReady;
- (void)sendKeyWithKeycode:(uint16_t)keycode scancode:(uint16_t)scancode modifiers:(uint16_t)modifiers down:(BOOL)down sessionImpl:(OPNLibWebRTCSessionImpl *)sessionImpl;
- (void)sendMouseMoveWithDx:(int16_t)dx dy:(int16_t)dy lowLatencyMode:(BOOL)lowLatencyMode sessionImpl:(OPNLibWebRTCSessionImpl *)sessionImpl;
- (void)sendMouseButtonWithButton:(uint8_t)button down:(BOOL)down sessionImpl:(OPNLibWebRTCSessionImpl *)sessionImpl;
- (void)sendMouseWheelWithDelta:(int16_t)delta sessionImpl:(OPNLibWebRTCSessionImpl *)sessionImpl;
- (void)sendUtf8Text:(NSString *)text sessionImpl:(OPNLibWebRTCSessionImpl *)sessionImpl;
- (void)sendGamepadStateWithControllerId:(uint16_t)controllerId
                                  buttons:(uint16_t)buttons
                              leftTrigger:(uint8_t)leftTrigger
                             rightTrigger:(uint8_t)rightTrigger
                               leftStickX:(int16_t)leftStickX
                               leftStickY:(int16_t)leftStickY
                              rightStickX:(int16_t)rightStickX
                              rightStickY:(int16_t)rightStickY
                              timestampUs:(uint64_t)timestampUs
                                   bitmap:(uint16_t)bitmap
                           lowLatencyMode:(BOOL)lowLatencyMode
                              sessionImpl:(OPNLibWebRTCSessionImpl *)sessionImpl;
- (void)handleDataChannelStateWithLabel:(NSString *)label open:(BOOL)open;
- (void)handleDataChannelMessageWithLabel:(NSString *)label data:(NSData *)data sessionImpl:(OPNLibWebRTCSessionImpl *)sessionImpl;
- (void)stop;
@end

@interface OPNLibWebRTCAudio : NSObject
- (instancetype)initWithOwner:(void *)owner;
- (void)setMicrophoneEnabled:(BOOL)enabled sessionImpl:(OPNLibWebRTCSessionImpl *)sessionImpl;
- (void)setGameVolume:(double)volume sessionImpl:(OPNLibWebRTCSessionImpl *)sessionImpl;
- (void)setMicrophoneVolume:(double)volume sessionImpl:(OPNLibWebRTCSessionImpl *)sessionImpl;
- (void)refreshAudioDevicesWithSessionImpl:(OPNLibWebRTCSessionImpl *)sessionImpl;
- (void)startAudioDeviceMonitoring;
- (void)stopAudioDeviceMonitoring;
- (void)handleAudioDeviceChangeWithSessionImpl:(OPNLibWebRTCSessionImpl *)sessionImpl;
- (void)startMicrophoneLevelPollingWithSessionImpl:(OPNLibWebRTCSessionImpl *)sessionImpl statsQueue:(dispatch_queue_t)statsQueue;
- (void)stopMicrophoneLevelPolling;
@property(nonatomic, readonly) double gameVolume;
@end

@interface OPNLibWebRTCStats : NSObject
- (instancetype)initWithOwner:(void *)owner;
- (void)requestStatsWithSessionImpl:(OPNLibWebRTCSessionImpl *)sessionImpl queue:(dispatch_queue_t)queue;
- (void)startPollingWithSessionImpl:(OPNLibWebRTCSessionImpl *)sessionImpl queue:(dispatch_queue_t)queue;
- (void)stopPolling;
- (void)applyRuntimeBitrateLimitMbps:(NSInteger)mbps reason:(NSString *)reason sessionImpl:(OPNLibWebRTCSessionImpl *)sessionImpl;
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

extern "C" BOOL OPNMetalVideoViewOwnerLowLatencyMode(void *owner) {
    OPN::LibWebRTCStreamSession *session = owner ? static_cast<OPN::LibWebRTCStreamSession *>(owner) : nullptr;
    return session && session->LowLatencyMode() ? YES : NO;
}

extern "C" void OPNMetalVideoViewOwnerLocalVideoEnhancement(void *owner, int *mode, int *sharpness, int *denoise, int *targetHeight) {
    if (mode) *mode = 0;
    if (sharpness) *sharpness = 0;
    if (denoise) *denoise = 0;
    if (targetHeight) *targetHeight = 2160;
    OPN::LibWebRTCStreamSession *session = owner ? static_cast<OPN::LibWebRTCStreamSession *>(owner) : nullptr;
    if (!session) return;
    int localMode = 0;
    int localSharpness = 0;
    int localDenoise = 0;
    int localTargetHeight = 2160;
    session->LocalVideoEnhancement(localMode, localSharpness, localDenoise, localTargetHeight);
    if (mode) *mode = localMode;
    if (sharpness) *sharpness = localSharpness;
    if (denoise) *denoise = localDenoise;
    if (targetHeight) *targetHeight = localTargetHeight;
}

extern "C" void OPNMetalVideoViewOwnerHandleVideoFrame(void *owner, void *frame) {
    OPN::LibWebRTCStreamSession *session = owner ? static_cast<OPN::LibWebRTCStreamSession *>(owner) : nullptr;
    if (session && frame) session->HandleVideoFrame(frame);
}

extern "C" BOOL OPNMetalVideoViewOwnerWantsEnhancedVideoFrames(void *owner) {
    OPN::LibWebRTCStreamSession *session = owner ? static_cast<OPN::LibWebRTCStreamSession *>(owner) : nullptr;
    return session && session->WantsEnhancedVideoFrames() ? YES : NO;
}

extern "C" void OPNMetalVideoViewOwnerHandleEnhancedVideoFrame(void *owner, CVPixelBufferRef pixelBuffer) {
    OPN::LibWebRTCStreamSession *session = owner ? static_cast<OPN::LibWebRTCStreamSession *>(owner) : nullptr;
    if (session && pixelBuffer) session->HandleEnhancedVideoFrame(pixelBuffer);
}

extern "C" void OPNMetalVideoViewOwnerSetVideoRenderDiagnostics(void *owner,
                                                                 NSString *pixelFormat,
                                                                 NSString *renderMode,
                                                                 NSString *frameSource,
                                                                 NSString *renderPath,
                                                                 NSString *fallback,
                                                                 NSString *enhancementConfiguredTier,
                                                                 NSString *enhancementActiveTier,
                                                                 NSString *enhancementFallbackReason,
                                                                 NSString *enhancementSourceResolution,
                                                                 NSString *enhancementDrawableResolution,
                                                                 NSString *enhancementDiagnostics,
                                                                 double enhancementFrameTimeMs,
                                                                 uint64_t enhancementDroppedFrames) {
    OPN::LibWebRTCStreamSession *session = owner ? static_cast<OPN::LibWebRTCStreamSession *>(owner) : nullptr;
    if (!session) return;
    auto stringValue = [](NSString *value) -> std::string {
        return value ? std::string(value.UTF8String ?: "") : std::string();
    };
    session->SetVideoRenderDiagnostics(stringValue(pixelFormat),
                                       stringValue(renderMode),
                                       stringValue(frameSource),
                                       stringValue(renderPath),
                                       stringValue(fallback),
                                       stringValue(enhancementConfiguredTier),
                                       stringValue(enhancementActiveTier),
                                       stringValue(enhancementFallbackReason),
                                       stringValue(enhancementSourceResolution),
                                       stringValue(enhancementDrawableResolution),
                                       stringValue(enhancementDiagnostics),
                                       enhancementFrameTimeMs,
                                       enhancementDroppedFrames);
}

extern "C" void OPNLibWebRTCSessionOwnerCancelDisconnectGraceTimer(void *owner) {
    OPN::LibWebRTCStreamSession *session = owner ? static_cast<OPN::LibWebRTCStreamSession *>(owner) : nullptr;
    if (session) session->CancelDisconnectGraceTimer();
}

extern "C" void OPNLibWebRTCSessionOwnerStartDisconnectGraceTimer(void *owner, NSString *reason) {
    OPN::LibWebRTCStreamSession *session = owner ? static_cast<OPN::LibWebRTCStreamSession *>(owner) : nullptr;
    if (session) session->StartDisconnectGraceTimer(std::string(reason.UTF8String ?: ""));
}

extern "C" void OPNLibWebRTCSessionOwnerHandleConnectionState(void *owner, BOOL connected, NSString *error) {
    OPN::LibWebRTCStreamSession *session = owner ? static_cast<OPN::LibWebRTCStreamSession *>(owner) : nullptr;
    if (session) session->HandleConnectionState(connected ? true : false, std::string(error.UTF8String ?: ""));
}

extern "C" void OPNLibWebRTCSessionOwnerHandleLocalIceCandidate(void *owner, NSString *candidate, NSString *sdpMid, int sdpMLineIndex) {
    OPN::LibWebRTCStreamSession *session = owner ? static_cast<OPN::LibWebRTCStreamSession *>(owner) : nullptr;
    if (!session) return;
    OPN::IceCandidatePayload payload;
    payload.candidate = candidate.UTF8String ?: "";
    payload.sdpMid = sdpMid.UTF8String ?: "";
    payload.sdpMLineIndex = sdpMLineIndex;
    session->HandleLocalIceCandidate(payload);
}

extern "C" void *OPNLibWebRTCSessionOwnerNativeWindowHandle(void *owner) {
    OPN::LibWebRTCStreamSession *session = owner ? static_cast<OPN::LibWebRTCStreamSession *>(owner) : nullptr;
    return session ? session->NativeWindowHandle() : nullptr;
}

extern "C" int OPNLibWebRTCSessionOwnerTargetFps(void *owner) {
    OPN::LibWebRTCStreamSession *session = owner ? static_cast<OPN::LibWebRTCStreamSession *>(owner) : nullptr;
    return session ? session->TargetFps() : 60;
}

extern "C" double OPNLibWebRTCSessionOwnerGameVolume(void *owner) {
    OPN::LibWebRTCStreamSession *session = owner ? static_cast<OPN::LibWebRTCStreamSession *>(owner) : nullptr;
    return session ? session->GameVolume() : 1.0;
}

extern "C" void OPNLibWebRTCSessionOwnerSetVideoRendererState(void *owner, NSString *sink, NSString *pipelineMode) {
    OPN::LibWebRTCStreamSession *session = owner ? static_cast<OPN::LibWebRTCStreamSession *>(owner) : nullptr;
    if (session) session->SetVideoRendererState(std::string(sink.UTF8String ?: ""), std::string(pipelineMode.UTF8String ?: ""));
}

extern "C" void OPNLibWebRTCSessionOwnerHandleDataChannelState(void *owner, NSString *label, BOOL open) {
    OPN::LibWebRTCStreamSession *session = owner ? static_cast<OPN::LibWebRTCStreamSession *>(owner) : nullptr;
    if (session) session->HandleDataChannelState(std::string(label.UTF8String ?: ""), open ? true : false);
}

extern "C" BOOL OPNLibWebRTCSessionOwnerInputReady(void *owner) {
    OPN::LibWebRTCStreamSession *session = owner ? static_cast<OPN::LibWebRTCStreamSession *>(owner) : nullptr;
    return session && session->InputReady() ? YES : NO;
}

extern "C" void OPNLibWebRTCSessionOwnerHandleDataChannelMessage(void *owner, NSString *label, NSData *data) {
    OPN::LibWebRTCStreamSession *session = owner ? static_cast<OPN::LibWebRTCStreamSession *>(owner) : nullptr;
    if (!session || !data) return;
    session->HandleDataChannelMessage(std::string(label.UTF8String ?: ""), static_cast<const uint8_t *>(data.bytes), data.length);
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
    OPNLibWebRTCInput *inputController = [[OPNLibWebRTCInput alloc] initWithOwner:this];
    m_inputController = (__bridge_retained void *)inputController;
    OPNLibWebRTCAudio *audioController = [[OPNLibWebRTCAudio alloc] initWithOwner:this];
    m_audioController = (__bridge_retained void *)audioController;
    OPNLibWebRTCStats *statsController = [[OPNLibWebRTCStats alloc] initWithOwner:this];
    m_statsController = (__bridge_retained void *)statsController;
    m_callbackLiveness = std::make_shared<std::atomic_bool>(true);
}

LibWebRTCStreamSession::~LibWebRTCStreamSession() {
    Stop();
    if (m_statsQueue) {
        dispatch_queue_t statsQueue = (__bridge_transfer dispatch_queue_t)m_statsQueue;
        m_statsQueue = nullptr;
        (void)statsQueue;
    }
    if (m_inputController) {
        OPNLibWebRTCInput *inputController = (__bridge_transfer OPNLibWebRTCInput *)m_inputController;
        [inputController stop];
        m_inputController = nullptr;
    }
    if (m_audioController) {
        OPNLibWebRTCAudio *audioController = (__bridge_transfer OPNLibWebRTCAudio *)m_audioController;
        [audioController stopAudioDeviceMonitoring];
        [audioController stopMicrophoneLevelPolling];
        m_audioController = nullptr;
    }
    if (m_statsController) {
        OPNLibWebRTCStats *statsController = (__bridge_transfer OPNLibWebRTCStats *)m_statsController;
        [statsController stopPolling];
        m_statsController = nullptr;
    }
}

}

#include "OPNLibWebRTCStreamSession.h"

#if defined(OPN_HAVE_LIBWEBRTC)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-umbrella"
#import <WebRTC/WebRTC.h>
#import <WebRTC/RTCAudioDevice.h>
#pragma clang diagnostic pop

@interface OPNCoreAudioRTCDevice : NSObject <RTCAudioDevice>
@property(nonatomic, assign) void *owner;
- (void)handleDefaultDeviceChange;
@end

@interface OPNLibWebRTCSessionImpl : NSObject <RTCPeerConnectionDelegate, RTCDataChannelDelegate>
- (instancetype)initWithOwner:(void *)owner;
@property(nonatomic, assign) void *owner;
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

@interface OPNWebRTCCodecSupport : NSObject
+ (BOOL)supportsCodecWithFactory:(RTCPeerConnectionFactory *)factory normalizedCodec:(NSString *)normalizedCodec;
+ (NSDictionary *)h265ReceiverSupportWithFactory:(RTCPeerConnectionFactory *)factory;
+ (BOOL)applyVideoCodecPreferenceWithFactory:(RTCPeerConnectionFactory *)factory peerConnection:(RTCPeerConnection *)peerConnection normalizedCodec:(NSString *)normalizedCodec;
@end
#endif

#include <algorithm>
#include <cctype>
#include <climits>
#include <cstdlib>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

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

struct OPNLibWebRTCIceCredentials {
    std::string ufrag;
    std::string pwd;
    std::string fingerprint;
};

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

namespace OPN {

static constexpr int OPNPartialReliableInputLifetimeMs = 5;

static bool OPNNvstStartsWith(const std::string &value, const char *prefix) {
    const size_t prefixLen = std::char_traits<char>::length(prefix);
    return value.size() >= prefixLen && value.compare(0, prefixLen, prefix) == 0;
}

static std::vector<std::string> OPNSplitResolution(const std::string &resolution) {
    const size_t x = resolution.find('x');
    if (x == std::string::npos) return {"1920", "1080"};
    std::string width = resolution.substr(0, x);
    std::string height = resolution.substr(x + 1);
    if (width.empty() || height.empty()) return {"1920", "1080"};
    return {width, height};
}

static int OPNStringToPositiveInt(const std::string &value, int fallback) {
    if (value.empty()) return fallback;
    char *end = nullptr;
    long parsed = strtol(value.c_str(), &end, 10);
    if (end == value.c_str() || parsed <= 0 || parsed > INT_MAX) return fallback;
    return (int)parsed;
}

static std::string OPNBuildNvstSdp(const StreamSettings &settings, const OPNLibWebRTCIceCredentials &credentials) {
    std::vector<std::string> resolution = OPNSplitResolution(settings.resolution);
    const int width = OPNStringToPositiveInt(resolution[0], 1920);
    const int height = OPNStringToPositiveInt(resolution[1], 1080);
    const int maxBitrateKbps = std::max(1000, settings.maxBitrateMbps * 1000);
    const int minBitrateKbps = std::max(5000, maxBitrateKbps * 35 / 100);
    const int initialBitrateKbps = std::max(minBitrateKbps, maxBitrateKbps * 70 / 100);
    const int bitDepth = OPNNvstStartsWith(settings.colorQuality, "10bit") ? 10 : 8;
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
        "v=0", "o=SdpTest test_id_13 14 IN IPv4 127.0.0.1", "s=-", "t=0 0",
        "a=general.icePassword:" + credentials.pwd,
        "a=general.iceUserNameFragment:" + credentials.ufrag,
        "a=general.dtlsFingerprint:" + credentials.fingerprint,
        "m=video 0 RTP/AVP", "a=msid:fbc-video-0", "a=vqos.fec.rateDropWindow:10",
        "a=vqos.fec.minRequiredFecPackets:2", "a=vqos.fec.repairMinPercent:5", "a=vqos.fec.repairPercent:5",
        "a=vqos.fec.repairMaxPercent:35", "a=vqos.dynamicStreamingMode:0", "a=vqos.drc.enable:0",
        "a=vqos.dfc.enable:0", "a=vqos.dfc.adjustResAndFps:0", "a=video.dx9EnableNv12:1",
        "a=video.dx9EnableHdr:1", "a=vqos.qpg.enable:1", "a=vqos.resControl.qp.qpg.featureSetting:7",
        "a=bwe.useOwdCongestionControl:1", "a=video.enableRtpNack:1", "a=vqos.bw.txRxLag.minFeedbackTxDeltaMs:200",
        "a=vqos.drc.bitrateIirFilterFactor:18", "a=video.packetSize:1140", "a=packetPacing.minNumPacketsPerGroup:15",
    };

    if (isHighFps) {
        lines.insert(lines.end(), {
            "a=bwe.iirFilterFactor:8", "a=video.encoderFeatureSetting:47", "a=video.encoderPreset:6",
            "a=vqos.resControl.cpmRtc.badNwSkipFramesCount:600", "a=vqos.resControl.cpmRtc.decodeTimeThresholdMs:9",
            std::string("a=video.fbcDynamicFpsGrabTimeoutMs:") + (is120Fps ? "6" : "18"),
            std::string("a=vqos.resControl.cpmRtc.serverResolutionUpdateCoolDownCount:") + (is120Fps ? "6000" : "12000"),
        });
    }

    if (is240Fps) {
        lines.insert(lines.end(), {"a=video.enableNextCaptureMode:1", "a=vqos.maxStreamFpsEstimate:240", "a=video.videoSplitEncodeStripsPerFrame:3", "a=video.updateSplitEncodeStateDynamically:1"});
    }

    lines.insert(lines.end(), {
        "a=vqos.adjustStreamingFpsDuringOutOfFocus:1", "a=vqos.resControl.cpmRtc.ignoreOutOfFocusWindowState:1",
        "a=vqos.resControl.perfHistory.rtcIgnoreOutOfFocusWindowState:1", "a=vqos.resControl.cpmRtc.featureMask:0",
        "a=vqos.resControl.cpmRtc.enable:0", "a=vqos.resControl.cpmRtc.minResolutionPercent:100",
        "a=vqos.resControl.cpmRtc.resolutionChangeHoldonMs:999999", std::string("a=packetPacing.numGroups:") + (is120Fps ? "3" : "5"),
        "a=packetPacing.maxDelayUs:1000", "a=packetPacing.minNumPacketsFrame:10", "a=video.rtpNackQueueLength:1024",
        "a=video.rtpNackQueueMaxPackets:512", "a=video.rtpNackMaxPacketCount:25", "a=vqos.drc.qpMaxResThresholdAdj:4",
        "a=vqos.grc.qpMaxResThresholdAdj:4", "a=vqos.drc.iirFilterFactor:100",
    });

    if (isAv1) {
        lines.insert(lines.end(), {
            "a=vqos.drc.minQpHeadroom:20", "a=vqos.drc.lowerQpThreshold:100", "a=vqos.drc.upperQpThreshold:200",
            "a=vqos.drc.minAdaptiveQpThreshold:180", "a=vqos.drc.qpCodecThresholdAdj:0", "a=vqos.drc.qpMaxResThresholdAdj:20",
            "a=vqos.dfc.minQpHeadroom:20", "a=vqos.dfc.qpLowerLimit:100", "a=vqos.dfc.qpMaxUpperLimit:200",
            "a=vqos.dfc.qpMinUpperLimit:180", "a=vqos.dfc.qpMaxResThresholdAdj:20", "a=vqos.dfc.qpCodecThresholdAdj:0",
            "a=vqos.grc.minQpHeadroom:20", "a=vqos.grc.lowerQpThreshold:100", "a=vqos.grc.upperQpThreshold:200",
            "a=vqos.grc.minAdaptiveQpThreshold:180", "a=vqos.grc.qpMaxResThresholdAdj:20", "a=vqos.grc.qpCodecThresholdAdj:0",
            "a=video.minQp:25", "a=video.enableAv1RcPrecisionFactor:1",
        });
    }

    lines.insert(lines.end(), {
        "a=video.clientViewportWd:" + std::to_string(width), "a=video.clientViewportHt:" + std::to_string(height),
        "a=video.maxFPS:" + std::to_string(settings.fps), "a=video.initialBitrateKbps:" + std::to_string(initialBitrateKbps),
        "a=video.initialPeakBitrateKbps:" + std::to_string(maxBitrateKbps), "a=vqos.bw.maximumBitrateKbps:" + std::to_string(maxBitrateKbps),
        "a=vqos.bw.minimumBitrateKbps:" + std::to_string(minBitrateKbps), "a=vqos.bw.peakBitrateKbps:" + std::to_string(maxBitrateKbps),
        "a=vqos.bw.serverPeakBitrateKbps:" + std::to_string(maxBitrateKbps), "a=vqos.bw.enableBandwidthEstimation:1",
        "a=vqos.bw.disableBitrateLimit:0", "a=vqos.grc.maximumBitrateKbps:" + std::to_string(maxBitrateKbps),
        "a=vqos.grc.enable:0", "a=video.maxNumReferenceFrames:4", "a=video.mapRtpTimestampsToFrames:1",
        "a=video.encoderCscMode:3", "a=video.dynamicRangeMode:0", "a=video.bitDepth:" + std::to_string(bitDepth),
        std::string("a=video.scalingFeature1:") + (isAv1 ? "1" : "0"), "a=video.prefilterParams.prefilterMode:" + std::to_string(prefilterMode),
        "a=video.prefilterParams.prefilterModel:" + std::to_string(prefilterModel), "a=video.prefilterParams.sharpnessLevel:" + std::to_string(prefilterSharpness),
        "a=video.prefilterParams.denoiseLevel:" + std::to_string(prefilterDenoise), "m=audio 0 RTP/AVP", "a=msid:audio",
        "m=mic 0 RTP/AVP", "a=msid:mic", "a=rtpmap:0 PCMU/8000", "m=application 0 RTP/AVP", "a=msid:input_1",
        "a=ri.partialReliableThresholdMs:" + std::to_string(OPNPartialReliableInputLifetimeMs), "a=ri.hidDeviceMask:4294967295",
        "a=ri.enablePartiallyReliableTransferGamepad:15", "a=ri.enablePartiallyReliableTransferHid:4294967295", "",
    });

    std::string result;
    for (const std::string &line : lines) {
        result += line;
        result += '\n';
    }
    return result;
}

static NSString *OPNStringToNSString(const std::string &value) {
    return [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding] ?: @"";
}

static std::string OPNNSStringToString(NSString *value) {
    return value ? std::string(value.UTF8String ?: "") : std::string();
}

static bool OPNEnvFlagEnabled(const char *name, bool defaultValue) {
    const char *value = getenv(name);
    if (!value || !*value) return defaultValue;
    std::string normalized(value);
    std::transform(normalized.begin(), normalized.end(), normalized.begin(), [](unsigned char c) { return (char)std::tolower(c); });
    return !(normalized == "0" || normalized == "false" || normalized == "no" || normalized == "off");
}

static OPNLibWebRTCSessionImpl *OPNImplFromOpaque(void *opaque) {
    return (__bridge OPNLibWebRTCSessionImpl *)opaque;
}

static OPNLibWebRTCInput *OPNInputController(void *opaque) {
    return (__bridge OPNLibWebRTCInput *)opaque;
}

static OPNLibWebRTCAudio *OPNAudioController(void *opaque) {
    return (__bridge OPNLibWebRTCAudio *)opaque;
}

static OPNLibWebRTCStats *OPNStatsController(void *opaque) {
    return (__bridge OPNLibWebRTCStats *)opaque;
}

static uint64_t OPNMonotonicMs() {
    using Clock = std::chrono::steady_clock;
    return (uint64_t)std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now().time_since_epoch()).count();
}

static double OPNStatsDouble(NSDictionary *stats, NSString *key, double fallback = -1.0) {
    id value = stats[key];
    return [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : fallback;
}

static uint64_t OPNStatsUInt64(NSDictionary *stats, NSString *key) {
    id value = stats[key];
    return [value respondsToSelector:@selector(unsignedLongLongValue)] ? [value unsignedLongLongValue] : 0;
}

static int64_t OPNStatsInt64(NSDictionary *stats, NSString *key) {
    id value = stats[key];
    return [value respondsToSelector:@selector(longLongValue)] ? [value longLongValue] : 0;
}

static bool OPNStatsBool(NSDictionary *stats, NSString *key) {
    id value = stats[key];
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : false;
}

static std::string OPNStatsString(NSDictionary *stats, NSString *key) {
    id value = stats[key];
    if (![value isKindOfClass:NSString.class]) return "";
    return OPNNSStringToString((NSString *)value);
}

static dispatch_queue_t OPNStatsQueue(void *queue) {
    return queue ? (__bridge dispatch_queue_t)queue : dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
}

void LibWebRTCStreamSession::SendInput(const uint8_t *data, size_t len) {
    if (!data || len == 0) return;
    NSData *payload = [NSData dataWithBytes:data length:len];
    [OPNInputController(m_inputController) sendInputData:payload partiallyReliable:NO lowLatencyMode:m_settings.lowLatencyMode ? YES : NO sessionImpl:OPNImplFromOpaque(m_impl)];
}

void LibWebRTCStreamSession::SendInputPartiallyReliable(const uint8_t *data, size_t len) {
    if (!data || len == 0) return;
    NSData *payload = [NSData dataWithBytes:data length:len];
    [OPNInputController(m_inputController) sendInputData:payload partiallyReliable:YES lowLatencyMode:m_settings.lowLatencyMode ? YES : NO sessionImpl:OPNImplFromOpaque(m_impl)];
}

void LibWebRTCStreamSession::CreateInputChannel() {
    [OPNInputController(m_inputController) createInputChannelWithSessionImpl:OPNImplFromOpaque(m_impl)];
}

bool LibWebRTCStreamSession::InputReady() const {
    return [OPNInputController(m_inputController) isInputReady] ? true : false;
}

void LibWebRTCStreamSession::SendKeyEvent(uint16_t keycode, uint16_t scancode, uint16_t modifiers, bool down) {
    [OPNInputController(m_inputController) sendKeyWithKeycode:keycode scancode:scancode modifiers:modifiers down:down ? YES : NO sessionImpl:OPNImplFromOpaque(m_impl)];
}

void LibWebRTCStreamSession::SendMouseMove(int16_t dx, int16_t dy) {
    [OPNInputController(m_inputController) sendMouseMoveWithDx:dx dy:dy lowLatencyMode:m_settings.lowLatencyMode ? YES : NO sessionImpl:OPNImplFromOpaque(m_impl)];
}

void LibWebRTCStreamSession::SendMouseButton(uint8_t button, bool down) {
    [OPNInputController(m_inputController) sendMouseButtonWithButton:button down:down ? YES : NO sessionImpl:OPNImplFromOpaque(m_impl)];
}

void LibWebRTCStreamSession::SendMouseWheel(int16_t delta) {
    [OPNInputController(m_inputController) sendMouseWheelWithDelta:delta sessionImpl:OPNImplFromOpaque(m_impl)];
}

void LibWebRTCStreamSession::SendUtf8Text(const std::string &text) {
    [OPNInputController(m_inputController) sendUtf8Text:OPNStringToNSString(text) sessionImpl:OPNImplFromOpaque(m_impl)];
}

void LibWebRTCStreamSession::SendGamepadState(const Input::GamepadState &state, uint16_t bitmap) {
    [OPNInputController(m_inputController) sendGamepadStateWithControllerId:state.controllerId
                                                                    buttons:state.buttons
                                                                leftTrigger:state.leftTrigger
                                                               rightTrigger:state.rightTrigger
                                                                 leftStickX:state.leftStickX
                                                                 leftStickY:state.leftStickY
                                                                rightStickX:state.rightStickX
                                                                rightStickY:state.rightStickY
                                                                timestampUs:state.timestampUs
                                                                     bitmap:bitmap
                                                             lowLatencyMode:m_settings.lowLatencyMode ? YES : NO
                                                                sessionImpl:OPNImplFromOpaque(m_impl)];
}

void LibWebRTCStreamSession::HandleDataChannelState(const std::string &label, bool open) {
    [OPNInputController(m_inputController) handleDataChannelStateWithLabel:OPNStringToNSString(label) open:open ? YES : NO];
}

void LibWebRTCStreamSession::HandleDataChannelMessage(const std::string &label, const uint8_t *data, size_t len) {
    if (!data || len == 0) return;
    NSData *payload = [NSData dataWithBytes:data length:len];
    [OPNInputController(m_inputController) handleDataChannelMessageWithLabel:OPNStringToNSString(label) data:payload sessionImpl:OPNImplFromOpaque(m_impl)];
}

void LibWebRTCStreamSession::HandleClipboardText(const std::string &text) {
    if (m_onClipboardText) m_onClipboardText(text);
}

extern "C" void OPNLibWebRTCInputOwnerHandleClipboardText(void *owner, NSString *text) {
    OPN::LibWebRTCStreamSession *session = owner ? static_cast<OPN::LibWebRTCStreamSession *>(owner) : nullptr;
    if (session) session->HandleClipboardText(OPNNSStringToString(text));
}

void LibWebRTCStreamSession::SetMicrophoneEnabled(bool enabled) {
    m_microphoneEnabled = enabled;
    [OPNAudioController(m_audioController) setMicrophoneEnabled:enabled ? YES : NO sessionImpl:OPNImplFromOpaque(m_impl)];
}

void LibWebRTCStreamSession::SetGameVolume(double volume) {
    m_gameVolume = std::max(0.0, std::min(volume, 1.0));
    [OPNAudioController(m_audioController) setGameVolume:m_gameVolume sessionImpl:OPNImplFromOpaque(m_impl)];
}

void LibWebRTCStreamSession::SetMicrophoneVolume(double volume) {
    m_microphoneVolumeLevel = std::max(0.0, std::min(volume, 1.0));
    [OPNAudioController(m_audioController) setMicrophoneVolume:m_microphoneVolumeLevel sessionImpl:OPNImplFromOpaque(m_impl)];
}

void LibWebRTCStreamSession::RefreshAudioDevices() {
    [OPNAudioController(m_audioController) refreshAudioDevicesWithSessionImpl:OPNImplFromOpaque(m_impl)];
}

void LibWebRTCStreamSession::StartAudioDeviceMonitoring() {
    [OPNAudioController(m_audioController) startAudioDeviceMonitoring];
}

void LibWebRTCStreamSession::StopAudioDeviceMonitoring() {
    [OPNAudioController(m_audioController) stopAudioDeviceMonitoring];
}

void LibWebRTCStreamSession::HandleAudioDeviceChange() {
    [OPNAudioController(m_audioController) handleAudioDeviceChangeWithSessionImpl:OPNImplFromOpaque(m_impl)];
}

void LibWebRTCStreamSession::StartMicrophoneLevelPolling() {
    dispatch_queue_t statsQueue = m_statsQueue ? (__bridge dispatch_queue_t)m_statsQueue : dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    [OPNAudioController(m_audioController) startMicrophoneLevelPollingWithSessionImpl:OPNImplFromOpaque(m_impl) statsQueue:statsQueue];
}

void LibWebRTCStreamSession::StopMicrophoneLevelPolling() {
    [OPNAudioController(m_audioController) stopMicrophoneLevelPolling];
}

double LibWebRTCStreamSession::GameVolume() const {
    return OPNAudioController(m_audioController).gameVolume;
}

void LibWebRTCStreamSession::HandleMicrophoneLevel(double level) {
    if (m_onMicrophoneLevel) m_onMicrophoneLevel(level);
}

extern "C" void OPNLibWebRTCAudioOwnerHandleMicrophoneLevel(void *owner, double level) {
    OPN::LibWebRTCStreamSession *session = owner ? static_cast<OPN::LibWebRTCStreamSession *>(owner) : nullptr;
    if (session) session->HandleMicrophoneLevel(level);
}

extern "C" void OPNLibWebRTCAudioOwnerHandleConnectionState(void *owner, BOOL connected, NSString *error) {
    OPN::LibWebRTCStreamSession *session = owner ? static_cast<OPN::LibWebRTCStreamSession *>(owner) : nullptr;
    if (session) session->HandleConnectionState(connected ? true : false, OPNNSStringToString(error));
}

extern "C" void OPNCoreAudioRTCDeviceHandleGameAudioFrame(void *owner,
                                                            const void *audioBufferList,
                                                            uint32_t frameCount,
                                                            double sampleRate,
                                                            uint32_t channels) {
    OPN::LibWebRTCStreamSession *session = owner ? static_cast<OPN::LibWebRTCStreamSession *>(owner) : nullptr;
    if (session && audioBufferList) session->HandleGameAudioFrame(audioBufferList, frameCount, sampleRate, channels);
}

extern "C" double OPNCoreAudioRTCDeviceDelegatePreferredInputSampleRate(id<RTCAudioDeviceDelegate> delegate) {
    return delegate ? delegate.preferredInputSampleRate : 0.0;
}

extern "C" double OPNCoreAudioRTCDeviceDelegatePreferredOutputSampleRate(id<RTCAudioDeviceDelegate> delegate) {
    return delegate ? delegate.preferredOutputSampleRate : 0.0;
}

extern "C" double OPNCoreAudioRTCDeviceDelegatePreferredInputIOBufferDuration(id<RTCAudioDeviceDelegate> delegate) {
    return delegate ? delegate.preferredInputIOBufferDuration : 0.0;
}

extern "C" double OPNCoreAudioRTCDeviceDelegatePreferredOutputIOBufferDuration(id<RTCAudioDeviceDelegate> delegate) {
    return delegate ? delegate.preferredOutputIOBufferDuration : 0.0;
}

extern "C" void OPNCoreAudioRTCDeviceDelegateNotifyDeviceChange(id<RTCAudioDeviceDelegate> delegate) {
    if (!delegate) return;
    [delegate dispatchAsync:^{
        [delegate notifyAudioOutputInterrupted];
        [delegate notifyAudioInputInterrupted];
        [delegate notifyAudioOutputParametersChange];
        [delegate notifyAudioInputParametersChange];
    }];
}

extern "C" OSStatus OPNCoreAudioRTCDeviceDelegateGetPlayoutData(id<RTCAudioDeviceDelegate> delegate,
                                                                  AudioUnitRenderActionFlags *actionFlags,
                                                                  const AudioTimeStamp *timestamp,
                                                                  NSInteger busNumber,
                                                                  UInt32 frameCount,
                                                                  AudioBufferList *audioBufferList) {
    if (!delegate || !delegate.getPlayoutData) return noErr;
    return delegate.getPlayoutData(actionFlags, timestamp, busNumber, frameCount, audioBufferList);
}

extern "C" OSStatus OPNCoreAudioRTCDeviceDelegateDeliverRecordedData(id<RTCAudioDeviceDelegate> delegate,
                                                                       AudioUnitRenderActionFlags *actionFlags,
                                                                       const AudioTimeStamp *timestamp,
                                                                       NSInteger busNumber,
                                                                       UInt32 frameCount,
                                                                       AudioBufferList *audioBufferList) {
    if (!delegate || !delegate.deliverRecordedData) return noErr;
    return delegate.deliverRecordedData(actionFlags, timestamp, busNumber, frameCount, audioBufferList, nullptr, nil);
}

void LibWebRTCStreamSession::RequestStats() {
    [OPNStatsController(m_statsController) requestStatsWithSessionImpl:OPNImplFromOpaque(m_impl) queue:OPNStatsQueue(m_statsQueue)];
}

void LibWebRTCStreamSession::StartStatsPolling() {
    [OPNStatsController(m_statsController) startPollingWithSessionImpl:OPNImplFromOpaque(m_impl) queue:OPNStatsQueue(m_statsQueue)];
}

void LibWebRTCStreamSession::StopStatsPolling() {
    [OPNStatsController(m_statsController) stopPolling];
}

StreamStats LibWebRTCStreamSession::GetLatestStats() const {
    std::lock_guard<std::mutex> lock(m_statsMutex);
    return m_latestStats;
}

void LibWebRTCStreamSession::ApplyRuntimeBitrateLimit(int mbps, const char *reason) {
    int clampedMbps = std::max(1, std::min(mbps, 250));
    {
        std::lock_guard<std::mutex> lock(m_statsMutex);
        m_latestStats.videoPipelineMode = "libwebrtc bitrate " + std::to_string(clampedMbps) + " Mbps";
    }
    [OPNStatsController(m_statsController) applyRuntimeBitrateLimitMbps:clampedMbps reason:@(reason ? reason : "manual") sessionImpl:OPNImplFromOpaque(m_impl)];
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
        const bool congested = stats.packetLossPercent >= 1.0 || stats.jitterMs >= 25.0 || stats.latencyMs >= 110.0 || stats.decodeTimeMs >= frameBudgetMs * 0.90 || (stats.renderFps > 0.0 && stats.renderFps < targetFps * 0.82);
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

    if (bitrateToApply > 0) ApplyRuntimeBitrateLimit(bitrateToApply, reason);
}

void LibWebRTCStreamSession::SetLocalVideoEnhancement(int mode, int sharpness, int denoise, int targetHeight) {
    std::lock_guard<std::mutex> lock(m_statsMutex);
    m_localEnhancementMode = std::max(0, std::min(mode, 4));
    m_localEnhancementSharpness = std::max(0, std::min(sharpness, 40));
    m_localEnhancementDenoise = std::max(0, std::min(denoise, 20));
    m_localEnhancementTargetHeight = std::max(1440, std::min(targetHeight, 2160));
}

void LibWebRTCStreamSession::SetEnhancedVideoFrameCaptureEnabled(bool enabled) {
    std::lock_guard<std::mutex> lock(m_statsMutex);
    m_enhancedVideoFrameCaptureEnabled = enabled;
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

void LibWebRTCStreamSession::LocalVideoEnhancement(int &mode, int &sharpness, int &denoise, int &targetHeight) const {
    std::lock_guard<std::mutex> lock(m_statsMutex);
    mode = m_localEnhancementMode;
    sharpness = m_localEnhancementSharpness;
    denoise = m_localEnhancementDenoise;
    targetHeight = m_localEnhancementTargetHeight;
}

void LibWebRTCStreamSession::SetVideoRendererState(const std::string &sink, const std::string &pipelineMode) {
    std::lock_guard<std::mutex> lock(m_statsMutex);
    m_latestStats.videoSink = sink;
    if (!pipelineMode.empty()) m_latestStats.videoPipelineMode = pipelineMode;
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
                                                       const std::string &enhancementDiagnostics,
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
    m_latestStats.videoEnhancementDiagnostics = enhancementDiagnostics;
    m_latestStats.videoEnhancementFrameTimeMs = enhancementFrameTimeMs;
    m_latestStats.videoEnhancementDroppedFrames = enhancementDroppedFrames;
}

void LibWebRTCStreamSession::HandleStatsDictionary(void *rawStats) {
    NSDictionary *stats = (__bridge NSDictionary *)rawStats;
    if (!stats) return;

    StreamStats parsed;
    {
        std::lock_guard<std::mutex> lock(m_statsMutex);
        parsed = m_latestStats;
    }
    parsed.available = OPNStatsBool(stats, @"available");
    parsed.latencyMs = OPNStatsDouble(stats, @"latencyMs");
    parsed.jitterMs = OPNStatsDouble(stats, @"jitterMs");
    parsed.inboundBitrateMbps = OPNStatsDouble(stats, @"inboundBitrateMbps");
    parsed.packetLossPercent = OPNStatsDouble(stats, @"packetLossPercent");
    parsed.decodeTimeMs = OPNStatsDouble(stats, @"decodeTimeMs");
    parsed.renderFps = OPNStatsDouble(stats, @"renderFps");
    parsed.bytesReceived = OPNStatsUInt64(stats, @"bytesReceived");
    parsed.packetsReceived = OPNStatsUInt64(stats, @"packetsReceived");
    parsed.packetsLost = OPNStatsInt64(stats, @"packetsLost");
    parsed.framesReceived = OPNStatsUInt64(stats, @"framesReceived");
    parsed.framesDecoded = OPNStatsUInt64(stats, @"framesDecoded");
    parsed.framesDropped = OPNStatsUInt64(stats, @"framesDropped");
    parsed.timestampMs = OPNStatsUInt64(stats, @"timestampMs");
    parsed.videoDecoder = OPNStatsString(stats, @"videoDecoder");
    if (parsed.videoSink.empty()) parsed.videoSink = OPNStatsString(stats, @"videoSink");
    if (parsed.videoPipelineMode.empty()) parsed.videoPipelineMode = OPNStatsString(stats, @"videoPipelineMode");
    std::string resolution = OPNStatsString(stats, @"resolution");
    if (!resolution.empty()) parsed.resolution = resolution;
    std::string codec = OPNStatsString(stats, @"codec");
    if (!codec.empty()) parsed.codec = codec;

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
        if (parsed.framesDecoded > 0) m_previousFramesDecoded = parsed.framesDecoded;
        m_latestStats = parsed;
    }
    UpdateAdaptiveBitrate(parsed);
}

extern "C" void OPNLibWebRTCStatsOwnerHandleStatsReport(void *owner, NSDictionary *stats) {
    OPN::LibWebRTCStreamSession *session = owner ? static_cast<OPN::LibWebRTCStreamSession *>(owner) : nullptr;
    if (session) session->HandleStatsDictionary((__bridge void *)stats);
}

#if defined(OPN_HAVE_LIBWEBRTC)
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
                OPNLogError(@"[LibWebRTC] failed to set microphone transceiver direction: %@", directionError.localizedDescription);
            }
        }
        transceiver.sender.track = audioTrack;
        transceiver.sender.streamIds = @[@"mic"];
        impl.localMicrophoneSender = transceiver.sender;
        OPNLogInfo(@"[LibWebRTC] local microphone track attached to transceiver mid=%@ direction=%s target=%s enabled=%d volume=%.2f",
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
    OPNLogInfo(@"[LibWebRTC] local microphone track added without negotiated transceiver; renegotiation may be required");
    return true;
}
#endif

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
        m_latestStats.videoEnhancementDiagnostics = "";
        m_latestStats.videoEnhancementFrameTimeMs = -1.0;
        m_latestStats.videoEnhancementDroppedFrames = 0;
        m_previousStatsTimestampMs = 0;
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
        OPNLogError(@"[LibWebRTC] CoreAudio RTC device factory failed; falling back to default WebRTC audio device");
        impl.audioDevice = nil;
        impl.factory = [[RTCPeerConnectionFactory alloc] init];
    } else {
        OPNLogInfo(@"[LibWebRTC] CoreAudio RTC audio device enabled");
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
        OPNLogInfo(@"[LibWebRTC] Offer contains 0.0.0.0 placeholders; leaving SDP unchanged for native parser compatibility (mediaIp=%s)",
              mediaIp.empty() ? "unknown" : mediaIp.c_str());
    }
    std::string requestedCodec = OPNNormalizeCodec(settings.codec);
    NSString *requestedCodecString = [NSString stringWithUTF8String:requestedCodec.c_str()] ?: @"";
    bool requestedCodecSupported = [OPNWebRTCCodecSupport supportsCodecWithFactory:impl.factory normalizedCodec:requestedCodecString] ? true : false;
    if (requestedCodec == "H265" && requestedCodecSupported && OPNEnvFlagEnabled("OPN_ENABLE_LIBWEBRTC_H265_OFFER_REWRITE", true)) {
        int maxMainLevelId = 0;
        int maxMain10LevelId = 0;
        bool supportsHighTier = false;
        NSDictionary *h265Support = [OPNWebRTCCodecSupport h265ReceiverSupportWithFactory:impl.factory];
        if ([h265Support[@"supported"] boolValue]) {
            maxMainLevelId = [h265Support[@"maxMainLevelId"] intValue];
            maxMain10LevelId = [h265Support[@"maxMain10LevelId"] intValue];
            supportsHighTier = [h265Support[@"supportsHighTier"] boolValue] ? true : false;
            processedOfferSdp = OPNRewriteH265OfferForReceiver(processedOfferSdp, maxMainLevelId, maxMain10LevelId, supportsHighTier);
        }
    } else if (requestedCodec == "H265" && requestedCodecSupported) {
        OPNLogInfo(@"[LibWebRTC] OPN_ENABLE_LIBWEBRTC_H265_OFFER_REWRITE=0; retaining original H265 offer parameters");
    }
    if (OPNIsSupportedCodecPreference(requestedCodec) && requestedCodecSupported && OPNEnvFlagEnabled("OPN_ENABLE_LIBWEBRTC_CODEC_FILTER", false)) {
        processedOfferSdp = OPNPreferCodecInOffer(processedOfferSdp, requestedCodec);
    } else if (OPNIsSupportedCodecPreference(requestedCodec) && !requestedCodecSupported) {
        OPNLogInfo(@"[LibWebRTC] Requested codec %s is not supported by this WebRTC.framework; retaining full offer so libwebrtc can negotiate a supported fallback", requestedCodec.c_str());
    } else if (OPNIsSupportedCodecPreference(requestedCodec)) {
        OPNLogInfo(@"[LibWebRTC] OPN_ENABLE_LIBWEBRTC_CODEC_FILTER=0; retaining all video payloads for requested codec %s", requestedCodec.c_str());
    } else {
        OPNLogInfo(@"[LibWebRTC] Unsupported requested codec preference '%s'; retaining all video payloads", settings.codec.c_str());
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
            NSString *answerCodecPreferenceString = [NSString stringWithUTF8String:answerCodecPreference.c_str()] ?: @"";
            if (![OPNWebRTCCodecSupport applyVideoCodecPreferenceWithFactory:strongImpl.factory peerConnection:strongImpl.peerConnection normalizedCodec:answerCodecPreferenceString]) {
                OPNLogInfo(@"[LibWebRTC] No video transceiver accepted %s codec preference before answer", answerCodecPreference.c_str());
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
                OPNLogError(@"[LibWebRTC] failed to attach local microphone track");
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
            const std::string mungedAnswerSdp = enableAnswerMunging
                ? OPNMungeAnswerSdp(rawAnswerSdp, std::max(1000, this->m_settings.maxBitrateMbps * 1000))
                : rawAnswerSdp;
            if (!enableAnswerMunging) {
                OPNLogInfo(@"[LibWebRTC] OPN_ENABLE_LIBWEBRTC_ANSWER_MUNGE=0; using raw local answer SDP");
            }
            const std::string localAnswerSdp = OPNAlignH265AnswerFmtpToOffer(mungedAnswerSdp, processedOfferSdp);
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

        OPNLogInfo(@"[LibWebRTC] filtered offer rejected (%@); retrying original GFN offer", error.localizedDescription);
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
    CancelDisconnectGraceTimer();
    StopAudioDeviceMonitoring();
    StopStatsPolling();
    StopMicrophoneLevelPolling();
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
    [OPNInputController(m_inputController) stop];
}

void LibWebRTCStreamSession::AddRemoteIceCandidate(const IceCandidatePayload &candidate) {
#if defined(OPN_HAVE_LIBWEBRTC)
    OPNLibWebRTCSessionImpl *impl = OPNImplFromOpaque(m_impl);
    if (!impl.peerConnection || candidate.candidate.empty()) return;
    OPNLogInfo(@"[LibWebRTC] Adding remote ICE candidate mid=%s mline=%d length=%zu",
          candidate.sdpMid.empty() ? "(none)" : candidate.sdpMid.c_str(),
          candidate.sdpMLineIndex,
          candidate.candidate.size());
    RTCIceCandidate *rtcCandidate = [[RTCIceCandidate alloc] initWithSdp:OPNStringToNSString(candidate.candidate)
                                                            sdpMLineIndex:candidate.sdpMLineIndex
                                                                   sdpMid:candidate.sdpMid.empty() ? nil : OPNStringToNSString(candidate.sdpMid)];
    [impl.peerConnection addIceCandidate:rtcCandidate completionHandler:^(NSError *error) {
        if (error) {
            OPNLogError(@"[LibWebRTC] addIceCandidate failed: %@", error.localizedDescription);
        } else {
            OPNLogInfo(@"[LibWebRTC] addIceCandidate succeeded mid=%s mline=%d",
                  candidate.sdpMid.empty() ? "(none)" : candidate.sdpMid.c_str(),
                  candidate.sdpMLineIndex);
        }
    }];
#else
    (void)candidate;
#endif
}

}
