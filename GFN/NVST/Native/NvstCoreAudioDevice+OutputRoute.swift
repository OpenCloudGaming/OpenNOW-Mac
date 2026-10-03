import CoreAudio
import Foundation

/// The output route's own half of the device: resolving the picker's saved UID, rebuilding only the
/// playout unit when it changes, and reporting the route playback is really on. Split from the class
/// body, which is at its length budget; the state it reads is module-internal for that reason.
extension NvstCoreAudioDevice {
    /// The system default output changed. Only a "Default Device" selection follows it: a pinned
    /// device is exactly the case where the session must not be disturbed.
    func handleDefaultOutputDeviceChange() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            guard preferredOutputDeviceUID == nil else { return }
            let wasPlaying = isPlayoutRunning
            stopPlayout()
            disposePlayoutUnit()
            rebuildCapture()
            let activated = wasPlaying ? startPlayout() : true
            notifyOutputDeviceChange(didActivateRoute: activated)
        }
    }

    /// A plug or unplug on the output side, or a device appearing that the saved choice names.
    /// Debounced for the same reason the input side is: one physical event fires several
    /// notifications and each rebuild disposes and recreates an AudioUnit.
    func handleOutputDeviceEnvironmentChange() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            outputDeviceChangeWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                outputDeviceChangeWorkItem = nil
                outputDeviceEvaluationCount += 1
                // A device that was plugged in is a row the picker should have, even when it is not
                // the one playback is on, so this is announced before the resolved-device check.
                onOutputDeviceListChange?()
                let resolved = OPNCoreAudioDeviceLookup.outputDevice(matching: preferredOutputDeviceUID)
                guard resolved != outputDevice else {
                    updateDeviceParameters()
                    return
                }
                let wasPlaying = isPlayoutRunning
                stopPlayout()
                disposePlayoutUnit()
                updateDeviceParameters()
                let activated = wasPlaying ? startPlayout() : true
                notifyOutputDeviceChange(didActivateRoute: activated)
            }
            outputDeviceChangeWorkItem = item
            audioQueue.asyncAfter(deadline: .now() + Self.outputDeviceChangeDebounce, execute: item)
        }
    }

    /// The output picker's UID, applied to the running session. Only the playout unit is torn down:
    /// the receive pipeline, its SSRC and the seat's stream were fixed at ANNOUNCE.
    public func setPreferredOutputDevice(uid: String?) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            let normalizedUID = uid.flatMap { $0.isEmpty ? nil : $0 }
            let previousDevice = outputDevice
            preferredOutputDeviceUID = normalizedUID
            guard OPNCoreAudioDeviceLookup.outputDevice(matching: normalizedUID) != previousDevice else {
                // Same device: re-read the parameters the HUD's fallback label is drawn from,
                // without tearing down an AudioUnit for a no-op.
                updateDeviceParameters()
                notifyOutputDeviceChange()
                return
            }
            let wasPlaying = isPlayoutRunning
            stopPlayout()
            disposePlayoutUnit()
            outputDeviceRebuildCount += 1
            updateDeviceParameters()
            let activated = wasPlaying ? startPlayout() : true
            notifyOutputDeviceChange(didActivateRoute: activated)
        }
    }

    /// The route playback is on, whether that is a fallback, and whether any output is usable.
    /// Reads the published snapshot, never `audioQueue.sync`.
    public var outputDeviceState: (uniqueID: String?, isFallback: Bool, hasUsableOutput: Bool) {
        outputStateLock.lock()
        defer { outputStateLock.unlock() }
        return publishedOutputDeviceState
    }

    /// Test seam: debounced output evaluations that ran, and how many rebuilt the route.
    var outputDeviceRebuildEvidence: (evaluations: Int, rebuilds: Int) {
        audioQueue.sync { (outputDeviceEvaluationCount, outputDeviceRebuildCount) }
    }

    func notifyOutputDeviceChange(didActivateRoute: Bool = true) {
        onOutputDeviceChange?(NvstOutputDeviceChange(resolvedUniqueID: outputDeviceUniqueID,
                                                     preferredUniqueID: preferredOutputDeviceUID,
                                                     isFallback: isUsingFallbackOutputDevice,
                                                     hasUsableOutput: outputDevice != AudioDeviceID(kAudioObjectUnknown),
                                                     didActivateRoute: didActivateRoute))
    }
}
