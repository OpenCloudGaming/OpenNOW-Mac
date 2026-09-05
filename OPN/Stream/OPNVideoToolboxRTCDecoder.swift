//  libwebrtc's own HEVC decoder hands out 8-bit NV12 whatever the bitstream carries, which
//  flattens a 10-bit or HDR stream before the renderer ever sees it. This decoder routes the same
//  Annex-B access units through the NVST path's VideoToolbox decoder, which follows the bitstream's
//  depth and keeps the colour tags the renderer's PQ/HLG drawable switch keys off.
//

import CoreMedia
import CoreVideo
import Foundation
import WebRTC

final class OPNVideoToolboxRTCDecoder: NSObject, RTCVideoDecoder, @unchecked Sendable {
    private static let codecOK = 0
    private static let codecError = -1
    private static let codecUninitialized = -7

    private let codec: NVSTVideoCodec
    private let lock = NSLock()
    private var decoder: NvstVideoToolboxDecoder?
    private var callback: RTCVideoDecoderCallback?
    private var frameIndex: UInt32 = 0
    private var loggedFailures = 0

    init(codec: NVSTVideoCodec) {
        self.codec = codec
        super.init()
    }

    func setCallback(_ callback: @escaping RTCVideoDecoderCallback) {
        lock.withLock { self.callback = callback }
    }

    func startDecode(withNumberOfCores numberOfCores: Int32) -> Int {
        let created: NvstVideoToolboxDecoder
        do {
            created = try NvstVideoToolboxDecoder(codec: codec)
        } catch {
            OPNLogCapture.appendEvent("[LibWebRTC] VideoToolbox \(codec.rawValue) decoder unavailable: \(error.localizedDescription)")
            return Self.codecError
        }
        created.onPixelBuffer = { [weak self] pixelBuffer, presentationTime, _ in
            self?.deliver(pixelBuffer, presentationTime: presentationTime)
        }
        lock.withLock { decoder = created }
        OPNLogCapture.appendEvent("[LibWebRTC] VideoToolbox \(codec.rawValue) decoder active (bitstream-depth output)")
        return Self.codecOK
    }

    func release() -> Int {
        let expiring = lock.withLock { () -> NvstVideoToolboxDecoder? in
            defer { decoder = nil }
            return decoder
        }
        expiring?.invalidate()
        return Self.codecOK
    }

    func decode(_ encodedImage: RTCEncodedImage, missingFrames: Bool, codecSpecificInfo info: (any RTCCodecSpecificInfo)?, renderTimeMs: Int64) -> Int {
        guard let decoder = lock.withLock({ decoder }) else { return Self.codecUninitialized }
        let index = lock.withLock { () -> UInt32 in
            frameIndex &+= 1
            return frameIndex
        }
        let unit = NvstAccessUnit(
            frameIndex: index,
            firstStreamPacketIndex: 0,
            rtpTimestamp: encodedImage.timeStamp,
            isKeyframe: encodedImage.frameType == .videoFrameKey,
            bytes: encodedImage.buffer
        )
        do {
            try decoder.decode(unit)
            return Self.codecOK
        } catch {
            let shouldLog = lock.withLock { () -> Bool in
                guard loggedFailures < 8 else { return false }
                loggedFailures += 1
                return true
            }
            if shouldLog {
                OPNLogCapture.appendEvent("[LibWebRTC] VideoToolbox \(codec.rawValue) decode rejected frame \(index) keyframe=\(unit.isKeyframe) bytes=\(unit.bytes.count): \(error.localizedDescription)")
            }
            return Self.codecError
        }
    }

    func implementationName() -> String {
        "OpenNOW VideoToolbox \(codec.rawValue)"
    }

    /// Runs on VideoToolbox's decode thread, as libwebrtc's own H264 decoder does.
    private func deliver(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard let callback = lock.withLock({ callback }) else { return }
        let seconds = presentationTime.isNumeric ? presentationTime.seconds : 0
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer), rotation: ._0, timeStampNs: Int64(seconds * 1_000_000_000))
        frame.timeStamp = Int32(bitPattern: UInt32(truncatingIfNeeded: presentationTime.value))
        callback(frame)
    }
}
