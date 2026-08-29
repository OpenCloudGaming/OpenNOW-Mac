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
    /// Raw value of `OPNPillarboxFillMode`; how to treat baked-in pillarbox columns.
    @objc var pillarboxFillMode = 0
    /// Brightness of the fill at the window edge, relative to the sampled source.
    @objc var pillarboxFillDim: Float = 0.55
    /// Packed 0xRRGGBB, used by the solid-colour mode.
    @objc var pillarboxFillColor: Int32 = 0
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


@objc(OPNVideoEnhancementRenderer)
@MainActor
final class OPNVideoEnhancementRenderer: NSObject {
    private static let renderTargetPixelFormat: MTLPixelFormat = .bgra8Unorm

    /// Resolution of the pillarbox fill history. Deliberately tiny: the downscale is
    /// what produces the blur, so sampling it back with linear filtering costs one
    /// fetch instead of a wide multi-tap kernel over a quarter of the screen.
    private static let fillHistoryWidth = 160
    private static let fillHistoryHeight = 90
    /// Weight of the current frame in the running average. ~0.12 settles in about
    /// eight frames, enough to stop heavy blur pulsing without visible smearing.
    private static let fillHistoryEMAAlpha: Float = 0.12


    private let device: (any MTLDevice)?
    private let commandQueue: (any MTLCommandQueue)?
    private let ciContext: CIContext?
    private let outputColorSpace = CGColorSpaceCreateDeviceRGB()
    private let metalFXUpscaler: OPNMetalFXUpscaler
    private let textureSource: OPNVideoTextureSource
    private let shaderLibrary: (any MTLLibrary)?
    private var metalFXIntermediateTexture: (any MTLTexture)?
    private var metalFXOutputTexture: (any MTLTexture)?
    private var spatialRGBPipeline: (any MTLRenderPipelineState)?
    private var spatialNV12Pipeline: (any MTLRenderPipelineState)?
    private var spatialI420Pipeline: (any MTLRenderPipelineState)?
    private var fastSpatialRGBPipeline: (any MTLRenderPipelineState)?
    private var fastSpatialNV12Pipeline: (any MTLRenderPipelineState)?
    private var fastSpatialI420Pipeline: (any MTLRenderPipelineState)?
    private let pillarboxDetector = OPNPillarboxDetector()
    private var lastLoggedFillMode: OPNPillarboxFillMode?
    private var lastLoggedContentRect: OPNPillarboxContentRect?
    private var fillHistoryRGBPipeline: (any MTLRenderPipelineState)?
    private var fillHistoryNV12Pipeline: (any MTLRenderPipelineState)?
    private var fillHistoryI420Pipeline: (any MTLRenderPipelineState)?
    private var fillHistoryTexture: (any MTLTexture)?
    /// False until the history texture holds a real frame, so the first pass after
    /// (re)allocation replaces rather than blends into uninitialised contents.
    private var fillHistoryPrimed = false
    private var fillHistoryContentRect = OPNPillarboxContentRect.full
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
    private var enhancedPixelBufferPool: CVPixelBufferPool?
    private var enhancedPixelBufferPoolWidth = 0
    private var enhancedPixelBufferPoolHeight = 0
    private let i420BGRAConverter = WebRTCI420BGRAConverter()
    private var i420PixelBufferPool: CVPixelBufferPool?
    private var i420PixelBufferPoolWidth = 0
    private var i420PixelBufferPoolHeight = 0

