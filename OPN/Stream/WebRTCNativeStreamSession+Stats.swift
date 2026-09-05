//  Stats and the adaptive bitrate they drive, plus microphone attachment and ICE server
//  translation.
//

import AppKit
import CoreVideo
import Darwin
import Foundation
import os
@preconcurrency import WebRTC

extension OPNLibWebRTCStreamSession {
    func handleStatsReport(_ report: [String: Any]) {
        os_unfair_lock_lock(&statsLock)
        latestStats.available = WebRTCSdp.bool(report["available"])
        latestStats.latencyMs = WebRTCSdp.double(report["latencyMs"], fallback: latestStats.latencyMs)
        latestStats.jitterMs = WebRTCSdp.double(report["jitterMs"], fallback: latestStats.jitterMs)
        latestStats.inboundBitrateMbps = WebRTCSdp.double(report["inboundBitrateMbps"], fallback: latestStats.inboundBitrateMbps)
        latestStats.packetLossPercent = WebRTCSdp.double(report["packetLossPercent"], fallback: latestStats.packetLossPercent)
        latestStats.decodeTimeMs = WebRTCSdp.double(report["decodeTimeMs"], fallback: latestStats.decodeTimeMs)
        latestStats.renderFps = WebRTCSdp.double(report["renderFps"], fallback: latestStats.renderFps)
        latestStats.framesReceived = WebRTCSdp.uint64(report["framesReceived"])
        latestStats.framesDropped = WebRTCSdp.uint64(report["framesDropped"])
        latestStats.packetsLost = WebRTCSdp.int64(report["packetsLost"])
        let decodedResolution = WebRTCSdp.string(report["resolution"])
        if !decodedResolution.isEmpty {
            if latestStats.resolution.isEmpty { latestStats.resolution = decodedResolution }
            latestStats.videoEnhancementSourceResolution = decodedResolution
        }
        latestStats.codec = WebRTCSdp.string(report["codec"]).isEmpty ? latestStats.codec : WebRTCSdp.string(report["codec"])
        latestStats.videoDecoder = WebRTCSdp.string(report["videoDecoder"]).isEmpty ? latestStats.videoDecoder : WebRTCSdp.string(report["videoDecoder"])
        latestStats.videoSink = WebRTCSdp.string(report["videoSink"]).isEmpty ? latestStats.videoSink : WebRTCSdp.string(report["videoSink"])
        latestStats.videoPipelineMode = WebRTCSdp.string(report["videoPipelineMode"]).isEmpty ? latestStats.videoPipelineMode : WebRTCSdp.string(report["videoPipelineMode"])
        os_unfair_lock_unlock(&statsLock)
        updateAdaptiveBitrate(report)
    }

    func resetStats(sessionInfo: [String: Any], settings: [String: Any]) {
        os_unfair_lock_lock(&statsLock)
        latestStats = OPNStreamStatsState()
        latestStats.transport = WebRTCSdp.string(sessionInfo["transport"], fallback: "WebRTC")
        latestStats.gpuType = WebRTCSdp.string(sessionInfo["gpuType"])
        latestStats.zone = WebRTCSdp.string(sessionInfo["zone"])
        latestStats.resolution = WebRTCSdp.string(settings["resolution"])
        latestStats.codec = WebRTCSdp.string(settings["codec"])
        latestStats.fps = WebRTCSdp.int(settings["fps"], fallback: 60)
        latestStats.videoDecoder = "libwebrtc"
        latestStats.videoSink = "OPNMetalVideoView"
        latestStats.videoPipelineMode = "libwebrtc Metal display"
        os_unfair_lock_unlock(&statsLock)
        previousStatsTimestampMs = 0
        previousBytesReceived = 0
        previousPacketsReceived = 0
        previousFramesDecoded = 0
        previousPacketsLost = 0
    }

    func updateAdaptiveBitrate(_ report: [String: Any]) {
        let timestampMs = WebRTCSdp.uint64(report["timestampMs"])
        guard timestampMs > 0 else { return }
        let bytesReceived = WebRTCSdp.uint64(report["bytesReceived"])
        let packetsReceived = WebRTCSdp.uint64(report["packetsReceived"])
        let framesDecoded = WebRTCSdp.uint64(report["framesDecoded"])
        let packetsLost = WebRTCSdp.int64(report["packetsLost"])
        guard previousStatsTimestampMs > 0 else {
            previousStatsTimestampMs = timestampMs
            previousBytesReceived = bytesReceived
            previousPacketsReceived = packetsReceived
            previousFramesDecoded = framesDecoded
            previousPacketsLost = packetsLost
            return
        }
        let dtMs = max(1, timestampMs - previousStatsTimestampMs)
        let lostDelta = max(0, packetsLost - previousPacketsLost)
        let packetDelta = max(0, Int64(packetsReceived >= previousPacketsReceived ? packetsReceived - previousPacketsReceived : 0))
        let lossPercent = packetDelta + lostDelta > 0 ? Double(lostDelta) * 100.0 / Double(packetDelta + lostDelta) : 0
        let byteDelta = bytesReceived >= previousBytesReceived ? bytesReceived - previousBytesReceived : 0
        let bitrateMbps = Double(byteDelta) * 8.0 / Double(dtMs) / 1000.0
        let framesDelta = framesDecoded >= previousFramesDecoded ? framesDecoded - previousFramesDecoded : 0
        let fps = Double(framesDelta) * 1000.0 / Double(dtMs)
        os_unfair_lock_lock(&statsLock)
        latestStats.inboundBitrateMbps = bitrateMbps
        latestStats.packetLossPercent = lossPercent
        if fps > 0 { latestStats.fps = Int(fps.rounded()) }
        os_unfair_lock_unlock(&statsLock)
        previousStatsTimestampMs = timestampMs
        previousBytesReceived = bytesReceived
        previousPacketsReceived = packetsReceived
        previousFramesDecoded = framesDecoded
        previousPacketsLost = packetsLost
        guard configuredMaxBitrateMbps > 0, timestampMs - lastAdaptiveBitrateChangeMs > 4000 else { return }
        if lossPercent > 3.0 || fps < Double(max(15, targetFps / 2)) {
            adaptiveCongestionScore += 1
            adaptiveRecoveryScore = 0
        } else {
            adaptiveRecoveryScore += 1
            adaptiveCongestionScore = 0
        }
        if adaptiveCongestionScore >= 2, adaptiveBitrateMbps > minAdaptiveBitrateMbps {
            adaptiveBitrateMbps = max(minAdaptiveBitrateMbps, adaptiveBitrateMbps * 85 / 100)
            applyRuntimeBitrateLimit(adaptiveBitrateMbps, reason: "adaptive congestion")
            lastAdaptiveBitrateChangeMs = timestampMs
            adaptiveCongestionScore = 0
        } else if adaptiveRecoveryScore >= 5, adaptiveBitrateMbps < configuredMaxBitrateMbps {
            adaptiveBitrateMbps = min(configuredMaxBitrateMbps, adaptiveBitrateMbps * 110 / 100 + 1)
            applyRuntimeBitrateLimit(adaptiveBitrateMbps, reason: "adaptive recovery")
            lastAdaptiveBitrateChangeMs = timestampMs
            adaptiveRecoveryScore = 0
        }
    }

