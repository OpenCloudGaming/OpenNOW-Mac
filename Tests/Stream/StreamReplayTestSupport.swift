//  What the replay suites share: isolated roots so a test never touches the reader's own cache or
//  Application Support store, the frame feeder, and the polling the async buffer needs.
//

import CoreVideo
import Foundation
@testable import OpenNOW

enum StreamReplayTestError: LocalizedError {
    case pixelBufferUnavailable
    case clipTimedOut
    case stateTimedOut
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .pixelBufferUnavailable: return "The replay test could not create a pixel buffer."
        case .clipTimedOut: return "The replay test timed out waiting for a saved clip."
        case .stateTimedOut: return "The replay test timed out waiting for the buffer state."
        case .saveFailed(let message): return "The replay save failed: \(message)"
        }
    }
}

actor StreamReplayStateRecorder {
    private(set) var values: [StreamReplayBufferState] = []

    func append(_ state: StreamReplayBufferState) {
        values.append(state)
    }

    func latest() -> StreamReplayBufferState? { values.last }

    func savedClip() -> StreamRecording? {
        values.compactMap(\.lastClip).last
    }
}

enum StreamReplayTestSupport {
    /// Isolated buffer and retained roots, removed together when the test finishes.
    struct Roots {
        let buffer: URL
        let retained: URL

        func remove() {
            try? FileManager.default.removeItem(at: buffer)
            try? FileManager.default.removeItem(at: retained)
        }
    }

    static func makeRoots() throws -> Roots {
        let buffer = FileManager.default.temporaryDirectory.appendingPathComponent("opn-replay-buffer-\(UUID().uuidString)", isDirectory: true)
        let retained = FileManager.default.temporaryDirectory.appendingPathComponent("opn-replay-retained-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: buffer, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: retained, withIntermediateDirectories: true)
        return Roots(buffer: buffer, retained: retained)
    }

    static func makeRoot(prefix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Feeds frames and audio at `interval` so the capture clock advances the way it would live.
    static func feed(_ buffer: StreamReplayBuffer, frames: Int, interval: Duration) async throws {
        for frameIndex in 0..<frames {
            guard let pixelBuffer = RecordingTestFixtures.makeNV12Frame(width: 64, height: 64, frameIndex: frameIndex) else {
                throw StreamReplayTestError.pixelBufferUnavailable
            }
            buffer.appendNativePixelBuffer(pixelBuffer)
            buffer.appendGameAudioSamples(RecordingTestFixtures.makeSineSamples(frameCount: 1_440, frameIndex: frameIndex), sampleRate: 48_000, channels: 2)
            try await Task.sleep(for: interval)
        }
    }

    /// Waits for the ring to open rather than for the same fact to arrive at the main actor: the
    /// delivery can starve under a loaded suite, and the frames the test feeds do not.
    static func waitForIngress(_ buffer: StreamReplayBuffer) async throws {
        try await waitUntil { buffer.isIngressOpen }
    }

    static func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw StreamReplayTestError.stateTimedOut
    }

    static func waitForRetainedWindow(in root: URL) async throws -> StreamReplayRetainedWindow {
        var window: StreamReplayRetainedWindow?
        try await waitUntil {
            window = StreamReplayRetentionLibrary.loadRetainedWindows(in: root).first
            return window != nil
        }
        guard let window else { throw StreamReplayTestError.clipTimedOut }
        return window
    }
}
