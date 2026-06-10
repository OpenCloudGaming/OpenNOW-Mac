#pragma once

#include "OPNStreamSessionHandle.h"
#include "OPNStreamSessionLaunchBridge.h"
#include "OPNStreamStats.h"

@class OPNStreamView;

namespace OPN {
class IStreamSession;
}

@interface OPNStreamSessionHandle (Private)
@property(nonatomic, readonly) OPN::IStreamSession *rawSession;

- (void)clearCallbacks;
- (void)configureCallbacksWithStreamView:(OPNStreamView *)streamView;
- (OPN::StreamStats)requestLatestStats;
- (void)sendMouseMoveWithDeltaX:(int16_t)dx deltaY:(int16_t)dy;
- (void)startWithSessionInfo:(const OPN::SessionInfo &)sessionInfo
                     offerSdp:(NSString *)offerSdp
                     settings:(const OPN::StreamSettings &)settings
                answerHandler:(OPNStreamSessionAnswerHandler)answerHandler
      localIceCandidateHandler:(OPNStreamSessionLocalIceCandidateHandler)localIceCandidateHandler
                 stateHandler:(OPNStreamSessionStateHandler)stateHandler;
- (void)injectManualIceCandidateWithSessionInfo:(const OPN::SessionInfo &)sessionInfo
                                       offerSdp:(NSString *)offerSdp
                                 serverIceUfrag:(NSString *)serverIceUfrag;
@end
