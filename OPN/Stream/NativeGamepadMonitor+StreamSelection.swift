import Foundation

/// One stream's controller admission: the HUD's rows, the toggle that edits them, and the haptic
/// release that follows a device losing its slot.
///
/// Kept in its own extension so the per-stream feature does not grow `NativeGamepadMonitor`'s own
/// body past the repository's size budget; the storage still lives with the monitor that owns it.
extension NativeGamepadMonitor {
    /// The HUD's rows for this stream: effective player per enabled device, plus the remembered
    /// rows for whatever is disabled, waiting or gone.
    var streamControllerRows: [ControllerStreamSelection.Row] { streamSelection.rows }

    /// Enables or disables one device for this stream only. The slot map, topology, mapped outputs
    /// and rumble routing are all recomputed by the refresh, which neutralizes the old slot before
    /// it publishes the replacement.
    @discardableResult
    func setStreamEnabled(_ enabled: Bool, for deviceID: InputDeviceID) -> Bool {
        guard streamSelection.setEnabled(enabled, for: deviceID) else { return false }
        OPNStreamTelemetry.capture("webrtc.input.gamepad.stream_selection", level: .info,
                                   message: "Controller enablement changed for this stream.",
                                   attributes: ["device": deviceID.rawValue, "enabled": String(enabled)])
        refreshControllerSlots()
        return true
    }

    /// Releases haptics only for the devices this stream no longer routes. A device disabled here
    /// must stop vibrating for this stream without stopping an unrelated device's rumble, and
    /// without reaching into another stream's monitor — which owns its own haptic state and its own
    /// pending stops for the same physical hardware.
    func stopHaptics(keepingSteamSlots: [InputDeviceID: Int], keepingControllerSlots: [ObjectIdentifier: Int]) {
        for key in Array(hapticStates.keys) where keepingControllerSlots[key] == nil {
            hapticStates[key]?.stop()
            hapticStates.removeValue(forKey: key)
        }
        for deviceID in Array(steamRumbleStopTasks.keys) where keepingSteamSlots[deviceID] == nil {
            steamRumbleStopTasks.removeValue(forKey: deviceID)?.cancel()
            SteamControllerHIDMonitor.shared.sendRumble(deviceID: deviceID, leftAmplitude: 0, rightAmplitude: 0)
        }
    }
}
