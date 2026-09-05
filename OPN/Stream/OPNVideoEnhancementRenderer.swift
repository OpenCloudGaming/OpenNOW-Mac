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
    /// `OPNVideoColorMatrix` raw value: which YCbCr matrix the planes were encoded with.
    @objc var colorMatrix = 0
    /// `OPNVideoTransferFunction` raw value: SDR, PQ or HLG. The shaders pass the signal through
    /// untouched either way; the layer's colour space is what tells the compositor how to read it.
    @objc var transferFunction = 0
    /// Whether luma/chroma use the full code range. Every surface this app's own decoder asks for
    /// is full range; a video-range buffer is expanded in the shader.
    @objc var isFullRange = true
}

/// YCbCr-to-RGB matrix families, as tagged on a decoded `CVPixelBuffer`.
enum OPNVideoColorMatrix: Int {
    case bt709 = 0
    case bt2020 = 1
    case bt601 = 2

    /// (Cr→R, Cb→G, Cr→G, Cb→B) for full-range input, from Kr/Kb of each matrix.
    var coefficients: SIMD4<Float> {
        switch self {
        case .bt709: SIMD4<Float>(1.5748, 0.1873, 0.4681, 1.8556)
        case .bt2020: SIMD4<Float>(1.4746, 0.1646, 0.5714, 1.8814)
        case .bt601: SIMD4<Float>(1.4020, 0.3441, 0.7141, 1.7720)
        }
    }

    static func from(pixelBuffer: CVPixelBuffer) -> OPNVideoColorMatrix {
        guard let value = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil) as? String else { return .bt709 }
        if value == (kCVImageBufferYCbCrMatrix_ITU_R_2020 as String) { return .bt2020 }
        if value == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String) || value == (kCVImageBufferYCbCrMatrix_SMPTE_240M_1995 as String) { return .bt601 }
        return .bt709
    }
}

enum OPNVideoTransferFunction: Int {
    case sdr = 0
    case pq = 1
    case hlg = 2

    var isHDR: Bool { self != .sdr }

    static func from(pixelBuffer: CVPixelBuffer) -> OPNVideoTransferFunction {
        guard let value = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, nil) as? String else { return .sdr }
        if value == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String) { return .pq }
        if value == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String) { return .hlg }
        return .sdr
    }
}


@objc(OPNVideoEnhancementRenderer)
@MainActor
final class OPNVideoEnhancementRenderer: NSObject {
    static let renderTargetPixelFormat: MTLPixelFormat = .bgra8Unorm

    /// Resolution of the pillarbox fill history. Deliberately tiny: the downscale is
    /// what produces the blur, so sampling it back with linear filtering costs one
    /// fetch instead of a wide multi-tap kernel over a quarter of the screen.
    static let fillHistoryWidth = 160
    static let fillHistoryHeight = 90
    /// Weight of the current frame in the running average. ~0.12 settles in about
    /// eight frames, enough to stop heavy blur pulsing without visible smearing.
    static let fillHistoryEMAAlpha: Float = 0.12


    let device: (any MTLDevice)?
    let commandQueue: (any MTLCommandQueue)?
    private let ciContext: CIContext?
    let outputColorSpace = CGColorSpaceCreateDeviceRGB()
    private let metalFXUpscaler: OPNMetalFXUpscaler
    let textureSource: OPNVideoTextureSource
    let shaderLibrary: (any MTLLibrary)?
    private var metalFXIntermediateTexture: (any MTLTexture)?
    private var metalFXOutputTexture: (any MTLTexture)?
    /// Pipelines that render into the drawable, keyed by fragment function and destination pixel
    /// format. The drawable is `bgra8Unorm` for 8-bit video, `bgr10a2Unorm` once a 10-bit frame
    /// arrives and `rgba16Float` for HDR, so the same shader needs one state per format; each is
    /// built on first use and a failure is remembered rather than retried every frame.
    var outputPipelines: [String: any MTLRenderPipelineState] = [:]
    var failedOutputPipelines: Set<String> = []
    let pillarboxDetector = OPNPillarboxDetector()
    var lastLoggedFillMode: OPNPillarboxFillMode?
    var lastLoggedContentRect: OPNPillarboxContentRect?
    var fillHistoryRGBPipeline: (any MTLRenderPipelineState)?
    var fillHistoryNV12Pipeline: (any MTLRenderPipelineState)?
    var fillHistoryI420Pipeline: (any MTLRenderPipelineState)?
    var fillHistoryTexture: (any MTLTexture)?
    /// False until the history texture holds a real frame, so the first pass after
    /// (re)allocation replaces rather than blends into uninitialised contents.
    var fillHistoryPrimed = false
    var fillHistoryContentRect = OPNPillarboxContentRect.full
    var temporalMotionPipeline: (any MTLRenderPipelineState)?
    var temporalCompositePipeline: (any MTLRenderPipelineState)?
    private var temporalCurrentTexture: (any MTLTexture)?
    private var temporalHistoryTexture: (any MTLTexture)?
    private var temporalOutputTexture: (any MTLTexture)?
    private var temporalMotionTexture: (any MTLTexture)?
    var temporalHistoryValid = false
    private var temporalFrameIndex = 0
    private var temporalPreviousJitter = SIMD2<Float>(0, 0)
    private var temporalHistoryWidth = 0
    private var temporalHistoryHeight = 0
    private var temporalSourceWidth = 0
    private var temporalSourceHeight = 0
    private var temporalHistoryResetCount = 0
    var droppedFrames: UInt64 = 0
    var enhancedPixelBufferPool: CVPixelBufferPool?
    var enhancedPixelBufferPoolWidth = 0
    var enhancedPixelBufferPoolHeight = 0
    let i420BGRAConverter = WebRTCI420BGRAConverter()
    var i420PixelBufferPool: CVPixelBufferPool?
    var i420PixelBufferPoolWidth = 0
    var i420PixelBufferPoolHeight = 0

