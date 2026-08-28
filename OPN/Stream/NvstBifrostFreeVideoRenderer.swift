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
        private let lock = NSLock()
        private var lastSize = CGSize.zero
        private var renderedFrames: UInt64 = 0

        init(videoView: OPNMetalVideoView) {
            self.videoView = videoView
        }

        public var renderedFrameCount: UInt64 { lock.lock(); defer { lock.unlock() }; return renderedFrames }

        public func render(pixelBuffer: CVPixelBuffer, presentationTime: CMTime, isKeyframe: Bool) {
            guard let videoView else { return }
            let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
            lock.lock()
            let sizeChanged = size != lastSize
            if sizeChanged { lastSize = size }
            renderedFrames &+= 1
            lock.unlock()
            if sizeChanged {
                videoView.setSize(size)
            }
            let buffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
            // The renderer only reads the timestamp for cadence diagnostics; nanoseconds keep it
            // monotonic across the 90 kHz RTP clock.
            let timestampNs = presentationTime.isValid ? Int64(CMTimeGetSeconds(presentationTime) * 1_000_000_000) : 0
            let frame = RTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: timestampNs)
            videoView.renderFrame(frame)
        }
    }

    public init(parentView: NSView, targetFps: Int32) {
        let videoView = OPNMetalVideoView(frame: parentView.bounds, targetFps: targetFps, owner: nil)
        videoView.autoresizingMask = [.width, .height]
        videoView.wantsLayer = true
        videoView.layer?.backgroundColor = NSColor.black.cgColor
        parentView.addSubview(videoView, positioned: .below, relativeTo: nil)
        self.videoView = videoView
        self.sink = NvstBifrostFreeVideoSink(videoView: videoView)
    }

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

    public func detach() {
        videoView.renderFrame(nil)
        videoView.removeFromSuperview()
    }
}
