import CoreImage
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import WebRTC

/// Presents the Bifrost-free NVST video path on the existing Metal surface.
///
/// Decoded `CVPixelBuffer`s are wrapped as `RTCVideoFrame`s and handed to `OPNMetalVideoView`,
/// which is the same renderer the WebRTC path uses — so HDR/10-bit handling, the video
/// enhancement pass, and the pillarbox fill all come along unchanged instead of being
/// reimplemented for this transport.
@MainActor
public final class NvstBifrostFreeVideoRenderer {
    private let videoView: OPNMetalVideoView
    private let sink: NvstBifrostFreeVideoSink

    /// Thread-safe entry point for the decode thread. `OPNMetalVideoView.renderFrame` and
    /// `setSize` are both nonisolated, so frames never have to hop to the main actor.
    public final class NvstBifrostFreeVideoSink: @unchecked Sendable {
        private weak var videoView: OPNMetalVideoView?
        /// The renderer that owns this sink, so a decoded-geometry change can be handed back to it
        /// on the main actor. Weak: the view owns the renderer, the renderer owns the sink.
        private weak var owner: NvstBifrostFreeVideoRenderer?
        let lock = NSLock()
        private var lastSize = CGSize.zero
        private var renderedFrames: UInt64 = 0
        private var latestRenderDiagnostics = OPNVideoRenderDiagnosticsSnapshot()
        /// Measures the baked pillarbox regardless of render path or fill mode, so a 16:9 title
        /// can be recognised even with the fill off and the plain
        /// 8-bit renderer drawing. Throttled inside: a 32-row scan a few times a second.
        private let contentDetector = OPNPillarboxDetector()
        /// The most recent decoded frame, kept so a diagnostic snapshot can be written on request
        /// without a screen-recording grant. One buffer retained; the pool has more.
        private var latestPixelBuffer: CVPixelBuffer?
        private let snapshotTransfer = OPNPixelBufferTransfer()

        init(videoView: OPNMetalVideoView) {
            self.videoView = videoView
        }

        func setOwner(_ owner: NvstBifrostFreeVideoRenderer?) {
            lock.lock()
            self.owner = owner
            lock.unlock()
        }

        public var renderedFrameCount: UInt64 { lock.lock(); defer { lock.unlock() }; return renderedFrames }

        /// The renderer's own account of the last second: decoded surface format, the drawable it
        /// presented into, whether EDR is on, and how many frames it drew versus received.
        var renderDiagnostics: OPNVideoRenderDiagnosticsSnapshot {
            lock.lock()
            defer { lock.unlock() }
            var snapshot = latestRenderDiagnostics
            snapshot.contentLeft = contentDetector.contentRect.left
            snapshot.contentRight = contentDetector.contentRect.right
            return snapshot
        }

