#pragma once

#import <Foundation/Foundation.h>

#import "OPNStreamStatsSnapshot.h"

NS_ASSUME_NONNULL_BEGIN

@interface OPNStreamSessionHandle : NSObject

@property(nonatomic, readonly, getter=isValid) BOOL valid;
@property(nonatomic, readonly, getter=isInputReady) BOOL inputReady;

+ (BOOL)isBackendAvailable;
+ (NSUInteger)maxGamepadControllers;
+ (NSString *)iceUfragFromOfferSdp:(NSString *)offerSdp;

- (instancetype)init;
- (void)stop;
- (void)setNativeWindow:(void *)nativeWindow;
- (void)setMaxBitrateMbps:(NSInteger)mbps;
- (void)addRemoteIceCandidatePayload:(NSDictionary *)payload;
- (OPNStreamStatsSnapshot *)latestStatsSnapshot;

@end

NS_ASSUME_NONNULL_END
