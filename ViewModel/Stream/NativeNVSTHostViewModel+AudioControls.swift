//  The stream HUD's AUDIO panel commands: the output device picker, the local game gain, and the
//  microphone gain. All three share one rule — the HUD writes the same stream preference Settings
//  writes, and applies the change to the running session where the transport supports it.
//
//  AppKit is imported for the same reason as the other `+` files on this model: the push-to-talk
//  monitor is reconfigured on a mode change, and `NativeStreamView` is the surface it lives on.
//
//  swiftlint:disable:next no_appkit_in_view_model
import AppKit
import Foundation

@MainActor
extension NativeNVSTHostViewModel {
    /// One controller press moves a volume by this much, wrapping to silence past full. Coarse
    /// enough to cross the range in ten presses, which is what a pad-only user can tolerate.
    static let volumeStepPercent = 10

    /// The mute icon's own state. The override wins over everything else — an override-muted
    /// microphone shows muted even while the push-to-talk key is held, and even though capture is
    /// what the key would otherwise open.
    var isNativeMicrophoneMuted: Bool {
        !microphoneAvailable || microphoneMuteOverride
    }

    /// The AUDIO panel's microphone status line. It lives here rather than on the view so the
    /// composed state is readable and testable without a rendered surface.
    var microphoneStatusText: String {
        guard microphoneAvailable else { return "Disabled" }
        // The override outranks the key state: a held key with the override on is still muted, and
        // saying "PTT Active" there would describe a transmission that is not happening.
        if microphoneMuteOverride { return "Muted" }
        if microphoneMode == "push-to-talk" { return microphoneEnabled ? "PTT Active" : "PTT Ready" }
        if microphoneMode == "voice-activity", microphoneEnabled { return "Voice Activity" }
        return microphoneEnabled ? "On" : "Muted"
    }

    /// The captions the panel shows for the focused volume row and its mute icon, so a pad user has
    /// the same words a hover tooltip would give a mouse user.
    var gameVolumeCaption: String { "Game Volume \u{00b7} \(gameVolumePercent)%" }
    var gameVolumeMuteCaption: String { nativeLocalAudioMuted ? "Unmute Local Audio" : "Mute Local Audio" }
    var microphoneVolumeCaption: String { "Microphone Volume \u{00b7} \(microphoneVolumePercent)%" }
    var microphoneVolumeMuteCaption: String { isNativeMicrophoneMuted ? "Unmute Microphone" : "Mute Microphone" }

    // MARK: - Local game volume

    /// The local playback gain, applied after the game-audio tee. 0% is silent and 100% is the
    /// decoded samples untouched; nothing above unity is reachable.
    func updateNativeGameVolume(percent: Int) {
        let clamped = min(max(percent, 0), 100)
        gameVolumePercent = clamped
        OPNStreamPreferences.saveGameVolume(Double(clamped) / 100)
        guard let path else { return }
        Task { @MainActor in
            do {
                try await path.setGameVolume(Double(clamped) / 100)
            } catch {
                guard !Task.isCancelled, !didEnd else { return }
                showNativeTransientStreamMessage(Self.message(for: error))
            }
        }
        OPNStreamTelemetry.capture("nvst.ui.game.volume", level: .info, message: "Native NVST local game volume changed.", attributes: ["applicationID": configuration.applicationID, "percent": String(clamped)])
    }

    /// Controller/keyboard step through the HUD row: +10% per press, wrapping to silence.
    func cycleNativeGameVolume() {
        let next = gameVolumePercent + Self.volumeStepPercent
        updateNativeGameVolume(percent: next > 100 ? 0 : next)
    }

    // MARK: - Microphone volume

    /// The capture gain for the current session. Separate from the mute override and from the mode:
    /// moving this slider never opens or closes the gate, and never clears the override.
    func updateNativeMicrophoneVolume(percent: Int) {
        let clamped = min(max(percent, 0), 100)
        microphoneVolumePercent = clamped
        OPNStreamPreferences.saveMicrophoneVolume(Double(clamped) / 100)
        guard let path else { return }
        Task { @MainActor in
            do {
                try await path.setMicrophoneVolume(Double(clamped) / 100)
            } catch {
                guard !Task.isCancelled, !didEnd else { return }
                showNativeTransientStreamMessage(Self.message(for: error))
            }
        }
        OPNStreamTelemetry.capture("nvst.ui.microphone.volume", level: .info, message: "Native NVST microphone volume changed.", attributes: ["applicationID": configuration.applicationID, "percent": String(clamped)])
    }

    func cycleNativeMicrophoneVolume() {
        let next = microphoneVolumePercent + Self.volumeStepPercent
        updateNativeMicrophoneVolume(percent: next > 100 ? 0 : next)
    }

    // MARK: - Output device

