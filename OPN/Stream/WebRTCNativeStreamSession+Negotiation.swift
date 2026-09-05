//  Bringing a libwebrtc session up: the peer-connection factory, the ICE configuration, the offer
//  rewrite this receiver needs, and the answer that closes the handshake.
//

import AppKit
import CoreVideo
import Darwin
import Foundation
import os
@preconcurrency import WebRTC

extension OPNLibWebRTCStreamSession {
    /// Builds the libwebrtc session implementation and its factory, preferring the CoreAudio RTC
    /// device and falling back to WebRTC's own when it cannot be created.
    func makeSessionImpl() -> (OPNLibWebRTCSessionImpl, RTCPeerConnectionFactory)? {
        let impl = OPNLibWebRTCSessionImpl(owner: self)
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        // Advertises H265 with real fmtp params so libwebrtc negotiates HEVC instead of dropping it
        // and falling back to AV1 (undecodable before Apple M3 → black screen). See OPNVideoDecoderFactory.
        // A 10-bit or HDR session needs the bitstream's depth to survive decode; libwebrtc's own
        // HEVC decoder always emits 8-bit NV12.
        let wantsBitstreamDepth = WebRTCSdp.string(settings["colorQuality"]).lowercased().hasPrefix("10bit") || WebRTCSdp.bool(settings["enableHdr"])
        let decoderFactory = OPNVideoDecoderFactory(decodesHEVCAtBitstreamDepth: wantsBitstreamDepth)
        let audioDevice = OPNCoreAudioRTCDevice(owner: self, playoutChannelCount: WebRTCSdp.int(settings["audioChannelCount"], fallback: 2))
        impl.audioDevice = audioDevice
        impl.factory = RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory, audioDevice: audioDevice)
        if impl.factory == nil {
            WebRTCMediaTelemetry.capture("webrtc.native.factory.audio_device_fallback", level: .warning, message: "CoreAudio RTC device factory failed; using default WebRTC audio device.")
            impl.audioDevice = nil
            impl.factory = RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)
        } else {
            WebRTCMediaTelemetry.capture("webrtc.native.factory.audio_device", level: .debug, message: "CoreAudio RTC audio device enabled.")
        }
        guard let factory = impl.factory else { return nil }
        return (impl, factory)
    }

    /// ICE servers come from the seat's session info when it named any, and otherwise from the
    /// NVST offer's TURN list; an empty result means a direct connection with injected candidates.
    func makeConfiguration(sessionInfo: [String: Any], nvstProfile: NVSTTransportProfile) -> RTCConfiguration {
        let configuration = RTCConfiguration()
        let configuredIceServers = iceServers(from: sessionInfo)
        let nvstIceServers = configuredIceServers.isEmpty ? iceServers(from: nvstProfile.turnServers) : []
        configuration.iceServers = configuredIceServers.isEmpty ? nvstIceServers : configuredIceServers
        configuration.iceTransportPolicy = nvstProfile.iceTransportPolicy == .relay ? .relay : .all
        let iceSource = configuredIceServers.isEmpty ? (nvstIceServers.isEmpty ? "manualDirect" : "nvstSdp") : "sessionInfo"
        WebRTCMediaTelemetry.capture("webrtc.native.ice_servers", level: .debug, message: "Configured ICE servers.", attributes: ["count": String(configuration.iceServers.count), "source": iceSource, "policy": nvstProfile.iceTransportPolicy == .relay ? "relay" : "all"])
        configuration.sdpSemantics = .unifiedPlan
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require
        configuration.tcpCandidatePolicy = .disabled
        configuration.continualGatheringPolicy = WebRTCSdp.envFlagEnabled("OPN_ENABLE_WEBRTC_CONTINUAL_ICE_GATHERING", defaultValue: false) ? .gatherContinually : .gatherOnce
        configuration.iceConnectionReceivingTimeout = 30_000
        return configuration
    }

    /// Rewrites the seat's offer for this receiver: H265 level/tier the local decoder can accept,
    /// an optional codec filter, and embedded ICE candidates pointed at the seat's real address.
    func processedOffer(_ offerSdp: String, factory: RTCPeerConnectionFactory, manualIceIp: String, manualIcePort: Int) -> String {
        var processedOfferSdp = offerSdp
        let requestedCodec = WebRTCSdp.normalizedCodec(WebRTCSdp.string(settings["codec"]))
        let requestedCodecSupported = OPNWebRTCCodecSupport.supportsCodec(factory: factory, normalizedCodec: requestedCodec)
        OPNLogCapture.appendEvent("[LibWebRTC] Start settings resolution=\(WebRTCSdp.string(settings["resolution"], fallback: "unknown")) fps=\(WebRTCSdp.int(settings["fps"])) codec=\(requestedCodec.isEmpty ? "unknown" : requestedCodec) requestedCodecSupported=\(requestedCodecSupported ? "yes" : "no") bitrate=\(WebRTCSdp.int(settings["maxBitrateMbps"]))Mbps h265Rewrite=\(WebRTCSdp.envFlagEnabled("OPN_ENABLE_LIBWEBRTC_H265_OFFER_REWRITE", defaultValue: true) ? "on" : "off") codecFilter=\(WebRTCSdp.envFlagEnabled("OPN_ENABLE_LIBWEBRTC_CODEC_FILTER", defaultValue: false) ? "on" : "off") answerMunge=\(WebRTCSdp.envFlagEnabled("OPN_ENABLE_LIBWEBRTC_ANSWER_MUNGE", defaultValue: false) ? "on" : "off") receiverCapabilities=\(OPNWebRTCCodecSupport.receiverCapabilitiesSummary(factory: factory))")
        if requestedCodec == "H265", requestedCodecSupported, WebRTCSdp.envFlagEnabled("OPN_ENABLE_LIBWEBRTC_H265_OFFER_REWRITE", defaultValue: true) {
            let support = OPNWebRTCCodecSupport.h265ReceiverSupport(factory: factory)
            processedOfferSdp = WebRTCSdp.rewriteH265OfferForReceiver(processedOfferSdp, maxMainLevelId: WebRTCSdp.int(support["maxMainLevelId"]), maxMain10LevelId: WebRTCSdp.int(support["maxMain10LevelId"]), supportsHighTier: WebRTCSdp.bool(support["supportsHighTier"]))
        }
        if WebRTCSdp.isSupportedCodecPreference(requestedCodec), requestedCodecSupported, WebRTCSdp.envFlagEnabled("OPN_ENABLE_LIBWEBRTC_CODEC_FILTER", defaultValue: false) {
            processedOfferSdp = WebRTCSdp.preferCodecInOffer(processedOfferSdp, normalizedCodec: requestedCodec)
        } else if !requestedCodec.isEmpty, !requestedCodecSupported {
            WebRTCMediaTelemetry.capture("webrtc.native.codec.unsupported_offer", level: .warning, message: "Requested codec is not supported; retaining full offer.", attributes: ["codec": requestedCodec])
        }
        return rewriteEmbeddedIceCandidates(processedOfferSdp, ip: manualIceIp, port: manualIcePort)
    }

    /// Everything the asynchronous negotiation callbacks need. Immutable, and only read on the
    /// callback queue, so the unchecked conformance is the whole story.
    struct NegotiationContext: @unchecked Sendable {
        let generation: UInt64
        let constraints: RTCMediaConstraints
        /// The seat's original offer, retried verbatim when the rewritten one is rejected.
        let offerSdp: String
        let remoteOfferSdp: String
        let remoteNVSTSdp: String
        let remoteNVSTServerOverrides: String
        let canRetryOriginalOffer: Bool
        let shouldInjectDirectCandidates: Bool
        let manualIceIp: String
        /// The seat always listens for direct media here, whatever port the session info named.
        let directIcePort = 47998
    }

    /// Applies the remote offer, falling back to the seat's original when the rewritten one is
    /// rejected, then answers it.
    func negotiate(impl: OPNLibWebRTCSessionImpl, peerConnection: RTCPeerConnection, context: NegotiationContext) {
        let offer = RTCSessionDescription(type: .offer, sdp: context.remoteOfferSdp)
        peerConnection.setRemoteDescription(offer) { [weak self, weak impl] error in
            guard let self, self.callbackGeneration == context.generation else { return }
            guard let error else {
                guard let impl, let peerConnection = impl.peerConnection, let factory = impl.factory else { return }
                self.remoteDescriptionDidSet(impl: impl, peerConnection: peerConnection, factory: factory, offerSdp: context.remoteOfferSdp, context: context)
                return
            }
            guard context.canRetryOriginalOffer else {
                self.handleConnectionState(false, error: "setRemoteDescription failed: \(error.localizedDescription)")
                return
            }
            guard let impl, let peerConnection = impl.peerConnection, impl.factory != nil else { return }
            let originalOffer = RTCSessionDescription(type: .offer, sdp: context.offerSdp)
            peerConnection.setRemoteDescription(originalOffer) { [weak self, weak impl] retryError in
                guard let self, self.callbackGeneration == context.generation else { return }
                guard retryError == nil else {
                    self.handleConnectionState(false, error: "setRemoteDescription failed: \(retryError?.localizedDescription ?? error.localizedDescription)")
                    return
                }
                guard let impl, let peerConnection = impl.peerConnection, let factory = impl.factory else { return }
                self.remoteDescriptionDidSet(impl: impl, peerConnection: peerConnection, factory: factory, offerSdp: context.offerSdp, context: context)
            }
        }
    }

    func remoteDescriptionDidSet(impl: OPNLibWebRTCSessionImpl,
                                         peerConnection: RTCPeerConnection,
                                         factory: RTCPeerConnectionFactory,
                                         offerSdp: String,
                                         context: NegotiationContext) {
        markRemoteDescriptionReady()
        injectDirectCandidatesIfNeeded(offerSdp: offerSdp, context: context)
        prepareMicrophoneIfNeeded(impl: impl, factory: factory)
        createAndSendAnswer(peerConnection: peerConnection,
                            factory: factory,
                            context: context,
                            codecPreferenceApplied: applyCodecPreference(peerConnection: peerConnection, factory: factory, context: context),
                            retriedWithoutCodecPreference: false)
    }

    /// Asks libwebrtc to prefer the negotiated codec, when the remote offer actually carries it.
    func applyCodecPreference(peerConnection: RTCPeerConnection, factory: RTCPeerConnectionFactory, context: NegotiationContext) -> Bool {
        let answerCodec = WebRTCSdp.normalizedCodec(WebRTCSdp.string(settings["codec"]))
        guard !answerCodec.isEmpty else { return false }
        guard WebRTCSdp.videoSdpContainsCodec(context.remoteOfferSdp, normalizedCodec: answerCodec) else {
            WebRTCMediaTelemetry.capture("webrtc.native.codec.preference_skipped", level: .debug, message: "Skipping codec preference because the remote offer does not include it.", attributes: ["codec": answerCodec])
            return false
        }
        let applied = OPNWebRTCCodecSupport.applyVideoCodecPreference(factory: factory, peerConnection: peerConnection, normalizedCodec: answerCodec)
        if !applied {
            WebRTCMediaTelemetry.capture("webrtc.native.codec.preference_unaccepted", level: .warning, message: "No video transceiver accepted codec preference before answer.", attributes: ["codec": answerCodec])
        }
        return applied
    }

    func createAndSendAnswer(peerConnection: RTCPeerConnection,
                                     factory: RTCPeerConnectionFactory,
                                     context: NegotiationContext,
                                     codecPreferenceApplied: Bool,
                                     retriedWithoutCodecPreference: Bool) {
        peerConnection.answer(for: context.constraints) { [weak self, weak impl] answer, answerError in
            guard let self, self.callbackGeneration == context.generation else { return }
            guard let impl, let peerConnection = impl.peerConnection, let answer else {
                self.handleConnectionState(false, error: "createAnswer failed: \(answerError?.localizedDescription ?? "unknown")")
                return
            }
            let mungedAnswer = WebRTCSdp.envFlagEnabled("OPN_ENABLE_LIBWEBRTC_ANSWER_MUNGE", defaultValue: false) ? WebRTCSdp.mungeAnswerSdp(answer.sdp, maxBitrateKbps: max(1000, WebRTCSdp.int(self.settings["maxBitrateMbps"], fallback: 50) * 1000)) : answer.sdp
            let audioChannelCount = WebRTCSdp.int(self.settings["audioChannelCount"], fallback: 2)
            let answerSdp = WebRTCSdp.applyingSurroundAudio(WebRTCSdp.alignH265AnswerFmtpToOffer(mungedAnswer, offerSdp: context.remoteOfferSdp), channels: audioChannelCount)
            WebRTCSdp.logVideoSdpSummary("answer-video", answerSdp)
            if audioChannelCount > 2 {
                OPNLogCapture.appendEvent("[LibWebRTC] answer requests \(audioChannelCount)-channel multiopus audio")
            }
            guard WebRTCSdp.videoSdpHasMediaCodec(answerSdp) else {
                if codecPreferenceApplied, !retriedWithoutCodecPreference, OPNWebRTCCodecSupport.resetVideoCodecPreferences(peerConnection: peerConnection) {
                    OPNLogCapture.appendEvent("[LibWebRTC] createAnswer rejected video after codec preference; retrying with default codec preferences")
                    self.createAndSendAnswer(peerConnection: peerConnection, factory: factory, context: context, codecPreferenceApplied: codecPreferenceApplied, retriedWithoutCodecPreference: true)
                    return
                }
                OPNLogCapture.appendEvent("[LibWebRTC] createAnswer produced no video codec failureContext retriedWithoutCodecPreference=\(retriedWithoutCodecPreference ? "yes" : "no") codecPreferenceApplied=\(codecPreferenceApplied ? "yes" : "no") offer=\(WebRTCSdp.buildSdpMediaSummary(context.remoteOfferSdp, label: "failure-offer")) answer=\(WebRTCSdp.buildSdpMediaSummary(answerSdp, label: "failure-answer"))")
                self.handleConnectionState(false, error: "createAnswer produced no negotiated video media codec")
                return
            }
            self.setLocalAnswer(answerSdp, peerConnection: peerConnection, context: context)
        }
    }

    func setLocalAnswer(_ answerSdp: String, peerConnection: RTCPeerConnection, context: NegotiationContext) {
        peerConnection.setLocalDescription(RTCSessionDescription(type: .answer, sdp: answerSdp)) { [weak self] localError in
            guard let self, self.callbackGeneration == context.generation else { return }
            if let localError {
                self.handleConnectionState(false, error: "setLocalDescription failed: \(localError.localizedDescription)")
                return
            }
            os_unfair_lock_lock(&self.statsLock)
            self.latestStats.videoPipelineMode = "libwebrtc answer sent"
            os_unfair_lock_unlock(&self.statsLock)
            self.onAnswer?(answerSdp, NVSTSessionDescriptionBuilder.buildAnswerExtension(settings: self.settings, credentials: NVSTSessionDescriptionBuilder.iceCredentials(from: answerSdp), remoteNVSTSdp: context.remoteNVSTSdp, serverOverrides: context.remoteNVSTServerOverrides))
        }
    }

    /// With no ICE servers the seat expects a direct candidate pointing at its media port.
    func injectDirectCandidatesIfNeeded(offerSdp: String, context: NegotiationContext) {
        guard context.shouldInjectDirectCandidates, !context.manualIceIp.isEmpty else { return }
        let serverIceUfrag = Self.iceUfrag(fromOfferSdp: offerSdp)
        guard !serverIceUfrag.isEmpty else { return }
        injectManualIceCandidate(offerSdp: offerSdp, serverIceUfrag: serverIceUfrag, ip: context.manualIceIp, port: context.directIcePort)
    }
}
