#pragma once

#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

@class MTKView;
@class RTCVideoFrame;

typedef NS_ENUM(NSInteger, OPNVideoEnhancementTier) {
    OPNVideoEnhancementTierOff = 0,
    OPNVideoEnhancementTierSpatial = 1,
    OPNVideoEnhancementTierMetalFX = 2,
};

@interface OPNVideoEnhancementSettings : NSObject
@property(nonatomic, assign) OPNVideoEnhancementTier configuredTier;
@property(nonatomic, assign) NSInteger sharpness;
@property(nonatomic, assign) NSInteger denoise;
@property(nonatomic, assign) CGSize sourceSize;
@property(nonatomic, assign) CGSize drawableSize;
@property(nonatomic, assign) double targetFrameTimeMs;
@property(nonatomic, assign) BOOL captureEnhancedPixelBuffer;
@end

@interface OPNVideoEnhancementResult : NSObject
@property(nonatomic, copy) NSString *pixelFormat;
@property(nonatomic, copy) NSString *renderMode;
@property(nonatomic, copy) NSString *frameSource;
@property(nonatomic, copy) NSString *renderPath;
@property(nonatomic, copy) NSString *fallbackReason;
@property(nonatomic, copy) NSString *configuredTier;
@property(nonatomic, copy) NSString *activeTier;
@property(nonatomic, copy) NSString *tierFallbackReason;
@property(nonatomic, copy) NSString *sourceResolution;
@property(nonatomic, copy) NSString *drawableResolution;
@property(nonatomic, assign) double frameTimeMs;
@property(nonatomic, assign) uint64_t droppedFrames;
@property(nonatomic, assign) CVPixelBufferRef enhancedPixelBuffer;
@end

@interface OPNVideoEnhancementRenderer : NSObject
- (instancetype)initWithDevice:(id<MTLDevice>)device commandQueue:(id<MTLCommandQueue>)commandQueue;
- (BOOL)renderFrame:(RTCVideoFrame *)frame
             toView:(MTKView *)view
           settings:(OPNVideoEnhancementSettings *)settings
             result:(OPNVideoEnhancementResult *)result;
- (BOOL)isMetalFXAvailable;
@end
