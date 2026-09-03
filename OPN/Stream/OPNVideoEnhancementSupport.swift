//  Core Image fallbacks, pixel-buffer pools and the naming the HUD reports. Split out of
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
import MetalFX

extension OPNVideoEnhancementRenderer {
    func populateResult(_ result: OPNVideoEnhancementResult?, settings: OPNVideoEnhancementSettings?) {
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

    func image(for frame: RTCVideoFrame, result: OPNVideoEnhancementResult) -> CIImage? {
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

    func enhancedImage(_ image: CIImage, settings: OPNVideoEnhancementSettings) -> CIImage {
        let target = CGRect(origin: .zero, size: settings.drawableSize)
        let sourceExtent = image.extent
        guard sourceExtent.width > 0, sourceExtent.height > 0, target.width > 0, target.height > 0 else { return image }
        let scaleX = target.width / sourceExtent.width
        let scaleY = target.height / sourceExtent.height
        var output = image.transformed(by: CGAffineTransform(translationX: -sourceExtent.origin.x, y: -sourceExtent.origin.y).scaledBy(x: scaleX, y: scaleY))
        output = enhancedImageWithoutScale(output, settings: settings)
        return output.cropped(to: target)
    }

    func enhancedImageWithoutScale(_ image: CIImage, settings: OPNVideoEnhancementSettings) -> CIImage {
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

    func reusableTexture(
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

    func newEnhancedPixelBuffer(from image: CIImage, width: Int, height: Int, context: CIContext) -> CVPixelBuffer? {
        guard width > 0, height > 0 else { return nil }
        let pool = enhancedPixelBufferPool(width: width, height: height)
        var pixelBuffer: CVPixelBuffer?
        guard let pool,
              CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { return nil }
        context.render(image, to: pixelBuffer, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: outputColorSpace)
        return pixelBuffer
    }

    func enhancedPixelBufferPool(width: Int, height: Int) -> CVPixelBufferPool? {
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

    func newBGRAFramebuffer(from i420: RTCI420Buffer) -> CVPixelBuffer? {
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

    func i420BGRAFramebufferPool(width: Int, height: Int) -> CVPixelBufferPool? {
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

    func recordDrop(in result: OPNVideoEnhancementResult) {
        droppedFrames += 1
        result.droppedFrames = droppedFrames
        result.activeTier = "Off"
        result.frameTimeMs = 0
    }

    func resolutionString(_ size: CGSize) -> String {
        let width = Int(max(0, size.width).rounded())
        let height = Int(max(0, size.height).rounded())
        return width > 0 && height > 0 ? "\(width)x\(height)" : "unknown"
    }

    func tierName(for tier: OPNVideoEnhancementTier) -> String {
        switch tier {
        case .spatial: return "Spatial"
        case .metalFX: return "MetalFX"
        case .temporal: return "Temporal"
        case .off: return "Off"
        @unknown default: return "Off"
        }
    }

    func activeTierName(for tier: OPNVideoEnhancementTier) -> String {
        switch tier {
        case .spatial: return "Spatial"
        case .metalFX: return isMetalFXAvailable ? "MetalFX Spatial" : "Spatial"
        case .temporal: return "Temporal"
        case .off: return "Off"
        @unknown default: return "Off"
        }
    }

    func renderMode(for tier: OPNVideoEnhancementTier) -> String {
        switch tier {
        case .metalFX: return isMetalFXAvailable ? "MetalFX" : "CoreImage"
        case .temporal: return "Temporal CoreImage"
        case .spatial: return "CoreImage"
        case .off: return "Off"
        @unknown default: return "CoreImage"
        }
    }

    func pixelFormatName(_ format: OSType) -> String {
        if format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange { return "420v/NV12" }
        if format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange { return "420f/NV12" }
        if format == kCVPixelFormatType_32BGRA { return "BGRA" }
        if format == kCVPixelFormatType_32ARGB { return "ARGB" }
        return String(format: "0x%08x", format)
    }

    static func temporalJitter(frameIndex: Int) -> SIMD2<Float> {
        temporalJitterOffsets[frameIndex % temporalJitterOffsets.count]
    }

    static let temporalJitterOffsets: [SIMD2<Float>] = [
        SIMD2<Float>(-0.375, -0.125),
        SIMD2<Float>(0.125, 0.375),
        SIMD2<Float>(-0.125, -0.375),
        SIMD2<Float>(0.375, 0.125),
        SIMD2<Float>(-0.3125, 0.3125),
        SIMD2<Float>(0.1875, -0.1875),
        SIMD2<Float>(-0.1875, 0.1875),
        SIMD2<Float>(0.3125, -0.3125),
    ]

    static func textureFrameUsesFullCrop(_ textureFrame: OPNVideoTextureFrame) -> Bool {
        let crop = textureFrame.cropRect
        return crop.minX <= 0.0001 && crop.minY <= 0.0001 && crop.width >= 0.9999 && crop.height >= 0.9999
    }

    static func frameBufferClassName(_ buffer: any RTCVideoFrameBuffer) -> NSString {
        NSStringFromClass(type(of: buffer) as AnyClass) as NSString
    }
}
