import Foundation

extension NativeGamepadMonitor {
    /// Every haptic this monitor owns, released together. Teardown and a wholesale slot reset want
    /// this; a per-stream disable wants the narrowed form below so it cannot take another stream's
    /// contribution with it.
    public func stopHaptics() {
        hapticStates.values.forEach { $0.stop() }
        hapticStates.removeAll()
        for (deviceID, task) in steamRumbleStopTasks {
            task.cancel()
            SteamControllerHIDMonitor.shared.sendRumble(deviceID: deviceID, leftAmplitude: 0, rightAmplitude: 0)
        }
        steamRumbleStopTasks.removeAll()
    }

    /// Neutralizes the slots that are going away, then releases their owned mapped outputs, before
    /// the replacement slot map is published.
    ///
    /// `keepingSteamSlots`/`keepingControllerSlots` are the *new* maps: when the caller has them, the
    /// haptic release is narrowed to the devices that actually lost their slot, so disabling one
    /// controller in this stream cannot stop an unrelated pad's rumble. Passing neither keeps the
    /// teardown behaviour of stopping every haptic this monitor owns.
    func prepareForControllerSlotChange(keepingSteamSlots: [InputDeviceID: Int]? = nil,
                                       keepingControllerSlots: [ObjectIdentifier: Int]? = nil) {
        if let keepingSteamSlots, let keepingControllerSlots {
            stopHaptics(keepingSteamSlots: keepingSteamSlots, keepingControllerSlots: keepingControllerSlots)
        } else {
            stopHaptics()
        }
        reapplyTasks.values.forEach { $0.cancel() }
        reapplyTasks.removeAll()
        let releases = pollingQueue.sync { pollState.prepareForSlotChange() }
        for event in releases { emitInputEvent(event) }
        for (id, slot) in pollState.steamControllerSlots.sorted(by: { $0.value < $1.value }) {
            if bindingEngines[id] != nil {
                releaseSteamBinding(deviceID: id, playerIndex: slot)
            } else {
                emitInputEvent(.gamepad(GamepadState(deviceID: id, playerIndex: slot,
                                                    timestamp: MediaTimestamp(nanoseconds: DispatchTime.now().uptimeNanoseconds))))
            }
        }
    }

    func emitCurrentSteamStates() {
        for (id, slot) in pollState.steamControllerSlots.sorted(by: { $0.value < $1.value }) {
            guard let snapshot = SteamControllerHIDMonitor.shared.snapshot(for: id) else { continue }
            processSteamSnapshot(deviceID: id, playerIndex: slot, snapshot: snapshot)
        }
    }
}
