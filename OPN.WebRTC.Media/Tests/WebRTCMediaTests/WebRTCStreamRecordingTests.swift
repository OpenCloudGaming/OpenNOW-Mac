import CoreVideo
import Foundation
import Testing
@testable import WebRTCMedia

private actor StreamRecordingStatusRecorder {
    private(set) var values: [WebRTCStreamRecordingStatus] = []

    func append(_ status: WebRTCStreamRecordingStatus) {
        values.append(status)
    }

    func terminalStatus() -> WebRTCStreamRecordingStatus? {
        values.first { $0.isTerminal }
    }
}

@Suite("WebRTCStreamRecording")
struct WebRTCStreamRecordingTests {
    @Test("recording writes a video file from pixel buffers")
    func recordingWritesVideoFileFromPixelBuffers() async throws {
        let recorder = WebRTCStreamRecorder(firstFrameTimeout: .seconds(1))
        let statuses = StreamRecordingStatusRecorder()
        recorder.onStatusChanged = { status in
            Task { await statuses.append(status) }
        }

        recorder.start(configuration: WebRTCStreamRecordingConfiguration(
            title: "Live Writer Regression",
            applicationID: "100",
            width: 64,
            height: 64,
            fps: 30,
            videoBitrateMbps: 1,
            audioBitrateKbps: 128,
            enhancedVideoEnabled: true
        ))

        for frameIndex in 0..<8 {
            guard let pixelBuffer = Self.makeBGRAFrame(width: 64, height: 64, frameIndex: frameIndex) else {
                Issue.record("Unable to create test pixel buffer")
                return
            }
            recorder.appendEnhancedPixelBuffer(pixelBuffer)
            try await Task.sleep(for: .milliseconds(34))
        }
        recorder.stop()

        var terminalStatus: WebRTCStreamRecordingStatus?
        for _ in 0..<40 {
            terminalStatus = await statuses.terminalStatus()
            if terminalStatus != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        guard case .finished(let recording) = terminalStatus else {
            Issue.record("Expected successful recording, got \(String(describing: terminalStatus))")
            return
        }
        defer { try? WebRTCStreamRecordingLibrary.delete(recording) }

        let fileAttributes = try FileManager.default.attributesOfItem(atPath: recording.videoURL.path)
        let fileSize = (fileAttributes[.size] as? NSNumber)?.int64Value ?? 0
        #expect(FileManager.default.fileExists(atPath: recording.videoURL.path))
        #expect(FileManager.default.fileExists(atPath: recording.metadataURL.path))
        #expect(fileSize > 0)
        #expect(recording.fileSizeBytes == fileSize)
        #expect(recording.durationSeconds > 0)
        #expect(recording.width == 64)
        #expect(recording.height == 64)
    }

    @Test("recording fails automatically when the first video frame never arrives")
    func recordingFailsAutomaticallyWhenFirstVideoFrameNeverArrives() async throws {
        let recorder = WebRTCStreamRecorder(firstFrameTimeout: .milliseconds(50))
        let statuses = StreamRecordingStatusRecorder()
        recorder.onStatusChanged = { status in
            Task { await statuses.append(status) }
        }

        recorder.start(configuration: WebRTCStreamRecordingConfiguration(
            title: "Timeout Regression",
            applicationID: "100",
            width: 1280,
            height: 720,
            fps: 60,
            videoBitrateMbps: 8,
            audioBitrateKbps: 128,
            enhancedVideoEnabled: false
        ))

        var terminalStatus: WebRTCStreamRecordingStatus?
        for _ in 0..<20 {
            terminalStatus = await statuses.terminalStatus()
            if terminalStatus != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }

        #expect(terminalStatus == .failed("Recording could not capture video frames."))
    }

    private static func makeBGRAFrame(width: Int, height: Int, frameIndex: Int) -> CVPixelBuffer? {
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
}
