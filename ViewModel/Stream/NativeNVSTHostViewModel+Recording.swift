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
            OPNStreamTelemetry.capture("nvst.ui.recording.stop", level: .info, message: "Native NVST recording stop requested.", attributes: ["applicationID": configuration.applicationID])
            return
        }
        guard !recordingIsBusy else { return }
        guard isConnected, !isEnding, !didEnd else { return }
        guard let settings = resolvedStreamSettings else {
            showNativeTransientStreamMessage("Recording unavailable")
            OPNStreamTelemetry.capture("nvst.ui.recording.start.unavailable", level: .warning, message: "Native NVST recording requested before the stream settings were resolved.", attributes: ["applicationID": configuration.applicationID])
            return
        }
        let size = Self.recordingResolution(settings.resolution)
        let recordingConfiguration = StreamRecordingConfiguration(
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
        OPNStreamTelemetry.capture("nvst.ui.recording.start", level: .info, message: "Native NVST recording start requested.", attributes: ["applicationID": configuration.applicationID])
    }

    /// Only a fallback: the writer takes the real dimensions from the first decoded frame, so this
    /// matters just for a recording that dies before one arrives.
    static func recordingResolution(_ value: String) -> (width: Int, height: Int) {
        let parts = value.split(separator: "x").compactMap { Int($0) }
        return (max(1, parts.first ?? 1920), max(1, parts.count > 1 ? parts[1] : 1080))
    }

    func handleRecordingStatusChanged(_ status: StreamRecordingStatus) {
        recordingStatus = status
        recordingStatusResetTask?.cancel()
        recordingStatusResetTask = nil
        switch status {
        case .finished(let recording):
            showNativeTransientStreamMessage("Recording Saved")
            OPNStreamTelemetry.capture("nvst.ui.recording.finished", level: .info, message: "Native NVST recording saved.", attributes: ["applicationID": configuration.applicationID, "durationSeconds": String(format: "%.1f", recording.durationSeconds), "resolution": "\(recording.width)x\(recording.height)"])
        case .failed(let message):
            showNativeTransientStreamMessage("Recording Failed")
            OPNStreamTelemetry.capture("nvst.ui.recording.failed", level: .error, message: message, attributes: ["applicationID": configuration.applicationID])
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

    // MARK: - Instant Replay

    var isReplayBufferActive: Bool { replayBufferState.isBuffering }

    /// Whether the launch profile put this session in Instant Replay mode. The HUD offers the replay
    /// tile on this, so a manual-only session cannot present an action it has no window for.
    var isInstantReplayEnabled: Bool { resolvedStreamSettings?.recordingMode == .instantReplay }

    var replayBufferStatusText: String {
        if let reason = replayBufferState.pauseReason, !reason.isEmpty { return reason }
        if replayBufferState.isSaving { return "Saving clip…" }
        guard replayBufferState.isBuffering else { return "Off" }
        guard replayBufferState.availableSeconds >= 1 else { return "Warming up" }
        return "Last \(replayBufferState.availableText) ready"
    }

    /// Starts the rolling window when the launch profile asked for one. Called once the session is
    /// up: a buffer started before the first frame would only time out.
    func startReplayBufferIfEnabled() {
        guard let settings = resolvedStreamSettings, settings.recordingMode == .instantReplay else { return }
        guard let path else { return }
        let size = Self.recordingResolution(settings.resolution)
        let recording = StreamRecordingConfiguration(
            title: configuration.title,
            applicationID: configuration.applicationID,
            width: size.width,
            height: size.height,
            fps: settings.fps,
            videoBitrateMbps: settings.recordingVideoBitrateMbps,
            audioBitrateKbps: settings.recordingAudioBitrateKbps,
            // The enhancement readback is not wired on this transport, so the window is the decoded
            // stream, exactly as a manual recording is here.
            enhancedVideoEnabled: false
        )
        let quality = OPNStreamPreferences.replayQualityOptions[min(max(settings.recordingReplayQualityIndex, 0), OPNStreamPreferences.replayQualityOptions.count - 1)]
        let buffer = StreamReplayBufferConfiguration(
            recording: recording,
            windowSeconds: Double(settings.recordingReplayBufferWindowSeconds),
            clipSeconds: Double(settings.recordingReplayClipSeconds),
            maxHeight: quality.maxHeight,
            bitrateCeilingMbps: quality.bitrateCeilingMbps,
            retainedBudgetBytes: StreamReplayRetentionLibrary.configuredBudgetBytes
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            let started = await path.startReplayBuffer(configuration: buffer)
            guard !started else { return }
            var failure = StreamReplayBufferState()
            failure.failureMessage = "Instant Replay could not start for this session."
            self.handleReplayBufferStateChanged(failure)
        }
        OPNStreamTelemetry.capture("nvst.ui.replay.start", level: .info, message: "Native NVST instant replay started.", attributes: ["applicationID": configuration.applicationID, "windowSeconds": String(Int(buffer.windowSeconds))])
    }

    func saveNativeReplayClip() {
        guard let path, isConnected, !isEnding, !didEnd else { return }
        guard replayBufferState.isBuffering else {
            showNativeTransientStreamMessage("Replay not buffering")
            OPNStreamTelemetry.capture("nvst.ui.replay.save.unavailable", level: .warning, message: "Replay save requested while the buffer was not running.", attributes: ["applicationID": configuration.applicationID])
            return
        }
        guard !replayBufferState.isSaving else { return }
        replayBufferState.isSaving = true
        showNativeTransientStreamMessage("Saving Replay")
        Task { await path.saveReplayClip() }
        OPNStreamTelemetry.capture("nvst.ui.replay.save", level: .info, message: "Native NVST replay save requested.", attributes: ["applicationID": configuration.applicationID])
    }

    func handleReplayBufferStateChanged(_ state: StreamReplayBufferState) {
        let previous = replayBufferState
        replayBufferState = state
        if let clip = state.lastClip, clip.id != previous.lastClip?.id {
            showNativeTransientStreamMessage("Replay Saved")
            OPNStreamTelemetry.capture("nvst.ui.replay.saved", level: .info, message: "Native NVST replay clip saved.", attributes: ["applicationID": configuration.applicationID, "durationSeconds": String(format: "%.1f", clip.durationSeconds), "resolution": "\(clip.width)x\(clip.height)"])
            return
        }
        if let message = state.failureMessage, message != previous.failureMessage {
            showNativeTransientStreamMessage("Replay Failed")
            OPNStreamTelemetry.capture("nvst.ui.replay.failed", level: .error, message: message, attributes: ["applicationID": configuration.applicationID])
            return
        }
        if let reason = state.pauseReason, !reason.isEmpty, reason != previous.pauseReason {
            showNativeTransientStreamMessage("Replay Paused")
            OPNStreamTelemetry.capture("nvst.ui.replay.paused", level: .warning, message: reason, attributes: ["applicationID": configuration.applicationID])
        }
    }
}
