import AVFoundation
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
        #expect(recording.videoURL.deletingLastPathComponent().path == WebRTCStreamRecordingLibrary.recordingsDirectory(forGameTitle: "Live Writer Regression").path)
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

    @Test("exports a trimmed recording as a new clip")
    func exportsTrimmedRecordingAsNewClip() async throws {
        let recording = try await Self.makeRecording(title: "Trim Source Regression", width: 96, height: 64, frames: 18)
        defer { try? WebRTCStreamRecordingLibrary.delete(recording) }
        let endSeconds = max(0.12, recording.durationSeconds * 0.55)
        let request = WebRTCStreamRecordingEditRequest(
            title: "Trimmed Export Regression",
            segments: [WebRTCStreamRecordingEditSegment(recording: recording, startSeconds: 0, endSeconds: endSeconds)],
            exportPreset: .balanced
        )

        let edited = try await WebRTCStreamRecordingLibrary.exportEditedRecording(request)
        defer { try? WebRTCStreamRecordingLibrary.delete(edited) }

        #expect(edited.id != recording.id)
        #expect(edited.title == "Trimmed Export Regression")
        #expect(FileManager.default.fileExists(atPath: edited.videoURL.path))
        #expect(FileManager.default.fileExists(atPath: edited.metadataURL.path))
        #expect(edited.durationSeconds > 0)
        #expect(edited.durationSeconds < recording.durationSeconds)
    }

    @Test("exports a recording with a middle cut removed")
    func exportsRecordingWithMiddleCutRemoved() async throws {
        let recording = try await Self.makeRecording(title: "Cut Source Regression", width: 96, height: 64, frames: 24)
        defer { try? WebRTCStreamRecordingLibrary.delete(recording) }
        let firstEnd = max(0.1, recording.durationSeconds * 0.28)
        let secondStart = min(recording.durationSeconds - 0.08, recording.durationSeconds * 0.62)
        let request = WebRTCStreamRecordingEditRequest(
            title: "Cut Export Regression",
            segments: [
                WebRTCStreamRecordingEditSegment(recording: recording, startSeconds: 0, endSeconds: firstEnd),
                WebRTCStreamRecordingEditSegment(recording: recording, startSeconds: secondStart, endSeconds: recording.durationSeconds),
            ],
            exportPreset: .balanced
        )

        let edited = try await WebRTCStreamRecordingLibrary.exportEditedRecording(request)
        defer { try? WebRTCStreamRecordingLibrary.delete(edited) }

        #expect(edited.durationSeconds > 0)
        #expect(edited.durationSeconds < recording.durationSeconds)
        #expect(edited.fileSizeBytes > 0)
    }

    @Test("exports joined recordings")
    func exportsJoinedRecordings() async throws {
        let first = try await Self.makeRecording(title: "Join Source A Regression", width: 80, height: 64, frames: 12)
        let second = try await Self.makeRecording(title: "Join Source B Regression", width: 80, height: 64, frames: 12)
        defer {
            try? WebRTCStreamRecordingLibrary.delete(first)
            try? WebRTCStreamRecordingLibrary.delete(second)
        }
        let request = WebRTCStreamRecordingEditRequest(
            title: "Joined Export Regression",
            segments: [
                WebRTCStreamRecordingEditSegment(recording: first, startSeconds: 0, endSeconds: first.durationSeconds),
                WebRTCStreamRecordingEditSegment(recording: second, startSeconds: 0, endSeconds: second.durationSeconds),
            ],
            exportPreset: .balanced
        )

        let edited = try await WebRTCStreamRecordingLibrary.exportEditedRecording(request)
        defer { try? WebRTCStreamRecordingLibrary.delete(edited) }

        #expect(edited.durationSeconds > first.durationSeconds)
        #expect(edited.durationSeconds > second.durationSeconds)
        #expect(edited.applicationID == first.applicationID)
    }

    @Test("builds an edited preview composition")
    func buildsEditedPreviewComposition() async throws {
        let recording = try await Self.makeRecording(title: "Preview Source Regression", width: 80, height: 64, frames: 18)
        defer { try? WebRTCStreamRecordingLibrary.delete(recording) }
        let split = max(0.08, recording.durationSeconds * 0.45)
        let request = WebRTCStreamRecordingEditRequest(
            title: "Preview Regression",
            segments: [
                WebRTCStreamRecordingEditSegment(recording: recording, startSeconds: split, endSeconds: recording.durationSeconds),
                WebRTCStreamRecordingEditSegment(recording: recording, startSeconds: 0, endSeconds: split),
            ],
            playbackRate: 2,
            exportPreset: .balanced
        )

        let preview = try await WebRTCStreamRecordingLibrary.previewEditedRecording(request)
        let assetDuration = try await preview.asset.load(.duration).seconds

        #expect(abs(preview.durationSeconds - recording.durationSeconds / 2) < 0.12)
        #expect(abs(assetDuration - preview.durationSeconds) < 0.05)
    }

    @Test("exports crop rotate flip speed and audio edits")
    func exportsTransformAndAudioEdits() async throws {
        let recording = try await Self.makeRecording(title: "Transform Source Regression", width: 128, height: 80, frames: 20)
        defer { try? WebRTCStreamRecordingLibrary.delete(recording) }
        let request = WebRTCStreamRecordingEditRequest(
            title: "Transform Export Regression",
            segments: [WebRTCStreamRecordingEditSegment(recording: recording, startSeconds: 0, endSeconds: recording.durationSeconds)],
            crop: WebRTCStreamRecordingCrop(x: 0.25, y: 0.20, width: 0.50, height: 0.60),
            rotation: .degrees90,
            isFlippedHorizontally: true,
            playbackRate: 1.5,
            audio: WebRTCStreamRecordingAudioEdit(volume: 0.65, isMuted: false, fadeInSeconds: 0.05, fadeOutSeconds: 0.05),
            exportPreset: .compact
        )

        let edited = try await WebRTCStreamRecordingLibrary.exportEditedRecording(request)
        defer { try? WebRTCStreamRecordingLibrary.delete(edited) }

        #expect(edited.width > 0)
        #expect(edited.height > 0)
        #expect(edited.durationSeconds > 0)
        #expect(edited.durationSeconds < recording.durationSeconds)
        #expect(edited.fileSizeBytes > 0)
    }

    @Test("failed exports clean partial files")
    func failedExportsCleanPartialFiles() async throws {
        let recording = try await Self.makeRecording(title: "Cleanup Source Regression", width: 64, height: 64, frames: 10)
        defer { try? WebRTCStreamRecordingLibrary.delete(recording) }
        let title = "Cleanup Export Regression"
        let directory = WebRTCStreamRecordingLibrary.recordingsDirectory(forGameTitle: title)
        try? FileManager.default.removeItem(at: directory)
        let request = WebRTCStreamRecordingEditRequest(
            title: title,
            segments: [WebRTCStreamRecordingEditSegment(recording: recording, startSeconds: 0, endSeconds: recording.durationSeconds + 10)]
        )

        do {
            _ = try await WebRTCStreamRecordingLibrary.exportEditedRecording(request)
            Issue.record("Expected invalid time range export to fail")
        } catch let error as WebRTCStreamRecordingEditorError {
            #expect(error == .invalidTimeRange(recording.videoURL.lastPathComponent))
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        #expect(leftovers.filter { $0.pathExtension == "mp4" || $0.pathExtension == "json" }.isEmpty)
        try? FileManager.default.removeItem(at: directory)
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

    private static func makeRecording(title: String, width: Int, height: Int, frames: Int) async throws -> WebRTCStreamRecording {
        let recorder = WebRTCStreamRecorder(firstFrameTimeout: .seconds(1))
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
        for frameIndex in 0..<frames {
            guard let pixelBuffer = makeBGRAFrame(width: width, height: height, frameIndex: frameIndex) else { throw WebRTCStreamRecordingTestError.unableToCreatePixelBuffer }
            recorder.appendEnhancedPixelBuffer(pixelBuffer)
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

private enum WebRTCStreamRecordingTestError: LocalizedError {
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
