import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Metal
import MetalKit
import QuartzCore
import WebRTC
#if canImport(MetalFX)
import MetalFX
#endif

@objc enum OPNVideoEnhancementTier: Int {
    case off = 0
    case spatial = 1
    case metalFX = 2
    case temporal = 3
}

@objc(OPNVideoEnhancementSettings)
final class OPNVideoEnhancementSettings: NSObject {
    @objc var configuredTier: OPNVideoEnhancementTier = .off
    @objc var sharpness: Int = 0
    @objc var denoise: Int = 0
    @objc var sourceSize: CGSize = .zero
    @objc var drawableSize: CGSize = .zero
    @objc var targetFrameTimeMs: Double = 0
    @objc var captureEnhancedPixelBuffer = false
    @objc var lowCostSpatial = false
    @objc var emitDiagnostics = false
}

@objc(OPNVideoEnhancementResult)
final class OPNVideoEnhancementResult: NSObject {
    @objc var pixelFormat = ""
    @objc var renderMode = ""
    @objc var frameSource = ""
    @objc var renderPath = ""
    @objc var fallbackReason = ""
    @objc var configuredTier = ""
    @objc var activeTier = ""
    @objc var tierFallbackReason = ""
    @objc var sourceResolution = ""
    @objc var drawableResolution = ""
    @objc var diagnostics = ""
    @objc var frameTimeMs = 0.0
    @objc var droppedFrames: UInt64 = 0
    @objc var enhancedPixelBuffer: CVPixelBuffer?
}

@objc(OPNVideoTextureFrame)
final class OPNVideoTextureFrame: NSObject {
    @objc var kind = 0
    @objc var rgbTexture: (any MTLTexture)?
    @objc var lumaTexture: (any MTLTexture)?
    @objc var chromaTexture: (any MTLTexture)?
    @objc var chromaUTexture: (any MTLTexture)?
    @objc var chromaVTexture: (any MTLTexture)?
    @objc var cropRect: CGRect = .zero
    @objc var contentWidth: UInt = 0
    @objc var contentHeight: UInt = 0
}

@objc(OPNVideoTextureSource)
final class OPNVideoTextureSource: NSObject {
    private let device: (any MTLDevice)?
    private var textureCache: CVMetalTextureCache?
    private var i420LumaTexture: (any MTLTexture)?
    private var i420ChromaUTexture: (any MTLTexture)?
    private var i420ChromaVTexture: (any MTLTexture)?

    @objc init(device: (any MTLDevice)?) {
        self.device = device
        super.init()
        if let device {
            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
            textureCache = cache
        }
    }

    deinit {
        if let textureCache {
            CVMetalTextureCacheFlush(textureCache, 0)
        }
    }

    @objc(newTextureFrameForFrame:pixelFormat:frameSource:fallback:)
    func newTextureFrame(
        for frame: RTCVideoFrame?,
        pixelFormat: AutoreleasingUnsafeMutablePointer<NSString?>?,
        frameSource: AutoreleasingUnsafeMutablePointer<NSString?>?,
        fallback: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Any? {
        guard let frame, let textureCache else {
            fallback?.pointee = "texture source unavailable"
            return nil
        }

        let buffer = frame.buffer
        guard let cvBuffer = buffer as? RTCCVPixelBuffer else {
            let i420Frame = frame.newI420()
            guard let i420 = i420Frame.buffer as? RTCI420Buffer, i420.width > 0, i420.height > 0 else {
                frameSource?.pointee = Self.frameBufferClassName(buffer)
                pixelFormat?.pointee = "I420"
                fallback?.pointee = "I420 frame unavailable"
                return nil
            }

            let textureFrame = OPNVideoTextureFrame()
            textureFrame.kind = 2
            textureFrame.cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            textureFrame.contentWidth = UInt(i420.width)
            textureFrame.contentHeight = UInt(i420.height)
            textureFrame.lumaTexture = reusablePlaneTexture(&i420LumaTexture, width: Int(i420.width), height: Int(i420.height), bytes: i420.dataY, bytesPerRow: Int(i420.strideY), label: "OpenNOW I420 Y")
            textureFrame.chromaUTexture = reusablePlaneTexture(&i420ChromaUTexture, width: Int(i420.chromaWidth), height: Int(i420.chromaHeight), bytes: i420.dataU, bytesPerRow: Int(i420.strideU), label: "OpenNOW I420 U")
            textureFrame.chromaVTexture = reusablePlaneTexture(&i420ChromaVTexture, width: Int(i420.chromaWidth), height: Int(i420.chromaHeight), bytes: i420.dataV, bytesPerRow: Int(i420.strideV), label: "OpenNOW I420 V")
            guard textureFrame.lumaTexture != nil, textureFrame.chromaUTexture != nil, textureFrame.chromaVTexture != nil else {
                frameSource?.pointee = Self.frameBufferClassName(buffer)
                pixelFormat?.pointee = "I420"
                fallback?.pointee = "I420 GPU plane upload failed"
                return nil
            }
            frameSource?.pointee = Self.frameBufferClassName(buffer)
            pixelFormat?.pointee = "I420"
            return textureFrame
        }

        let pixelBuffer = cvBuffer.pixelBuffer
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        pixelFormat?.pointee = Self.pixelFormatName(format) as NSString
        frameSource?.pointee = "CVPixelBuffer"
        let isBGRA = format == kCVPixelFormatType_32BGRA
        let isNV12 = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        guard isBGRA || isNV12 else {
            fallback?.pointee = "unsupported GPU ingestion format; using Core Image compatibility path"
            return nil
        }

        let width = isNV12 ? CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) : CVPixelBufferGetWidth(pixelBuffer)
        let height = isNV12 ? CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) : CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else {
            fallback?.pointee = "empty CVPixelBuffer dimensions"
            return nil
        }

        let textureFrame = OPNVideoTextureFrame()
        textureFrame.kind = isNV12 ? 1 : 0
        var contentWidth = width
        var contentHeight = height
        var cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        if cvBuffer.requiresCropping(), cvBuffer.cropWidth > 0, cvBuffer.cropHeight > 0 {
            let cropX = max(CGFloat(0), CGFloat(cvBuffer.cropX))
            let cropY = max(CGFloat(0), CGFloat(cvBuffer.cropY))
            let cropWidth = min(CGFloat(cvBuffer.cropWidth), CGFloat(width) - cropX)
            let cropHeight = min(CGFloat(cvBuffer.cropHeight), CGFloat(height) - cropY)
            if cropWidth > 0, cropHeight > 0 {
                cropRect = CGRect(x: cropX / CGFloat(width), y: cropY / CGFloat(height), width: cropWidth / CGFloat(width), height: cropHeight / CGFloat(height))
                contentWidth = Int(cropWidth.rounded())
                contentHeight = Int(cropHeight.rounded())
            }
        }
        textureFrame.cropRect = cropRect
        textureFrame.contentWidth = UInt(max(1, contentWidth))
        textureFrame.contentHeight = UInt(max(1, contentHeight))

