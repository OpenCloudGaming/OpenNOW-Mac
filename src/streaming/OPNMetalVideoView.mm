#include "OPNMetalVideoView.h"
#include "OPNLibWebRTCStreamSession.h"
#include "OPNVideoEnhancementRenderer.h"

#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <cmath>
#include <string>

#if defined(OPN_HAVE_LIBWEBRTC)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-umbrella"
#import <WebRTC/WebRTC.h>
#import <WebRTC/RTCCVPixelBuffer.h>
#pragma clang diagnostic pop
#import <MetalKit/MetalKit.h>

namespace OPN {
static std::string OPNNSStringToString(NSString *value) {
    return value ? std::string(value.UTF8String ?: "") : std::string();
}
}

@protocol OPNRTCMetalRenderer <NSObject>
- (BOOL)addRenderingDestination:(__kindof MTKView *)view;
- (void)drawFrame:(RTCVideoFrame *)frame;
@end

@interface OPNMetalVideoView () <MTKViewDelegate>
@property(nonatomic, strong) MTKView *metalView;
@property(nonatomic, strong) RTCVideoFrame *videoFrame;
@property(nonatomic, strong) id<OPNRTCMetalRenderer> rendererNV12;
@property(nonatomic, strong) id<OPNRTCMetalRenderer> rendererRGB;
@property(nonatomic, strong) id<OPNRTCMetalRenderer> rendererI420;
@property(nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property(nonatomic, strong) OPNVideoEnhancementRenderer *enhancementRenderer;
@property(nonatomic, assign) CGSize sourceFrameSize;
@property(nonatomic, assign) int targetFps;
@property(nonatomic, assign) uint64_t frameSerial;
@property(nonatomic, assign) uint64_t lastDrawnFrameSerial;
@property(nonatomic, assign) uint64_t enhancementDroppedFrameCount;
@property(nonatomic, assign) double lastEnhancementFrameTimeMs;
@property(nonatomic, assign) CFTimeInterval lastDiagnosticsUpdateTime;
@property(nonatomic, assign) BOOL drawScheduled;
@property(nonatomic, assign) BOOL drawableSizeDirty;
@property(nonatomic, strong) OPNVideoEnhancementSettings *enhancementSettings;
@property(nonatomic, strong) OPNVideoEnhancementResult *enhancementResult;
@property(nonatomic, assign) NSInteger enhancementOverBudgetCount;
@property(nonatomic, assign) NSInteger adaptiveEnhancementPenalty;
@property(nonatomic, assign) void *owner;
- (void)updateDrawableSizeForCurrentBackingScale;
- (CGSize)enhancementDrawableSizeForBoundsSize:(CGSize)boundsSize scale:(CGFloat)scale;
- (void)scheduleDraw;
- (id<OPNRTCMetalRenderer>)newRendererNamed:(NSString *)className fallback:(NSString **)fallback;
- (id<OPNRTCMetalRenderer>)i420RendererWithFallback:(NSString **)fallback;
- (id<OPNRTCMetalRenderer>)rendererForFrame:(RTCVideoFrame *)frame
                                 pixelFormat:(NSString **)pixelFormat
                                  renderMode:(NSString **)renderMode
                                 frameSource:(NSString **)frameSource
                                  renderPath:(NSString **)renderPath
                                     fallback:(NSString **)fallback;
@end

static NSString *OPNVideoResolutionString(CGSize size) {
    int width = (int)std::llround(std::max<CGFloat>(0.0, size.width));
    int height = (int)std::llround(std::max<CGFloat>(0.0, size.height));
    return width > 0 && height > 0 ? [NSString stringWithFormat:@"%dx%d", width, height] : @"unknown";
}

static BOOL OPNMetalDeviceIsAppleM1Class(id<MTLDevice> device) {
    NSString *deviceName = device.name.lowercaseString ?: @"";
    return [deviceName hasPrefix:@"apple m1"];
}

static OPNVideoEnhancementTier OPNAutomaticEnhancementTier(OPNVideoEnhancementRenderer *renderer, id<MTLDevice> device) {
    if (OPNMetalDeviceIsAppleM1Class(device)) {
        return [renderer isMetalFXAvailable] ? OPNVideoEnhancementTierMetalFX : OPNVideoEnhancementTierSpatial;
    }
    if ([renderer isTemporalAvailable]) return OPNVideoEnhancementTierTemporal;
    return [renderer isMetalFXAvailable] ? OPNVideoEnhancementTierMetalFX : OPNVideoEnhancementTierSpatial;
}

static OPN::LibWebRTCStreamSession *OPNMetalVideoViewOwner(OPNMetalVideoView *view) {
    return view.owner ? static_cast<OPN::LibWebRTCStreamSession *>(view.owner) : nullptr;
}

@implementation OPNMetalVideoView

- (instancetype)initWithFrame:(NSRect)frame targetFps:(int)targetFps owner:(void *)owner {
    self = [super initWithFrame:frame];
    if (self) {
        _owner = owner;
        _targetFps = MAX(30, MIN(targetFps, 240));
        _sourceFrameSize = CGSizeZero;
        _frameSerial = 0;
        _lastDrawnFrameSerial = 0;
        _enhancementDroppedFrameCount = 0;
        _lastEnhancementFrameTimeMs = -1.0;
        _lastDiagnosticsUpdateTime = 0.0;
        _drawScheduled = NO;
        _drawableSizeDirty = YES;
        _enhancementOverBudgetCount = 0;
        _adaptiveEnhancementPenalty = 0;
        self.wantsLayer = YES;
        self.layer.backgroundColor = NSColor.blackColor.CGColor;

        _metalView = [[MTKView alloc] initWithFrame:self.bounds device:MTLCreateSystemDefaultDevice()];
        _metalView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        _metalView.framebufferOnly = NO;
        _metalView.autoResizeDrawable = NO;
        _metalView.paused = NO;
        _metalView.enableSetNeedsDisplay = NO;
        _metalView.preferredFramesPerSecond = _targetFps;
        _metalView.delegate = self;
        _metalView.layerContentsPlacement = NSViewLayerContentsPlacementScaleProportionallyToFit;
        if ([_metalView.layer isKindOfClass:CAMetalLayer.class]) {
            CAMetalLayer *metalLayer = (CAMetalLayer *)_metalView.layer;
            metalLayer.presentsWithTransaction = NO;
            metalLayer.allowsNextDrawableTimeout = NO;
            if (@available(macOS 10.13, *)) {
                OPN::LibWebRTCStreamSession *typedOwner = owner ? static_cast<OPN::LibWebRTCStreamSession *>(owner) : nullptr;
                metalLayer.maximumDrawableCount = typedOwner && typedOwner->LowLatencyMode() ? 2 : 3;
            }
        }
        [self addSubview:_metalView];
        if (_metalView.device) {
            _commandQueue = [_metalView.device newCommandQueue];
            _enhancementRenderer = [[OPNVideoEnhancementRenderer alloc] initWithDevice:_metalView.device commandQueue:_commandQueue];
            _enhancementSettings = [[OPNVideoEnhancementSettings alloc] init];
            _enhancementResult = [[OPNVideoEnhancementResult alloc] init];
        }
    }
    return self;
}

- (void)layout {
    [super layout];
    self.metalView.frame = self.bounds;
    self.drawableSizeDirty = YES;
    [self updateDrawableSizeForCurrentBackingScale];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    self.drawableSizeDirty = YES;
    [self updateDrawableSizeForCurrentBackingScale];
}

- (void)setSize:(CGSize)size {
    if (size.width <= 0.0 || size.height <= 0.0) return;
    @synchronized (self) {
        self.sourceFrameSize = size;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        self.drawableSizeDirty = YES;
        [self updateDrawableSizeForCurrentBackingScale];
    });
}

