//  Measures what a guest costs the host per frame.
//
//  The relay hands the same `RTCVideoFrame` to every guest's peer, and each peer independently
//  converts it with `newI420()`. Same input, same output, once per guest. Whether that is worth
//  sharing is a number, not an opinion, so it is measured here at the sizes a real session uses:
//  an NVST 5K decode scaled down to the relay's ceiling.
//
//  The last two measurements carry regression thresholds — the whole point of the relay's shared
//  conversion is that adding guests must not multiply the work. A breach prints a FAIL verdict and
//  the runner exits nonzero, so the gate survives without timed asserts living in the test suite.

import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import WebRTC
@testable import OpenNOW

struct RemoteCoOpVideoRelayConversionBenchmark {
    /// An NV12 buffer, which is what VideoToolbox hands back from the NVST decoder.
    static func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw BenchmarkError.pixelBufferCreationFailed(status: status)
        }
        // Written rather than left zeroed: an untouched allocation can be lazily backed, which would
        // measure the page faults of the first pass instead of the conversion.
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
            let bytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane)
            memset(base, 0x40 + Int32(plane), bytes)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    static func relayFrame(from pixelBuffer: CVPixelBuffer, targetWidth: Int, targetHeight: Int) -> RTCVideoFrame {
        let buffer = RTCCVPixelBuffer(
            pixelBuffer: pixelBuffer,
            adaptedWidth: Int32(targetWidth),
            adaptedHeight: Int32(targetHeight),
            cropWidth: Int32(CVPixelBufferGetWidth(pixelBuffer)),
            cropHeight: Int32(CVPixelBufferGetHeight(pixelBuffer)),
            cropX: 0,
            cropY: 0
        )
        return RTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: 1)
    }

    static func medianMilliseconds(_ iterations: Int, _ body: () -> Void) -> Double {
        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        return samples.sorted()[samples.count / 2]
    }

    static func run() throws -> Bool {
        var verdicts: [String] = []
        print("one I420 conversion, at the sizes the relay actually emits")
        try conversionCostBySize()

        print("per-guest conversion multiplies, shared conversion does not")
        try conversionCostByGuestCount()

        verdicts.append(try relayCostIsFlatAcrossGuests().verdict)
        verdicts.append(try droppedFramesCostNothing().verdict)
        for verdict in verdicts where verdict.hasPrefix("FAIL") {
            print(verdict)
        }
        return !verdicts.contains { $0.hasPrefix("FAIL") }
    }

    /// One conversion, at the sizes the relay actually produces.
    ///
    /// The preset is a bounding box, not the output: `adaptedSize` preserves the source aspect ratio,
    /// so a 1440p preset on a 5120x2160 decode yields 2560x1080, not 2560x1440. That distinction is
    /// not cosmetic - it decides which libyuv path runs. An exact halving has a dedicated fast row
    /// scaler; 0.375 and 0.75 do not, and cost several times more. Measuring a size the relay never
    /// emits gives a number several times too high, which is what a first pass at this did.
    static func conversionCostBySize() throws {
        let pixelBuffer = try makePixelBuffer(width: 5120, height: 2160)
        for preset in OPNRemoteCoOpQualityPreset.allCases {
            let target = OPNRemoteCoOpHostVideoRelay.adaptedSize(sourceWidth: 5120, sourceHeight: 2160, maximumWidth: preset.width, maximumHeight: preset.height)
            let frame = relayFrame(from: pixelBuffer, targetWidth: target.width, targetHeight: target.height)
            _ = frame.newI420()
            let median = medianMilliseconds(30) { _ = frame.newI420() }
            let ratio = Double(target.width) / 5120
            print(String(format: "[relay conversion] %@ box -> %dx%d (x%.3f)  %.3f ms/frame  (%.1f%% of that preset's frame budget)",
                         preset.label, target.width, target.height, ratio, median, median / (1000.0 / Double(preset.fps)) * 100))
        }
    }

    /// The before and after, on a frame shaped exactly as the relay emits it.
    static func conversionCostByGuestCount() throws {
        let pixelBuffer = try makePixelBuffer(width: 5120, height: 2160)
        // The 4K preset: the worst real case, because 0.75 misses libyuv's halving fast path.
        let target = OPNRemoteCoOpHostVideoRelay.adaptedSize(sourceWidth: 5120, sourceHeight: 2160, maximumWidth: 3840, maximumHeight: 2160)
        let frame = relayFrame(from: pixelBuffer, targetWidth: target.width, targetHeight: target.height)
        _ = frame.newI420()
        for guests in 1...3 {
            let perPeer = medianMilliseconds(20) {
                for _ in 0..<guests { _ = frame.newI420() }
            }
            let shared = medianMilliseconds(20) {
                let converted = frame.newI420()
                for _ in 0..<guests { _ = converted }
            }
            print(String(format: "[relay conversion] %dx%d, %d guest(s): per-peer %.3f ms  shared %.3f ms  saved %.3f ms/frame",
                         target.width, target.height, guests, perPeer, shared, perPeer - shared))
        }
    }

    /// A sink that does what a real peer does with the frame it is handed, minus libwebrtc.
    private final class ConvertingSink: OPNRemoteCoOpHostVideoSink, @unchecked Sendable {
        let participantID = UUID()
        /// Set to mimic a guest whose rate limiter drops this frame, which must then cost it nothing.
        var forwards = true
        private(set) var converted = 0

        func renderVideoFrame(_ frame: RTCVideoFrame) {
            guard forwards else { return }
            _ = frame.buffer is RTCI420Buffer ? frame.buffer : frame.newI420().buffer
            converted += 1
        }

        func renderSharedVideoFrame(_ frame: OPNRemoteCoOpSharedVideoFrame) {
            guard forwards else { return }
            _ = frame.i420Buffer()
            converted += 1
        }
    }

    /// The measurement that decided this: cost through the real relay as guests are added.
    static func relayCostIsFlatAcrossGuests() throws -> (verdict: String, message: String) {
        let pixelBuffer = try makePixelBuffer(width: 5120, height: 2160)
        var costs: [Double] = []
        for guests in 1...3 {
            let relay = OPNRemoteCoOpHostVideoRelay()
            relay.setPreferredOutputSize(width: 2560, height: 1440)
            let sinks = (0..<guests).map { _ in ConvertingSink() }
            for sink in sinks { relay.upsert(sink) }
            // Warm: the first frame pays for allocations this is not trying to measure.
            relay.renderPixelBuffer(pixelBuffer, presentationTime: CMTime(value: 1, timescale: 90_000))
            var timestamp: Int64 = 2
            let median = medianMilliseconds(20) {
                relay.renderPixelBuffer(pixelBuffer, presentationTime: CMTime(value: timestamp, timescale: 90_000))
                timestamp += 1
            }
            costs.append(median)
            print(String(format: "[relay conversion] %d guest(s) through the relay: %.3f ms/frame", guests, median))
            if sinks.allSatisfy({ $0.converted > 0 }) == false {
                return (verdict: "FAIL: a sink received no frames through the relay", message: "")
            }
        }
        // Three guests must not cost meaningfully more than one. Before sharing this was 3.0 -> 9.1 ms,
        // which is past the 8.3 ms a 120 fps frame gets; the tolerance is loose enough for a loaded
        // machine but nowhere near loose enough to let per-guest conversion back in.
        if costs[2] < costs[0] * 1.8 {
            return (verdict: "PASS", message: "3 guests cost \(costs[2]) ms vs 1 guest \(costs[0]) ms")
        }
        return (verdict: "FAIL: 3 guests cost \(costs[2]) ms vs 1 guest \(costs[0]) ms", message: "")
    }

    /// A frame every guest drops converts nothing.
    static func droppedFramesCostNothing() throws -> (verdict: String, message: String) {
        let pixelBuffer = try makePixelBuffer(width: 5120, height: 2160)
        let relay = OPNRemoteCoOpHostVideoRelay()
        relay.setPreferredOutputSize(width: 2560, height: 1440)
        let sinks = (0..<3).map { _ in ConvertingSink() }
        for sink in sinks {
            sink.forwards = false
            relay.upsert(sink)
        }
        // Laziness is the reason the conversion is not simply done once up front in the relay: guests
        // have their own frame rates, and a 60 fps guest on a 120 fps source drops half the frames.
        let median = medianMilliseconds(20) {
            relay.renderPixelBuffer(pixelBuffer, presentationTime: CMTime(value: 1, timescale: 90_000))
        }
        print(String(format: "[relay conversion] 3 guests all dropping: %.3f ms/frame", median))
        if median < 0.5, sinks.allSatisfy({ $0.converted == 0 }) {
            return (verdict: "PASS", message: "a frame nobody forwards was not converted")
        }
        return (verdict: "FAIL: a frame nobody forwards was converted, took \(median) ms", message: "")
    }
}

enum BenchmarkError: Error {
    case pixelBufferCreationFailed(status: CVReturn)
}

func runRemoteCoOpVideoRelayConversionBenchmark() throws -> Bool {
    try RemoteCoOpVideoRelayConversionBenchmark.run()
}