        var metalTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            isNV12 ? .r8Unorm : .bgra8Unorm,
            width,
            height,
            0,
            &metalTexture
        )
        guard status == kCVReturnSuccess, let metalTexture, let texture = CVMetalTextureGetTexture(metalTexture) else {
            fallback?.pointee = "CVMetalTextureCache could not create BGRA texture"
            return nil
        }
        if !isNV12 {
            textureFrame.rgbTexture = texture
            return textureFrame
        }

        let chromaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        var chromaMetalTexture: CVMetalTexture?
        let chromaStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .rg8Unorm,
            chromaWidth,
            chromaHeight,
            1,
            &chromaMetalTexture
        )
        guard chromaStatus == kCVReturnSuccess, let chromaMetalTexture, let chromaTexture = CVMetalTextureGetTexture(chromaMetalTexture) else {
            fallback?.pointee = "CVMetalTextureCache could not create NV12 chroma texture"
            return nil
        }
        textureFrame.lumaTexture = texture
        textureFrame.chromaTexture = chromaTexture
        return textureFrame
    }

    private func reusablePlaneTexture(
        _ texture: inout (any MTLTexture)?,
        width: Int,
        height: Int,
        bytes: UnsafePointer<UInt8>?,
        bytesPerRow: Int,
        label: String
    ) -> (any MTLTexture)? {
        guard let device, let bytes, width > 0, height > 0, bytesPerRow > 0 else { return nil }
        if texture == nil || texture?.width != width || texture?.height != height || texture?.pixelFormat != .r8Unorm {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            texture = device.makeTexture(descriptor: descriptor)
            texture?.label = label
        }
        guard let existing = texture else { return nil }
        existing.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: bytesPerRow)
        return existing
    }

    private static func pixelFormatName(_ format: OSType) -> String {
        if format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange { return "420v/NV12" }
        if format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange { return "420f/NV12" }
        if format == kCVPixelFormatType_32BGRA { return "BGRA" }
        if format == kCVPixelFormatType_32ARGB { return "ARGB" }
        return String(format: "0x%08x", format)
    }

    private static func frameBufferClassName(_ buffer: any RTCVideoFrameBuffer) -> NSString {
        NSStringFromClass(type(of: buffer) as AnyClass) as NSString
    }

    fileprivate static let spatialShaderSource = """
#include <metal_stdlib>
using namespace metal;
struct VertexOut { float4 position [[position]]; float2 texCoord; };
vertex VertexOut opn_video_vertex(uint vid [[vertex_id]]) {
    const float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    const float2 texCoords[3] = { float2(0.0, 1.0), float2(2.0, 1.0), float2(0.0, -1.0) };
    VertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.texCoord = texCoords[vid];
    return out;
}
static float2 opn_crop_uv(float2 texCoord, float4 crop) {
    return mix(crop.xy, crop.zw, clamp(texCoord, float2(0.0), float2(1.0)));
}
static float2 opn_clamp_crop(float2 uv, float4 crop) {
    return clamp(uv, crop.xy, crop.zw);
}
static float3 opn_nv12_rgb(texture2d<float> yTexture, texture2d<float> uvTexture, sampler s, float2 uv) {
    float y = yTexture.sample(s, uv).r;
    float2 cbcr = uvTexture.sample(s, uv).rg - float2(0.5, 0.5);
    return saturate(float3(y + 1.5748 * cbcr.y, y - 0.1873 * cbcr.x - 0.4681 * cbcr.y, y + 1.8556 * cbcr.x));
}
static float3 opn_i420_rgb(texture2d<float> yTexture, texture2d<float> uTexture, texture2d<float> vTexture, sampler s, float2 uv) {
    float y = yTexture.sample(s, uv).r;
    float cb = uTexture.sample(s, uv).r - 0.5;
    float cr = vTexture.sample(s, uv).r - 0.5;
    return saturate(float3(y + 1.5748 * cr, y - 0.1873 * cb - 0.4681 * cr, y + 1.8556 * cb));
}
static float3 opn_finish(float3 center, float3 blur, float sharpness, float denoise) {
    float3 denoised = mix(center, blur, clamp(denoise, 0.0, 1.0));
    return clamp(denoised + (denoised - blur) * sharpness, float3(0.0), float3(1.0));
}
static float opn_luma(float3 color) {
    return dot(color, float3(0.2126, 0.7152, 0.0722));
}
static float opn_block_luma(texture2d<float> sourceTexture, sampler s, float2 uv, float2 texel) {
    float center = opn_luma(sourceTexture.sample(s, clamp(uv, float2(0.0), float2(1.0))).rgb);
    float horizontal = opn_luma(sourceTexture.sample(s, clamp(uv + float2(texel.x, 0.0), float2(0.0), float2(1.0))).rgb) + opn_luma(sourceTexture.sample(s, clamp(uv - float2(texel.x, 0.0), float2(0.0), float2(1.0))).rgb);
    float vertical = opn_luma(sourceTexture.sample(s, clamp(uv + float2(0.0, texel.y), float2(0.0), float2(1.0))).rgb) + opn_luma(sourceTexture.sample(s, clamp(uv - float2(0.0, texel.y), float2(0.0), float2(1.0))).rgb);
    return (center * 2.0 + horizontal + vertical) / 6.0;
}
static float3 opn_rgb_spatial(texture2d<float> sourceTexture, sampler s, float2 uv, float2 texel, float4 crop, float sharpness, float denoise) {
    float3 center = sourceTexture.sample(s, uv).rgb;
    float3 blur = (sourceTexture.sample(s, opn_clamp_crop(uv + float2(texel.x, 0.0), crop)).rgb + sourceTexture.sample(s, opn_clamp_crop(uv - float2(texel.x, 0.0), crop)).rgb + sourceTexture.sample(s, opn_clamp_crop(uv + float2(0.0, texel.y), crop)).rgb + sourceTexture.sample(s, opn_clamp_crop(uv - float2(0.0, texel.y), crop)).rgb) * 0.25;
    return opn_finish(center, blur, sharpness, denoise);
}
fragment float4 opn_video_spatial_rgb(VertexOut in [[stage_in]], texture2d<float> sourceTexture [[texture(0)]], constant float2 &scale [[buffer(0)]], constant float &sharpness [[buffer(1)]], constant float &denoise [[buffer(2)]], constant float4 &crop [[buffer(3)]], constant float2 &jitter [[buffer(4)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 uv = opn_clamp_crop(opn_crop_uv(in.texCoord, crop) + jitter, crop);
    float2 texel = max(scale, float2(1.0 / 8192.0));
    return float4(opn_rgb_spatial(sourceTexture, s, uv, texel, crop, sharpness, denoise), 1.0);
}
fragment float4 opn_video_spatial_nv12(VertexOut in [[stage_in]], texture2d<float> yTexture [[texture(0)]], texture2d<float> uvTexture [[texture(1)]], constant float2 &scale [[buffer(0)]], constant float &sharpness [[buffer(1)]], constant float &denoise [[buffer(2)]], constant float4 &crop [[buffer(3)]], constant float2 &jitter [[buffer(4)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 uv = opn_clamp_crop(opn_crop_uv(in.texCoord, crop) + jitter, crop);
    float2 texel = max(scale, float2(1.0 / 8192.0));
    float3 center = opn_nv12_rgb(yTexture, uvTexture, s, uv);
    float3 blur = (opn_nv12_rgb(yTexture, uvTexture, s, opn_clamp_crop(uv + float2(texel.x, 0.0), crop)) + opn_nv12_rgb(yTexture, uvTexture, s, opn_clamp_crop(uv - float2(texel.x, 0.0), crop)) + opn_nv12_rgb(yTexture, uvTexture, s, opn_clamp_crop(uv + float2(0.0, texel.y), crop)) + opn_nv12_rgb(yTexture, uvTexture, s, opn_clamp_crop(uv - float2(0.0, texel.y), crop))) * 0.25;
    return float4(opn_finish(center, blur, sharpness, denoise), 1.0);
}
fragment float4 opn_video_spatial_i420(VertexOut in [[stage_in]], texture2d<float> yTexture [[texture(0)]], texture2d<float> uTexture [[texture(1)]], texture2d<float> vTexture [[texture(2)]], constant float2 &scale [[buffer(0)]], constant float &sharpness [[buffer(1)]], constant float &denoise [[buffer(2)]], constant float4 &crop [[buffer(3)]], constant float2 &jitter [[buffer(4)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 uv = opn_clamp_crop(opn_crop_uv(in.texCoord, crop) + jitter, crop);
    float2 texel = max(scale, float2(1.0 / 8192.0));
    float3 center = opn_i420_rgb(yTexture, uTexture, vTexture, s, uv);
    float3 blur = (opn_i420_rgb(yTexture, uTexture, vTexture, s, opn_clamp_crop(uv + float2(texel.x, 0.0), crop)) + opn_i420_rgb(yTexture, uTexture, vTexture, s, opn_clamp_crop(uv - float2(texel.x, 0.0), crop)) + opn_i420_rgb(yTexture, uTexture, vTexture, s, opn_clamp_crop(uv + float2(0.0, texel.y), crop)) + opn_i420_rgb(yTexture, uTexture, vTexture, s, opn_clamp_crop(uv - float2(0.0, texel.y), crop))) * 0.25;
    return float4(opn_finish(center, blur, sharpness, denoise), 1.0);
}
fragment float4 opn_video_fast_rgb(VertexOut in [[stage_in]], texture2d<float> sourceTexture [[texture(0)]], constant float2 &scale [[buffer(0)]], constant float &sharpness [[buffer(1)]], constant float &denoise [[buffer(2)]], constant float4 &crop [[buffer(3)]], constant float2 &jitter [[buffer(4)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    return float4(sourceTexture.sample(s, opn_crop_uv(in.texCoord, crop)).rgb, 1.0);
}
fragment float4 opn_video_fast_nv12(VertexOut in [[stage_in]], texture2d<float> yTexture [[texture(0)]], texture2d<float> uvTexture [[texture(1)]], constant float2 &scale [[buffer(0)]], constant float &sharpness [[buffer(1)]], constant float &denoise [[buffer(2)]], constant float4 &crop [[buffer(3)]], constant float2 &jitter [[buffer(4)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    return float4(opn_nv12_rgb(yTexture, uvTexture, s, opn_crop_uv(in.texCoord, crop)), 1.0);
}
fragment float4 opn_video_fast_i420(VertexOut in [[stage_in]], texture2d<float> yTexture [[texture(0)]], texture2d<float> uTexture [[texture(1)]], texture2d<float> vTexture [[texture(2)]], constant float2 &scale [[buffer(0)]], constant float &sharpness [[buffer(1)]], constant float &denoise [[buffer(2)]], constant float4 &crop [[buffer(3)]], constant float2 &jitter [[buffer(4)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    return float4(opn_i420_rgb(yTexture, uTexture, vTexture, s, opn_crop_uv(in.texCoord, crop)), 1.0);
}
fragment float4 opn_video_temporal_motion(VertexOut in [[stage_in]], texture2d<float> currentTexture [[texture(0)]], texture2d<float> historyTexture [[texture(1)]], constant float2 &texel [[buffer(0)]], constant int &hasHistory [[buffer(1)]], constant float2 &jitterDelta [[buffer(2)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 uv = clamp(in.texCoord, float2(0.0), float2(1.0));
    if (hasHistory == 0) return float4(0.0, 0.0, 0.0, 1.0);
    float2 blockTexel = texel * 2.0;
    float currentLuma = opn_block_luma(currentTexture, s, uv, blockTexel);
    float bestDiff = 1.0;
    float bestScore = 1.0;
    float2 bestOffset = float2(0.0);
    for (int y = -2; y <= 2; ++y) {
        for (int x = -2; x <= 2; ++x) {
            float2 offset = jitterDelta + float2((float)x, (float)y) * blockTexel;
            float diff = fabs(currentLuma - opn_block_luma(historyTexture, s, uv + offset, blockTexel));
            float score = diff + length(float2((float)x, (float)y)) * 0.003;
            if (score < bestScore) { bestScore = score; bestDiff = diff; bestOffset = offset; }
        }
    }
    float confidence = 1.0 - smoothstep(0.018, 0.135, bestDiff);
    return float4(bestOffset, confidence, bestDiff);
}
fragment float4 opn_video_temporal_composite(VertexOut in [[stage_in]], texture2d<float> currentTexture [[texture(0)]], texture2d<float> historyTexture [[texture(1)]], texture2d<float> motionTexture [[texture(2)]], constant float2 &texel [[buffer(0)]], constant float &historyWeight [[buffer(1)]], constant float &sharpness [[buffer(2)]], constant int &hasHistory [[buffer(3)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 uv = clamp(in.texCoord, float2(0.0), float2(1.0));
    float3 current = currentTexture.sample(s, uv).rgb;
    float2 uvL = clamp(uv - float2(texel.x, 0.0), float2(0.0), float2(1.0));
    float2 uvR = clamp(uv + float2(texel.x, 0.0), float2(0.0), float2(1.0));
    float2 uvU = clamp(uv + float2(0.0, texel.y), float2(0.0), float2(1.0));
    float2 uvD = clamp(uv - float2(0.0, texel.y), float2(0.0), float2(1.0));
    float3 left = currentTexture.sample(s, uvL).rgb;
    float3 right = currentTexture.sample(s, uvR).rgb;
    float3 up = currentTexture.sample(s, uvU).rgb;
    float3 down = currentTexture.sample(s, uvD).rgb;
    float3 blur = (left + right + up + down) * 0.25;
    float3 minColor = min(min(current, left), min(right, min(up, down)));
    float3 maxColor = max(max(current, left), max(right, max(up, down)));
    float3 history = current;
    float motionConfidence = 0.0;
    float historyDiff = 1.0;
    if (hasHistory != 0) {
        float4 motion = motionTexture.sample(s, uv);
        float2 rawHistoryUv = uv + motion.xy;
        float historyInside = step(0.0, rawHistoryUv.x) * step(rawHistoryUv.x, 1.0) * step(0.0, rawHistoryUv.y) * step(rawHistoryUv.y, 1.0);
        float2 historyUv = clamp(rawHistoryUv, float2(0.0), float2(1.0));
        history = clamp(historyTexture.sample(s, historyUv).rgb, minColor - float3(0.004), maxColor + float3(0.004));
        historyDiff = fabs(opn_luma(current) - opn_luma(history));
        float sceneContinuity = 1.0 - smoothstep(0.105, 0.255, motion.w);
        motionConfidence = clamp(motion.z, 0.0, 1.0) * historyInside * sceneContinuity;
    }
    float lumaStability = 1.0 - smoothstep(0.016, 0.125, historyDiff);
    float edgeStrength = smoothstep(0.014, 0.20, length(current - blur));
    float temporalMix = hasHistory != 0 ? clamp(historyWeight * motionConfidence * lumaStability * mix(1.0, 0.68, edgeStrength), 0.0, 0.86) : 0.0;
    float3 reconstructed = mix(current, history, temporalMix);
    reconstructed += (current - blur) * sharpness * edgeStrength * (1.0 - temporalMix * 0.52);
    return float4(clamp(reconstructed, float3(0.0), float3(1.0)), 1.0);
}
fragment float4 opn_video_present_rgb(VertexOut in [[stage_in]], texture2d<float> sourceTexture [[texture(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 uv = clamp(in.texCoord, float2(0.0), float2(1.0));
    float2 texel = max(1.0 / float2((float)sourceTexture.get_width(), (float)sourceTexture.get_height()), float2(1.0 / 8192.0));
    float3 center = sourceTexture.sample(s, uv).rgb;
    float3 left = sourceTexture.sample(s, clamp(uv - float2(texel.x, 0.0), float2(0.0), float2(1.0))).rgb;
    float3 right = sourceTexture.sample(s, clamp(uv + float2(texel.x, 0.0), float2(0.0), float2(1.0))).rgb;
    float3 up = sourceTexture.sample(s, clamp(uv + float2(0.0, texel.y), float2(0.0), float2(1.0))).rgb;
    float3 down = sourceTexture.sample(s, clamp(uv - float2(0.0, texel.y), float2(0.0), float2(1.0))).rgb;
    float centerLuma = opn_luma(center);
    float horizontalContrast = abs(opn_luma(left) - centerLuma) + abs(opn_luma(right) - centerLuma);
    float verticalContrast = abs(opn_luma(up) - centerLuma) + abs(opn_luma(down) - centerLuma);
    float edgeAmount = smoothstep(0.04, 0.22, max(horizontalContrast, verticalContrast));
    float3 tangent = horizontalContrast > verticalContrast ? (up + down) * 0.5 : (left + right) * 0.5;
    float3 resolved = mix(center, tangent, edgeAmount * 0.20);
    float3 minColor = min(min(center, left), min(right, min(up, down)));
    float3 maxColor = max(max(center, left), max(right, max(up, down)));
    return float4(clamp(resolved, minColor, maxColor), 1.0);
}
"""
}

