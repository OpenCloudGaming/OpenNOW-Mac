#include "OPNNvstSdpBuilder.h"

#include <algorithm>
#include <climits>
#include <cstdlib>
#include <vector>

namespace OPN {
namespace {

constexpr int OPNPartialReliableInputLifetimeMs = 5;

bool OPNNvstStartsWith(const std::string &value, const char *prefix) {
    const size_t prefixLen = std::char_traits<char>::length(prefix);
    return value.size() >= prefixLen && value.compare(0, prefixLen, prefix) == 0;
}

std::vector<std::string> OPNSplitResolution(const std::string &resolution) {
    const size_t x = resolution.find('x');
    if (x == std::string::npos) return {"1920", "1080"};
    std::string width = resolution.substr(0, x);
    std::string height = resolution.substr(x + 1);
    if (width.empty() || height.empty()) return {"1920", "1080"};
    return {width, height};
}

int OPNStringToPositiveInt(const std::string &value, int fallback) {
    if (value.empty()) return fallback;
    char *end = nullptr;
    long parsed = strtol(value.c_str(), &end, 10);
    if (end == value.c_str() || parsed <= 0 || parsed > INT_MAX) return fallback;
    return (int)parsed;
}

std::string OPNNormalizeNvstCodec(std::string codec) {
    return OPNNormalizeCodec(std::move(codec));
}

}

std::string OPNBuildNvstSdp(const StreamSettings &settings, const OPNLibWebRTCIceCredentials &credentials) {
    std::vector<std::string> resolution = OPNSplitResolution(settings.resolution);
    const int width = OPNStringToPositiveInt(resolution[0], 1920);
    const int height = OPNStringToPositiveInt(resolution[1], 1080);
    const int maxBitrateKbps = std::max(1000, settings.maxBitrateMbps * 1000);
    const int minBitrateKbps = std::max(5000, maxBitrateKbps * 35 / 100);
    const int initialBitrateKbps = std::max(minBitrateKbps, maxBitrateKbps * 70 / 100);
    const int bitDepth = OPNNvstStartsWith(settings.colorQuality, "10bit") ? 10 : 8;
    const std::string codec = OPNNormalizeNvstCodec(settings.codec);
    const int prefilterMode = std::max(0, std::min(settings.prefilterMode, 2));
    const int prefilterSharpness = std::max(0, std::min(settings.prefilterSharpness, 10));
    const int prefilterDenoise = std::max(0, std::min(settings.prefilterDenoise, 10));
    const int prefilterModel = std::max(0, settings.prefilterModel);
    const bool isAv1 = codec == "AV1";
    const bool isHighFps = settings.fps >= 90;
    const bool is120Fps = settings.fps == 120;
    const bool is240Fps = settings.fps >= 240;

    std::vector<std::string> lines = {
        "v=0",
        "o=SdpTest test_id_13 14 IN IPv4 127.0.0.1",
        "s=-",
        "t=0 0",
        "a=general.icePassword:" + credentials.pwd,
        "a=general.iceUserNameFragment:" + credentials.ufrag,
        "a=general.dtlsFingerprint:" + credentials.fingerprint,
        "m=video 0 RTP/AVP",
        "a=msid:fbc-video-0",
        "a=vqos.fec.rateDropWindow:10",
        "a=vqos.fec.minRequiredFecPackets:2",
        "a=vqos.fec.repairMinPercent:5",
        "a=vqos.fec.repairPercent:5",
        "a=vqos.fec.repairMaxPercent:35",
        "a=vqos.dynamicStreamingMode:0",
        "a=vqos.drc.enable:0",
        "a=vqos.dfc.enable:0",
        "a=vqos.dfc.adjustResAndFps:0",
        "a=video.dx9EnableNv12:1",
        "a=video.dx9EnableHdr:1",
        "a=vqos.qpg.enable:1",
        "a=vqos.resControl.qp.qpg.featureSetting:7",
        "a=bwe.useOwdCongestionControl:1",
        "a=video.enableRtpNack:1",
        "a=vqos.bw.txRxLag.minFeedbackTxDeltaMs:200",
        "a=vqos.drc.bitrateIirFilterFactor:18",
        "a=video.packetSize:1140",
        "a=packetPacing.minNumPacketsPerGroup:15",
    };

    if (isHighFps) {
        lines.insert(lines.end(), {
            "a=bwe.iirFilterFactor:8",
            "a=video.encoderFeatureSetting:47",
            "a=video.encoderPreset:6",
            "a=vqos.resControl.cpmRtc.badNwSkipFramesCount:600",
            "a=vqos.resControl.cpmRtc.decodeTimeThresholdMs:9",
            std::string("a=video.fbcDynamicFpsGrabTimeoutMs:") + (is120Fps ? "6" : "18"),
            std::string("a=vqos.resControl.cpmRtc.serverResolutionUpdateCoolDownCount:") + (is120Fps ? "6000" : "12000"),
        });
    }

    if (is240Fps) {
        lines.insert(lines.end(), {
            "a=video.enableNextCaptureMode:1",
            "a=vqos.maxStreamFpsEstimate:240",
            "a=video.videoSplitEncodeStripsPerFrame:3",
            "a=video.updateSplitEncodeStateDynamically:1",
        });
    }

    lines.insert(lines.end(), {
        "a=vqos.adjustStreamingFpsDuringOutOfFocus:1",
        "a=vqos.resControl.cpmRtc.ignoreOutOfFocusWindowState:1",
        "a=vqos.resControl.perfHistory.rtcIgnoreOutOfFocusWindowState:1",
        "a=vqos.resControl.cpmRtc.featureMask:0",
        "a=vqos.resControl.cpmRtc.enable:0",
        "a=vqos.resControl.cpmRtc.minResolutionPercent:100",
        "a=vqos.resControl.cpmRtc.resolutionChangeHoldonMs:999999",
        std::string("a=packetPacing.numGroups:") + (is120Fps ? "3" : "5"),
        "a=packetPacing.maxDelayUs:1000",
        "a=packetPacing.minNumPacketsFrame:10",
        "a=video.rtpNackQueueLength:1024",
        "a=video.rtpNackQueueMaxPackets:512",
        "a=video.rtpNackMaxPacketCount:25",
        "a=vqos.drc.qpMaxResThresholdAdj:4",
        "a=vqos.grc.qpMaxResThresholdAdj:4",
        "a=vqos.drc.iirFilterFactor:100",
    });

    if (isAv1) {
        lines.insert(lines.end(), {
            "a=vqos.drc.minQpHeadroom:20",
            "a=vqos.drc.lowerQpThreshold:100",
            "a=vqos.drc.upperQpThreshold:200",
            "a=vqos.drc.minAdaptiveQpThreshold:180",
            "a=vqos.drc.qpCodecThresholdAdj:0",
            "a=vqos.drc.qpMaxResThresholdAdj:20",
            "a=vqos.dfc.minQpHeadroom:20",
            "a=vqos.dfc.qpLowerLimit:100",
            "a=vqos.dfc.qpMaxUpperLimit:200",
            "a=vqos.dfc.qpMinUpperLimit:180",
            "a=vqos.dfc.qpMaxResThresholdAdj:20",
            "a=vqos.dfc.qpCodecThresholdAdj:0",
            "a=vqos.grc.minQpHeadroom:20",
            "a=vqos.grc.lowerQpThreshold:100",
            "a=vqos.grc.upperQpThreshold:200",
            "a=vqos.grc.minAdaptiveQpThreshold:180",
            "a=vqos.grc.qpMaxResThresholdAdj:20",
            "a=vqos.grc.qpCodecThresholdAdj:0",
            "a=video.minQp:25",
            "a=video.enableAv1RcPrecisionFactor:1",
        });
    }

    lines.insert(lines.end(), {
        "a=video.clientViewportWd:" + std::to_string(width),
        "a=video.clientViewportHt:" + std::to_string(height),
        "a=video.maxFPS:" + std::to_string(settings.fps),
        "a=video.initialBitrateKbps:" + std::to_string(initialBitrateKbps),
        "a=video.initialPeakBitrateKbps:" + std::to_string(maxBitrateKbps),
        "a=vqos.bw.maximumBitrateKbps:" + std::to_string(maxBitrateKbps),
        "a=vqos.bw.minimumBitrateKbps:" + std::to_string(minBitrateKbps),
        "a=vqos.bw.peakBitrateKbps:" + std::to_string(maxBitrateKbps),
        "a=vqos.bw.serverPeakBitrateKbps:" + std::to_string(maxBitrateKbps),
        "a=vqos.bw.enableBandwidthEstimation:1",
        "a=vqos.bw.disableBitrateLimit:0",
        "a=vqos.grc.maximumBitrateKbps:" + std::to_string(maxBitrateKbps),
        "a=vqos.grc.enable:0",
        "a=video.maxNumReferenceFrames:4",
        "a=video.mapRtpTimestampsToFrames:1",
        "a=video.encoderCscMode:3",
        "a=video.dynamicRangeMode:0",
        "a=video.bitDepth:" + std::to_string(bitDepth),
        std::string("a=video.scalingFeature1:") + (isAv1 ? "1" : "0"),
        "a=video.prefilterParams.prefilterMode:" + std::to_string(prefilterMode),
        "a=video.prefilterParams.prefilterModel:" + std::to_string(prefilterModel),
        "a=video.prefilterParams.sharpnessLevel:" + std::to_string(prefilterSharpness),
        "a=video.prefilterParams.denoiseLevel:" + std::to_string(prefilterDenoise),
        "m=audio 0 RTP/AVP",
        "a=msid:audio",
        "m=mic 0 RTP/AVP",
        "a=msid:mic",
        "a=rtpmap:0 PCMU/8000",
        "m=application 0 RTP/AVP",
        "a=msid:input_1",
        "a=ri.partialReliableThresholdMs:" + std::to_string(OPNPartialReliableInputLifetimeMs),
        "a=ri.hidDeviceMask:4294967295",
        "a=ri.enablePartiallyReliableTransferGamepad:15",
        "a=ri.enablePartiallyReliableTransferHid:4294967295",
        "",
    });

    std::string result;
    for (const std::string &line : lines) {
        result += line;
        result += '\n';
    }
    return result;
}

}
