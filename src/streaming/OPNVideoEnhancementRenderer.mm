#include "OPNVideoEnhancementRenderer.h"

#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#if __has_include(<MetalFX/MetalFX.h>)
#import <MetalFX/MetalFX.h>
#define OPN_HAVE_METALFX 1
#else
#define OPN_HAVE_METALFX 0
#endif

#include <algorithm>
#include <cmath>
#include <cstring>

#if defined(OPN_HAVE_LIBWEBRTC)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-umbrella"
#import <WebRTC/WebRTC.h>
#import <WebRTC/RTCCVPixelBuffer.h>
#import <WebRTC/RTCVideoFrame.h>
#pragma clang diagnostic pop
#endif

@implementation OPNVideoEnhancementResult
@end

static NSString *OPNEnhancementResolutionString(CGSize size) {
    int width = (int)std::llround(std::max<CGFloat>(0.0, size.width));
    int height = (int)std::llround(std::max<CGFloat>(0.0, size.height));
    return width > 0 && height > 0 ? [NSString stringWithFormat:@"%dx%d", width, height] : @"unknown";
}

static NSString *OPNEnhancementTierName(OPNVideoEnhancementTier tier) {
    switch (tier) {
        case OPNVideoEnhancementTierSpatial: return @"Spatial";
        case OPNVideoEnhancementTierMetalFX: return @"MetalFX";
        case OPNVideoEnhancementTierTemporal: return @"Temporal";
        case OPNVideoEnhancementTierOff: return @"Off";
    }
}

static NSString *OPNVideoPixelFormatName(OSType format) {
    if (format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) return @"420v/NV12";
    if (format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) return @"420f/NV12";
    if (format == kCVPixelFormatType_32BGRA) return @"BGRA";
    if (format == kCVPixelFormatType_32ARGB) return @"ARGB";
    return [NSString stringWithFormat:@"0x%08x", (unsigned int)format];
}

static void OPNTemporalJitterForFrame(NSUInteger frameIndex, float *x, float *y) {
    static const float offsets[8][2] = {
        {-0.375f, -0.125f},
        { 0.125f,  0.375f},
        {-0.125f, -0.375f},
        { 0.375f,  0.125f},
        {-0.3125f,  0.3125f},
        { 0.1875f, -0.1875f},
        {-0.1875f,  0.1875f},
        { 0.3125f, -0.3125f},
    };
    size_t index = (size_t)(frameIndex % 8);
    *x = offsets[index][0];
    *y = offsets[index][1];
}

@interface OPNVideoTextureSource : NSObject
- (instancetype)initWithDevice:(id<MTLDevice>)device;
- (id)newTextureFrameForFrame:(RTCVideoFrame *)frame pixelFormat:(NSString **)pixelFormat frameSource:(NSString **)frameSource fallback:(NSString **)fallback;
@end

typedef NS_ENUM(NSInteger, OPNVideoTextureFrameKind) {
    OPNVideoTextureFrameKindRGB = 0,
    OPNVideoTextureFrameKindNV12 = 1,
    OPNVideoTextureFrameKindI420 = 2,
};

typedef NS_ENUM(NSInteger, OPNVideoRenderTier) {
    OPNVideoRenderTierSpatial = 1,
    OPNVideoRenderTierMetalFX = 2,
    OPNVideoRenderTierTemporal = 3,
};

@interface OPNVideoTextureFrame : NSObject
@property(nonatomic, assign) OPNVideoTextureFrameKind kind;
@property(nonatomic, strong) id<MTLTexture> rgbTexture;
@property(nonatomic, strong) id<MTLTexture> lumaTexture;
@property(nonatomic, strong) id<MTLTexture> chromaTexture;
@property(nonatomic, strong) id<MTLTexture> chromaUTexture;
@property(nonatomic, strong) id<MTLTexture> chromaVTexture;
@property(nonatomic, assign) CGRect cropRect;
@property(nonatomic, assign) NSUInteger contentWidth;
@property(nonatomic, assign) NSUInteger contentHeight;
@end

@implementation OPNVideoTextureFrame
@end

static BOOL OPNVideoTextureFrameUsesFullCrop(OPNVideoTextureFrame *textureFrame) {
    if (!textureFrame) return YES;
    CGRect crop = textureFrame.cropRect;
    return crop.origin.x <= 0.0001 && crop.origin.y <= 0.0001 &&
        crop.size.width >= 0.9999 && crop.size.height >= 0.9999;
}

@implementation OPNVideoTextureSource {
    CVMetalTextureCacheRef _textureCache;
    id<MTLDevice> _device;
    id<MTLTexture> _i420LumaTexture;
    id<MTLTexture> _i420ChromaUTexture;
    id<MTLTexture> _i420ChromaVTexture;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    self = [super init];
    if (self && device) {
        _device = device;
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &_textureCache);
    }
    return self;
}

- (void)dealloc {
    if (_textureCache) {
        CFRelease(_textureCache);
        _textureCache = nil;
    }
}

- (id)newTextureFrameForFrame:(RTCVideoFrame *)frame pixelFormat:(NSString **)pixelFormat frameSource:(NSString **)frameSource fallback:(NSString **)fallback {
#if defined(OPN_HAVE_LIBWEBRTC)
    if (!frame || !_textureCache) {
        if (fallback) *fallback = @"texture source unavailable";
        return nil;
    }
    id<RTCVideoFrameBuffer> buffer = frame.buffer;
    if (![buffer isKindOfClass:RTCCVPixelBuffer.class]) {
        RTCVideoFrame *i420Frame = [frame newI420VideoFrame];
        id<RTCI420Buffer> i420 = (id<RTCI420Buffer>)i420Frame.buffer;
        if (!i420 || i420.width <= 0 || i420.height <= 0) {
            if (frameSource) *frameSource = NSStringFromClass([buffer class]) ?: @"unknown";
            if (pixelFormat) *pixelFormat = @"I420";
            if (fallback) *fallback = @"I420 frame unavailable";
            return nil;
        }

        OPNVideoTextureFrame *textureFrame = [[OPNVideoTextureFrame alloc] init];
        textureFrame.kind = OPNVideoTextureFrameKindI420;
        textureFrame.cropRect = CGRectMake(0.0, 0.0, 1.0, 1.0);
        textureFrame.contentWidth = (NSUInteger)i420.width;
        textureFrame.contentHeight = (NSUInteger)i420.height;
        textureFrame.lumaTexture = [self reusablePlaneTexture:&_i420LumaTexture width:(NSUInteger)i420.width height:(NSUInteger)i420.height bytes:i420.dataY bytesPerRow:(NSUInteger)i420.strideY label:@"OpenNOW I420 Y"];
        textureFrame.chromaUTexture = [self reusablePlaneTexture:&_i420ChromaUTexture width:(NSUInteger)i420.chromaWidth height:(NSUInteger)i420.chromaHeight bytes:i420.dataU bytesPerRow:(NSUInteger)i420.strideU label:@"OpenNOW I420 U"];
        textureFrame.chromaVTexture = [self reusablePlaneTexture:&_i420ChromaVTexture width:(NSUInteger)i420.chromaWidth height:(NSUInteger)i420.chromaHeight bytes:i420.dataV bytesPerRow:(NSUInteger)i420.strideV label:@"OpenNOW I420 V"];
        if (!textureFrame.lumaTexture || !textureFrame.chromaUTexture || !textureFrame.chromaVTexture) {
            if (frameSource) *frameSource = NSStringFromClass([buffer class]) ?: @"unknown";
            if (pixelFormat) *pixelFormat = @"I420";
            if (fallback) *fallback = @"I420 GPU plane upload failed";
            return nil;
        }
        if (frameSource) *frameSource = NSStringFromClass([buffer class]) ?: @"I420";
        if (pixelFormat) *pixelFormat = @"I420";
        return textureFrame;
    }

    RTCCVPixelBuffer *cvBuffer = (RTCCVPixelBuffer *)buffer;
    CVPixelBufferRef pixelBuffer = cvBuffer.pixelBuffer;
    if (!pixelBuffer) {
        if (fallback) *fallback = @"empty CVPixelBuffer";
        return nil;
    }

    OSType format = CVPixelBufferGetPixelFormatType(pixelBuffer);
    if (pixelFormat) *pixelFormat = OPNVideoPixelFormatName(format);
    if (frameSource) *frameSource = @"CVPixelBuffer";
    const BOOL isBGRA = format == kCVPixelFormatType_32BGRA;
    const BOOL isNV12 = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    if (!isBGRA && !isNV12) {
        if (fallback) *fallback = @"unsupported GPU ingestion format; using Core Image compatibility path";
        return nil;
    }

    const size_t width = isNV12 ? CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) : CVPixelBufferGetWidth(pixelBuffer);
    const size_t height = isNV12 ? CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) : CVPixelBufferGetHeight(pixelBuffer);
    if (width == 0 || height == 0) {
        if (fallback) *fallback = @"empty CVPixelBuffer dimensions";
        return nil;
    }

    OPNVideoTextureFrame *textureFrame = [[OPNVideoTextureFrame alloc] init];
    textureFrame.kind = isNV12 ? OPNVideoTextureFrameKindNV12 : OPNVideoTextureFrameKindRGB;
    size_t contentWidth = width;
    size_t contentHeight = height;
    CGRect cropRect = CGRectMake(0.0, 0.0, 1.0, 1.0);
    if (cvBuffer.requiresCropping && cvBuffer.cropWidth > 0 && cvBuffer.cropHeight > 0) {
        CGFloat cropX = std::max<CGFloat>(0.0, (CGFloat)cvBuffer.cropX);
        CGFloat cropY = std::max<CGFloat>(0.0, (CGFloat)cvBuffer.cropY);
        CGFloat cropWidth = std::min<CGFloat>((CGFloat)cvBuffer.cropWidth, (CGFloat)width - cropX);
        CGFloat cropHeight = std::min<CGFloat>((CGFloat)cvBuffer.cropHeight, (CGFloat)height - cropY);
        if (cropWidth > 0.0 && cropHeight > 0.0) {
            cropRect = CGRectMake(cropX / (CGFloat)width, cropY / (CGFloat)height, cropWidth / (CGFloat)width, cropHeight / (CGFloat)height);
            contentWidth = (size_t)std::llround(cropWidth);
            contentHeight = (size_t)std::llround(cropHeight);
        }
    }
    textureFrame.cropRect = cropRect;
    textureFrame.contentWidth = std::max<size_t>(1, contentWidth);
    textureFrame.contentHeight = std::max<size_t>(1, contentHeight);

    CVMetalTextureRef metalTexture = nil;
    CVReturn status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                                _textureCache,
                                                                pixelBuffer,
                                                                nil,
                                                                isNV12 ? MTLPixelFormatR8Unorm : MTLPixelFormatBGRA8Unorm,
                                                                width,
                                                                height,
                                                                0,
                                                                &metalTexture);
    if (status != kCVReturnSuccess || !metalTexture) {
        if (fallback) *fallback = @"CVMetalTextureCache could not create BGRA texture";
        return nil;
    }

    id<MTLTexture> texture = CVMetalTextureGetTexture(metalTexture);
    id<MTLTexture> retainedTexture = texture;
    CFRelease(metalTexture);
    if (!isNV12) {
        textureFrame.rgbTexture = retainedTexture;
        return textureFrame;
    }

    const size_t chromaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1);
    const size_t chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1);
    CVMetalTextureRef chromaMetalTexture = nil;
    CVReturn chromaStatus = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                                      _textureCache,
                                                                      pixelBuffer,
                                                                      nil,
                                                                      MTLPixelFormatRG8Unorm,
                                                                      chromaWidth,
                                                                      chromaHeight,
                                                                      1,
                                                                      &chromaMetalTexture);
    if (chromaStatus != kCVReturnSuccess || !chromaMetalTexture) {
        if (fallback) *fallback = @"CVMetalTextureCache could not create NV12 chroma texture";
        return nil;
    }
    id<MTLTexture> chromaTexture = CVMetalTextureGetTexture(chromaMetalTexture);
    id<MTLTexture> retainedChromaTexture = chromaTexture;
    CFRelease(chromaMetalTexture);
    textureFrame.lumaTexture = retainedTexture;
    textureFrame.chromaTexture = retainedChromaTexture;
    return textureFrame;