@objc(OPNMetalFXUpscaler)
final class OPNMetalFXUpscaler: NSObject {
    private let device: (any MTLDevice)?
    private var spatialScaler: AnyObject?
    private var inputWidth = 0
    private var inputHeight = 0
    private var outputWidth = 0
    private var outputHeight = 0

    @objc init(device: (any MTLDevice)?) {
        self.device = device
        super.init()
    }

    @objc var isAvailable: Bool {
#if canImport(MetalFX)
        guard let device, NSClassFromString("MTLFXSpatialScalerDescriptor") != nil else { return false }
        if #available(macOS 13.0, *) {
            return MTLFXSpatialScalerDescriptor.supportsDevice(device)
        }
        return false
#else
        return false
#endif
    }

    @objc(encodeTexture:toTexture:commandBuffer:fallback:)
    func encodeTexture(
        _ sourceTexture: (any MTLTexture)?,
        toTexture destinationTexture: (any MTLTexture)?,
        commandBuffer: (any MTLCommandBuffer)?,
        fallback: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Bool {
#if canImport(MetalFX)
        guard isAvailable, let device, let sourceTexture, let destinationTexture, let commandBuffer else {
            fallback?.pointee = "MetalFX unavailable"
            return false
        }
        if #available(macOS 13.0, *) {
            let dimensionsChanged = spatialScaler == nil ||
                inputWidth != sourceTexture.width ||
                inputHeight != sourceTexture.height ||
                outputWidth != destinationTexture.width ||
                outputHeight != destinationTexture.height
            if dimensionsChanged {
                let descriptor = MTLFXSpatialScalerDescriptor()
                descriptor.colorTextureFormat = sourceTexture.pixelFormat
                descriptor.outputTextureFormat = destinationTexture.pixelFormat
                descriptor.inputWidth = sourceTexture.width
                descriptor.inputHeight = sourceTexture.height
                descriptor.outputWidth = destinationTexture.width
                descriptor.outputHeight = destinationTexture.height
                descriptor.colorProcessingMode = .perceptual
                spatialScaler = descriptor.makeSpatialScaler(device: device) as AnyObject?
                inputWidth = sourceTexture.width
                inputHeight = sourceTexture.height
                outputWidth = destinationTexture.width
                outputHeight = destinationTexture.height
            }
            guard let scaler = spatialScaler as? MTLFXSpatialScaler else {
                fallback?.pointee = "MetalFX scaler creation failed"
                return false
            }
            scaler.colorTexture = sourceTexture
            scaler.outputTexture = destinationTexture
            scaler.inputContentWidth = sourceTexture.width
            scaler.inputContentHeight = sourceTexture.height
            scaler.encode(commandBuffer: commandBuffer)
            return true
        }
        fallback?.pointee = "MetalFX requires macOS 13"
        return false
#else
        fallback?.pointee = "MetalFX headers unavailable"
        return false
#endif
    }
}