- (void)updateDrawableSizeForCurrentBackingScale {
    if (!self.metalView) return;
    CGFloat scale = self.window.backingScaleFactor;
    if (scale <= 0.0) scale = self.metalView.window.backingScaleFactor;
    if (scale <= 0.0) scale = NSScreen.mainScreen.backingScaleFactor;
    if (scale <= 0.0) scale = 1.0;

    CGSize boundsSize = self.metalView.bounds.size;
    if (boundsSize.width <= 0.0 || boundsSize.height <= 0.0) return;

    CGSize drawableSize = CGSizeMake(std::max<CGFloat>(1.0, floor(boundsSize.width * scale)),
                                     std::max<CGFloat>(1.0, floor(boundsSize.height * scale)));
    int enhancementMode = 0;
    int enhancementSharpness = 0;
    int enhancementDenoise = 0;
    int enhancementTargetHeight = 2160;
    OPN::LibWebRTCStreamSession *owner = OPNMetalVideoViewOwner(self);
    if (owner) owner->LocalVideoEnhancement(enhancementMode, enhancementSharpness, enhancementDenoise, enhancementTargetHeight);
    if (enhancementMode > 0) {
        drawableSize = [self enhancementDrawableSizeForBoundsSize:boundsSize scale:scale];
    }
    CGSize currentSize = self.metalView.drawableSize;
    if ((int)std::llround(currentSize.width) != (int)std::llround(drawableSize.width) ||
        (int)std::llround(currentSize.height) != (int)std::llround(drawableSize.height)) {
        self.metalView.drawableSize = drawableSize;
    }
    self.drawableSizeDirty = NO;
}

