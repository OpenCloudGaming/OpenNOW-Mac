//  Using a retained replay window: watching the ring before deciding what to do with it, and
//  opening it in the quick editor as one prepared timeline.
//

import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import OpenNOW

@Suite("Retained replay playback", .serialized)
struct RetainedReplayPlaybackTests {
    @MainActor
    @Test("it composes the whole ring for watching before deciding")
    func itComposesTheWholeRingForWatching() async throws {
        let ring = try await RetainedReplayRing.build()
        defer { ring.roots.remove() }

        let composition = try await RetainedReplayEditing.makeWatchComposition(for: ring.window)
        #expect(composition.durationSeconds > 0.3)
        #expect(try await !composition.asset.loadTracks(withMediaType: .video).isEmpty)
    }

    @MainActor
    @Test("a retained window opens as an editable clip and exports")
    func aRetainedWindowOpensAndExports() async throws {
        let ring = try await RetainedReplayRing.build()
        defer { ring.roots.remove() }
        let window = ring.window

        let editor = try #require(await RetainedReplayEditing.makeEditor(for: window, library: []))
        #expect(editor.segments.count == window.segments.count)
        #expect(editor.canExport)
        #expect(editor.segments.allSatisfy { $0.durationSeconds > 0 })
        let fullSeconds = editor.outputDurationSeconds

        // One clip per ring file, so trimming the first really cuts into the ring rather than only
        // its last file.
        let first = try #require(editor.segments.first)
        editor.selectSegment(first)
        editor.trimEndToPlayhead(first.startSeconds + 0.2)
        #expect(editor.outputDurationSeconds < fullSeconds)

        let clip = try await editor.export()
        defer { try? StreamRecordingLibrary.delete(clip) }
        #expect(clip.durationSeconds > 0.1)
        #expect(clip.durationSeconds < fullSeconds + 0.5)
        let asset = AVURLAsset(url: clip.videoURL)
        #expect(try await !asset.loadTracks(withMediaType: .video).isEmpty)
    }
}

/// A ring built end to end through the buffer, so both playback paths run over real segment files.
private enum RetainedReplayRing {
    struct Ring {
        let window: StreamReplayRetainedWindow
        let roots: StreamReplayTestSupport.Roots
    }

    @MainActor
    static func build() async throws -> Ring {
        let roots = try StreamReplayTestSupport.makeRoots()
        let buffer = StreamReplayBuffer(root: roots.buffer, retainedRoot: roots.retained)
        buffer.start(configuration: configuration())
        try await StreamReplayTestSupport.waitForIngress(buffer)
        try await StreamReplayTestSupport.feed(buffer, frames: 120, interval: .milliseconds(30))
        buffer.retain()
        let window = try await StreamReplayTestSupport.waitForRetainedWindow(in: roots.retained)
        return Ring(window: window, roots: roots)
    }

    private static func configuration() -> StreamReplayBufferConfiguration {
        StreamReplayBufferConfiguration(
            recording: StreamRecordingConfiguration(
                title: "Replay Playback",
                applicationID: "100",
                width: 64,
                height: 64,
                fps: 30,
                videoBitrateMbps: 2,
                audioBitrateKbps: 128,
                enhancedVideoEnabled: false
            ),
            windowSeconds: 2,
            clipSeconds: 1,
            segmentSeconds: 0.5
        )
    }
}