@objc(OPNVideoEnhancementRenderer)
@MainActor
final class OPNVideoEnhancementRenderer: NSObject {
    private let device: (any MTLDevice)?
    private let commandQueue: (any MTLCommandQueue)?
    private let ciContext: CIContext?
    private let outputColorSpace = CGColorSpaceCreateDeviceRGB()
    private let metalFXUpscaler: OPNMetalFXUpscaler
    private let textureSource: OPNVideoTextureSource
    private var metalFXIntermediateTexture: (any MTLTexture)?
    private var metalFXOutputTexture: (any MTLTexture)?
    private var spatialRGBPipeline: (any MTLRenderPipelineState)?
    private var spatialNV12Pipeline: (any MTLRenderPipelineState)?
    private var spatialI420Pipeline: (any MTLRenderPipelineState)?
    private var fastSpatialRGBPipeline: (any MTLRenderPipelineState)?
    private var fastSpatialNV12Pipeline: (any MTLRenderPipelineState)?
    private var fastSpatialI420Pipeline: (any MTLRenderPipelineState)?
    private var temporalMotionPipeline: (any MTLRenderPipelineState)?
    private var temporalCompositePipeline: (any MTLRenderPipelineState)?
    private var temporalPresentPipeline: (any MTLRenderPipelineState)?
    private var temporalCurrentTexture: (any MTLTexture)?
    private var temporalHistoryTexture: (any MTLTexture)?
    private var temporalOutputTexture: (any MTLTexture)?
    private var temporalMotionTexture: (any MTLTexture)?
    private var temporalHistoryValid = false
    private var temporalFrameIndex = 0
    private var temporalPreviousJitter = SIMD2<Float>(0, 0)
    private var temporalHistoryWidth = 0
    private var temporalHistoryHeight = 0
    private var temporalSourceWidth = 0
    private var temporalSourceHeight = 0
    private var temporalHistoryResetCount = 0
    private var droppedFrames: UInt64 = 0

    @objc init(device: (any MTLDevice)?, commandQueue: (any MTLCommandQueue)?) {
        self.device = device
        self.commandQueue = commandQueue
        self.ciContext = device.map { CIContext(mtlDevice: $0, options: [.workingColorSpace: NSNull()]) }
        self.metalFXUpscaler = OPNMetalFXUpscaler(device: device)
        self.textureSource = OPNVideoTextureSource(device: device)
        super.init()
        spatialRGBPipeline = newSpatialPipeline(fragmentFunctionName: "opn_video_spatial_rgb")
        spatialNV12Pipeline = newSpatialPipeline(fragmentFunctionName: "opn_video_spatial_nv12")
        spatialI420Pipeline = newSpatialPipeline(fragmentFunctionName: "opn_video_spatial_i420")
        fastSpatialRGBPipeline = newSpatialPipeline(fragmentFunctionName: "opn_video_fast_rgb")
        fastSpatialNV12Pipeline = newSpatialPipeline(fragmentFunctionName: "opn_video_fast_nv12")
        fastSpatialI420Pipeline = newSpatialPipeline(fragmentFunctionName: "opn_video_fast_i420")
        temporalMotionPipeline = newSpatialPipeline(fragmentFunctionName: "opn_video_temporal_motion", pixelFormat: .rgba16Float)
        temporalCompositePipeline = newSpatialPipeline(fragmentFunctionName: "opn_video_temporal_composite")
        temporalPresentPipeline = newSpatialPipeline(fragmentFunctionName: "opn_video_present_rgb")
    }

    @objc var isMetalFXAvailable: Bool {
        metalFXUpscaler.isAvailable
    }

    @objc var isTemporalAvailable: Bool {
        commandQueue != nil && spatialRGBPipeline != nil && spatialNV12Pipeline != nil && spatialI420Pipeline != nil && temporalMotionPipeline != nil && temporalCompositePipeline != nil && temporalPresentPipeline != nil
    }

