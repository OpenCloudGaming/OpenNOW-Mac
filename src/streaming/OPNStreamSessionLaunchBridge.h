#pragma once

#import <Foundation/Foundation.h>

namespace OPN {
class IStreamSession;
struct SessionInfo;
struct StreamSettings;
}

typedef void (^OPNStreamSessionAnswerHandler)(NSString *sdp, NSString *nvstSdp);
typedef void (^OPNStreamSessionLocalIceCandidateHandler)(NSDictionary *candidate);
typedef void (^OPNStreamSessionStateHandler)(BOOL connected, NSString *errorMessage);

NSString *OPNStreamSessionIceUfragFromOffer(NSString *offerSdp);
void OPNInjectManualStreamSessionIceCandidate(OPN::IStreamSession *session,
                                              const OPN::SessionInfo &sessionInfo,
                                              NSString *offerSdp,
                                              NSString *serverIceUfrag);

void OPNStartStreamSession(OPN::IStreamSession *session,
                           const OPN::SessionInfo &sessionInfo,
                           NSString *offerSdp,
                           const OPN::StreamSettings &settings,
                           OPNStreamSessionAnswerHandler answerHandler,
                           OPNStreamSessionLocalIceCandidateHandler localIceCandidateHandler,
                           OPNStreamSessionStateHandler stateHandler);