#else
    (void)frame;
    if (pixelFormat) *pixelFormat = @"unknown";
    if (frameSource) *frameSource = @"unavailable";
    if (fallback) *fallback = @"WebRTC unavailable";
    return nil;
#endif
}

- (id<MTLTexture>)newPlaneTextureWithWidth:(NSUInteger)width height:(NSUInteger)height bytes:(const uint8_t *)bytes bytesPerRow:(NSUInteger)bytesPerRow label:(NSString *)label {
    if (!_device || !bytes || width == 0 || height == 0 || bytesPerRow == 0) return nil;
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                                                           width:width
                                                                                          height:height
                                                                                       mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead;
    descriptor.storageMode = MTLStorageModeShared;
    id<MTLTexture> texture = [_device newTextureWithDescriptor:descriptor];
    texture.label = label;
    if (!texture) return nil;
    MTLRegion region = MTLRegionMake2D(0, 0, width, height);
    [texture replaceRegion:region mipmapLevel:0 withBytes:bytes bytesPerRow:bytesPerRow];
    return texture;
}

- (id<MTLTexture>)reusablePlaneTexture:(id<MTLTexture> __strong *)texture width:(NSUInteger)width height:(NSUInteger)height bytes:(const uint8_t *)bytes bytesPerRow:(NSUInteger)bytesPerRow label:(NSString *)label {
    if (!texture || !_device || !bytes || width == 0 || height == 0 || bytesPerRow == 0) return nil;
    id<MTLTexture> existing = *texture;
    if (!existing || existing.width != width || existing.height != height || existing.pixelFormat != MTLPixelFormatR8Unorm) {
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                                                               width:width
                                                                                              height:height
                                                                                           mipmapped:NO];
        descriptor.usage = MTLTextureUsageShaderRead;
        descriptor.storageMode = MTLStorageModeShared;
        existing = [_device newTextureWithDescriptor:descriptor];
        existing.label = label;
        *texture = existing;
    }
    if (!existing) return nil;
    MTLRegion region = MTLRegionMake2D(0, 0, width, height);
    [existing replaceRegion:region mipmapLevel:0 withBytes:bytes bytesPerRow:bytesPerRow];
    return existing;
}

@end

@interface OPNMetalFXUpscaler : NSObject
- (instancetype)initWithDevice:(id<MTLDevice>)device;
- (BOOL)isAvailable;
- (BOOL)encodeTexture:(id<MTLTexture>)sourceTexture
            toTexture:(id<MTLTexture>)destinationTexture
        commandBuffer:(id<MTLCommandBuffer>)commandBuffer
              fallback:(NSString **)fallback;
@end

@implementation OPNMetalFXUpscaler {
    id<MTLDevice> _device;
    id _spatialScaler;
    NSUInteger _inputWidth;
    NSUInteger _inputHeight;
    NSUInteger _outputWidth;
    NSUInteger _outputHeight;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    self = [super init];
    if (self) {
        _device = device;
    }
    return self;
}

- (BOOL)isAvailable {
#if OPN_HAVE_METALFX
    if (!_device || !NSClassFromString(@"MTLFXSpatialScalerDescriptor")) return NO;
    if (@available(macOS 13.0, *)) {
        return [MTLFXSpatialScalerDescriptor supportsDevice:_device];
    }
    return NO;
#else
    return NO;
#endif
}

- (BOOL)encodeTexture:(id<MTLTexture>)sourceTexture
            toTexture:(id<MTLTexture>)destinationTexture
        commandBuffer:(id<MTLCommandBuffer>)commandBuffer
              fallback:(NSString **)fallback {
#if OPN_HAVE_METALFX
    if (![self isAvailable] || !sourceTexture || !destinationTexture || !commandBuffer) {
        if (fallback) *fallback = @"MetalFX unavailable";
        return NO;
    }
    if (@available(macOS 13.0, *)) {
        BOOL dimensionsChanged = !_spatialScaler ||
            _inputWidth != sourceTexture.width ||
            _inputHeight != sourceTexture.height ||
            _outputWidth != destinationTexture.width ||
            _outputHeight != destinationTexture.height;
        if (dimensionsChanged) {
            MTLFXSpatialScalerDescriptor *descriptor = [[MTLFXSpatialScalerDescriptor alloc] init];
            descriptor.colorTextureFormat = sourceTexture.pixelFormat;
            descriptor.outputTextureFormat = destinationTexture.pixelFormat;
            descriptor.inputWidth = sourceTexture.width;
            descriptor.inputHeight = sourceTexture.height;
            descriptor.outputWidth = destinationTexture.width;
            descriptor.outputHeight = destinationTexture.height;
            descriptor.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
            _spatialScaler = [descriptor newSpatialScalerWithDevice:_device];
            _inputWidth = sourceTexture.width;
            _inputHeight = sourceTexture.height;
            _outputWidth = destinationTexture.width;
            _outputHeight = destinationTexture.height;
        }
        id<MTLFXSpatialScaler> scaler = (id<MTLFXSpatialScaler>)_spatialScaler;
        if (!scaler) {
            if (fallback) *fallback = @"MetalFX scaler creation failed";
            return NO;
        }
        scaler.colorTexture = sourceTexture;
        scaler.outputTexture = destinationTexture;
        scaler.inputContentWidth = sourceTexture.width;
        scaler.inputContentHeight = sourceTexture.height;
        [scaler encodeToCommandBuffer:commandBuffer];
        return YES;
    }
    if (fallback) *fallback = @"MetalFX requires macOS 13";
    return NO;
#else
    (void)sourceTexture;
    (void)destinationTexture;
    (void)commandBuffer;
    if (fallback) *fallback = @"MetalFX headers unavailable";
    return NO;
#endif
}
@end

