#pragma once

#include "OPNLibWebRTCStreamSession.h"
#include "OPNCoreAudioRTCDevice.h"

#if defined(OPN_HAVE_LIBWEBRTC)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-umbrella"
#import <WebRTC/WebRTC.h>
#pragma clang diagnostic pop

@interface OPNLibWebRTCSessionImpl : NSObject <RTCPeerConnectionDelegate, RTCDataChannelDelegate>
- (instancetype)initWithOwner:(OPN::LibWebRTCStreamSession *)owner;
@property(nonatomic, assign) OPN::LibWebRTCStreamSession *owner;
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
#endif
