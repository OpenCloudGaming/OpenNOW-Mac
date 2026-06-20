import AppKit
import QuartzCore
@preconcurrency import WebRTC

@objc(OPNLibWebRTCSessionImpl)
final class OPNLibWebRTCSessionImpl: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate, @unchecked Sendable {
    weak var owner: OPNLibWebRTCStreamSession?
    @objc var factory: RTCPeerConnectionFactory?
    @objc var audioDevice: OPNCoreAudioRTCDevice?
    @objc var peerConnection: RTCPeerConnection?
    @objc var reliableInputChannel: RTCDataChannel?
    @objc var partialInputChannel: RTCDataChannel?
    @objc var remoteVideoTrack: RTCVideoTrack?
    @objc var remoteVideoView: NSView?
    @objc var remoteVideoRenderer: RTCVideoRenderer?
    @objc var remoteAudioTrack: RTCAudioTrack?
    @objc var localMicrophoneTrack: RTCAudioTrack?
    @objc var localMicrophoneSender: RTCRtpSender?

    @objc(initWithOwner:)
    init(owner: OPNLibWebRTCStreamSession?) {
        self.owner = owner
        super.init()
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        WebRTCMediaTelemetry.capture("webrtc.native.signaling_state", level: .debug, message: "Signaling state changed.", attributes: ["state": String(stateChanged.rawValue)])
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        WebRTCMediaTelemetry.capture("webrtc.native.ice_state", level: .debug, message: "ICE connection state changed.", attributes: ["state": String(newState.rawValue)])
        let owner = owner
        DispatchQueue.main.async { [weak owner] in
            switch newState {
            case .connected, .completed:
                owner?.cancelDisconnectGraceTimer()
                owner?.handleConnectionState(true, error: "")
            case .disconnected:
                owner?.startDisconnectGraceTimer(reason: "libwebrtc ICE disconnected")
            case .failed, .closed:
                owner?.cancelDisconnectGraceTimer()
                owner?.handleConnectionState(false, error: "libwebrtc ICE failed")
            default:
                break
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        WebRTCMediaTelemetry.capture("webrtc.native.ice_gathering_state", level: .debug, message: "ICE gathering state changed.", attributes: ["state": String(newState.rawValue)])
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        owner?.handleLocalIceCandidate(candidate: candidate.sdp, sdpMid: candidate.sdpMid ?? "", sdpMLineIndex: Int32(candidate.sdpMLineIndex))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        dataChannel.delegate = self
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        WebRTCMediaTelemetry.capture("webrtc.native.peer_state", level: .debug, message: "Peer connection state changed.", attributes: ["state": String(newState.rawValue)])
        let owner = owner
        DispatchQueue.main.async { [weak owner] in
            switch newState {
            case .connected:
                owner?.cancelDisconnectGraceTimer()
                owner?.handleConnectionState(true, error: "")
            case .disconnected:
                owner?.startDisconnectGraceTimer(reason: "libwebrtc peer connection disconnected")
            case .failed, .closed:
                owner?.cancelDisconnectGraceTimer()
                owner?.handleConnectionState(false, error: "libwebrtc peer connection failed")
            default:
                break
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track else { return }
        if track.kind == kRTCMediaStreamTrackKindVideo {
            guard let videoTrack = track as? RTCVideoTrack else { return }
            WebRTCMediaTelemetry.capture("webrtc.native.remote_video", level: .debug, message: "Remote video receiver added.", attributes: ["trackId": track.trackId])
            DispatchQueue.main.async { @MainActor [weak self] in
                self?.attachRemoteVideoTrack(videoTrack)
            }
        } else if track.kind == kRTCMediaStreamTrackKindAudio, let audioTrack = track as? RTCAudioTrack {
            audioTrack.isEnabled = true
            audioTrack.source.volume = owner?.gameVolumeLevel ?? 1.0
            remoteAudioTrack = audioTrack
            WebRTCMediaTelemetry.capture("webrtc.native.remote_audio", level: .debug, message: "Remote audio track enabled.", attributes: ["trackId": audioTrack.trackId, "volume": String(format: "%.2f", audioTrack.source.volume)])
        }
    }

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        let open = dataChannel.readyState == .open
        owner?.handleDataChannelState(label: dataChannel.label, open: open)
        WebRTCMediaTelemetry.capture("webrtc.native.data_channel", level: .debug, message: "Data channel state changed.", attributes: ["label": dataChannel.label, "state": String(dataChannel.readyState.rawValue), "inputReady": String(owner?.isInputReady == true)])
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        owner?.handleDataChannelMessage(label: dataChannel.label, data: buffer.data)
    }

    @MainActor private func attachRemoteVideoTrack(_ videoTrack: RTCVideoTrack) {
        guard let owner, let nativeWindow = owner.nativeWindowHandle() else {
            WebRTCMediaTelemetry.capture("webrtc.native.video_attach.error", level: .warning, message: "Cannot attach remote video because the native view is missing.")
            return
        }
        let parentView = Unmanaged<NSView>.fromOpaque(nativeWindow).takeUnretainedValue()
        guard RTCMTLNSVideoView.isMetalAvailable() else {
            WebRTCMediaTelemetry.capture("webrtc.native.video_attach.error", level: .warning, message: "Cannot attach remote video because Metal rendering is unavailable.")
            return
        }

        if let remoteVideoTrack, let remoteVideoRenderer {
            remoteVideoTrack.remove(remoteVideoRenderer)
        }
        remoteVideoView?.removeFromSuperview()

        let targetFps = Int32(owner.targetFps)
        let metalView = OPNMetalVideoView(frame: parentView.bounds, targetFps: targetFps, owner: owner)
        let videoView: NSView = metalView
        let videoRenderer: RTCVideoRenderer = metalView
        owner.setVideoRendererState(sink: "OPNMetalVideoView", pipelineMode: "libwebrtc Metal display")
        videoView.autoresizingMask = [.width, .height]
        videoView.wantsLayer = true
        videoView.layer?.backgroundColor = NSColor.black.cgColor
        parentView.addSubview(videoView, positioned: .below, relativeTo: nil)
        videoTrack.add(videoRenderer)

        remoteVideoTrack = videoTrack
        remoteVideoView = videoView
        remoteVideoRenderer = videoRenderer
        WebRTCMediaTelemetry.capture("webrtc.native.video_attach", level: .info, message: "Remote video renderer attached.", attributes: ["renderer": "Metal", "targetFps": String(targetFps)])
    }
}
