#include "OPNStreamStatsSnapshot+Private.h"

static NSString *OPNStreamStatsSnapshotString(const std::string &value) {
    if (value.empty()) return @"";
    NSString *string = [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding];
    return string ?: @"";
}

@implementation OPNStreamStatsSnapshot {
    OPN::StreamStats _stats;
    NSString *_resolution;
    NSString *_codec;
    NSString *_videoEnhancementActiveTier;
    NSString *_videoEnhancementConfiguredTier;
    NSString *_videoEnhancementSourceResolution;
    NSString *_videoEnhancementDrawableResolution;
    NSString *_videoEnhancementFallbackReason;
    NSString *_videoEnhancementDiagnostics;
}

- (instancetype)initWithStreamStats:(const OPN::StreamStats &)stats {
    self = [super init];
    if (self) {
        _stats = stats;
        _resolution = OPNStreamStatsSnapshotString(stats.resolution);
        _codec = OPNStreamStatsSnapshotString(stats.codec);
        _videoEnhancementActiveTier = OPNStreamStatsSnapshotString(stats.videoEnhancementActiveTier);
        _videoEnhancementConfiguredTier = OPNStreamStatsSnapshotString(stats.videoEnhancementConfiguredTier);
        _videoEnhancementSourceResolution = OPNStreamStatsSnapshotString(stats.videoEnhancementSourceResolution);
        _videoEnhancementDrawableResolution = OPNStreamStatsSnapshotString(stats.videoEnhancementDrawableResolution);
        _videoEnhancementFallbackReason = OPNStreamStatsSnapshotString(stats.videoEnhancementFallbackReason);
        _videoEnhancementDiagnostics = OPNStreamStatsSnapshotString(stats.videoEnhancementDiagnostics);
    }
    return self;
}

- (const OPN::StreamStats &)rawStats {
    return _stats;
}

- (BOOL)available { return _stats.available ? YES : NO; }
- (double)latencyMs { return _stats.latencyMs; }
- (double)jitterMs { return _stats.jitterMs; }
- (double)inboundBitrateMbps { return _stats.inboundBitrateMbps; }
- (double)packetLossPercent { return _stats.packetLossPercent; }
- (double)decodeTimeMs { return _stats.decodeTimeMs; }
- (double)renderFps { return _stats.renderFps; }
- (unsigned long long)framesReceived { return (unsigned long long)_stats.framesReceived; }
- (unsigned long long)framesDropped { return (unsigned long long)_stats.framesDropped; }
- (long long)packetsLost { return (long long)_stats.packetsLost; }
- (NSInteger)fps { return _stats.fps; }
- (NSString *)resolution { return _resolution; }
- (NSString *)codec { return _codec; }
- (NSString *)videoEnhancementActiveTier { return _videoEnhancementActiveTier; }
- (NSString *)videoEnhancementConfiguredTier { return _videoEnhancementConfiguredTier; }
- (NSString *)videoEnhancementSourceResolution { return _videoEnhancementSourceResolution; }
- (NSString *)videoEnhancementDrawableResolution { return _videoEnhancementDrawableResolution; }
- (NSString *)videoEnhancementFallbackReason { return _videoEnhancementFallbackReason; }
- (NSString *)videoEnhancementDiagnostics { return _videoEnhancementDiagnostics; }
- (double)videoEnhancementFrameTimeMs { return _stats.videoEnhancementFrameTimeMs; }
- (unsigned long long)videoEnhancementDroppedFrames { return (unsigned long long)_stats.videoEnhancementDroppedFrames; }

@end
