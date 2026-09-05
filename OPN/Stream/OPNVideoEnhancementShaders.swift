//  The Metal shader source the enhancement renderer compiles at runtime. Kept apart from the
//  Swift that drives it so neither is buried in the other.
//

import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Metal
import MetalKit

extension OPNVideoTextureSource {
    /// The renderer compiles this at runtime, so a syntax error here surfaces as a failed
    /// pipeline at first frame rather than at build time.
    /// Compiled at runtime, so a mistake at the seam between the two halves surfaces as a failed
    /// pipeline at first frame rather than as a build error. The split falls between two complete
    /// functions; keep it there.
    static var spatialShaderSource: String { scalingShaderSource + "\n" + fillAndTemporalShaderSource }

    // Continues in OPNVideoEnhancementFillShaders.swift, from the fill-history pass onward.
    private static let scalingShaderSource = """
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
// YCbCr to RGB. `cm` carries the matrix (Cr->R, Cb->G, Cr->G, Cb->B) for the frame's tagged
// colour matrix (BT.709 / BT.2020 / BT.601), `cr` the code range as (luma offset, luma scale,
// chroma scale, 0) — identity for full range. The transfer function is left alone: for SDR the
// result is display-referred as before, for PQ/HLG the layer's colour space tells the
// compositor how to read the same numbers, so an HDR frame needs no shader-side tone map.
static float3 opn_ycbcr_rgb(float y, float2 cbcr, float4 cm, float4 cr) {
    y = (y - cr.x) * cr.y;
    cbcr = (cbcr - float2(0.5, 0.5)) * cr.z;
    return saturate(float3(y + cm.x * cbcr.y, y - cm.y * cbcr.x - cm.z * cbcr.y, y + cm.w * cbcr.x));
}
static float3 opn_nv12_rgb_cm(texture2d<float> yTexture, texture2d<float> uvTexture, sampler s, float2 uv, float4 cm, float4 cr) {
    return opn_ycbcr_rgb(yTexture.sample(s, uv).r, uvTexture.sample(s, uv).rg, cm, cr);
}
static float3 opn_i420_rgb_cm(texture2d<float> yTexture, texture2d<float> uTexture, texture2d<float> vTexture, sampler s, float2 uv, float4 cm, float4 cr) {
    return opn_ycbcr_rgb(yTexture.sample(s, uv).r, float2(uTexture.sample(s, uv).r, vTexture.sample(s, uv).r), cm, cr);
}
// Every fragment that samples YCbCr declares `cm` and `cr` as constant buffers; the macros bind
// those by name so the many sampling sites below stay as they were.
#define opn_nv12_rgb(Y, UV, S, COORD) opn_nv12_rgb_cm(Y, UV, S, COORD, cm, cr)
#define opn_i420_rgb(Y, U, V, S, COORD) opn_i420_rgb_cm(Y, U, V, S, COORD, cm, cr)
// Downscale-aware centre sample. A 5K stream drawn into a smaller window used to be one bilinear
// tap per output pixel, which reads two of every three source texels at 3:1 and aliases text
// and fine detail. `down` is source/destination texels per axis; above ~1 the four taps sit a
// quarter of the footprint out in each direction, so with each tap's own bilinear 2x2 the
// output pixel averages its whole footprint up to ~3:1. At 1:1 or when magnifying it is the
// plain sample it always was.
static float3 opn_box4_rgb(texture2d<float> t, sampler s, float2 uv, float2 texel, float2 down) {
    if (max(down.x, down.y) < 1.05) { return t.sample(s, uv).rgb; }
    float2 o = texel * down * 0.25;
    return (t.sample(s, uv + float2(-o.x, -o.y)).rgb + t.sample(s, uv + float2(o.x, -o.y)).rgb
          + t.sample(s, uv + float2(-o.x, o.y)).rgb + t.sample(s, uv + float2(o.x, o.y)).rgb) * 0.25;
}
static float3 opn_box4_nv12(texture2d<float> y, texture2d<float> uvT, sampler s, float2 uv, float2 texel, float2 down, float4 cm, float4 cr) {
    if (max(down.x, down.y) < 1.05) { return opn_nv12_rgb_cm(y, uvT, s, uv, cm, cr); }
    float2 o = texel * down * 0.25;
    return (opn_nv12_rgb_cm(y, uvT, s, uv + float2(-o.x, -o.y), cm, cr) + opn_nv12_rgb_cm(y, uvT, s, uv + float2(o.x, -o.y), cm, cr)
          + opn_nv12_rgb_cm(y, uvT, s, uv + float2(-o.x, o.y), cm, cr) + opn_nv12_rgb_cm(y, uvT, s, uv + float2(o.x, o.y), cm, cr)) * 0.25;
}
static float3 opn_box4_i420(texture2d<float> y, texture2d<float> u, texture2d<float> v, sampler s, float2 uv, float2 texel, float2 down, float4 cm, float4 cr) {
    if (max(down.x, down.y) < 1.05) { return opn_i420_rgb_cm(y, u, v, s, uv, cm, cr); }
    float2 o = texel * down * 0.25;
    return (opn_i420_rgb_cm(y, u, v, s, uv + float2(-o.x, -o.y), cm, cr) + opn_i420_rgb_cm(y, u, v, s, uv + float2(o.x, -o.y), cm, cr)
          + opn_i420_rgb_cm(y, u, v, s, uv + float2(-o.x, o.y), cm, cr) + opn_i420_rgb_cm(y, u, v, s, uv + float2(o.x, o.y), cm, cr)) * 0.25;
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
fragment float4 opn_video_spatial_rgb(VertexOut in [[stage_in]], texture2d<float> sourceTexture [[texture(0)]], texture2d<float> fillHistory [[texture(3)]], constant float2 &scale [[buffer(0)]], constant float &sharpness [[buffer(1)]], constant float &denoise [[buffer(2)]], constant float4 &crop [[buffer(3)]], constant float2 &jitter [[buffer(4)]], constant float4 &fill [[buffer(5)]], constant float4 &fillGeom [[buffer(6)]], constant float4 &fillColor [[buffer(7)]], constant float2 &downscale [[buffer(10)]]) {
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
        float3 center = opn_box4_rgb(sourceTexture, s, uv, texel, downscale);
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
fragment float4 opn_video_spatial_nv12(VertexOut in [[stage_in]], texture2d<float> yTexture [[texture(0)]], texture2d<float> uvTexture [[texture(1)]], texture2d<float> fillHistory [[texture(3)]], constant float2 &scale [[buffer(0)]], constant float &sharpness [[buffer(1)]], constant float &denoise [[buffer(2)]], constant float4 &crop [[buffer(3)]], constant float2 &jitter [[buffer(4)]], constant float4 &fill [[buffer(5)]], constant float4 &fillGeom [[buffer(6)]], constant float4 &fillColor [[buffer(7)]], constant float4 &cm [[buffer(8)]], constant float4 &cr [[buffer(9)]], constant float2 &downscale [[buffer(10)]]) {
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
        float3 center = opn_box4_nv12(yTexture, uvTexture, s, uv, texel, downscale, cm, cr);
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
fragment float4 opn_video_spatial_i420(VertexOut in [[stage_in]], texture2d<float> yTexture [[texture(0)]], texture2d<float> uTexture [[texture(1)]], texture2d<float> vTexture [[texture(2)]], texture2d<float> fillHistory [[texture(3)]], constant float2 &scale [[buffer(0)]], constant float &sharpness [[buffer(1)]], constant float &denoise [[buffer(2)]], constant float4 &crop [[buffer(3)]], constant float2 &jitter [[buffer(4)]], constant float4 &fill [[buffer(5)]], constant float4 &fillGeom [[buffer(6)]], constant float4 &fillColor [[buffer(7)]], constant float4 &cm [[buffer(8)]], constant float4 &cr [[buffer(9)]], constant float2 &downscale [[buffer(10)]]) {
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
        float3 center = opn_box4_i420(yTexture, uTexture, vTexture, s, uv, texel, downscale, cm, cr);
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
fragment float4 opn_video_fast_rgb(VertexOut in [[stage_in]], texture2d<float> sourceTexture [[texture(0)]], texture2d<float> fillHistory [[texture(3)]], constant float2 &scale [[buffer(0)]], constant float &sharpness [[buffer(1)]], constant float &denoise [[buffer(2)]], constant float4 &crop [[buffer(3)]], constant float2 &jitter [[buffer(4)]], constant float4 &fill [[buffer(5)]], constant float4 &fillGeom [[buffer(6)]], constant float4 &fillColor [[buffer(7)]], constant float2 &downscale [[buffer(10)]]) {
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
    float3 content = opn_box4_rgb(sourceTexture, s, uv, texel, downscale);
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
fragment float4 opn_video_fast_nv12(VertexOut in [[stage_in]], texture2d<float> yTexture [[texture(0)]], texture2d<float> uvTexture [[texture(1)]], texture2d<float> fillHistory [[texture(3)]], constant float2 &scale [[buffer(0)]], constant float &sharpness [[buffer(1)]], constant float &denoise [[buffer(2)]], constant float4 &crop [[buffer(3)]], constant float2 &jitter [[buffer(4)]], constant float4 &fill [[buffer(5)]], constant float4 &fillGeom [[buffer(6)]], constant float4 &fillColor [[buffer(7)]], constant float4 &cm [[buffer(8)]], constant float4 &cr [[buffer(9)]], constant float2 &downscale [[buffer(10)]]) {
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
    float3 content = opn_box4_nv12(yTexture, uvTexture, s, uv, texel, downscale, cm, cr);
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
fragment float4 opn_video_fast_i420(VertexOut in [[stage_in]], texture2d<float> yTexture [[texture(0)]], texture2d<float> uTexture [[texture(1)]], texture2d<float> vTexture [[texture(2)]], texture2d<float> fillHistory [[texture(3)]], constant float2 &scale [[buffer(0)]], constant float &sharpness [[buffer(1)]], constant float &denoise [[buffer(2)]], constant float4 &crop [[buffer(3)]], constant float2 &jitter [[buffer(4)]], constant float4 &fill [[buffer(5)]], constant float4 &fillGeom [[buffer(6)]], constant float4 &fillColor [[buffer(7)]], constant float4 &cm [[buffer(8)]], constant float4 &cr [[buffer(9)]], constant float2 &downscale [[buffer(10)]]) {
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
    float3 content = opn_box4_i420(yTexture, uTexture, vTexture, s, uv, texel, downscale, cm, cr);
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
"""
}
