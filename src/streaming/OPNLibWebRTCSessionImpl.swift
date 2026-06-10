import AppKit
import Foundation
import QuartzCore
@preconcurrency import WebRTC

@_silgen_name("OPNLibWebRTCSessionOwnerCancelDisconnectGraceTimer")
private func OPNLibWebRTCSessionOwnerCancelDisconnectGraceTimer(_ owner: UnsafeMutableRawPointer?)

@_silgen_name("OPNLibWebRTCSessionOwnerStartDisconnectGraceTimer")
private func OPNLibWebRTCSessionOwnerStartDisconnectGraceTimer(_ owner: UnsafeMutableRawPointer?, _ reason: NSString)

@_silgen_name("OPNLibWebRTCSessionOwnerHandleConnectionState")
private func OPNLibWebRTCSessionOwnerHandleConnectionState(_ owner: UnsafeMutableRawPointer?, _ connected: Bool, _ error: NSString)

@_silgen_name("OPNLibWebRTCSessionOwnerHandleLocalIceCandidate")
private func OPNLibWebRTCSessionOwnerHandleLocalIceCandidate(_ owner: UnsafeMutableRawPointer?, _ candidate: NSString, _ sdpMid: NSString, _ sdpMLineIndex: Int32)

@_silgen_name("OPNLibWebRTCSessionOwnerNativeWindowHandle")
private func OPNLibWebRTCSessionOwnerNativeWindowHandle(_ owner: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?

@_silgen_name("OPNLibWebRTCSessionOwnerTargetFps")
private func OPNLibWebRTCSessionOwnerTargetFps(_ owner: UnsafeMutableRawPointer?) -> Int32

@_silgen_name("OPNLibWebRTCSessionOwnerGameVolume")
private func OPNLibWebRTCSessionOwnerGameVolume(_ owner: UnsafeMutableRawPointer?) -> Double

@_silgen_name("OPNLibWebRTCSessionOwnerSetVideoRendererState")
private func OPNLibWebRTCSessionOwnerSetVideoRendererState(_ owner: UnsafeMutableRawPointer?, _ sink: NSString, _ pipelineMode: NSString)

@_silgen_name("OPNLibWebRTCSessionOwnerHandleDataChannelState")
private func OPNLibWebRTCSessionOwnerHandleDataChannelState(_ owner: UnsafeMutableRawPointer?, _ label: NSString, _ open: Bool)

@_silgen_name("OPNLibWebRTCSessionOwnerInputReady")
private func OPNLibWebRTCSessionOwnerInputReady(_ owner: UnsafeMutableRawPointer?) -> Bool

@_silgen_name("OPNLibWebRTCSessionOwnerHandleDataChannelMessage")
private func OPNLibWebRTCSessionOwnerHandleDataChannelMessage(_ owner: UnsafeMutableRawPointer?, _ label: NSString, _ data: NSData)

@objc(OPNLibWebRTCSessionImpl)
final class OPNLibWebRTCSessionImpl: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate, @unchecked Sendable {
    @objc var owner: UnsafeMutableRawPointer?
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
    init(owner: UnsafeMutableRawPointer?) {
        self.owner = owner
        super.init()
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        NSLog("[LibWebRTC] signaling state=%ld", stateChanged.rawValue)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        NSLog("[LibWebRTC] ICE state=%ld", newState.rawValue)
        let ownerAddress = UInt(bitPattern: owner)
        DispatchQueue.main.async {
            let owner = UnsafeMutableRawPointer(bitPattern: ownerAddress)
            switch newState {
            case .connected, .completed:
                OPNLibWebRTCSessionOwnerCancelDisconnectGraceTimer(owner)
                OPNLibWebRTCSessionOwnerHandleConnectionState(owner, true, "" as NSString)
            case .disconnected:
                OPNLibWebRTCSessionOwnerStartDisconnectGraceTimer(owner, "libwebrtc ICE disconnected" as NSString)
            case .failed, .closed:
                OPNLibWebRTCSessionOwnerCancelDisconnectGraceTimer(owner)
                OPNLibWebRTCSessionOwnerHandleConnectionState(owner, false, "libwebrtc ICE failed" as NSString)
            default:
                break
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        NSLog("[LibWebRTC] ICE gathering state=%ld", newState.rawValue)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        OPNLibWebRTCSessionOwnerHandleLocalIceCandidate(owner, candidate.sdp as NSString, candidate.sdpMid as NSString? ?? "" as NSString, Int32(candidate.sdpMLineIndex))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        dataChannel.delegate = self
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        NSLog("[LibWebRTC] peer state=%ld", newState.rawValue)
        let ownerAddress = UInt(bitPattern: owner)
        DispatchQueue.main.async {
            let owner = UnsafeMutableRawPointer(bitPattern: ownerAddress)
            switch newState {
            case .connected:
                OPNLibWebRTCSessionOwnerCancelDisconnectGraceTimer(owner)
                OPNLibWebRTCSessionOwnerHandleConnectionState(owner, true, "" as NSString)
            case .disconnected:
                OPNLibWebRTCSessionOwnerStartDisconnectGraceTimer(owner, "libwebrtc peer connection disconnected" as NSString)
            case .failed, .closed:
                OPNLibWebRTCSessionOwnerCancelDisconnectGraceTimer(owner)
                OPNLibWebRTCSessionOwnerHandleConnectionState(owner, false, "libwebrtc peer connection failed" as NSString)
            default:
                break
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track else { return }
        if track.kind == kRTCMediaStreamTrackKindVideo {
            guard let videoTrack = track as? RTCVideoTrack else { return }
            NSLog("[LibWebRTC] remote video receiver added: %@", track.trackId)
            DispatchQueue.main.async { @MainActor [weak self] in
                self?.attachRemoteVideoTrack(videoTrack)
            }
        } else if track.kind == kRTCMediaStreamTrackKindAudio, let audioTrack = track as? RTCAudioTrack {
            audioTrack.isEnabled = true
            audioTrack.source.volume = OPNLibWebRTCSessionOwnerGameVolume(owner)
            remoteAudioTrack = audioTrack
            NSLog("[LibWebRTC] remote audio track enabled: %@ volume=%.2f", audioTrack.trackId, audioTrack.source.volume)
        }
    }

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        let open = dataChannel.readyState == .open
        OPNLibWebRTCSessionOwnerHandleDataChannelState(owner, dataChannel.label as NSString, open)
        NSLog("[LibWebRTC] data channel %@ state=%ld inputReady=%d", dataChannel.label, dataChannel.readyState.rawValue, OPNLibWebRTCSessionOwnerInputReady(owner) ? 1 : 0)
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        OPNLibWebRTCSessionOwnerHandleDataChannelMessage(owner, dataChannel.label as NSString, buffer.data as NSData)
    }

    @MainActor private func attachRemoteVideoTrack(_ videoTrack: RTCVideoTrack) {
        guard let nativeWindow = OPNLibWebRTCSessionOwnerNativeWindowHandle(owner) else {
            NSLog("[LibWebRTC] Cannot attach remote video: native view is missing")
            return
        }
        let parentView = Unmanaged<NSView>.fromOpaque(nativeWindow).takeUnretainedValue()
        guard RTCMTLNSVideoView.isMetalAvailable() else {
            NSLog("[LibWebRTC] Cannot attach remote video: Metal renderer is unavailable")
            return
        }

        if let remoteVideoTrack, let remoteVideoRenderer {
            remoteVideoTrack.remove(remoteVideoRenderer)
        }
        remoteVideoView?.removeFromSuperview()

        let targetFps = OPNLibWebRTCSessionOwnerTargetFps(owner)
        let metalView = OPNMetalVideoView(frame: parentView.bounds, targetFps: targetFps, owner: owner)
        let videoView: NSView = metalView
        let videoRenderer: RTCVideoRenderer = metalView
        OPNLibWebRTCSessionOwnerSetVideoRendererState(owner, "OPNMetalVideoView" as NSString, "libwebrtc Metal display" as NSString)
        videoView.autoresizingMask = [.width, .height]
        videoView.wantsLayer = true
        videoView.layer?.backgroundColor = NSColor.black.cgColor
        parentView.addSubview(videoView, positioned: .below, relativeTo: nil)
        videoTrack.add(videoRenderer)

        remoteVideoTrack = videoTrack
        remoteVideoView = videoView
        remoteVideoRenderer = videoRenderer
        NSLog("[LibWebRTC] Remote video renderer attached metal=1 targetFps=%d", targetFps)
    }
}