@interface OPNVideoEnhancementRenderer ()
@property(nonatomic, strong) id<MTLDevice> device;
@property(nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property(nonatomic, strong) CIContext *ciContext;
@property(nonatomic, assign) CGColorSpaceRef outputColorSpace;
@property(nonatomic, strong) OPNVideoTextureSource *textureSource;
@property(nonatomic, strong) OPNMetalFXUpscaler *metalFXUpscaler;
@property(nonatomic, strong) id<MTLTexture> metalFXIntermediateTexture;
@property(nonatomic, strong) id<MTLTexture> metalFXOutputTexture;
@property(nonatomic, strong) id<MTLTexture> temporalCurrentTexture;
@property(nonatomic, strong) id<MTLTexture> temporalHistoryTexture;
@property(nonatomic, strong) id<MTLTexture> temporalOutputTexture;
@property(nonatomic, strong) id<MTLTexture> temporalMotionTexture;
@property(nonatomic, strong) id<MTLRenderPipelineState> spatialRGBPipeline;
@property(nonatomic, strong) id<MTLRenderPipelineState> spatialNV12Pipeline;
@property(nonatomic, strong) id<MTLRenderPipelineState> spatialI420Pipeline;
@property(nonatomic, strong) id<MTLRenderPipelineState> fastSpatialRGBPipeline;
@property(nonatomic, strong) id<MTLRenderPipelineState> fastSpatialNV12Pipeline;
@property(nonatomic, strong) id<MTLRenderPipelineState> fastSpatialI420Pipeline;
@property(nonatomic, strong) id<MTLRenderPipelineState> temporalMotionPipeline;
@property(nonatomic, strong) id<MTLRenderPipelineState> temporalCompositePipeline;
@property(nonatomic, strong) id<MTLRenderPipelineState> temporalPresentPipeline;
@property(nonatomic, assign) uint64_t droppedFrames;
@property(nonatomic, assign) BOOL temporalHistoryValid;
@property(nonatomic, assign) NSUInteger temporalFrameIndex;
@property(nonatomic, assign) float temporalPreviousJitterX;
@property(nonatomic, assign) float temporalPreviousJitterY;
@property(nonatomic, assign) NSUInteger temporalHistoryWidth;
@property(nonatomic, assign) NSUInteger temporalHistoryHeight;
@property(nonatomic, assign) NSUInteger temporalSourceWidth;
@property(nonatomic, assign) NSUInteger temporalSourceHeight;
@property(nonatomic, assign) NSUInteger temporalHistoryResetCount;
@property(nonatomic, assign) NSUInteger enhancedCaptureWidth;
@property(nonatomic, assign) NSUInteger enhancedCaptureHeight;
- (id<MTLTexture>)reusableMetalFXIntermediateTextureWithWidth:(NSUInteger)width height:(NSUInteger)height;
- (id<MTLTexture>)reusableMetalFXOutputTextureWithWidth:(NSUInteger)width height:(NSUInteger)height pixelFormat:(MTLPixelFormat)pixelFormat;
- (id<MTLTexture>)reusableTemporalTexture:(id<MTLTexture>)texture width:(NSUInteger)width height:(NSUInteger)height pixelFormat:(MTLPixelFormat)pixelFormat label:(NSString *)label;
- (CVPixelBufferRef)consumeCompletedEnhancedPixelBuffer CF_RETURNS_RETAINED;
- (void)clearCompletedEnhancedPixelBuffers;
- (void)enqueueEnhancedPixelBufferCaptureFromTexture:(id<MTLTexture>)texture commandBuffer:(id<MTLCommandBuffer>)commandBuffer;
- (CVPixelBufferRef)newPooledEnhancedPixelBufferWithWidth:(NSUInteger)width height:(NSUInteger)height CF_RETURNS_RETAINED;
- (BOOL)renderTemporalTextureFrame:(OPNVideoTextureFrame *)textureFrame drawable:(id<CAMetalDrawable>)drawable settings:(OPNVideoEnhancementSettings *)settings result:(OPNVideoEnhancementResult *)result start:(CFTimeInterval)start;
- (BOOL)encodeTemporalMotionTexture:(id<MTLTexture>)currentTexture historyTexture:(id<MTLTexture>)historyTexture motionTexture:(id<MTLTexture>)motionTexture jitterDelta:(const float *)jitterDelta commandBuffer:(id<MTLCommandBuffer>)commandBuffer result:(OPNVideoEnhancementResult *)result;
- (BOOL)encodeTemporalCurrentTexture:(id<MTLTexture>)currentTexture historyTexture:(id<MTLTexture>)historyTexture motionTexture:(id<MTLTexture>)motionTexture destinationTexture:(id<MTLTexture>)destinationTexture commandBuffer:(id<MTLCommandBuffer>)commandBuffer settings:(OPNVideoEnhancementSettings *)settings result:(OPNVideoEnhancementResult *)result;
- (BOOL)encodePresentTexture:(id<MTLTexture>)sourceTexture destinationTexture:(id<MTLTexture>)destinationTexture commandBuffer:(id<MTLCommandBuffer>)commandBuffer result:(OPNVideoEnhancementResult *)result;
@end

@implementation OPNVideoEnhancementRenderer {
    CVPixelBufferPoolRef _enhancedCapturePool;
    CVMetalTextureCacheRef _enhancedCaptureTextureCache;
    NSMutableArray *_completedEnhancedPixelBuffers;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device commandQueue:(id<MTLCommandQueue>)commandQueue {
    self = [super init];
    if (self) {
        _device = device;
        _commandQueue = commandQueue;
        _ciContext = device ? [CIContext contextWithMTLDevice:device options:@{kCIContextWorkingColorSpace: [NSNull null]}] : nil;
        _outputColorSpace = CGColorSpaceCreateDeviceRGB();
        if (device) CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &_enhancedCaptureTextureCache);
        _textureSource = [[OPNVideoTextureSource alloc] initWithDevice:device];
        _metalFXUpscaler = [[OPNMetalFXUpscaler alloc] initWithDevice:device];
        _spatialRGBPipeline = [self newSpatialPipelineWithDevice:device fragmentFunction:@"opn_video_spatial_rgb"];
        _spatialNV12Pipeline = [self newSpatialPipelineWithDevice:device fragmentFunction:@"opn_video_spatial_nv12"];
        _spatialI420Pipeline = [self newSpatialPipelineWithDevice:device fragmentFunction:@"opn_video_spatial_i420"];
        _fastSpatialRGBPipeline = [self newSpatialPipelineWithDevice:device fragmentFunction:@"opn_video_fast_rgb"];
        _fastSpatialNV12Pipeline = [self newSpatialPipelineWithDevice:device fragmentFunction:@"opn_video_fast_nv12"];
        _fastSpatialI420Pipeline = [self newSpatialPipelineWithDevice:device fragmentFunction:@"opn_video_fast_i420"];
        _temporalMotionPipeline = [self newSpatialPipelineWithDevice:device fragmentFunction:@"opn_video_temporal_motion" pixelFormat:MTLPixelFormatRGBA16Float];
        _temporalCompositePipeline = [self newSpatialPipelineWithDevice:device fragmentFunction:@"opn_video_temporal_composite"];
        _temporalPresentPipeline = [self newSpatialPipelineWithDevice:device fragmentFunction:@"opn_video_present_rgb"];
        _droppedFrames = 0;
        _temporalHistoryValid = NO;
        _temporalFrameIndex = 0;
        _temporalPreviousJitterX = 0.0f;
        _temporalPreviousJitterY = 0.0f;
        _temporalHistoryResetCount = 0;
        _completedEnhancedPixelBuffers = [NSMutableArray array];
    }
    return self;
}

- (void)dealloc {
    if (_outputColorSpace) {
        CGColorSpaceRelease(_outputColorSpace);
        _outputColorSpace = nil;
    }
    if (_enhancedCapturePool) {
        CVPixelBufferPoolRelease(_enhancedCapturePool);
        _enhancedCapturePool = nil;
    }
    if (_enhancedCaptureTextureCache) {
        CVMetalTextureCacheFlush(_enhancedCaptureTextureCache, 0);
        CFRelease(_enhancedCaptureTextureCache);
        _enhancedCaptureTextureCache = nil;
    }
    [self clearCompletedEnhancedPixelBuffers];
}

- (BOOL)isMetalFXAvailable {
    return [self.metalFXUpscaler isAvailable];
}

- (BOOL)isTemporalAvailable {
    return self.commandQueue && self.spatialRGBPipeline && self.spatialNV12Pipeline && self.spatialI420Pipeline && self.temporalMotionPipeline && self.temporalCompositePipeline && self.temporalPresentPipeline;
}

- (id<MTLRenderPipelineState>)newSpatialPipelineWithDevice:(id<MTLDevice>)device fragmentFunction:(NSString *)fragmentFunctionName {
    return [self newSpatialPipelineWithDevice:device fragmentFunction:fragmentFunctionName pixelFormat:MTLPixelFormatBGRA8Unorm];
}

- (id<MTLRenderPipelineState>)newSpatialPipelineWithDevice:(id<MTLDevice>)device fragmentFunction:(NSString *)fragmentFunctionName pixelFormat:(MTLPixelFormat)pixelFormat {
    if (!device) return nil;
    static NSString *source = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct VertexOut { float4 position [[position]]; float2 texCoord; };\n"
    "vertex VertexOut opn_video_vertex(uint vid [[vertex_id]]) {\n"
    "    const float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };\n"
    "    const float2 texCoords[3] = { float2(0.0, 1.0), float2(2.0, 1.0), float2(0.0, -1.0) };\n"
    "    VertexOut out; out.position = float4(positions[vid], 0.0, 1.0); out.texCoord = texCoords[vid]; return out;\n"
    "}\n"
    "static float opn_cubic(float v) {\n"
    "    v = fabs(v);\n"
    "    float v2 = v * v;\n"
    "    float v3 = v2 * v;\n"
    "    return v <= 1.0 ? (1.5 * v3 - 2.5 * v2 + 1.0) : (v < 2.0 ? (-0.5 * v3 + 2.5 * v2 - 4.0 * v + 2.0) : 0.0);\n"
    "}\n"
    "static float2 opn_crop_uv(float2 texCoord, float4 crop) {\n"
    "    return mix(crop.xy, crop.zw, clamp(texCoord, float2(0.0), float2(1.0)));\n"
    "}\n"
    "static float2 opn_clamp_crop(float2 uv, float4 crop) {\n"
    "    return clamp(uv, crop.xy, crop.zw);\n"
    "}\n"
    "static float3 opn_rgb_bicubic(texture2d<float> sourceTexture, sampler s, float2 uv, float4 crop) {\n"
    "    float2 size = float2(sourceTexture.get_width(), sourceTexture.get_height());\n"
    "    float2 pixel = uv * size - 0.5;\n"
    "    float2 base = floor(pixel);\n"
    "    float2 f = pixel - base;\n"
    "    float3 sum = float3(0.0);\n"
    "    float weightSum = 0.0;\n"
    "    for (int j = -1; j <= 2; ++j) {\n"
    "        for (int i = -1; i <= 2; ++i) {\n"
    "            float2 samplePixel = base + float2(i, j) + 0.5;\n"
    "            float2 sampleUv = opn_clamp_crop(samplePixel / size, crop);\n"
    "            float w = opn_cubic(float(i) - f.x) * opn_cubic(f.y - float(j));\n"
    "            sum += sourceTexture.sample(s, sampleUv).rgb * w;\n"
    "            weightSum += w;\n"
    "        }\n"
    "    }\n"
    "    return saturate(sum / max(weightSum, 0.0001));\n"
    "}\n"
    "static float3 opn_nv12_rgb(texture2d<float> yTexture, texture2d<float> uvTexture, sampler s, float2 uv) {\n"
    "    float y = yTexture.sample(s, uv).r;\n"
    "    float2 cbcr = uvTexture.sample(s, uv).rg - float2(0.5, 0.5);\n"
    "    return saturate(float3(y + 1.5748 * cbcr.y, y - 0.1873 * cbcr.x - 0.4681 * cbcr.y, y + 1.8556 * cbcr.x));\n"
    "}\n"
    "static float3 opn_i420_rgb(texture2d<float> yTexture, texture2d<float> uTexture, texture2d<float> vTexture, sampler s, float2 uv) {\n"
    "    float y = yTexture.sample(s, uv).r;\n"
    "    float cb = uTexture.sample(s, uv).r - 0.5;\n"
    "    float cr = vTexture.sample(s, uv).r - 0.5;\n"
    "    return saturate(float3(y + 1.5748 * cr, y - 0.1873 * cb - 0.4681 * cr, y + 1.8556 * cb));\n"
    "}\n"
    "static float3 opn_finish(float3 center, float3 blur, float sharpness, float denoise) {\n"
    "    float3 denoised = mix(center, blur, clamp(denoise, 0.0, 1.0));\n"
    "    return clamp(denoised + (denoised - blur) * sharpness, float3(0.0), float3(1.0));\n"
    "}\n"
    "static float opn_luma(float3 color) {\n"
    "    return dot(color, float3(0.2126, 0.7152, 0.0722));\n"
    "}\n"
    "static float2 opn_edge_aware_jitter(float2 uv, float2 jitter, float edgeMetric, float4 crop) {\n"
    "    float jitterStrength = 1.0 - smoothstep(0.045, 0.16, edgeMetric);\n"
    "    return opn_clamp_crop(uv + jitter * jitterStrength, crop);\n"
    "}\n"
    "static float opn_block_luma(texture2d<float> sourceTexture, sampler s, float2 uv, float2 texel) {\n"
    "    float center = opn_luma(sourceTexture.sample(s, clamp(uv, float2(0.0), float2(1.0))).rgb);\n"
    "    float horizontal = opn_luma(sourceTexture.sample(s, clamp(uv + float2(texel.x, 0.0), float2(0.0), float2(1.0))).rgb) + opn_luma(sourceTexture.sample(s, clamp(uv - float2(texel.x, 0.0), float2(0.0), float2(1.0))).rgb);\n"
    "    float vertical = opn_luma(sourceTexture.sample(s, clamp(uv + float2(0.0, texel.y), float2(0.0), float2(1.0))).rgb) + opn_luma(sourceTexture.sample(s, clamp(uv - float2(0.0, texel.y), float2(0.0), float2(1.0))).rgb);\n"
    "    return (center * 2.0 + horizontal + vertical) / 6.0;\n"
    "}\n"
    "fragment float4 opn_video_spatial_rgb(VertexOut in [[stage_in]], texture2d<float> sourceTexture [[texture(0)]], constant float2 &scale [[buffer(0)]], constant float &sharpness [[buffer(1)]], constant float &denoise [[buffer(2)]], constant float4 &crop [[buffer(3)]], constant float2 &jitter [[buffer(4)]]) {\n"
    "    constexpr sampler s(address::clamp_to_edge, filter::linear);\n"
    "    float2 baseUv = opn_crop_uv(in.texCoord, crop);\n"
    "    float2 texel = max(scale, float2(1.0 / 8192.0));\n"
    "    float centerLuma = opn_luma(sourceTexture.sample(s, baseUv).rgb);\n"
    "    float edgeMetric = abs(centerLuma - opn_luma(sourceTexture.sample(s, opn_clamp_crop(baseUv + float2(texel.x, 0.0), crop)).rgb)) + abs(centerLuma - opn_luma(sourceTexture.sample(s, opn_clamp_crop(baseUv + float2(0.0, texel.y), crop)).rgb));\n"
    "    float2 uv = opn_edge_aware_jitter(baseUv, jitter, edgeMetric, crop);\n"
    "    float3 center = opn_rgb_bicubic(sourceTexture, s, uv, crop);\n"
    "    float3 blur = (opn_rgb_bicubic(sourceTexture, s, uv + float2(texel.x, 0.0), crop) + opn_rgb_bicubic(sourceTexture, s, uv - float2(texel.x, 0.0), crop) + opn_rgb_bicubic(sourceTexture, s, uv + float2(0.0, texel.y), crop) + opn_rgb_bicubic(sourceTexture, s, uv - float2(0.0, texel.y), crop)) * 0.25;\n"
    "    return float4(opn_finish(center, blur, sharpness, denoise), 1.0);\n"
    "}\n"
    "fragment float4 opn_video_spatial_nv12(VertexOut in [[stage_in]], texture2d<float> yTexture [[texture(0)]], texture2d<float> uvTexture [[texture(1)]], constant float2 &scale [[buffer(0)]], constant float &sharpness [[buffer(1)]], constant float &denoise [[buffer(2)]], constant float4 &crop [[buffer(3)]], constant float2 &jitter [[buffer(4)]]) {\n"
    "    constexpr sampler s(address::clamp_to_edge, filter::linear);\n"
    "    float2 baseUv = opn_crop_uv(in.texCoord, crop);\n"
    "    float2 texel = max(scale, float2(1.0 / 8192.0));\n"
    "    float centerLuma = yTexture.sample(s, baseUv).r;\n"
    "    float edgeMetric = abs(centerLuma - yTexture.sample(s, opn_clamp_crop(baseUv + float2(texel.x, 0.0), crop)).r) + abs(centerLuma - yTexture.sample(s, opn_clamp_crop(baseUv + float2(0.0, texel.y), crop)).r);\n"
    "    float2 uv = opn_edge_aware_jitter(baseUv, jitter, edgeMetric, crop);\n"
    "    float3 center = opn_nv12_rgb(yTexture, uvTexture, s, uv);\n"
    "    float3 blur = (opn_nv12_rgb(yTexture, uvTexture, s, opn_clamp_crop(uv + float2(texel.x, 0.0), crop)) + opn_nv12_rgb(yTexture, uvTexture, s, opn_clamp_crop(uv - float2(texel.x, 0.0), crop)) + opn_nv12_rgb(yTexture, uvTexture, s, opn_clamp_crop(uv + float2(0.0, texel.y), crop)) + opn_nv12_rgb(yTexture, uvTexture, s, opn_clamp_crop(uv - float2(0.0, texel.y), crop))) * 0.25;\n"
    "    return float4(opn_finish(center, blur, sharpness, denoise), 1.0);\n"
    "}\n"
    "fragment float4 opn_video_spatial_i420(VertexOut in [[stage_in]], texture2d<float> yTexture [[texture(0)]], texture2d<float> uTexture [[texture(1)]], texture2d<float> vTexture [[texture(2)]], constant float2 &scale [[buffer(0)]], constant float &sharpness [[buffer(1)]], constant float &denoise [[buffer(2)]], constant float4 &crop [[buffer(3)]], constant float2 &jitter [[buffer(4)]]) {\n"
    "    constexpr sampler s(address::clamp_to_edge, filter::linear);\n"
    "    float2 baseUv = opn_crop_uv(in.texCoord, crop);\n"
    "    float2 texel = max(scale, float2(1.0 / 8192.0));\n"
    "    float centerLuma = yTexture.sample(s, baseUv).r;\n"
    "    float edgeMetric = abs(centerLuma - yTexture.sample(s, opn_clamp_crop(baseUv + float2(texel.x, 0.0), crop)).r) + abs(centerLuma - yTexture.sample(s, opn_clamp_crop(baseUv + float2(0.0, texel.y), crop)).r);\n"
    "    float2 uv = opn_edge_aware_jitter(baseUv, jitter, edgeMetric, crop);\n"
    "    float3 center = opn_i420_rgb(yTexture, uTexture, vTexture, s, uv);\n"
    "    float3 blur = (opn_i420_rgb(yTexture, uTexture, vTexture, s, opn_clamp_crop(uv + float2(texel.x, 0.0), crop)) + opn_i420_rgb(yTexture, uTexture, vTexture, s, opn_clamp_crop(uv - float2(texel.x, 0.0), crop)) + opn_i420_rgb(yTexture, uTexture, vTexture, s, opn_clamp_crop(uv + float2(0.0, texel.y), crop)) + opn_i420_rgb(yTexture, uTexture, vTexture, s, opn_clamp_crop(uv - float2(0.0, texel.y), crop))) * 0.25;\n"
    "    return float4(opn_finish(center, blur, sharpness, denoise), 1.0);\n"
    "}\n"
    "fragment float4 opn_video_fast_rgb(VertexOut in [[stage_in]], texture2d<float> sourceTexture [[texture(0)]], constant float2 &scale [[buffer(0)]], constant float &sharpness [[buffer(1)]], constant float &denoise [[buffer(2)]], constant float4 &crop [[buffer(3)]], constant float2 &jitter [[buffer(4)]]) {\n"
    "    constexpr sampler s(address::clamp_to_edge, filter::linear);\n"
    "    float2 uv = opn_crop_uv(in.texCoord, crop);\n"
    "    return float4(sourceTexture.sample(s, uv).rgb, 1.0);\n"
    "}\n"
    "fragment float4 opn_video_fast_nv12(VertexOut in [[stage_in]], texture2d<float> yTexture [[texture(0)]], texture2d<float> uvTexture [[texture(1)]], constant float2 &scale [[buffer(0)]], constant float &sharpness [[buffer(1)]], constant float &denoise [[buffer(2)]], constant float4 &crop [[buffer(3)]], constant float2 &jitter [[buffer(4)]]) {\n"
    "    constexpr sampler s(address::clamp_to_edge, filter::linear);\n"
    "    float2 uv = opn_crop_uv(in.texCoord, crop);\n"
    "    return float4(opn_nv12_rgb(yTexture, uvTexture, s, uv), 1.0);\n"
    "}\n"
    "fragment float4 opn_video_fast_i420(VertexOut in [[stage_in]], texture2d<float> yTexture [[texture(0)]], texture2d<float> uTexture [[texture(1)]], texture2d<float> vTexture [[texture(2)]], constant float2 &scale [[buffer(0)]], constant float &sharpness [[buffer(1)]], constant float &denoise [[buffer(2)]], constant float4 &crop [[buffer(3)]], constant float2 &jitter [[buffer(4)]]) {\n"
    "    constexpr sampler s(address::clamp_to_edge, filter::linear);\n"
    "    float2 uv = opn_crop_uv(in.texCoord, crop);\n"
    "    return float4(opn_i420_rgb(yTexture, uTexture, vTexture, s, uv), 1.0);\n"
    "}\n"
    "fragment float4 opn_video_temporal_motion(VertexOut in [[stage_in]], texture2d<float> currentTexture [[texture(0)]], texture2d<float> historyTexture [[texture(1)]], constant float2 &texel [[buffer(0)]], constant int &hasHistory [[buffer(1)]], constant float2 &jitterDelta [[buffer(2)]]) {\n"
    "    constexpr sampler s(address::clamp_to_edge, filter::linear);\n"
    "    float2 uv = clamp(in.texCoord, float2(0.0), float2(1.0));\n"
    "    if (hasHistory == 0) return float4(0.0, 0.0, 0.0, 1.0);\n"
    "    float2 blockTexel = texel * 2.0;\n"
    "    float currentLuma = opn_block_luma(currentTexture, s, uv, blockTexel);\n"
    "    float bestDiff = 1.0;\n"
    "    float bestScore = 1.0;\n"
    "    float2 bestOffset = float2(0.0);\n"
    "    for (int y = -2; y <= 2; ++y) {\n"
    "        for (int x = -2; x <= 2; ++x) {\n"
    "            float2 offset = jitterDelta + float2((float)x, (float)y) * blockTexel;\n"
    "            float diff = fabs(currentLuma - opn_block_luma(historyTexture, s, uv + offset, blockTexel));\n"
    "            float score = diff + length(float2((float)x, (float)y)) * 0.003;\n"
    "            if (score < bestScore) { bestScore = score; bestDiff = diff; bestOffset = offset; }\n"
    "        }\n"
    "    }\n"
    "    float confidence = 1.0 - smoothstep(0.018, 0.135, bestDiff);\n"
    "    return float4(bestOffset, confidence, bestDiff);\n"
    "}\n"
    "fragment float4 opn_video_temporal_composite(VertexOut in [[stage_in]], texture2d<float> currentTexture [[texture(0)]], texture2d<float> historyTexture [[texture(1)]], texture2d<float> motionTexture [[texture(2)]], constant float2 &texel [[buffer(0)]], constant float &historyWeight [[buffer(1)]], constant float &sharpness [[buffer(2)]], constant int &hasHistory [[buffer(3)]]) {\n"
    "    constexpr sampler s(address::clamp_to_edge, filter::linear);\n"
    "    float2 uv = clamp(in.texCoord, float2(0.0), float2(1.0));\n"
    "    float3 current = currentTexture.sample(s, uv).rgb;\n"
    "    float2 uvL = clamp(uv - float2(texel.x, 0.0), float2(0.0), float2(1.0));\n"
    "    float2 uvR = clamp(uv + float2(texel.x, 0.0), float2(0.0), float2(1.0));\n"
    "    float2 uvU = clamp(uv + float2(0.0, texel.y), float2(0.0), float2(1.0));\n"
    "    float2 uvD = clamp(uv - float2(0.0, texel.y), float2(0.0), float2(1.0));\n"
    "    float3 left = currentTexture.sample(s, uvL).rgb;\n"
    "    float3 right = currentTexture.sample(s, uvR).rgb;\n"
    "    float3 up = currentTexture.sample(s, uvU).rgb;\n"
    "    float3 down = currentTexture.sample(s, uvD).rgb;\n"
    "    float3 upLeft = currentTexture.sample(s, clamp(uv + float2(-texel.x, texel.y), float2(0.0), float2(1.0))).rgb;\n"
    "    float3 upRight = currentTexture.sample(s, clamp(uv + float2(texel.x, texel.y), float2(0.0), float2(1.0))).rgb;\n"
    "    float3 downLeft = currentTexture.sample(s, clamp(uv + float2(-texel.x, -texel.y), float2(0.0), float2(1.0))).rgb;\n"
    "    float3 downRight = currentTexture.sample(s, clamp(uv + float2(texel.x, -texel.y), float2(0.0), float2(1.0))).rgb;\n"
    "    float3 blur = (left + right + up + down) * 0.25;\n"
    "    float3 minColor = min(min(min(min(current, left), min(right, up)), min(down, upLeft)), min(min(upRight, downLeft), downRight));\n"
    "    float3 maxColor = max(max(max(max(current, left), max(right, up)), max(down, upLeft)), max(max(upRight, downLeft), downRight));\n"
    "    float3 mean = (current + left + right + up + down + upLeft + upRight + downLeft + downRight) * (1.0 / 9.0);\n"
    "    float3 moment = (current * current + left * left + right * right + up * up + down * down + upLeft * upLeft + upRight * upRight + downLeft * downLeft + downRight * downRight) * (1.0 / 9.0);\n"
    "    float3 sigma = sqrt(max(moment - mean * mean, float3(0.0)));\n"
    "    float3 clipMin = minColor - sigma * 0.75 - float3(0.004);\n"
    "    float3 clipMax = maxColor + sigma * 0.75 + float3(0.004);\n"
    "    float3 history = current;\n"
    "    float historyDiff = 1.0;\n"
    "    float clipDistance = 1.0;\n"
    "    float motionConfidence = 0.0;\n"
    "    float currentLuma = opn_luma(current);\n"
    "    float edgeStrength = smoothstep(0.014, 0.20, length(current - blur));\n"
    "    if (hasHistory != 0) {\n"
    "        float4 motion = motionTexture.sample(s, uv);\n"
    "        float2 rawHistoryUv = uv + motion.xy;\n"
    "        float historyInside = step(0.0, rawHistoryUv.x) * step(rawHistoryUv.x, 1.0) * step(0.0, rawHistoryUv.y) * step(rawHistoryUv.y, 1.0);\n"
    "        float2 historyUv = clamp(rawHistoryUv, float2(0.0), float2(1.0));\n"
    "        float2 motionTexel2 = max(1.0 / float2((float)motionTexture.get_width(), (float)motionTexture.get_height()), float2(1.0 / 8192.0));\n"
    "        float2 motionRight = motionTexture.sample(s, clamp(uv + float2(motionTexel2.x, 0.0), float2(0.0), float2(1.0))).xy;\n"
    "        float2 motionLeft = motionTexture.sample(s, clamp(uv - float2(motionTexel2.x, 0.0), float2(0.0), float2(1.0))).xy;\n"
    "        float2 motionUp = motionTexture.sample(s, clamp(uv + float2(0.0, motionTexel2.y), float2(0.0), float2(1.0))).xy;\n"
    "        float2 motionDown = motionTexture.sample(s, clamp(uv - float2(0.0, motionTexel2.y), float2(0.0), float2(1.0))).xy;\n"
    "        float motionTexel = max(max(motionTexel2.x, motionTexel2.y), 1.0 / 8192.0);\n"
    "        float vectorDisagreement = (length(motion.xy - motionRight) + length(motion.xy - motionLeft) + length(motion.xy - motionUp) + length(motion.xy - motionDown)) / (motionTexel * 4.0);\n"
    "        float vectorCoherence = 1.0 - smoothstep(2.25, 8.0, vectorDisagreement);\n"
    "        float sceneContinuity = 1.0 - smoothstep(0.105, 0.255, motion.w);\n"
    "        motionConfidence = clamp(motion.z, 0.0, 1.0) * historyInside * vectorCoherence * sceneContinuity;\n"
    "        history = historyTexture.sample(s, historyUv).rgb;\n"
    "        historyDiff = fabs(currentLuma - opn_luma(history));\n"
    "        float3 candidate = historyTexture.sample(s, clamp(historyUv + float2(texel.x, 0.0), float2(0.0), float2(1.0))).rgb;\n"
    "        float diff = fabs(currentLuma - opn_luma(candidate)); if (diff < historyDiff) { historyDiff = diff; history = candidate; }\n"
    "        candidate = historyTexture.sample(s, clamp(historyUv - float2(texel.x, 0.0), float2(0.0), float2(1.0))).rgb;\n"
    "        diff = fabs(currentLuma - opn_luma(candidate)); if (diff < historyDiff) { historyDiff = diff; history = candidate; }\n"
    "        candidate = historyTexture.sample(s, clamp(historyUv + float2(0.0, texel.y), float2(0.0), float2(1.0))).rgb;\n"
    "        diff = fabs(currentLuma - opn_luma(candidate)); if (diff < historyDiff) { historyDiff = diff; history = candidate; }\n"
    "        candidate = historyTexture.sample(s, clamp(historyUv - float2(0.0, texel.y), float2(0.0), float2(1.0))).rgb;\n"
    "        diff = fabs(currentLuma - opn_luma(candidate)); if (diff < historyDiff) { historyDiff = diff; history = candidate; }\n"
    "        float3 clippedHistory = clamp(history, clipMin, clipMax);\n"
    "        clipDistance = length(history - clippedHistory);\n"
    "        history = clippedHistory;\n"
    "        historyDiff = fabs(currentLuma - opn_luma(history));\n"
    "    }\n"
    "    float lumaStability = 1.0 - smoothstep(0.016, 0.125, historyDiff);\n"
    "    float clipStability = 1.0 - smoothstep(0.018, 0.155, clipDistance);\n"
    "    float disocclusionRisk = smoothstep(0.045, 0.17, length(current - blur)) * (1.0 - motionConfidence);\n"
    "    float stability = motionConfidence * lumaStability * clipStability * (1.0 - disocclusionRisk) * mix(1.0, 0.68, edgeStrength);\n"
    "    float temporalMix = hasHistory != 0 ? clamp(historyWeight * stability, 0.0, 0.86) : 0.0;\n"
    "    float3 reconstructed = mix(current, history, temporalMix);\n"
    "    reconstructed += (current - blur) * sharpness * edgeStrength * (1.0 - temporalMix * 0.52);\n"
    "    return float4(clamp(reconstructed, float3(0.0), float3(1.0)), 1.0);\n"
    "}\n"
    "fragment float4 opn_video_present_rgb(VertexOut in [[stage_in]], texture2d<float> sourceTexture [[texture(0)]]) {\n"
    "    constexpr sampler s(address::clamp_to_edge, filter::linear);\n"
    "    float2 uv = clamp(in.texCoord, float2(0.0), float2(1.0));\n"
    "    float2 texel = max(1.0 / float2((float)sourceTexture.get_width(), (float)sourceTexture.get_height()), float2(1.0 / 8192.0));\n"
    "    float3 center = sourceTexture.sample(s, uv).rgb;\n"
    "    float3 left = sourceTexture.sample(s, clamp(uv - float2(texel.x, 0.0), float2(0.0), float2(1.0))).rgb;\n"
    "    float3 right = sourceTexture.sample(s, clamp(uv + float2(texel.x, 0.0), float2(0.0), float2(1.0))).rgb;\n"
    "    float3 up = sourceTexture.sample(s, clamp(uv + float2(0.0, texel.y), float2(0.0), float2(1.0))).rgb;\n"
    "    float3 down = sourceTexture.sample(s, clamp(uv - float2(0.0, texel.y), float2(0.0), float2(1.0))).rgb;\n"
    "    float centerLuma = opn_luma(center);\n"
    "    float horizontalContrast = abs(opn_luma(left) - centerLuma) + abs(opn_luma(right) - centerLuma);\n"
    "    float verticalContrast = abs(opn_luma(up) - centerLuma) + abs(opn_luma(down) - centerLuma);\n"
    "    float edgeAmount = smoothstep(0.04, 0.22, max(horizontalContrast, verticalContrast));\n"
    "    float3 tangent = horizontalContrast > verticalContrast ? (up + down) * 0.5 : (left + right) * 0.5;\n"
    "    float3 resolved = mix(center, tangent, edgeAmount * 0.20);\n"
    "    float3 minColor = min(min(center, left), min(right, min(up, down)));\n"
    "    float3 maxColor = max(max(center, left), max(right, max(up, down)));\n"
    "    return float4(clamp(resolved, minColor, maxColor), 1.0);\n"
    "}\n";

    NSError *libraryError = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&libraryError];
    if (!library) return nil;
    MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
    descriptor.vertexFunction = [library newFunctionWithName:@"opn_video_vertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:fragmentFunctionName];
    descriptor.colorAttachments[0].pixelFormat = pixelFormat;
    NSError *pipelineError = nil;
    return [device newRenderPipelineStateWithDescriptor:descriptor error:&pipelineError];
}

- (BOOL)renderFrame:(RTCVideoFrame *)frame
             toView:(MTKView *)view
           settings:(OPNVideoEnhancementSettings *)settings
             result:(OPNVideoEnhancementResult *)result {
    CFTimeInterval start = CACurrentMediaTime();
    [self populateResult:result settings:settings];
    if (!frame || !view || !settings || settings.configuredTier == OPNVideoEnhancementTierOff) {
        result.fallbackReason = @"enhancement disabled";
        if (result.enhancedPixelBuffer) {
            CVPixelBufferRelease(result.enhancedPixelBuffer);
            result.enhancedPixelBuffer = nil;
        }
        return NO;
    }

    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!drawable || settings.drawableSize.width <= 0.0 || settings.drawableSize.height <= 0.0) {
        result.fallbackReason = @"enhancement renderer got empty drawable";
        [self recordDropInResult:result];
        if (result.enhancedPixelBuffer) {
            CVPixelBufferRelease(result.enhancedPixelBuffer);
            result.enhancedPixelBuffer = nil;
        }
        return NO;
    }

    NSString *pixelFormat = @"unknown";
    NSString *frameSource = @"unknown";
    NSString *textureFallback = @"";
    OPNVideoTextureFrame *textureFrame = [self.textureSource newTextureFrameForFrame:frame pixelFormat:&pixelFormat frameSource:&frameSource fallback:&textureFallback];
    result.pixelFormat = pixelFormat;
    result.frameSource = frameSource;

    OPNVideoRenderTier requestedTier = OPNVideoRenderTierSpatial;
    if (settings.configuredTier == OPNVideoEnhancementTierTemporal) {
        requestedTier = OPNVideoRenderTierTemporal;
    } else if (settings.configuredTier == OPNVideoEnhancementTierMetalFX) {
        requestedTier = OPNVideoRenderTierMetalFX;
    }
    BOOL rendered = NO;
    if (textureFrame && requestedTier == OPNVideoRenderTierTemporal) {
        rendered = [self renderTemporalTextureFrame:textureFrame drawable:drawable settings:settings result:result start:start];
    } else if (textureFrame && requestedTier == OPNVideoRenderTierMetalFX) {
        rendered = [self renderMetalFXTextureFrame:textureFrame drawable:drawable settings:settings result:result start:start];
    } else if (textureFrame && requestedTier == OPNVideoRenderTierSpatial) {
        rendered = [self renderSpatialTextureFrame:textureFrame drawable:drawable settings:settings result:result start:start];
    }
    if (rendered) {
        return YES;
    }

    if (textureFallback.length > 0 && result.fallbackReason.length == 0) result.fallbackReason = textureFallback;
    [self recordDropInResult:result];
    if (result.enhancedPixelBuffer) {
        CVPixelBufferRelease(result.enhancedPixelBuffer);
        result.enhancedPixelBuffer = nil;
    }
    return NO;
}

