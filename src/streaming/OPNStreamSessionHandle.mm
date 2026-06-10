#include "OPNStreamSessionHandle.h"
#include "OPNStreamSessionHandle+Private.h"

#include "OPNStreamSessionCallbackBridge.h"
#include "OPNStreamSessionInputBridge.h"
#include "OPNStreamSessionLaunchBridge.h"
#include "OPNStreamSessionLifecycleBridge.h"
#include "OPNStreamStatsSnapshot+Private.h"

@implementation OPNStreamSessionHandle {
    OPN::IStreamSession *_session;
}

+ (BOOL)isBackendAvailable {
    return OPNStreamSessionBackendAvailable() ? YES : NO;
}

+ (NSUInteger)maxGamepadControllers {
    return OPNStreamSessionMaxGamepadControllers();
}

+ (NSString *)iceUfragFromOfferSdp:(NSString *)offerSdp {
    return OPNStreamSessionIceUfragFromOffer(offerSdp);
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _session = OPNCreateStreamSession();
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (BOOL)isValid {
    return _session != nullptr;
}

- (BOOL)isInputReady {
    return OPNStreamSessionInputReady(_session) ? YES : NO;
}

- (OPN::IStreamSession *)rawSession {
    return _session;
}

- (void)stop {
    if (!_session) return;
    OPN::IStreamSession *session = _session;
    _session = nullptr;
    OPNReleaseStreamSessionAfterCallbacks(session);
}

- (void)setNativeWindow:(void *)nativeWindow {
    OPNSetStreamSessionNativeWindow(_session, nativeWindow);
}

- (void)setMaxBitrateMbps:(NSInteger)mbps {
    OPNSetStreamSessionMaxBitrateMbps(_session, (int)mbps);
}

- (void)addRemoteIceCandidatePayload:(NSDictionary *)payload {
    OPNAddStreamSessionRemoteIceCandidateFromDictionary(_session, payload);
}

- (OPNStreamStatsSnapshot *)latestStatsSnapshot {
    return [[OPNStreamStatsSnapshot alloc] initWithStreamStats:OPNRequestLatestStreamSessionStats(_session)];
}

- (void)clearCallbacks {
    OPNClearStreamSessionCallbacks(_session);
}

- (void)configureCallbacksWithStreamView:(OPNStreamView *)streamView {
    OPNConfigureStreamViewSessionCallbacks(_session, streamView);
}

- (OPN::StreamStats)requestLatestStats {
    return OPNRequestLatestStreamSessionStats(_session);
}

- (void)sendMouseMoveWithDeltaX:(int16_t)dx deltaY:(int16_t)dy {
    OPNSendStreamSessionMouseMove(_session, dx, dy);
}

- (void)startWithSessionInfo:(const OPN::SessionInfo &)sessionInfo
                     offerSdp:(NSString *)offerSdp
                     settings:(const OPN::StreamSettings &)settings
                answerHandler:(OPNStreamSessionAnswerHandler)answerHandler
      localIceCandidateHandler:(OPNStreamSessionLocalIceCandidateHandler)localIceCandidateHandler
                 stateHandler:(OPNStreamSessionStateHandler)stateHandler {
    OPNStartStreamSession(_session, sessionInfo, offerSdp, settings, answerHandler, localIceCandidateHandler, stateHandler);
}

- (void)injectManualIceCandidateWithSessionInfo:(const OPN::SessionInfo &)sessionInfo
                                       offerSdp:(NSString *)offerSdp
                                 serverIceUfrag:(NSString *)serverIceUfrag {
    OPNInjectManualStreamSessionIceCandidate(_session, sessionInfo, offerSdp, serverIceUfrag);
}

@end
