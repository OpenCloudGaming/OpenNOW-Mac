//  The window a finished stream leaves behind: the ring stays on disk, one window per title, capped
//  by the reader's budget, and a later session of the same title picks it back up and keeps rolling.
//

import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import OpenNOW

@Suite("StreamReplayRetention", .serialized)
struct StreamReplayRetentionTests {
    @Test("it moves the ring out of the purgeable cache and keeps it")
    func itMovesTheRingOutOfTheCacheAndKeepsIt() async throws {
        let roots = try StreamReplayTestSupport.makeRoots()
        defer { roots.remove() }
        let buffer = StreamReplayBuffer(root: roots.buffer, retainedRoot: roots.retained)
        let states = StreamReplayStateRecorder()
        buffer.onStateChanged = { state in Task { await states.append(state) } }
        buffer.start(configuration: Self.configuration())
        try await StreamReplayTestSupport.waitForIngress(buffer)
        try await StreamReplayTestSupport.feed(buffer, frames: 80, interval: .milliseconds(30))

        buffer.retain()

        let window = try await StreamReplayTestSupport.waitForRetainedWindow(in: roots.retained)
        #expect(window.title == "Replay Retention")
        #expect(window.durationSeconds > 0.3)
        #expect(window.hasAllSegments)
        // Kept where a cache purge cannot reach it, and gone from where it was written.
        #expect(window.directoryURL.path.hasPrefix(roots.retained.path))
        #expect(FileManager.default.fileExists(atPath: window.manifestURL.path))
        let cacheLeftovers = (try? FileManager.default.contentsOfDirectory(atPath: roots.buffer.path)) ?? []
        #expect(cacheLeftovers.isEmpty)

        // And it is still saveable: Keep writes one ordinary recording.
        let recording = try await StreamReplayClipExporter.exportRetainedWindow(window)
        defer { try? StreamRecordingLibrary.delete(recording) }
        #expect(recording.durationSeconds > 0.3)
        let asset = AVURLAsset(url: recording.videoURL)
        #expect(try await !asset.loadTracks(withMediaType: .video).isEmpty)
    }

    @Test("it keeps one window per title, newest wins")
    func itKeepsOneWindowPerTitle() throws {
        let root = try StreamReplayTestSupport.makeRoot(prefix: "opn-retention")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeWindow(in: root, applicationID: "100", createdAt: Date().addingTimeInterval(-600))
        let newest = try Self.writeWindow(in: root, applicationID: "100", createdAt: Date())
        let other = try Self.writeWindow(in: root, applicationID: "200", createdAt: Date().addingTimeInterval(-120))

        #expect(StreamReplayRetentionLibrary.prune(in: root, budgetBytes: 1_000_000))
        let remaining = Set(StreamReplayRetentionLibrary.loadRetainedWindows(in: root).map(\.id))
        #expect(remaining == Set([newest.id, other.id]))
    }

    @Test("it evicts the oldest title when the store is over budget")
    func itEvictsTheOldestTitleOverBudget() throws {
        let root = try StreamReplayTestSupport.makeRoot(prefix: "opn-retention")
        defer { try? FileManager.default.removeItem(at: root) }
        let older = try Self.writeWindow(in: root, applicationID: "100", createdAt: Date().addingTimeInterval(-600), segmentSizes: [600])
        let newer = try Self.writeWindow(in: root, applicationID: "200", createdAt: Date(), segmentSizes: [600])

        #expect(StreamReplayRetentionLibrary.prune(in: root, budgetBytes: 1_000))
        let remaining = StreamReplayRetentionLibrary.loadRetainedWindows(in: root)
        #expect(remaining.map(\.id) == [newer.id])
        #expect(!FileManager.default.fileExists(atPath: older.directoryURL.path))
    }