- (void)populateResult:(OPNVideoEnhancementResult *)result settings:(OPNVideoEnhancementSettings *)settings {
    result.pixelFormat = @"unknown";
    result.renderMode = @"Upscaler";
    result.frameSource = @"processed frame";
    result.renderPath = @"OPNVideoEnhancementRenderer";
    result.fallbackReason = @"";
    result.configuredTier = OPNEnhancementTierName(settings.configuredTier);
    result.activeTier = @"Native fallback";
    result.tierFallbackReason = @"";
    result.sourceResolution = settings.emitDiagnostics ? OPNEnhancementResolutionString(settings.sourceSize) : @"";
    result.drawableResolution = settings.emitDiagnostics ? OPNEnhancementResolutionString(settings.drawableSize) : @"";
    result.diagnostics = @"";
    result.frameTimeMs = -1.0;
    result.droppedFrames = self.droppedFrames;
    if (settings.captureEnhancedPixelBuffer) {
        result.enhancedPixelBuffer = [self consumeCompletedEnhancedPixelBuffer];
    } else {
        result.enhancedPixelBuffer = nil;
        [self clearCompletedEnhancedPixelBuffers];
    }
}

- (void)recordDropInResult:(OPNVideoEnhancementResult *)result {
    self.droppedFrames++;
    result.droppedFrames = self.droppedFrames;
    if (result.tierFallbackReason.length == 0) result.tierFallbackReason = result.fallbackReason.length > 0 ? result.fallbackReason : @"enhancement renderer failed";
}