    @objc(renderFrame:toView:settings:result:)
    func renderFrame(
        _ frame: RTCVideoFrame?,
        to view: MTKView?,
        settings: OPNVideoEnhancementSettings?,
        result: OPNVideoEnhancementResult?
    ) -> Bool {
        let start = CACurrentMediaTime()
        populateResult(result, settings: settings)
        guard let frame, let view, let settings, let result, settings.configuredTier != .off else {
            result?.fallbackReason = "enhancement disabled"
            result?.enhancedPixelBuffer = nil
            return false
        }
        guard let drawable = view.currentDrawable, let commandQueue, let ciContext else {
            result.fallbackReason = "enhancement renderer got empty drawable"
            recordDrop(in: result)
            return false
        }
        guard settings.drawableSize.width > 0, settings.drawableSize.height > 0 else {
            result.fallbackReason = "enhancement renderer got empty drawable"
            recordDrop(in: result)
            return false
        }

        if (settings.configuredTier == .spatial || settings.configuredTier == .metalFX || settings.configuredTier == .temporal), !settings.captureEnhancedPixelBuffer {
            var pixelFormat: NSString?
            var frameSource: NSString?
            var textureFallback: NSString?
            let textureFrame = textureSource.newTextureFrame(for: frame, pixelFormat: &pixelFormat, frameSource: &frameSource, fallback: &textureFallback) as? OPNVideoTextureFrame
            result.pixelFormat = (pixelFormat as String?) ?? result.pixelFormat
            result.frameSource = (frameSource as String?) ?? result.frameSource
            if let textureFrame, let commandBuffer = commandQueue.makeCommandBuffer() {
                if settings.configuredTier == .temporal, renderTemporalTextureFrame(textureFrame, drawable: drawable, commandBuffer: commandBuffer, settings: settings, result: result, start: start) {
                    return true
                }
                if settings.configuredTier == .metalFX, renderMetalFXTextureFrame(textureFrame, drawable: drawable, commandBuffer: commandBuffer, settings: settings, result: result, start: start) {
                    return true
                }
                if settings.configuredTier == .spatial, renderSpatialTextureFrame(textureFrame, drawable: drawable, commandBuffer: commandBuffer, settings: settings, result: result, start: start) {
                    return true
                }
            }
            if let textureFallback, result.fallbackReason.isEmpty { result.fallbackReason = textureFallback as String }
        }

        guard let source = image(for: frame, result: result) else {
            result.fallbackReason = result.fallbackReason.isEmpty ? "video frame conversion failed" : result.fallbackReason
            recordDrop(in: result)
            return false
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            result.fallbackReason = "Core Image command buffer unavailable"
            recordDrop(in: result)
            return false
        }

        if settings.configuredTier == .metalFX,
           !settings.captureEnhancedPixelBuffer,
           renderMetalFXFrame(source, drawable: drawable, commandBuffer: commandBuffer, settings: settings, result: result, start: start) {
            return true
        }

        let drawableBounds = CGRect(x: 0, y: 0, width: drawable.texture.width, height: drawable.texture.height)
        let filtered = enhancedImage(source, settings: settings)
        ciContext.render(filtered, to: drawable.texture, commandBuffer: commandBuffer, bounds: drawableBounds, colorSpace: outputColorSpace)
        if settings.captureEnhancedPixelBuffer {
            result.enhancedPixelBuffer = newEnhancedPixelBuffer(from: filtered, width: drawable.texture.width, height: drawable.texture.height, context: ciContext)
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()

        result.renderPath = "OPNVideoEnhancementRendererSwift"
        result.renderMode = renderMode(for: settings.configuredTier)
        result.activeTier = activeTierName(for: settings.configuredTier)
        result.frameTimeMs = max(0, (CACurrentMediaTime() - start) * 1000)
        result.droppedFrames = droppedFrames
        result.diagnostics = "Swift Core Image renderer"
        return true
    }

    private func renderMetalFXFrame(
        _ image: CIImage,
        drawable: any CAMetalDrawable,
        commandBuffer: any MTLCommandBuffer,
        settings: OPNVideoEnhancementSettings,
        result: OPNVideoEnhancementResult,
        start: CFTimeInterval
    ) -> Bool {
        guard isMetalFXAvailable, let ciContext else { return false }
        let sourceExtent = image.extent.integral
        let sourceWidth = Int(sourceExtent.width.rounded())
        let sourceHeight = Int(sourceExtent.height.rounded())
        let outputWidth = drawable.texture.width
        let outputHeight = drawable.texture.height
        guard sourceWidth > 0, sourceHeight > 0, outputWidth >= sourceWidth, outputHeight >= sourceHeight else { return false }
        guard let sourceTexture = reusableTexture(&metalFXIntermediateTexture, width: sourceWidth, height: sourceHeight, pixelFormat: .bgra8Unorm, usage: [.shaderRead, .renderTarget], label: "OpenNOW MetalFX source"),
              let outputTexture = reusableTexture(&metalFXOutputTexture, width: outputWidth, height: outputHeight, pixelFormat: drawable.texture.pixelFormat, usage: [.shaderRead, .shaderWrite, .renderTarget], label: "OpenNOW MetalFX output") else {
            result.fallbackReason = "MetalFX texture allocation failed"
            recordDrop(in: result)
            return false
        }

        let filtered = enhancedImageWithoutScale(image.transformed(by: CGAffineTransform(translationX: -sourceExtent.origin.x, y: -sourceExtent.origin.y)), settings: settings).cropped(to: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight))
        ciContext.render(filtered, to: sourceTexture, commandBuffer: commandBuffer, bounds: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight), colorSpace: outputColorSpace)
        var fallback: NSString?
        guard metalFXUpscaler.encodeTexture(sourceTexture, toTexture: outputTexture, commandBuffer: commandBuffer, fallback: &fallback) else {
            result.fallbackReason = (fallback as String?) ?? "MetalFX encode failed"
            recordDrop(in: result)
            return false
        }
        guard encodePresentTexture(sourceTexture: outputTexture, destinationTexture: drawable.texture, commandBuffer: commandBuffer, result: result) else {
            if result.fallbackReason.isEmpty { result.fallbackReason = "MetalFX present failed" }
            recordDrop(in: result)
            return false
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()

        result.renderPath = "OPNMetalFXSpatialScalerSwift"
        result.renderMode = "MetalFX"
        result.activeTier = "MetalFX Spatial"
        result.frameTimeMs = max(0, (CACurrentMediaTime() - start) * 1000)
        result.droppedFrames = droppedFrames
        result.diagnostics = "Swift MetalFX spatial scaler"
        return true
    }

