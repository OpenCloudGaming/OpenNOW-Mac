#pragma once

#include <cstdint>
#include <string>

namespace OPN {

struct StreamStats {
    bool available = false;
    double latencyMs = -1.0;
    double jitterMs = -1.0;
    double inboundBitrateMbps = -1.0;
    double packetLossPercent = -1.0;
    double decodeTimeMs = -1.0;
    double renderFps = -1.0;
    uint64_t bytesReceived = 0;
    uint64_t packetsReceived = 0;
    int64_t packetsLost = 0;
    uint64_t framesReceived = 0;
    uint64_t framesDecoded = 0;
    uint64_t framesDropped = 0;
    uint64_t timestampMs = 0;
    std::string gpuType;
    std::string zone;
    std::string resolution;
    std::string codec;
    std::string videoDecoder;
    std::string videoSink;
    std::string videoPipelineMode;
    std::string videoPixelFormat;
    std::string videoRenderMode;
    std::string videoFrameSource;
    std::string videoRenderPath;
    std::string videoRendererFallback;
    std::string videoEnhancementConfiguredTier;
    std::string videoEnhancementActiveTier;
    std::string videoEnhancementFallbackReason;
    std::string videoEnhancementSourceResolution;
    std::string videoEnhancementDrawableResolution;
    std::string videoEnhancementDiagnostics;
    double videoEnhancementFrameTimeMs = -1.0;
    uint64_t videoEnhancementDroppedFrames = 0;
    int fps = 0;
};

}
