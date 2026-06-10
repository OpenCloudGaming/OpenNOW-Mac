#include "OPNWebRTCCodecSupport.h"
#include "OPNStreamTypes.h"
#include "OPNWebRTCSdpUtils.h"

#if defined(OPN_HAVE_LIBWEBRTC)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-umbrella"
#import <WebRTC/WebRTC.h>
#pragma clang diagnostic pop

#include <algorithm>

namespace OPN {
namespace {

bool OPNCodecCapabilityMatches(RTCRtpCodecCapability *codec, const std::string &normalizedCodec) {
    NSString *name = codec.name ?: @"";
    NSString *mimeType = codec.mimeType ?: @"";
    NSString *combined = [[NSString stringWithFormat:@"%@ %@", name, mimeType] uppercaseString];
    if (normalizedCodec == "H265") return [combined containsString:@"H265"] || [combined containsString:@"HEVC"];
    if (normalizedCodec == "H264") return [combined containsString:@"H264"];
    if (normalizedCodec == "AV1") return [combined containsString:@"AV1"];
    return false;
}

bool OPNCodecCapabilityIsTransportSupport(RTCRtpCodecCapability *codec) {
    NSString *name = [codec.name ?: @"" uppercaseString];
    NSString *mimeType = [codec.mimeType ?: @"" uppercaseString];
    return [name isEqualToString:@"RTX"] || [name isEqualToString:@"RED"] ||
           [name isEqualToString:@"ULPFEC"] || [name isEqualToString:@"FLEXFEC-03"] ||
           [mimeType containsString:@"/RTX"] || [mimeType containsString:@"/RED"] ||
           [mimeType containsString:@"/ULPFEC"] || [mimeType containsString:@"/FLEXFEC-03"];
}

}

bool OPNLibWebRTCSupportsCodec(RTCPeerConnectionFactory *factory, const std::string &normalizedCodec) {
    if (!factory || !OPNIsSupportedCodecPreference(normalizedCodec)) return false;
    RTCRtpCapabilities *capabilities = [factory rtpReceiverCapabilitiesForKind:kRTCMediaStreamTrackKindVideo];
    if (!capabilities) return false;

    NSMutableArray<NSString *> *codecNames = [NSMutableArray array];
    for (RTCRtpCodecCapability *codec in capabilities.codecs) {
        NSString *name = codec.name ?: @"";
        NSString *mimeType = codec.mimeType ?: @"";
        NSString *combined = [[NSString stringWithFormat:@"%@ %@", name, mimeType] uppercaseString];
        if (combined.length > 1) [codecNames addObject:combined];
        if (OPNCodecCapabilityMatches(codec, normalizedCodec)) return true;
    }

    OPNLogInfo(@"[LibWebRTC] Receiver codec capabilities do not include %s; available=%@", normalizedCodec.c_str(), [codecNames componentsJoinedByString:@", "]);
    return false;
}

bool OPNLibWebRTCH265ReceiverSupport(RTCPeerConnectionFactory *factory,
                                     int &maxMainLevelId,
                                     int &maxMain10LevelId,
                                     bool &supportsHighTier) {
    maxMainLevelId = 0;
    maxMain10LevelId = 0;
    supportsHighTier = false;
    if (!factory) return false;

    RTCRtpCapabilities *capabilities = [factory rtpReceiverCapabilitiesForKind:kRTCMediaStreamTrackKindVideo];
    if (!capabilities) return false;

    bool hasH265 = false;
    for (RTCRtpCodecCapability *codec in capabilities.codecs) {
        if (!OPNCodecCapabilityMatches(codec, "H265")) continue;
        hasH265 = true;
        NSDictionary<NSString *, NSString *> *parameters = codec.parameters ?: @{};
        NSString *tierFlag = parameters[@"tier-flag"];
        if (tierFlag && tierFlag.integerValue == 1) supportsHighTier = true;

        NSInteger profileId = parameters[@"profile-id"].integerValue;
        NSInteger levelId = parameters[@"level-id"].integerValue;
        if (levelId <= 0) continue;
        if (profileId == 2) {
            maxMain10LevelId = std::max(maxMain10LevelId, (int)levelId);
        } else {
            maxMainLevelId = std::max(maxMainLevelId, (int)levelId);
        }
    }
    return hasH265;
}

bool OPNApplyVideoCodecPreference(RTCPeerConnectionFactory *factory,
                                  RTCPeerConnection *peerConnection,
                                  const std::string &normalizedCodec) {
    if (!factory || !peerConnection || !OPNIsSupportedCodecPreference(normalizedCodec)) return false;

    RTCRtpCapabilities *capabilities = [factory rtpReceiverCapabilitiesForKind:kRTCMediaStreamTrackKindVideo];
    if (!capabilities) return false;

    NSMutableArray<RTCRtpCodecCapability *> *preferredCodecs = [NSMutableArray array];
    for (RTCRtpCodecCapability *codec in capabilities.codecs) {
        if (OPNCodecCapabilityMatches(codec, normalizedCodec)) {
            [preferredCodecs addObject:codec];
        }
    }
    if (preferredCodecs.count == 0) return false;
    for (RTCRtpCodecCapability *codec in capabilities.codecs) {
        if (OPNCodecCapabilityIsTransportSupport(codec)) {
            [preferredCodecs addObject:codec];
        }
    }

    bool applied = false;
    for (RTCRtpTransceiver *transceiver in peerConnection.transceivers) {
        if (transceiver.mediaType != RTCRtpMediaTypeVideo || transceiver.isStopped) continue;
        NSError *codecError = nil;
        if ([transceiver setCodecPreferences:preferredCodecs error:&codecError]) {
            applied = true;
            OPNLogInfo(@"[LibWebRTC] Applied %s codec preference to video transceiver mid=%@ (%lu codecs)",
                  normalizedCodec.c_str(),
                  transceiver.mid ?: @"(none)",
                  (unsigned long)preferredCodecs.count);
        } else {
            OPNLogInfo(@"[LibWebRTC] Failed to apply %s codec preference to video transceiver mid=%@: %@",
                  normalizedCodec.c_str(),
                  transceiver.mid ?: @"(none)",
                  codecError.localizedDescription ?: @"unknown error");
        }
    }
    return applied;
}

}
#endif
