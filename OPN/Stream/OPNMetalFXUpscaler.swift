//  OPNMetalFXUpscaler.swift
//  OpenNOW
//

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

@objc(OPNMetalFXUpscaler)
final class OPNMetalFXUpscaler: NSObject {
    private let device: (any MTLDevice)?
    private var spatialScaler: AnyObject?
    private var inputWidth = 0
    private var inputHeight = 0
    private var outputWidth = 0
    private var outputHeight = 0
    private var inputPixelFormat: MTLPixelFormat = .invalid
    private var outputPixelFormat: MTLPixelFormat = .invalid
    private var neutralMotionTexture: (any MTLTexture)?
    private var disabledByCaptureScaler = false
    private static let setMotionTextureSelector = NSSelectorFromString("setMotionTexture:")
    private static let motionTextureFormatSelector = NSSelectorFromString("motionTextureFormat")
    private static let motionTextureUsageSelector = NSSelectorFromString("motionTextureUsage")

    @objc init(device: (any MTLDevice)?) {
        self.device = device
        super.init()
    }

    @objc var isAvailable: Bool {
#if canImport(MetalFX)
        guard !disabledByCaptureScaler, let device, NSClassFromString("MTLFXSpatialScalerDescriptor") != nil else { return false }
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
                outputHeight != destinationTexture.height ||
                inputPixelFormat != sourceTexture.pixelFormat ||
                outputPixelFormat != destinationTexture.pixelFormat
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
                inputPixelFormat = sourceTexture.pixelFormat
                outputPixelFormat = destinationTexture.pixelFormat
            }
            guard let scaler = spatialScaler as? MTLFXSpatialScaler else {
                fallback?.pointee = "MetalFX scaler creation failed"
                return false
            }
            let scalerClassName = String(describing: type(of: scaler as AnyObject))
            if scalerClassName.contains("CaptureMTLFXSpatialScaler") {
                disabledByCaptureScaler = true
                spatialScaler = nil
                neutralMotionTexture = nil
                inputWidth = 0
                inputHeight = 0
                outputWidth = 0
                outputHeight = 0
                inputPixelFormat = .invalid
                outputPixelFormat = .invalid
                fallback?.pointee = "MetalFX disabled under Xcode Metal capture"
                return false
            }
            guard sourceTexture.usage.isSuperset(of: scaler.colorTextureUsage) else {
                fallback?.pointee = "MetalFX source texture usage unsupported"
                return false
            }
            guard destinationTexture.usage.isSuperset(of: scaler.outputTextureUsage) else {
                fallback?.pointee = "MetalFX output texture usage unsupported"
                return false
            }
            guard configureMotionTextureIfNeeded(for: scaler, fallback: fallback) else {
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

#if canImport(MetalFX)
    @available(macOS 13.0, *)
    private func configureMotionTextureIfNeeded(
        for scaler: any MTLFXSpatialScaler,
        fallback: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Bool {
        guard let scalerObject = scaler as AnyObject as? NSObject,
              scalerObject.responds(to: Self.setMotionTextureSelector) else { return true }
        let rawPixelFormat = Self.unsignedIntegerValue(from: scalerObject, selector: Self.motionTextureFormatSelector)
        let pixelFormat = rawPixelFormat.flatMap { MTLPixelFormat(rawValue: $0) } ?? .rg16Float
        let rawUsage = Self.unsignedIntegerValue(from: scalerObject, selector: Self.motionTextureUsageSelector) ?? MTLTextureUsage.shaderRead.rawValue
        let usage = MTLTextureUsage(rawValue: rawUsage).union(.shaderRead)
        guard let motionTexture = reusableNeutralMotionTexture(width: inputWidth, height: inputHeight, pixelFormat: pixelFormat, usage: usage) else {
            fallback?.pointee = "MetalFX motion texture allocation failed"
            return false
        }
        Self.setObjectValue(motionTexture as AnyObject, on: scalerObject, selector: Self.setMotionTextureSelector)
        return true
    }

    private static func unsignedIntegerValue(from object: NSObject, selector: Selector) -> UInt? {
        guard object.responds(to: selector), let method = object.method(for: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> UInt
        return unsafeBitCast(method, to: Getter.self)(object, selector)
    }

    private static func setObjectValue(_ value: AnyObject, on object: NSObject, selector: Selector) {
        guard object.responds(to: selector), let method = object.method(for: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        unsafeBitCast(method, to: Setter.self)(object, selector, value)
    }

    private func reusableNeutralMotionTexture(
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat,
        usage: MTLTextureUsage
    ) -> (any MTLTexture)? {
        guard let device, width > 0, height > 0, let bytesPerPixel = Self.bytesPerPixel(for: pixelFormat) else { return nil }
        let requiredUsage = usage.union(.shaderRead)
        if neutralMotionTexture == nil ||
            neutralMotionTexture?.width != width ||
            neutralMotionTexture?.height != height ||
            neutralMotionTexture?.pixelFormat != pixelFormat ||
            neutralMotionTexture?.usage.isSuperset(of: requiredUsage) != true {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
            descriptor.usage = requiredUsage
            descriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
            let bytesPerRow = width * bytesPerPixel
            let zeroBytes = [UInt8](repeating: 0, count: bytesPerRow * height)
            zeroBytes.withUnsafeBytes { bytes in
                if let baseAddress = bytes.baseAddress {
                    texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: baseAddress, bytesPerRow: bytesPerRow)
                }
            }
            texture.label = "OpenNOW MetalFX neutral motion"
            neutralMotionTexture = texture
        }
        return neutralMotionTexture
    }

    private static func bytesPerPixel(for pixelFormat: MTLPixelFormat) -> Int? {
        switch pixelFormat {
        case .r8Unorm, .r8Snorm, .r8Uint, .r8Sint:
            return 1
        case .r16Unorm, .r16Snorm, .r16Uint, .r16Sint, .r16Float, .rg8Unorm, .rg8Snorm, .rg8Uint, .rg8Sint:
            return 2
        case .r32Uint, .r32Sint, .r32Float, .rg16Unorm, .rg16Snorm, .rg16Uint, .rg16Sint, .rg16Float, .rgba8Unorm, .rgba8Unorm_srgb, .rgba8Snorm, .rgba8Uint, .rgba8Sint, .bgra8Unorm, .bgra8Unorm_srgb:
            return 4
        case .rg32Uint, .rg32Sint, .rg32Float, .rgba16Unorm, .rgba16Snorm, .rgba16Uint, .rgba16Sint, .rgba16Float:
            return 8
        case .rgba32Uint, .rgba32Sint, .rgba32Float:
            return 16
        default:
            return nil
        }
    }
#endif
}
