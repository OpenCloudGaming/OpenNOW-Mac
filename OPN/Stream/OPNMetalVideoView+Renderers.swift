//  Enhancement overrides, per-second diagnostics and draw-cadence bookkeeping for
//  `OPNMetalVideoView`.
//

import AppKit
import Foundation
import Metal
import MetalKit
import QuartzCore

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
    var renderMode = "BiPlanar"
    var frameSource = "CVPixelBuffer"
    var renderPath = "OPNMetalSpatialUpscalerSwift"
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
        let values = localVideoEnhancementOverride() ?? (0, 0, 0, 2160, 0, 55, 0)
        return VideoEnhancement(mode: normalizedEnhancementMode(values.0), sharpness: values.1, denoise: values.2, targetHeight: values.3, pillarboxFillMode: values.4, pillarboxFillDim: values.5, pillarboxFillColor: values.6)
    }

    /// The pillarbox fill the last drawn frame actually went through. `none` whenever the draw took
    /// a path with no fill pass, which is what a pointer needs to know before reprojecting a click.
    var committedPillarboxFill: OPNCommittedPillarboxFill {
        enhancementRenderer?.pillarboxFillCommit.value ?? .notApplied
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
