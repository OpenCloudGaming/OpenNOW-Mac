import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Metal
import MetalKit
import QuartzCore
#if canImport(MetalFX)
import MetalFX
#endif

@objc(OPNVideoTextureSource)
final class OPNVideoTextureSource: NSObject {
    let device: (any MTLDevice)?
    private var textureCache: CVMetalTextureCache?

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

    @objc(newTextureFrameForPixelBuffer:pixelFormat:frameSource:fallback:)
    func newTextureFrame(
        for pixelBuffer: CVPixelBuffer,
        pixelFormat: AutoreleasingUnsafeMutablePointer<NSString?>?,
        frameSource: AutoreleasingUnsafeMutablePointer<NSString?>?,
        fallback: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Any? {
        guard let textureCache else {
            fallback?.pointee = "texture source unavailable"
            return nil
        }
        return pixelBufferTextureFrame(pixelBuffer, textureCache: textureCache, pixelFormat: pixelFormat, frameSource: frameSource, fallback: fallback)
    }

    /// The zero-copy path: BGRA and bi-planar buffers are wrapped as Metal textures straight out of
    /// the texture cache.
    private func pixelBufferTextureFrame(_ pixelBuffer: CVPixelBuffer,
                                         textureCache: CVMetalTextureCache,
                                         pixelFormat: AutoreleasingUnsafeMutablePointer<NSString?>?,
                                         frameSource: AutoreleasingUnsafeMutablePointer<NSString?>?,
                                         fallback: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Any? {
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
        // The decoded surface is sampled whole: VideoToolbox's clean-aperture trim is display
        // geometry, applied when the picture is fitted to the drawable, not a crop of the planes.
        textureFrame.cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        textureFrame.contentWidth = UInt(max(1, width))
        textureFrame.contentHeight = UInt(max(1, height))
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

    /// The HUD's render tier for a surface: `Native 10-bit`, `Native 4:4:4`, `Native 10-bit 4:4:4`.
    static func nativeRenderTierLabel(_ format: OSType) -> String {
        var parts = ["Native"]
        if isTenBitBiPlanarFormat(format) { parts.append("10-bit") }
        switch format {
        case kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
            parts.append("4:2:2")
        case kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
            parts.append("4:4:4")
        default:
            break
        }
        return parts.joined(separator: " ")
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
}