    /// Applies an output picker choice to the running session. The saved UID is only rewritten once
    /// the device reports that the route actually activated, so a failed switch cannot leave the
    /// picker claiming a device playback never reached.
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
                outputDevicePendingUID = nil
                outputDeviceUpdateTask = nil
                let message = Self.message(for: error)
                showNativeTransientStreamMessage(message)
                OPNStreamTelemetry.capture("nvst.ui.output.device.failed", level: .error, message: message, attributes: ["applicationID": configuration.applicationID])
                return
            }
            // A route the device never reports back on must not leave the picker stuck on
            // "switching": the report is the authority, but it is not guaranteed to arrive when the
            // session has no audio device at all.
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, outputDevicePendingUID == uid else { return }
            outputDevicePendingUID = nil
            outputDeviceUpdateTask = nil
            showNativeTransientStreamMessage("Could not switch audio output.")
        }
        OPNStreamTelemetry.capture("nvst.ui.output.device", level: .info, message: "Native NVST output device requested.", attributes: ["applicationID": configuration.applicationID, "deviceId": uid.isEmpty ? "default" : uid])
    }

    /// The device's own report: every route change, every fallback, and every switch that failed to
    /// activate. It is the authority on which route is really in use.
    func handleNativeOutputDeviceChange(_ change: NvstOutputDeviceChange) {
        guard !didEnd else { return }
        let wasFallback = isOutputDeviceFallbackActive
        refreshOutputDeviceOptions()
        isOutputDeviceFallbackActive = change.isFallback
        outputDeviceResolvedUID = change.resolvedUniqueID ?? ""
        guard let requested = outputDevicePendingUID else {
            if change.isFallback, !wasFallback {
                showNativeTransientStreamMessage("Audio output unavailable \u{2014} using \(outputDeviceSelectionLabel).")
            } else if wasFallback, !change.isFallback {
                showNativeTransientStreamMessage("Audio output restored.")
            } else if !change.hasUsableOutput {
                showNativeTransientStreamMessage("No audio output device available.")
            }
            return
        }
        outputDeviceUpdateTask?.cancel()
        outputDeviceUpdateTask = nil
        outputDevicePendingUID = nil
        let didReachRequestedRoute = change.resolvedUniqueID == requested && !change.isFallback && change.didActivateRoute
        guard didReachRequestedRoute else {
            showNativeTransientStreamMessage(change.hasUsableOutput ? "Could not switch audio output." : "No audio output device available.")
            OPNStreamTelemetry.capture("nvst.ui.output.device.unavailable", level: .warning, message: "Native NVST output device did not activate.", attributes: ["applicationID": configuration.applicationID, "deviceId": requested.isEmpty ? "default" : requested])
            return
        }
        outputDeviceUID = requested
        OPNStreamPreferences.saveOutputDeviceId(requested)
        showNativeTransientStreamMessage(outputDeviceStatusMessage(for: requested))
    }

    /// Re-reads the output rows, so an output device plugged in mid-stream becomes a row.
    func reloadOutputDeviceOptions() {
        outputDeviceOptions = OPNStreamPreferences.loadOutputDeviceOptions()
    }

    func refreshOutputDeviceOptions() {
        reloadOutputDeviceOptions()
        resolveOutputDeviceFallback()
    }

    /// Whether the saved output is still one of the rows present. The saved UID is never rewritten
    /// here: a fallback is a resolution result, and the device is expected back.
    func resolveOutputDeviceFallback() {
        let savedUID = outputDeviceUID.isEmpty ? OPNStreamPreferences.loadProfile().outputDeviceId : outputDeviceUID
        isOutputDeviceFallbackActive = !savedUID.isEmpty
            && !outputDeviceOptions.contains { $0.uniqueId == savedUID }
    }

    /// The trigger's label: the device in use, named as the picker names it. A missing saved device
    /// resolves to no row, so this reads "Default Device" and the suffix says it is a fallback.
    var outputDeviceSelectionLabel: String {
        let label = outputDeviceOptions.first { $0.uniqueId == selectedOutputDeviceUID }?.label ?? "Default Device"
        return isOutputDeviceFallbackActive ? "\(label) (fallback)" : label
    }

    var outputDeviceCaption: String {
        "Output Device \u{00b7} \(outputDeviceSelectionLabel)"
    }

    /// Whether the output picker can be used: a session has to be running, and no route change may
    /// already be in flight behind the same transport call.
    var isOutputDeviceRowDisabled: Bool {
        !isConnected || outputDevicePendingUID != nil || outputDeviceOptions.count <= 1
    }

    private func outputDeviceStatusMessage(for uid: String) -> String {
        guard let option = outputDeviceOptions.first(where: { $0.uniqueId == uid }) else { return "Output Device Changed" }
        return "Audio Output: \(option.label)"
    }

    // MARK: - Settings parity

    /// Re-reads the three AUDIO preferences the HUD and Settings share. Called when the HUD opens so
    /// a change made in Settings during the session is reflected rather than only at the next launch.
    func refreshNativeAudioPreferences() {
        let profile = OPNStreamPreferences.loadProfile()
        let savedGameVolume = Int((profile.gameVolume * 100).rounded())
        let savedMicrophoneVolume = Int((profile.microphoneVolume * 100).rounded())
        if savedGameVolume != gameVolumePercent { updateNativeGameVolume(percent: savedGameVolume) }
        if savedMicrophoneVolume != microphoneVolumePercent { updateNativeMicrophoneVolume(percent: savedMicrophoneVolume) }
        if profile.outputDeviceId != outputDeviceUID {
            outputDevicePendingUID = nil
            // Through the same request path as a HUD selection, so the saved UID is only rewritten
            // once the device confirms the route activated.
            if isConnected {
                requestNativeOutputDevice(profile.outputDeviceId)
            } else {
                outputDeviceUID = profile.outputDeviceId
            }
        }
        refreshOutputDeviceOptions()
    }
}
