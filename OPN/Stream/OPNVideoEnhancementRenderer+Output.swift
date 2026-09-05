//  Output-format pipelines, pillarbox detection and the offscreen snapshot render. Split from
//  OPNVideoEnhancementRenderer.swift for size.
//

import CoreGraphics
import CoreVideo
import Foundation
import Metal
import QuartzCore
import WebRTC

extension OPNVideoEnhancementRenderer {

    func outputPipeline(_ fragmentFunctionName: String, format: MTLPixelFormat) -> (any MTLRenderPipelineState)? {
        let key = "\(fragmentFunctionName)#\(format.rawValue)"
        if let existing = outputPipelines[key] { return existing }
        guard !failedOutputPipelines.contains(key) else { return nil }
        guard let pipeline = newSpatialPipeline(fragmentFunctionName: fragmentFunctionName, pixelFormat: format) else {
            failedOutputPipelines.insert(key)
            return nil
        }
        outputPipelines[key] = pipeline
        return pipeline
    }

    /// Renders `frame` through the spatial pass into an offscreen `bgra8Unorm` texture of `size`
    /// — the same shader and the same fill uniforms the drawable gets — and blocks until it is
    /// done. Exists for the autopilot's render snapshots: a session launched from a shell never
    /// gets its window shown, so there is no drawable to read back, but the picture the viewer
    /// would see can still be produced. The pillarbox detector is primed with a few spaced
    /// measurements first, since it latches only after agreeing samples over time.
    func renderOffscreenSnapshot(_ frame: RTCVideoFrame, settings: OPNVideoEnhancementSettings, size: CGSize) -> (any MTLTexture)? {
        guard let device, let commandQueue, size.width >= 1, size.height >= 1 else { return nil }
        if OPNPillarboxFillMode.from(settings.pillarboxFillMode) != .black, let cvBuffer = frame.buffer as? RTCCVPixelBuffer {
            let now = CACurrentMediaTime()
            for step in 0..<6 { _ = pillarboxDetector.update(with: cvBuffer.pixelBuffer, now: now + Double(step) * 0.3) }
        }
        var pixelFormat: NSString?
        var frameSource: NSString?
        var fallback: NSString?
        guard let textureFrame = textureSource.newTextureFrame(for: frame, pixelFormat: &pixelFormat, frameSource: &frameSource, fallback: &fallback) as? OPNVideoTextureFrame else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(size.width), height: Int(size.height), mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor), let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }
        let result = OPNVideoEnhancementResult()
        guard encodeSpatialTextureFrame(textureFrame, destinationTexture: target, commandBuffer: commandBuffer, settings: settings, result: result) else { return nil }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return target
    }

    /// The bar geometry only needs re-measuring while a non-black fill is selected; switching back
    /// to black releases the latched rect so a later re-enable starts clean.
    func updatePillarboxDetection(frame: RTCVideoFrame, settings: OPNVideoEnhancementSettings) {
        let fillMode = OPNPillarboxFillMode.from(settings.pillarboxFillMode)
        if fillMode != .black, let cvBuffer = frame.buffer as? RTCCVPixelBuffer {
            pillarboxDetector.update(with: cvBuffer.pixelBuffer)
        } else if fillMode == .black, !pillarboxDetector.contentRect.isFull {
            pillarboxDetector.reset()
        }
    }
}
