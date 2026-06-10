#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface OPNStreamStatsSnapshot : NSObject

@property(nonatomic, readonly) BOOL available;
@property(nonatomic, readonly) double latencyMs;
@property(nonatomic, readonly) double jitterMs;
@property(nonatomic, readonly) double inboundBitrateMbps;
@property(nonatomic, readonly) double packetLossPercent;
@property(nonatomic, readonly) double decodeTimeMs;
@property(nonatomic, readonly) double renderFps;
@property(nonatomic, readonly) unsigned long long framesReceived;
@property(nonatomic, readonly) unsigned long long framesDropped;
@property(nonatomic, readonly) long long packetsLost;
@property(nonatomic, readonly) NSInteger fps;
@property(nonatomic, readonly) NSString *resolution;
@property(nonatomic, readonly) NSString *codec;
@property(nonatomic, readonly) NSString *videoEnhancementActiveTier;
@property(nonatomic, readonly) NSString *videoEnhancementConfiguredTier;
@property(nonatomic, readonly) NSString *videoEnhancementSourceResolution;
@property(nonatomic, readonly) NSString *videoEnhancementDrawableResolution;
@property(nonatomic, readonly) NSString *videoEnhancementFallbackReason;
@property(nonatomic, readonly) NSString *videoEnhancementDiagnostics;
@property(nonatomic, readonly) double videoEnhancementFrameTimeMs;
@property(nonatomic, readonly) unsigned long long videoEnhancementDroppedFrames;

@end

NS_ASSUME_NONNULL_END
