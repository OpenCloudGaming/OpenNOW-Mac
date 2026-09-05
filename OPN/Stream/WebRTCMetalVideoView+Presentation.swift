//  Presentation and output-format half of `OPNMetalVideoView`: how decoded frames meet the display
//  (pacing modes, 10-bit and EDR drawables), the presented-time measurement, and the snapshot paths
//  the autopilot uses to look at the picture.
//

import AppKit
import CoreImage
import CoreVideo
import Foundation
import Metal
import MetalKit
import QuartzCore
import WebRTC

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

extension OPNMetalVideoView {

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
    func captureDrawableIfRequested() {
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
        // Read on the completion thread only, after the GPU has written it.
        nonisolated(unsafe) let stagingTexture = staging
        let width = source.width
        let height = source.height
        commandBuffer.addCompletedHandler { _ in
            guard let image = CIImage(mtlTexture: stagingTexture, options: [.colorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any]) else {
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
                OpenNOWLog.info(.stream, "Render snapshot \(width)x\(height) \(formatName) -> \(url.path)")
            } catch {
                OpenNOWLog.warning(.stream, "Render snapshot: write failed \(error.localizedDescription)")
            }
        }
        commandBuffer.commit()
    }

    /// Renders the latest frame offscreen through the fill/spatial pass — what the viewer would
    /// see at the current settings — and writes it as a JPEG. Needs no window: the autopilot's way
    /// to look at the picture when the app is not frontmost. Returns the rendered size.
    func writeOffscreenRenderSnapshot(to url: URL) -> CGSize? {
        os_unfair_lock_lock(&frameLock)
        let frame = videoFrame
        let sourceSize = sourceFrameSize
        os_unfair_lock_unlock(&frameLock)
        guard let frame, let enhancementRenderer else { return nil }
        let size = metalView.drawableSize.width >= 1 && metalView.drawableSize.height >= 1
            ? metalView.drawableSize
            : CGSize(width: Int(frame.width), height: Int(frame.height))
        let resolvedSource = sourceSize.width > 0 && sourceSize.height > 0 ? sourceSize : CGSize(width: Int(frame.width), height: Int(frame.height))
        let settings = configuredEnhancementSettings(enhancement: localVideoEnhancement(), sourceSize: resolvedSource, renderer: enhancementRenderer)
        settings.drawableSize = size
        settings.captureEnhancedPixelBuffer = false
        if settings.configuredTier == .off || settings.configuredTier == .metalFX || settings.configuredTier == .temporal {
            settings.configuredTier = .spatial
        }
        guard let texture = enhancementRenderer.renderOffscreenSnapshot(frame, settings: settings, size: size),
              let image = CIImage(mtlTexture: texture, options: [.colorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any]) else { return nil }
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let data = context.jpegRepresentation(of: image.oriented(.downMirrored), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:]) else { return nil }
        do { try data.write(to: url, options: .atomic) } catch { return nil }
        return size
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
    func nextFrameToDraw() -> (frame: RTCVideoFrame, serial: UInt64, sourceSize: CGSize, tenBit: Bool, output: (MTLPixelFormat, OPNVideoTransferFunction), receivedAt: CFTimeInterval)? {
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
    func attachPresentedHandler(receivedAt: CFTimeInterval) {
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
    func takePresentDiagnostics() -> (latency: Double, maximum: Double, jitter: Double) {
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
    nonisolated static func desiredOutput(for pixelBuffer: CVPixelBuffer) -> (MTLPixelFormat, OPNVideoTransferFunction) {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let tenBit = OPNVideoTextureSource.isTenBitBiPlanarFormat(format)
        let transfer = OPNVideoTransferFunction.from(pixelBuffer: pixelBuffer)
        if tenBit, transfer.isHDR { return (.rgba16Float, transfer) }
        return (tenBit ? .bgr10a2Unorm : .bgra8Unorm, .sdr)
    }

    /// Reconfigures the layer for a new output format. Returns true when it did, in which case the
    /// current draw is skipped: the drawable already vended for this pass has the old format, and
    /// the next display tick is a few milliseconds away.
    func applyOutputFormatIfNeeded(_ format: MTLPixelFormat, transfer: OPNVideoTransferFunction) -> Bool {
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
}
