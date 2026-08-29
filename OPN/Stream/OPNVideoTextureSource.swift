//  OPNVideoTextureSource.swift
//  OpenNOW
//

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
        let isBiPlanar = Self.isSupportedBiPlanarFormat(format)
        let isTenBitBiPlanar = Self.isTenBitBiPlanarFormat(format)
        guard isBGRA || isBiPlanar else {
            fallback?.pointee = "unsupported GPU ingestion format; using Core Image compatibility path"
            return nil
        }

        let width = isBiPlanar ? CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) : CVPixelBufferGetWidth(pixelBuffer)
        let height = isBiPlanar ? CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) : CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else {
            fallback?.pointee = "empty CVPixelBuffer dimensions"
            return nil
        }

        let textureFrame = OPNVideoTextureFrame()
        textureFrame.kind = isBiPlanar ? 1 : 0
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
            isBiPlanar ? (isTenBitBiPlanar ? .r16Unorm : .r8Unorm) : .bgra8Unorm,
            width,
            height,
            0,
            &metalTexture
        )
        guard status == kCVReturnSuccess, let metalTexture, let texture = CVMetalTextureGetTexture(metalTexture) else {
            fallback?.pointee = "CVMetalTextureCache could not create BGRA texture"
            return nil
        }
        if !isBiPlanar {
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
            isTenBitBiPlanar ? .rg16Unorm : .rg8Unorm,
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
        if format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange { return "x420/P010" }
        if format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange { return "xf20/P010" }
        if format == kCVPixelFormatType_32BGRA { return "BGRA" }
        if format == kCVPixelFormatType_32ARGB { return "ARGB" }
        return String(format: "0x%08x", format)
    }

    private static func isSupportedBiPlanarFormat(_ format: OSType) -> Bool {
        format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
            format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
            isTenBitBiPlanarFormat(format)
    }

    private static func isTenBitBiPlanarFormat(_ format: OSType) -> Bool {
        format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
            format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
    }

    private static func frameBufferClassName(_ buffer: any RTCVideoFrameBuffer) -> NSString {
        NSStringFromClass(type(of: buffer) as AnyClass) as NSString
    }

    static let spatialShaderSource = """
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
// Pillarbox fill. `fill` carries (contentLeft, contentRight, dim, mode) where the
// edges are fractions of frame width and mode is an OPNPillarboxFillMode raw value.
// The server bakes black side bars into 16:9-only titles, so these columns hold
// no picture data and are repainted by mirroring the adjacent content outward.
// Modes 1..3 repaint only the bar columns. Mode 0 (black) needs no branch at all
// because the encoded source pixels are already black, and modes 4..5 remap the
// picture itself so nothing ever lands outside the content span.
// Fill mode is an integer carried in a float. Compare against an exact value rather
// than with open-ended ranges: a `mode > 3.5` style test silently captures every mode
// added afterwards, which is how "Extend" ended up rendering as "Stretch".
static bool opn_mode_is(float mode, float value) {
    return fabs(mode - value) < 0.5;
}
// Blend factor between sharp content (0) and repainted bar fill (1), feathered across
// `feather` UV units straddling the content edge so the seam has no hard vertical
// line. Outside the repaint modes this is always 0 (no fill drawn, edge geometry
// modes never reach here with bar-region UVs).
static float opn_fill_blend_alpha(float2 uv, float4 fill, float feather) {
    bool repaintsBars = opn_mode_is(fill.w, 1.0) || opn_mode_is(fill.w, 2.0) || opn_mode_is(fill.w, 3.0);
    if (!repaintsBars) { return 0.0; }
    float d = max(fill.x - uv.x, uv.x - fill.y);
    return smoothstep(-feather, feather, d);
}
// Feather width in UV units, scaled with resolution so the crossfade band is a
// consistent fraction of frame width. This only has to cover the change in sharpness
// between the picture and the fill; it used to be four times wider because it was also
// being asked to bury the encoder's dark contamination at the content edge, and that is
// now cropped away in `pillarboxUniforms` instead of blurred over.
static float opn_fill_feather(float2 texel) {
    return max(texel.x * 6.0, 0.003);
}
// A seam vignette and a rim sheen were both tried here and both removed. Each one
// draws a band of its own at the very place the seam is meant to disappear — the
// vignette a dark one on the edge, the sheen a bright one a little inside it, mirrored
// on each side of the rim so it reads as a double line. They were worth it while the
// two sides still failed to colour-match; once the cross-blur below closed that gap
// they were the most visible thing left.
//
// How far the seam cross-blur reaches on either side of the content edge, scaled with
// resolution like the other seam bands. Narrow on purpose: a wide band is what made the
// join look smeared and let faint kernel replicas show, and the only reason it had to be
// wide was to swallow the contaminated columns now cropped in `pillarboxUniforms`.
static float opn_fill_seam_radius(float2 texel) {
    return max(texel.x * 10.0, 0.005);
}
// Weight of the cross-blur result at `uv`: 1 right on the seam, fading to 0 by
// `radius` away on either side. Layered on top of the plain content/fill crossfade.
static float opn_fill_seam_weight(float2 uv, float4 fill, float radius) {
    bool repaintsBars = opn_mode_is(fill.w, 1.0) || opn_mode_is(fill.w, 2.0) || opn_mode_is(fill.w, 3.0);
    if (!repaintsBars) { return 0.0; }
    float d = min(fabs(uv.x - fill.x), fabs(uv.x - fill.y));
    return 1.0 - smoothstep(0.0, radius, d);
}
// The seam treated as the rim of a bevelled glass panel laid over the picture. A blur
// alone reads as a blur; what makes an edge read as glass is that the image visibly
// bends as it passes under the rim, and that the rim catches a highlight. Both are
// confined to the same band the cross-blur already occupies.
//
// Signed horizontal sampling offset, in UV. Zero at the rim and zero at the bevel's
// inner limit, peaking between the two: a rounded edge is steepest halfway up its
// curve, so that is where a ray crossing it bends furthest. The offset points toward
// the picture, so content is drawn outward under the bar rather than pushed away.
static float opn_glass_refraction(float2 uv, float4 fill, float width) {
    bool repaintsBars = opn_mode_is(fill.w, 1.0) || opn_mode_is(fill.w, 2.0) || opn_mode_is(fill.w, 3.0);
    if (!repaintsBars) { return 0.0; }
    float d = min(fabs(uv.x - fill.x), fabs(uv.x - fill.y));
    if (d > width) { return 0.0; }
    float n = clamp(d / max(width, 1e-4), 0.0, 1.0);
    float slope = 4.0 * n * (1.0 - n);
    // Which rim is nearest decides the direction, not which side of it this fragment
    // sits on. Keyed on the side instead, fragments just inside the left rim get pushed
    // outward into the bar columns — and those columns hold encoded black in the source
    // texture, so the picture edge samples black and the seam grows the very dark line
    // this whole effect exists to remove.
    bool nearLeftRim = fabs(uv.x - fill.x) <= fabs(uv.x - fill.y);
    float towardContent = nearLeftRim ? 1.0 : -1.0;
    // Strength is capped by a hard geometric limit, not by taste. The warp x' = x +
    // offset(x) stays single-valued only while |d(offset)/dx| < 1; here that derivative
    // peaks at 4 * strength, so anything at or above 0.25 folds the image over itself
    // and the fold shows up as a crease with doubled detail either side of it — worse
    // than the seam it was meant to disguise. 0.12 leaves a wide margin, which the tap
    // kernel needs since it adds a gradient of its own.
    return width * 0.12 * slope * towardContent;
}
// Modes 4 (stretch) and 5 (crop) rewrite where every picture pixel is sampled from.
// `geom` carries (cropScaleY, stretchK, 0, 0).
static float2 opn_fill_geometry_uv(float2 uv, float2 texCoord, float4 fill, float4 geom) {
    float mode = fill.w;
    float2 t = clamp(texCoord, float2(0.0), float2(1.0));
    if (opn_mode_is(mode, 5.0)) {
        // Crop-to-fill: content spans the full width, and the vertical overflow that
        // the wider window cannot show is trimmed symmetrically.
        return float2(mix(fill.x, fill.y, t.x), 0.5 + (t.y - 0.5) * geom.x);
    }
    if (opn_mode_is(mode, 4.0)) {
        // Edge stretch: c = k*u + (1-k)*u^3 over u in [-1,1]. The cubic keeps the
        // endpoints pinned to the content edges while the centre slope k sets how
        // much of the total stretch is pushed outward. k = window/content aspect
        // leaves the centre near 1:1; the edges absorb the difference.
        float u = t.x * 2.0 - 1.0;
        float k = geom.y;
        float c = k * u + (1.0 - k) * u * u * u;
        return float2(mix(fill.x, fill.y, clamp(c, -1.0, 1.0) * 0.5 + 0.5), uv.y);
    }
    return uv;
}
// Fade toward `dim` at the window edge so the fill reads as ambient spill rather
// than competing with the picture.
static float opn_fill_dim(float2 uv, float4 fill) {
    float distance = uv.x < fill.x ? (fill.x - uv.x) : (uv.x - fill.y);
    float span = max(uv.x < fill.x ? fill.x : (1.0 - fill.y), 1e-4);
    return mix(1.0, fill.z, clamp(distance / span, 0.0, 1.0));
}
// Where to read the fill history texture, whose [0,1] span covers exactly the
// picture content. Working in normalised content space makes the mirror a plain
// reflection about 0 or 1.
static float2 opn_fill_history_uv(float2 uv, float2 texCoord, float4 fill) {
    if (opn_mode_is(fill.w, 3.0)) { return clamp(texCoord, float2(0.0), float2(1.0)); }
    float span = max(fill.y - fill.x, 1e-4);
    float c = (uv.x - fill.x) / span;
    c = c < 0.0 ? -c : (c > 1.0 ? 2.0 - c : c);
    return float2(clamp(c, 0.0, 1.0), clamp(uv.y, 0.0, 1.0));
}
// Resolve the colour of a bar pixel for modes 1..3. Solid colour is used as given;
// the blur modes read the pre-blurred, temporally smoothed history and are dimmed
// toward the window edge so they behave as ambient spill.
// Cubic B-spline upsample from four bilinear taps.
//
// The history is tiny and gets magnified enormously into the bars, where plain
// bilinear shows its piecewise-linear seams as visible faceting. The B-spline basis
// is C2 continuous and slightly smoothing (unlike Catmull-Rom, which sharpens and
// would reintroduce structure we are trying to lose), so the result reads as a soft
// wash at any magnification.
static float3 opn_sample_bspline(texture2d<float> tex, sampler s, float2 uv) {
    float2 size = float2((float)tex.get_width(), (float)tex.get_height());
    float2 coord = uv * size - 0.5;
    float2 f = fract(coord);
    float2 base = floor(coord);
    float2 f2 = f * f;
    float2 f3 = f2 * f;
    float2 w0 = (-f3 + 3.0 * f2 - 3.0 * f + 1.0) / 6.0;
    float2 w1 = (3.0 * f3 - 6.0 * f2 + 4.0) / 6.0;
    float2 w2 = (-3.0 * f3 + 3.0 * f2 + 3.0 * f + 1.0) / 6.0;
    float2 w3 = f3 / 6.0;
    float2 g0 = w0 + w1;
    float2 g1 = w2 + w3;
    // Offset each bilinear fetch so hardware interpolation performs two of the four
    // cubic taps for free.
    float2 h0 = (base - 0.5 + w1 / g0) / size;
    float2 h1 = (base + 1.5 + w3 / g1) / size;
    float3 s00 = tex.sample(s, float2(h0.x, h0.y)).rgb;
    float3 s10 = tex.sample(s, float2(h1.x, h0.y)).rgb;
    float3 s01 = tex.sample(s, float2(h0.x, h1.y)).rgb;
    float3 s11 = tex.sample(s, float2(h1.x, h1.y)).rgb;
    return mix(mix(s11, s01, g0.x), mix(s10, s00, g0.x), g0.y);
}
static float3 opn_fill_outside(texture2d<float> fillHistory, sampler s, float2 uv, float2 texCoord, float4 fill, float4 fillColor) {
    if (opn_mode_is(fill.w, 1.0)) { return fillColor.rgb; }
    return opn_sample_bspline(fillHistory, s, opn_fill_history_uv(uv, texCoord, fill)) * opn_fill_dim(uv, fill);
}
// Plain-bilinear twin of `opn_fill_outside`, for use inside the seam kernel only.
// The B-spline exists to hide bilinear's faceting when the tiny history is magnified
// across a whole bar; inside the kernel that job is already done by averaging many
// weighted taps, so paying four fetches per tap buys nothing. One fetch instead of
// four is what makes doubling the tap count affordable.
static float3 opn_fill_outside_fast(texture2d<float> fillHistory, sampler s, float2 uv, float2 texCoord, float4 fill, float4 fillColor) {
    if (opn_mode_is(fill.w, 1.0)) { return fillColor.rgb; }
    return fillHistory.sample(s, opn_fill_history_uv(uv, texCoord, fill)).rgb * opn_fill_dim(uv, fill);
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
fragment float4 opn_video_spatial_rgb(VertexOut in [[stage_in]], texture2d<float> sourceTexture [[texture(0)]], texture2d<float> fillHistory [[texture(3)]], constant float2 &scale [[buffer(0)]], constant float &sharpness [[buffer(1)]], constant float &denoise [[buffer(2)]], constant float4 &crop [[buffer(3)]], constant float2 &jitter [[buffer(4)]], constant float4 &fill [[buffer(5)]], constant float4 &fillGeom [[buffer(6)]], constant float4 &fillColor [[buffer(7)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 uv = opn_clamp_crop(opn_crop_uv(in.texCoord, crop) + jitter, crop);
    uv = opn_fill_geometry_uv(uv, in.texCoord, fill, fillGeom);
    float2 texel = max(scale, float2(1.0 / 8192.0));
    float feather = opn_fill_feather(texel);
    float seamRadius = opn_fill_seam_radius(texel);
    float alpha = opn_fill_blend_alpha(uv, fill, feather);
    float w = opn_fill_seam_weight(uv, fill, seamRadius);
    // Sampling coordinate only. Every band measurement above is taken from the true
    // fragment position, so bending the image does not also bend the bands that decide
    // how it is mixed. Outside the bevel the offset is exactly zero.
    uv += float2(opn_glass_refraction(uv, fill, seamRadius), 0.0);
    float3 result;
    if (alpha >= 1.0 && w <= 0.0) {
        result = opn_fill_outside(fillHistory, s, uv, in.texCoord, fill, fillColor);
    } else {
        float3 center = sourceTexture.sample(s, uv).rgb;
        float3 blur = (sourceTexture.sample(s, opn_clamp_crop(uv + float2(texel.x, 0.0), crop)).rgb + sourceTexture.sample(s, opn_clamp_crop(uv - float2(texel.x, 0.0), crop)).rgb + sourceTexture.sample(s, opn_clamp_crop(uv + float2(0.0, texel.y), crop)).rgb + sourceTexture.sample(s, opn_clamp_crop(uv - float2(0.0, texel.y), crop)).rgb) * 0.25;
        float3 content = opn_finish(center, blur, sharpness, denoise);
        if (alpha <= 0.0 && w <= 0.0) {
            result = content;
        } else {
            float3 softened = mix(content, blur, min(alpha * 1.5, 1.0));
            float3 outside = opn_fill_outside(fillHistory, s, uv, in.texCoord, fill, fillColor);
            result = mix(softened, outside, alpha);
        }
    }
    if (w > 0.0) {
        float3 acc = float3(0.0);
        float weightSum = 0.0;
        // Taps must land close enough together to resolve a one-pixel stroke, or the
        // kernel undersamples and thin high-contrast marks reappear as faint evenly
        // spaced replicas. `sigma = K/2` with `step = radius/K` holds the physical
        // blur width at radius/2 whatever K is, so K controls density alone. Spacing is
        // what matters, not the count: against the narrow radius above, 8 puts taps
        // roughly a texel apart — tighter than 16 managed over the old wide band.
        const int K = 8;
        const float sigma = float(K) * 0.5;
        float step = seamRadius / float(K);
        for (int t = -K; t <= K; ++t) {
            float ft = float(t);
            float weight = exp(-0.5 * (ft / sigma) * (ft / sigma));
            float2 tapUV = uv + float2(step * ft, 0.0);
            float tapAlpha = opn_fill_blend_alpha(tapUV, fill, feather);
            float3 tapColor = mix(sourceTexture.sample(s, opn_clamp_crop(tapUV, crop)).rgb,
                                   opn_fill_outside_fast(fillHistory, s, tapUV, in.texCoord, fill, fillColor),
                                   tapAlpha);
            acc += tapColor * weight;
            weightSum += weight;
        }
        result = mix(result, acc / max(weightSum, 1e-4), w);
    }
    return float4(result, 1.0);
}
fragment float4 opn_video_spatial_nv12(VertexOut in [[stage_in]], texture2d<float> yTexture [[texture(0)]], texture2d<float> uvTexture [[texture(1)]], texture2d<float> fillHistory [[texture(3)]], constant float2 &scale [[buffer(0)]], constant float &sharpness [[buffer(1)]], constant float &denoise [[buffer(2)]], constant float4 &crop [[buffer(3)]], constant float2 &jitter [[buffer(4)]], constant float4 &fill [[buffer(5)]], constant float4 &fillGeom [[buffer(6)]], constant float4 &fillColor [[buffer(7)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 uv = opn_clamp_crop(opn_crop_uv(in.texCoord, crop) + jitter, crop);
    uv = opn_fill_geometry_uv(uv, in.texCoord, fill, fillGeom);
    float2 texel = max(scale, float2(1.0 / 8192.0));
    float feather = opn_fill_feather(texel);
    float seamRadius = opn_fill_seam_radius(texel);
    float alpha = opn_fill_blend_alpha(uv, fill, feather);
    float w = opn_fill_seam_weight(uv, fill, seamRadius);
    // Sampling coordinate only. Every band measurement above is taken from the true
    // fragment position, so bending the image does not also bend the bands that decide
    // how it is mixed. Outside the bevel the offset is exactly zero.
    uv += float2(opn_glass_refraction(uv, fill, seamRadius), 0.0);
    float3 result;
    if (alpha >= 1.0 && w <= 0.0) {
        result = opn_fill_outside(fillHistory, s, uv, in.texCoord, fill, fillColor);
    } else {
        float3 center = opn_nv12_rgb(yTexture, uvTexture, s, uv);
        float3 blur = (opn_nv12_rgb(yTexture, uvTexture, s, opn_clamp_crop(uv + float2(texel.x, 0.0), crop)) + opn_nv12_rgb(yTexture, uvTexture, s, opn_clamp_crop(uv - float2(texel.x, 0.0), crop)) + opn_nv12_rgb(yTexture, uvTexture, s, opn_clamp_crop(uv + float2(0.0, texel.y), crop)) + opn_nv12_rgb(yTexture, uvTexture, s, opn_clamp_crop(uv - float2(0.0, texel.y), crop))) * 0.25;
        float3 content = opn_finish(center, blur, sharpness, denoise);
        if (alpha <= 0.0 && w <= 0.0) {
            result = content;
        } else {
            float3 softened = mix(content, blur, min(alpha * 1.5, 1.0));
            float3 outside = opn_fill_outside(fillHistory, s, uv, in.texCoord, fill, fillColor);
            result = mix(softened, outside, alpha);
        }
    }
    if (w > 0.0) {
        float3 acc = float3(0.0);
        float weightSum = 0.0;
        // Taps must land close enough together to resolve a one-pixel stroke, or the
        // kernel undersamples and thin high-contrast marks reappear as faint evenly
        // spaced replicas. `sigma = K/2` with `step = radius/K` holds the physical
        // blur width at radius/2 whatever K is, so K controls density alone. Spacing is
        // what matters, not the count: against the narrow radius above, 8 puts taps
        // roughly a texel apart — tighter than 16 managed over the old wide band.
        const int K = 8;
        const float sigma = float(K) * 0.5;
        float step = seamRadius / float(K);
        for (int t = -K; t <= K; ++t) {
            float ft = float(t);
            float weight = exp(-0.5 * (ft / sigma) * (ft / sigma));
            float2 tapUV = uv + float2(step * ft, 0.0);
            float tapAlpha = opn_fill_blend_alpha(tapUV, fill, feather);
            float3 tapColor = mix(opn_nv12_rgb(yTexture, uvTexture, s, opn_clamp_crop(tapUV, crop)),
                                   opn_fill_outside_fast(fillHistory, s, tapUV, in.texCoord, fill, fillColor),
                                   tapAlpha);
            acc += tapColor * weight;
            weightSum += weight;
        }
        result = mix(result, acc / max(weightSum, 1e-4), w);
    }
    return float4(result, 1.0);
}
fragment float4 opn_video_spatial_i420(VertexOut in [[stage_in]], texture2d<float> yTexture [[texture(0)]], texture2d<float> uTexture [[texture(1)]], texture2d<float> vTexture [[texture(2)]], texture2d<float> fillHistory [[texture(3)]], constant float2 &scale [[buffer(0)]], constant float &sharpness [[buffer(1)]], constant float &denoise [[buffer(2)]], constant float4 &crop [[buffer(3)]], constant float2 &jitter [[buffer(4)]], constant float4 &fill [[buffer(5)]], constant float4 &fillGeom [[buffer(6)]], constant float4 &fillColor [[buffer(7)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 uv = opn_clamp_crop(opn_crop_uv(in.texCoord, crop) + jitter, crop);
    uv = opn_fill_geometry_uv(uv, in.texCoord, fill, fillGeom);
    float2 texel = max(scale, float2(1.0 / 8192.0));
    float feather = opn_fill_feather(texel);
    float seamRadius = opn_fill_seam_radius(texel);
    float alpha = opn_fill_blend_alpha(uv, fill, feather);
    float w = opn_fill_seam_weight(uv, fill, seamRadius);
    // Sampling coordinate only. Every band measurement above is taken from the true
    // fragment position, so bending the image does not also bend the bands that decide
    // how it is mixed. Outside the bevel the offset is exactly zero.
    uv += float2(opn_glass_refraction(uv, fill, seamRadius), 0.0);
    float3 result;
    if (alpha >= 1.0 && w <= 0.0) {
        result = opn_fill_outside(fillHistory, s, uv, in.texCoord, fill, fillColor);
    } else {
        float3 center = opn_i420_rgb(yTexture, uTexture, vTexture, s, uv);
        float3 blur = (opn_i420_rgb(yTexture, uTexture, vTexture, s, opn_clamp_crop(uv + float2(texel.x, 0.0), crop)) + opn_i420_rgb(yTexture, uTexture, vTexture, s, opn_clamp_crop(uv - float2(texel.x, 0.0), crop)) + opn_i420_rgb(yTexture, uTexture, vTexture, s, opn_clamp_crop(uv + float2(0.0, texel.y), crop)) + opn_i420_rgb(yTexture, uTexture, vTexture, s, opn_clamp_crop(uv - float2(0.0, texel.y), crop))) * 0.25;
        float3 content = opn_finish(center, blur, sharpness, denoise);
        if (alpha <= 0.0 && w <= 0.0) {
            result = content;
        } else {
            float3 softened = mix(content, blur, min(alpha * 1.5, 1.0));
            float3 outside = opn_fill_outside(fillHistory, s, uv, in.texCoord, fill, fillColor);
            result = mix(softened, outside, alpha);
        }
    }
    if (w > 0.0) {
        float3 acc = float3(0.0);
        float weightSum = 0.0;
        // Taps must land close enough together to resolve a one-pixel stroke, or the
        // kernel undersamples and thin high-contrast marks reappear as faint evenly
        // spaced replicas. `sigma = K/2` with `step = radius/K` holds the physical
        // blur width at radius/2 whatever K is, so K controls density alone. Spacing is
        // what matters, not the count: against the narrow radius above, 8 puts taps
        // roughly a texel apart — tighter than 16 managed over the old wide band.
        const int K = 8;
        const float sigma = float(K) * 0.5;
        float step = seamRadius / float(K);
        for (int t = -K; t <= K; ++t) {
            float ft = float(t);
            float weight = exp(-0.5 * (ft / sigma) * (ft / sigma));
            float2 tapUV = uv + float2(step * ft, 0.0);
            float tapAlpha = opn_fill_blend_alpha(tapUV, fill, feather);
            float3 tapColor = mix(opn_i420_rgb(yTexture, uTexture, vTexture, s, opn_clamp_crop(tapUV, crop)),
                                   opn_fill_outside_fast(fillHistory, s, tapUV, in.texCoord, fill, fillColor),
                                   tapAlpha);
            acc += tapColor * weight;
            weightSum += weight;
        }
        result = mix(result, acc / max(weightSum, 1e-4), w);
    }
    return float4(result, 1.0);
}
fragment float4 opn_video_fast_rgb(VertexOut in [[stage_in]], texture2d<float> sourceTexture [[texture(0)]], texture2d<float> fillHistory [[texture(3)]], constant float2 &scale [[buffer(0)]], constant float &sharpness [[buffer(1)]], constant float &denoise [[buffer(2)]], constant float4 &crop [[buffer(3)]], constant float2 &jitter [[buffer(4)]], constant float4 &fill [[buffer(5)]], constant float4 &fillGeom [[buffer(6)]], constant float4 &fillColor [[buffer(7)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 uv = opn_fill_geometry_uv(opn_crop_uv(in.texCoord, crop), in.texCoord, fill, fillGeom);
    float2 texel = max(scale, float2(1.0 / 8192.0));
    float feather = opn_fill_feather(texel);
    float seamRadius = opn_fill_seam_radius(texel);
    float alpha = opn_fill_blend_alpha(uv, fill, feather);
    float w = opn_fill_seam_weight(uv, fill, seamRadius);
    // Sampling coordinate only. Every band measurement above is taken from the true
    // fragment position, so bending the image does not also bend the bands that decide
    // how it is mixed. Outside the bevel the offset is exactly zero.
    uv += float2(opn_glass_refraction(uv, fill, seamRadius), 0.0);
    float3 content = sourceTexture.sample(s, uv).rgb;
    float3 result;
    if (alpha <= 0.0 && w <= 0.0) {
        result = content;
    } else if (alpha >= 1.0 && w <= 0.0) {
        result = opn_fill_outside(fillHistory, s, uv, in.texCoord, fill, fillColor);
    } else {
        float3 blur = (sourceTexture.sample(s, opn_clamp_crop(uv + float2(texel.x, 0.0), crop)).rgb + sourceTexture.sample(s, opn_clamp_crop(uv - float2(texel.x, 0.0), crop)).rgb + sourceTexture.sample(s, opn_clamp_crop(uv + float2(0.0, texel.y), crop)).rgb + sourceTexture.sample(s, opn_clamp_crop(uv - float2(0.0, texel.y), crop)).rgb) * 0.25;
        float3 softened = mix(content, blur, min(alpha * 1.5, 1.0));
        float3 outside = opn_fill_outside(fillHistory, s, uv, in.texCoord, fill, fillColor);
        result = mix(softened, outside, alpha);
    }
    if (w > 0.0) {
        float3 acc = float3(0.0);
        float weightSum = 0.0;
        // Taps must land close enough together to resolve a one-pixel stroke, or the
        // kernel undersamples and thin high-contrast marks reappear as faint evenly
        // spaced replicas. `sigma = K/2` with `step = radius/K` holds the physical
        // blur width at radius/2 whatever K is, so K controls density alone. Spacing is
        // what matters, not the count: against the narrow radius above, 8 puts taps
        // roughly a texel apart — tighter than 16 managed over the old wide band.
        const int K = 8;
        const float sigma = float(K) * 0.5;
        float step = seamRadius / float(K);
        for (int t = -K; t <= K; ++t) {
            float ft = float(t);
            float weight = exp(-0.5 * (ft / sigma) * (ft / sigma));
            float2 tapUV = uv + float2(step * ft, 0.0);
            float tapAlpha = opn_fill_blend_alpha(tapUV, fill, feather);
            float3 tapColor = mix(sourceTexture.sample(s, opn_clamp_crop(tapUV, crop)).rgb,
                                   opn_fill_outside_fast(fillHistory, s, tapUV, in.texCoord, fill, fillColor),
                                   tapAlpha);
            acc += tapColor * weight;
            weightSum += weight;
        }
        result = mix(result, acc / max(weightSum, 1e-4), w);
    }
    return float4(result, 1.0);
}
fragment float4 opn_video_fast_nv12(VertexOut in [[stage_in]], texture2d<float> yTexture [[texture(0)]], texture2d<float> uvTexture [[texture(1)]], texture2d<float> fillHistory [[texture(3)]], constant float2 &scale [[buffer(0)]], constant float &sharpness [[buffer(1)]], constant float &denoise [[buffer(2)]], constant float4 &crop [[buffer(3)]], constant float2 &jitter [[buffer(4)]], constant float4 &fill [[buffer(5)]], constant float4 &fillGeom [[buffer(6)]], constant float4 &fillColor [[buffer(7)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 uv = opn_fill_geometry_uv(opn_crop_uv(in.texCoord, crop), in.texCoord, fill, fillGeom);
    float2 texel = max(scale, float2(1.0 / 8192.0));
    float feather = opn_fill_feather(texel);
    float seamRadius = opn_fill_seam_radius(texel);
    float alpha = opn_fill_blend_alpha(uv, fill, feather);
    float w = opn_fill_seam_weight(uv, fill, seamRadius);
    // Sampling coordinate only. Every band measurement above is taken from the true
    // fragment position, so bending the image does not also bend the bands that decide
    // how it is mixed. Outside the bevel the offset is exactly zero.
    uv += float2(opn_glass_refraction(uv, fill, seamRadius), 0.0);
    float3 content = opn_nv12_rgb(yTexture, uvTexture, s, uv);
    float3 result;
    if (alpha <= 0.0 && w <= 0.0) {
        result = content;
    } else if (alpha >= 1.0 && w <= 0.0) {
        result = opn_fill_outside(fillHistory, s, uv, in.texCoord, fill, fillColor);
    } else {
        float3 blur = (opn_nv12_rgb(yTexture, uvTexture, s, opn_clamp_crop(uv + float2(texel.x, 0.0), crop)) + opn_nv12_rgb(yTexture, uvTexture, s, opn_clamp_crop(uv - float2(texel.x, 0.0), crop)) + opn_nv12_rgb(yTexture, uvTexture, s, opn_clamp_crop(uv + float2(0.0, texel.y), crop)) + opn_nv12_rgb(yTexture, uvTexture, s, opn_clamp_crop(uv - float2(0.0, texel.y), crop))) * 0.25;
        float3 softened = mix(content, blur, min(alpha * 1.5, 1.0));
        float3 outside = opn_fill_outside(fillHistory, s, uv, in.texCoord, fill, fillColor);
        result = mix(softened, outside, alpha);
    }
    if (w > 0.0) {
        float3 acc = float3(0.0);
        float weightSum = 0.0;
        // Taps must land close enough together to resolve a one-pixel stroke, or the
        // kernel undersamples and thin high-contrast marks reappear as faint evenly
        // spaced replicas. `sigma = K/2` with `step = radius/K` holds the physical
        // blur width at radius/2 whatever K is, so K controls density alone. Spacing is
        // what matters, not the count: against the narrow radius above, 8 puts taps
        // roughly a texel apart — tighter than 16 managed over the old wide band.
        const int K = 8;
        const float sigma = float(K) * 0.5;
        float step = seamRadius / float(K);
        for (int t = -K; t <= K; ++t) {
            float ft = float(t);
            float weight = exp(-0.5 * (ft / sigma) * (ft / sigma));
            float2 tapUV = uv + float2(step * ft, 0.0);
            float tapAlpha = opn_fill_blend_alpha(tapUV, fill, feather);
            float3 tapColor = mix(opn_nv12_rgb(yTexture, uvTexture, s, opn_clamp_crop(tapUV, crop)),
                                   opn_fill_outside_fast(fillHistory, s, tapUV, in.texCoord, fill, fillColor),
                                   tapAlpha);
            acc += tapColor * weight;
            weightSum += weight;
        }
        result = mix(result, acc / max(weightSum, 1e-4), w);
    }
    return float4(result, 1.0);
}
fragment float4 opn_video_fast_i420(VertexOut in [[stage_in]], texture2d<float> yTexture [[texture(0)]], texture2d<float> uTexture [[texture(1)]], texture2d<float> vTexture [[texture(2)]], texture2d<float> fillHistory [[texture(3)]], constant float2 &scale [[buffer(0)]], constant float &sharpness [[buffer(1)]], constant float &denoise [[buffer(2)]], constant float4 &crop [[buffer(3)]], constant float2 &jitter [[buffer(4)]], constant float4 &fill [[buffer(5)]], constant float4 &fillGeom [[buffer(6)]], constant float4 &fillColor [[buffer(7)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 uv = opn_fill_geometry_uv(opn_crop_uv(in.texCoord, crop), in.texCoord, fill, fillGeom);
    float2 texel = max(scale, float2(1.0 / 8192.0));
    float feather = opn_fill_feather(texel);
    float seamRadius = opn_fill_seam_radius(texel);
    float alpha = opn_fill_blend_alpha(uv, fill, feather);
    float w = opn_fill_seam_weight(uv, fill, seamRadius);
    // Sampling coordinate only. Every band measurement above is taken from the true
    // fragment position, so bending the image does not also bend the bands that decide
    // how it is mixed. Outside the bevel the offset is exactly zero.
    uv += float2(opn_glass_refraction(uv, fill, seamRadius), 0.0);
    float3 content = opn_i420_rgb(yTexture, uTexture, vTexture, s, uv);
    float3 result;
    if (alpha <= 0.0 && w <= 0.0) {
        result = content;
    } else if (alpha >= 1.0 && w <= 0.0) {
        result = opn_fill_outside(fillHistory, s, uv, in.texCoord, fill, fillColor);
    } else {
        float3 blur = (opn_i420_rgb(yTexture, uTexture, vTexture, s, opn_clamp_crop(uv + float2(texel.x, 0.0), crop)) + opn_i420_rgb(yTexture, uTexture, vTexture, s, opn_clamp_crop(uv + float2(0.0, texel.y), crop)) + opn_i420_rgb(yTexture, uTexture, vTexture, s, opn_clamp_crop(uv - float2(texel.x, 0.0), crop)) + opn_i420_rgb(yTexture, uTexture, vTexture, s, opn_clamp_crop(uv - float2(0.0, texel.y), crop))) * 0.25;
        float3 softened = mix(content, blur, min(alpha * 1.5, 1.0));
        float3 outside = opn_fill_outside(fillHistory, s, uv, in.texCoord, fill, fillColor);
        result = mix(softened, outside, alpha);
    }
    if (w > 0.0) {
        float3 acc = float3(0.0);
        float weightSum = 0.0;
        // Taps must land close enough together to resolve a one-pixel stroke, or the
        // kernel undersamples and thin high-contrast marks reappear as faint evenly
        // spaced replicas. `sigma = K/2` with `step = radius/K` holds the physical
        // blur width at radius/2 whatever K is, so K controls density alone. Spacing is
        // what matters, not the count: against the narrow radius above, 8 puts taps
        // roughly a texel apart — tighter than 16 managed over the old wide band.
        const int K = 8;
        const float sigma = float(K) * 0.5;
        float step = seamRadius / float(K);
        for (int t = -K; t <= K; ++t) {
            float ft = float(t);
            float weight = exp(-0.5 * (ft / sigma) * (ft / sigma));
            float2 tapUV = uv + float2(step * ft, 0.0);
            float tapAlpha = opn_fill_blend_alpha(tapUV, fill, feather);
            float3 tapColor = mix(opn_i420_rgb(yTexture, uTexture, vTexture, s, opn_clamp_crop(tapUV, crop)),
                                   opn_fill_outside_fast(fillHistory, s, tapUV, in.texCoord, fill, fillColor),
                                   tapAlpha);
            acc += tapColor * weight;
            weightSum += weight;
        }
        result = mix(result, acc / max(weightSum, 1e-4), w);
    }
    return float4(result, 1.0);
}
// Fill history pass. Renders the picture content into a small texture using a 4x4
// box so the huge downscale does not alias, and returns `emaAlpha` so the pipeline's
// blend state folds it into the previous frame: dst = a*src + (1-a)*dst.
//
// Two jobs in one: the low resolution is the blur, and the running average is what
// stops heavy blur over moving content from pulsing in peripheral vision.
static float3 opn_fill_history_box_rgb(texture2d<float> sourceTexture, sampler s, float2 uv, float2 boxStep) {
    float3 acc = float3(0.0);
    for (int y = 0; y < 4; ++y) {
        for (int x = 0; x < 4; ++x) {
            float2 offset = (float2((float)x, (float)y) - 1.5) * boxStep;
            acc += sourceTexture.sample(s, clamp(uv + offset, float2(0.0), float2(1.0))).rgb;
        }
    }
    return acc / 16.0;
}
fragment float4 opn_video_fill_history_rgb(VertexOut in [[stage_in]], texture2d<float> sourceTexture [[texture(0)]], constant float4 &fill [[buffer(0)]], constant float2 &boxStep [[buffer(1)]], constant float &emaAlpha [[buffer(2)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 t = clamp(in.texCoord, float2(0.0), float2(1.0));
    float2 uv = float2(mix(fill.x, fill.y, t.x), t.y);
    return float4(opn_fill_history_box_rgb(sourceTexture, s, uv, boxStep), emaAlpha);
}
fragment float4 opn_video_fill_history_nv12(VertexOut in [[stage_in]], texture2d<float> yTexture [[texture(0)]], texture2d<float> uvTexture [[texture(1)]], constant float4 &fill [[buffer(0)]], constant float2 &boxStep [[buffer(1)]], constant float &emaAlpha [[buffer(2)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 t = clamp(in.texCoord, float2(0.0), float2(1.0));
    float2 uv = float2(mix(fill.x, fill.y, t.x), t.y);
    float3 acc = float3(0.0);
    for (int y = 0; y < 4; ++y) {
        for (int x = 0; x < 4; ++x) {
            float2 offset = (float2((float)x, (float)y) - 1.5) * boxStep;
            acc += opn_nv12_rgb(yTexture, uvTexture, s, clamp(uv + offset, float2(0.0), float2(1.0)));
        }
    }
    return float4(acc / 16.0, emaAlpha);
}
fragment float4 opn_video_fill_history_i420(VertexOut in [[stage_in]], texture2d<float> yTexture [[texture(0)]], texture2d<float> uTexture [[texture(1)]], texture2d<float> vTexture [[texture(2)]], constant float4 &fill [[buffer(0)]], constant float2 &boxStep [[buffer(1)]], constant float &emaAlpha [[buffer(2)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 t = clamp(in.texCoord, float2(0.0), float2(1.0));
    float2 uv = float2(mix(fill.x, fill.y, t.x), t.y);
    float3 acc = float3(0.0);
    for (int y = 0; y < 4; ++y) {
        for (int x = 0; x < 4; ++x) {
            float2 offset = (float2((float)x, (float)y) - 1.5) * boxStep;
            acc += opn_i420_rgb(yTexture, uTexture, vTexture, s, clamp(uv + offset, float2(0.0), float2(1.0)));
        }
    }
    return float4(acc / 16.0, emaAlpha);
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