- (BOOL)renderMetalFXTextureFrame:(OPNVideoTextureFrame *)textureFrame
                          drawable:(id<CAMetalDrawable>)drawable
                          settings:(OPNVideoEnhancementSettings *)settings
                            result:(OPNVideoEnhancementResult *)result
                             start:(CFTimeInterval)start {
    if (![self isMetalFXAvailable] || !self.temporalPresentPipeline) return NO;
    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    if (!commandBuffer) {
        result.fallbackReason = @"MetalFX could not create command buffer";
        return NO;
    }
    id<MTLTexture> outputTexture = [self reusableMetalFXOutputTextureWithWidth:drawable.texture.width height:drawable.texture.height pixelFormat:drawable.texture.pixelFormat];
    if (!outputTexture) {
        result.fallbackReason = @"MetalFX output texture allocation failed";
        return NO;
    }
    id<MTLTexture> sourceTexture = nil;
    BOOL needsSpatialConversion = textureFrame.kind != OPNVideoTextureFrameKindRGB || !OPNVideoTextureFrameUsesFullCrop(textureFrame);
    if (!needsSpatialConversion) {
        sourceTexture = textureFrame.rgbTexture;
    } else {
        id<MTLTexture> primaryTexture = textureFrame.lumaTexture;
        if (textureFrame.kind == OPNVideoTextureFrameKindRGB) primaryTexture = textureFrame.rgbTexture;
        if (!primaryTexture) return NO;
        NSUInteger width = textureFrame.contentWidth > 0 ? textureFrame.contentWidth : primaryTexture.width;
        NSUInteger height = textureFrame.contentHeight > 0 ? textureFrame.contentHeight : primaryTexture.height;
        sourceTexture = [self reusableMetalFXIntermediateTextureWithWidth:width height:height];
        if (!sourceTexture) {
            result.fallbackReason = @"MetalFX intermediate texture allocation failed";
            return NO;
        }
        if (![self encodeSpatialTextureFrame:textureFrame destinationTexture:sourceTexture commandBuffer:commandBuffer settings:settings result:result jitter:nullptr]) {
            result.fallbackReason = @"MetalFX RGB conversion failed";
            return NO;
        }
    }
    NSString *metalFXFallback = @"";
    if (![self.metalFXUpscaler encodeTexture:sourceTexture toTexture:outputTexture commandBuffer:commandBuffer fallback:&metalFXFallback]) {
        result.fallbackReason = metalFXFallback.length > 0 ? metalFXFallback : @"MetalFX encode failed";
        return NO;
    }
    if (![self encodePresentTexture:outputTexture destinationTexture:drawable.texture commandBuffer:commandBuffer result:result]) {
        if (result.fallbackReason.length == 0) result.fallbackReason = @"MetalFX present failed";
        return NO;
    }
    if (settings.captureEnhancedPixelBuffer) [self enqueueEnhancedPixelBufferCaptureFromTexture:drawable.texture commandBuffer:commandBuffer];
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
    result.renderPath = @"OPNMetalFXSpatialScaler";
    result.activeTier = @"MetalFX Spatial";
    result.frameTimeMs = (CACurrentMediaTime() - start) * 1000.0;
    result.droppedFrames = self.droppedFrames;
    return YES;
}

