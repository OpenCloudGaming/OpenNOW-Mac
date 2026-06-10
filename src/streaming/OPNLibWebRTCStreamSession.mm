#include "OPNLibWebRTCStreamSession.h"

#include "OPNLibWebRTCStreamSession.h"

#include "OPNWebRTCSdpUtils.h"

#import <Foundation/Foundation.h>

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

NSString *OPNStreamSessionIceUfragFromOffer(NSString *offerSdp);

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

extern "C" BOOL OPNStreamSessionHandleBackendAvailable(void) {
    return OPN::LibWebRTCStreamSession::IsAvailable() ? YES : NO;
}

extern "C" NSUInteger OPNStreamSessionHandleMaxGamepadControllers(void) {
    return (NSUInteger)OPN::Input::GAMEPAD_MAX_CONTROLLERS;
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
