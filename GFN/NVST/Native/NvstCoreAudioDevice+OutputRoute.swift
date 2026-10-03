import CoreAudio
import Foundation

/// The output route's own half of the device, split from the class body's length budget.
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
            notifyOutputDeviceChange(isRouteActivated: activated)
        }
    }

    /// A plug or unplug on the output side, debounced because one physical event fires several
    /// notifications and each rebuild recreates an AudioUnit.
    func handleOutputDeviceEnvironmentChange() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            outputDeviceChangeWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                outputDeviceChangeWorkItem = nil
                outputDeviceEvaluationCount += 1
                // Announced before the resolved-device check: a plugged-in device is a new row even
                // when playback is not moving to it.
                onOutputDeviceListChange?()
                let resolved = OPNCoreAudioDeviceLookup.resolvedOutputDevice(matching: preferredOutputDeviceUID)
                guard resolved != outputDevice else {
                    updateDeviceParameters()
                    return
                }
                let wasPlaying = isPlayoutRunning
                stopPlayout()
                disposePlayoutUnit()
                updateDeviceParameters()
                let activated = wasPlaying ? startPlayout() : true
                notifyOutputDeviceChange(isRouteActivated: activated)
            }
            outputDeviceChangeWorkItem = item
            audioQueue.asyncAfter(deadline: .now() + Self.outputDeviceChangeDebounce, execute: item)
        }
    }

    /// Only the playout unit is rebuilt: the receive pipeline and the seat's stream are fixed.
    public func setPreferredOutputDevice(uid: String?) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            let normalizedUID = uid.flatMap { $0.isEmpty ? nil : $0 }
            let previousDevice = outputDevice
            preferredOutputDeviceUID = normalizedUID
            guard OPNCoreAudioDeviceLookup.resolvedOutputDevice(matching: normalizedUID) != previousDevice else {
                // Same device: re-read the fallback label's parameters, no AudioUnit teardown.
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
            notifyOutputDeviceChange(isRouteActivated: activated)
        }
    }

    /// Reads the published snapshot, never `audioQueue.sync`, so diagnostics cannot wedge it.
    public var outputDeviceState: (uniqueID: String?, isFallback: Bool, isOutputUsable: Bool) {
        outputStateLock.lock()
        defer { outputStateLock.unlock() }
        return publishedOutputDeviceState
    }

    /// Test seam: debounced output evaluations that ran, and how many rebuilt the route.
    var outputDeviceRebuildEvidence: (evaluations: Int, rebuilds: Int) {
        audioQueue.sync { (outputDeviceEvaluationCount, outputDeviceRebuildCount) }
    }

    func notifyOutputDeviceChange(isRouteActivated: Bool = true) {
        onOutputDeviceChange?(NvstOutputDeviceChange(resolvedUniqueID: outputDeviceUniqueID,
                                                     preferredUniqueID: preferredOutputDeviceUID,
                                                     isFallback: isUsingFallbackOutputDevice,
                                                     isOutputUsable: outputDevice != AudioDeviceID(kAudioObjectUnknown),
                                                     isRouteActivated: isRouteActivated))
    }
}
