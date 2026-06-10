#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface OPNStreamViewPreferenceSnapshot : NSObject
@property(nonatomic, readonly) BOOL directMouseInput;
@property(nonatomic, readonly) BOOL microphoneShortcutEnabled;
@property(nonatomic, readonly) double gameVolume;
@property(nonatomic, readonly) double microphoneVolume;
@property(nonatomic, readonly) NSInteger maxBitrateMbps;
@property(nonatomic, readonly) BOOL lowLatencyMode;
@property(nonatomic, readonly) NSInteger upscalingModeIndex;
@property(nonatomic, readonly) NSInteger upscalingMode;
@property(nonatomic, readonly) NSInteger upscalingTargetHeight;
@property(nonatomic, readonly) NSInteger upscalingSharpness;
@property(nonatomic, readonly) NSInteger upscalingDenoise;
@property(nonatomic, readonly) NSInteger streamWidth;
@property(nonatomic, readonly) NSInteger streamHeight;
@property(nonatomic, readonly) BOOL recordingEnhancedVideoEnabled;
@end

@interface OPNStreamViewPreferences : NSObject
+ (OPNStreamViewPreferenceSnapshot *)loadViewPreferenceSnapshot;
+ (NSArray<NSString *> *)upscalingModeLabels;
+ (NSInteger)upscalingModeValueAtIndex:(NSInteger)index;
+ (void)saveMicrophoneShortcutEnabled:(BOOL)enabled;
+ (void)saveGameVolume:(double)value;
+ (void)saveMicrophoneVolume:(double)value;
+ (void)saveUpscalingModeIndex:(NSInteger)index;
+ (void)saveUpscalingSharpness:(NSInteger)sharpness;
+ (void)saveUpscalingDenoise:(NSInteger)denoise;
@end

NS_ASSUME_NONNULL_END
