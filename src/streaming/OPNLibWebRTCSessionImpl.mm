#include "OPNLibWebRTCSessionImpl.h"

#include "OPNMetalVideoView.h"

#if defined(OPN_HAVE_LIBWEBRTC)
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

namespace OPN {
static std::string OPNNSStringToString(NSString *value) {
    return value ? std::string(value.UTF8String ?: "") : std::string();
}
}

@implementation OPNLibWebRTCSessionImpl

- (instancetype)initWithOwner:(OPN::LibWebRTCStreamSession *)owner {
    self = [super init];
    if (self) {
        _owner = owner;
    }
    return self;
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeSignalingState:(RTCSignalingState)stateChanged {
    (void)peerConnection;
    OPNLogInfo(@"[LibWebRTC] signaling state=%ld", (long)stateChanged);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didAddStream:(RTCMediaStream *)stream {
    (void)peerConnection;
    (void)stream;
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveStream:(RTCMediaStream *)stream {
    (void)peerConnection;
    (void)stream;
}

- (void)peerConnectionShouldNegotiate:(RTCPeerConnection *)peerConnection {
    (void)peerConnection;
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceConnectionState:(RTCIceConnectionState)newState {
    (void)peerConnection;
    OPNLogInfo(@"[LibWebRTC] ICE state=%ld", (long)newState);
    __weak OPNLibWebRTCSessionImpl *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        OPNLibWebRTCSessionImpl *strongSelf = weakSelf;
        if (!strongSelf.owner) return;
        OPN::LibWebRTCStreamSession *owner = strongSelf.owner;
        if (newState == RTCIceConnectionStateConnected || newState == RTCIceConnectionStateCompleted) {
            owner->CancelDisconnectGraceTimer();
            owner->HandleConnectionState(true, "");
        } else if (newState == RTCIceConnectionStateDisconnected) {
            owner->StartDisconnectGraceTimer("libwebrtc ICE disconnected");
        } else if (newState == RTCIceConnectionStateFailed || newState == RTCIceConnectionStateClosed) {
            owner->CancelDisconnectGraceTimer();
            owner->HandleConnectionState(false, "libwebrtc ICE failed");
        }
    });
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeIceGatheringState:(RTCIceGatheringState)newState {
    (void)peerConnection;
    OPNLogInfo(@"[LibWebRTC] ICE gathering state=%ld", (long)newState);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didGenerateIceCandidate:(RTCIceCandidate *)candidate {
    (void)peerConnection;
    if (!_owner || !candidate) return;
    OPN::IceCandidatePayload payload;
    payload.candidate = OPN::OPNNSStringToString(candidate.sdp);
    payload.sdpMid = OPN::OPNNSStringToString(candidate.sdpMid);
    payload.sdpMLineIndex = candidate.sdpMLineIndex;
    _owner->HandleLocalIceCandidate(payload);
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didRemoveIceCandidates:(NSArray<RTCIceCandidate *> *)candidates {
    (void)peerConnection;
    (void)candidates;
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didOpenDataChannel:(RTCDataChannel *)dataChannel {
    (void)peerConnection;
    dataChannel.delegate = self;
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didChangeConnectionState:(RTCPeerConnectionState)newState {
    (void)peerConnection;
    OPNLogInfo(@"[LibWebRTC] peer state=%ld", (long)newState);
    __weak OPNLibWebRTCSessionImpl *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        OPNLibWebRTCSessionImpl *strongSelf = weakSelf;
        if (!strongSelf.owner) return;
        OPN::LibWebRTCStreamSession *owner = strongSelf.owner;
        if (newState == RTCPeerConnectionStateConnected) {
            owner->CancelDisconnectGraceTimer();
            owner->HandleConnectionState(true, "");
        } else if (newState == RTCPeerConnectionStateDisconnected) {
            owner->StartDisconnectGraceTimer("libwebrtc peer connection disconnected");
        } else if (newState == RTCPeerConnectionStateFailed || newState == RTCPeerConnectionStateClosed) {
            owner->CancelDisconnectGraceTimer();
            owner->HandleConnectionState(false, "libwebrtc peer connection failed");
        }
    });
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection didAddReceiver:(RTCRtpReceiver *)rtpReceiver streams:(NSArray<RTCMediaStream *> *)mediaStreams {
    (void)peerConnection;
    (void)mediaStreams;
    if ([rtpReceiver.track.kind isEqualToString:kRTCMediaStreamTrackKindVideo]) {
        OPNLogInfo(@"[LibWebRTC] remote video receiver added: %@", rtpReceiver.track.trackId);
        RTCVideoTrack *videoTrack = (RTCVideoTrack *)rtpReceiver.track;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!_owner) return;
            NSView *parentView = (__bridge NSView *)_owner->NativeWindowHandle();
            if (!parentView) {
                OPNLogError(@"[LibWebRTC] Cannot attach remote video: native view is missing");
                return;
            }
            if (![RTCMTLNSVideoView isMetalAvailable]) {
                OPNLogError(@"[LibWebRTC] Cannot attach remote video: Metal renderer is unavailable");
                return;
            }

            if (self.remoteVideoTrack && self.remoteVideoRenderer) {
                [self.remoteVideoTrack removeRenderer:self.remoteVideoRenderer];
            }
            [self.remoteVideoView removeFromSuperview];

            OPNMetalVideoView *metalView = [[OPNMetalVideoView alloc] initWithFrame:parentView.bounds
                                                                          targetFps:_owner->TargetFps()
                                                                              owner:_owner];
            NSView *videoView = metalView;
            id<RTCVideoRenderer> videoRenderer = metalView;
            _owner->SetVideoRendererState("OPNMetalVideoView", "libwebrtc Metal display");
            videoView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            videoView.wantsLayer = YES;
            videoView.layer.backgroundColor = NSColor.blackColor.CGColor;
            [parentView addSubview:videoView positioned:NSWindowBelow relativeTo:nil];
            [videoTrack addRenderer:videoRenderer];

            self.remoteVideoTrack = videoTrack;
            self.remoteVideoView = videoView;
            self.remoteVideoRenderer = videoRenderer;
            OPNLogInfo(@"[LibWebRTC] Remote video renderer attached to native view=%p metal=1 targetFps=%d", (__bridge void *)parentView, _owner->TargetFps());
        });
    } else if ([rtpReceiver.track.kind isEqualToString:kRTCMediaStreamTrackKindAudio]) {
        RTCAudioTrack *audioTrack = (RTCAudioTrack *)rtpReceiver.track;
        audioTrack.isEnabled = YES;
        audioTrack.source.volume = _owner ? _owner->GameVolume() : 1.0;
        self.remoteAudioTrack = audioTrack;
        OPNLogInfo(@"[LibWebRTC] remote audio track enabled: %@ volume=%.2f", audioTrack.trackId, audioTrack.source.volume);
    }
}

- (void)dataChannelDidChangeState:(RTCDataChannel *)dataChannel {
    if (!_owner || !dataChannel) return;
    const bool open = dataChannel.readyState == RTCDataChannelStateOpen;
    _owner->HandleDataChannelState(OPN::OPNNSStringToString(dataChannel.label), open);
    OPNLogInfo(@"[LibWebRTC] data channel %@ state=%ld inputReady=%d", dataChannel.label, (long)dataChannel.readyState, _owner->InputReady());
}

- (void)dataChannel:(RTCDataChannel *)dataChannel didReceiveMessageWithBuffer:(RTCDataBuffer *)buffer {
    if (!_owner || !dataChannel || !buffer) return;
    _owner->HandleDataChannelMessage(OPN::OPNNSStringToString(dataChannel.label), static_cast<const uint8_t *>(buffer.data.bytes), buffer.data.length);
}

@end
#endif
