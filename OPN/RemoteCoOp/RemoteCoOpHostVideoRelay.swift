import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import WebRTC

public protocol OPNRemoteCoOpHostVideoSink: AnyObject, Sendable {
    var participantID: UUID { get }
    func renderVideoFrame(_ frame: RTCVideoFrame)
}

public final class OPNRemoteCoOpHostVideoRelay: @unchecked Sendable {
    let lock = NSLock()
    private var sinks: [UUID: any OPNRemoteCoOpHostVideoSink] = [:]
    private var preferredOutputWidth = 0
    private var preferredOutputHeight = 0

    public init() {}

    /// The box guest frames should be scaled into before they are handed to libwebrtc.
    ///
    /// On the WebRTC transport the relay is fed `RTCVideoFrame`s that libwebrtc already owns, and
    /// the peer's `adaptOutputFormat` downscales them. The native NVST transport instead hands over
    /// the decoder's own `CVPixelBuffer` at full session resolution — up to 5120x2160 — and the
    /// conversion to I420 happens before any adaptation. Converting 5K and then throwing away 95%
    /// of it costs roughly 16 MB of copies per frame per guest; giving `RTCCVPixelBuffer` the
    /// target up front makes the scale part of the same pass.
    public func setPreferredOutputSize(width: Int, height: Int) {
        lock.withLock {
            preferredOutputWidth = max(0, width)
            preferredOutputHeight = max(0, height)
        }
    }

    public func upsert(_ sink: any OPNRemoteCoOpHostVideoSink) {
        lock.withLock { sinks[sink.participantID] = sink }
    }

    public func remove(participantID: UUID) {
        lock.withLock { sinks[participantID] = nil }
    }

    public func removeAll() {
        lock.withLock { sinks.removeAll() }
    }

    public func activeSinkCount() -> Int {
        lock.withLock { sinks.count }
    }

    public func renderVideoFrame(_ frame: RTCVideoFrame) {
        let currentSinks = lock.withLock { Array(sinks.values) }
        for sink in currentSinks { sink.renderVideoFrame(frame) }
    }

    /// Feeds a decoded pixel buffer straight from a native decoder.
    ///
    /// Called on the decode thread, so it returns immediately when no guest is connected — the
    /// wrap and the scale are only paid for once someone is actually watching. `RTCCVPixelBuffer`
    /// retains the buffer rather than copying it, and the pixel data is only read later on the
    /// peer's own video queue.
    public func renderPixelBuffer(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        let state = lock.withLock { (Array(sinks.values), preferredOutputWidth, preferredOutputHeight) }
        guard !state.0.isEmpty else { return }
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard sourceWidth > 0, sourceHeight > 0 else { return }
        let target = Self.adaptedSize(sourceWidth: sourceWidth, sourceHeight: sourceHeight, maximumWidth: state.1, maximumHeight: state.2)
        let buffer = RTCCVPixelBuffer(
            pixelBuffer: pixelBuffer,
            adaptedWidth: Int32(target.width),
            adaptedHeight: Int32(target.height),
            cropWidth: Int32(sourceWidth),
            cropHeight: Int32(sourceHeight),
            cropX: 0,
            cropY: 0
        )
        // The decoder's presentation time, not the wall clock.
        //
        // This is the seat's own RTP timestamp (`NvstVideoToolboxDecoder` builds it as
        // `CMTime(value: unit.rtpTimestamp, timescale: clockRate)`), so it describes when the frame
        // was captured rather than when it happened to reach this function. Stamping with
        // `DispatchTime.now()` here instead folded every hop between decode and relay - VideoToolbox
        // callback scheduling, actor hops, SRTP receive bursts, the seat's own network jitter - into
        // the capture clock. libwebrtc's receiver infers network jitter by comparing capture
        // timestamps against arrival times, so it read all of that as a jittery link and grew its
        // jitter buffer to absorb it: measured at 287 ms on a 4 ms LAN route.
        //
        // It also skewed the rate limiter, which compares consecutive timestamps against the guest
        // preset's frame interval. Jittery stamps put some frames under the threshold and dropped
        // them, so a 60 fps source arrived as an uneven ~40 fps.
        //
        // A zero or backwards value is not special-cased here: the limiter falls back to the arrival
        // clock when a timestamp fails to advance, which covers both the first frames of a session
        // and an RTP timestamp wrap.
        let nanoseconds = CMTimeConvertScale(presentationTime, timescale: 1_000_000_000, method: .default)
        let timeStampNs = nanoseconds.isValid ? nanoseconds.value : Int64(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds)
        let frame = RTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: timeStampNs)
        for sink in state.0 { sink.renderVideoFrame(frame) }
    }

    /// The largest box no bigger than the limit that keeps the source's aspect ratio, with even
    /// dimensions because I420 subsamples chroma by two. A zero limit means "do not scale".
    static func adaptedSize(sourceWidth: Int, sourceHeight: Int, maximumWidth: Int, maximumHeight: Int) -> (width: Int, height: Int) {
        guard maximumWidth > 0, maximumHeight > 0 else { return (even(sourceWidth), even(sourceHeight)) }
        let scale = min(Double(maximumWidth) / Double(sourceWidth), Double(maximumHeight) / Double(sourceHeight))
        guard scale < 1 else { return (even(sourceWidth), even(sourceHeight)) }
        return (even(Int((Double(sourceWidth) * scale).rounded())), even(Int((Double(sourceHeight) * scale).rounded())))
    }

    private static func even(_ value: Int) -> Int { max(2, value - (value % 2)) }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