    @objc init(device: (any MTLDevice)?, commandQueue: (any MTLCommandQueue)?) {
        self.device = device
        self.commandQueue = commandQueue
        self.ciContext = device.map { CIContext(mtlDevice: $0, options: [.workingColorSpace: NSNull()]) }
        self.metalFXUpscaler = OPNMetalFXUpscaler(device: device)
        self.textureSource = OPNVideoTextureSource(device: device)
        self.shaderLibrary = Self.makeShaderLibrary(device: device)
        super.init()
        // The 8-bit drawable states are built up front so the first frame does not pay for them;
        // other output formats compile on first use.
        for name in ["opn_video_spatial_rgb", "opn_video_spatial_nv12", "opn_video_spatial_i420",
                     "opn_video_fast_rgb", "opn_video_fast_nv12", "opn_video_fast_i420", "opn_video_present_rgb"] {
            _ = outputPipeline(name, format: Self.renderTargetPixelFormat)
        }
        fillHistoryRGBPipeline = newFillHistoryPipeline(fragmentFunctionName: "opn_video_fill_history_rgb")
        fillHistoryNV12Pipeline = newFillHistoryPipeline(fragmentFunctionName: "opn_video_fill_history_nv12")
        fillHistoryI420Pipeline = newFillHistoryPipeline(fragmentFunctionName: "opn_video_fill_history_i420")
        temporalMotionPipeline = newSpatialPipeline(fragmentFunctionName: "opn_video_temporal_motion", pixelFormat: .rgba16Float)
        temporalCompositePipeline = newSpatialPipeline(fragmentFunctionName: "opn_video_temporal_composite")
    }


    @objc var isMetalFXAvailable: Bool {
        metalFXUpscaler.isAvailable
    }

    @objc var isTemporalAvailable: Bool {
        commandQueue != nil
            && outputPipeline("opn_video_spatial_rgb", format: Self.renderTargetPixelFormat) != nil
            && outputPipeline("opn_video_spatial_nv12", format: Self.renderTargetPixelFormat) != nil
            && outputPipeline("opn_video_spatial_i420", format: Self.renderTargetPixelFormat) != nil
            && temporalMotionPipeline != nil && temporalCompositePipeline != nil
            && outputPipeline("opn_video_present_rgb", format: Self.renderTargetPixelFormat) != nil
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

        updatePillarboxDetection(frame: frame, settings: settings)
        if renderThroughTexturePath(frame, drawable: drawable, commandQueue: commandQueue, settings: settings, result: result, start: start) {
            return true
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



    /// The Metal texture path, which every tier prefers when the caller does not also need the
    /// enhanced frame back as a pixel buffer. False means fall through to the Core Image path.
    func renderThroughTexturePath(_ frame: RTCVideoFrame,
                                          drawable: any CAMetalDrawable,
                                          commandQueue: any MTLCommandQueue,
                                          settings: OPNVideoEnhancementSettings,
                                          result: OPNVideoEnhancementResult,
                                          start: CFTimeInterval) -> Bool {
        let tier = settings.configuredTier
        guard tier == .spatial || tier == .metalFX || tier == .temporal, !settings.captureEnhancedPixelBuffer else { return false }
        var pixelFormat: NSString?
        var frameSource: NSString?
        var textureFallback: NSString?
        let textureFrame = textureSource.newTextureFrame(for: frame, pixelFormat: &pixelFormat, frameSource: &frameSource, fallback: &textureFallback) as? OPNVideoTextureFrame
        result.pixelFormat = (pixelFormat as String?) ?? result.pixelFormat
        result.frameSource = (frameSource as String?) ?? result.frameSource
        if let textureFrame, let commandBuffer = commandQueue.makeCommandBuffer() {
            if tier == .temporal, renderTemporalTextureFrame(textureFrame, drawable: drawable, commandBuffer: commandBuffer, settings: settings, result: result, start: start) {
                return true
            }
            if tier == .metalFX, renderMetalFXTextureFrame(textureFrame, drawable: drawable, commandBuffer: commandBuffer, settings: settings, result: result, start: start) {
                return true
            }
            if tier == .spatial, renderSpatialTextureFrame(textureFrame, drawable: drawable, commandBuffer: commandBuffer, settings: settings, result: result, start: start) {
                return true
            }
        }
        if let textureFallback, result.fallbackReason.isEmpty { result.fallbackReason = textureFallback as String }
        return false
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
        guard isMetalFXAvailable, outputPipeline("opn_video_present_rgb", format: drawable.texture.pixelFormat) != nil else { return false }
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

}