- (CGSize)enhancementDrawableSizeForBoundsSize:(CGSize)boundsSize scale:(CGFloat)scale {
    CGSize backingSize = CGSizeMake(std::max<CGFloat>(1.0, floor(boundsSize.width * scale)),
                                    std::max<CGFloat>(1.0, floor(boundsSize.height * scale)));
    CGFloat aspect = boundsSize.height > 0.0 ? boundsSize.width / boundsSize.height : 16.0 / 9.0;
    if (aspect <= 0.1 || !std::isfinite((double)aspect)) aspect = 16.0 / 9.0;
    int enhancementMode = 0;
    int enhancementSharpness = 0;
    int enhancementDenoise = 0;
    int enhancementTargetHeight = 2160;
    OPN::LibWebRTCStreamSession *owner = OPNMetalVideoViewOwner(self);
    if (owner) owner->LocalVideoEnhancement(enhancementMode, enhancementSharpness, enhancementDenoise, enhancementTargetHeight);
    CGFloat targetHeightPixels = (CGFloat)std::max(1440, std::min(enhancementTargetHeight, 2160));
    if (enhancementMode == 1 && OPNMetalDeviceIsAppleM1Class(self.metalView.device)) {
        targetHeightPixels = std::min<CGFloat>(targetHeightPixels, 1440.0);
    }
    CGFloat targetWidth = targetHeightPixels * aspect;
    CGFloat targetHeight = targetWidth / aspect;
    return CGSizeMake(std::max<CGFloat>(backingSize.width, floor(targetWidth)),
                      std::max<CGFloat>(backingSize.height, floor(targetHeight)));
}

- (void)renderFrame:(RTCVideoFrame *)frame {
    OPN::LibWebRTCStreamSession *owner = OPNMetalVideoViewOwner(self);
    if (frame && owner) {
        owner->HandleVideoFrame((__bridge void *)frame);
    }
    if (!frame) return;
    @synchronized (self) {
        self.videoFrame = frame;
        self.frameSerial++;
    }
}

- (void)scheduleDraw {
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            @synchronized (self) {
                self.drawScheduled = NO;
            }
            if (self.metalView) {
                [self.metalView draw];
            }
        }
    });
}

