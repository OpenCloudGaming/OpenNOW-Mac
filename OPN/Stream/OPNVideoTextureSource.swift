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
    let device: (any MTLDevice)?
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
            return i420TextureFrame(frame, buffer: buffer, pixelFormat: pixelFormat, frameSource: frameSource, fallback: fallback)
        }
        return pixelBufferTextureFrame(cvBuffer, textureCache: textureCache, pixelFormat: pixelFormat, frameSource: frameSource, fallback: fallback)
    }

    /// A frame that is not already a `CVPixelBuffer` is converted to I420 and uploaded plane by
    /// plane into reused textures.
    private func i420TextureFrame(_ frame: RTCVideoFrame,
                                  buffer: any RTCVideoFrameBuffer,
                                  pixelFormat: AutoreleasingUnsafeMutablePointer<NSString?>?,
                                  frameSource: AutoreleasingUnsafeMutablePointer<NSString?>?,
                                  fallback: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Any? {
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
        frameSource?.pointee = Self.frameBufferClassName(buffer)
        pixelFormat?.pointee = "I420"
        guard textureFrame.lumaTexture != nil, textureFrame.chromaUTexture != nil, textureFrame.chromaVTexture != nil else {
            fallback?.pointee = "I420 GPU plane upload failed"
            return nil
        }
        return textureFrame
    }

    /// The zero-copy path: BGRA and bi-planar buffers are wrapped as Metal textures straight out of
    /// the texture cache.
    private func pixelBufferTextureFrame(_ cvBuffer: RTCCVPixelBuffer,
                                         textureCache: CVMetalTextureCache,
                                         pixelFormat: AutoreleasingUnsafeMutablePointer<NSString?>?,
                                         frameSource: AutoreleasingUnsafeMutablePointer<NSString?>?,
                                         fallback: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Any? {
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
        applyCropRect(cvBuffer, width: width, height: height, to: textureFrame)
        textureFrame.colorMatrix = OPNVideoColorMatrix.from(pixelBuffer: pixelBuffer).rawValue
        textureFrame.transferFunction = OPNVideoTransferFunction.from(pixelBuffer: pixelBuffer).rawValue
        textureFrame.isFullRange = !isBiPlanar || Self.isFullRangeBiPlanarFormat(format)

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

        guard let chromaTexture = chromaPlaneTexture(pixelBuffer, textureCache: textureCache, isTenBit: isTenBitBiPlanar) else {
            fallback?.pointee = "CVMetalTextureCache could not create NV12 chroma texture"
            return nil
        }
        textureFrame.lumaTexture = texture
        textureFrame.chromaTexture = chromaTexture
        return textureFrame
    }

    /// The interleaved chroma plane of a bi-planar buffer, as an `rg` texture.
    private func chromaPlaneTexture(_ pixelBuffer: CVPixelBuffer, textureCache: CVMetalTextureCache, isTenBit: Bool) -> (any MTLTexture)? {
        var chromaMetalTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            isTenBit ? .rg16Unorm : .rg8Unorm,
            CVPixelBufferGetWidthOfPlane(pixelBuffer, 1),
            CVPixelBufferGetHeightOfPlane(pixelBuffer, 1),
            1,
            &chromaMetalTexture
        )
        guard status == kCVReturnSuccess, let chromaMetalTexture else { return nil }
        return CVMetalTextureGetTexture(chromaMetalTexture)
    }

    /// The decoder can hand back a buffer larger than the picture; the crop rect keeps the shader
    /// sampling only the real content.
    private func applyCropRect(_ cvBuffer: RTCCVPixelBuffer, width: Int, height: Int, to textureFrame: OPNVideoTextureFrame) {
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

    private static let pixelFormatNames: [OSType: String] = [
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: "420v/NV12",
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: "420f/NV12",
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: "x420/P010",
        kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: "xf20/P010",
        kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange: "422v/NV16",
        kCVPixelFormatType_422YpCbCr8BiPlanarFullRange: "422f/NV16",
        kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange: "x422/P210",
        kCVPixelFormatType_422YpCbCr10BiPlanarFullRange: "xf22/P210",
        kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange: "444v/NV24",
        kCVPixelFormatType_444YpCbCr8BiPlanarFullRange: "444f/NV24",
        kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange: "x444/P410",
        kCVPixelFormatType_444YpCbCr10BiPlanarFullRange: "xf44/P410",
        kCVPixelFormatType_32BGRA: "BGRA",
        kCVPixelFormatType_32ARGB: "ARGB",
    ]

    static func pixelFormatName(_ format: OSType) -> String {
        if let name = pixelFormatNames[format] { return name }
        return String(format: "0x%08x", format)
    }

    /// Luma plane plus one interleaved CbCr plane, at any chroma subsampling and either depth.
    /// The shaders sample both planes at the same normalised coordinate, so 4:2:2 and 4:4:4
    /// chroma planes bind exactly like 4:2:0 ones — only the texture dimensions differ.
    static func isSupportedBiPlanarFormat(_ format: OSType) -> Bool {
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr8BiPlanarFullRange:
            return true
        default:
            return isTenBitBiPlanarFormat(format)
        }
    }

    static func isTenBitBiPlanarFormat(_ format: OSType) -> Bool {
        switch format {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
            return true
        default:
            return false
        }
    }

    static func isFullRangeBiPlanarFormat(_ format: OSType) -> Bool {
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr8BiPlanarFullRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr8BiPlanarFullRange, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
            return true
        default:
            return false
        }
    }

    private static func frameBufferClassName(_ buffer: any RTCVideoFrameBuffer) -> NSString {
        NSStringFromClass(type(of: buffer) as AnyClass) as NSString
    }

}