        /// Writes the latest decoded frame as a JPEG. 10-bit and 4:4:4 surfaces go through an NV12
        /// transfer first, which is the layout Core Image reads reliably. Returns the frame size.
        func writeLatestFrameJPEG(to url: URL) -> CGSize? {
            lock.lock()
            let buffer = latestPixelBuffer
            lock.unlock()
            guard let buffer,
                  let nv12 = snapshotTransfer.convert(buffer, to: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) else { return nil }
            let image = CIImage(cvPixelBuffer: nv12)
            let context = CIContext(options: [.cacheIntermediates: false])
            guard let data = context.jpegRepresentation(of: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:]) else { return nil }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                return nil
            }
            return image.extent.size
        }

        func noteRenderDiagnostics(_ snapshot: OPNVideoRenderDiagnosticsSnapshot) {
            lock.lock()
            latestRenderDiagnostics = snapshot
            lock.unlock()
        }

        public func render(pixelBuffer: CVPixelBuffer, presentationTime: CMTime, isKeyframe: Bool) {
            lock.lock()
            _ = contentDetector.update(with: pixelBuffer)
            latestPixelBuffer = pixelBuffer
            lock.unlock()
            guard let videoView else { return }
            let size = Self.displaySize(of: pixelBuffer)
            lock.lock()
            let sizeChanged = size != lastSize
            if sizeChanged { lastSize = size }
            renderedFrames &+= 1
            lock.unlock()
            if sizeChanged {
                videoView.setSize(size)
                announceDecodedSize(size, buffer: pixelBuffer)
            }
            let buffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
            // The renderer only reads the timestamp for cadence diagnostics; nanoseconds keep it
            // monotonic across the 90 kHz RTP clock.
            let timestampNs = presentationTime.isValid ? Int64(CMTimeGetSeconds(presentationTime) * 1_000_000_000) : 0
            let frame = RTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: timestampNs)
            videoView.renderFrame(frame)
        }

        /// The frame's *display* geometry, which is what the surface is letterboxed to and what
        /// absolute pointer coordinates are measured against.
        ///
        /// VideoToolbox attaches a clean aperture when the coded frame is padded out to a
        /// macroblock multiple — a 1080p H.264 stream is coded 1920x1088 and displayed 1920x1080 —
        /// and returns the full buffer rect when there is nothing to trim. Row padding never
        /// reaches here at all: that lives in `bytesPerRow`, not in the width.
        static func displaySize(of pixelBuffer: CVPixelBuffer) -> CGSize {
            let clean = CVImageBufferGetCleanRect(pixelBuffer)
            guard clean.width >= 1, clean.height >= 1 else {
                return CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
            }
            return CGSize(width: clean.width.rounded(), height: clean.height.rounded())
        }

        /// Hands the new geometry to the main actor. Called off the lock and asynchronously: the
        /// handler ends in AppKit layout, which must never sit on the decode thread's critical path.
        private func announceDecodedSize(_ size: CGSize, buffer: CVPixelBuffer) {
            let coded = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
            OpenNOWLog.info(.stream, "NVST decoded size \(Int(size.width))x\(Int(size.height)) coded \(Int(coded.width))x\(Int(coded.height))")
            lock.lock()
            let owner = owner
            lock.unlock()
            guard let owner else { return }
            Task { @MainActor in
                owner.reportDecodedSize(width: Int(size.width), height: Int(size.height))
            }
        }
    }

    public init(parentView: NSView, targetFps: Int32) {
        let videoView = OPNMetalVideoView(frame: parentView.bounds, targetFps: targetFps, owner: nil)
        videoView.autoresizingMask = [.width, .height]
        videoView.wantsLayer = true
        videoView.layer?.backgroundColor = NSColor.black.cgColor
        parentView.addSubview(videoView, positioned: .below, relativeTo: nil)
        self.videoView = videoView
        let sink = NvstBifrostFreeVideoSink(videoView: videoView)
        self.sink = sink
        sink.setOwner(self)
        videoView.renderDiagnosticsHandler = { [weak sink] snapshot in sink?.noteRenderDiagnostics(snapshot) }
    }

    /// Set by ``detach()``. A decoded-size hop raised on the decode thread can still be waiting for
    /// the main actor when the session ends; without this the next session's view is handed the
    /// previous stream's geometry.
    private var isDetached = false

    var renderDiagnostics: OPNVideoRenderDiagnosticsSnapshot { sink.renderDiagnostics }

    /// The pillarbox fill the drawn frame actually went through, as the fill pass committed it —
    /// not the once-a-second diagnostics snapshot above, which carries a second detector's
    /// measurement and can be a second stale. Pointer mapping reads this.
    var committedPillarboxFill: OPNCommittedPillarboxFill { videoView.committedPillarboxFill }

    /// The decoded frame's own dimensions, reported when they first arrive and on every format
    /// change after that. The negotiated profile is a request; this is what the seat actually sent.
    public var onDecodedSizeChanged: (@MainActor (Int, Int) -> Void)?

    /// Hop target for the sink, which measures the geometry on the decode thread and so cannot
    /// reach a main-actor handler from there.
    fileprivate func reportDecodedSize(width: Int, height: Int) {
        guard !isDetached else { return }
        onDecodedSizeChanged?(width, height)
    }

    /// Saves the latest decoded frame as a JPEG; see `NvstBifrostFreeVideoSink.writeLatestFrameJPEG`.
    func writeLatestFrameJPEG(to url: URL) -> CGSize? { sink.writeLatestFrameJPEG(to: url) }

    public var frameSink: NvstBifrostFreeVideoSink { sink }

    /// The health monitor's readiness signal for this renderer. `nativeNVSTRendererSurfaceReady` is
    /// tied to the vendored NVST Metal view, which this path never attaches; this reports our own
    /// surface's state instead — a view still in a window that has actually drawn frames.
    public var isSurfaceReady: Bool {
        videoView.window != nil && sink.renderedFrameCount > 0
    }

    public var renderedFrameCount: UInt64 { sink.renderedFrameCount }

    /// Applies the enhancement and pillarbox-fill settings. There is no `OPNLibWebRTCStreamSession`
    /// on this transport — we own the decoder — so the view is told directly instead of pulling
    /// from an owner. Everything downstream is the WebRTC path's: the enhancement pass, the
    /// pillarbox detector that measures the baked bars from the luma plane, and the fill shader
    /// that paints/reprojects them. All fill modes (mirror, zoom, stretch, crop) work as a result.
    public func setVideoEnhancement(mode: Int,
                                    sharpness: Int,
                                    denoise: Int,
                                    targetHeight: Int,
                                    pillarboxFillMode: Int,
                                    pillarboxFillDim: Int,
                                    pillarboxFillColor: Int) {
        videoView.setLocalVideoEnhancementOverride(mode: Int32(mode),
                                                   sharpness: Int32(sharpness),
                                                   denoise: Int32(denoise),
                                                   targetHeight: Int32(targetHeight),
                                                   pillarboxFillMode: Int32(pillarboxFillMode),
                                                   pillarboxFillDim: Int32(pillarboxFillDim),
                                                   pillarboxFillColor: Int32(pillarboxFillColor))
    }

    /// Renders the latest frame offscreen at the current settings and writes it; needs no window.
    func writeOffscreenRenderSnapshot(to url: URL) -> CGSize? {
        videoView.writeOffscreenRenderSnapshot(to: url)
    }

    /// Writes the next drawn frame — the drawable, after our render pass — as a JPEG.
    func requestRenderSnapshot(to url: URL) {
        videoView.requestRenderSnapshot(to: url)
    }

    func setPresentationMode(_ mode: OPNVideoPresentationMode) {
        videoView.setPresentationMode(mode)
    }

    public func detach() {
        isDetached = true
        // Nothing further should reach the main actor from the decode thread either: the sink is
        // what raises those hops, and the view it feeds is about to leave the hierarchy.
        sink.setOwner(nil)
        videoView.renderFrame(nil)
        videoView.removeFromSuperview()
    }
}