- (void)drawInMTKView:(MTKView *)view {
    if (view != self.metalView) return;
    if (self.drawableSizeDirty) [self updateDrawableSizeForCurrentBackingScale];

    RTCVideoFrame *frame = nil;
    uint64_t drawSerial = 0;
    CGSize sourceSize = CGSizeZero;
    @synchronized (self) {
        frame = self.videoFrame;
        drawSerial = self.frameSerial;
        sourceSize = self.sourceFrameSize;
    }
    if (!frame || frame.width <= 0 || frame.height <= 0 || drawSerial == 0 || drawSerial == self.lastDrawnFrameSerial) return;
    if (sourceSize.width <= 0.0 || sourceSize.height <= 0.0) sourceSize = CGSizeMake(frame.width, frame.height);

    NSString *pixelFormat = @"unknown";
    NSString *renderMode = @"I420";
    NSString *frameSource = @"unknown";
    NSString *renderPath = @"RTCMTLI420Renderer";
    NSString *fallback = @"";
    NSString *enhancementConfiguredTier = @"Off";
    NSString *enhancementActiveTier = @"Native";
    NSString *enhancementFallbackReason = @"";
    NSString *enhancementSourceResolution = OPNVideoResolutionString(sourceSize);
    NSString *enhancementDrawableResolution = OPNVideoResolutionString(self.metalView.drawableSize);
    NSString *enhancementDiagnostics = @"";
    double enhancementFrameTimeMs = -1.0;
    int enhancementMode = 0;
    int enhancementSharpness = 0;
    int enhancementDenoise = 0;
    int enhancementTargetHeight = 2160;
    OPN::LibWebRTCStreamSession *owner = OPNMetalVideoViewOwner(self);
    if (owner) owner->LocalVideoEnhancement(enhancementMode, enhancementSharpness, enhancementDenoise, enhancementTargetHeight);
    if (self.adaptiveEnhancementPenalty > 0) {
        if (enhancementMode == 4) enhancementMode = [self.enhancementRenderer isMetalFXAvailable] ? 3 : 2;
        else if (enhancementMode == 3 && ![self.enhancementRenderer isMetalFXAvailable]) enhancementMode = 2;
        else if (enhancementMode == 2 && self.adaptiveEnhancementPenalty > 1) enhancementMode = 0;
    }
    if (self.drawableSizeDirty) [self updateDrawableSizeForCurrentBackingScale];
    if (enhancementMode > 0) {
        OPNVideoEnhancementSettings *settings = self.enhancementSettings ?: [[OPNVideoEnhancementSettings alloc] init];
        if (enhancementMode == 4) {
            settings.configuredTier = OPNVideoEnhancementTierTemporal;
        } else if (enhancementMode == 3) {
            settings.configuredTier = OPNVideoEnhancementTierMetalFX;
        } else if (enhancementMode == 2) {
            settings.configuredTier = OPNVideoEnhancementTierSpatial;
        } else {
            settings.configuredTier = OPNAutomaticEnhancementTier(self.enhancementRenderer, self.metalView.device);
        }
        settings.sharpness = enhancementSharpness;
        settings.denoise = enhancementDenoise;
        settings.sourceSize = sourceSize;
        settings.drawableSize = self.metalView.drawableSize;
        settings.targetFrameTimeMs = 1000.0 / (double)std::max(1, self.targetFps);
        settings.captureEnhancedPixelBuffer = owner ? owner->WantsEnhancedVideoFrames() : NO;
        settings.lowCostSpatial = self.adaptiveEnhancementPenalty > 0;
        CFTimeInterval diagnosticsNow = CACurrentMediaTime();
        settings.emitDiagnostics = self.lastDiagnosticsUpdateTime <= 0.0 || diagnosticsNow - self.lastDiagnosticsUpdateTime >= 1.0;
        OPNVideoEnhancementResult *result = self.enhancementResult ?: [[OPNVideoEnhancementResult alloc] init];
        if ([self.enhancementRenderer renderFrame:frame toView:self.metalView settings:settings result:result]) {
            pixelFormat = result.pixelFormat ?: @"unknown";
            renderMode = result.renderMode ?: @"Upscaler";
            frameSource = result.frameSource ?: @"processed frame";
            renderPath = result.renderPath ?: @"OPNVideoEnhancementRenderer";
            fallback = result.fallbackReason ?: @"";
            enhancementConfiguredTier = result.configuredTier ?: @"Upscaler";
            enhancementActiveTier = result.activeTier ?: @"Enhanced";
            enhancementFallbackReason = result.tierFallbackReason ?: @"";
            enhancementSourceResolution = result.sourceResolution ?: enhancementSourceResolution;
            enhancementDrawableResolution = result.drawableResolution ?: enhancementDrawableResolution;
            enhancementDiagnostics = result.diagnostics ?: @"";
            enhancementFrameTimeMs = result.frameTimeMs;
            self.enhancementDroppedFrameCount = result.droppedFrames;
            self.lastDrawnFrameSerial = drawSerial;
            if (enhancementFrameTimeMs > settings.targetFrameTimeMs * 1.15) {
                self.enhancementOverBudgetCount++;
                if (self.enhancementOverBudgetCount >= 10) {
                    self.adaptiveEnhancementPenalty = MIN((NSInteger)2, self.adaptiveEnhancementPenalty + 1);
                    self.enhancementOverBudgetCount = 0;
                }
            } else if (enhancementFrameTimeMs > 0.0 && enhancementFrameTimeMs < settings.targetFrameTimeMs * 0.72) {
                self.enhancementOverBudgetCount = 0;
                if (self.adaptiveEnhancementPenalty > 0) self.adaptiveEnhancementPenalty--;
            }
            if (result.enhancedPixelBuffer && owner) {
                owner->HandleEnhancedVideoFrame(result.enhancedPixelBuffer);
                CVPixelBufferRelease(result.enhancedPixelBuffer);
                result.enhancedPixelBuffer = nil;
            }
        } else {
            fallback = result.fallbackReason.length > 0 ? result.fallbackReason : @"processed renderer unavailable; using WebRTC renderer";
            enhancementConfiguredTier = result.configuredTier ?: @"Upscaler";
            enhancementActiveTier = @"Native fallback";
            enhancementFallbackReason = result.tierFallbackReason.length > 0 ? result.tierFallbackReason : fallback;
            enhancementSourceResolution = result.sourceResolution ?: enhancementSourceResolution;
            enhancementDrawableResolution = result.drawableResolution ?: enhancementDrawableResolution;
            enhancementDiagnostics = result.diagnostics ?: @"";
            self.enhancementDroppedFrameCount = result.droppedFrames;
        }
        if (self.lastDrawnFrameSerial != drawSerial) {
            enhancementActiveTier = @"Native fallback";
            enhancementFallbackReason = fallback.length > 0 ? fallback : @"processed renderer failed";
        }
    }
    if (self.lastDrawnFrameSerial == drawSerial) {
        self.lastEnhancementFrameTimeMs = enhancementFrameTimeMs;
        CFTimeInterval now = CACurrentMediaTime();
        if (owner && (self.lastDiagnosticsUpdateTime <= 0.0 || now - self.lastDiagnosticsUpdateTime >= 1.0 || fallback.length > 0)) {
            self.lastDiagnosticsUpdateTime = now;
            owner->SetVideoRenderDiagnostics(OPN::OPNNSStringToString(pixelFormat),
                                             OPN::OPNNSStringToString(renderMode),
                                             OPN::OPNNSStringToString(frameSource),
                                             OPN::OPNNSStringToString(renderPath),
                                             OPN::OPNNSStringToString(fallback),
                                             OPN::OPNNSStringToString(enhancementConfiguredTier),
                                             OPN::OPNNSStringToString(enhancementActiveTier),
                                             OPN::OPNNSStringToString(enhancementFallbackReason),
                                             OPN::OPNNSStringToString(enhancementSourceResolution),
                                             OPN::OPNNSStringToString(enhancementDrawableResolution),
                                             OPN::OPNNSStringToString(enhancementDiagnostics),
                                             enhancementFrameTimeMs,
                                             self.enhancementDroppedFrameCount);
        }
        return;
    }
    id<OPNRTCMetalRenderer> renderer = [self rendererForFrame:frame
                                                   pixelFormat:&pixelFormat
                                                   renderMode:&renderMode
                                                  frameSource:&frameSource
                                                   renderPath:&renderPath
                                                     fallback:&fallback];
    if (!renderer) {
        fallback = @"renderer unavailable";
    } else {
        [renderer drawFrame:frame];
        self.lastDrawnFrameSerial = drawSerial;
    }
    self.lastEnhancementFrameTimeMs = enhancementFrameTimeMs;
    CFTimeInterval now = CACurrentMediaTime();
    if (owner && (self.lastDiagnosticsUpdateTime <= 0.0 || now - self.lastDiagnosticsUpdateTime >= 1.0 || fallback.length > 0)) {
        self.lastDiagnosticsUpdateTime = now;
        owner->SetVideoRenderDiagnostics(OPN::OPNNSStringToString(pixelFormat),
                                         OPN::OPNNSStringToString(renderMode),
                                         OPN::OPNNSStringToString(frameSource),
                                         OPN::OPNNSStringToString(renderPath),
                                         OPN::OPNNSStringToString(fallback),
                                         OPN::OPNNSStringToString(enhancementConfiguredTier),
                                         OPN::OPNNSStringToString(enhancementActiveTier),
                                         OPN::OPNNSStringToString(enhancementFallbackReason),
                                         OPN::OPNNSStringToString(enhancementSourceResolution),
                                         OPN::OPNNSStringToString(enhancementDrawableResolution),
                                         OPN::OPNNSStringToString(enhancementDiagnostics),
                                         enhancementFrameTimeMs,
                                         self.enhancementDroppedFrameCount);
    }
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    (void)view;
    (void)size;
}