    private func renderMetalFXTextureFrame(
        _ textureFrame: OPNVideoTextureFrame,
        drawable: any CAMetalDrawable,
        commandBuffer: any MTLCommandBuffer,
        settings: OPNVideoEnhancementSettings,
        result: OPNVideoEnhancementResult,
        start: CFTimeInterval
    ) -> Bool {
        guard isMetalFXAvailable, temporalPresentPipeline != nil else { return false }
        let outputWidth = drawable.texture.width
        let outputHeight = drawable.texture.height
        guard let outputTexture = reusableTexture(&metalFXOutputTexture, width: outputWidth, height: outputHeight, pixelFormat: drawable.texture.pixelFormat, usage: [.shaderRead, .shaderWrite, .renderTarget], label: "OpenNOW MetalFX output") else {
            result.fallbackReason = "MetalFX output texture allocation failed"
            return false
        }

        let needsSpatialConversion = textureFrame.kind != 0 || !Self.textureFrameUsesFullCrop(textureFrame)
        let sourceTexture: (any MTLTexture)?
        if needsSpatialConversion {
            let primaryTexture = textureFrame.rgbTexture ?? textureFrame.lumaTexture
            guard let primaryTexture else { return false }
            let width = Int(textureFrame.contentWidth) > 0 ? Int(textureFrame.contentWidth) : primaryTexture.width
            let height = Int(textureFrame.contentHeight) > 0 ? Int(textureFrame.contentHeight) : primaryTexture.height
            guard let intermediateTexture = reusableTexture(&metalFXIntermediateTexture, width: width, height: height, pixelFormat: .bgra8Unorm, usage: [.renderTarget, .shaderRead], label: "OpenNOW MetalFX conversion intermediate") else {
                result.fallbackReason = "MetalFX intermediate texture allocation failed"
                return false
            }
            guard encodeSpatialTextureFrame(textureFrame, destinationTexture: intermediateTexture, commandBuffer: commandBuffer, settings: settings, result: result) else {
                result.fallbackReason = "MetalFX RGB conversion failed"
                return false
            }
            sourceTexture = intermediateTexture
        } else {
            sourceTexture = textureFrame.rgbTexture
        }

        var fallback: NSString?
        guard metalFXUpscaler.encodeTexture(sourceTexture, toTexture: outputTexture, commandBuffer: commandBuffer, fallback: &fallback) else {
            result.fallbackReason = (fallback as String?) ?? "MetalFX encode failed"
            return false
        }
        guard encodePresentTexture(sourceTexture: outputTexture, destinationTexture: drawable.texture, commandBuffer: commandBuffer, result: result) else {
            if result.fallbackReason.isEmpty { result.fallbackReason = "MetalFX present failed" }
            return false
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()

        result.renderPath = "OPNMetalFXSpatialScalerSwift"
        result.renderMode = "MetalFX"
        result.activeTier = "MetalFX Spatial"
        result.frameTimeMs = max(0, (CACurrentMediaTime() - start) * 1000)
        result.droppedFrames = droppedFrames
        result.diagnostics = needsSpatialConversion ? "Swift MetalFX spatial scaler with RGB conversion" : "Swift MetalFX spatial scaler"
        return true
    }

    private func renderSpatialTextureFrame(
        _ textureFrame: OPNVideoTextureFrame,
        drawable: any CAMetalDrawable,
        commandBuffer: any MTLCommandBuffer,
        settings: OPNVideoEnhancementSettings,
        result: OPNVideoEnhancementResult,
        start: CFTimeInterval
    ) -> Bool {
        guard encodeSpatialTextureFrame(textureFrame, destinationTexture: drawable.texture, commandBuffer: commandBuffer, settings: settings, result: result) else { return false }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        result.renderPath = "OPNMetalSpatialUpscalerSwift"
        result.renderMode = "Spatial"
        result.activeTier = settings.lowCostSpatial ? "Metal Spatial Low Cost" : "Metal Spatial"
        result.frameTimeMs = max(0, (CACurrentMediaTime() - start) * 1000)
        result.droppedFrames = droppedFrames
        result.diagnostics = settings.lowCostSpatial ? "Swift Metal fast spatial shader" : "Swift Metal spatial shader"
        return true
    }

    private func renderTemporalTextureFrame(
        _ textureFrame: OPNVideoTextureFrame,
        drawable: any CAMetalDrawable,
        commandBuffer: any MTLCommandBuffer,
        settings: OPNVideoEnhancementSettings,
        result: OPNVideoEnhancementResult,
        start: CFTimeInterval
    ) -> Bool {
        guard isTemporalAvailable else { return false }
        let width = drawable.texture.width
        let height = drawable.texture.height
        let motionWidth = max(1, (width + 1) / 2)
        let motionHeight = max(1, (height + 1) / 2)
        guard let currentTexture = reusableTexture(&temporalCurrentTexture, width: width, height: height, pixelFormat: .bgra8Unorm, usage: [.renderTarget, .shaderRead], label: "OpenNOW temporal current"),
              let outputTexture = reusableTexture(&temporalOutputTexture, width: width, height: height, pixelFormat: .bgra8Unorm, usage: [.renderTarget, .shaderRead], label: "OpenNOW temporal output"),
              let historyTexture = reusableTexture(&temporalHistoryTexture, width: width, height: height, pixelFormat: .bgra8Unorm, usage: [.renderTarget, .shaderRead], label: "OpenNOW temporal history"),
              let motionTexture = reusableTexture(&temporalMotionTexture, width: motionWidth, height: motionHeight, pixelFormat: .rgba16Float, usage: [.renderTarget, .shaderRead], label: "OpenNOW temporal half-res motion") else {
            result.fallbackReason = "temporal upscaler could not allocate history textures"
            temporalHistoryValid = false
            return false
        }

        let primaryTexture = textureFrame.rgbTexture ?? textureFrame.lumaTexture
        let sourceWidth = primaryTexture?.width ?? 0
        let sourceHeight = primaryTexture?.height ?? 0
        let jitterPixels = Self.temporalJitter(frameIndex: temporalFrameIndex)
        let currentJitter = SIMD2<Float>(sourceWidth > 0 ? jitterPixels.x / Float(sourceWidth) : 0, sourceHeight > 0 ? jitterPixels.y / Float(sourceHeight) : 0)
        var previousJitter = temporalPreviousJitter
        if temporalHistoryWidth != width || temporalHistoryHeight != height || temporalSourceWidth != sourceWidth || temporalSourceHeight != sourceHeight {
            if temporalHistoryWidth > 0 || temporalHistoryHeight > 0 || temporalSourceWidth > 0 || temporalSourceHeight > 0 { temporalHistoryResetCount += 1 }
            temporalHistoryValid = false
            temporalHistoryWidth = width
            temporalHistoryHeight = height
            temporalSourceWidth = sourceWidth
            temporalSourceHeight = sourceHeight
            previousJitter = currentJitter
        }
        let hadHistoryBeforeFrame = temporalHistoryValid
        let jitterDelta = currentJitter - previousJitter

        guard encodeSpatialTextureFrame(textureFrame, destinationTexture: currentTexture, commandBuffer: commandBuffer, settings: settings, result: result, jitter: currentJitter),
              encodeTemporalMotionTexture(currentTexture: currentTexture, historyTexture: historyTexture, motionTexture: motionTexture, jitterDelta: jitterDelta, commandBuffer: commandBuffer, result: result),
              encodeTemporalCurrentTexture(currentTexture: currentTexture, historyTexture: historyTexture, motionTexture: motionTexture, destinationTexture: outputTexture, commandBuffer: commandBuffer, settings: settings, result: result),
              encodePresentTexture(sourceTexture: outputTexture, destinationTexture: drawable.texture, commandBuffer: commandBuffer, result: result) else {
            temporalHistoryValid = false
            return false
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
        let previousHistory = temporalHistoryTexture
        temporalHistoryTexture = temporalOutputTexture
        temporalOutputTexture = previousHistory
        temporalHistoryValid = true
        temporalPreviousJitter = currentJitter
        temporalFrameIndex = (temporalFrameIndex + 1) % 8

        result.renderPath = "OPNMetalTemporalUpscalerSwift"
        result.renderMode = "Temporal"
        result.activeTier = "Temporal reconstruction"
        if settings.emitDiagnostics {
            result.diagnostics = String(format: "motion %dx%d half-res; jitter 8-sample %.2f,%.2f px; history %@; resets %d; AA history clip/adaptive edge resolve", motionWidth, motionHeight, jitterPixels.x, jitterPixels.y, hadHistoryBeforeFrame ? "reused" : "priming", temporalHistoryResetCount)
        }
        result.frameTimeMs = max(0, (CACurrentMediaTime() - start) * 1000)
        result.droppedFrames = droppedFrames
        return true
    }

    private func encodeSpatialTextureFrame(
        _ textureFrame: OPNVideoTextureFrame,
        destinationTexture: any MTLTexture,
        commandBuffer: any MTLCommandBuffer,
        settings: OPNVideoEnhancementSettings,
        result: OPNVideoEnhancementResult,
        jitter suppliedJitter: SIMD2<Float> = SIMD2<Float>(0, 0)
    ) -> Bool {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = destinationTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            result.fallbackReason = "spatial scaler could not create encoder"
            return false
        }

        let primaryTexture: (any MTLTexture)?
        let pipeline: (any MTLRenderPipelineState)?
        switch textureFrame.kind {
        case 1:
            primaryTexture = textureFrame.lumaTexture
            pipeline = settings.lowCostSpatial ? (fastSpatialNV12Pipeline ?? spatialNV12Pipeline) : spatialNV12Pipeline
        case 2:
            primaryTexture = textureFrame.lumaTexture
            pipeline = settings.lowCostSpatial ? (fastSpatialI420Pipeline ?? spatialI420Pipeline) : spatialI420Pipeline
        default:
            primaryTexture = textureFrame.rgbTexture
            pipeline = settings.lowCostSpatial ? (fastSpatialRGBPipeline ?? spatialRGBPipeline) : spatialRGBPipeline
        }
        guard let primaryTexture, let pipeline else {
            encoder.endEncoding()
            result.fallbackReason = "spatial scaler missing texture or pipeline"
            return false
        }

        var texel = SIMD2<Float>(primaryTexture.width > 0 ? 1.0 / Float(primaryTexture.width) : 0, primaryTexture.height > 0 ? 1.0 / Float(primaryTexture.height) : 0)
        var sharpness = min(max(Float(settings.sharpness) / 10.0, 0), 4)
        var denoise = min(max((Float(settings.denoise) / 10.0) * 0.65, 0), 1)
        let cropRect = textureFrame.cropRect.width > 0 && textureFrame.cropRect.height > 0 ? textureFrame.cropRect : CGRect(x: 0, y: 0, width: 1, height: 1)
        let minX = min(max(Float(cropRect.minX), 0), 1)
        let minY = min(max(Float(cropRect.minY), 0), 1)
        let maxX = min(max(Float(cropRect.maxX), 0), 1)
        let maxY = min(max(Float(cropRect.maxY), 0), 1)
        var crop = maxX > minX && maxY > minY ? SIMD4<Float>(minX, minY, maxX, maxY) : SIMD4<Float>(0, 0, 1, 1)
        var jitter = suppliedJitter

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(primaryTexture, index: 0)
        if textureFrame.kind == 1 { encoder.setFragmentTexture(textureFrame.chromaTexture, index: 1) }
        if textureFrame.kind == 2 {
            encoder.setFragmentTexture(textureFrame.chromaUTexture, index: 1)
            encoder.setFragmentTexture(textureFrame.chromaVTexture, index: 2)
        }
        encoder.setFragmentBytes(&texel, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
        encoder.setFragmentBytes(&sharpness, length: MemoryLayout<Float>.size, index: 1)
        encoder.setFragmentBytes(&denoise, length: MemoryLayout<Float>.size, index: 2)
        encoder.setFragmentBytes(&crop, length: MemoryLayout<SIMD4<Float>>.size, index: 3)
        encoder.setFragmentBytes(&jitter, length: MemoryLayout<SIMD2<Float>>.size, index: 4)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }

    private func encodeTemporalMotionTexture(
        currentTexture: any MTLTexture,
        historyTexture: any MTLTexture,
        motionTexture: any MTLTexture,
        jitterDelta: SIMD2<Float>,
        commandBuffer: any MTLCommandBuffer,
        result: OPNVideoEnhancementResult
    ) -> Bool {
        guard let temporalMotionPipeline else {
            result.fallbackReason = "temporal upscaler missing motion target"
            return false
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = motionTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            result.fallbackReason = "temporal upscaler could not create motion encoder"
            return false
        }
        var texel = SIMD2<Float>(currentTexture.width > 0 ? 1.0 / Float(currentTexture.width) : 0, currentTexture.height > 0 ? 1.0 / Float(currentTexture.height) : 0)
        var hasHistory: Int32 = temporalHistoryValid ? 1 : 0
        var jitterDelta = jitterDelta
        encoder.setRenderPipelineState(temporalMotionPipeline)
        encoder.setFragmentTexture(currentTexture, index: 0)
        encoder.setFragmentTexture(historyTexture, index: 1)
        encoder.setFragmentBytes(&texel, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
        encoder.setFragmentBytes(&hasHistory, length: MemoryLayout<Int32>.size, index: 1)
        encoder.setFragmentBytes(&jitterDelta, length: MemoryLayout<SIMD2<Float>>.size, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }

    private func encodeTemporalCurrentTexture(
        currentTexture: any MTLTexture,
        historyTexture: any MTLTexture,
        motionTexture: any MTLTexture,
        destinationTexture: any MTLTexture,
        commandBuffer: any MTLCommandBuffer,
        settings: OPNVideoEnhancementSettings,
        result: OPNVideoEnhancementResult
    ) -> Bool {
        guard let temporalCompositePipeline else {
            result.fallbackReason = "temporal upscaler missing composite target"
            return false
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = destinationTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            result.fallbackReason = "temporal upscaler could not create composite encoder"
            return false
        }
        var texel = SIMD2<Float>(currentTexture.width > 0 ? 1.0 / Float(currentTexture.width) : 0, currentTexture.height > 0 ? 1.0 / Float(currentTexture.height) : 0)
        let denoiseScale = min(max(Float(settings.denoise) / 20.0, 0), 1)
        let sharpnessScale = min(max(Float(settings.sharpness) / 40.0, 0), 1)
        var historyWeight = min(max(0.52 + denoiseScale * 0.24 - sharpnessScale * 0.08, 0.35), 0.76)
        var temporalSharpness = min(max(0.08 + sharpnessScale * 0.34, 0), 0.42)
        var hasHistory: Int32 = temporalHistoryValid ? 1 : 0
        encoder.setRenderPipelineState(temporalCompositePipeline)
        encoder.setFragmentTexture(currentTexture, index: 0)
        encoder.setFragmentTexture(historyTexture, index: 1)
        encoder.setFragmentTexture(motionTexture, index: 2)
        encoder.setFragmentBytes(&texel, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
        encoder.setFragmentBytes(&historyWeight, length: MemoryLayout<Float>.size, index: 1)
        encoder.setFragmentBytes(&temporalSharpness, length: MemoryLayout<Float>.size, index: 2)
        encoder.setFragmentBytes(&hasHistory, length: MemoryLayout<Int32>.size, index: 3)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }

    private func encodePresentTexture(
        sourceTexture: any MTLTexture,
        destinationTexture: any MTLTexture,
        commandBuffer: any MTLCommandBuffer,
        result: OPNVideoEnhancementResult
    ) -> Bool {
        guard let temporalPresentPipeline else {
            result.fallbackReason = "temporal upscaler missing present target"
            return false
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = destinationTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            result.fallbackReason = "temporal upscaler could not create present encoder"
            return false
        }
        encoder.setRenderPipelineState(temporalPresentPipeline)
        encoder.setFragmentTexture(sourceTexture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }

    private func newSpatialPipeline(fragmentFunctionName: String, pixelFormat: MTLPixelFormat = .bgra8Unorm) -> (any MTLRenderPipelineState)? {
        guard let device else { return nil }
        do {
            let library = try device.makeLibrary(source: OPNVideoTextureSource.spatialShaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "opn_video_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: fragmentFunctionName)
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            NSLog("[LibWebRTC] spatial enhancement pipeline %@ failed: %@", fragmentFunctionName, error.localizedDescription)
            return nil
        }
    }

    private func populateResult(_ result: OPNVideoEnhancementResult?, settings: OPNVideoEnhancementSettings?) {
        guard let result else { return }
        result.pixelFormat = "unknown"
        result.renderMode = "CoreImage"
        result.frameSource = "unknown"
        result.renderPath = ""
        result.fallbackReason = ""
        result.configuredTier = settings.map { tierName(for: $0.configuredTier) } ?? "Off"
        result.activeTier = "Off"
        result.tierFallbackReason = ""
        result.sourceResolution = settings.map { resolutionString($0.sourceSize) } ?? "unknown"
        result.drawableResolution = settings.map { resolutionString($0.drawableSize) } ?? "unknown"
        result.diagnostics = ""
        result.frameTimeMs = 0
        result.droppedFrames = droppedFrames
        result.enhancedPixelBuffer = nil
    }

    private func image(for frame: RTCVideoFrame, result: OPNVideoEnhancementResult) -> CIImage? {
        let buffer = frame.buffer
        if let cvBuffer = buffer as? RTCCVPixelBuffer {
            let pixelBuffer = cvBuffer.pixelBuffer
            result.frameSource = "CVPixelBuffer"
            result.pixelFormat = pixelFormatName(CVPixelBufferGetPixelFormatType(pixelBuffer))
            var image = CIImage(cvPixelBuffer: pixelBuffer)
            if cvBuffer.requiresCropping(), cvBuffer.cropWidth > 0, cvBuffer.cropHeight > 0 {
                let crop = CGRect(x: CGFloat(cvBuffer.cropX), y: CGFloat(cvBuffer.cropY), width: CGFloat(cvBuffer.cropWidth), height: CGFloat(cvBuffer.cropHeight))
                image = image.cropped(to: crop)
            }
            return image
        }

        let i420Frame = frame.newI420()
        guard let i420 = i420Frame.buffer as? RTCI420Buffer,
              let pixelBuffer = newBGRAFramebuffer(from: i420) else {
            result.frameSource = Self.frameBufferClassName(buffer) as String
            result.pixelFormat = "I420"
            result.fallbackReason = "I420 frame conversion failed"
            return nil
        }
        result.frameSource = Self.frameBufferClassName(buffer) as String
        result.pixelFormat = "I420"
        return CIImage(cvPixelBuffer: pixelBuffer)
    }

    private func enhancedImage(_ image: CIImage, settings: OPNVideoEnhancementSettings) -> CIImage {
        let target = CGRect(origin: .zero, size: settings.drawableSize)
        let sourceExtent = image.extent
        guard sourceExtent.width > 0, sourceExtent.height > 0, target.width > 0, target.height > 0 else { return image }
        let scaleX = target.width / sourceExtent.width
        let scaleY = target.height / sourceExtent.height
        var output = image.transformed(by: CGAffineTransform(translationX: -sourceExtent.origin.x, y: -sourceExtent.origin.y).scaledBy(x: scaleX, y: scaleY))
        output = enhancedImageWithoutScale(output, settings: settings)
        return output.cropped(to: target)
    }

    private func enhancedImageWithoutScale(_ image: CIImage, settings: OPNVideoEnhancementSettings) -> CIImage {
        var output = image
        if settings.denoise > 0, let filter = CIFilter(name: "CINoiseReduction") {
            filter.setValue(output, forKey: kCIInputImageKey)
            filter.setValue(Double(settings.denoise) / 100.0, forKey: "inputNoiseLevel")
            filter.setValue(0.40, forKey: "inputSharpness")
            output = filter.outputImage ?? output
        }
        if settings.sharpness > 0, let filter = CIFilter(name: "CISharpenLuminance") {
            filter.setValue(output, forKey: kCIInputImageKey)
            filter.setValue(Double(settings.sharpness) / 50.0, forKey: kCIInputSharpnessKey)
            output = filter.outputImage ?? output
        }
        return output
    }

    private func reusableTexture(
        _ texture: inout (any MTLTexture)?,
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat,
        usage: MTLTextureUsage,
        label: String
    ) -> (any MTLTexture)? {
        guard let device, width > 0, height > 0 else { return nil }
        if texture == nil || texture?.width != width || texture?.height != height || texture?.pixelFormat != pixelFormat {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
            descriptor.usage = usage
            descriptor.storageMode = .private
            texture = device.makeTexture(descriptor: descriptor)
            texture?.label = label
        }
        return texture
    }

    private func newEnhancedPixelBuffer(from image: CIImage, width: Int, height: Int, context: CIContext) -> CVPixelBuffer? {
        guard width > 0, height > 0 else { return nil }
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { return nil }
        context.render(image, to: pixelBuffer, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: outputColorSpace)
        return pixelBuffer
    }

    private func newBGRAFramebuffer(from i420: RTCI420Buffer) -> CVPixelBuffer? {
        let width = Int(i420.width)
        let height = Int(i420.height)
        guard width > 0, height > 0 else { return nil }
        let dataY = i420.dataY
        let dataU = i420.dataU
        let dataV = i420.dataV
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let dst = baseAddress.assumingMemoryBound(to: UInt8.self)
        let dstStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let strideY = Int(i420.strideY)
        let strideU = Int(i420.strideU)
        let strideV = Int(i420.strideV)
        for y in 0..<height {
            let row = dst.advanced(by: y * dstStride)
            let yRow = dataY.advanced(by: y * strideY)
            let uRow = dataU.advanced(by: (y / 2) * strideU)
            let vRow = dataV.advanced(by: (y / 2) * strideV)
            for x in 0..<width {
                let yy = Int(yRow[x])
                let uu = Int(uRow[x / 2]) - 128
                let vv = Int(vRow[x / 2]) - 128
                let r = clamp8(yy + ((1436 * vv) >> 10))
                let g = clamp8(yy - ((352 * uu + 731 * vv) >> 10))
                let b = clamp8(yy + ((1815 * uu) >> 10))
                let offset = x * 4
                row[offset] = b
                row[offset + 1] = g
                row[offset + 2] = r
                row[offset + 3] = 255
            }
        }
        return pixelBuffer
    }

    private func recordDrop(in result: OPNVideoEnhancementResult) {
        droppedFrames += 1
        result.droppedFrames = droppedFrames
        result.activeTier = "Off"
        result.frameTimeMs = 0
    }

    private func resolutionString(_ size: CGSize) -> String {
        let width = Int(max(0, size.width).rounded())
        let height = Int(max(0, size.height).rounded())
        return width > 0 && height > 0 ? "\(width)x\(height)" : "unknown"
    }

    private func tierName(for tier: OPNVideoEnhancementTier) -> String {
        switch tier {
        case .spatial: return "Spatial"
        case .metalFX: return "MetalFX"
        case .temporal: return "Temporal"
        case .off: return "Off"
        @unknown default: return "Off"
        }
    }

    private func activeTierName(for tier: OPNVideoEnhancementTier) -> String {
        switch tier {
        case .spatial: return "Spatial"
        case .metalFX: return isMetalFXAvailable ? "MetalFX Spatial" : "Spatial"
        case .temporal: return "Temporal"
        case .off: return "Off"
        @unknown default: return "Off"
        }
    }

    private func renderMode(for tier: OPNVideoEnhancementTier) -> String {
        switch tier {
        case .metalFX: return isMetalFXAvailable ? "MetalFX" : "CoreImage"
        case .temporal: return "Temporal CoreImage"
        case .spatial: return "CoreImage"
        case .off: return "Off"
        @unknown default: return "CoreImage"
        }
    }

    private func pixelFormatName(_ format: OSType) -> String {
        if format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange { return "420v/NV12" }
        if format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange { return "420f/NV12" }
        if format == kCVPixelFormatType_32BGRA { return "BGRA" }
        if format == kCVPixelFormatType_32ARGB { return "ARGB" }
        return String(format: "0x%08x", format)
    }

    private func clamp8(_ value: Int) -> UInt8 {
        UInt8(max(0, min(255, value)))
    }

    private static func temporalJitter(frameIndex: Int) -> SIMD2<Float> {
        let offsets: [SIMD2<Float>] = [
            SIMD2<Float>(-0.375, -0.125),
            SIMD2<Float>(0.125, 0.375),
            SIMD2<Float>(-0.125, -0.375),
            SIMD2<Float>(0.375, 0.125),
            SIMD2<Float>(-0.3125, 0.3125),
            SIMD2<Float>(0.1875, -0.1875),
            SIMD2<Float>(-0.1875, 0.1875),
            SIMD2<Float>(0.3125, -0.3125),
        ]
        return offsets[frameIndex % offsets.count]
    }

    private static func textureFrameUsesFullCrop(_ textureFrame: OPNVideoTextureFrame) -> Bool {
        let crop = textureFrame.cropRect
        return crop.minX <= 0.0001 && crop.minY <= 0.0001 && crop.width >= 0.9999 && crop.height >= 0.9999
    }

    private static func frameBufferClassName(_ buffer: any RTCVideoFrameBuffer) -> NSString {
        NSStringFromClass(type(of: buffer) as AnyClass) as NSString
    }
}
