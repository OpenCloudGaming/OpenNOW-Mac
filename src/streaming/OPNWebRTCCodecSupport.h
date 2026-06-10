#pragma once

#include <string>

#if defined(OPN_HAVE_LIBWEBRTC)
@class RTCPeerConnection;
@class RTCPeerConnectionFactory;

namespace OPN {

bool OPNLibWebRTCSupportsCodec(RTCPeerConnectionFactory *factory, const std::string &normalizedCodec);
bool OPNLibWebRTCH265ReceiverSupport(RTCPeerConnectionFactory *factory,
                                     int &maxMainLevelId,
                                     int &maxMain10LevelId,
                                     bool &supportsHighTier);
bool OPNApplyVideoCodecPreference(RTCPeerConnectionFactory *factory,
                                  RTCPeerConnection *peerConnection,
                                  const std::string &normalizedCodec);

}
#endif
