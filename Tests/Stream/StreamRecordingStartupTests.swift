import Foundation
import Testing
@testable import OpenNOW

private actor RecordingStatusRecorder {
    private(set) var values: [StreamRecordingStatus] = []

    func append(_ status: StreamRecordingStatus) {
        values.append(status)
    }

    func terminalStatus() -> StreamRecordingStatus? {
        values.first { $0.isTerminal }
    }
}

@Suite("Stream recording startup")
struct StreamRecordingStartupTests {
    @Test("stopping recording before first video frame fails without crashing")
    func stoppingRecordingBeforeFirstFrameFailsWithoutCrashing() async throws {
        let recorder = StreamRecorder(firstFrameTimeout: .seconds(600))
        let statuses = RecordingStatusRecorder()
        recorder.onStatusChanged = { status in
            Task { await statuses.append(status) }
        }

        recorder.start(configuration: StreamRecordingConfiguration(
            title: "Crash Regression",
            applicationID: "100",
            width: 1280,
            height: 720,
            fps: 60,
            videoBitrateMbps: 8,
            audioBitrateKbps: 128,
            enhancedVideoEnabled: false
        ))
        try await Task.sleep(for: .milliseconds(100))
        recorder.stop()

        var terminalStatus: StreamRecordingStatus?
        for _ in 0..<200 {
            terminalStatus = await statuses.terminalStatus()
            if terminalStatus != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(terminalStatus == .failed("Recording stopped before any video frames were captured."))
    }
}