- (id<MTLTexture>)reusableMetalFXIntermediateTextureWithWidth:(NSUInteger)width height:(NSUInteger)height {
    if (!self.device || width == 0 || height == 0) return nil;
    if (self.metalFXIntermediateTexture &&
        self.metalFXIntermediateTexture.width == width &&
        self.metalFXIntermediateTexture.height == height &&
        self.metalFXIntermediateTexture.pixelFormat == MTLPixelFormatBGRA8Unorm) {
        return self.metalFXIntermediateTexture;
    }
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                           width:width
                                                                                          height:height
                                                                                       mipmapped:NO];
    descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    descriptor.storageMode = MTLStorageModePrivate;
    self.metalFXIntermediateTexture = [self.device newTextureWithDescriptor:descriptor];
    self.metalFXIntermediateTexture.label = @"OpenNOW MetalFX conversion intermediate";
    return self.metalFXIntermediateTexture;
}

- (id<MTLTexture>)reusableMetalFXOutputTextureWithWidth:(NSUInteger)width height:(NSUInteger)height pixelFormat:(MTLPixelFormat)pixelFormat {
    if (!self.device || width == 0 || height == 0 || pixelFormat == MTLPixelFormatInvalid) return nil;
    if (self.metalFXOutputTexture &&
        self.metalFXOutputTexture.width == width &&
        self.metalFXOutputTexture.height == height &&
        self.metalFXOutputTexture.pixelFormat == pixelFormat &&
        self.metalFXOutputTexture.storageMode == MTLStorageModePrivate) {
        return self.metalFXOutputTexture;
    }
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pixelFormat
                                                                                           width:width
                                                                                          height:height
                                                                                       mipmapped:NO];
    descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
    descriptor.storageMode = MTLStorageModePrivate;
    self.metalFXOutputTexture = [self.device newTextureWithDescriptor:descriptor];
    self.metalFXOutputTexture.label = @"OpenNOW MetalFX private output";
    return self.metalFXOutputTexture;
}

- (id<MTLTexture>)reusableTemporalTexture:(id<MTLTexture>)texture width:(NSUInteger)width height:(NSUInteger)height pixelFormat:(MTLPixelFormat)pixelFormat label:(NSString *)label {
    if (!self.device || width == 0 || height == 0) return nil;
    if (texture && texture.width == width && texture.height == height && texture.pixelFormat == pixelFormat) return texture;
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pixelFormat
                                                                                           width:width
                                                                                          height:height
                                                                                       mipmapped:NO];
    descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    descriptor.storageMode = MTLStorageModePrivate;
    id<MTLTexture> newTexture = [self.device newTextureWithDescriptor:descriptor];
    newTexture.label = label;
    return newTexture;
}

- (BOOL)renderTemporalTextureFrame:(OPNVideoTextureFrame *)textureFrame
                           drawable:(id<CAMetalDrawable>)drawable
                           settings:(OPNVideoEnhancementSettings *)settings
                             result:(OPNVideoEnhancementResult *)result
                              start:(CFTimeInterval)start {
    if (![self isTemporalAvailable]) return NO;
    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    if (!commandBuffer) {
        result.fallbackReason = @"temporal upscaler could not create command buffer";
        return NO;
    }

    NSUInteger width = drawable.texture.width;
    NSUInteger height = drawable.texture.height;
    NSUInteger motionWidth = std::max<NSUInteger>(1, (width + 1) / 2);
    NSUInteger motionHeight = std::max<NSUInteger>(1, (height + 1) / 2);
    self.temporalCurrentTexture = [self reusableTemporalTexture:self.temporalCurrentTexture width:width height:height pixelFormat:MTLPixelFormatBGRA8Unorm label:@"OpenNOW temporal current"];
    self.temporalOutputTexture = [self reusableTemporalTexture:self.temporalOutputTexture width:width height:height pixelFormat:MTLPixelFormatBGRA8Unorm label:@"OpenNOW temporal output"];
    self.temporalHistoryTexture = [self reusableTemporalTexture:self.temporalHistoryTexture width:width height:height pixelFormat:MTLPixelFormatBGRA8Unorm label:@"OpenNOW temporal history"];
    self.temporalMotionTexture = [self reusableTemporalTexture:self.temporalMotionTexture width:motionWidth height:motionHeight pixelFormat:MTLPixelFormatRGBA16Float label:@"OpenNOW temporal half-res motion"];
    if (!self.temporalCurrentTexture || !self.temporalOutputTexture || !self.temporalHistoryTexture || !self.temporalMotionTexture) {
        result.fallbackReason = @"temporal upscaler could not allocate history textures";
        self.temporalHistoryValid = NO;
        return NO;
    }

    id<MTLTexture> primaryTexture = textureFrame.rgbTexture ?: textureFrame.lumaTexture;
    NSUInteger sourceWidth = primaryTexture ? primaryTexture.width : 0;
    NSUInteger sourceHeight = primaryTexture ? primaryTexture.height : 0;
    float jitterPixelsX = 0.0f;
    float jitterPixelsY = 0.0f;
    OPNTemporalJitterForFrame(self.temporalFrameIndex, &jitterPixelsX, &jitterPixelsY);
    float currentJitter[2] = {sourceWidth > 0 ? jitterPixelsX / (float)sourceWidth : 0.0f,
                              sourceHeight > 0 ? jitterPixelsY / (float)sourceHeight : 0.0f};
    float previousJitter[2] = {self.temporalPreviousJitterX, self.temporalPreviousJitterY};
    if (self.temporalHistoryWidth != width || self.temporalHistoryHeight != height || self.temporalSourceWidth != sourceWidth || self.temporalSourceHeight != sourceHeight) {
        if (self.temporalHistoryWidth > 0 || self.temporalHistoryHeight > 0 || self.temporalSourceWidth > 0 || self.temporalSourceHeight > 0) {
            self.temporalHistoryResetCount++;
        }
        self.temporalHistoryValid = NO;
        self.temporalHistoryWidth = width;
        self.temporalHistoryHeight = height;
        self.temporalSourceWidth = sourceWidth;
        self.temporalSourceHeight = sourceHeight;
        previousJitter[0] = currentJitter[0];
        previousJitter[1] = currentJitter[1];
    }
    BOOL hadHistoryBeforeFrame = self.temporalHistoryValid;
    float jitterDelta[2] = {currentJitter[0] - previousJitter[0], currentJitter[1] - previousJitter[1]};

    if (![self encodeSpatialTextureFrame:textureFrame destinationTexture:self.temporalCurrentTexture commandBuffer:commandBuffer settings:settings result:result jitter:currentJitter]) {
        self.temporalHistoryValid = NO;
        return NO;
    }
    if (![self encodeTemporalMotionTexture:self.temporalCurrentTexture historyTexture:self.temporalHistoryTexture motionTexture:self.temporalMotionTexture jitterDelta:jitterDelta commandBuffer:commandBuffer result:result]) {
        self.temporalHistoryValid = NO;
        return NO;
    }
    if (![self encodeTemporalCurrentTexture:self.temporalCurrentTexture historyTexture:self.temporalHistoryTexture motionTexture:self.temporalMotionTexture destinationTexture:self.temporalOutputTexture commandBuffer:commandBuffer settings:settings result:result]) {
        self.temporalHistoryValid = NO;
        return NO;
    }
    if (![self encodePresentTexture:self.temporalOutputTexture destinationTexture:drawable.texture commandBuffer:commandBuffer result:result]) {
        self.temporalHistoryValid = NO;
        return NO;
    }

    if (settings.captureEnhancedPixelBuffer) [self enqueueEnhancedPixelBufferCaptureFromTexture:drawable.texture commandBuffer:commandBuffer];
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
    id<MTLTexture> previousHistory = self.temporalHistoryTexture;
    self.temporalHistoryTexture = self.temporalOutputTexture;
    self.temporalOutputTexture = previousHistory;
    self.temporalHistoryValid = YES;
    self.temporalPreviousJitterX = currentJitter[0];
    self.temporalPreviousJitterY = currentJitter[1];
    self.temporalFrameIndex = (self.temporalFrameIndex + 1) % 8;

    result.renderPath = @"OPNMetalTemporalUpscaler";
    result.activeTier = @"Temporal reconstruction";
    if (settings.emitDiagnostics) {
        result.diagnostics = [NSString stringWithFormat:@"motion %dx%d half-res; jitter 8-sample %.2f,%.2f px; history %@; resets %llu; AA history clip/adaptive edge resolve",
                              (int)motionWidth,
                              (int)motionHeight,
                              jitterPixelsX,
                              jitterPixelsY,
                              hadHistoryBeforeFrame ? @"reused" : @"priming",
                              (unsigned long long)self.temporalHistoryResetCount];
    }
    result.frameTimeMs = (CACurrentMediaTime() - start) * 1000.0;
    result.droppedFrames = self.droppedFrames;
    return YES;
}

