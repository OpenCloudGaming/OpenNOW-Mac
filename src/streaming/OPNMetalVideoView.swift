import AppKit
import CoreVideo
import Foundation
import Metal
import MetalKit
import QuartzCore
@preconcurrency import WebRTC

@objc private protocol OPNRTCMetalRenderer: NSObjectProtocol {
    @objc(addRenderingDestination:)
    func addRenderingDestination(_ view: MTKView) -> Bool

    @objc(drawFrame:)
    func drawFrame(_ frame: RTCVideoFrame)
}

@objc(OPNMetalVideoView)
final class OPNMetalVideoView: NSView, @preconcurrency RTCVideoRenderer, MTKViewDelegate {
    private let metalView: MTKView
    private var videoFrame: RTCVideoFrame?
    private var rendererNV12: OPNRTCMetalRenderer?
    private var rendererRGB: OPNRTCMetalRenderer?
    private var rendererI420: OPNRTCMetalRenderer?
    private var commandQueue: (any MTLCommandQueue)?
    private var enhancementRenderer: OPNVideoEnhancementRenderer?
    private var sourceFrameSize = CGSize.zero
    private let targetFps: Int
    private var frameSerial: UInt64 = 0
    private var lastDrawnFrameSerial: UInt64 = 0
    private var enhancementDroppedFrameCount: UInt64 = 0
    private var lastEnhancementFrameTimeMs = -1.0
    private var lastDiagnosticsUpdateTime: CFTimeInterval = 0
    private var drawableSizeDirty = true
    private var enhancementSettings = OPNVideoEnhancementSettings()
    private var enhancementResult = OPNVideoEnhancementResult()
    private var enhancementOverBudgetCount = 0
    private var adaptiveEnhancementPenalty = 0
    private weak var owner: OPNLibWebRTCStreamSession?

    init(frame frameRect: NSRect, targetFps: Int32, owner: OPNLibWebRTCStreamSession?) {
        self.owner = owner
        self.targetFps = min(max(Int(targetFps), 30), 240)
        metalView = MTKView(frame: frameRect, device: MTLCreateSystemDefaultDevice())
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        metalView.frame = bounds
        metalView.autoresizingMask = [.width, .height]
        metalView.framebufferOnly = false
        metalView.autoResizeDrawable = false
        metalView.isPaused = false
        metalView.enableSetNeedsDisplay = false
        metalView.preferredFramesPerSecond = self.targetFps
        metalView.delegate = self
        metalView.layerContentsPlacement = .scaleProportionallyToFit
        if let metalLayer = metalView.layer as? CAMetalLayer {
            metalLayer.presentsWithTransaction = false
            metalLayer.allowsNextDrawableTimeout = false
            if #available(macOS 10.13, *) {
                metalLayer.maximumDrawableCount = owner?.lowLatencyMode == true ? 2 : 3
            }
        }
        addSubview(metalView)
        if let device = metalView.device {
            commandQueue = device.makeCommandQueue()
            enhancementRenderer = OPNVideoEnhancementRenderer(device: device, commandQueue: commandQueue)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        metalView.frame = bounds
        drawableSizeDirty = true
        updateDrawableSizeForCurrentBackingScale()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        drawableSizeDirty = true
        updateDrawableSizeForCurrentBackingScale()
    }

