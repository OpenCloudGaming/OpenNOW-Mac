import Foundation

extension NativeWebRTCGamepadMonitor {
    func prepareForControllerSlotChange() {
        stopHaptics()
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
