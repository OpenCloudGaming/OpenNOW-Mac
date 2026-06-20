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
}