    func setSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        synchronized {
            sourceFrameSize = size
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.drawableSizeDirty = true
            self.updateDrawableSizeForCurrentBackingScale()
        }
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        owner?.handleVideoFrame(Unmanaged.passUnretained(frame).toOpaque())
        synchronized {
            videoFrame = frame
            frameSerial += 1
        }
    }

    func draw(in view: MTKView) {
        guard view == metalView else { return }
        if drawableSizeDirty { updateDrawableSizeForCurrentBackingScale() }

        let snapshot = synchronized { () -> (RTCVideoFrame?, UInt64, CGSize) in
            (videoFrame, frameSerial, sourceFrameSize)
        }
        guard let frame = snapshot.0,
              frame.width > 0,
              frame.height > 0,
              snapshot.1 > 0,
              snapshot.1 != lastDrawnFrameSerial else { return }

        let sourceSize = snapshot.2.width > 0 && snapshot.2.height > 0 ? snapshot.2 : CGSize(width: Int(frame.width), height: Int(frame.height))
        var diagnostics = RenderDiagnostics(sourceResolution: videoResolutionString(sourceSize), drawableResolution: videoResolutionString(metalView.drawableSize))
        var enhancement = localVideoEnhancement()
        if adaptiveEnhancementPenalty > 0, let enhancementRenderer {
            if enhancement.mode == 4 {
                enhancement.mode = enhancementRenderer.isMetalFXAvailable ? 3 : 2
            } else if enhancement.mode == 3, !enhancementRenderer.isMetalFXAvailable {
                enhancement.mode = 2
            } else if enhancement.mode == 2, adaptiveEnhancementPenalty > 1 {
                enhancement.mode = 0
            }
        }
        if drawableSizeDirty { updateDrawableSizeForCurrentBackingScale() }

        if enhancement.mode > 0, renderEnhancedFrame(frame, drawSerial: snapshot.1, sourceSize: sourceSize, enhancement: enhancement, diagnostics: &diagnostics) {
            emitDiagnosticsIfNeeded(diagnostics, force: !diagnostics.fallback.isEmpty)
            return
        }

        let renderer = rendererForFrame(frame, diagnostics: &diagnostics)
        if let renderer {
            renderer.drawFrame(frame)
            lastDrawnFrameSerial = snapshot.1
        } else {
            diagnostics.fallback = "renderer unavailable"
        }
        lastEnhancementFrameTimeMs = diagnostics.enhancementFrameTimeMs
        emitDiagnosticsIfNeeded(diagnostics, force: !diagnostics.fallback.isEmpty)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private func updateDrawableSizeForCurrentBackingScale() {
        var scale = window?.backingScaleFactor ?? 0
        if scale <= 0 { scale = metalView.window?.backingScaleFactor ?? 0 }
        if scale <= 0 { scale = NSScreen.main?.backingScaleFactor ?? 1 }
        if scale <= 0 { scale = 1 }
        let boundsSize = metalView.bounds.size
        guard boundsSize.width > 0, boundsSize.height > 0 else { return }
        var drawableSize = CGSize(width: max(1, floor(boundsSize.width * scale)), height: max(1, floor(boundsSize.height * scale)))
        if localVideoEnhancement().mode > 0 {
            drawableSize = enhancementDrawableSize(for: boundsSize, scale: scale)
        }
        let currentSize = metalView.drawableSize
        if Int(currentSize.width.rounded()) != Int(drawableSize.width.rounded()) || Int(currentSize.height.rounded()) != Int(drawableSize.height.rounded()) {
            metalView.drawableSize = drawableSize
        }
        drawableSizeDirty = false
    }

    private func enhancementDrawableSize(for boundsSize: CGSize, scale: CGFloat) -> CGSize {
        let backingSize = CGSize(width: max(1, floor(boundsSize.width * scale)), height: max(1, floor(boundsSize.height * scale)))
        var aspect = boundsSize.height > 0 ? boundsSize.width / boundsSize.height : 16.0 / 9.0
        if aspect <= 0.1 || !aspect.isFinite { aspect = 16.0 / 9.0 }
        let enhancement = localVideoEnhancement()
        var targetHeightPixels = CGFloat(max(1440, min(Int(enhancement.targetHeight), 2160)))
        if enhancement.mode == 1, metalDeviceIsAppleM1Class(metalView.device) {
            targetHeightPixels = min(targetHeightPixels, 1440)
        }
        let targetWidth = targetHeightPixels * aspect
        let targetHeight = targetWidth / aspect
        return CGSize(width: max(backingSize.width, floor(targetWidth)), height: max(backingSize.height, floor(targetHeight)))
    }

    private func renderEnhancedFrame(_ frame: RTCVideoFrame, drawSerial: UInt64, sourceSize: CGSize, enhancement: VideoEnhancement, diagnostics: inout RenderDiagnostics) -> Bool {
        guard let enhancementRenderer else { return false }
        let settings = enhancementSettings
        switch enhancement.mode {
        case 4: settings.configuredTier = .temporal
        case 3: settings.configuredTier = .metalFX
        case 2: settings.configuredTier = .spatial
        default: settings.configuredTier = automaticEnhancementTier(renderer: enhancementRenderer, device: metalView.device)
        }
        settings.sharpness = Int(enhancement.sharpness)
        settings.denoise = Int(enhancement.denoise)
        settings.sourceSize = sourceSize
        settings.drawableSize = metalView.drawableSize
        settings.targetFrameTimeMs = 1000.0 / Double(max(1, targetFps))
        settings.captureEnhancedPixelBuffer = owner?.wantsEnhancedVideoFrames() == true
        settings.lowCostSpatial = adaptiveEnhancementPenalty > 0
        let diagnosticsNow = CACurrentMediaTime()
        settings.emitDiagnostics = lastDiagnosticsUpdateTime <= 0 || diagnosticsNow - lastDiagnosticsUpdateTime >= 1.0

        let result = enhancementResult
        if enhancementRenderer.renderFrame(frame, to: metalView, settings: settings, result: result) {
            diagnostics.pixelFormat = result.pixelFormat.isEmpty ? "unknown" : result.pixelFormat
            diagnostics.renderMode = result.renderMode.isEmpty ? "Upscaler" : result.renderMode
            diagnostics.frameSource = result.frameSource.isEmpty ? "processed frame" : result.frameSource
            diagnostics.renderPath = result.renderPath.isEmpty ? "OPNVideoEnhancementRenderer" : result.renderPath
            diagnostics.fallback = result.fallbackReason
            diagnostics.enhancementConfiguredTier = result.configuredTier.isEmpty ? "Upscaler" : result.configuredTier
            diagnostics.enhancementActiveTier = result.activeTier.isEmpty ? "Enhanced" : result.activeTier
            diagnostics.enhancementFallbackReason = result.tierFallbackReason
            diagnostics.sourceResolution = result.sourceResolution.isEmpty ? diagnostics.sourceResolution : result.sourceResolution
            diagnostics.drawableResolution = result.drawableResolution.isEmpty ? diagnostics.drawableResolution : result.drawableResolution
            diagnostics.enhancementDiagnostics = result.diagnostics
            diagnostics.enhancementFrameTimeMs = result.frameTimeMs
            enhancementDroppedFrameCount = result.droppedFrames
            lastDrawnFrameSerial = drawSerial
            adaptEnhancementBudget(frameTimeMs: result.frameTimeMs, targetFrameTimeMs: settings.targetFrameTimeMs)
            if let enhancedPixelBuffer = result.enhancedPixelBuffer {
                owner?.handleEnhancedVideoFrame(enhancedPixelBuffer)
                result.enhancedPixelBuffer = nil
            }
            lastEnhancementFrameTimeMs = diagnostics.enhancementFrameTimeMs
            return true
        }

        diagnostics.fallback = result.fallbackReason.isEmpty ? "processed renderer unavailable; using WebRTC renderer" : result.fallbackReason
        diagnostics.enhancementConfiguredTier = result.configuredTier.isEmpty ? "Upscaler" : result.configuredTier
        diagnostics.enhancementActiveTier = "Native fallback"
        diagnostics.enhancementFallbackReason = result.tierFallbackReason.isEmpty ? diagnostics.fallback : result.tierFallbackReason
        diagnostics.sourceResolution = result.sourceResolution.isEmpty ? diagnostics.sourceResolution : result.sourceResolution
        diagnostics.drawableResolution = result.drawableResolution.isEmpty ? diagnostics.drawableResolution : result.drawableResolution
        diagnostics.enhancementDiagnostics = result.diagnostics
        enhancementDroppedFrameCount = result.droppedFrames
        return false
    }

    private func adaptEnhancementBudget(frameTimeMs: Double, targetFrameTimeMs: Double) {
        if frameTimeMs > targetFrameTimeMs * 1.15 {
            enhancementOverBudgetCount += 1
            if enhancementOverBudgetCount >= 10 {
                adaptiveEnhancementPenalty = min(2, adaptiveEnhancementPenalty + 1)
                enhancementOverBudgetCount = 0
            }
        } else if frameTimeMs > 0, frameTimeMs < targetFrameTimeMs * 0.72 {
            enhancementOverBudgetCount = 0
            if adaptiveEnhancementPenalty > 0 { adaptiveEnhancementPenalty -= 1 }
        }
    }

    private func rendererForFrame(_ frame: RTCVideoFrame, diagnostics: inout RenderDiagnostics) -> OPNRTCMetalRenderer? {
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
                diagnostics.fallback = fallback.isEmpty ? "RGB unavailable; using I420" : fallback
            } else {
                diagnostics.fallback = "unsupported CVPixelBuffer; using I420"
            }
        } else {
            diagnostics.frameSource = NSStringFromClass(type(of: frame.buffer as AnyObject))
            diagnostics.pixelFormat = "I420"
        }
        diagnostics.renderMode = "I420"
        diagnostics.renderPath = "RTCMTLI420Renderer"
        return i420Renderer(fallback: &diagnostics.fallback)
    }

    private func newRenderer(named className: String, fallback: inout String) -> OPNRTCMetalRenderer? {
        guard let rendererClass = NSClassFromString(className) as? NSObject.Type else {
            fallback = "\(className) unavailable"
            return nil
        }
        guard let renderer = rendererClass.init() as? OPNRTCMetalRenderer else {
            fallback = "\(className) does not conform to renderer protocol"
            return nil
        }
        guard renderer.addRenderingDestination(metalView) else {
            fallback = "\(className) rejected MTKView"
            return nil
        }
        metalView.isPaused = false
        metalView.enableSetNeedsDisplay = false
        metalView.preferredFramesPerSecond = targetFps
        return renderer
    }

    private func i420Renderer(fallback: inout String) -> OPNRTCMetalRenderer? {
        if rendererI420 == nil { rendererI420 = newRenderer(named: "RTCMTLI420Renderer", fallback: &fallback) }
        return rendererI420
    }

    private func emitDiagnosticsIfNeeded(_ diagnostics: RenderDiagnostics, force: Bool) {
        let now = CACurrentMediaTime()
        guard force || lastDiagnosticsUpdateTime <= 0 || now - lastDiagnosticsUpdateTime >= 1.0 else { return }
        lastDiagnosticsUpdateTime = now
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
            enhancementDroppedFrames: enhancementDroppedFrameCount
        )
    }

    private func localVideoEnhancement() -> VideoEnhancement {
        let values = owner?.localVideoEnhancement() ?? (0, 0, 0, 2160)
        return VideoEnhancement(mode: values.0, sharpness: values.1, denoise: values.2, targetHeight: values.3)
    }

    private func synchronized<T>(_ body: () -> T) -> T {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        return body()
    }
}

