#include "OPNLibWebRTCStreamSession.h"
#include "OPNCoreAudioRTCDevice.h"
#include "OPNLibWebRTCSessionImpl.h"
#include "OPNNvstSdpBuilder.h"
#include "OPNWebRTCCodecSupport.h"
#include "OPNWebRTCSdpUtils.h"

#import <Foundation/Foundation.h>

#if defined(OPN_HAVE_LIBWEBRTC)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-umbrella"
#import <WebRTC/WebRTC.h>
#import <WebRTC/RTCAudioDevice.h>
#pragma clang diagnostic pop
#endif

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <mutex>
#include <string>
#include <utility>

namespace OPN {

static NSString *OPNStringToNSString(const std::string &value) {
    return [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding] ?: @"";
}

static std::string OPNNSStringToString(NSString *value) {
    return value ? std::string(value.UTF8String ?: "") : std::string();
}

static bool OPNEnvFlagEnabled(const char *name, bool defaultValue) {
    const char *value = getenv(name);
    if (!value || !*value) return defaultValue;
    std::string normalized(value);
    std::transform(normalized.begin(), normalized.end(), normalized.begin(), [](unsigned char c) { return (char)std::tolower(c); });
    return !(normalized == "0" || normalized == "false" || normalized == "no" || normalized == "off");
}

#if defined(OPN_HAVE_LIBWEBRTC)
static OPNLibWebRTCSessionImpl *OPNImplFromOpaque(void *opaque) {
    return (__bridge OPNLibWebRTCSessionImpl *)opaque;
}

static const char *OPNRTCRtpTransceiverDirectionName(RTCRtpTransceiverDirection direction) {
    switch (direction) {
        case RTCRtpTransceiverDirectionSendRecv: return "sendrecv";
        case RTCRtpTransceiverDirectionSendOnly: return "sendonly";
        case RTCRtpTransceiverDirectionRecvOnly: return "recvonly";
        case RTCRtpTransceiverDirectionInactive: return "inactive";
        case RTCRtpTransceiverDirectionStopped: return "stopped";
    }
    return "unknown";
}

static RTCRtpTransceiver *OPNFindMicrophoneTransceiver(RTCPeerConnection *peerConnection) {
    RTCRtpTransceiver *firstAvailableAudio = nil;
    RTCRtpTransceiver *firstSendableAudio = nil;
    for (RTCRtpTransceiver *transceiver in peerConnection.transceivers) {
        if (transceiver.mediaType != RTCRtpMediaTypeAudio || transceiver.isStopped) continue;
        if ([transceiver.mid isEqualToString:@"3"]) return transceiver;
        if (!firstAvailableAudio && !transceiver.sender.track) firstAvailableAudio = transceiver;
        if (!firstSendableAudio &&
            (transceiver.direction == RTCRtpTransceiverDirectionSendRecv ||
             transceiver.direction == RTCRtpTransceiverDirectionRecvOnly ||
             transceiver.direction == RTCRtpTransceiverDirectionInactive)) {
            firstSendableAudio = transceiver;
        }
    }
    return firstAvailableAudio ?: firstSendableAudio;
}

static bool OPNAttachMicrophoneTrack(OPNLibWebRTCSessionImpl *impl, RTCAudioTrack *audioTrack) {
    if (!impl.peerConnection || !audioTrack) return false;

    RTCRtpTransceiver *transceiver = OPNFindMicrophoneTransceiver(impl.peerConnection);
    if (transceiver) {
        NSError *directionError = nil;
        RTCRtpTransceiverDirection targetDirection = transceiver.direction;
        if (transceiver.direction == RTCRtpTransceiverDirectionRecvOnly) {
            targetDirection = RTCRtpTransceiverDirectionSendRecv;
        } else if (transceiver.direction == RTCRtpTransceiverDirectionInactive) {
            targetDirection = RTCRtpTransceiverDirectionSendOnly;
        }
        if (targetDirection != transceiver.direction) {
            [transceiver setDirection:targetDirection error:&directionError];
            if (directionError) {
                OPNLogError(@"[LibWebRTC] failed to set microphone transceiver direction: %@", directionError.localizedDescription);
            }
        }
        transceiver.sender.track = audioTrack;
        transceiver.sender.streamIds = @[@"mic"];
        impl.localMicrophoneSender = transceiver.sender;
        OPNLogInfo(@"[LibWebRTC] local microphone track attached to transceiver mid=%@ direction=%s target=%s enabled=%d volume=%.2f",
              transceiver.mid ?: @"(none)",
              OPNRTCRtpTransceiverDirectionName(transceiver.direction),
              OPNRTCRtpTransceiverDirectionName(targetDirection),
              audioTrack.isEnabled,
              audioTrack.source.volume);
        return true;
    }

    RTCRtpSender *sender = [impl.peerConnection addTrack:audioTrack streamIds:@[@"mic"]];
    if (!sender) return false;
    impl.localMicrophoneSender = sender;
    OPNLogInfo(@"[LibWebRTC] local microphone track added without negotiated transceiver; renegotiation may be required");
    return true;
}
#endif

void LibWebRTCStreamSession::Start(const SessionInfo &session,
                                   const std::string &offerSdp,
                                   const StreamSettings &settings,
                                   StreamStateCallback onState) {
    Stop();
    m_callbackLiveness = std::make_shared<std::atomic_bool>(true);
    auto callbackLiveness = m_callbackLiveness;
    m_settings = settings;
    m_configuredMaxBitrateMbps = std::max(1, settings.maxBitrateMbps);
    m_adaptiveBitrateMbps = m_configuredMaxBitrateMbps;
    m_minAdaptiveBitrateMbps = std::min(m_configuredMaxBitrateMbps, std::max(8, m_configuredMaxBitrateMbps * 35 / 100));
    m_adaptiveCongestionScore = 0;
    m_adaptiveRecoveryScore = 0;
    m_lastAdaptiveBitrateChangeMs = 0;
    m_onState = std::move(onState);
    {
        std::lock_guard<std::mutex> lock(m_statsMutex);
        m_latestStats = StreamStats{};
        m_latestStats.gpuType = session.gpuType;
        m_latestStats.zone = session.zone;
        m_latestStats.resolution = settings.resolution;
        m_latestStats.codec = settings.codec;
        m_latestStats.fps = settings.fps;
        m_latestStats.videoDecoder = "libwebrtc";
        m_latestStats.videoSink = "OPNMetalVideoView";
        m_latestStats.videoPipelineMode = "libwebrtc Metal display";
        m_latestStats.videoPixelFormat = "pending";
        m_latestStats.videoRenderMode = "pending";
        m_latestStats.videoFrameSource = "pending";
        m_latestStats.videoRenderPath = "pending";
        m_latestStats.videoRendererFallback = "";
        m_latestStats.videoEnhancementConfiguredTier = "pending";
        m_latestStats.videoEnhancementActiveTier = "pending";
        m_latestStats.videoEnhancementFallbackReason = "";
        m_latestStats.videoEnhancementSourceResolution = "pending";
        m_latestStats.videoEnhancementDrawableResolution = "pending";
        m_latestStats.videoEnhancementDiagnostics = "";
        m_latestStats.videoEnhancementFrameTimeMs = -1.0;
        m_latestStats.videoEnhancementDroppedFrames = 0;
        m_statsRequestInFlight = false;
        m_previousStatsTimestampMs = 0;
        m_lastStatsRequestMs = 0;
        m_previousBytesReceived = 0;
        m_previousPacketsReceived = 0;
        m_previousFramesDecoded = 0;
        m_previousPacketsLost = 0;
    }
    if (settings.microphoneMode != "disabled" && !m_microphoneEnabled) {
        m_microphoneEnabled = settings.microphoneMode == "voice-activity";
    }

#if defined(OPN_HAVE_LIBWEBRTC)
    if (!IsAvailable()) {
        const std::string error = AvailabilityDescription();
        if (m_onState) m_onState(false, error);
        return;
    }

    auto *impl = [[OPNLibWebRTCSessionImpl alloc] initWithOwner:this];
    impl.audioDevice = [[OPNCoreAudioRTCDevice alloc] init];
    impl.audioDevice.owner = this;
    RTCDefaultVideoEncoderFactory *encoderFactory = [[RTCDefaultVideoEncoderFactory alloc] init];
    RTCDefaultVideoDecoderFactory *decoderFactory = [[RTCDefaultVideoDecoderFactory alloc] init];
    impl.factory = [[RTCPeerConnectionFactory alloc] initWithEncoderFactory:encoderFactory
                                                             decoderFactory:decoderFactory
                                                                audioDevice:impl.audioDevice];
    if (!impl.factory) {
        OPNLogError(@"[LibWebRTC] CoreAudio RTC device factory failed; falling back to default WebRTC audio device");
        impl.audioDevice = nil;
        impl.factory = [[RTCPeerConnectionFactory alloc] init];
    } else {
        OPNLogInfo(@"[LibWebRTC] CoreAudio RTC audio device enabled");
    }

    RTCConfiguration *configuration = [[RTCConfiguration alloc] init];
    NSMutableArray<RTCIceServer *> *iceServers = [NSMutableArray array];
    for (const IceServer &server : session.iceServers) {
        NSMutableArray<NSString *> *urls = [NSMutableArray array];
        for (const std::string &url : server.urls) {
            [urls addObject:OPNStringToNSString(url)];
        }
        if (urls.count == 0) continue;
        RTCIceServer *iceServer = [[RTCIceServer alloc] initWithURLStrings:urls
                                                                  username:server.username.empty() ? nil : OPNStringToNSString(server.username)
                                                                credential:server.credential.empty() ? nil : OPNStringToNSString(server.credential)];
        [iceServers addObject:iceServer];
    }
    configuration.iceServers = iceServers;
    configuration.sdpSemantics = RTCSdpSemanticsUnifiedPlan;
    configuration.bundlePolicy = RTCBundlePolicyMaxBundle;
    configuration.rtcpMuxPolicy = RTCRtcpMuxPolicyRequire;
    configuration.tcpCandidatePolicy = RTCTcpCandidatePolicyDisabled;
    configuration.continualGatheringPolicy = RTCContinualGatheringPolicyGatherOnce;
    configuration.iceConnectionReceivingTimeout = 30000;

    RTCMediaConstraints *constraints = [[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil optionalConstraints:nil];
    impl.peerConnection = [impl.factory peerConnectionWithConfiguration:configuration constraints:constraints delegate:impl];
    if (!impl.peerConnection) {
        const std::string error = "failed to create libwebrtc peer connection";
        if (m_onState) m_onState(false, error);
        return;
    }

    m_impl = (__bridge_retained void *)impl;
    StartAudioDeviceMonitoring();
    CreateInputChannel();

    std::string processedOfferSdp = offerSdp;
    if (offerSdp.find("0.0.0.0") != std::string::npos) {
        std::string mediaIp = OPNExtractPublicIp(!session.mediaConnectionInfo.ip.empty() ? session.mediaConnectionInfo.ip : session.serverIp);
        OPNLogInfo(@"[LibWebRTC] Offer contains 0.0.0.0 placeholders; leaving SDP unchanged for native parser compatibility (mediaIp=%s)",
              mediaIp.empty() ? "unknown" : mediaIp.c_str());
    }
    std::string requestedCodec = OPNNormalizeCodec(settings.codec);
    bool requestedCodecSupported = OPNLibWebRTCSupportsCodec(impl.factory, requestedCodec);
    if (requestedCodec == "H265" && requestedCodecSupported && OPNEnvFlagEnabled("OPN_ENABLE_LIBWEBRTC_H265_OFFER_REWRITE", true)) {
        int maxMainLevelId = 0;
        int maxMain10LevelId = 0;
        bool supportsHighTier = false;
        if (OPNLibWebRTCH265ReceiverSupport(impl.factory, maxMainLevelId, maxMain10LevelId, supportsHighTier)) {
            processedOfferSdp = OPNRewriteH265OfferForReceiver(processedOfferSdp, maxMainLevelId, maxMain10LevelId, supportsHighTier);
        }
    } else if (requestedCodec == "H265" && requestedCodecSupported) {
        OPNLogInfo(@"[LibWebRTC] OPN_ENABLE_LIBWEBRTC_H265_OFFER_REWRITE=0; retaining original H265 offer parameters");
    }
    if (OPNIsSupportedCodecPreference(requestedCodec) && requestedCodecSupported && OPNEnvFlagEnabled("OPN_ENABLE_LIBWEBRTC_CODEC_FILTER", false)) {
        processedOfferSdp = OPNPreferCodecInOffer(processedOfferSdp, requestedCodec);
    } else if (OPNIsSupportedCodecPreference(requestedCodec) && !requestedCodecSupported) {
        OPNLogInfo(@"[LibWebRTC] Requested codec %s is not supported by this WebRTC.framework; retaining full offer so libwebrtc can negotiate a supported fallback", requestedCodec.c_str());
    } else if (OPNIsSupportedCodecPreference(requestedCodec)) {
        OPNLogInfo(@"[LibWebRTC] OPN_ENABLE_LIBWEBRTC_CODEC_FILTER=0; retaining all video payloads for requested codec %s", requestedCodec.c_str());
    } else {
        OPNLogInfo(@"[LibWebRTC] Unsupported requested codec preference '%s'; retaining all video payloads", settings.codec.c_str());
    }
    OPNLogVideoSdpSummary("offer-video", processedOfferSdp);

    __weak OPNLibWebRTCSessionImpl *weakImpl = impl;
    NSString *processedOfferString = OPNStringToNSString(processedOfferSdp);
    NSString *originalOfferString = OPNStringToNSString(offerSdp);
    const bool canRetryOriginalOffer = processedOfferSdp != offerSdp;
    void (^handleRemoteDescriptionSet)(void) = ^{
        if (!callbackLiveness->load()) return;
        OPNLibWebRTCSessionImpl *strongImpl = weakImpl;
        if (!strongImpl) return;

        std::string answerCodecPreference = OPNNormalizeCodec(this->m_settings.codec);
        if (OPNIsSupportedCodecPreference(answerCodecPreference)) {
            if (!OPNApplyVideoCodecPreference(strongImpl.factory, strongImpl.peerConnection, answerCodecPreference)) {
                OPNLogInfo(@"[LibWebRTC] No video transceiver accepted %s codec preference before answer", answerCodecPreference.c_str());
            }
        }

        if (this->m_settings.microphoneMode != "disabled" && !strongImpl.localMicrophoneTrack) {
            RTCMediaConstraints *audioConstraints = [[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil optionalConstraints:nil];
            RTCAudioSource *audioSource = [strongImpl.factory audioSourceWithConstraints:audioConstraints];
            audioSource.volume = this->m_microphoneVolumeLevel;
            RTCAudioTrack *audioTrack = [strongImpl.factory audioTrackWithSource:audioSource trackId:@"opennow-microphone"];
            audioTrack.isEnabled = this->m_microphoneEnabled;
            if (OPNAttachMicrophoneTrack(strongImpl, audioTrack)) {
                strongImpl.localMicrophoneTrack = audioTrack;
                this->StartMicrophoneLevelPolling();
            } else {
                OPNLogError(@"[LibWebRTC] failed to attach local microphone track");
            }
        }

        RTCMediaConstraints *answerConstraints = [[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil optionalConstraints:nil];
        [strongImpl.peerConnection answerForConstraints:answerConstraints completionHandler:^(RTCSessionDescription *answer, NSError *answerError) {
            if (!callbackLiveness->load()) return;
            OPNLibWebRTCSessionImpl *answerImpl = weakImpl;
            if (!answerImpl) return;
            if (answerError || !answer) {
                const std::string message = "createAnswer failed: " + OPNNSStringToString(answerError.localizedDescription);
                this->HandleConnectionState(false, message);
                return;
            }

            const std::string rawAnswerSdp = OPNNSStringToString(answer.sdp);
            OPNLogVideoSdpSummary("answer-raw-video", rawAnswerSdp);
            const bool enableAnswerMunging = OPNEnvFlagEnabled("OPN_ENABLE_LIBWEBRTC_ANSWER_MUNGE", false);
            const std::string mungedAnswerSdp = enableAnswerMunging
                ? OPNMungeAnswerSdp(rawAnswerSdp, std::max(1000, this->m_settings.maxBitrateMbps * 1000))
                : rawAnswerSdp;
            if (!enableAnswerMunging) {
                OPNLogInfo(@"[LibWebRTC] OPN_ENABLE_LIBWEBRTC_ANSWER_MUNGE=0; using raw local answer SDP");
            }
            const std::string localAnswerSdp = OPNAlignH265AnswerFmtpToOffer(mungedAnswerSdp, processedOfferSdp);
            OPNLogVideoSdpSummary("answer-video", localAnswerSdp);
            if (!OPNVideoSdpHasMediaCodec(localAnswerSdp)) {
                const std::string message = "createAnswer produced no negotiated video media codec";
                this->HandleConnectionState(false, message);
                return;
            }
            RTCSessionDescription *localAnswer = [[RTCSessionDescription alloc] initWithType:RTCSdpTypeAnswer sdp:OPNStringToNSString(localAnswerSdp)];

            [answerImpl.peerConnection setLocalDescription:localAnswer completionHandler:^(NSError *localError) {
                if (!callbackLiveness->load()) return;
                if (localError) {
                    const std::string message = "setLocalDescription failed: " + OPNNSStringToString(localError.localizedDescription);
                    this->HandleConnectionState(false, message);
                    return;
                }

                const std::string localSdp = localAnswerSdp;
                SendAnswerRequest request;
                request.sdp = localSdp;
                request.nvstSdp = OPNBuildNvstSdp(this->m_settings, OPNExtractIceCredentials(localSdp));
                {
                    std::lock_guard<std::mutex> lock(this->m_statsMutex);
                    this->m_latestStats.videoPipelineMode = "libwebrtc answer sent";
                }
                if (this->m_onAnswer) this->m_onAnswer(request);
            }];
        }];
    };

    RTCSessionDescription *offer = [[RTCSessionDescription alloc] initWithType:RTCSdpTypeOffer sdp:processedOfferString];
    [impl.peerConnection setRemoteDescription:offer completionHandler:^(NSError *error) {
        if (!callbackLiveness->load()) return;
        OPNLibWebRTCSessionImpl *strongImpl = weakImpl;
        if (!strongImpl) return;
        if (!error) {
            handleRemoteDescriptionSet();
            return;
        }
        if (!canRetryOriginalOffer) {
            const std::string message = "setRemoteDescription failed: " + OPNNSStringToString(error.localizedDescription);
            this->HandleConnectionState(false, message);
            return;
        }

        OPNLogInfo(@"[LibWebRTC] filtered offer rejected (%@); retrying original GFN offer", error.localizedDescription);
        RTCSessionDescription *originalOffer = [[RTCSessionDescription alloc] initWithType:RTCSdpTypeOffer sdp:originalOfferString];
        [strongImpl.peerConnection setRemoteDescription:originalOffer completionHandler:^(NSError *retryError) {
            if (!callbackLiveness->load()) return;
            if (retryError) {
                const std::string message = "setRemoteDescription failed: " + OPNNSStringToString(retryError.localizedDescription);
                this->HandleConnectionState(false, message);
                return;
            }
            handleRemoteDescriptionSet();
        }];
    }];
#else
    (void)offerSdp;
    const std::string error = "libwebrtc backend requested in a build without WebRTC.framework";
    if (m_onState) m_onState(false, error);
#endif
}

void LibWebRTCStreamSession::Stop() {
    if (m_callbackLiveness) m_callbackLiveness->store(false);
    CancelDisconnectGraceTimer();
    StopAudioDeviceMonitoring();
    StopStatsPolling();
    StopMicrophoneLevelPolling();
    {
        std::lock_guard<std::mutex> lock(m_statsMutex);
        m_statsRequestInFlight = false;
    }
#if defined(OPN_HAVE_LIBWEBRTC)
    if (m_impl) {
        OPNLibWebRTCSessionImpl *impl = (__bridge_transfer OPNLibWebRTCSessionImpl *)m_impl;
        impl.owner = nullptr;
        impl.reliableInputChannel.delegate = nil;
        impl.partialInputChannel.delegate = nil;
        impl.peerConnection.delegate = nil;
        if (impl.remoteVideoTrack && impl.remoteVideoRenderer) {
            [impl.remoteVideoTrack removeRenderer:impl.remoteVideoRenderer];
        }
        impl.remoteAudioTrack.isEnabled = NO;
        impl.localMicrophoneTrack.isEnabled = NO;
        [impl.remoteVideoView removeFromSuperview];
        [impl.reliableInputChannel close];
        [impl.partialInputChannel close];
        [impl.peerConnection close];
        m_impl = nullptr;
    }
#else
    m_impl = nullptr;
#endif
    StopInputHeartbeat();
    m_inputReady = false;
    m_reliableOpen = false;
    m_partialOpen = false;
}

void LibWebRTCStreamSession::AddRemoteIceCandidate(const IceCandidatePayload &candidate) {
#if defined(OPN_HAVE_LIBWEBRTC)
    OPNLibWebRTCSessionImpl *impl = OPNImplFromOpaque(m_impl);
    if (!impl.peerConnection || candidate.candidate.empty()) return;
    OPNLogInfo(@"[LibWebRTC] Adding remote ICE candidate mid=%s mline=%d length=%zu",
          candidate.sdpMid.empty() ? "(none)" : candidate.sdpMid.c_str(),
          candidate.sdpMLineIndex,
          candidate.candidate.size());
    RTCIceCandidate *rtcCandidate = [[RTCIceCandidate alloc] initWithSdp:OPNStringToNSString(candidate.candidate)
                                                            sdpMLineIndex:candidate.sdpMLineIndex
                                                                   sdpMid:candidate.sdpMid.empty() ? nil : OPNStringToNSString(candidate.sdpMid)];
    [impl.peerConnection addIceCandidate:rtcCandidate completionHandler:^(NSError *error) {
        if (error) {
            OPNLogError(@"[LibWebRTC] addIceCandidate failed: %@", error.localizedDescription);
        } else {
            OPNLogInfo(@"[LibWebRTC] addIceCandidate succeeded mid=%s mline=%d",
                  candidate.sdpMid.empty() ? "(none)" : candidate.sdpMid.c_str(),
                  candidate.sdpMLineIndex);
        }
    }];
#else
    (void)candidate;
#endif
}

}
