//  The stream HUD's AUDIO panel commands: the output device picker, the local game gain and the
//  microphone gain. Each writes the same stream preference Settings writes.
import Foundation

@MainActor
extension NativeNVSTHostViewModel {
    /// One controller press moves a volume this far, wrapping to silence past full.
    static let volumeStepPercent = 10

    /// The mute icon's own state. The override outranks a held push-to-talk key.
    var isNativeMicrophoneMuted: Bool {
        !microphoneAvailable || isMicrophoneMuteOverrideActive
    }

    /// The AUDIO panel's microphone status line, composed here so the view and its tests agree.
    var microphoneStatusText: String {
        guard microphoneAvailable else { return "Disabled" }
        guard !isMicrophoneMuteOverrideActive else { return "Muted" }
        if microphoneMode == "push-to-talk" { return microphoneEnabled ? "PTT Active" : "PTT Ready" }
        if microphoneMode == "voice-activity", microphoneEnabled { return "Voice Activity" }
        return microphoneEnabled ? "On" : "Muted"
    }

    /// The captions the panel shows for a focused volume row and its mute icon.
    var gameVolumeCaption: String { "Game Volume \u{00b7} \(gameVolumePercent)%" }
    var gameVolumeMuteCaption: String { nativeLocalAudioMuted ? "Unmute Local Audio" : "Mute Local Audio" }
    var microphoneVolumeCaption: String { "Microphone Volume \u{00b7} \(microphoneVolumePercent)%" }
    var microphoneVolumeMuteCaption: String { isNativeMicrophoneMuted ? "Unmute Microphone" : "Mute Microphone" }

    // MARK: - Local game volume

    /// The local playback gain, applied after the game-audio tee: 0% is silent, 100% is untouched.
    func updateNativeGameVolume(percent: Int) {
        let level = clampedAudioPercent(percent)
        gameVolumePercent = level
        OPNStreamPreferences.saveGameVolume(Double(level) / 100)
        pushNativeAudioLevel(level, to: .game)
        OPNStreamTelemetry.capture("nvst.ui.game.volume", level: .info, message: "Native NVST local game volume changed.", attributes: ["applicationID": configuration.applicationID, "percent": String(level)])
    }

    /// Controller/keyboard step through the HUD row: +10% per press, wrapping to silence.
    func cycleNativeGameVolume() {
        updateNativeGameVolume(percent: nextVolumePercent(after: gameVolumePercent))
    }

    // MARK: - Microphone volume

    /// The capture gain. It never opens or closes the gate and never clears the mute override.
    func updateNativeMicrophoneVolume(percent: Int) {
        let level = clampedAudioPercent(percent)
        microphoneVolumePercent = level
        OPNStreamPreferences.saveMicrophoneVolume(Double(level) / 100)
        pushNativeAudioLevel(level, to: .microphone)
        OPNStreamTelemetry.capture("nvst.ui.microphone.volume", level: .info, message: "Native NVST microphone volume changed.", attributes: ["applicationID": configuration.applicationID, "percent": String(level)])
    }

    func cycleNativeMicrophoneVolume() {
        updateNativeMicrophoneVolume(percent: nextVolumePercent(after: microphoneVolumePercent))
    }

    /// Which transport call a level belongs to. The two levels differ only in that.
    private enum NativeAudioLevelTarget {
        case game
        case microphone
    }

    private func clampedAudioPercent(_ percent: Int) -> Int {
        min(max(percent, 0), 100)
    }

    private func nextVolumePercent(after percent: Int) -> Int {
        let next = percent + Self.volumeStepPercent
        return next > 100 ? 0 : next
    }

    private func pushNativeAudioLevel(_ percent: Int, to target: NativeAudioLevelTarget) {
        guard let path else { return }
        let normalizedLevel = Double(percent) / 100
        Task { @MainActor in
            do {
                switch target {
                case .game: try await path.setGameVolume(normalizedLevel)
                case .microphone: try await path.setMicrophoneVolume(normalizedLevel)
                }
            } catch {
                guard !Task.isCancelled, !didEnd else { return }
                showNativeTransientStreamMessage(Self.message(for: error))
            }
        }
    }

    // MARK: - Output device

    /// Refuses a UID the picker does not offer, then asks the device to switch. The saved choice is
    /// only written once the device reports the route activated.
    func requestNativeOutputDevice(_ uid: String) {
        guard let path, isConnected, !isEnding, !didEnd else { return }
        guard outputDeviceOptions.contains(where: { $0.uniqueId == uid }), uid != selectedOutputDeviceUID else { return }
        outputDevicePendingUID = uid
        outputDeviceUpdateTask?.cancel()
        outputDeviceUpdateTask = Task { @MainActor in
            do {
                try await path.setOutputDevice(uid)
            } catch {
                guard !Task.isCancelled, !didEnd else { return }
                abandonPendingOutputDevice(message: Self.message(for: error))
                return
            }
            // A session with no audio device never reports back, so the picker must not stay stuck.
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, outputDevicePendingUID == uid else { return }
            abandonPendingOutputDevice(message: "Could not switch audio output.")
        }
        OPNStreamTelemetry.capture("nvst.ui.output.device", level: .info, message: "Native NVST output device requested.", attributes: ["applicationID": configuration.applicationID, "deviceId": uid.isEmpty ? "default" : uid])
    }

