import AppKit
import CoreVideo
import Darwin
import Foundation
import Metal
import MetalKit
import ObjectiveC
import QuartzCore
@preconcurrency import WebRTC

@objc protocol OPNRTCMetalRenderer: NSObjectProtocol {
    @objc(addRenderingDestination:)
    func addRenderingDestination(_ view: MTKView) -> Bool

    @objc(drawFrame:)
    func drawFrame(_ frame: RTCVideoFrame)
}

final class OPNObjCMetalRenderer: NSObject, OPNRTCMetalRenderer {
    private let renderer: NSObject
    private let addDestinationSelector = NSSelectorFromString("addRenderingDestination:")
    private let drawFrameSelector = NSSelectorFromString("drawFrame:")

    init?(_ renderer: NSObject) {
        guard renderer.responds(to: addDestinationSelector), renderer.responds(to: drawFrameSelector) else { return nil }
        self.renderer = renderer
    }

    func addRenderingDestination(_ view: MTKView) -> Bool {
        typealias AddRenderingDestination = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        let implementation = renderer.method(for: addDestinationSelector)
        let call = unsafeBitCast(implementation, to: AddRenderingDestination.self)
        return call(renderer, addDestinationSelector, view)
    }

    func drawFrame(_ frame: RTCVideoFrame) {
        typealias DrawFrame = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        let implementation = renderer.method(for: drawFrameSelector)
        let call = unsafeBitCast(implementation, to: DrawFrame.self)
        call(renderer, drawFrameSelector, frame)
    }
}

