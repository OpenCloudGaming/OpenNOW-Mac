#include "OPNVideoEnhancementRenderer.h"

#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#if __has_include(<CoreML/CoreML.h>)
#import <CoreML/CoreML.h>
#define OPN_HAVE_COREML 1
#else
#define OPN_HAVE_COREML 0
#endif
#if __has_include(<MetalFX/MetalFX.h>)
#import <MetalFX/MetalFX.h>
#define OPN_HAVE_METALFX 1
#else
#define OPN_HAVE_METALFX 0
#endif

#include <algorithm>
#include <cmath>

#if defined(OPN_HAVE_LIBWEBRTC)
#import <WebRTC/WebRTC.h>
#import <WebRTC/RTCCVPixelBuffer.h>
#import <WebRTC/RTCVideoFrame.h>
#endif

@implementation OPNVideoEnhancementSettings
@end

@implementation OPNVideoEnhancementResult
@end

static NSString *OPNEnhancementResolutionString(CGSize size) {
    int width = (int)std::llround(std::max<CGFloat>(0.0, size.width));
    int height = (int)std::llround(std::max<CGFloat>(0.0, size.height));
    return width > 0 && height > 0 ? [NSString stringWithFormat:@"%dx%d", width, height] : @"unknown";
}

static NSString *OPNEnhancementTierName(OPNVideoEnhancementTier tier) {
    switch (tier) {
        case OPNVideoEnhancementTierNeuralSpatial: return @"Neural Spatial";
        case OPNVideoEnhancementTierSpatial: return @"Spatial";
        case OPNVideoEnhancementTierMetalFX: return @"MetalFX";
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

@interface OPNVideoTextureSource : NSObject
- (instancetype)initWithDevice:(id<MTLDevice>)device;
- (id)newTextureFrameForFrame:(RTCVideoFrame *)frame pixelFormat:(NSString **)pixelFormat frameSource:(NSString **)frameSource fallback:(NSString **)fallback;
@end

typedef NS_ENUM(NSInteger, OPNVideoTextureFrameKind) {
    OPNVideoTextureFrameKindRGB = 0,
    OPNVideoTextureFrameKindNV12 = 1,
    OPNVideoTextureFrameKindI420 = 2,
};

typedef NS_ENUM(NSInteger, OPNVideoGovernorTier) {
    OPNVideoGovernorTierNative = 0,
    OPNVideoGovernorTierSpatial = 1,
    OPNVideoGovernorTierMetalFX = 2,
    OPNVideoGovernorTierNeuralSpatial = 3,
};

@interface OPNVideoTextureFrame : NSObject
@property(nonatomic, assign) OPNVideoTextureFrameKind kind;
@property(nonatomic, strong) id<MTLTexture> rgbTexture;
@property(nonatomic, strong) id<MTLTexture> lumaTexture;
@property(nonatomic, strong) id<MTLTexture> chromaTexture;
@property(nonatomic, strong) id<MTLTexture> chromaUTexture;
@property(nonatomic, strong) id<MTLTexture> chromaVTexture;
@end

@implementation OPNVideoTextureFrame
@end

@implementation OPNVideoTextureSource {
    CVMetalTextureCacheRef _textureCache;
    id<MTLDevice> _device;
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
        textureFrame.lumaTexture = [self newPlaneTextureWithWidth:(NSUInteger)i420.width height:(NSUInteger)i420.height bytes:i420.dataY bytesPerRow:(NSUInteger)i420.strideY label:@"OpenNOW I420 Y"];
        textureFrame.chromaUTexture = [self newPlaneTextureWithWidth:(NSUInteger)i420.chromaWidth height:(NSUInteger)i420.chromaHeight bytes:i420.dataU bytesPerRow:(NSUInteger)i420.strideU label:@"OpenNOW I420 U"];
        textureFrame.chromaVTexture = [self newPlaneTextureWithWidth:(NSUInteger)i420.chromaWidth height:(NSUInteger)i420.chromaHeight bytes:i420.dataV bytesPerRow:(NSUInteger)i420.strideV label:@"OpenNOW I420 V"];
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

@end

@interface OPNNeuralSpatialUpscaler : NSObject
- (instancetype)initWithDevice:(id<MTLDevice>)device ciContext:(CIContext *)ciContext outputColorSpace:(CGColorSpaceRef)outputColorSpace;
- (BOOL)isAvailable;
- (CVPixelBufferRef)newUpscaledPixelBufferFromTexture:(id<MTLTexture>)sourceTexture fallback:(NSString **)fallback CF_RETURNS_RETAINED;
@end

@implementation OPNNeuralSpatialUpscaler {
    id<MTLDevice> _device;
    CIContext *_ciContext;
    CGColorSpaceRef _outputColorSpace;
#if OPN_HAVE_COREML
    MLModel *_model;
    NSString *_inputName;
    NSString *_outputName;
#endif
    BOOL _modelLoadAttempted;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device ciContext:(CIContext *)ciContext outputColorSpace:(CGColorSpaceRef)outputColorSpace {
    self = [super init];
    if (self) {
        _device = device;
        _ciContext = ciContext;
        _outputColorSpace = outputColorSpace ? CGColorSpaceRetain(outputColorSpace) : nil;
    }
    return self;
}

- (void)dealloc {
    if (_outputColorSpace) {
        CGColorSpaceRelease(_outputColorSpace);
        _outputColorSpace = nil;
    }
}

- (BOOL)isAvailable {
    NSString *fallback = @"";
    return [self loadModelIfNeededWithFallback:&fallback] && [self deviceAllowsNeuralSpatial];
}

- (BOOL)deviceAllowsNeuralSpatial {
    if (!_device) return NO;
    if (NSProcessInfo.processInfo.thermalState >= NSProcessInfoThermalStateSerious) return NO;
    if (@available(macOS 12.0, *)) {
        if (NSProcessInfo.processInfo.lowPowerModeEnabled) return NO;
    }
    if (@available(macOS 11.0, *)) {
        return [_device supportsFamily:MTLGPUFamilyApple1];
    }
    return NO;
}

- (BOOL)loadModelIfNeededWithFallback:(NSString **)fallback {
#if OPN_HAVE_COREML
    if (_model) return YES;
    if (_modelLoadAttempted) {
        if (fallback) *fallback = @"Neural spatial model unavailable; using spatial scaler";
        return NO;
    }
    _modelLoadAttempted = YES;

    NSURL *modelURL = [NSBundle.mainBundle URLForResource:@"OPNNeuralSpatialUpscaler" withExtension:@"mlmodelc"];
    if (!modelURL) {
        if (fallback) *fallback = @"Neural spatial model asset missing; using spatial scaler";
        return NO;
    }

    NSError *modelError = nil;
    MLModelConfiguration *configuration = [[MLModelConfiguration alloc] init];
    configuration.computeUnits = MLComputeUnitsAll;
    _model = [MLModel modelWithContentsOfURL:modelURL configuration:configuration error:&modelError];
    if (!_model) {
        if (fallback) *fallback = modelError.localizedDescription.length > 0 ? [NSString stringWithFormat:@"Neural spatial model load failed: %@", modelError.localizedDescription] : @"Neural spatial model load failed";
        return NO;
    }

    NSDictionary<NSString *, MLFeatureDescription *> *inputs = _model.modelDescription.inputDescriptionsByName;
    for (NSString *name in inputs) {
        MLFeatureDescription *description = inputs[name];
        if (description.type == MLFeatureTypeImage) {
            _inputName = [name copy];
            break;
        }
    }
    NSDictionary<NSString *, MLFeatureDescription *> *outputs = _model.modelDescription.outputDescriptionsByName;
    for (NSString *name in outputs) {
        MLFeatureDescription *description = outputs[name];
        if (description.type == MLFeatureTypeImage) {
            _outputName = [name copy];
            break;
        }
    }
    if (_inputName.length == 0 || _outputName.length == 0) {
        _model = nil;
        if (fallback) *fallback = @"Neural spatial model must expose image input and image output";
        return NO;
    }
    return YES;
#else
    if (fallback) *fallback = @"Core ML headers unavailable; using spatial scaler";
    return NO;
#endif
}

- (CVPixelBufferRef)newUpscaledPixelBufferFromTexture:(id<MTLTexture>)sourceTexture fallback:(NSString **)fallback {
#if OPN_HAVE_COREML
    if (![self deviceAllowsNeuralSpatial]) {
        if (fallback) *fallback = @"Neural spatial disabled by device power or thermal state";
        return nil;
    }
    if (![self loadModelIfNeededWithFallback:fallback]) return nil;
    CVPixelBufferRef inputPixelBuffer = [self newModelInputPixelBufferFromTexture:sourceTexture fallback:fallback];
    if (!inputPixelBuffer) return nil;

    NSError *featureError = nil;
    MLFeatureValue *inputValue = [MLFeatureValue featureValueWithPixelBuffer:inputPixelBuffer];
    MLDictionaryFeatureProvider *provider = [[MLDictionaryFeatureProvider alloc] initWithDictionary:@{_inputName: inputValue} error:&featureError];
    CVPixelBufferRelease(inputPixelBuffer);
    if (!provider) {
        if (fallback) *fallback = featureError.localizedDescription.length > 0 ? [NSString stringWithFormat:@"Neural spatial input failed: %@", featureError.localizedDescription] : @"Neural spatial input failed";
        return nil;
    }

    NSError *predictionError = nil;
    id<MLFeatureProvider> prediction = [_model predictionFromFeatures:provider error:&predictionError];
    if (!prediction) {
        if (fallback) *fallback = predictionError.localizedDescription.length > 0 ? [NSString stringWithFormat:@"Neural spatial prediction failed: %@", predictionError.localizedDescription] : @"Neural spatial prediction failed";
        return nil;
    }
    MLFeatureValue *outputValue = [prediction featureValueForName:_outputName];
    CVPixelBufferRef outputPixelBuffer = outputValue.imageBufferValue;
    if (!outputPixelBuffer) {
        if (fallback) *fallback = @"Neural spatial output image missing";
        return nil;
    }
    CVPixelBufferRetain(outputPixelBuffer);
    return outputPixelBuffer;
#else
    (void)sourceTexture;
    if (fallback) *fallback = @"Core ML headers unavailable; using spatial scaler";
    return nil;
#endif
}

- (CVPixelBufferRef)newModelInputPixelBufferFromTexture:(id<MTLTexture>)sourceTexture fallback:(NSString **)fallback {
    if (!sourceTexture || !_ciContext || !_outputColorSpace) {
        if (fallback) *fallback = @"Neural spatial input texture unavailable";
        return nil;
    }
    size_t width = sourceTexture.width;
    size_t height = sourceTexture.height;
#if OPN_HAVE_COREML
    MLFeatureDescription *inputDescription = _model.modelDescription.inputDescriptionsByName[_inputName];
    if (inputDescription.imageConstraint.pixelsWide > 0 && inputDescription.imageConstraint.pixelsHigh > 0) {
        width = (size_t)inputDescription.imageConstraint.pixelsWide;
        height = (size_t)inputDescription.imageConstraint.pixelsHigh;
    }
#endif
    if (width == 0 || height == 0) {
        if (fallback) *fallback = @"Neural spatial input dimensions unavailable";
        return nil;
    }
    NSDictionary *attributes = @{(__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
                                 (__bridge NSString *)kCVPixelBufferCGImageCompatibilityKey: @YES,
                                 (__bridge NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
                                 (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}};
    CVPixelBufferRef pixelBuffer = nil;
    CVReturn createResult = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attributes, &pixelBuffer);
    if (createResult != kCVReturnSuccess || !pixelBuffer) {
        if (fallback) *fallback = @"Neural spatial input allocation failed";
        return nil;
    }
    CIImage *image = [CIImage imageWithMTLTexture:sourceTexture options:@{kCIImageColorSpace: (__bridge id)_outputColorSpace}];
    if (!image) {
        CVPixelBufferRelease(pixelBuffer);
        if (fallback) *fallback = @"Neural spatial input image creation failed";
        return nil;
    }
    CGRect extent = image.extent;
    if (!CGRectIsEmpty(extent) && extent.size.width > 0.0 && extent.size.height > 0.0) {
        CGFloat scale = MIN((CGFloat)width / extent.size.width, (CGFloat)height / extent.size.height);
        image = [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
        CGRect scaledExtent = image.extent;
        CGFloat x = floor(((CGFloat)width - scaledExtent.size.width) * 0.5 - scaledExtent.origin.x);
        CGFloat y = floor(((CGFloat)height - scaledExtent.size.height) * 0.5 - scaledExtent.origin.y);
        image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(x, y)];
    }
    [_ciContext render:image toCVPixelBuffer:pixelBuffer bounds:CGRectMake(0.0, 0.0, width, height) colorSpace:_outputColorSpace];
    return pixelBuffer;
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
@property(nonatomic, strong) OPNNeuralSpatialUpscaler *neuralSpatialUpscaler;
@property(nonatomic, strong) OPNMetalFXUpscaler *metalFXUpscaler;
@property(nonatomic, strong) id<MTLRenderPipelineState> spatialRGBPipeline;
@property(nonatomic, strong) id<MTLRenderPipelineState> spatialNV12Pipeline;
@property(nonatomic, strong) id<MTLRenderPipelineState> spatialI420Pipeline;
@property(nonatomic, assign) uint64_t droppedFrames;
@property(nonatomic, assign) OPNVideoGovernorTier governorTier;
@property(nonatomic, assign) NSInteger overloadScore;
@property(nonatomic, assign) NSInteger recoveryScore;
@end

@implementation OPNVideoEnhancementRenderer

- (instancetype)initWithDevice:(id<MTLDevice>)device commandQueue:(id<MTLCommandQueue>)commandQueue {
    self = [super init];
    if (self) {
        _device = device;
        _commandQueue = commandQueue;
        _ciContext = device ? [CIContext contextWithMTLDevice:device options:@{kCIContextWorkingColorSpace: [NSNull null]}] : nil;
        _outputColorSpace = CGColorSpaceCreateDeviceRGB();
        _textureSource = [[OPNVideoTextureSource alloc] initWithDevice:device];
        _neuralSpatialUpscaler = [[OPNNeuralSpatialUpscaler alloc] initWithDevice:device ciContext:_ciContext outputColorSpace:_outputColorSpace];
        _metalFXUpscaler = [[OPNMetalFXUpscaler alloc] initWithDevice:device];
        _spatialRGBPipeline = [self newSpatialPipelineWithDevice:device fragmentFunction:@"opn_video_spatial_rgb"];
        _spatialNV12Pipeline = [self newSpatialPipelineWithDevice:device fragmentFunction:@"opn_video_spatial_nv12"];
        _spatialI420Pipeline = [self newSpatialPipelineWithDevice:device fragmentFunction:@"opn_video_spatial_i420"];
        _droppedFrames = 0;
        _governorTier = OPNVideoGovernorTierMetalFX;
        _overloadScore = 0;
        _recoveryScore = 0;
    }
    return self;
}

- (void)dealloc {
    if (_outputColorSpace) {
        CGColorSpaceRelease(_outputColorSpace);
        _outputColorSpace = nil;
    }
}

- (BOOL)isMetalFXAvailable {
    return [self.metalFXUpscaler isAvailable];
}

- (BOOL)isNeuralSpatialAvailable {
    return [self.neuralSpatialUpscaler isAvailable];
}

- (id<MTLRenderPipelineState>)newSpatialPipelineWithDevice:(id<MTLDevice>)device fragmentFunction:(NSString *)fragmentFunctionName {
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
    "static float3 opn_rgb_bicubic(texture2d<float> sourceTexture, sampler s, float2 uv) {\n"
    "    float2 size = float2(sourceTexture.get_width(), sourceTexture.get_height());\n"
    "    float2 pixel = uv * size - 0.5;\n"
    "    float2 base = floor(pixel);\n"
    "    float2 f = pixel - base;\n"
    "    float3 sum = float3(0.0);\n"
    "    float weightSum = 0.0;\n"
    "    for (int j = -1; j <= 2; ++j) {\n"
    "        for (int i = -1; i <= 2; ++i) {\n"
    "            float2 samplePixel = base + float2(i, j) + 0.5;\n"
    "            float2 sampleUv = clamp(samplePixel / size, float2(0.0), float2(1.0));\n"
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
    "fragment float4 opn_video_spatial_rgb(VertexOut in [[stage_in]], texture2d<float> sourceTexture [[texture(0)]], constant float2 &scale [[buffer(0)]], constant float &sharpness [[buffer(1)]], constant float &denoise [[buffer(2)]]) {\n"
    "    constexpr sampler s(address::clamp_to_edge, filter::linear);\n"
    "    float2 uv = clamp(in.texCoord, float2(0.0), float2(1.0));\n"
    "    float3 center = opn_rgb_bicubic(sourceTexture, s, uv);\n"
    "    float2 texel = max(scale, float2(1.0 / 8192.0));\n"
    "    float3 blur = (opn_rgb_bicubic(sourceTexture, s, uv + float2(texel.x, 0.0)) + opn_rgb_bicubic(sourceTexture, s, uv - float2(texel.x, 0.0)) + opn_rgb_bicubic(sourceTexture, s, uv + float2(0.0, texel.y)) + opn_rgb_bicubic(sourceTexture, s, uv - float2(0.0, texel.y))) * 0.25;\n"
    "    return float4(opn_finish(center, blur, sharpness, denoise), 1.0);\n"
    "}\n"
    "fragment float4 opn_video_spatial_nv12(VertexOut in [[stage_in]], texture2d<float> yTexture [[texture(0)]], texture2d<float> uvTexture [[texture(1)]], constant float2 &scale [[buffer(0)]], constant float &sharpness [[buffer(1)]], constant float &denoise [[buffer(2)]]) {\n"
    "    constexpr sampler s(address::clamp_to_edge, filter::linear);\n"
    "    float2 uv = clamp(in.texCoord, float2(0.0), float2(1.0));\n"
    "    float3 center = opn_nv12_rgb(yTexture, uvTexture, s, uv);\n"
    "    float2 texel = max(scale, float2(1.0 / 8192.0));\n"
    "    float3 blur = (opn_nv12_rgb(yTexture, uvTexture, s, uv + float2(texel.x, 0.0)) + opn_nv12_rgb(yTexture, uvTexture, s, uv - float2(texel.x, 0.0)) + opn_nv12_rgb(yTexture, uvTexture, s, uv + float2(0.0, texel.y)) + opn_nv12_rgb(yTexture, uvTexture, s, uv - float2(0.0, texel.y))) * 0.25;\n"
    "    return float4(opn_finish(center, blur, sharpness, denoise), 1.0);\n"
    "}\n"
    "fragment float4 opn_video_spatial_i420(VertexOut in [[stage_in]], texture2d<float> yTexture [[texture(0)]], texture2d<float> uTexture [[texture(1)]], texture2d<float> vTexture [[texture(2)]], constant float2 &scale [[buffer(0)]], constant float &sharpness [[buffer(1)]], constant float &denoise [[buffer(2)]]) {\n"
    "    constexpr sampler s(address::clamp_to_edge, filter::linear);\n"
    "    float2 uv = clamp(in.texCoord, float2(0.0), float2(1.0));\n"
    "    float3 center = opn_i420_rgb(yTexture, uTexture, vTexture, s, uv);\n"
    "    float2 texel = max(scale, float2(1.0 / 8192.0));\n"
    "    float3 blur = (opn_i420_rgb(yTexture, uTexture, vTexture, s, uv + float2(texel.x, 0.0)) + opn_i420_rgb(yTexture, uTexture, vTexture, s, uv - float2(texel.x, 0.0)) + opn_i420_rgb(yTexture, uTexture, vTexture, s, uv + float2(0.0, texel.y)) + opn_i420_rgb(yTexture, uTexture, vTexture, s, uv - float2(0.0, texel.y))) * 0.25;\n"
    "    return float4(opn_finish(center, blur, sharpness, denoise), 1.0);\n"
    "}\n";

    NSError *libraryError = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&libraryError];
    if (!library) return nil;
    MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
    descriptor.vertexFunction = [library newFunctionWithName:@"opn_video_vertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:fragmentFunctionName];
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
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
        return NO;
    }

    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!drawable || settings.drawableSize.width <= 0.0 || settings.drawableSize.height <= 0.0) {
        result.fallbackReason = @"enhancement renderer got empty drawable";
        [self recordDropInResult:result];
        return NO;
    }

    NSString *pixelFormat = @"unknown";
    NSString *frameSource = @"unknown";
    NSString *textureFallback = @"";
    OPNVideoTextureFrame *textureFrame = [self.textureSource newTextureFrameForFrame:frame pixelFormat:&pixelFormat frameSource:&frameSource fallback:&textureFallback];
    result.pixelFormat = pixelFormat;
    result.frameSource = frameSource;

    OPNVideoGovernorTier requestedTier = OPNVideoGovernorTierSpatial;
    if (settings.configuredTier == OPNVideoEnhancementTierNeuralSpatial) {
        requestedTier = OPNVideoGovernorTierNeuralSpatial;
    } else if (settings.configuredTier == OPNVideoEnhancementTierMetalFX) {
        requestedTier = OPNVideoGovernorTierMetalFX;
    }
    if (requestedTier == OPNVideoGovernorTierNeuralSpatial && ![self isNeuralSpatialAvailable]) {
        requestedTier = [self isMetalFXAvailable] ? OPNVideoGovernorTierMetalFX : OPNVideoGovernorTierSpatial;
        result.tierFallbackReason = @"Neural spatial unavailable; using best spatial scaler";
    }
    if (requestedTier == OPNVideoGovernorTierMetalFX && ![self isMetalFXAvailable]) requestedTier = OPNVideoGovernorTierSpatial;
    OPNVideoGovernorTier activeTier = [self governedTierForRequestedTier:requestedTier settings:settings result:result];
    if (activeTier == OPNVideoGovernorTierNative) {
        result.fallbackReason = @"enhancement governor selected native renderer";
        result.activeTier = @"Native fallback";
        if (result.tierFallbackReason.length == 0) result.tierFallbackReason = @"governor selected native renderer to preserve frame pacing";
        return NO;
    }

    if (settings.configuredTier == OPNVideoEnhancementTierMetalFX && ![self isMetalFXAvailable]) {
        result.tierFallbackReason = @"MetalFX unavailable; using custom spatial scaler";
    }

    if (textureFrame && activeTier == OPNVideoGovernorTierNeuralSpatial && [self renderNeuralTextureFrame:textureFrame drawable:drawable settings:settings result:result start:start]) {
        [self updateGovernorAfterFrameTime:result.frameTimeMs requestedTier:requestedTier activeTier:activeTier settings:settings];
        return YES;
    }
    if (textureFrame && activeTier == OPNVideoGovernorTierMetalFX && [self renderMetalFXTextureFrame:textureFrame drawable:drawable settings:settings result:result start:start]) {
        [self updateGovernorAfterFrameTime:result.frameTimeMs requestedTier:requestedTier activeTier:activeTier settings:settings];
        return YES;
    }
    if (textureFrame && [self renderSpatialTextureFrame:textureFrame drawable:drawable settings:settings result:result start:start]) {
        [self updateGovernorAfterFrameTime:result.frameTimeMs requestedTier:requestedTier activeTier:OPNVideoGovernorTierSpatial settings:settings];
        return YES;
    }

    if (textureFallback.length > 0) result.tierFallbackReason = textureFallback;
    if ([self renderCoreImageFrame:frame drawable:drawable settings:settings result:result start:start]) {
        [self updateGovernorAfterFrameTime:result.frameTimeMs requestedTier:requestedTier activeTier:OPNVideoGovernorTierSpatial settings:settings];
        return YES;
    }

    [self recordDropInResult:result];
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
    result.sourceResolution = OPNEnhancementResolutionString(settings.sourceSize);
    result.drawableResolution = OPNEnhancementResolutionString(settings.drawableSize);
    result.frameTimeMs = -1.0;
    result.droppedFrames = self.droppedFrames;
    result.enhancedPixelBuffer = nil;
}

- (void)recordDropInResult:(OPNVideoEnhancementResult *)result {
    self.droppedFrames++;
    result.droppedFrames = self.droppedFrames;
    if (result.tierFallbackReason.length == 0) result.tierFallbackReason = result.fallbackReason.length > 0 ? result.fallbackReason : @"enhancement renderer failed";
}

- (OPNVideoGovernorTier)governedTierForRequestedTier:(OPNVideoGovernorTier)requestedTier settings:(OPNVideoEnhancementSettings *)settings result:(OPNVideoEnhancementResult *)result {
    if (self.governorTier > requestedTier) self.governorTier = requestedTier;
    if (self.governorTier == OPNVideoGovernorTierNative) {
        self.governorTier = OPNVideoGovernorTierSpatial;
        if (result.tierFallbackReason.length == 0) result.tierFallbackReason = @"governor restored minimum enhanced tier";
        return OPNVideoGovernorTierSpatial;
    }
    if (self.governorTier == OPNVideoGovernorTierMetalFX && requestedTier == OPNVideoGovernorTierNeuralSpatial) {
        if (result.tierFallbackReason.length == 0) result.tierFallbackReason = @"governor downgraded Neural Spatial to MetalFX";
        return OPNVideoGovernorTierMetalFX;
    }
    if (self.governorTier == OPNVideoGovernorTierSpatial && requestedTier == OPNVideoGovernorTierMetalFX) {
        if (result.tierFallbackReason.length == 0) result.tierFallbackReason = @"governor downgraded MetalFX to custom spatial scaler";
        return OPNVideoGovernorTierSpatial;
    }
    if (self.governorTier == OPNVideoGovernorTierSpatial && requestedTier == OPNVideoGovernorTierNeuralSpatial) {
        if (result.tierFallbackReason.length == 0) result.tierFallbackReason = @"governor downgraded Neural Spatial to custom spatial scaler";
        return OPNVideoGovernorTierSpatial;
    }
    (void)settings;
    return requestedTier;
}

- (void)updateGovernorAfterFrameTime:(double)frameTimeMs requestedTier:(OPNVideoGovernorTier)requestedTier activeTier:(OPNVideoGovernorTier)activeTier settings:(OPNVideoEnhancementSettings *)settings {
    double budgetMs = settings.targetFrameTimeMs > 0.0 ? settings.targetFrameTimeMs : 16.67;
    BOOL overloaded = frameTimeMs > budgetMs * 0.92;
    BOOL hasHeadroom = frameTimeMs > 0.0 && frameTimeMs < budgetMs * 0.55;

    if (overloaded) {
        self.overloadScore = std::min<NSInteger>(self.overloadScore + 1, 8);
        self.recoveryScore = 0;
    } else {
        self.overloadScore = std::max<NSInteger>(0, self.overloadScore - 1);
        self.recoveryScore = hasHeadroom ? std::min<NSInteger>(self.recoveryScore + 1, 180) : std::max<NSInteger>(0, self.recoveryScore - 1);
    }

    if (self.overloadScore >= 3) {
        if (activeTier == OPNVideoGovernorTierNeuralSpatial) {
            self.governorTier = requestedTier >= OPNVideoGovernorTierMetalFX ? OPNVideoGovernorTierMetalFX : OPNVideoGovernorTierSpatial;
        } else if (activeTier == OPNVideoGovernorTierMetalFX) {
            self.governorTier = OPNVideoGovernorTierSpatial;
        } else if (activeTier == OPNVideoGovernorTierSpatial) {
            self.governorTier = OPNVideoGovernorTierSpatial;
        }
        self.overloadScore = 0;
        self.recoveryScore = 0;
        return;
    }

    if (self.recoveryScore >= 90) {
        if (self.governorTier == OPNVideoGovernorTierNative) {
            self.governorTier = OPNVideoGovernorTierSpatial;
        } else if (self.governorTier == OPNVideoGovernorTierSpatial && requestedTier >= OPNVideoGovernorTierMetalFX) {
            self.governorTier = OPNVideoGovernorTierMetalFX;
        } else if (self.governorTier == OPNVideoGovernorTierMetalFX && requestedTier == OPNVideoGovernorTierNeuralSpatial) {
            self.governorTier = OPNVideoGovernorTierNeuralSpatial;
        }
        self.recoveryScore = 0;
    }
}

- (BOOL)renderNeuralTextureFrame:(OPNVideoTextureFrame *)textureFrame
                         drawable:(id<CAMetalDrawable>)drawable
                         settings:(OPNVideoEnhancementSettings *)settings
                           result:(OPNVideoEnhancementResult *)result
                            start:(CFTimeInterval)start {
    if (![self isNeuralSpatialAvailable]) {
        result.tierFallbackReason = @"Neural spatial unavailable; using best spatial scaler";
        return NO;
    }
    id<MTLTexture> sourceTexture = textureFrame.rgbTexture;
    if (textureFrame.kind != OPNVideoTextureFrameKindRGB) {
        id<MTLTexture> primaryTexture = textureFrame.lumaTexture;
        if (!primaryTexture) return NO;
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                               width:primaryTexture.width
                                                                                              height:primaryTexture.height
                                                                                           mipmapped:NO];
        descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        descriptor.storageMode = MTLStorageModePrivate;
        sourceTexture = [self.device newTextureWithDescriptor:descriptor];
        if (!sourceTexture) {
            result.tierFallbackReason = @"Neural spatial intermediate texture allocation failed; using best spatial scaler";
            return NO;
        }
        id<MTLCommandBuffer> conversionCommandBuffer = [self.commandQueue commandBuffer];
        if (!conversionCommandBuffer || ![self encodeSpatialTextureFrame:textureFrame destinationTexture:sourceTexture commandBuffer:conversionCommandBuffer settings:settings result:result]) {
            result.tierFallbackReason = @"Neural spatial RGB conversion failed; using best spatial scaler";
            return NO;
        }
        [conversionCommandBuffer commit];
        [conversionCommandBuffer waitUntilCompleted];
    }

    NSString *neuralFallback = @"";
    CVPixelBufferRef neuralPixelBuffer = [self.neuralSpatialUpscaler newUpscaledPixelBufferFromTexture:sourceTexture fallback:&neuralFallback];
    if (!neuralPixelBuffer) {
        result.tierFallbackReason = neuralFallback.length > 0 ? neuralFallback : @"Neural spatial inference failed; using best spatial scaler";
        return NO;
    }

    CIImage *image = [CIImage imageWithCVPixelBuffer:neuralPixelBuffer options:@{kCIImageColorSpace: (__bridge id)self.outputColorSpace}];
    if (!image) {
        CVPixelBufferRelease(neuralPixelBuffer);
        result.tierFallbackReason = @"Neural spatial output image creation failed; using best spatial scaler";
        return NO;
    }
    CGRect sourceExtent = image.extent;
    if (!CGRectIsEmpty(sourceExtent) && sourceExtent.size.width > 0.0 && sourceExtent.size.height > 0.0) {
        CGFloat scale = MIN(settings.drawableSize.width / sourceExtent.size.width, settings.drawableSize.height / sourceExtent.size.height);
        image = [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
        CGRect scaledExtent = image.extent;
        CGFloat x = floor((settings.drawableSize.width - scaledExtent.size.width) * 0.5 - scaledExtent.origin.x);
        CGFloat y = floor((settings.drawableSize.height - scaledExtent.size.height) * 0.5 - scaledExtent.origin.y);
        image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(x, y)];
    }

    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    if (!commandBuffer) {
        CVPixelBufferRelease(neuralPixelBuffer);
        result.fallbackReason = @"Neural spatial could not create command buffer";
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
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
    if (settings.captureEnhancedPixelBuffer) [commandBuffer waitUntilCompleted];
    CVPixelBufferRelease(neuralPixelBuffer);

    result.renderPath = @"OPNCoreMLNeuralSpatialUpscaler";
    result.activeTier = @"Neural Spatial";
    result.frameTimeMs = (CACurrentMediaTime() - start) * 1000.0;
    result.droppedFrames = self.droppedFrames;
    if (settings.captureEnhancedPixelBuffer) result.enhancedPixelBuffer = [self newPixelBufferFromTexture:drawable.texture size:settings.drawableSize];
    return YES;
}

- (BOOL)renderMetalFXTextureFrame:(OPNVideoTextureFrame *)textureFrame
                          drawable:(id<CAMetalDrawable>)drawable
                          settings:(OPNVideoEnhancementSettings *)settings
                            result:(OPNVideoEnhancementResult *)result
                             start:(CFTimeInterval)start {
    if (![self isMetalFXAvailable]) return NO;
    id<MTLTexture> sourceTexture = nil;
    if (textureFrame.kind == OPNVideoTextureFrameKindRGB) {
        sourceTexture = textureFrame.rgbTexture;
    } else {
        id<MTLTexture> primaryTexture = textureFrame.lumaTexture;
        if (!primaryTexture) return NO;
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                               width:primaryTexture.width
                                                                                              height:primaryTexture.height
                                                                                           mipmapped:NO];
        descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        descriptor.storageMode = MTLStorageModePrivate;
        sourceTexture = [self.device newTextureWithDescriptor:descriptor];
        if (!sourceTexture) {
            result.tierFallbackReason = @"MetalFX intermediate texture allocation failed; using custom spatial scaler";
            return NO;
        }
        id<MTLCommandBuffer> conversionCommandBuffer = [self.commandQueue commandBuffer];
        if (!conversionCommandBuffer || ![self encodeSpatialTextureFrame:textureFrame destinationTexture:sourceTexture commandBuffer:conversionCommandBuffer settings:settings result:result]) {
            result.tierFallbackReason = @"MetalFX RGB conversion failed; using custom spatial scaler";
            return NO;
        }
        [conversionCommandBuffer commit];
        [conversionCommandBuffer waitUntilCompleted];
    }

    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    if (!commandBuffer) {
        result.fallbackReason = @"MetalFX could not create command buffer";
        return NO;
    }
    NSString *metalFXFallback = @"";
    if (![self.metalFXUpscaler encodeTexture:sourceTexture toTexture:drawable.texture commandBuffer:commandBuffer fallback:&metalFXFallback]) {
        result.tierFallbackReason = metalFXFallback.length > 0 ? metalFXFallback : @"MetalFX encode failed; using custom spatial scaler";
        return NO;
    }
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
    if (settings.captureEnhancedPixelBuffer) [commandBuffer waitUntilCompleted];
    result.renderPath = @"OPNMetalFXSpatialScaler";
    result.activeTier = @"MetalFX Spatial";
    result.frameTimeMs = (CACurrentMediaTime() - start) * 1000.0;
    result.droppedFrames = self.droppedFrames;
    if (settings.captureEnhancedPixelBuffer) result.enhancedPixelBuffer = [self newPixelBufferFromTexture:drawable.texture size:settings.drawableSize];
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
    if (![self encodeSpatialTextureFrame:textureFrame destinationTexture:drawable.texture commandBuffer:commandBuffer settings:settings result:result]) {
        return NO;
    }
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
    if (settings.captureEnhancedPixelBuffer) [commandBuffer waitUntilCompleted];

    result.renderPath = settings.configuredTier == OPNVideoEnhancementTierMetalFX || settings.configuredTier == OPNVideoEnhancementTierNeuralSpatial ? @"OPNEnhancedFallbackSpatial" : @"OPNMetalSpatialUpscaler";
    result.activeTier = settings.configuredTier == OPNVideoEnhancementTierMetalFX || settings.configuredTier == OPNVideoEnhancementTierNeuralSpatial ? @"Enhanced Spatial fallback" : @"Metal Spatial";
    result.frameTimeMs = (CACurrentMediaTime() - start) * 1000.0;
    result.droppedFrames = self.droppedFrames;
    if (settings.captureEnhancedPixelBuffer) result.enhancedPixelBuffer = [self newPixelBufferFromTexture:drawable.texture size:settings.drawableSize];
    return YES;
}

- (BOOL)encodeSpatialTextureFrame:(OPNVideoTextureFrame *)textureFrame
                destinationTexture:(id<MTLTexture>)destinationTexture
                     commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                          settings:(OPNVideoEnhancementSettings *)settings
                            result:(OPNVideoEnhancementResult *)result {
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
    id<MTLRenderPipelineState> pipeline = self.spatialRGBPipeline;
    if (textureFrame.kind == OPNVideoTextureFrameKindNV12) {
        primaryTexture = textureFrame.lumaTexture;
        pipeline = self.spatialNV12Pipeline;
    } else if (textureFrame.kind == OPNVideoTextureFrameKindI420) {
        primaryTexture = textureFrame.lumaTexture;
        pipeline = self.spatialI420Pipeline;
    }
    if (!primaryTexture || !pipeline) {
        result.fallbackReason = @"spatial scaler missing texture or pipeline";
        return NO;
    }
    float texel[2] = {primaryTexture.width > 0 ? 1.0f / (float)primaryTexture.width : 0.0f,
                      primaryTexture.height > 0 ? 1.0f / (float)primaryTexture.height : 0.0f};
    float sharpness = std::max(0.0f, std::min(1.0f, (float)settings.sharpness / 10.0f));
    float denoise = std::max(0.0f, std::min(0.65f, (float)settings.denoise / 10.0f));
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
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
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
        CIFilter *noiseReduction = [CIFilter filterWithName:@"CINoiseReduction"];
        [noiseReduction setDefaults];
        [noiseReduction setValue:image forKey:kCIInputImageKey];
        [noiseReduction setValue:@(0.01 + ((double)settings.denoise / 10.0) * 0.055) forKey:@"inputNoiseLevel"];
        [noiseReduction setValue:@(0.20 + ((double)settings.sharpness / 10.0) * 0.25) forKey:@"inputSharpness"];
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
        CIFilter *unsharp = [CIFilter filterWithName:@"CIUnsharpMask"];
        [unsharp setDefaults];
        [unsharp setValue:image forKey:kCIInputImageKey];
        [unsharp setValue:@(0.45 + ((double)settings.sharpness / 10.0) * 1.0) forKey:kCIInputIntensityKey];
        [unsharp setValue:@(0.55 + ((double)settings.sharpness / 10.0) * 1.15) forKey:kCIInputRadiusKey];
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
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
    if (settings.captureEnhancedPixelBuffer) [commandBuffer waitUntilCompleted];
    result.renderPath = @"OPNCoreImageCompatibilityUpscaler";
    result.activeTier = @"CoreImage compatibility";
    result.frameTimeMs = (CACurrentMediaTime() - start) * 1000.0;
    result.droppedFrames = self.droppedFrames;
    if (settings.captureEnhancedPixelBuffer) result.enhancedPixelBuffer = [self newPixelBufferFromTexture:drawable.texture size:settings.drawableSize];
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

- (CVPixelBufferRef)newPixelBufferFromTexture:(id<MTLTexture>)texture size:(CGSize)size {
    if (!texture || !self.ciContext || size.width <= 0.0 || size.height <= 0.0) return nil;
    const size_t width = (size_t)std::max<CGFloat>(2.0, std::floor(size.width));
    const size_t height = (size_t)std::max<CGFloat>(2.0, std::floor(size.height));
    NSDictionary *attributes = @{(__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
                                 (__bridge NSString *)kCVPixelBufferCGImageCompatibilityKey: @YES,
                                 (__bridge NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
                                 (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}};
    CVPixelBufferRef pixelBuffer = nil;
    CVReturn result = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attributes, &pixelBuffer);
    if (result != kCVReturnSuccess || !pixelBuffer) return nil;
    CIImage *image = [CIImage imageWithMTLTexture:texture options:@{kCIImageColorSpace: (__bridge id)self.outputColorSpace}];
    if (!image) {
        CVPixelBufferRelease(pixelBuffer);
        return nil;
    }
    CGRect bounds = CGRectMake(0.0, 0.0, width, height);
    [self.ciContext render:image toCVPixelBuffer:pixelBuffer bounds:bounds colorSpace:self.outputColorSpace];
    return pixelBuffer;
}

@end
