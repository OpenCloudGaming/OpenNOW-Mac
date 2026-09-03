//
//  WebRTCStreamRecordingFixtures.swift
//  OpenNOWTests
//
//  Synthetic frames, audio and finished recordings for the recording tests. Split out of
//  WebRTCStreamRecordingTests.swift: they are setup, not assertions, and inside the suite they
//  pushed it past the type-size budget.
//

import AVFoundation
import CoreVideo
import Foundation
@testable import OpenNOW

actor StreamRecordingStatusRecorder {
    private(set) var values: [WebRTCStreamRecordingStatus] = []

    func append(_ status: WebRTCStreamRecordingStatus) {
        values.append(status)
    }

    func terminalStatus() -> WebRTCStreamRecordingStatus? {
        values.first { $0.isTerminal }
    }
}

enum RecordingTestFixtures {
    static func makeSineSamples(frameCount: Int, frameIndex: Int) -> [Float] {
        var samples = [Float]()
        samples.reserveCapacity(frameCount * 2)
        for frame in 0..<frameCount {
            let phase = Float(frameIndex * frameCount + frame) * 0.01
            let value = sin(phase) * 0.25
            samples.append(value)
            samples.append(value)
        }
        return samples
    }

    static func makeNV12Frame(width: Int, height: Int, frameIndex: Int) -> CVPixelBuffer? {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attributes as CFDictionary, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let luma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let chroma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return nil }
        let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let chromaRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let lumaPixels = luma.assumingMemoryBound(to: UInt8.self)
        let chromaPixels = chroma.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                lumaPixels[y * lumaRow + x] = UInt8((x + y + frameIndex * 13) % 256)
            }
        }
        for y in 0..<(height / 2) {
            for x in 0..<(width / 2) {
                chromaPixels[y * chromaRow + x * 2] = UInt8((x + frameIndex * 7) % 256)
                chromaPixels[y * chromaRow + x * 2 + 1] = UInt8((y + frameIndex * 5) % 256)
            }
        }
        return pixelBuffer
    }

    static func makeBGRAFrame(width: Int, height: Int, frameIndex: Int) -> CVPixelBuffer? {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pixels = baseAddress.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                pixels[offset] = UInt8((x + frameIndex * 11) % 256)
                pixels[offset + 1] = UInt8((y + frameIndex * 17) % 256)
                pixels[offset + 2] = UInt8((x + y + frameIndex * 23) % 256)
                pixels[offset + 3] = 255
            }
        }
        return pixelBuffer
    }

    static func makeRecording(title: String, width: Int, height: Int, frames: Int) async throws -> WebRTCStreamRecording {
        let recorder = WebRTCStreamRecorder()
        let statuses = StreamRecordingStatusRecorder()
        recorder.onStatusChanged = { status in
            Task { await statuses.append(status) }
        }
        recorder.start(configuration: WebRTCStreamRecordingConfiguration(
            title: title,
            applicationID: "100",
            width: width,
            height: height,
            fps: 30,
            videoBitrateMbps: 1,
            audioBitrateKbps: 128,
            enhancedVideoEnabled: true
        ))

        // Feed frames until the writer accepts one; on loaded CI runners the asset
        // writer input reports not-ready during spin-up and a fixed burst would all
        // be dropped, tripping the first-frame timeout despite frames flowing.
        var frameIndex = 0
        var sawRecording = false
        var framesAfterStart = 0
        let feedDeadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < feedDeadline {
            if await statuses.terminalStatus() != nil { break }
            if let pixelBuffer = makeBGRAFrame(width: width, height: height, frameIndex: frameIndex) {
                recorder.appendEnhancedPixelBuffer(pixelBuffer)
                frameIndex += 1
                if sawRecording { framesAfterStart += 1 }
            } else {
                throw WebRTCStreamRecordingTestError.unableToCreatePixelBuffer
            }
            if !sawRecording {
                sawRecording = await statuses.values.contains { status in
                    if case .recording = status { return true }
                    return false
                }
            }
            if sawRecording && framesAfterStart >= frames { break }
            try await Task.sleep(for: .milliseconds(34))
        }
        recorder.stop()
        var terminalStatus: WebRTCStreamRecordingStatus?
        for _ in 0..<60 {
            terminalStatus = await statuses.terminalStatus()
            if terminalStatus != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard case .finished(let recording) = terminalStatus else { throw WebRTCStreamRecordingTestError.recordingFailed(String(describing: terminalStatus)) }
        return recording
    }
}

enum WebRTCStreamRecordingTestError: LocalizedError {
    case unableToCreatePixelBuffer
    case recordingFailed(String)

    var errorDescription: String? {
        switch self {
        case .unableToCreatePixelBuffer:
            return "Unable to create test pixel buffer."
        case .recordingFailed(let status):
            return "Recording failed with status \(status)."
        }
    }
}