    /// The device's own report, which is the authority on the route really in use.
    func handleNativeOutputDeviceChange(_ change: NvstOutputDeviceChange) {
        guard !didEnd else { return }
        let wasFallback = isOutputDeviceFallbackActive
        refreshOutputDeviceOptions()
        isOutputDeviceFallbackActive = change.isFallback
        outputDeviceResolvedUID = change.resolvedUniqueID ?? ""
        guard let requested = outputDevicePendingUID else {
            announceSettledOutputRoute(change: change, wasFallback: wasFallback)
            return
        }
        resolvePendingOutputDevice(requested: requested, change: change)
    }

    /// A route change nobody asked for: a fallback, a restore, or no usable output at all.
    private func announceSettledOutputRoute(change: NvstOutputDeviceChange, wasFallback: Bool) {
        if change.isFallback != wasFallback {
            let message = change.isFallback
                ? "Audio output unavailable \u{2014} using \(outputDeviceSelectionLabel)."
                : "Audio output restored."
            showNativeTransientStreamMessage(message)
            return
        }
        guard !change.isOutputUsable else { return }
        showNativeTransientStreamMessage("No audio output device available.")
    }

    /// The saved UID is only rewritten once the device confirms the route activated, so a failed
    /// switch cannot leave the picker claiming a device playback never reached.
    private func resolvePendingOutputDevice(requested: String, change: NvstOutputDeviceChange) {
        outputDeviceUpdateTask?.cancel()
        outputDeviceUpdateTask = nil
        outputDevicePendingUID = nil
        let isRequestedRouteActive = change.resolvedUniqueID == requested && !change.isFallback && change.isRouteActivated
        guard isRequestedRouteActive else {
            showNativeTransientStreamMessage(change.isOutputUsable ? "Could not switch audio output." : "No audio output device available.")
            OPNStreamTelemetry.capture("nvst.ui.output.device.unavailable", level: .warning, message: "Native NVST output device did not activate.", attributes: ["applicationID": configuration.applicationID, "deviceId": requested.isEmpty ? "default" : requested])
            return
        }
        outputDeviceUID = requested
        OPNStreamPreferences.saveOutputDeviceId(requested)
        showNativeTransientStreamMessage(outputDeviceStatusMessage(for: requested))
    }

    private func abandonPendingOutputDevice(message: String) {
        outputDevicePendingUID = nil
        outputDeviceUpdateTask = nil
        showNativeTransientStreamMessage(message)
    }

    /// The picker needs a running session, a choice to make, and no route change already in flight.
    var isOutputDeviceRowDisabled: Bool {
        !isConnected || outputDevicePendingUID != nil || outputDeviceOptions.count <= 1
    }

    private func outputDeviceStatusMessage(for uid: String) -> String {
        guard let option = outputDeviceOptions.first(where: { $0.uniqueId == uid }) else { return "Output Device Changed" }
        return "Audio Output: \(option.label)"
    }

    // MARK: - Settings parity

    /// Re-reads the AUDIO preferences Settings shares, so a change made there is not only visible at
    /// the next launch. Called when the HUD opens.
    func refreshNativeAudioPreferences() {
        let profile = OPNStreamPreferences.loadProfile()
        applySavedAudioLevels(profile)
        adoptSavedOutputDevice(profile.outputDeviceId)
        refreshOutputDeviceOptions()
    }

    private func applySavedAudioLevels(_ profile: OPNStreamPreferenceProfile) {
        let savedGameVolume = Int((profile.gameVolume * 100).rounded())
        if savedGameVolume != gameVolumePercent { updateNativeGameVolume(percent: savedGameVolume) }
        let savedMicrophoneVolume = Int((profile.microphoneVolume * 100).rounded())
        if savedMicrophoneVolume != microphoneVolumePercent { updateNativeMicrophoneVolume(percent: savedMicrophoneVolume) }
    }

    /// Through the same request path as a HUD selection, so the saved UID is only rewritten once the
    /// device confirms the route activated.
    private func adoptSavedOutputDevice(_ savedUID: String) {
        guard savedUID != outputDeviceUID else { return }
        outputDevicePendingUID = nil
        guard isConnected else {
            outputDeviceUID = savedUID
            return
        }
        requestNativeOutputDevice(savedUID)
    }
}
