import CoreGraphics
import CoreVideo
import Foundation
import Metal
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
