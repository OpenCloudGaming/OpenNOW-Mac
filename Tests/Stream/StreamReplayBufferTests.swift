//  The rolling instant-replay window driven end to end: real `AVAssetWriter`s fed by synthetic
//  frames, a save that stitches the window without re-encoding, and the clip read back to prove it
//  starts on a keyframe and is decodable.
//

import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import OpenNOW

@Suite("StreamReplayBuffer", .serialized)
struct StreamReplayBufferTests {
    @Test("it saves the buffered window as a clip that decodes from its first frame")
    func savesTheWindowAsADecodableClip() async throws {
        let roots = try StreamReplayTestSupport.makeRoots()
        defer { roots.remove() }
        let buffer = StreamReplayBuffer(root: roots.buffer, retainedRoot: roots.retained)
        let states = StreamReplayStateRecorder()
        buffer.onStateChanged = { state in
            Task { await states.append(state) }
        }
        let configuration = StreamReplayBufferConfiguration(
            recording: Self.recordingConfiguration(title: "Replay Save"),
            windowSeconds: 1.5,
            segmentSeconds: 0.5
        )
        buffer.start(configuration: configuration)
        defer { buffer.stop() }
        try await StreamReplayTestSupport.waitForIngress(buffer)

        try await StreamReplayTestSupport.feed(buffer, frames: 80, interval: .milliseconds(30))

        let clip = try await Self.saveAndAwaitClip(buffer, states: states)
        defer { try? StreamRecordingLibrary.delete(clip) }

        #expect(clip.width == 64)
        #expect(clip.height == 64)
        #expect(clip.durationSeconds > 0.3)
        #expect(clip.durationSeconds <= configuration.windowSeconds + configuration.segmentSeconds + 1.5)
        #expect(FileManager.default.fileExists(atPath: clip.videoURL.path))

        let asset = AVURLAsset(url: clip.videoURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(videoTracks.count == 1)
        #expect(audioTracks.count == 1)

        // Decoding the first sample proves the clip opens on a keyframe and references nothing the
        // clip does not contain.
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: try #require(videoTracks.first),
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        #expect(reader.canAdd(output))
        reader.add(output)
        #expect(reader.startReading())
        let firstSample = try #require(output.copyNextSampleBuffer())
        #expect(CMSampleBufferGetNumSamples(firstSample) > 0)
        #expect(CMSampleBufferGetImageBuffer(firstSample) != nil)
        reader.cancelReading()
    }

    @Test("it keeps the buffered window bounded as the stream outgrows it")
    func keepsTheWindowBounded() async throws {
        let roots = try StreamReplayTestSupport.makeRoots()
        defer { roots.remove() }
        let buffer = StreamReplayBuffer(root: roots.buffer, retainedRoot: roots.retained)
        let states = StreamReplayStateRecorder()
        buffer.onStateChanged = { state in
            Task { await states.append(state) }
        }
        let configuration = StreamReplayBufferConfiguration(
            recording: Self.recordingConfiguration(title: "Replay Bound"),
            windowSeconds: 1,
            segmentSeconds: 0.4
        )
        buffer.start(configuration: configuration)
        defer { buffer.stop() }
        try await StreamReplayTestSupport.waitForIngress(buffer)

        // Three seconds of footage against a one-second window: the window must not grow with it.
        try await StreamReplayTestSupport.feed(buffer, frames: 100, interval: .milliseconds(30))
        let available = await states.latest()?.availableSeconds ?? 0
        #expect(available <= configuration.windowSeconds + 0.05)

        let clip = try await Self.saveAndAwaitClip(buffer, states: states)
        defer { try? StreamRecordingLibrary.delete(clip) }
        #expect(clip.durationSeconds <= configuration.windowSeconds + configuration.segmentSeconds + 1.5)
    }

    @Test("a save writes the clip length, not the whole window")
    func aSaveWritesTheClipLengthNotTheWholeWindow() async throws {
        let roots = try StreamReplayTestSupport.makeRoots()
        defer { roots.remove() }
        let buffer = StreamReplayBuffer(root: roots.buffer, retainedRoot: roots.retained)
        let states = StreamReplayStateRecorder()
        buffer.onStateChanged = { state in
            Task { await states.append(state) }
        }
        let configuration = StreamReplayBufferConfiguration(
            recording: Self.recordingConfiguration(title: "Replay Slice"),
            windowSeconds: 4,
            clipSeconds: 1,
            segmentSeconds: 0.5
        )
        buffer.start(configuration: configuration)
        defer { buffer.stop() }
        try await StreamReplayTestSupport.waitForIngress(buffer)

        // Long enough for the window to hold several seconds, so a one-second clip proves the cut.
        try await StreamReplayTestSupport.feed(buffer, frames: 120, interval: .milliseconds(30))

        let clip = try await Self.saveAndAwaitClip(buffer, states: states)
        defer { try? StreamRecordingLibrary.delete(clip) }
        #expect(clip.durationSeconds > 0.5)
        #expect(clip.durationSeconds <= configuration.clipSeconds + configuration.segmentSeconds + 1.0)
    }

    @Test("a clip is never longer than the window it is cut from")
    func aClipIsNeverLongerThanItsWindow() {
        let short = StreamReplayBufferConfiguration(recording: Self.recordingConfiguration(title: "Clip"), windowSeconds: 120, clipSeconds: 600)
        #expect(short.clipSeconds == 120)
        let normal = StreamReplayBufferConfiguration(recording: Self.recordingConfiguration(title: "Clip"), windowSeconds: 1_800, clipSeconds: 30)
        #expect(normal.clipSeconds == 30)
        #expect(StreamReplayBufferConfiguration.maximumWindowSeconds == 7_200)
    }

    @Test("the scaler really resizes a decoded frame, and passes small ones through")
    func theScalerResizesAndPassesThrough() throws {
        let source = try #require(RecordingTestFixtures.makeNV12Frame(width: 64, height: 48, frameIndex: 0))
        let transfer = OPNPixelBufferTransfer()
        let scaled = try #require(transfer.scaled(source, maxHeight: 32))
        #expect(CVPixelBufferGetHeight(scaled) == 32)
        // 64 × 32/48 = 42.67, rounded down to an even 42.
        #expect(CVPixelBufferGetWidth(scaled) == 42)
        let untouched = try #require(transfer.scaled(source, maxHeight: 720))
        #expect(CVPixelBufferGetWidth(untouched) == 64)
        #expect(CVPixelBufferGetHeight(untouched) == 48)
    }

    @Test("a capped tier encodes a smaller frame and estimates a smaller file")
    func aCappedTierEncodesAndEstimatesSmaller() {
        // Auto bitrate, so the estimate follows the pixel count the way the writer's own rule does.
        let recording = Self.recordingConfiguration(title: "Full", videoBitrateMbps: 0)
        let full = StreamReplayBufferConfiguration(recording: recording, windowSeconds: 60)
        let capped = StreamReplayBufferConfiguration(recording: recording, windowSeconds: 60, maxHeight: 480, bitrateCeilingMbps: 3)
        #expect(full.estimatedBufferBytes(width: 1920, height: 1080) > capped.estimatedBufferBytes(width: 1920, height: 1080))
        // 1080p scaled to a 480 cap stays 16:9 and even.
        let size = OPNVideoSize.capped(width: 1920, height: 1080, maxHeight: 480)
        #expect(size == (width: 852, height: 480))
        // An uncapped or already-small frame is handed back untouched.
        #expect(OPNVideoSize.capped(width: 1920, height: 1080, maxHeight: 0) == (width: 1920, height: 1080))
        #expect(OPNVideoSize.capped(width: 640, height: 360, maxHeight: 720) == (width: 640, height: 360))
    }

    @Test("the replay quality tiers run from match-stream down to 480p")
    func replayQualityTiersDescend() {
        let options = OPNStreamPreferences.replayQualityOptions
        #expect(options.first?.maxHeight == 0)
        #expect(options.map(\.maxHeight) == [0, 1440, 1080, 720, 480])
        // Every capped tier carries a ceiling, or it would cost the same as the stream it was cut
        // down from.
        #expect(options.dropFirst().allSatisfy { $0.bitrateCeilingMbps > 0 })
    }

    @Test("the disk estimate follows the encoder's own bitrate rule")
    func diskEstimateFollowsTheEncoderBitrate() {
        let explicit = StreamReplayBufferConfiguration(
            recording: Self.recordingConfiguration(title: "Estimate", videoBitrateMbps: 20),
            windowSeconds: 60,
            segmentSeconds: 1
        )
        let expected = Double(20_000_000 + 128 * 1_000) / 8 * 61
        #expect(abs(Double(explicit.estimatedBufferBytes(width: 1920, height: 1080)) - expected) < 1)
    }

    // MARK: - Fixtures

    private static func recordingConfiguration(title: String, videoBitrateMbps: Int = 2) -> StreamRecordingConfiguration {
        StreamRecordingConfiguration(
            title: title,
            applicationID: "100",
            width: 64,
            height: 64,
            fps: 30,
            videoBitrateMbps: videoBitrateMbps,
            audioBitrateKbps: 128,
            enhancedVideoEnabled: false
        )
    }

    private static func saveAndAwaitClip(_ buffer: StreamReplayBuffer, states: StreamReplayStateRecorder) async throws -> StreamRecording {
        let previousID = await states.savedClip()?.id
        buffer.saveClip()
        let deadline = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < deadline {
            if let clip = await states.savedClip(), clip.id != previousID { return clip }
            if let failure = await states.latest()?.failureMessage, !failure.isEmpty {
                throw StreamReplayTestError.saveFailed(failure)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw StreamReplayTestError.clipTimedOut
    }
}