private struct VideoEnhancement {
    var mode: Int32
    var sharpness: Int32
    var denoise: Int32
    var targetHeight: Int32
}

private struct RenderDiagnostics {
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
}

private func videoResolutionString(_ size: CGSize) -> String {
    let width = Int(max(CGFloat(0), size.width).rounded())
    let height = Int(max(CGFloat(0), size.height).rounded())
    return width > 0 && height > 0 ? "\(width)x\(height)" : "unknown"
}

@MainActor
private func metalDeviceIsAppleM1Class(_ device: (any MTLDevice)?) -> Bool {
    device?.name.lowercased().hasPrefix("apple m1") == true
}

@MainActor
private func automaticEnhancementTier(renderer: OPNVideoEnhancementRenderer, device: (any MTLDevice)?) -> OPNVideoEnhancementTier {
    if metalDeviceIsAppleM1Class(device) {
        return renderer.isMetalFXAvailable ? .metalFX : .spatial
    }
    if renderer.isTemporalAvailable { return .temporal }
    return renderer.isMetalFXAvailable ? .metalFX : .spatial
}

private func pixelFormatName(_ format: OSType) -> String {
    switch format {
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: return "420v/NV12"
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: return "420f/NV12"
    case kCVPixelFormatType_32BGRA: return "BGRA"
    case kCVPixelFormatType_32ARGB: return "ARGB"
    default: return String(format: "0x%08x", format)
    }
}
