//  Renderer selection (libwebrtc's NV12/RGB/I420 Metal renderers vs the custom enhancement path),
//  per-second diagnostics and draw-cadence bookkeeping for `OPNMetalVideoView`.
//

import AppKit
import Foundation
import Metal
import MetalKit
import QuartzCore
import WebRTC

struct VideoEnhancement {
    var mode: Int32
    var sharpness: Int32
    var denoise: Int32
    var targetHeight: Int32
    var pillarboxFillMode: Int32
    var pillarboxFillDim: Int32
    var pillarboxFillColor: Int32

    var fillMode: OPNPillarboxFillMode { OPNPillarboxFillMode.from(Int(pillarboxFillMode)) }
}

struct RenderDiagnostics {
    var pixelFormat = "unknown"
    var renderMode = "I420"
    var frameSource = "unknown"
    var renderPath = "RTCMTLI420Renderer"
    var fallback = ""
    var enhancementConfiguredTier = "Off"
    var enhancementActiveTier = "Native"
    var enhancementFallbackReason = ""
    var sourceResolution: String
    var drawableResolution: String
    var enhancementDiagnostics = ""
    var enhancementFrameTimeMs = -1.0
    var frameIntervalMs = -1.0
    var maxFrameIntervalMs = -1.0
    var outputFormat = ""
    var isHDR = false
}

extension OPNMetalVideoView {
    func rendererForFrame(_ frame: RTCVideoFrame, diagnostics: inout RenderDiagnostics) -> OPNRTCMetalRenderer? {
        if let buffer = frame.buffer as? RTCCVPixelBuffer {
            diagnostics.frameSource = "CVPixelBuffer"
            let format = CVPixelBufferGetPixelFormatType(buffer.pixelBuffer)
            let isNV12 = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            let isRGB = format == kCVPixelFormatType_32BGRA || format == kCVPixelFormatType_32ARGB
            diagnostics.pixelFormat = pixelFormatName(format)
            if isNV12 {
                var fallback = ""
                if rendererNV12 == nil { rendererNV12 = newRenderer(named: "RTCMTLNV12Renderer", fallback: &fallback) }
                if let rendererNV12 {
                    diagnostics.renderMode = "NV12"
                    diagnostics.renderPath = "RTCMTLNV12Renderer"
                    return rendererNV12
                }
                diagnostics.fallback = fallback.isEmpty ? "NV12 unavailable; using I420" : fallback
            } else if isRGB {
                var fallback = ""
                if rendererRGB == nil { rendererRGB = newRenderer(named: "RTCMTLRGBRenderer", fallback: &fallback) }
                if let rendererRGB {
                    diagnostics.renderMode = "RGB"
                    diagnostics.renderPath = "RTCMTLRGBRenderer"
                    return rendererRGB
                }
                diagnostics.fallback = fallback.isEmpty ? "NV12 preferred; RGB unavailable; using I420" : fallback
            } else {
                diagnostics.fallback = "NV12 preferred; unsupported CVPixelBuffer; using I420"
            }
        } else {
            diagnostics.frameSource = NSStringFromClass(type(of: frame.buffer as AnyObject))
            diagnostics.pixelFormat = "I420"
        }
        diagnostics.renderMode = "I420"
        diagnostics.renderPath = "RTCMTLI420Renderer"
        return i420Renderer(fallback: &diagnostics.fallback)
    }

    func newRenderer(named className: String, fallback: inout String) -> OPNRTCMetalRenderer? {
        guard let rendererClass = NSClassFromString(className) as? NSObject.Type else {
            fallback = "\(className) unavailable"
            return nil
        }
        guard let renderer = OPNObjCMetalRenderer(rendererClass.init()) else {
            fallback = "\(className) does not expose renderer selectors"
            return nil
        }
        guard renderer.addRenderingDestination(metalView) else {
            fallback = "\(className) rejected MTKView"
            return nil
        }
        metalView.preferredFramesPerSecond = targetFps
        return renderer
    }

    func i420Renderer(fallback: inout String) -> OPNRTCMetalRenderer? {
        if rendererI420 == nil { rendererI420 = newRenderer(named: "RTCMTLI420Renderer", fallback: &fallback) }
        return rendererI420
    }

