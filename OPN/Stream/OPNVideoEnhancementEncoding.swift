//  The Metal encoding passes: the spatial scaler, the temporal motion/current passes, the
//  present blit, and the pillarbox fill history they sample. Split out of
//  OPNVideoEnhancementRenderer.swift.
//

import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Metal
import MetalKit
import QuartzCore
import WebRTC

extension OPNVideoEnhancementRenderer {
    func encodeSpatialTextureFrame(
        _ textureFrame: OPNVideoTextureFrame,
        destinationTexture: any MTLTexture,
        commandBuffer: any MTLCommandBuffer,
        settings: OPNVideoEnhancementSettings,
        result: OPNVideoEnhancementResult,
        jitter suppliedJitter: SIMD2<Float> = SIMD2<Float>(0, 0)
    ) -> Bool {
        let format = destinationTexture.pixelFormat
        let primaryTexture: (any MTLTexture)?
        let pipeline: (any MTLRenderPipelineState)?
        switch textureFrame.kind {
        case 1:
            primaryTexture = textureFrame.lumaTexture
            pipeline = (settings.lowCostSpatial ? outputPipeline("opn_video_fast_nv12", format: format) : nil) ?? outputPipeline("opn_video_spatial_nv12", format: format)
        case 2:
            primaryTexture = textureFrame.lumaTexture
            pipeline = (settings.lowCostSpatial ? outputPipeline("opn_video_fast_i420", format: format) : nil) ?? outputPipeline("opn_video_spatial_i420", format: format)
        default:
            primaryTexture = textureFrame.rgbTexture
            pipeline = (settings.lowCostSpatial ? outputPipeline("opn_video_fast_rgb", format: format) : nil) ?? outputPipeline("opn_video_spatial_rgb", format: format)
        }
        guard let primaryTexture, let pipeline else {
            result.fallbackReason = "spatial scaler missing texture or pipeline for \(format.rawValue)"
            return false
        }

        var uniforms = spatialUniforms(textureFrame, settings: settings, primaryTexture: primaryTexture, jitter: suppliedJitter)
        // The history pass owns its own encoder, so it has to finish before the main pass opens
        // one. Modes that never read the history skip it entirely, and `fill.w` is 0 whenever
        // `pillarboxUniforms` disabled the effect.
        var fillHistory: (any MTLTexture)?
        if OPNPillarboxFillMode.from(settings.pillarboxFillMode).usesDim, uniforms.fill.w > 0.5 {
            fillHistory = encodeFillHistory(textureFrame, commandBuffer: commandBuffer, contentRect: pillarboxDetector.contentRect)
            // No history means no spill to draw; fall back to leaving the bars as encoded rather
            // than sampling an unbound texture.
            if fillHistory == nil { uniforms.fill.w = 0 }
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = destinationTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            result.fallbackReason = "spatial scaler could not create encoder"
            return false
        }

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(primaryTexture, index: 0)
        if textureFrame.kind == 1 { encoder.setFragmentTexture(textureFrame.chromaTexture, index: 1) }
        if textureFrame.kind == 2 {
            encoder.setFragmentTexture(textureFrame.chromaUTexture, index: 1)
            encoder.setFragmentTexture(textureFrame.chromaVTexture, index: 2)
        }
        // Always bound, even when unused: the shaders declare the binding, and Metal
        // validation objects to a declared texture being left unset.
        encoder.setFragmentTexture(fillHistory ?? primaryTexture, index: 3)
        encoder.setFragmentBytes(&uniforms.texel, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
        encoder.setFragmentBytes(&uniforms.sharpness, length: MemoryLayout<Float>.size, index: 1)
        encoder.setFragmentBytes(&uniforms.denoise, length: MemoryLayout<Float>.size, index: 2)
        encoder.setFragmentBytes(&uniforms.crop, length: MemoryLayout<SIMD4<Float>>.size, index: 3)
        encoder.setFragmentBytes(&uniforms.jitter, length: MemoryLayout<SIMD2<Float>>.size, index: 4)
        encoder.setFragmentBytes(&uniforms.fill, length: MemoryLayout<SIMD4<Float>>.size, index: 5)
        encoder.setFragmentBytes(&uniforms.fillGeometry, length: MemoryLayout<SIMD4<Float>>.size, index: 6)
        encoder.setFragmentBytes(&uniforms.fillColor, length: MemoryLayout<SIMD4<Float>>.size, index: 7)
        var colorMatrix = Self.colorMatrixCoefficients(textureFrame)
        var colorRange = Self.colorRangeCoefficients(textureFrame)
        encoder.setFragmentBytes(&colorMatrix, length: MemoryLayout<SIMD4<Float>>.size, index: 8)
        encoder.setFragmentBytes(&colorRange, length: MemoryLayout<SIMD4<Float>>.size, index: 9)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }

    /// The YCbCr→RGB coefficients for this frame's tagged matrix. BT.709 unless the buffer says
    /// otherwise — an HDR stream arrives tagged BT.2020 and would render with visibly wrong hues
    /// through the 709 numbers the shaders used to hardcode.
    static func colorMatrixCoefficients(_ textureFrame: OPNVideoTextureFrame) -> SIMD4<Float> {
        (OPNVideoColorMatrix(rawValue: textureFrame.colorMatrix) ?? .bt709).coefficients
    }

    /// (luma offset, luma scale, chroma scale, 0). Identity for full-range planes; the standard
    /// 16-235 / 16-240 expansion for video range. The 10-bit surfaces store their samples in the
    /// high bits of 16, so the normalised offsets are the same fractions as for 8 bits.
    static func colorRangeCoefficients(_ textureFrame: OPNVideoTextureFrame) -> SIMD4<Float> {
        textureFrame.isFullRange
            ? SIMD4<Float>(0, 1, 1, 0)
            : SIMD4<Float>(16.0 / 255.0, 255.0 / 219.0, 255.0 / 224.0, 0)
    }

    /// Everything the spatial fragment shader is fed for one frame.
    struct SpatialUniforms {
        var texel = SIMD2<Float>(0, 0)
        var sharpness: Float = 0
        var denoise: Float = 0
        var crop = SIMD4<Float>(0, 0, 1, 1)
        var jitter = SIMD2<Float>(0, 0)
        var fill = SIMD4<Float>(0, 0, 0, 0)
        var fillGeometry = SIMD4<Float>(0, 0, 0, 0)
        var fillColor = SIMD4<Float>(0, 0, 0, 0)
    }

    func spatialUniforms(_ textureFrame: OPNVideoTextureFrame,
                                 settings: OPNVideoEnhancementSettings,
                                 primaryTexture: any MTLTexture,
                                 jitter suppliedJitter: SIMD2<Float>) -> SpatialUniforms {
        let texel = SIMD2<Float>(primaryTexture.width > 0 ? 1.0 / Float(primaryTexture.width) : 0, primaryTexture.height > 0 ? 1.0 / Float(primaryTexture.height) : 0)
        let sharpness = min(max(Float(settings.sharpness) / 10.0, 0), 4)
        let denoise = min(max((Float(settings.denoise) / 10.0) * 0.65, 0), 1)
        let cropRect = textureFrame.cropRect.width > 0 && textureFrame.cropRect.height > 0 ? textureFrame.cropRect : CGRect(x: 0, y: 0, width: 1, height: 1)
        let minX = min(max(Float(cropRect.minX), 0), 1)
        let minY = min(max(Float(cropRect.minY), 0), 1)
        let maxX = min(max(Float(cropRect.maxX), 0), 1)
        let maxY = min(max(Float(cropRect.maxY), 0), 1)
        let crop = maxX > minX && maxY > minY ? SIMD4<Float>(minX, minY, maxX, maxY) : SIMD4<Float>(0, 0, 1, 1)
        let jitter = suppliedJitter
        // One line whenever the fill mode or the measured bar geometry changes. The fill is easy to
        // get silently wrong — a stale mode, or a detector that never finds the bars — and neither
        // shows up as an error, so state it explicitly.
        let fillModeNow = OPNPillarboxFillMode.from(settings.pillarboxFillMode)
        let contentNow = pillarboxDetector.contentRect
        if fillModeNow != lastLoggedFillMode || contentNow != lastLoggedContentRect {
            lastLoggedFillMode = fillModeNow
            lastLoggedContentRect = contentNow
            OpenNOWLog.info(.stream, "Pillarbox fill mode=\(fillModeNow.label) content=[\(String(format: "%.4f", contentNow.left)), \(String(format: "%.4f", contentNow.right))] source=\(primaryTexture.width)x\(primaryTexture.height)")
        }
        let uniforms = Self.pillarboxUniforms(
            mode: OPNPillarboxFillMode.from(settings.pillarboxFillMode),
            contentRect: pillarboxDetector.contentRect,
            codecCropIsIdentity: minX <= 0.0001 && minY <= 0.0001 && maxX >= 0.9999 && maxY >= 0.9999,
            sourceSize: CGSize(width: primaryTexture.width, height: primaryTexture.height),
            drawableSize: settings.drawableSize,
            dim: settings.pillarboxFillDim,
            packedColor: settings.pillarboxFillColor
        )
        let fill = uniforms.fill
        let fillGeom = uniforms.geometry
        let fillColor = uniforms.color
        return SpatialUniforms(texel: texel,
                               sharpness: sharpness,
                               denoise: denoise,
                               crop: crop,
                               jitter: jitter,
                               fill: fill,
                               fillGeometry: fillGeom,
                               fillColor: fillColor)
    }

    func encodeTemporalMotionTexture(
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

    func encodeTemporalCurrentTexture(
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
        let sharpnessScale = min(max(Float(settings.sharpness) / 15.0, 0), 1)
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

    func encodePresentTexture(
        sourceTexture: any MTLTexture,
        destinationTexture: any MTLTexture,
        commandBuffer: any MTLCommandBuffer,
        result: OPNVideoEnhancementResult
    ) -> Bool {
        guard let presentPipeline = outputPipeline("opn_video_present_rgb", format: destinationTexture.pixelFormat) else {
            result.fallbackReason = "present pipeline unavailable for drawable format \(destinationTexture.pixelFormat.rawValue)"
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
        encoder.setRenderPipelineState(presentPipeline)
        encoder.setFragmentTexture(sourceTexture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }

    func newSpatialPipeline(fragmentFunctionName: String, pixelFormat: MTLPixelFormat = renderTargetPixelFormat) -> (any MTLRenderPipelineState)? {
        guard let device, let shaderLibrary else { return nil }
        do {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = shaderLibrary.makeFunction(name: "opn_video_vertex")
            descriptor.fragmentFunction = shaderLibrary.makeFunction(name: fragmentFunctionName)
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            WebRTCMediaTelemetry.capture("webrtc.native.video_enhancement.pipeline.error", level: .warning, message: "Spatial enhancement pipeline failed.", attributes: ["function": fragmentFunctionName, "error": error.localizedDescription])
            return nil
        }
    }

    /// Like `newSpatialPipeline`, but with blending configured so the fragment's
    /// alpha acts as the EMA weight: dst = a*src + (1-a)*dst.
    func newFillHistoryPipeline(fragmentFunctionName: String) -> (any MTLRenderPipelineState)? {
        guard let device, let shaderLibrary else { return nil }
        do {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = shaderLibrary.makeFunction(name: "opn_video_vertex")
            descriptor.fragmentFunction = shaderLibrary.makeFunction(name: fragmentFunctionName)
            descriptor.colorAttachments[0].pixelFormat = Self.renderTargetPixelFormat
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].rgbBlendOperation = .add
            descriptor.colorAttachments[0].alphaBlendOperation = .add
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .zero
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            WebRTCMediaTelemetry.capture("webrtc.native.video_enhancement.pipeline.error", level: .warning, message: "Pillarbox fill history pipeline failed.", attributes: ["function": fragmentFunctionName, "error": error.localizedDescription])
            return nil
        }
    }

    /// Renders the picture content into the small history texture, blending it into
    /// the running average. Returns the texture to sample, or nil if unavailable.
    func encodeFillHistory(
        _ textureFrame: OPNVideoTextureFrame,
        commandBuffer: any MTLCommandBuffer,
        contentRect: OPNPillarboxContentRect
    ) -> (any MTLTexture)? {
        let previous = fillHistoryTexture
        guard let texture = reusableTexture(
            &fillHistoryTexture,
            width: Self.fillHistoryWidth,
            height: Self.fillHistoryHeight,
            pixelFormat: Self.renderTargetPixelFormat,
            usage: [.shaderRead, .renderTarget],
            label: "OpenNOW pillarbox fill history"
        ) else { return nil }

        // A reallocated texture holds garbage, and a moved content edge means the
        // stored average now describes a different crop. Either way, restart it.
        if previous !== texture || contentRect != fillHistoryContentRect {
            fillHistoryPrimed = false
            fillHistoryContentRect = contentRect
        }

        guard encodeContentDownsample(
            textureFrame,
            commandBuffer: commandBuffer,
            contentRect: contentRect,
            target: texture,
            emaAlpha: fillHistoryPrimed ? Self.fillHistoryEMAAlpha : 1.0,
            loadAction: fillHistoryPrimed ? .load : .clear
        ) else { return nil }

        fillHistoryPrimed = true
        return texture
    }

    /// Renders the picture content into `target`, mapping the content span across the
    /// full [0,1] of the destination. With `emaAlpha` below 1 the pipeline's blend
    /// state folds the result into whatever the target already holds.
    func encodeContentDownsample(
        _ textureFrame: OPNVideoTextureFrame,
        commandBuffer: any MTLCommandBuffer,
        contentRect: OPNPillarboxContentRect,
        target: any MTLTexture,
        emaAlpha: Float,
        loadAction: MTLLoadAction
    ) -> Bool {
        let pipeline: (any MTLRenderPipelineState)?
        let primaryTexture: (any MTLTexture)?
        switch textureFrame.kind {
        case 1: pipeline = fillHistoryNV12Pipeline; primaryTexture = textureFrame.lumaTexture
        case 2: pipeline = fillHistoryI420Pipeline; primaryTexture = textureFrame.lumaTexture
        default: pipeline = fillHistoryRGBPipeline; primaryTexture = textureFrame.rgbTexture
        }
        guard let pipeline, let primaryTexture else { return false }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = loadAction
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }

        // Same trimmed span the sampling pass uses. Reading the untrimmed one here would
        // box-blur the encoder's darkened edge columns straight into the outermost texels
        // of the history — the very texels the bars mirror against the seam.
        let (contentLeft, contentRight) = Self.pillarboxInsetSpan(
            contentRect: contentRect,
            sourceWidth: Double(primaryTexture.width)
        )
        var fill = SIMD4<Float>(Float(contentLeft), Float(contentRight), 0, 0)
        // Spread the 4x4 box across one destination texel's worth of source.
        var boxStep = SIMD2<Float>(
            Float(contentRight - contentLeft) / Float(target.width) / 3.0,
            1.0 / Float(target.height) / 3.0
        )
        var alpha = emaAlpha

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(primaryTexture, index: 0)
        if textureFrame.kind == 1 { encoder.setFragmentTexture(textureFrame.chromaTexture, index: 1) }
        if textureFrame.kind == 2 {
            encoder.setFragmentTexture(textureFrame.chromaUTexture, index: 1)
            encoder.setFragmentTexture(textureFrame.chromaVTexture, index: 2)
        }
        encoder.setFragmentBytes(&fill, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.setFragmentBytes(&boxStep, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
        encoder.setFragmentBytes(&alpha, length: MemoryLayout<Float>.size, index: 2)
        var colorMatrix = Self.colorMatrixCoefficients(textureFrame)
        var colorRange = Self.colorRangeCoefficients(textureFrame)
        encoder.setFragmentBytes(&colorMatrix, length: MemoryLayout<SIMD4<Float>>.size, index: 3)
        encoder.setFragmentBytes(&colorRange, length: MemoryLayout<SIMD4<Float>>.size, index: 4)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }


    static func makeShaderLibrary(device: (any MTLDevice)?) -> (any MTLLibrary)? {
        guard let device else { return nil }
        do {
            return try device.makeLibrary(source: OPNVideoTextureSource.spatialShaderSource, options: nil)
        } catch {
            WebRTCMediaTelemetry.capture("webrtc.native.video_enhancement.library.error", level: .warning, message: "Spatial enhancement shader library failed.", attributes: ["error": error.localizedDescription])
            return nil
        }
    }
}
