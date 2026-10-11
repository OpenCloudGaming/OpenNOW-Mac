import Foundation

/// The stream-local half of the controller panel: the monitor that owns this session's admission,
/// narrowed to the two operations the HUD's sheet needs so its toggles edit this stream only.
/// A stream whose surface has not resolved has no context, so the panel shows the app-wide order.
@MainActor
struct StreamControllerSelectionContext {
    let monitor: NativeGamepadMonitor

    var rows: [ControllerStreamSelection.Row] { monitor.streamControllerRows }

    func setEnabled(_ isEnabled: Bool, for deviceID: InputDeviceID) {
        monitor.setStreamEnabled(isEnabled, for: deviceID)
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