    func applyRuntimeBitrateLimit(_ mbps: Int, reason: String) {
        statsController.applyRuntimeBitrateLimit(mbps: mbps, reason: reason, sessionImpl: impl)
    }

    func prepareMicrophoneIfNeeded(impl: OPNLibWebRTCSessionImpl, factory: RTCPeerConnectionFactory) {
        guard WebRTCSdp.string(settings["microphoneMode"]) != "disabled", impl.localMicrophoneTrack == nil else { return }
        let audioSource = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        audioSource.volume = microphoneVolume
        let audioTrack = factory.audioTrack(with: audioSource, trackId: "opennow-microphone")
        audioTrack.isEnabled = microphoneEnabled
        if attachMicrophoneTrack(impl: impl, audioTrack: audioTrack) {
            impl.localMicrophoneTrack = audioTrack
            if impl.audioDevice == nil {
                audioController.startMicrophoneLevelPolling(sessionImpl: impl, statsQueue: statsQueue)
            }
        } else {
            WebRTCMediaTelemetry.capture("webrtc.native.microphone.attach.error", level: .warning, message: "Failed to attach local microphone track.")
        }
    }

    func attachMicrophoneTrack(impl: OPNLibWebRTCSessionImpl, audioTrack: RTCAudioTrack) -> Bool {
        guard let peerConnection = impl.peerConnection else { return false }
        if let transceiver = findMicrophoneTransceiver(peerConnection: peerConnection) {
            var target = transceiver.direction
            if transceiver.direction == .recvOnly { target = .sendRecv }
            else if transceiver.direction == .inactive { target = .sendOnly }
            if target != transceiver.direction {
                var directionError: NSError?
                transceiver.setDirection(target, error: &directionError)
                if let directionError { WebRTCMediaTelemetry.capture("webrtc.native.microphone.direction.error", level: .warning, message: "Failed to set microphone transceiver direction.", attributes: ["error": directionError.localizedDescription]) }
            }
            transceiver.sender.track = audioTrack
            transceiver.sender.streamIds = ["mic"]
            impl.localMicrophoneSender = transceiver.sender
            return true
        }
        guard let sender = peerConnection.add(audioTrack, streamIds: ["mic"]) else { return false }
        impl.localMicrophoneSender = sender
        return true
    }

    func findMicrophoneTransceiver(peerConnection: RTCPeerConnection) -> RTCRtpTransceiver? {
        var firstAvailableAudio: RTCRtpTransceiver?
        var firstSendableAudio: RTCRtpTransceiver?
        for transceiver in peerConnection.transceivers where transceiver.mediaType == .audio && !transceiver.isStopped {
            if transceiver.mid == "3" { return transceiver }
            if firstAvailableAudio == nil, transceiver.sender.track == nil { firstAvailableAudio = transceiver }
            if firstSendableAudio == nil, transceiver.direction == .sendRecv || transceiver.direction == .recvOnly || transceiver.direction == .inactive { firstSendableAudio = transceiver }
        }
        return firstAvailableAudio ?? firstSendableAudio
    }

    func iceServers(from sessionInfo: [String: Any]) -> [RTCIceServer] {
        WebRTCSdp.array(sessionInfo["iceServers"]).compactMap { item in
            guard let dictionary = item as? [String: Any] else { return nil }
            let urls = WebRTCSdp.stringArray(dictionary["urls"])
            guard !urls.isEmpty else { return nil }
            return RTCIceServer(urlStrings: urls, username: WebRTCSdp.emptyNil(WebRTCSdp.string(dictionary["username"])), credential: WebRTCSdp.emptyNil(WebRTCSdp.string(dictionary["credential"])))
        }
    }

    func iceServers(from turnServers: [NVSTTurnServer]) -> [RTCIceServer] {
        turnServers.compactMap { server in
            guard !server.urls.isEmpty else { return nil }
            return RTCIceServer(urlStrings: server.urls, username: WebRTCSdp.emptyNil(server.username), credential: WebRTCSdp.emptyNil(server.credential))
        }
    }

    func rewrittenRemoteCandidate(_ candidate: String) -> String {
        rewriteIceCandidateLine(candidate, ip: remoteCandidateOverrideIp, port: remoteCandidateOverridePort)
    }
}