    @Test("it cuts the oldest footage when one title alone is over budget")
    func itCutsTheOldestFootageOverBudget() throws {
        let root = try StreamReplayTestSupport.makeRoot(prefix: "opn-retention")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeWindow(in: root, applicationID: "100", segmentSizes: [600, 600])

        #expect(StreamReplayRetentionLibrary.enforceBudget(1_000, in: root))
        let remaining = try #require(StreamReplayRetentionLibrary.loadRetainedWindows(in: root).first)
        #expect(remaining.segments.count == 1)
        #expect(remaining.startHostTime == 60)
    }

    @Test("it rolls a title's window across that title's sessions")
    func itRollsATitlesWindowAcrossItsSessions() async throws {
        let roots = try StreamReplayTestSupport.makeRoots()
        defer { roots.remove() }
        let firstSession = StreamReplayBuffer(root: roots.buffer, retainedRoot: roots.retained)
        firstSession.start(configuration: Self.configuration())
        try await StreamReplayTestSupport.waitForIngress(firstSession)
        try await StreamReplayTestSupport.feed(firstSession, frames: 80, interval: .milliseconds(30))
        firstSession.retain()
        let window = try await StreamReplayTestSupport.waitForRetainedWindow(in: roots.retained)
        #expect(FileManager.default.fileExists(atPath: window.directoryURL.path))

        let secondSession = StreamReplayBuffer(root: roots.buffer, retainedRoot: roots.retained)
        let states = StreamReplayStateRecorder()
        secondSession.onStateChanged = { state in Task { await states.append(state) } }
        secondSession.start(configuration: Self.configuration())
        defer { secondSession.stop() }

        // The ring already holds the earlier session's footage, before this one sends a frame.
        let adoptedSeconds = try await Self.waitForAvailableSeconds(above: 0.3, states: states)
        #expect(adoptedSeconds > 0.3)
        // And it was consumed rather than left behind as a second window.
        #expect(StreamReplayRetentionLibrary.loadRetainedWindows(in: roots.retained).isEmpty)
    }

    @Test("it adopts a stored ring into the next session")
    func itAdoptsAStoredRing() async throws {
        let roots = try StreamReplayTestSupport.makeRoots()
        defer { roots.remove() }
        try Self.writeWindow(in: roots.retained, applicationID: "100", segmentSizes: [16])

        let buffer = StreamReplayBuffer(root: roots.buffer, retainedRoot: roots.retained)
        buffer.start(configuration: Self.configuration())
        defer { buffer.stop() }
        try await StreamReplayTestSupport.waitForIngress(buffer)

        #expect(StreamReplayRetentionLibrary.loadRetainedWindows(in: roots.retained).isEmpty)
        // The ring's files now live in the session's own staging directory.
        let staged = (try? FileManager.default.contentsOfDirectory(atPath: roots.buffer.path)) ?? []
        #expect(staged.count == 1)
    }

    @Test("it keeps an adopted ring when the new session captures nothing")
    func itKeepsAnAdoptedRingWhenTheNewSessionCapturesNothing() async throws {
        let roots = try StreamReplayTestSupport.makeRoots()
        defer { roots.remove() }
        let firstSession = StreamReplayBuffer(root: roots.buffer, retainedRoot: roots.retained)
        firstSession.start(configuration: Self.configuration())
        try await StreamReplayTestSupport.waitForIngress(firstSession)
        try await StreamReplayTestSupport.feed(firstSession, frames: 80, interval: .milliseconds(30))
        firstSession.retain()
        let window = try await StreamReplayTestSupport.waitForRetainedWindow(in: roots.retained)
        #expect(window.durationSeconds > 0.3)

        let secondSession = StreamReplayBuffer(root: roots.buffer, retainedRoot: roots.retained)
        secondSession.start(configuration: Self.configuration())
        try await StreamReplayTestSupport.waitForIngress(secondSession)
        secondSession.stop()

        // The earlier session's footage survives: it is retained again rather than taken down with
        // a session that never sent a frame.
        let kept = try await StreamReplayTestSupport.waitForRetainedWindow(in: roots.retained)
        #expect(kept.durationSeconds > 0.3)
    }