@objc(OPNMetalVideoView)
@MainActor
final class OPNMetalVideoView: NSView, RTCVideoRenderer, MTKViewDelegate {
    let metalView: MTKView
    nonisolated(unsafe) var videoFrame: RTCVideoFrame?
    var rendererNV12: OPNRTCMetalRenderer?
    var rendererRGB: OPNRTCMetalRenderer?
    var rendererI420: OPNRTCMetalRenderer?
    var commandQueue: (any MTLCommandQueue)?
    var enhancementRenderer: OPNVideoEnhancementRenderer?
    nonisolated(unsafe) var sourceFrameSize = CGSize.zero
    let targetFps: Int
    nonisolated(unsafe) var frameSerial: UInt64 = 0
    var lastDrawnFrameSerial: UInt64 = 0
    var lastDrawCadenceTime: CFTimeInterval = 0
    var drawIntervalTotalMs = 0.0
    var drawIntervalMaxMs = 0.0
    var drawIntervalCount = 0
    var enhancementDroppedFrameCount: UInt64 = 0
    private var lastEnhancementFrameTimeMs = -1.0
    var lastDiagnosticsUpdateTime: CFTimeInterval = 0
    nonisolated(unsafe) var drawableSizeDirty = true
    private var enhancementSettings = OPNVideoEnhancementSettings()
    private var enhancementResult = OPNVideoEnhancementResult()
    private var enhancementOverBudgetCount = 0
    private var lastLoggedFallbackReason = ""
    private var adaptiveEnhancementPenalty = 0
    var customDrawableRenderingEnabled = false
    nonisolated(unsafe) weak var owner: OPNLibWebRTCStreamSession?
    /// Enhancement/pillarbox settings for renderers with no libwebrtc session behind them. The
    /// Bifrost-free NVST path owns its own decoder, so there is no `OPNLibWebRTCStreamSession` to
    /// ask and every setting silently stayed at its default — which is why pillarbox fill did
    /// nothing on that transport. When set this wins over `owner`; everything downstream (the
    /// enhancement pass, the pillarbox detector, the fill shader) is shared, so NVST gets all the
    /// same modes without a second implementation.
    nonisolated(unsafe) var enhancementOverride: (Int32, Int32, Int32, Int32, Int32, Int32, Int32)?
    nonisolated(unsafe) var enhancementOverrideLock = os_unfair_lock_s()
    nonisolated(unsafe) var frameLock = os_unfair_lock_s()
    nonisolated(unsafe) private var cachedPixelFormat: OSType = 0
    nonisolated(unsafe) var cachedIsTenBitBiPlanar = false
    nonisolated(unsafe) private var pixelFormatCached = false
    /// The drawable format and transfer function the latest frame wants. Re-read on every frame:
    /// a stream can switch to 10-bit or HDR at a keyframe without changing size, which is the only
    /// event the older per-size cache above keyed on.
    nonisolated(unsafe) var desiredOutputFormat: MTLPixelFormat = .bgra8Unorm
    nonisolated(unsafe) var desiredTransfer = OPNVideoTransferFunction.sdr
    var appliedTransfer = OPNVideoTransferFunction.sdr
    nonisolated(unsafe) var framesReceived: UInt64 = 0
    var framesDrawn: UInt64 = 0
    nonisolated(unsafe) var presentationMode = OPNVideoPresentationMode.balanced
    /// `smooth` only: frames waiting for a refresh, oldest first. Capped at two so a stall cannot
    /// build a latency debt; anything older than the newest two is dropped like `balanced` does.
    nonisolated(unsafe) var pendingFrames: [(frame: RTCVideoFrame, serial: UInt64, receivedAt: CFTimeInterval)] = []
    /// When the newest frame reached `renderFrame`, for the presented-time measurement.
    nonisolated(unsafe) var latestFrameReceivedAt: CFTimeInterval = 0
    /// Presented-time accounting, filled from the drawable's presented handler on a Metal thread.
    nonisolated(unsafe) var presentLock = os_unfair_lock_s()
    nonisolated(unsafe) var presentLatencyTotalMs = 0.0
    nonisolated(unsafe) var presentLatencyMaxMs = 0.0
    nonisolated(unsafe) var presentCount = 0
    nonisolated(unsafe) var lastPresentedAt: CFTimeInterval = 0
    nonisolated(unsafe) var lastPresentInterval = -1.0
    nonisolated(unsafe) var presentJitterTotalMs = 0.0
    nonisolated(unsafe) var presentJitterCount = 0
    /// `lowestLatency` only: `draw()` is driven from the decode thread; two completions must not
    /// enter the render pass together.
    nonisolated(unsafe) var manualDrawLock = os_unfair_lock_s()
    /// The same MTKView, reachable from the decode thread for the manual `draw()` call. MTKView
    /// already invokes `draw(in:)` off the main thread from its own display link, so the render
    /// path is written for that; this only changes who kicks it.
    let metalViewForManualDraw: MTKView
    /// A one-shot request to write the next drawn frame — the drawable itself, after our render
    /// pass — as a JPEG. Set on the main actor, consumed on the render thread under `frameLock`.
    nonisolated(unsafe) var pendingRenderSnapshotURL: URL?
    /// Owner-less diagnostics sink (the NVST path). Called about once a second from the render
    /// thread.
    nonisolated(unsafe) var renderDiagnosticsHandler: (@Sendable (OPNVideoRenderDiagnosticsSnapshot) -> Void)?

