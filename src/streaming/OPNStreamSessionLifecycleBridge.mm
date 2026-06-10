#include "OPNStreamSessionLifecycleBridge.h"

#include "OPNLibWebRTCStreamSession.h"

#import <Foundation/Foundation.h>

bool OPNStreamSessionBackendAvailable(void) {
    return OPN::LibWebRTCStreamSession::IsAvailable();
}

OPN::IStreamSession *OPNCreateStreamSession(void) {
    if (OPNStreamSessionBackendAvailable()) {
        return new OPN::LibWebRTCStreamSession();
    }
    return nullptr;
}

void OPNReleaseStreamSessionAfterCallbacks(OPN::IStreamSession *session) {
    if (!session) return;
    session->Stop();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        delete session;
    });
}
