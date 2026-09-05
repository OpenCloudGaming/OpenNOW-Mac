import AppKit
import CoreVideo
import Darwin
import Foundation
import Metal
import MetalKit
import ObjectiveC
import QuartzCore
@preconcurrency import WebRTC

@objc private protocol OPNRTCMetalRenderer: NSObjectProtocol {
    @objc(addRenderingDestination:)
    func addRenderingDestination(_ view: MTKView) -> Bool

    @objc(drawFrame:)
    func drawFrame(_ frame: RTCVideoFrame)
}

private final class OPNObjCMetalRenderer: NSObject, OPNRTCMetalRenderer {
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

/// How decoded frames meet the display.
///
/// Measured 2026-09-04 on a 120 Hz panel with a 120 fps stream: decode completions arrive in bursts
/// of two per refresh often enough that `balanced` — draw the newest frame at each refresh — left
/// ~17% of received frames undrawn (`skipped 1493` of ~8600). The other two modes trade that
/// against latency in opposite directions.
enum OPNVideoPresentationMode: Int, Sendable {
    /// Newest decoded frame at each display refresh. What the view always did.
    case balanced = 0
    /// A queue of one: the oldest undrawn frame at each refresh, so a burst of two both get shown
    /// a refresh apart. Even cadence for about one frame of added latency.
    case smooth = 1
    /// Present as soon as a frame decodes, without waiting for the refresh (`displaySyncEnabled`
    /// off, the display link paused). Lowest latency; tearing is possible.
    case lowestLatency = 2