    @Test("it leaves a window written before a reboot alone")
    func itLeavesAPreRebootWindowAlone() async throws {
        let roots = try StreamReplayTestSupport.makeRoots()
        defer { roots.remove() }
        // After a reboot the capture clock restarts, so a stored window's times sit ahead of now.
        let now = CACurrentMediaTime()
        let window = try Self.writeWindow(in: roots.retained, applicationID: "100", startHostTime: now + 600, endHostTime: now + 660)

        let buffer = StreamReplayBuffer(root: roots.buffer, retainedRoot: roots.retained)
        buffer.start(configuration: Self.configuration())
        defer { buffer.stop() }
        try await StreamReplayTestSupport.waitForIngress(buffer)

        #expect(StreamReplayRetentionLibrary.loadRetainedWindows(in: roots.retained).map(\.id) == [window.id])
    }

    @Test("it leaves a window of another encoded shape for that shape's session")
    func itLeavesAMismatchedWindowAlone() async throws {
        let roots = try StreamReplayTestSupport.makeRoots()
        defer { roots.remove() }
        let window = try Self.writeWindow(in: roots.retained, applicationID: "100", width: 128, height: 128)

        let buffer = StreamReplayBuffer(root: roots.buffer, retainedRoot: roots.retained)
        buffer.start(configuration: Self.configuration())
        defer { buffer.stop() }
        try await StreamReplayTestSupport.waitForIngress(buffer)

        #expect(StreamReplayRetentionLibrary.loadRetainedWindows(in: roots.retained).map(\.id) == [window.id])
    }

    // MARK: - Fixtures

    private static func configuration() -> StreamReplayBufferConfiguration {
        StreamReplayBufferConfiguration(
            recording: StreamRecordingConfiguration(
                title: "Replay Retention",
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

    @discardableResult
    private static func writeWindow(in root: URL,
                                    applicationID: String = "100",
                                    createdAt: Date = Date(),
                                    width: Int = 64,
                                    height: Int = 64,
                                    startHostTime: CFTimeInterval = 0,
                                    endHostTime: CFTimeInterval = 0,
                                    segmentSizes: [Int] = [0]) throws -> StreamReplayRetainedWindow {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let secondsPerSegment: Double = 60
        var segments: [StreamReplayRetainedWindow.Segment] = []
        for (index, size) in segmentSizes.enumerated() {
            let name = "segment-\(index).mp4"
            try Data(repeating: 0, count: size).write(to: directory.appendingPathComponent(name))
            let start = Double(index) * secondsPerSegment
            segments.append(StreamReplayRetainedWindow.Segment(fileName: name, hostStart: start, hostEnd: start + secondsPerSegment))
        }
        let window = StreamReplayRetainedWindow(
            id: UUID(),
            title: "Replay Retention",
            applicationID: applicationID,
            createdAt: createdAt,
            startHostTime: endHostTime > 0 ? startHostTime : (segments.first?.hostStart ?? 0),
            endHostTime: endHostTime > 0 ? endHostTime : (segments.last?.hostEnd ?? 0),
            width: width,
            height: height,
            videoBitrateMbps: 2,
            audioBitrateKbps: 128,
            segments: segments,
            storageDirectoryPath: directory.path
        )
        try StreamReplayRetentionLibrary.write(window)
        return window
    }

    private static func waitForAvailableSeconds(above threshold: Double, states: StreamReplayStateRecorder) async throws -> Double {
        let deadline = ContinuousClock.now + .seconds(20)
        var latest = 0.0
        while ContinuousClock.now < deadline {
            latest = await states.latest()?.availableSeconds ?? 0
            if latest > threshold { return latest }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw StreamReplayTestError.stateTimedOut
    }
}
