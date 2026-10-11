import Foundation

/// The stream-local half of the controller panel: the monitor that owns this session's admission
/// decision, handed to the HUD's controller sheet so its toggles edit *this* stream only.
///
/// Deliberately a thin handle rather than a second copy of the state. The monitor is the owner, the
/// panel only reads its rows and asks for a change; a stream that has not resolved its surface yet
/// has no context and the panel falls back to the app-wide order-only presentation.
@MainActor
struct StreamControllerSelectionContext {
    let monitor: NativeGamepadMonitor

    var rows: [ControllerStreamSelection.Row] { monitor.streamControllerRows }

    func setEnabled(_ enabled: Bool, for deviceID: InputDeviceID) {
        monitor.setStreamEnabled(enabled, for: deviceID)
    }
}

@MainActor
extension NativeNVSTHostViewModel {
    /// Nil until the surface resolves — the panel then behaves exactly as it does in Settings.
    var streamControllerSelection: StreamControllerSelectionContext? {
        guard let nativeView else { return nil }
        return StreamControllerSelectionContext(monitor: nativeView.gamepadMonitor)
    }
}
