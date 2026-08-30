//
//  OPNVideoEnhancementFillShaders.swift
//  OpenNOW
//
//  The second half of the runtime Metal source: the pillarbox fill history, the temporal
//  passes and the present blit. Concatenated onto OPNVideoEnhancementShaders.swift's half.
//

import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Metal
import MetalKit

extension OPNVideoTextureSource {
    // Continued from OPNVideoEnhancementShaders.swift; this half is appended to that one.
    static let fillAndTemporalShaderSource = """
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
