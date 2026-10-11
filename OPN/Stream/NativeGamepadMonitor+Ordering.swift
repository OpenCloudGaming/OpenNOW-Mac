import Foundation

extension NativeGamepadMonitor {
    func emitCurrentSteamStates() {
        for (id, slot) in pollState.steamControllerSlots.sorted(by: { $0.value < $1.value }) {
            guard let snapshot = SteamControllerHIDMonitor.shared.snapshot(for: id) else { continue }
            processSteamSnapshot(deviceID: id, playerIndex: slot, snapshot: snapshot)
        }
    }
}
