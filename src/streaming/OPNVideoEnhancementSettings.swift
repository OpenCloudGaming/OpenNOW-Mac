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
    private var metalFXIntermediateTexture: (any MTLTexture)?
    private var metalFXOutputTexture: (any MTLTexture)?
    private var droppedFrames: UInt64 = 0

    @objc init(device: (any MTLDevice)?, commandQueue: (any MTLCommandQueue)?) {
        self.device = device
        self.commandQueue = commandQueue
        self.ciContext = device.map { CIContext(mtlDevice: $0, options: [.workingColorSpace: NSNull()]) }
        self.metalFXUpscaler = OPNMetalFXUpscaler(device: device)
        super.init()
    }

    @objc var isMetalFXAvailable: Bool {
        metalFXUpscaler.isAvailable
    }

    @objc var isTemporalAvailable: Bool {
        device != nil && commandQueue != nil && ciContext != nil
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
              let outputTexture = reusableTexture(&metalFXOutputTexture, width: outputWidth, height: outputHeight, pixelFormat: drawable.texture.pixelFormat, usage: [.shaderRead, .shaderWrite], label: "OpenNOW MetalFX output") else {
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
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            result.fallbackReason = "MetalFX blit encoder unavailable"
            recordDrop(in: result)
            return false
        }
        blit.copy(from: outputTexture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: outputWidth, height: outputHeight, depth: 1), to: drawable.texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
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

    private static func frameBufferClassName(_ buffer: any RTCVideoFrameBuffer) -> NSString {
        NSStringFromClass(type(of: buffer) as AnyClass) as NSString
    }
}
