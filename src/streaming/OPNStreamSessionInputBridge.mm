#include "OPNStreamSessionInputBridge.h"

#include "OPNStreamSession.h"
#include "OPNStreamTypes.h"
#include "OPNLibWebRTCStreamSession.h"
#include "OPNStreamSessionLaunchBridge.h"

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

static NSString *OPNStreamStatsSnapshotString(const std::string &value) {
    if (value.empty()) return @"";
    NSString *string = [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding];
    return string ?: @"";
}

static OPN::IStreamSession *OPNRawStreamSession(void *session) {
    return static_cast<OPN::IStreamSession *>(session);
}

extern "C" BOOL OPNStreamSessionHandleBackendAvailable(void) {
    return OPN::LibWebRTCStreamSession::IsAvailable() ? YES : NO;
}

extern "C" NSUInteger OPNStreamSessionHandleMaxGamepadControllers(void) {
    return OPNStreamSessionMaxGamepadControllers();
}

extern "C" NSString *OPNStreamSessionHandleIceUfragFromOfferSdp(NSString *offerSdp) {
    return OPNStreamSessionIceUfragFromOffer(offerSdp);
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
    return OPNStreamSessionInputReady(OPNRawStreamSession(session)) ? YES : NO;
}

extern "C" void OPNStreamSessionHandleSetNativeWindow(void *session, void *nativeWindow) {
    OPNSetStreamSessionNativeWindow(OPNRawStreamSession(session), nativeWindow);
}

extern "C" void OPNStreamSessionHandleSetMaxBitrateMbps(void *session, NSInteger mbps) {
    OPNSetStreamSessionMaxBitrateMbps(OPNRawStreamSession(session), (int)mbps);
}

extern "C" void OPNStreamSessionHandleAddRemoteIceCandidatePayload(void *session, NSDictionary *payload) {
    OPNAddStreamSessionRemoteIceCandidateFromDictionary(OPNRawStreamSession(session), payload);
}

extern "C" OPNStreamStatsSnapshot *OPNStreamSessionHandleLatestStatsSnapshot(void *session) {
    OPN::StreamStats stats = OPNRequestLatestStreamSessionStats(OPNRawStreamSession(session));
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

NSUInteger OPNStreamSessionMaxGamepadControllers(void) {
    return (NSUInteger)OPN::Input::GAMEPAD_MAX_CONTROLLERS;
}

bool OPNStreamSessionInputReady(OPN::IStreamSession *session) {
    return session && session->InputReady();
}

void OPNSetStreamSessionMaxBitrateMbps(OPN::IStreamSession *session, int mbps) {
    if (!session) return;
    session->SetMaxBitrateMbps(mbps);
}

OPN::StreamStats OPNRequestLatestStreamSessionStats(OPN::IStreamSession *session) {
    OPN::StreamStats stats;
    if (!session) return stats;
    session->RequestStats();
    return session->GetLatestStats();
}

void OPNSetStreamSessionNativeWindow(OPN::IStreamSession *session, void *nativeWindow) {
    if (!session) return;
    session->SetNativeWindow(nativeWindow);
}

void OPNAddStreamSessionRemoteIceCandidateFromDictionary(OPN::IStreamSession *session, NSDictionary *payload) {
    if (!session) return;
    OPN::IceCandidatePayload candidate;
    NSString *candidateText = [payload[@"candidate"] isKindOfClass:[NSString class]] ? payload[@"candidate"] : @"";
    NSString *sdpMid = [payload[@"sdpMid"] isKindOfClass:[NSString class]] ? payload[@"sdpMid"] : @"";
    NSNumber *sdpMLineIndex = [payload[@"sdpMLineIndex"] isKindOfClass:[NSNumber class]] ? payload[@"sdpMLineIndex"] : nil;
    NSString *usernameFragment = [payload[@"usernameFragment"] isKindOfClass:[NSString class]] ? payload[@"usernameFragment"] : @"";
    candidate.candidate = candidateText.UTF8String ?: "";
    candidate.sdpMid = sdpMid.UTF8String ?: "";
    candidate.sdpMLineIndex = sdpMLineIndex ? sdpMLineIndex.intValue : 0;
    candidate.usernameFragment = usernameFragment.UTF8String ?: "";
    session->AddRemoteIceCandidate(candidate);
}

void OPNSendStreamSessionMouseMove(OPN::IStreamSession *session, int16_t dx, int16_t dy) {
    if (!session) return;
    session->SendMouseMove(dx, dy);
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