    func emitDiagnosticsIfNeeded(_ diagnostics: RenderDiagnostics, force: Bool) {
        let now = CACurrentMediaTime()
        guard force || lastDiagnosticsUpdateTime <= 0 || now - lastDiagnosticsUpdateTime >= 1.0 else { return }
        lastDiagnosticsUpdateTime = now
        var diagnostics = diagnostics
        populateDrawCadenceDiagnostics(&diagnostics)
        diagnostics.outputFormat = Self.outputFormatName(metalView.colorPixelFormat)
        diagnostics.isHDR = appliedTransfer.isHDR
        if let renderDiagnosticsHandler {
            os_unfair_lock_lock(&frameLock)
            let received = framesReceived
            os_unfair_lock_unlock(&frameLock)
            let present = takePresentDiagnostics()
            renderDiagnosticsHandler(OPNVideoRenderDiagnosticsSnapshot(
                pixelFormat: diagnostics.pixelFormat,
                outputFormat: diagnostics.outputFormat,
                renderPath: diagnostics.renderPath,
                activeTier: diagnostics.enhancementActiveTier,
                fallback: diagnostics.fallback,
                isHDR: diagnostics.isHDR,
                frameIntervalMs: diagnostics.frameIntervalMs,
                maxFrameIntervalMs: diagnostics.maxFrameIntervalMs,
                framesReceived: received,
                framesDrawn: framesDrawn,
                presentationMode: presentationMode.label,
                presentLatencyMs: present.latency,
                presentLatencyMaxMs: present.maximum,
                presentJitterMs: present.jitter
            ))
        }
        owner?.setVideoRenderDiagnostics(
            pixelFormat: diagnostics.pixelFormat,
            renderMode: diagnostics.renderMode,
            frameSource: diagnostics.frameSource,
            renderPath: diagnostics.renderPath,
            fallback: diagnostics.fallback,
            enhancementConfiguredTier: diagnostics.enhancementConfiguredTier,
            enhancementActiveTier: diagnostics.enhancementActiveTier,
            enhancementFallbackReason: diagnostics.enhancementFallbackReason,
            enhancementSourceResolution: diagnostics.sourceResolution,
            enhancementDrawableResolution: diagnostics.drawableResolution,
            enhancementDiagnostics: diagnostics.enhancementDiagnostics,
            enhancementFrameTimeMs: diagnostics.enhancementFrameTimeMs,
            enhancementDroppedFrames: enhancementDroppedFrameCount,
            frameIntervalMs: diagnostics.frameIntervalMs,
            maxFrameIntervalMs: diagnostics.maxFrameIntervalMs
        )
    }

    /// Supplies enhancement/pillarbox settings for an owner-less renderer. Safe from any thread;
    /// the render pass reads it under the same lock.
    nonisolated func setLocalVideoEnhancementOverride(mode: Int32,
                                                      sharpness: Int32,
                                                      denoise: Int32,
                                                      targetHeight: Int32,
                                                      pillarboxFillMode: Int32,
                                                      pillarboxFillDim: Int32,
                                                      pillarboxFillColor: Int32) {
        os_unfair_lock_lock(&enhancementOverrideLock)
        enhancementOverride = (mode, sharpness, denoise, targetHeight, pillarboxFillMode, pillarboxFillDim, pillarboxFillColor)
        os_unfair_lock_unlock(&enhancementOverrideLock)
    }

    func localVideoEnhancementOverride() -> (Int32, Int32, Int32, Int32, Int32, Int32, Int32)? {
        os_unfair_lock_lock(&enhancementOverrideLock)
        defer { os_unfair_lock_unlock(&enhancementOverrideLock) }
        return enhancementOverride
    }

    func localVideoEnhancement() -> VideoEnhancement {
        let values = localVideoEnhancementOverride() ?? owner?.localVideoEnhancement() ?? (0, 0, 0, 2160, 0, 55, 0)
        return VideoEnhancement(mode: normalizedEnhancementMode(values.0), sharpness: values.1, denoise: values.2, targetHeight: values.3, pillarboxFillMode: values.4, pillarboxFillDim: values.5, pillarboxFillColor: values.6)
    }

    func setCustomDrawableRenderingEnabled(_ enabled: Bool) {
        guard customDrawableRenderingEnabled != enabled else { return }
        customDrawableRenderingEnabled = enabled
        metalView.framebufferOnly = !enabled
    }

    func recordDrawCadence() {
        framesDrawn &+= 1
        let now = CACurrentMediaTime()
        if lastDrawCadenceTime > 0 {
            let intervalMs = max(0, (now - lastDrawCadenceTime) * 1000)
            drawIntervalTotalMs += intervalMs
            drawIntervalMaxMs = max(drawIntervalMaxMs, intervalMs)
            drawIntervalCount += 1
        }
        lastDrawCadenceTime = now
    }

    func populateDrawCadenceDiagnostics(_ diagnostics: inout RenderDiagnostics) {
        guard drawIntervalCount > 0 else { return }
        diagnostics.frameIntervalMs = drawIntervalTotalMs / Double(drawIntervalCount)
        diagnostics.maxFrameIntervalMs = drawIntervalMaxMs
        drawIntervalTotalMs = 0
        drawIntervalMaxMs = 0
        drawIntervalCount = 0
    }

    func resetDrawCadence() {
        lastDrawCadenceTime = 0
        drawIntervalTotalMs = 0
        drawIntervalMaxMs = 0
        drawIntervalCount = 0
    }
}