    @objc init(device: (any MTLDevice)?, commandQueue: (any MTLCommandQueue)?) {
        self.device = device
        self.commandQueue = commandQueue
        self.ciContext = device.map { CIContext(mtlDevice: $0, options: [.workingColorSpace: NSNull()]) }
        self.metalFXUpscaler = OPNMetalFXUpscaler(device: device)
        self.textureSource = OPNVideoTextureSource(device: device)
        self.shaderLibrary = Self.makeShaderLibrary(device: device)
        super.init()
        spatialRGBPipeline = newSpatialPipeline(fragmentFunctionName: "opn_video_spatial_rgb")
        spatialNV12Pipeline = newSpatialPipeline(fragmentFunctionName: "opn_video_spatial_nv12")
        spatialI420Pipeline = newSpatialPipeline(fragmentFunctionName: "opn_video_spatial_i420")
        fastSpatialRGBPipeline = newSpatialPipeline(fragmentFunctionName: "opn_video_fast_rgb")
        fastSpatialNV12Pipeline = newSpatialPipeline(fragmentFunctionName: "opn_video_fast_nv12")
        fastSpatialI420Pipeline = newSpatialPipeline(fragmentFunctionName: "opn_video_fast_i420")
        fillHistoryRGBPipeline = newFillHistoryPipeline(fragmentFunctionName: "opn_video_fill_history_rgb")
        fillHistoryNV12Pipeline = newFillHistoryPipeline(fragmentFunctionName: "opn_video_fill_history_nv12")
        fillHistoryI420Pipeline = newFillHistoryPipeline(fragmentFunctionName: "opn_video_fill_history_i420")
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

        let fillMode = OPNPillarboxFillMode.from(settings.pillarboxFillMode)
        if fillMode != .black, let cvBuffer = frame.buffer as? RTCCVPixelBuffer {
            pillarboxDetector.update(with: cvBuffer.pixelBuffer)
        } else if fillMode == .black, !pillarboxDetector.contentRect.isFull {
            pillarboxDetector.reset()
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
        guard let sourceTexture = reusableTexture(&metalFXIntermediateTexture, width: sourceWidth, height: sourceHeight, pixelFormat: Self.renderTargetPixelFormat, usage: [.shaderRead, .renderTarget], label: "OpenNOW MetalFX source"),
              let outputTexture = reusableTexture(&metalFXOutputTexture, width: outputWidth, height: outputHeight, pixelFormat: Self.renderTargetPixelFormat, usage: [.shaderRead, .shaderWrite, .renderTarget], label: "OpenNOW MetalFX output") else {
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
        guard let outputTexture = reusableTexture(&metalFXOutputTexture, width: outputWidth, height: outputHeight, pixelFormat: Self.renderTargetPixelFormat, usage: [.shaderRead, .shaderWrite, .renderTarget], label: "OpenNOW MetalFX output") else {
            result.fallbackReason = "MetalFX output texture allocation failed"
            return false
        }

        let primaryTexture = textureFrame.rgbTexture ?? textureFrame.lumaTexture
        guard let primaryTexture else { return false }
        let width = Int(textureFrame.contentWidth) > 0 ? Int(textureFrame.contentWidth) : primaryTexture.width
        let height = Int(textureFrame.contentHeight) > 0 ? Int(textureFrame.contentHeight) : primaryTexture.height
        guard let sourceTexture = reusableTexture(&metalFXIntermediateTexture, width: width, height: height, pixelFormat: Self.renderTargetPixelFormat, usage: [.renderTarget, .shaderRead], label: "OpenNOW MetalFX source intermediate") else {
            result.fallbackReason = "MetalFX intermediate texture allocation failed"
            return false
        }
        guard encodeSpatialTextureFrame(textureFrame, destinationTexture: sourceTexture, commandBuffer: commandBuffer, settings: settings, result: result) else {
            result.fallbackReason = "MetalFX RGB conversion failed"
            return false
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
        result.diagnostics = "Swift MetalFX spatial scaler with controlled source staging"
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
        guard let currentTexture = reusableTexture(&temporalCurrentTexture, width: width, height: height, pixelFormat: Self.renderTargetPixelFormat, usage: [.renderTarget, .shaderRead], label: "OpenNOW temporal current"),
              let outputTexture = reusableTexture(&temporalOutputTexture, width: width, height: height, pixelFormat: Self.renderTargetPixelFormat, usage: [.renderTarget, .shaderRead], label: "OpenNOW temporal output"),
              let historyTexture = reusableTexture(&temporalHistoryTexture, width: width, height: height, pixelFormat: Self.renderTargetPixelFormat, usage: [.renderTarget, .shaderRead], label: "OpenNOW temporal history"),
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

    /// Picture columns discarded at each content edge before anything samples there.
    ///
    /// The encoder does not hand over a clean step between the baked black bars and the
    /// picture: chroma subsampling and ringing around that high-contrast boundary darken
    /// the outermost few picture columns, so the edge of the content arrives already part
    /// black. Drawing those columns puts a thin black line at the seam that no amount of
    /// blending removes — the darkness is in the source pixels, not in the join, and blur
    /// only spreads it thinner and wider. Discarding them leaves nothing to hide, which
    /// is what lets the seam blend stay narrow instead of smearing a broad band.
    ///
    /// Four columns covers 4:2:0 chroma siting plus the ringing of one DCT block. The
    /// cost is under a third of a percent of picture width.
    static let pillarboxEdgeInsetColumns = 4.0

    /// The content span with ``pillarboxEdgeInsetColumns`` trimmed from each side.
    ///
    /// Every pass that reads the picture has to agree on this span exactly. The bars
    /// mirror the picture about these edges, so a span that disagreed between the fill
    /// history and the pass that samples it would slide the reflection sideways and put
    /// back the visible join the trim exists to remove.
    static func pillarboxInsetSpan(
        contentRect: OPNPillarboxContentRect,
        sourceWidth: Double
    ) -> (left: Double, right: Double) {
        guard sourceWidth > 0 else { return (contentRect.left, contentRect.right) }
        let inset = pillarboxEdgeInsetColumns / sourceWidth
        let left = min(contentRect.left + inset, contentRect.right)
        let right = max(contentRect.right - inset, left)
        return (left, right)
    }

    /// Builds the three pillarbox fragment uniforms.
    ///
    /// Pure so the geometry can be tested without a GPU. Returns a disabled set
    /// (mode 0) whenever fill cannot be drawn correctly, which keeps every caller
    /// from having to repeat the same guards.
    static func pillarboxUniforms(
        mode: OPNPillarboxFillMode,
        contentRect: OPNPillarboxContentRect,
        codecCropIsIdentity: Bool,
        sourceSize: CGSize,
        drawableSize: CGSize,
        dim: Float,
        packedColor: Int32
    ) -> (fill: SIMD4<Float>, geometry: SIMD4<Float>, color: SIMD4<Float>) {
        let clampedDim = min(max(dim, 0), 1)
        let disabled = (
            fill: SIMD4<Float>(0, 1, clampedDim, 0),
            geometry: SIMD4<Float>(1, 1, 0, 0),
            color: SIMD4<Float>(0, 0, 0, 1)
        )

        // The detector measures against the full pixel buffer, so a non-identity
        // codec crop would shift the content edges out from under these numbers.
        guard mode != .black, !contentRect.isFull, codecCropIsIdentity,
              sourceSize.width > 0, sourceSize.height > 0,
              drawableSize.width > 0, drawableSize.height > 0 else {
            return disabled
        }

        let (contentLeft, contentRight) = Self.pillarboxInsetSpan(
            contentRect: contentRect,
            sourceWidth: Double(sourceSize.width)
        )
        let contentWidth = contentRight - contentLeft
        guard contentWidth > 0 else { return disabled }

        let contentAspect = contentWidth * Double(sourceSize.width) / Double(sourceSize.height)
        let windowAspect = Double(drawableSize.width) / Double(drawableSize.height)
        guard contentAspect > 0, windowAspect > 0 else { return disabled }

        // Fraction of source height still visible once the picture is scaled to fill
        // the width. Above 1 would mean sampling past the frame, so cap at no crop.
        let cropScaleY = min(max(contentAspect / windowAspect, 0.05), 1.0)

        // Centre slope of the stretch cubic. The curve stays monotonic only while
        // k <= 1.5 (its edge slope is 3 - 2k), so wider-than-1.5x stretches give up
        // some centre fidelity rather than folding the image back on itself.
        let stretchK = min(max(windowAspect / contentAspect, 1.0), 1.5)

        let red = Float((packedColor >> 16) & 0xFF) / 255.0
        let green = Float((packedColor >> 8) & 0xFF) / 255.0
        let blue = Float(packedColor & 0xFF) / 255.0

        return (
            fill: SIMD4<Float>(Float(contentLeft), Float(contentRight), clampedDim, Float(mode.rawValue)),
            geometry: SIMD4<Float>(Float(cropScaleY), Float(stretchK), 0, 0),
            color: SIMD4<Float>(red, green, blue, 1)
        )
    }

    private func encodeSpatialTextureFrame(
        _ textureFrame: OPNVideoTextureFrame,
        destinationTexture: any MTLTexture,
        commandBuffer: any MTLCommandBuffer,
        settings: OPNVideoEnhancementSettings,
        result: OPNVideoEnhancementResult,
        jitter suppliedJitter: SIMD2<Float> = SIMD2<Float>(0, 0)
    ) -> Bool {
        guard destinationTexture.pixelFormat == Self.renderTargetPixelFormat else {
            result.fallbackReason = "spatial scaler drawable format unsupported"
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
        var fill = uniforms.fill
        var fillGeom = uniforms.geometry
        var fillColor = uniforms.color

        // The history pass owns its own encoder, so it has to finish before the main
        // pass opens one. Modes that never read the history skip it entirely.
        let activeFillMode = OPNPillarboxFillMode.from(settings.pillarboxFillMode)
        var fillHistory: (any MTLTexture)? = nil
        // fill.w is 0 whenever pillarboxUniforms disabled the effect.
        if activeFillMode.usesDim, uniforms.fill.w > 0.5 {
            fillHistory = encodeFillHistory(textureFrame, commandBuffer: commandBuffer, contentRect: pillarboxDetector.contentRect)
            if fillHistory == nil {
                // No history means no spill to draw; fall back to leaving the bars as
                // encoded rather than sampling an unbound texture.
                fill.w = 0
            }
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
        encoder.setFragmentBytes(&texel, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
        encoder.setFragmentBytes(&sharpness, length: MemoryLayout<Float>.size, index: 1)
        encoder.setFragmentBytes(&denoise, length: MemoryLayout<Float>.size, index: 2)
        encoder.setFragmentBytes(&crop, length: MemoryLayout<SIMD4<Float>>.size, index: 3)
        encoder.setFragmentBytes(&jitter, length: MemoryLayout<SIMD2<Float>>.size, index: 4)
        encoder.setFragmentBytes(&fill, length: MemoryLayout<SIMD4<Float>>.size, index: 5)
        encoder.setFragmentBytes(&fillGeom, length: MemoryLayout<SIMD4<Float>>.size, index: 6)
        encoder.setFragmentBytes(&fillColor, length: MemoryLayout<SIMD4<Float>>.size, index: 7)
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

    private func encodePresentTexture(
        sourceTexture: any MTLTexture,
        destinationTexture: any MTLTexture,
        commandBuffer: any MTLCommandBuffer,
        result: OPNVideoEnhancementResult
    ) -> Bool {
        guard destinationTexture.pixelFormat == Self.renderTargetPixelFormat else {
            result.fallbackReason = "present drawable format unsupported"
            return false
        }
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

    private func newSpatialPipeline(fragmentFunctionName: String, pixelFormat: MTLPixelFormat = renderTargetPixelFormat) -> (any MTLRenderPipelineState)? {
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
    private func newFillHistoryPipeline(fragmentFunctionName: String) -> (any MTLRenderPipelineState)? {
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
    private func encodeFillHistory(
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
    private func encodeContentDownsample(
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
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }


    private static func makeShaderLibrary(device: (any MTLDevice)?) -> (any MTLLibrary)? {
        guard let device else { return nil }
        do {
            return try device.makeLibrary(source: OPNVideoTextureSource.spatialShaderSource, options: nil)
        } catch {
            WebRTCMediaTelemetry.capture("webrtc.native.video_enhancement.library.error", level: .warning, message: "Spatial enhancement shader library failed.", attributes: ["error": error.localizedDescription])
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
        if texture == nil || texture?.width != width || texture?.height != height || texture?.pixelFormat != pixelFormat || texture?.usage.isSuperset(of: usage) != true {
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
        let pool = enhancedPixelBufferPool(width: width, height: height)
        var pixelBuffer: CVPixelBuffer?
        guard let pool,
              CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { return nil }
        context.render(image, to: pixelBuffer, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: outputColorSpace)
        return pixelBuffer
    }

    private func enhancedPixelBufferPool(width: Int, height: Int) -> CVPixelBufferPool? {
        if enhancedPixelBufferPool != nil, enhancedPixelBufferPoolWidth == width, enhancedPixelBufferPoolHeight == height {
            return enhancedPixelBufferPool
        }
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 3,
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as CFDictionary, attributes as CFDictionary, &pool) == kCVReturnSuccess else { return nil }
        enhancedPixelBufferPool = pool
        enhancedPixelBufferPoolWidth = width
        enhancedPixelBufferPoolHeight = height
        return pool
    }

    private func newBGRAFramebuffer(from i420: RTCI420Buffer) -> CVPixelBuffer? {
        let width = Int(i420.width)
        let height = Int(i420.height)
        guard width > 0, height > 0 else { return nil }
        let pool = i420BGRAFramebufferPool(width: width, height: height)
        var pixelBuffer: CVPixelBuffer?
        guard let pool,
              CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { return nil }
        return i420BGRAConverter.copy(i420, toBGRAOutput: pixelBuffer) ? pixelBuffer : nil
    }

    private func i420BGRAFramebufferPool(width: Int, height: Int) -> CVPixelBufferPool? {
        if i420PixelBufferPool != nil, i420PixelBufferPoolWidth == width, i420PixelBufferPoolHeight == height {
            return i420PixelBufferPool
        }
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 3,
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as CFDictionary, attributes as CFDictionary, &pool) == kCVReturnSuccess else { return nil }
        i420PixelBufferPool = pool
        i420PixelBufferPoolWidth = width
        i420PixelBufferPoolHeight = height
        return pool
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

    private static func temporalJitter(frameIndex: Int) -> SIMD2<Float> {
        temporalJitterOffsets[frameIndex % temporalJitterOffsets.count]
    }

    private static let temporalJitterOffsets: [SIMD2<Float>] = [
        SIMD2<Float>(-0.375, -0.125),
        SIMD2<Float>(0.125, 0.375),
        SIMD2<Float>(-0.125, -0.375),
        SIMD2<Float>(0.375, 0.125),
        SIMD2<Float>(-0.3125, 0.3125),
        SIMD2<Float>(0.1875, -0.1875),
        SIMD2<Float>(-0.1875, 0.1875),
        SIMD2<Float>(0.3125, -0.3125),
    ]

    private static func textureFrameUsesFullCrop(_ textureFrame: OPNVideoTextureFrame) -> Bool {
        let crop = textureFrame.cropRect
        return crop.minX <= 0.0001 && crop.minY <= 0.0001 && crop.width >= 0.9999 && crop.height >= 0.9999
    }

    private static func frameBufferClassName(_ buffer: any RTCVideoFrameBuffer) -> NSString {
        NSStringFromClass(type(of: buffer) as AnyClass) as NSString
    }
}
