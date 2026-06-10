import CoreGraphics
import CoreVideo
import Foundation
import Metal
import WebRTC
#if canImport(MetalFX)
import MetalFX
#endif

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