    init(frame frameRect: NSRect, targetFps: Int32, owner: OPNLibWebRTCStreamSession?) {
        self.owner = owner
        self.targetFps = min(max(Int(targetFps), 30), 240)
        metalView = MTKView(frame: frameRect, device: MTLCreateSystemDefaultDevice())
        metalViewForManualDraw = metalView
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        metalView.frame = bounds
        metalView.autoresizingMask = [.width, .height]
        metalView.framebufferOnly = true
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.depthStencilPixelFormat = .invalid
        metalView.sampleCount = 1
        metalView.autoResizeDrawable = false
        metalView.preferredFramesPerSecond = self.targetFps
        metalView.isPaused = false
        metalView.enableSetNeedsDisplay = false
        metalView.delegate = self
        metalView.layerContentsPlacement = .scaleProportionallyToFit
        if let metalLayer = metalView.layer as? CAMetalLayer {
            metalLayer.presentsWithTransaction = false
            metalLayer.allowsNextDrawableTimeout = false
            if #available(macOS 10.13, *) {
                metalLayer.maximumDrawableCount = 2
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
        markDrawableSizeDirty(true)
        updateDrawableSizeForCurrentBackingScale()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resetDrawCadence()
        markDrawableSizeDirty(true)
        updateDrawableSizeForCurrentBackingScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        markDrawableSizeDirty(true)
        updateDrawableSizeForCurrentBackingScale()
    }

    nonisolated private func drawableSizeNeedsUpdate() -> Bool {
        os_unfair_lock_lock(&frameLock)
        defer { os_unfair_lock_unlock(&frameLock) }
        return drawableSizeDirty
    }

    nonisolated private func markDrawableSizeDirty(_ dirty: Bool) {
        os_unfair_lock_lock(&frameLock)
        drawableSizeDirty = dirty
        os_unfair_lock_unlock(&frameLock)
    }

    nonisolated func setSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        os_unfair_lock_lock(&frameLock)
        sourceFrameSize = size
        pixelFormatCached = false
        os_unfair_lock_unlock(&frameLock)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.markDrawableSizeDirty(true)
            self.resetDrawCadence()
            self.updateDrawableSizeForCurrentBackingScale()
        }
    }

    nonisolated func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        owner?.handleVideoFrame(Unmanaged.passUnretained(frame).toOpaque())
        var output: (MTLPixelFormat, OPNVideoTransferFunction)?
        if let buffer = frame.buffer as? RTCCVPixelBuffer {
            output = Self.desiredOutput(for: buffer.pixelBuffer)
        }
        os_unfair_lock_lock(&frameLock)
        if !pixelFormatCached, let buffer = frame.buffer as? RTCCVPixelBuffer {
            let format = CVPixelBufferGetPixelFormatType(buffer.pixelBuffer)
            cachedPixelFormat = format
            cachedIsTenBitBiPlanar = OPNVideoTextureSource.isTenBitBiPlanarFormat(format)
            pixelFormatCached = true
        }
        if let output {
            desiredOutputFormat = output.0
            desiredTransfer = output.1
        }
        videoFrame = frame
        frameSerial += 1
        framesReceived &+= 1
        let receivedAt = CACurrentMediaTime()
        latestFrameReceivedAt = receivedAt
        let mode = presentationMode
        if mode == .smooth {
            pendingFrames.append((frame, frameSerial, receivedAt))
            if pendingFrames.count > 2 { pendingFrames.removeFirst(pendingFrames.count - 2) }
        }
        os_unfair_lock_unlock(&frameLock)
        if mode == .lowestLatency {
            os_unfair_lock_lock(&manualDrawLock)
            // Deliberately off the main actor: this is the decode thread kicking a draw the
            // moment a frame lands, which is the whole point of the mode. `MTKView.draw()` is
            // main-actor-annotated in the SDK, though MTKView itself calls `draw(in:)` from its
            // display-link thread; the ObjC dispatch says what the annotation cannot.
            _ = metalViewForManualDraw.perform(#selector(MTKView.draw as (MTKView) -> () -> Void))
            os_unfair_lock_unlock(&manualDrawLock)
        }
    }

    func draw(in view: MTKView) {
        guard view == metalView else { return }
        // MTKView's internal display link invokes this on a background render thread,
        // where querying window/backingScaleFactor trips AppKit's main-thread checker.
        // Defer the drawable-size recompute to the main actor; rendering proceeds into
        // the current drawable and catches up a frame later.
        synchronizeDrawableSize()

        guard let next = nextFrameToDraw(), next.frame.width > 0, next.frame.height > 0 else { return }
        let frame = next.frame
        let snapshot = (frame, next.serial, next.sourceSize, next.tenBit)
        if applyOutputFormatIfNeeded(next.output.0, transfer: next.output.1) { return }
        attachPresentedHandler(receivedAt: next.receivedAt)

        let sourceSize = snapshot.2.width > 0 && snapshot.2.height > 0 ? snapshot.2 : CGSize(width: Int(frame.width), height: Int(frame.height))
        var diagnostics = RenderDiagnostics(sourceResolution: videoResolutionString(sourceSize), drawableResolution: videoResolutionString(metalView.drawableSize))
        let enhancement = budgetedEnhancement()
        if drawableSizeDirty { updateDrawableSizeForCurrentBackingScale() }

        let needsCustomPath = enhancement.mode > 0 || enhancement.fillMode.needsCustomRenderPath
        if needsCustomPath {
            setCustomDrawableRenderingEnabled(true)
        }
        if needsCustomPath, renderEnhancedFrame(frame, drawSerial: snapshot.1, sourceSize: sourceSize, enhancement: enhancement, diagnostics: &diagnostics) {
            captureDrawableIfRequested()
            emitDiagnosticsIfNeeded(diagnostics, force: !diagnostics.fallback.isEmpty)
            return
        }

        let tenBitFrame = snapshot.3
        if tenBitFrame {
            setCustomDrawableRenderingEnabled(true)
        }
        if tenBitFrame, renderTenBitFrame(frame, drawSerial: snapshot.1, sourceSize: sourceSize, diagnostics: &diagnostics) {
            captureDrawableIfRequested()
            emitDiagnosticsIfNeeded(diagnostics, force: !diagnostics.fallback.isEmpty)
            return
        }

        setCustomDrawableRenderingEnabled(false)
        let renderer = rendererForFrame(frame, diagnostics: &diagnostics)
        if let renderer {
            renderer.drawFrame(frame)
            lastDrawnFrameSerial = snapshot.1
            recordDrawCadence()
            captureDrawableIfRequested()
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
        let enhancement = localVideoEnhancement()
        if enhancement.mode > 0 {
            drawableSize = Self.enhancementDrawableSize(boundsSize: boundsSize, scale: scale, targetHeight: Int(enhancement.targetHeight))
        }
        let currentSize = metalView.drawableSize
        if Int(currentSize.width.rounded()) != Int(drawableSize.width.rounded()) || Int(currentSize.height.rounded()) != Int(drawableSize.height.rounded()) {
            metalView.drawableSize = drawableSize
            resetDrawCadence()
        }
        markDrawableSizeDirty(false)
    }

    /// The enhancement drawable follows the window like the plain path, but never renders past
    /// `targetHeight` pixels tall. A window smaller than the target is a no-op (min()) — this caps
    /// upscaling cost, it never supersamples beyond what the window would already draw at.
    nonisolated static func enhancementDrawableSize(boundsSize: CGSize, scale: CGFloat, targetHeight: Int) -> CGSize {
        guard boundsSize.height > 0 else { return CGSize(width: max(1, boundsSize.width), height: 1) }
        let uncappedHeight = max(1, floor(boundsSize.height * scale))
        let cappedHeight = floor(min(uncappedHeight, CGFloat(max(1, targetHeight))))
        let aspect = boundsSize.width / boundsSize.height
        let width = max(1, floor(cappedHeight * aspect))
        return CGSize(width: width, height: max(1, cappedHeight))
    }

    /// Fills in the shared settings object for this frame. Fill with upscaling off borrows the
    /// spatial path in its cheapest form: `lowCostSpatial` selects the plain-sample `fast_*`
    /// shaders, so the picture area is untouched and only the bar columns cost anything extra.
    func configuredEnhancementSettings(enhancement: VideoEnhancement,
                                               sourceSize: CGSize,
                                               renderer: OPNVideoEnhancementRenderer) -> OPNVideoEnhancementSettings {
        let settings = enhancementSettings
        // Fill with upscaling off: borrow the spatial path in its cheapest form.
        // lowCostSpatial selects the plain-sample `fast_*` shaders, so the picture
        // area is untouched and only the bar columns cost anything extra.
        let fillOnly = enhancement.mode == 0
        switch enhancement.mode {
        case 4: settings.configuredTier = .temporal
        case 3: settings.configuredTier = .metalFX
        case 2: settings.configuredTier = .spatial
        case 0: settings.configuredTier = .spatial
        default: settings.configuredTier = automaticEnhancementTier(renderer: renderer, device: metalView.device)
        }
        settings.pillarboxFillMode = Int(enhancement.pillarboxFillMode)
        settings.pillarboxFillDim = Float(enhancement.pillarboxFillDim) / 100.0
        settings.pillarboxFillColor = enhancement.pillarboxFillColor
        settings.sharpness = fillOnly ? 0 : Int(enhancement.sharpness)
        settings.denoise = fillOnly ? 0 : Int(enhancement.denoise)
        settings.sourceSize = sourceSize
        settings.drawableSize = metalView.drawableSize
        settings.targetFrameTimeMs = 1000.0 / Double(max(1, targetFps))
        settings.captureEnhancedPixelBuffer = owner?.wantsEnhancedVideoFrames() == true
        settings.lowCostSpatial = fillOnly || adaptiveEnhancementPenalty > 0
        return settings
    }

    /// Copies an accepted enhanced frame's result into the HUD diagnostics and the adaptive budget.
    private func applyEnhancementSuccess(_ result: OPNVideoEnhancementResult,
                                         drawSerial: UInt64,
                                         targetFrameTimeMs: Double,
                                         diagnostics: inout RenderDiagnostics) {
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
        recordDrawCadence()
        adaptEnhancementBudget(frameTimeMs: result.frameTimeMs, targetFrameTimeMs: targetFrameTimeMs)
        if let enhancedPixelBuffer = result.enhancedPixelBuffer {
            owner?.handleEnhancedVideoFrame(enhancedPixelBuffer)
            result.enhancedPixelBuffer = nil
        }
        lastEnhancementFrameTimeMs = diagnostics.enhancementFrameTimeMs
    }

    /// MTKView's internal display link invokes `draw(in:)` on a background render thread, where
    /// querying window/backingScaleFactor trips AppKit's main-thread checker. Defer the recompute to
    /// the main actor; rendering proceeds into the current drawable and catches up a frame later.
    private func synchronizeDrawableSize() {
        guard drawableSizeNeedsUpdate() else { return }
        guard Thread.isMainThread else {
            Task { @MainActor [weak self] in
                guard let self, self.drawableSizeNeedsUpdate() else { return }
                self.updateDrawableSizeForCurrentBackingScale()
            }
            return
        }
        updateDrawableSizeForCurrentBackingScale()
    }

    /// The requested enhancement, stepped down while the adaptive budget is over. Each penalty
    /// level drops to the next cheaper tier rather than switching the picture off outright.
    private func budgetedEnhancement() -> VideoEnhancement {
        var enhancement = localVideoEnhancement()
        guard adaptiveEnhancementPenalty > 0, let enhancementRenderer else { return enhancement }
        if enhancement.mode == 4 {
            enhancement.mode = enhancementRenderer.isMetalFXAvailable ? 3 : 2
        } else if enhancement.mode == 3, !enhancementRenderer.isMetalFXAvailable {
            enhancement.mode = 2
        } else if enhancement.mode == 2, adaptiveEnhancementPenalty > 1 {
            enhancement.mode = 0
        }
        return enhancement
    }

    private func renderEnhancedFrame(_ frame: RTCVideoFrame, drawSerial: UInt64, sourceSize: CGSize, enhancement: VideoEnhancement, diagnostics: inout RenderDiagnostics) -> Bool {
        guard let enhancementRenderer else { return false }
        let settings = configuredEnhancementSettings(enhancement: enhancement, sourceSize: sourceSize, renderer: enhancementRenderer)
        let diagnosticsNow = CACurrentMediaTime()
        settings.emitDiagnostics = lastDiagnosticsUpdateTime <= 0 || diagnosticsNow - lastDiagnosticsUpdateTime >= 1.0

        let result = enhancementResult
        let enhancedOK = enhancementRenderer.renderFrame(frame, to: metalView, settings: settings, result: result)
        if !enhancedOK, enhancement.fillMode.needsCustomRenderPath, result.fallbackReason != lastLoggedFallbackReason {
            lastLoggedFallbackReason = result.fallbackReason
            OpenNOWLog.info(.stream, "Pillarbox custom path FELL BACK: \(result.fallbackReason)")
        }
        if enhancedOK {
            applyEnhancementSuccess(result, drawSerial: drawSerial, targetFrameTimeMs: settings.targetFrameTimeMs, diagnostics: &diagnostics)
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

    private func renderTenBitFrame(_ frame: RTCVideoFrame, drawSerial: UInt64, sourceSize: CGSize, diagnostics: inout RenderDiagnostics) -> Bool {
        guard let enhancementRenderer else { return false }
        let settings = enhancementSettings
        settings.configuredTier = .spatial
        let enhancement = localVideoEnhancement()
        settings.pillarboxFillMode = Int(enhancement.pillarboxFillMode)
        settings.pillarboxFillDim = Float(enhancement.pillarboxFillDim) / 100.0
        settings.pillarboxFillColor = enhancement.pillarboxFillColor
        settings.sharpness = 0
        settings.denoise = 0
        settings.sourceSize = sourceSize
        settings.drawableSize = metalView.drawableSize
        settings.targetFrameTimeMs = 1000.0 / Double(max(1, targetFps))
        settings.captureEnhancedPixelBuffer = false
        settings.lowCostSpatial = true
        settings.emitDiagnostics = lastDiagnosticsUpdateTime <= 0 || CACurrentMediaTime() - lastDiagnosticsUpdateTime >= 1.0

        let result = enhancementResult
        if enhancementRenderer.renderFrame(frame, to: metalView, settings: settings, result: result) {
            diagnostics.pixelFormat = result.pixelFormat.isEmpty ? "P010" : result.pixelFormat
            diagnostics.renderMode = "P010"
            diagnostics.frameSource = result.frameSource.isEmpty ? "CVPixelBuffer" : result.frameSource
            diagnostics.renderPath = result.renderPath.isEmpty ? "OPNMetalSpatialUpscalerSwift" : result.renderPath
            diagnostics.fallback = result.fallbackReason
            diagnostics.enhancementConfiguredTier = "Off"
            diagnostics.enhancementActiveTier = "Native 10-bit"
            diagnostics.enhancementFallbackReason = result.tierFallbackReason
            diagnostics.sourceResolution = result.sourceResolution.isEmpty ? diagnostics.sourceResolution : result.sourceResolution
            diagnostics.drawableResolution = result.drawableResolution.isEmpty ? diagnostics.drawableResolution : result.drawableResolution
            diagnostics.enhancementDiagnostics = result.diagnostics
            diagnostics.enhancementFrameTimeMs = result.frameTimeMs
            enhancementDroppedFrameCount = result.droppedFrames
            lastDrawnFrameSerial = drawSerial
            recordDrawCadence()
            lastEnhancementFrameTimeMs = diagnostics.enhancementFrameTimeMs
            return true
        }
        diagnostics.fallback = result.fallbackReason.isEmpty ? "P010 renderer unavailable" : result.fallbackReason
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

}

/// 2/3/4 are real tier codes (`renderEnhancedFrame`'s own switch: spatial/MetalFX/temporal) that a
/// caller can now select explicitly. 1 predates tier selection — it only ever meant "some
/// enhancement is on" — so it keeps resolving to MetalFX rather than becoming a new, unintended tier.
func normalizedEnhancementMode(_ mode: Int32) -> Int32 {
    switch mode {
    case 0: return 0
    case 2: return 2
    case 3: return 3
    case 4: return 4
    case 1: return 3
    default: return 0
    }
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

func pixelFormatName(_ format: OSType) -> String {
    switch format {
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: return "420v/NV12"
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: return "420f/NV12"
    case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: return "x420/P010"
    case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: return "xf20/P010"
    case kCVPixelFormatType_32BGRA: return "BGRA"
    case kCVPixelFormatType_32ARGB: return "ARGB"
    default: return String(format: "0x%08x", format)
    }
}

// MARK: - Renderer selection and diagnostics

// Split out of the main declaration so it stays inside the size budget. Same file, so `private`
// members stay reachable.