- (BOOL)encodeTemporalMotionTexture:(id<MTLTexture>)currentTexture
                       historyTexture:(id<MTLTexture>)historyTexture
                         motionTexture:(id<MTLTexture>)motionTexture
                           jitterDelta:(const float *)jitterDelta
                         commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                                result:(OPNVideoEnhancementResult *)result {
    if (!currentTexture || !historyTexture || !motionTexture || !commandBuffer || !self.temporalMotionPipeline) {
        result.fallbackReason = @"temporal upscaler missing motion target";
        return NO;
    }
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = motionTexture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (!encoder) {
        result.fallbackReason = @"temporal upscaler could not create motion encoder";
        return NO;
    }
    float texel[2] = {currentTexture.width > 0 ? 1.0f / (float)currentTexture.width : 0.0f,
                      currentTexture.height > 0 ? 1.0f / (float)currentTexture.height : 0.0f};
    int hasHistory = self.temporalHistoryValid ? 1 : 0;
    [encoder setRenderPipelineState:self.temporalMotionPipeline];
    [encoder setFragmentTexture:currentTexture atIndex:0];
    [encoder setFragmentTexture:historyTexture atIndex:1];
    [encoder setFragmentBytes:texel length:sizeof(texel) atIndex:0];
    [encoder setFragmentBytes:&hasHistory length:sizeof(hasHistory) atIndex:1];
    [encoder setFragmentBytes:jitterDelta length:sizeof(float) * 2 atIndex:2];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    return YES;
}

- (BOOL)encodeTemporalCurrentTexture:(id<MTLTexture>)currentTexture
                       historyTexture:(id<MTLTexture>)historyTexture
                         motionTexture:(id<MTLTexture>)motionTexture
                   destinationTexture:(id<MTLTexture>)destinationTexture
                        commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                             settings:(OPNVideoEnhancementSettings *)settings
                               result:(OPNVideoEnhancementResult *)result {
    if (!currentTexture || !historyTexture || !motionTexture || !destinationTexture || !commandBuffer || !self.temporalCompositePipeline) {
        result.fallbackReason = @"temporal upscaler missing composite target";
        return NO;
    }
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = destinationTexture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (!encoder) {
        result.fallbackReason = @"temporal upscaler could not create composite encoder";
        return NO;
    }
    float texel[2] = {currentTexture.width > 0 ? 1.0f / (float)currentTexture.width : 0.0f,
                      currentTexture.height > 0 ? 1.0f / (float)currentTexture.height : 0.0f};
    float denoiseScale = std::max(0.0f, std::min(1.0f, (float)settings.denoise / 20.0f));
    float sharpnessScale = std::max(0.0f, std::min(1.0f, (float)settings.sharpness / 40.0f));
    float historyWeight = std::max(0.35f, std::min(0.76f, 0.52f + denoiseScale * 0.24f - sharpnessScale * 0.08f));
    float temporalSharpness = std::max(0.0f, std::min(0.42f, 0.08f + sharpnessScale * 0.34f));
    int hasHistory = self.temporalHistoryValid ? 1 : 0;
    [encoder setRenderPipelineState:self.temporalCompositePipeline];
    [encoder setFragmentTexture:currentTexture atIndex:0];
    [encoder setFragmentTexture:historyTexture atIndex:1];
    [encoder setFragmentTexture:motionTexture atIndex:2];
    [encoder setFragmentBytes:texel length:sizeof(texel) atIndex:0];
    [encoder setFragmentBytes:&historyWeight length:sizeof(historyWeight) atIndex:1];
    [encoder setFragmentBytes:&temporalSharpness length:sizeof(temporalSharpness) atIndex:2];
    [encoder setFragmentBytes:&hasHistory length:sizeof(hasHistory) atIndex:3];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    return YES;
}

- (BOOL)encodePresentTexture:(id<MTLTexture>)sourceTexture
          destinationTexture:(id<MTLTexture>)destinationTexture
               commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                      result:(OPNVideoEnhancementResult *)result {
    if (!sourceTexture || !destinationTexture || !commandBuffer || !self.temporalPresentPipeline) {
        result.fallbackReason = @"temporal upscaler missing present target";
        return NO;
    }
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = destinationTexture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (!encoder) {
        result.fallbackReason = @"temporal upscaler could not create present encoder";
        return NO;
    }
    [encoder setRenderPipelineState:self.temporalPresentPipeline];
    [encoder setFragmentTexture:sourceTexture atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    return YES;
}

- (BOOL)renderSpatialTextureFrame:(OPNVideoTextureFrame *)textureFrame
                    drawable:(id<CAMetalDrawable>)drawable
                    settings:(OPNVideoEnhancementSettings *)settings
                      result:(OPNVideoEnhancementResult *)result
                       start:(CFTimeInterval)start {
    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    if (!commandBuffer) {
        result.fallbackReason = @"spatial scaler could not create command buffer";
        return NO;
    }
    if (![self encodeSpatialTextureFrame:textureFrame destinationTexture:drawable.texture commandBuffer:commandBuffer settings:settings result:result jitter:nullptr]) {
        return NO;
    }
    if (settings.captureEnhancedPixelBuffer) [self enqueueEnhancedPixelBufferCaptureFromTexture:drawable.texture commandBuffer:commandBuffer];
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];

    result.renderPath = @"OPNMetalSpatialUpscaler";
    result.activeTier = settings.lowCostSpatial ? @"Metal Spatial Low Cost" : @"Metal Spatial";
    result.frameTimeMs = (CACurrentMediaTime() - start) * 1000.0;
    result.droppedFrames = self.droppedFrames;
    return YES;
}

- (BOOL)encodeSpatialTextureFrame:(OPNVideoTextureFrame *)textureFrame
                destinationTexture:(id<MTLTexture>)destinationTexture
                     commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                          settings:(OPNVideoEnhancementSettings *)settings
                            result:(OPNVideoEnhancementResult *)result
                            jitter:(const float *)jitter {
    if (!textureFrame || !destinationTexture || !commandBuffer) {
        result.fallbackReason = @"spatial scaler missing target";
        return NO;
    }
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = destinationTexture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (!encoder) {
        result.fallbackReason = @"spatial scaler could not create encoder";
        return NO;
    }

    id<MTLTexture> primaryTexture = textureFrame.rgbTexture;
    id<MTLRenderPipelineState> pipeline = settings.lowCostSpatial && self.fastSpatialRGBPipeline ? self.fastSpatialRGBPipeline : self.spatialRGBPipeline;
    if (textureFrame.kind == OPNVideoTextureFrameKindNV12) {
        primaryTexture = textureFrame.lumaTexture;
        pipeline = settings.lowCostSpatial && self.fastSpatialNV12Pipeline ? self.fastSpatialNV12Pipeline : self.spatialNV12Pipeline;
    } else if (textureFrame.kind == OPNVideoTextureFrameKindI420) {
        primaryTexture = textureFrame.lumaTexture;
        pipeline = settings.lowCostSpatial && self.fastSpatialI420Pipeline ? self.fastSpatialI420Pipeline : self.spatialI420Pipeline;
    }
    if (!primaryTexture || !pipeline) {
        result.fallbackReason = @"spatial scaler missing texture or pipeline";
        return NO;
    }
    float texel[2] = {primaryTexture.width > 0 ? 1.0f / (float)primaryTexture.width : 0.0f,
                      primaryTexture.height > 0 ? 1.0f / (float)primaryTexture.height : 0.0f};
    float zeroJitter[2] = {0.0f, 0.0f};
    const float *activeJitter = jitter ? jitter : zeroJitter;
    float sharpness = std::max(0.0f, std::min(4.0f, (float)settings.sharpness / 10.0f));
    float denoise = std::max(0.0f, std::min(1.0f, ((float)settings.denoise / 10.0f) * 0.65f));
    CGRect cropRect = textureFrame.cropRect;
    if (cropRect.size.width <= 0.0 || cropRect.size.height <= 0.0) cropRect = CGRectMake(0.0, 0.0, 1.0, 1.0);
    float crop[4] = {
        (float)std::max<CGFloat>(0.0, std::min<CGFloat>(cropRect.origin.x, 1.0)),
        (float)std::max<CGFloat>(0.0, std::min<CGFloat>(cropRect.origin.y, 1.0)),
        (float)std::max<CGFloat>(0.0, std::min<CGFloat>(cropRect.origin.x + cropRect.size.width, 1.0)),
        (float)std::max<CGFloat>(0.0, std::min<CGFloat>(cropRect.origin.y + cropRect.size.height, 1.0)),
    };
    if (crop[2] <= crop[0] || crop[3] <= crop[1]) {
        crop[0] = 0.0f;
        crop[1] = 0.0f;
        crop[2] = 1.0f;
        crop[3] = 1.0f;
    }
    [encoder setRenderPipelineState:pipeline];
    [encoder setFragmentTexture:primaryTexture atIndex:0];
    if (textureFrame.kind == OPNVideoTextureFrameKindNV12) [encoder setFragmentTexture:textureFrame.chromaTexture atIndex:1];
    if (textureFrame.kind == OPNVideoTextureFrameKindI420) {
        [encoder setFragmentTexture:textureFrame.chromaUTexture atIndex:1];
        [encoder setFragmentTexture:textureFrame.chromaVTexture atIndex:2];
    }
    [encoder setFragmentBytes:texel length:sizeof(texel) atIndex:0];
    [encoder setFragmentBytes:&sharpness length:sizeof(sharpness) atIndex:1];
    [encoder setFragmentBytes:&denoise length:sizeof(denoise) atIndex:2];
    [encoder setFragmentBytes:crop length:sizeof(crop) atIndex:3];
    [encoder setFragmentBytes:activeJitter length:sizeof(float) * 2 atIndex:4];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    if (settings.lowCostSpatial) result.activeTier = @"Metal Spatial Low Cost";
    return YES;
}

