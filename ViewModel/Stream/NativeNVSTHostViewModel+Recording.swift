//  Screen recording of a running native NVST stream: the HUD start/stop button state, the status
//  text it shows and the writer callbacks behind it.
//

import Foundation

@MainActor
extension NativeNVSTHostViewModel {

    /// True only while the writer is closing: the button has to stay dead until the file lands,
    /// because a second start would race the finish.
    var recordingIsBusy: Bool {
        if case .finishing = recordingStatus { return true }
        return false
    }

    var recordingCanStop: Bool {
        switch recordingStatus {
        case .starting, .recording: return true
        case .idle, .finishing, .finished, .failed: return false
        }
    }

    var recordingStatusText: String {
        switch recordingStatus {
        case .idle: return "Idle"
        case .starting: return "Starting"
        case .recording(_, let elapsedSeconds): return recordingElapsedText(elapsedSeconds)
        case .finishing: return "Saving"
        case .finished: return "Saved"
        case .failed: return "Failed"
        }
    }

    func recordingElapsedText(_ elapsedSeconds: Double) -> String {
        let seconds = max(0, Int(elapsedSeconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }

    func toggleNativeRecording() {
        guard sidebarCapabilities.supports(.recording) else { return }
        guard let path else { return }
        if recordingCanStop {
            Task { await path.stopRecording() }
            WebRTCMediaTelemetry.capture("nvst.ui.recording.stop", level: .info, message: "Native NVST recording stop requested.", attributes: ["applicationID": configuration.applicationID])
            return
        }
        guard !recordingIsBusy else { return }
        guard isConnected, !isEnding, !didEnd else { return }
        guard let settings = resolvedStreamSettings else {
            showNativeTransientStreamMessage("Recording unavailable")
            WebRTCMediaTelemetry.capture("nvst.ui.recording.start.unavailable", level: .warning, message: "Native NVST recording requested before the stream settings were resolved.", attributes: ["applicationID": configuration.applicationID])
            return
        }
        let size = Self.recordingResolution(settings.resolution)
        let recordingConfiguration = WebRTCStreamRecordingConfiguration(
            title: configuration.title,
            applicationID: configuration.applicationID,
            width: size.width,
            height: size.height,
            fps: settings.fps,
            videoBitrateMbps: settings.recordingVideoBitrateMbps,
            audioBitrateKbps: settings.recordingAudioBitrateKbps,
            // The enhancement readback is not wired on this transport, so the recording is always
            // the decoded stream. Claiming otherwise in the metadata would mislabel the file.
            enhancedVideoEnabled: false
        )
        recordingStatus = .starting
        Task { @MainActor [weak self] in
            let started = await path.startRecording(configuration: recordingConfiguration)
            guard let self, !started else { return }
            // The session went away between the button press and the actor hop, so no recorder was
            // started and nothing will ever emit a status. Put the button back rather than leaving
            // it reading "Stop Recording" for a recording that does not exist.
            self.handleRecordingStatusChanged(.failed("Recording could not start: the stream ended."))
        }
        showNativeTransientStreamMessage("Recording")
        WebRTCMediaTelemetry.capture("nvst.ui.recording.start", level: .info, message: "Native NVST recording start requested.", attributes: ["applicationID": configuration.applicationID])
    }

    /// Only a fallback: the writer takes the real dimensions from the first decoded frame, so this
    /// matters just for a recording that dies before one arrives.
    static func recordingResolution(_ value: String) -> (width: Int, height: Int) {
        let parts = value.split(separator: "x").compactMap { Int($0) }
        return (max(1, parts.first ?? 1920), max(1, parts.count > 1 ? parts[1] : 1080))
    }

    func handleRecordingStatusChanged(_ status: WebRTCStreamRecordingStatus) {
        recordingStatus = status
        recordingStatusResetTask?.cancel()
        recordingStatusResetTask = nil
        switch status {
        case .finished(let recording):
            showNativeTransientStreamMessage("Recording Saved")
            WebRTCMediaTelemetry.capture("nvst.ui.recording.finished", level: .info, message: "Native NVST recording saved.", attributes: ["applicationID": configuration.applicationID, "durationSeconds": String(format: "%.1f", recording.durationSeconds), "resolution": "\(recording.width)x\(recording.height)"])
        case .failed(let message):
            showNativeTransientStreamMessage("Recording Failed")
            WebRTCMediaTelemetry.capture("nvst.ui.recording.failed", level: .error, message: message, attributes: ["applicationID": configuration.applicationID])
        case .idle, .starting, .recording, .finishing:
            break
        }
        guard status.isTerminal else { return }
        // Leave the outcome on screen briefly, then go back to Idle so the button reads as ready.
        recordingStatusResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            guard let self, self.recordingStatus.isTerminal else { return }
            self.recordingStatus = .idle
        }
    }
}