- (id<OPNRTCMetalRenderer>)newRendererNamed:(NSString *)className fallback:(NSString **)fallback {
    Class rendererClass = NSClassFromString(className);
    if (!rendererClass) {
        if (fallback) *fallback = [NSString stringWithFormat:@"%@ unavailable", className];
        return nil;
    }
    id<OPNRTCMetalRenderer> renderer = (id<OPNRTCMetalRenderer>)[[rendererClass alloc] init];
    if (![renderer addRenderingDestination:self.metalView]) {
        if (fallback) *fallback = [NSString stringWithFormat:@"%@ rejected MTKView", className];
        return nil;
    }
    self.metalView.paused = NO;
    self.metalView.enableSetNeedsDisplay = NO;
    self.metalView.preferredFramesPerSecond = self.targetFps;
    return renderer;
}

- (id<OPNRTCMetalRenderer>)i420RendererWithFallback:(NSString **)fallback {
    if (!self.rendererI420) {
        self.rendererI420 = [self newRendererNamed:@"RTCMTLI420Renderer" fallback:fallback];
    }
    return self.rendererI420;
}

- (id<OPNRTCMetalRenderer>)rendererForFrame:(RTCVideoFrame *)frame
                                pixelFormat:(NSString **)pixelFormat
                                 renderMode:(NSString **)renderMode
                                frameSource:(NSString **)frameSource
                                 renderPath:(NSString **)renderPath
                                   fallback:(NSString **)fallback {
    if ([frame.buffer isKindOfClass:RTCCVPixelBuffer.class]) {
        if (frameSource) *frameSource = @"CVPixelBuffer";
        RTCCVPixelBuffer *buffer = (RTCCVPixelBuffer *)frame.buffer;
        OSType format = CVPixelBufferGetPixelFormatType(buffer.pixelBuffer);
        BOOL isNV12 = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
        BOOL isRGB = format == kCVPixelFormatType_32BGRA || format == kCVPixelFormatType_32ARGB;
        if (pixelFormat) {
            if (format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) *pixelFormat = @"420v/NV12";
            else if (format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) *pixelFormat = @"420f/NV12";
            else if (format == kCVPixelFormatType_32BGRA) *pixelFormat = @"BGRA";
            else if (format == kCVPixelFormatType_32ARGB) *pixelFormat = @"ARGB";
            else *pixelFormat = [NSString stringWithFormat:@"0x%08x", (unsigned int)format];
        }
        if (isNV12) {
            NSString *localFallback = @"";
            if (!self.rendererNV12) self.rendererNV12 = [self newRendererNamed:@"RTCMTLNV12Renderer" fallback:&localFallback];
            if (self.rendererNV12) {
                if (renderMode) *renderMode = @"NV12";
                if (renderPath) *renderPath = @"RTCMTLNV12Renderer";
                return self.rendererNV12;
            }
            if (fallback) *fallback = localFallback.length > 0 ? localFallback : @"NV12 unavailable; using I420";
        } else if (isRGB) {
            NSString *localFallback = @"";
            if (!self.rendererRGB) self.rendererRGB = [self newRendererNamed:@"RTCMTLRGBRenderer" fallback:&localFallback];
            if (self.rendererRGB) {
                if (renderMode) *renderMode = @"RGB";
                if (renderPath) *renderPath = @"RTCMTLRGBRenderer";
                return self.rendererRGB;
            }
            if (fallback) *fallback = localFallback.length > 0 ? localFallback : @"RGB unavailable; using I420";
        } else if (fallback) {
            *fallback = @"unsupported CVPixelBuffer; using I420";
        }
    } else {
        if (frameSource) *frameSource = NSStringFromClass([frame.buffer class]) ?: @"unknown";
        if (pixelFormat) *pixelFormat = @"I420";
    }
    if (renderMode) *renderMode = @"I420";
    if (renderPath) *renderPath = @"RTCMTLI420Renderer";
    return [self i420RendererWithFallback:fallback];
}

@end

#endif
