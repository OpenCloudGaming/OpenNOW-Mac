import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import OpenNOW

/// Serialized: every test here drives a real `AVAssetWriter`. Run in parallel they put five
/// concurrent video encoders on a CI runner with three cores and no hardware encoder, and the
/// writer inputs then report not-ready for long enough to trip the first-frame watchdog.
@Suite("WebRTCStreamRecording", .serialized)
struct WebRTCStreamRecordingTests {
    @Test("recording writes a video file from pixel buffers")
    func recordingWritesVideoFileFromPixelBuffers() async throws {
        let recorder = WebRTCStreamRecorder()
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

        var frameIndex = 0
        var sawRecording = false
        var framesAfterStart = 0
        let feedDeadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < feedDeadline {
            if await statuses.terminalStatus() != nil { break }
            guard let pixelBuffer = RecordingTestFixtures.makeBGRAFrame(width: 64, height: 64, frameIndex: frameIndex) else {
                Issue.record("Unable to create test pixel buffer")
                return
            }
            recorder.appendEnhancedPixelBuffer(pixelBuffer)
            frameIndex += 1
            if sawRecording { framesAfterStart += 1 }
            if !sawRecording {
                sawRecording = await statuses.values.contains { status in
                    if case .recording = status { return true }
                    return false
                }
            }
            if sawRecording && framesAfterStart >= 8 { break }
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
        for _ in 0..<40 {
            terminalStatus = await statuses.terminalStatus()
            if terminalStatus != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(terminalStatus == .failed("Recording could not capture video frames."))
    }

    @Test("exports a trimmed recording as a new clip")
    func exportsTrimmedRecordingAsNewClip() async throws {
        let recording = try await RecordingTestFixtures.makeRecording(title: "Trim Source Regression", width: 96, height: 64, frames: 18)
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

    /// Highest on a trim-only edit takes the passthrough path - no re-encode - so this is the guard
    /// that the copy still lands as a valid, shorter clip at the source resolution.
    @Test("exports a trim-only edit without re-encoding it")
    func exportsTrimOnlyEditWithoutReEncoding() async throws {
        let recording = try await RecordingTestFixtures.makeRecording(title: "Passthrough Source Regression", width: 96, height: 64, frames: 18)
        defer { try? WebRTCStreamRecordingLibrary.delete(recording) }
        let endSeconds = max(0.12, recording.durationSeconds * 0.6)
        let request = WebRTCStreamRecordingEditRequest(
            title: "Passthrough Export Regression",
            segments: [WebRTCStreamRecordingEditSegment(recording: recording, startSeconds: 0, endSeconds: endSeconds)],
            exportPreset: .highestQuality
        )

        let edited = try await WebRTCStreamRecordingLibrary.exportEditedRecording(request)
        defer { try? WebRTCStreamRecordingLibrary.delete(edited) }

        #expect(edited.width == recording.width)
        #expect(edited.height == recording.height)
        #expect(edited.durationSeconds > 0)
        #expect(edited.durationSeconds < recording.durationSeconds)
        #expect(edited.fileSizeBytes > 0)
        #expect(edited.videoBitrateMbps == recording.videoBitrateMbps)
    }

    /// The rule itself, not its effect. The exported file cannot distinguish the two paths -
    /// `.highestQuality` renders at source resolution either way, and the recorded bitrate comes
    /// from the preset, not from how the export ran - so the branch that protects against a copy
    /// starting on the wrong keyframe is pinned here directly.
    @Test("passthrough is allowed only for a single segment starting at the head")
    func passthroughRuleRefusesAnythingThatCannotBeACopy() {
        let recording = WebRTCStreamRecording(
            id: UUID(), title: "Rule", applicationID: "com.example.game", createdAt: Date(),
            durationSeconds: 30, width: 1920, height: 1080, videoBitrateMbps: 40, audioBitrateKbps: 160,
            enhancedVideo: false, fileName: "clip.mp4", fileSizeBytes: 1, storageDirectoryPath: NSTemporaryDirectory()
        )
        func request(
            crop: WebRTCStreamRecordingCrop? = nil,
            rotation: WebRTCStreamRecordingRotation = .degrees0,
            rate: Double = 1,
            audio: WebRTCStreamRecordingAudioEdit = .original,
            preset: WebRTCStreamRecordingExportPreset = .highestQuality
        ) -> WebRTCStreamRecordingEditRequest {
            WebRTCStreamRecordingEditRequest(
                title: "Rule",
                segments: [WebRTCStreamRecordingEditSegment(recording: recording, startSeconds: 0, endSeconds: 30)],
                crop: crop, rotation: rotation, playbackRate: rate, audio: audio, exportPreset: preset
            )
        }
        func allowed(_ request: WebRTCStreamRecordingEditRequest, segments: Int = 1, start: Double = 0) -> Bool {
            WebRTCStreamRecordingLibrary.canPassthrough(request, segmentCount: segments, firstSegmentStartSeconds: start)
        }

        #expect(allowed(request()), "a tail trim of one segment is a genuine copy")

        // The keyframe rule: a copy cannot begin on a non-sync sample, and the recorder writes one
        // every two seconds, so a head trim would silently keep from the preceding keyframe.
        #expect(allowed(request(), start: 17.4) == false)
        #expect(allowed(request(), segments: 2) == false, "a second section would begin mid-GOP")

        // Anything that changes the pixels or the samples has to be re-encoded.
        #expect(allowed(request(crop: WebRTCStreamRecordingCrop(x: 0.1, y: 0.1, width: 0.5, height: 0.5))) == false)
        #expect(allowed(request(rotation: .degrees90)) == false)
        #expect(allowed(request(rate: 1.5)) == false)
        #expect(allowed(request(audio: WebRTCStreamRecordingAudioEdit(volume: 0.5))) == false)
        #expect(allowed(request(audio: WebRTCStreamRecordingAudioEdit(isMuted: true))) == false)
        #expect(allowed(request(preset: .balanced)) == false, "the smaller presets exist to re-encode")
        #expect(allowed(request(preset: .compact)) == false)
    }

    /// A passthrough copy starts at the preceding keyframe, so a head trim would land up to a GOP
    /// early. The exporter must re-encode instead of quietly returning different footage.
    @Test("a head trim is re-encoded rather than copied to the wrong keyframe")
    func headTrimIsReEncodedNotSnappedToAKeyframe() async throws {
        let recording = try await RecordingTestFixtures.makeRecording(title: "Head Trim Regression", width: 96, height: 64, frames: 24)
        defer { try? WebRTCStreamRecordingLibrary.delete(recording) }
        let start = recording.durationSeconds * 0.4
        let request = WebRTCStreamRecordingEditRequest(
            title: "Head Trim Export Regression",
            segments: [WebRTCStreamRecordingEditSegment(recording: recording, startSeconds: start, endSeconds: recording.durationSeconds)],
            exportPreset: .highestQuality
        )

        let edited = try await WebRTCStreamRecordingLibrary.exportEditedRecording(request)
        defer { try? WebRTCStreamRecordingLibrary.delete(edited) }

        let expected = recording.durationSeconds - start
        #expect(edited.durationSeconds > 0)
        #expect(abs(edited.durationSeconds - expected) < 0.25, "asked for \(expected)s, got \(edited.durationSeconds)s")
    }

    @Test("exports a recording with a middle cut removed")
    func exportsRecordingWithMiddleCutRemoved() async throws {
        let recording = try await RecordingTestFixtures.makeRecording(title: "Cut Source Regression", width: 96, height: 64, frames: 24)
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
        let first = try await RecordingTestFixtures.makeRecording(title: "Join Source A Regression", width: 80, height: 64, frames: 12)
        let second = try await RecordingTestFixtures.makeRecording(title: "Join Source B Regression", width: 80, height: 64, frames: 12)
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
        let recording = try await RecordingTestFixtures.makeRecording(title: "Preview Source Regression", width: 80, height: 64, frames: 18)
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
        let recording = try await RecordingTestFixtures.makeRecording(title: "Transform Source Regression", width: 128, height: 80, frames: 20)
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
        let recording = try await RecordingTestFixtures.makeRecording(title: "Cleanup Source Regression", width: 64, height: 64, frames: 10)
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

    @Test("recording writes a video file from native NV12 frames")
    func recordingWritesVideoFileFromNativePixelBuffers() async throws {
        let recorder = WebRTCStreamRecorder()
        let statuses = StreamRecordingStatusRecorder()
        recorder.onStatusChanged = { status in
            Task { await statuses.append(status) }
        }

        recorder.start(configuration: WebRTCStreamRecordingConfiguration(
            title: "Native Frame Regression",
            applicationID: "100",
            width: 64,
            height: 64,
            fps: 30,
            videoBitrateMbps: 1,
            audioBitrateKbps: 128,
            enhancedVideoEnabled: false
        ))

        var frameIndex = 0
        var sawRecording = false
        var framesAfterStart = 0
        let feedDeadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < feedDeadline {
            if await statuses.terminalStatus() != nil { break }
            guard let pixelBuffer = RecordingTestFixtures.makeNV12Frame(width: 64, height: 64, frameIndex: frameIndex) else {
                Issue.record("Unable to create test NV12 pixel buffer")
                return
            }
            recorder.appendNativePixelBuffer(pixelBuffer)
            // Interleaved stereo float, the shape the NVST Opus decoder produces when audio runs on
            // its own socket rather than through libwebrtc's audio device.
            recorder.appendGameAudioSamples(RecordingTestFixtures.makeSineSamples(frameCount: 480, frameIndex: frameIndex), sampleRate: 48_000, channels: 2)
            frameIndex += 1
            if sawRecording { framesAfterStart += 1 }
            if !sawRecording {
                sawRecording = await statuses.values.contains { status in
                    if case .recording = status { return true }
                    return false
                }
            }
            if sawRecording && framesAfterStart >= 8 { break }
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

        #expect(FileManager.default.fileExists(atPath: recording.videoURL.path))
        #expect(recording.fileSizeBytes > 0)
        #expect(recording.durationSeconds > 0)
        #expect(recording.width == 64)
        #expect(recording.height == 64)
        #expect(recording.enhancedVideo == false)
        let asset = AVURLAsset(url: recording.videoURL)
        #expect(try await asset.loadTracks(withMediaType: .video).first != nil)
        // The float PCM path has to reach the file, not just be accepted: with audio on its own
        // socket this is the recording's only audio source.
        #expect(try await asset.loadTracks(withMediaType: .audio).first != nil)
    }

}