    var label: String {
        switch self {
        case .balanced: "balanced"
        case .smooth: "smooth"
        case .lowestLatency: "lowest latency"
        }
    }
}

/// What the renderer is actually doing, for a HUD with no libwebrtc session to ask. The
/// Bifrost-free NVST path owns its own decoder, so `OPNLibWebRTCStreamSession`'s diagnostics
/// never reach it; this is the owner-less equivalent.
struct OPNVideoRenderDiagnosticsSnapshot: Equatable, Sendable {
    /// The decoded surface (`xf20/P010`, `420f/NV12`, ...).
    var pixelFormat = ""
    /// The drawable the frame was presented into (`bgra8`, `bgr10a2`, `rgba16f`).
    var outputFormat = ""
    var renderPath = ""
    var activeTier = ""
    var fallback = ""
    /// Whether the layer is presenting extended-dynamic-range content (PQ or HLG stream).
    var isHDR = false
    var frameIntervalMs = -1.0
    var maxFrameIntervalMs = -1.0
    /// Frames handed to the renderer and frames it actually drew. The difference is frames the
    /// display loop never got to — decode running ahead of the refresh, or a stalled draw.
    var framesReceived: UInt64 = 0
    var framesDrawn: UInt64 = 0
    var presentationMode = ""
    /// Decode-to-glass: from the frame reaching the renderer to the drawable's presented time,
    /// mean and worst over the last diagnostics window; -1 with no presents in the window.
    var presentLatencyMs = -1.0
    var presentLatencyMaxMs = -1.0
    /// Mean absolute deviation of consecutive present intervals, ms — the judder number.
    var presentJitterMs = -1.0
    /// Picture content span as fractions of frame width, from the pillarbox detector; 0...1 when
    /// the frame has no bars (or nothing has been measured yet).
    var contentLeft = 0.0
    var contentRight = 1.0
}

@objc(OPNMetalVideoView)
@MainActor
final class OPNMetalVideoView: NSView, RTCVideoRenderer, MTKViewDelegate {
    private let metalView: MTKView
    nonisolated(unsafe) private var videoFrame: RTCVideoFrame?
    private var rendererNV12: OPNRTCMetalRenderer?
    private var rendererRGB: OPNRTCMetalRenderer?
    private var rendererI420: OPNRTCMetalRenderer?
    private var commandQueue: (any MTLCommandQueue)?
    private var enhancementRenderer: OPNVideoEnhancementRenderer?
    nonisolated(unsafe) private var sourceFrameSize = CGSize.zero
    private let targetFps: Int
    nonisolated(unsafe) private var frameSerial: UInt64 = 0
    private var lastDrawnFrameSerial: UInt64 = 0
    private var lastDrawCadenceTime: CFTimeInterval = 0
    private var drawIntervalTotalMs = 0.0
    private var drawIntervalMaxMs = 0.0
    private var drawIntervalCount = 0
    private var enhancementDroppedFrameCount: UInt64 = 0
    private var lastEnhancementFrameTimeMs = -1.0
    private var lastDiagnosticsUpdateTime: CFTimeInterval = 0
    nonisolated(unsafe) private var drawableSizeDirty = true
    private var enhancementSettings = OPNVideoEnhancementSettings()
    private var enhancementResult = OPNVideoEnhancementResult()
    private var enhancementOverBudgetCount = 0
    private var lastLoggedFallbackReason = ""
    private var adaptiveEnhancementPenalty = 0
    private var customDrawableRenderingEnabled = false
    nonisolated(unsafe) private weak var owner: OPNLibWebRTCStreamSession?
    /// Enhancement/pillarbox settings for renderers with no libwebrtc session behind them. The
    /// Bifrost-free NVST path owns its own decoder, so there is no `OPNLibWebRTCStreamSession` to
    /// ask and every setting silently stayed at its default — which is why pillarbox fill did
    /// nothing on that transport. When set this wins over `owner`; everything downstream (the
    /// enhancement pass, the pillarbox detector, the fill shader) is shared, so NVST gets all the
    /// same modes without a second implementation.
    nonisolated(unsafe) private var enhancementOverride: (Int32, Int32, Int32, Int32, Int32, Int32, Int32)?
    nonisolated(unsafe) private var enhancementOverrideLock = os_unfair_lock_s()
    nonisolated(unsafe) private var frameLock = os_unfair_lock_s()
    nonisolated(unsafe) private var cachedPixelFormat: OSType = 0
    nonisolated(unsafe) private var cachedIsTenBitBiPlanar = false
    nonisolated(unsafe) private var pixelFormatCached = false
    /// The drawable format and transfer function the latest frame wants. Re-read on every frame:
    /// a stream can switch to 10-bit or HDR at a keyframe without changing size, which is the only
    /// event the older per-size cache above keyed on.
    nonisolated(unsafe) private var desiredOutputFormat: MTLPixelFormat = .bgra8Unorm
    nonisolated(unsafe) private var desiredTransfer = OPNVideoTransferFunction.sdr
    private var appliedTransfer = OPNVideoTransferFunction.sdr
    nonisolated(unsafe) private var framesReceived: UInt64 = 0
    private var framesDrawn: UInt64 = 0
    nonisolated(unsafe) private var presentationMode = OPNVideoPresentationMode.balanced
    /// `smooth` only: frames waiting for a refresh, oldest first. Capped at two so a stall cannot
    /// build a latency debt; anything older than the newest two is dropped like `balanced` does.
    nonisolated(unsafe) private var pendingFrames: [(frame: RTCVideoFrame, serial: UInt64, receivedAt: CFTimeInterval)] = []
    /// When the newest frame reached `renderFrame`, for the presented-time measurement.
    nonisolated(unsafe) private var latestFrameReceivedAt: CFTimeInterval = 0
    /// Presented-time accounting, filled from the drawable's presented handler on a Metal thread.
    nonisolated(unsafe) private var presentLock = os_unfair_lock_s()
    nonisolated(unsafe) private var presentLatencyTotalMs = 0.0
    nonisolated(unsafe) private var presentLatencyMaxMs = 0.0
    nonisolated(unsafe) private var presentCount = 0
    nonisolated(unsafe) private var lastPresentedAt: CFTimeInterval = 0
    nonisolated(unsafe) private var lastPresentInterval = -1.0
    nonisolated(unsafe) private var presentJitterTotalMs = 0.0
    nonisolated(unsafe) private var presentJitterCount = 0
    /// `lowestLatency` only: `draw()` is driven from the decode thread; two completions must not
    /// enter the render pass together.
    nonisolated(unsafe) private var manualDrawLock = os_unfair_lock_s()
    /// The same MTKView, reachable from the decode thread for the manual `draw()` call. MTKView
    /// already invokes `draw(in:)` off the main thread from its own display link, so the render
    /// path is written for that; this only changes who kicks it.
    nonisolated(unsafe) private let metalViewForManualDraw: MTKView
    /// A one-shot request to write the next drawn frame — the drawable itself, after our render
    /// pass — as a JPEG. Set on the main actor, consumed on the render thread under `frameLock`.
    nonisolated(unsafe) private var pendingRenderSnapshotURL: URL?
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
            metalViewForManualDraw.draw()
            os_unfair_lock_unlock(&manualDrawLock)
        }
    }

    /// Asks for the next drawn frame to be written to `url` as a JPEG: what the viewer sees, fill,
    /// scaling and all, as opposed to the decoded frame the NVST sink can hand out. The layer is
    /// switched off `framebufferOnly` so the drawable can be read back; that costs a little
    /// bandwidth, so it is only done once a snapshot has been asked for.
    func requestRenderSnapshot(to url: URL) {
        metalView.framebufferOnly = false
        os_unfair_lock_lock(&frameLock)
        pendingRenderSnapshotURL = url
        os_unfair_lock_unlock(&frameLock)
    }

    /// On the render thread, after a render path has committed its commands: copies the drawable
    /// out on the same queue (so the copy runs after the render) and writes it once complete.
    /// The libwebrtc renderers use their own queue, so a capture taken on that path may read a
    /// frame that is still being drawn; the custom paths are exact.
    private func captureDrawableIfRequested() {
        os_unfair_lock_lock(&frameLock)
        let url = pendingRenderSnapshotURL
        pendingRenderSnapshotURL = nil
        os_unfair_lock_unlock(&frameLock)
        guard let url else { return }
        guard let drawable = metalView.currentDrawable, let commandQueue, let device = metalView.device else {
            OpenNOWLog.warning(.stream, "Render snapshot: no drawable")
            return
        }
        let source = drawable.texture
        guard !source.isFramebufferOnly else {
            // The drawable in flight was vended before `framebufferOnly` flipped; the next one works.
            os_unfair_lock_lock(&frameLock)
            pendingRenderSnapshotURL = url
            os_unfair_lock_unlock(&frameLock)
            return
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: source.pixelFormat, width: source.width, height: source.height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        guard let staging = device.makeTexture(descriptor: descriptor),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            OpenNOWLog.warning(.stream, "Render snapshot: could not create the copy")
            return
        }
        blit.copy(from: source, to: staging)
        blit.endEncoding()
        let formatName = Self.outputFormatName(source.pixelFormat)
        commandBuffer.addCompletedHandler { _ in
            guard let image = CIImage(mtlTexture: staging, options: [.colorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any]) else {
                OpenNOWLog.warning(.stream, "Render snapshot: Core Image cannot read a \(formatName) drawable")
                return
            }
            // Metal's origin is top-left, Core Image's bottom-left.
            let oriented = image.oriented(.downMirrored)
            let context = CIContext(options: [.cacheIntermediates: false])
            guard let data = context.jpegRepresentation(of: oriented, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:]) else {
                OpenNOWLog.warning(.stream, "Render snapshot: JPEG encode failed")
                return
            }
            do {
                try data.write(to: url, options: .atomic)
                OpenNOWLog.info(.stream, "Render snapshot \(source.width)x\(source.height) \(formatName) -> \(url.path)")
            } catch {
                OpenNOWLog.warning(.stream, "Render snapshot: write failed \(error.localizedDescription)")
            }
        }
        commandBuffer.commit()
    }

    /// Switches how frames meet the display. Main actor: it reconfigures the layer and the
    /// display link.
    func setPresentationMode(_ mode: OPNVideoPresentationMode) {
        os_unfair_lock_lock(&frameLock)
        let previous = presentationMode
        presentationMode = mode
        pendingFrames.removeAll()
        os_unfair_lock_unlock(&frameLock)
        guard previous != mode else { return }
        let metalLayer = metalView.layer as? CAMetalLayer
        switch mode {
        case .lowestLatency:
            // Our own draw() calls replace the display link; presenting no longer waits for vsync.
            metalView.isPaused = true
            metalView.enableSetNeedsDisplay = false
            metalLayer?.displaySyncEnabled = false
        case .balanced, .smooth:
            metalLayer?.displaySyncEnabled = true
            metalView.enableSetNeedsDisplay = false
            metalView.isPaused = false
        }
        resetDrawCadence()
        OpenNOWLog.info(.stream, "Video presentation mode \(previous.label) -> \(mode.label)")
    }

    /// The frame this refresh should draw, or nil when there is nothing new. `smooth` hands out
    /// its queue oldest first; the other modes hand out the newest frame once.
    private func nextFrameToDraw() -> (frame: RTCVideoFrame, serial: UInt64, sourceSize: CGSize, tenBit: Bool, output: (MTLPixelFormat, OPNVideoTransferFunction), receivedAt: CFTimeInterval)? {
        os_unfair_lock_lock(&frameLock)
        defer { os_unfair_lock_unlock(&frameLock) }
        let output = (desiredOutputFormat, desiredTransfer)
        if presentationMode == .smooth {
            guard !pendingFrames.isEmpty else { return nil }
            let next = pendingFrames.removeFirst()
            return (next.frame, next.serial, sourceFrameSize, cachedIsTenBitBiPlanar, output, next.receivedAt)
        }
        guard let frame = videoFrame, frameSerial > 0, frameSerial != lastDrawnFrameSerial else { return nil }
        return (frame, frameSerial, sourceFrameSize, cachedIsTenBitBiPlanar, output, latestFrameReceivedAt)
    }

    /// Hooks the drawable every render path is about to present (MTKView hands the same one to
    /// whoever asks during this draw) so its presented time can be measured against when the frame
    /// reached the renderer. That difference is the latency a viewer can feel from this side of the
    /// wire; its interval jitter is what reads as judder.
    private func attachPresentedHandler(receivedAt: CFTimeInterval) {
        guard receivedAt > 0, let drawable = metalView.currentDrawable else { return }
        drawable.addPresentedHandler { [weak self] presented in
            guard let self else { return }
            let presentedAt = presented.presentedTime
            guard presentedAt > 0 else { return }
            let latencyMs = max(0, (presentedAt - receivedAt) * 1000)
            os_unfair_lock_lock(&self.presentLock)
            self.presentLatencyTotalMs += latencyMs
            self.presentLatencyMaxMs = max(self.presentLatencyMaxMs, latencyMs)
            self.presentCount += 1
            if self.lastPresentedAt > 0 {
                let interval = (presentedAt - self.lastPresentedAt) * 1000
                if self.lastPresentInterval >= 0 {
                    self.presentJitterTotalMs += abs(interval - self.lastPresentInterval)
                    self.presentJitterCount += 1
                }
                self.lastPresentInterval = interval
            }
            self.lastPresentedAt = presentedAt
            os_unfair_lock_unlock(&self.presentLock)
        }
    }

    /// Drains the presented-time window into the diagnostics snapshot.
    private func takePresentDiagnostics() -> (latency: Double, maximum: Double, jitter: Double) {
        os_unfair_lock_lock(&presentLock)
        defer {
            presentLatencyTotalMs = 0
            presentLatencyMaxMs = 0
            presentCount = 0
            presentJitterTotalMs = 0
            presentJitterCount = 0
            os_unfair_lock_unlock(&presentLock)
        }
        let latency = presentCount > 0 ? presentLatencyTotalMs / Double(presentCount) : -1
        let maximum = presentCount > 0 ? presentLatencyMaxMs : -1
        let jitter = presentJitterCount > 0 ? presentJitterTotalMs / Double(presentJitterCount) : -1
        return (latency, maximum, jitter)
    }

    /// The drawable a decoded surface deserves. 8-bit video keeps the 8-bit drawable it always
    /// had. A 10-bit surface gets a 10-bit drawable, so the extra two bits survive to the display
    /// instead of being quantised away at present — the whole point of decoding to P010. An HDR
    /// surface (PQ or HLG tagged) gets a half-float drawable with extended dynamic range on, so
    /// the compositor tone-maps it for the panel.
    nonisolated private static func desiredOutput(for pixelBuffer: CVPixelBuffer) -> (MTLPixelFormat, OPNVideoTransferFunction) {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let tenBit = OPNVideoTextureSource.isTenBitBiPlanarFormat(format)
        let transfer = OPNVideoTransferFunction.from(pixelBuffer: pixelBuffer)
        if tenBit, transfer.isHDR { return (.rgba16Float, transfer) }
        return (tenBit ? .bgr10a2Unorm : .bgra8Unorm, .sdr)
    }

    /// Reconfigures the layer for a new output format. Returns true when it did, in which case the
    /// current draw is skipped: the drawable already vended for this pass has the old format, and
    /// the next display tick is a few milliseconds away.
    private func applyOutputFormatIfNeeded(_ format: MTLPixelFormat, transfer: OPNVideoTransferFunction) -> Bool {
        guard metalView.colorPixelFormat != format || appliedTransfer != transfer else { return false }
        let previous = metalView.colorPixelFormat
        metalView.colorPixelFormat = format
        appliedTransfer = transfer
        if let metalLayer = metalView.layer as? CAMetalLayer {
            switch transfer {
            case .pq:
                metalLayer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
                metalLayer.wantsExtendedDynamicRangeContent = true
                // Static HDR10 metadata for a stream that carries none of its own. GeForce NOW
                // asks the game for 1000-nit content (`desiredContentMaxLuminance` in the session
                // request), and 1.0 in a PQ-encoded signal is 10 000 nits by definition, which is
                // what the optical output scale describes for a PQ colour space.
                metalLayer.edrMetadata = CAEDRMetadata.hdr10(minLuminance: 0.0001, maxLuminance: 1000, opticalOutputScale: 10_000)
            case .hlg:
                metalLayer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)
                metalLayer.wantsExtendedDynamicRangeContent = true
                metalLayer.edrMetadata = CAEDRMetadata.hlg
            case .sdr:
                metalLayer.colorspace = nil
                metalLayer.wantsExtendedDynamicRangeContent = false
                metalLayer.edrMetadata = nil
            }
        }
        // libwebrtc's renderers compile their pipeline state against the view's format at attach
        // time, so a format change invalidates them; they rebuild lazily on the next 8-bit frame.
        rendererNV12 = nil
        rendererRGB = nil
        rendererI420 = nil
        OpenNOWLog.info(.stream, "Video output format \(Self.outputFormatName(previous)) -> \(Self.outputFormatName(format)) transfer=\(transfer) edr=\(transfer.isHDR)")
        return true
    }

    nonisolated static func outputFormatName(_ format: MTLPixelFormat) -> String {
        switch format {
        case .bgra8Unorm: "bgra8"
        case .bgr10a2Unorm: "bgr10a2"
        case .rgba16Float: "rgba16f"
        default: "mtl\(format.rawValue)"
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
    private func configuredEnhancementSettings(enhancement: VideoEnhancement,
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
private func normalizedEnhancementMode(_ mode: Int32) -> Int32 {
    switch mode {
    case 0: return 0
    case 2: return 2
    case 3: return 3
    case 4: return 4
    case 1: return 3
    default: return 0
    }
}

private struct VideoEnhancement {
    var mode: Int32
    var sharpness: Int32
    var denoise: Int32
    var targetHeight: Int32
    var pillarboxFillMode: Int32
    var pillarboxFillDim: Int32
    var pillarboxFillColor: Int32

    var fillMode: OPNPillarboxFillMode { OPNPillarboxFillMode.from(Int(pillarboxFillMode)) }
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
    var frameIntervalMs = -1.0
    var maxFrameIntervalMs = -1.0
    var outputFormat = ""
    var isHDR = false
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
extension OPNMetalVideoView {
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

    private func newRenderer(named className: String, fallback: inout String) -> OPNRTCMetalRenderer? {
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

    private func i420Renderer(fallback: inout String) -> OPNRTCMetalRenderer? {
        if rendererI420 == nil { rendererI420 = newRenderer(named: "RTCMTLI420Renderer", fallback: &fallback) }
        return rendererI420
    }

    private func emitDiagnosticsIfNeeded(_ diagnostics: RenderDiagnostics, force: Bool) {
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

    private func localVideoEnhancementOverride() -> (Int32, Int32, Int32, Int32, Int32, Int32, Int32)? {
        os_unfair_lock_lock(&enhancementOverrideLock)
        defer { os_unfair_lock_unlock(&enhancementOverrideLock) }
        return enhancementOverride
    }

    private func localVideoEnhancement() -> VideoEnhancement {
        let values = localVideoEnhancementOverride() ?? owner?.localVideoEnhancement() ?? (0, 0, 0, 2160, 0, 55, 0)
        return VideoEnhancement(mode: normalizedEnhancementMode(values.0), sharpness: values.1, denoise: values.2, targetHeight: values.3, pillarboxFillMode: values.4, pillarboxFillDim: values.5, pillarboxFillColor: values.6)
    }

    private func setCustomDrawableRenderingEnabled(_ enabled: Bool) {
        guard customDrawableRenderingEnabled != enabled else { return }
        customDrawableRenderingEnabled = enabled
        metalView.framebufferOnly = !enabled
    }

    private func recordDrawCadence() {
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

    private func populateDrawCadenceDiagnostics(_ diagnostics: inout RenderDiagnostics) {
        guard drawIntervalCount > 0 else { return }
        diagnostics.frameIntervalMs = drawIntervalTotalMs / Double(drawIntervalCount)
        diagnostics.maxFrameIntervalMs = drawIntervalMaxMs
        drawIntervalTotalMs = 0
        drawIntervalMaxMs = 0
        drawIntervalCount = 0
    }

    private func resetDrawCadence() {
        lastDrawCadenceTime = 0
        drawIntervalTotalMs = 0
        drawIntervalMaxMs = 0
        drawIntervalCount = 0
    }
}
