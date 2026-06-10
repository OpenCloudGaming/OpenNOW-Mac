#include "OPNLibWebRTCStreamSession.h"

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
