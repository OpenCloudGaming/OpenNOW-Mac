#pragma once

#include <string>

namespace OPN {

struct OPNLibWebRTCIceCredentials {
    std::string ufrag;
    std::string pwd;
    std::string fingerprint;
};

OPNLibWebRTCIceCredentials OPNExtractIceCredentials(const std::string &sdp);
std::string OPNExtractPublicIp(const std::string &hostOrIp);
std::string OPNAlignH265AnswerFmtpToOffer(const std::string &answerSdp, const std::string &offerSdp);
std::string OPNFixServerIpInSdp(const std::string &sdp, const std::string &serverHostOrIp);
std::string OPNMungeAnswerSdp(const std::string &sdp, int maxBitrateKbps);
void OPNLogVideoSdpSummary(const char *label, const std::string &sdp);
bool OPNVideoSdpHasMediaCodec(const std::string &sdp);
std::string OPNRewriteH265OfferForReceiver(const std::string &sdp,
                                           int maxMainLevelId,
                                           int maxMain10LevelId,
                                           bool supportsHighTier);
std::string OPNNormalizeStatsCodecName(const std::string &codecId);
std::string OPNNormalizeCodec(std::string codec);
bool OPNIsSupportedCodecPreference(const std::string &codec);
std::string OPNPreferCodecInOffer(const std::string &sdp, const std::string &normalizedCodec);

}