- (BOOL)renderCoreImageFrame:(RTCVideoFrame *)frame
                    drawable:(id<CAMetalDrawable>)drawable
                    settings:(OPNVideoEnhancementSettings *)settings
                      result:(OPNVideoEnhancementResult *)result
                       start:(CFTimeInterval)start {
    if (!self.ciContext || !self.commandQueue || !self.outputColorSpace) {
        result.fallbackReason = @"Core Image fallback unavailable";
        return NO;
    }
#if defined(OPN_HAVE_LIBWEBRTC)
    CIImage *image = nil;
    id<RTCVideoFrameBuffer> buffer = frame.buffer;
    if ([buffer isKindOfClass:RTCCVPixelBuffer.class]) {
        RTCCVPixelBuffer *cvBuffer = (RTCCVPixelBuffer *)buffer;
        image = [CIImage imageWithCVPixelBuffer:cvBuffer.pixelBuffer];
        if (cvBuffer.requiresCropping) {
            CGRect crop = CGRectMake(cvBuffer.cropX, cvBuffer.cropY, cvBuffer.cropWidth, cvBuffer.cropHeight);
            image = [[image imageByCroppingToRect:crop] imageByApplyingTransform:CGAffineTransformMakeTranslation(-crop.origin.x, -crop.origin.y)];
        }
        result.frameSource = @"CVPixelBuffer";
        result.pixelFormat = OPNVideoPixelFormatName(CVPixelBufferGetPixelFormatType(cvBuffer.pixelBuffer));
    } else {
        RTCVideoFrame *i420Frame = [frame newI420VideoFrame];
        id<RTCI420Buffer> i420 = (id<RTCI420Buffer>)i420Frame.buffer;
        if (!i420 || i420.width <= 0 || i420.height <= 0) {
            result.fallbackReason = @"Core Image fallback could not read I420 frame";
            return NO;
        }
        NSDictionary *attributes = @{(__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
                                     (__bridge NSString *)kCVPixelBufferCGImageCompatibilityKey: @YES,
                                     (__bridge NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES};
        CVPixelBufferRef output = nil;
        CVReturn createResult = CVPixelBufferCreate(kCFAllocatorDefault,
                                                    (size_t)i420.width,
                                                    (size_t)i420.height,
                                                    kCVPixelFormatType_32BGRA,
                                                    (__bridge CFDictionaryRef)attributes,
                                                    &output);
        if (createResult != kCVReturnSuccess || !output) {
            result.fallbackReason = @"Core Image fallback could not allocate I420 buffer";
            return NO;
        }
        CVPixelBufferLockBaseAddress(output, 0);
        uint8_t *dst = (uint8_t *)CVPixelBufferGetBaseAddress(output);
        const size_t dstStride = CVPixelBufferGetBytesPerRow(output);
        for (int y = 0; y < i420.height; y++) {
            uint8_t *row = dst + (size_t)y * dstStride;
            const uint8_t *yRow = i420.dataY + y * i420.strideY;
            const uint8_t *uRow = i420.dataU + (y / 2) * i420.strideU;
            const uint8_t *vRow = i420.dataV + (y / 2) * i420.strideV;
            for (int x = 0; x < i420.width; x++) {
                int yy = (int)yRow[x];
                int uu = (int)uRow[x / 2] - 128;
                int vv = (int)vRow[x / 2] - 128;
                int r = yy + (int)std::lround(1.402 * vv);
                int g = yy - (int)std::lround(0.344136 * uu + 0.714136 * vv);
                int b = yy + (int)std::lround(1.772 * uu);
                row[x * 4 + 0] = (uint8_t)std::max(0, std::min(255, b));
                row[x * 4 + 1] = (uint8_t)std::max(0, std::min(255, g));
                row[x * 4 + 2] = (uint8_t)std::max(0, std::min(255, r));
                row[x * 4 + 3] = 255;
            }
        }
        CVPixelBufferUnlockBaseAddress(output, 0);
        image = [CIImage imageWithCVPixelBuffer:output];
        CVPixelBufferRelease(output);
        result.frameSource = NSStringFromClass([buffer class]) ?: @"I420";
        result.pixelFormat = @"I420";
    }
    if (!image) {
        result.fallbackReason = @"Core Image fallback could not create image";
        return NO;
    }

    CGRect sourceExtent = image.extent;
    if (CGRectIsEmpty(sourceExtent) || sourceExtent.size.width <= 0.0 || sourceExtent.size.height <= 0.0) {
        result.fallbackReason = @"Core Image fallback got empty frame";
        return NO;
    }
    if (settings.denoise > 0) {
        double localSharpnessScale = std::max(0.0, std::min(4.0, (double)settings.sharpness / 10.0));
        double localDenoiseScale = std::max(0.0, std::min(2.0, (double)settings.denoise / 10.0));
        CIFilter *noiseReduction = [CIFilter filterWithName:@"CINoiseReduction"];
        [noiseReduction setDefaults];
        [noiseReduction setValue:image forKey:kCIInputImageKey];
        [noiseReduction setValue:@(0.01 + localDenoiseScale * 0.055) forKey:@"inputNoiseLevel"];
        [noiseReduction setValue:@(0.20 + localSharpnessScale * 0.25) forKey:@"inputSharpness"];
        image = noiseReduction.outputImage ?: image;
    }
    const CGFloat scale = MIN(settings.drawableSize.width / sourceExtent.size.width, settings.drawableSize.height / sourceExtent.size.height);
    if (scale > 0.0 && std::isfinite((double)scale)) {
        CIFilter *lanczos = [CIFilter filterWithName:@"CILanczosScaleTransform"];
        [lanczos setDefaults];
        [lanczos setValue:image forKey:kCIInputImageKey];
        [lanczos setValue:@(scale) forKey:kCIInputScaleKey];
        [lanczos setValue:@1.0 forKey:kCIInputAspectRatioKey];
        image = lanczos.outputImage ?: [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    }
    if (settings.sharpness > 0) {
        double localSharpnessScale = std::max(0.0, std::min(4.0, (double)settings.sharpness / 10.0));
        CIFilter *unsharp = [CIFilter filterWithName:@"CIUnsharpMask"];
        [unsharp setDefaults];
        [unsharp setValue:image forKey:kCIInputImageKey];
        [unsharp setValue:@(0.45 + localSharpnessScale * 1.0) forKey:kCIInputIntensityKey];
        [unsharp setValue:@(0.55 + localSharpnessScale * 1.15) forKey:kCIInputRadiusKey];
        image = unsharp.outputImage ?: image;
    }

    CGRect scaledExtent = image.extent;
    CGFloat x = floor((settings.drawableSize.width - scaledExtent.size.width) * 0.5 - scaledExtent.origin.x);
    CGFloat y = floor((settings.drawableSize.height - scaledExtent.size.height) * 0.5 - scaledExtent.origin.y);
    image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(x, y)];

    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    if (!commandBuffer) {
        result.fallbackReason = @"Core Image fallback could not create command buffer";
        return NO;
    }
    MTLRenderPassDescriptor *clearPass = [MTLRenderPassDescriptor renderPassDescriptor];
    clearPass.colorAttachments[0].texture = drawable.texture;
    clearPass.colorAttachments[0].loadAction = MTLLoadActionClear;
    clearPass.colorAttachments[0].storeAction = MTLStoreActionStore;
    clearPass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:clearPass];
    [encoder endEncoding];
    CGRect outputBounds = CGRectMake(0.0, 0.0, settings.drawableSize.width, settings.drawableSize.height);
    [self.ciContext render:image toMTLTexture:drawable.texture commandBuffer:commandBuffer bounds:outputBounds colorSpace:self.outputColorSpace];
    if (settings.captureEnhancedPixelBuffer) [self enqueueEnhancedPixelBufferCaptureFromTexture:drawable.texture commandBuffer:commandBuffer];
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
    result.renderPath = @"OPNCoreImageCompatibilityUpscaler";
    result.activeTier = @"CoreImage compatibility";
    result.frameTimeMs = (CACurrentMediaTime() - start) * 1000.0;
    result.droppedFrames = self.droppedFrames;
    return YES;
#else
    (void)frame;
    (void)drawable;
    (void)settings;
    (void)start;
    result.fallbackReason = @"WebRTC unavailable";
    return NO;
#endif
}

- (CVPixelBufferRef)consumeCompletedEnhancedPixelBuffer {
    @synchronized (_completedEnhancedPixelBuffers) {
        NSValue *entry = _completedEnhancedPixelBuffers.firstObject;
        if (!entry) return nil;
        [_completedEnhancedPixelBuffers removeObjectAtIndex:0];
        return (CVPixelBufferRef)entry.pointerValue;
    }
}

- (void)clearCompletedEnhancedPixelBuffers {
    @synchronized (_completedEnhancedPixelBuffers) {
        for (NSValue *entry in _completedEnhancedPixelBuffers) {
            CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)entry.pointerValue;
            if (pixelBuffer) CVPixelBufferRelease(pixelBuffer);
        }
        [_completedEnhancedPixelBuffers removeAllObjects];
    }
}

- (CVPixelBufferRef)newPooledEnhancedPixelBufferWithWidth:(NSUInteger)width height:(NSUInteger)height {
    if (width < 2 || height < 2) return nil;
    if (!_enhancedCapturePool || self.enhancedCaptureWidth != width || self.enhancedCaptureHeight != height) {
        if (_enhancedCapturePool) CVPixelBufferPoolRelease(_enhancedCapturePool);
        NSDictionary *attributes = @{
            (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (__bridge NSString *)kCVPixelBufferWidthKey: @(width),
            (__bridge NSString *)kCVPixelBufferHeightKey: @(height),
            (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
            (__bridge NSString *)kCVPixelBufferCGImageCompatibilityKey: @YES,
            (__bridge NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
            (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
        };
        CVReturn status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, (__bridge CFDictionaryRef)attributes, &_enhancedCapturePool);
        if (status != kCVReturnSuccess) {
            _enhancedCapturePool = nil;
            return nil;
        }
        self.enhancedCaptureWidth = width;
        self.enhancedCaptureHeight = height;
    }
    CVPixelBufferRef pixelBuffer = nil;
    CVReturn status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _enhancedCapturePool, &pixelBuffer);
    return status == kCVReturnSuccess ? pixelBuffer : nil;
}

- (void)enqueueEnhancedPixelBufferCaptureFromTexture:(id<MTLTexture>)texture commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
    if (!texture || !commandBuffer || !self.device || !_enhancedCaptureTextureCache) return;
    const NSUInteger width = texture.width;
    const NSUInteger height = texture.height;
    if (width < 2 || height < 2 || texture.pixelFormat != MTLPixelFormatBGRA8Unorm) return;
    CVPixelBufferRef pixelBuffer = [self newPooledEnhancedPixelBufferWithWidth:width height:height];
    if (!pixelBuffer) return;

    CVMetalTextureRef captureTexture = nil;
    CVReturn textureStatus = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                                       _enhancedCaptureTextureCache,
                                                                       pixelBuffer,
                                                                       nil,
                                                                       MTLPixelFormatBGRA8Unorm,
                                                                       width,
                                                                       height,
                                                                       0,
                                                                       &captureTexture);
    if (textureStatus != kCVReturnSuccess || !captureTexture) {
        CVPixelBufferRelease(pixelBuffer);
        return;
    }

    id<MTLTexture> destinationTexture = CVMetalTextureGetTexture(captureTexture);
    if (!destinationTexture) {
        CFRelease(captureTexture);
        CVPixelBufferRelease(pixelBuffer);
        return;
    }

    id<MTLBlitCommandEncoder> blitEncoder = [commandBuffer blitCommandEncoder];
    if (!blitEncoder) {
        CFRelease(captureTexture);
        CVPixelBufferRelease(pixelBuffer);
        return;
    }
    [blitEncoder copyFromTexture:texture
                     sourceSlice:0
                     sourceLevel:0
                    sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(width, height, 1)
                        toTexture:destinationTexture
                 destinationSlice:0
                 destinationLevel:0
                destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blitEncoder endEncoding];

    NSMutableArray *completedBuffers = _completedEnhancedPixelBuffers;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completedCommandBuffer) {
        CFRelease(captureTexture);
        if (completedCommandBuffer.status == MTLCommandBufferStatusError) {
            CVPixelBufferRelease(pixelBuffer);
            return;
        }
        @synchronized (completedBuffers) {
            [completedBuffers addObject:[NSValue valueWithPointer:pixelBuffer]];
            while (completedBuffers.count > 3) {
                CVPixelBufferRef staleBuffer = (CVPixelBufferRef)((NSValue *)completedBuffers.firstObject).pointerValue;
                if (staleBuffer) CVPixelBufferRelease(staleBuffer);
                [completedBuffers removeObjectAtIndex:0];
            }
        }
    }];
}

@end
