import Foundation

/// One rendered row of the controller panel, built from either the app-wide order (Settings) or a
/// stream's selection (the HUD), so the panel itself stays a renderer with no knowledge of which one
/// it is showing.
struct ControllerOrderRow: Identifiable, Equatable {
    let id: InputDeviceID
    let name: String
    /// The effective slot, never the position in the shared order.
    let slotLabel: String
    let detail: String
    /// The remembered choice, including for a disconnected row, where the toggle is read-only.
    let isEnabled: Bool
    let showsEnableToggle: Bool
    let isDimmed: Bool
}

/// The two ways the controller panel's rows are built. Kept out of the view so the strings a player
/// actually reads — and the state each one is derived from — are covered without rendering.
enum ControllerOrderRows {
    /// The app-wide order on its own, as the Settings surface shows it: nothing is per-stream here,
    /// so every connected device is enabled and its slot is its position in the order.
    static func order(_ devices: [ControllerMappingDevice]) -> [ControllerOrderRow] {
        devices.enumerated().map { index, device in
            let isActive = index < ControllerPlayerOrder.maximumPlayers
            return ControllerOrderRow(id: device.id, name: device.name,
                                      slotLabel: isActive ? "PLAYER \(index + 1)" : "WAITING",
                                      detail: isActive ? device.family.label : "Move into the first four to use in the stream",
                                      isEnabled: true, showsEnableToggle: false, isDimmed: false)
        }
    }

    /// A stream's selection: the effective player each enabled device occupies, then the remembered
    /// rows for whatever is disabled, waiting or gone. `families` supplies the type label for the
    /// devices the registry still knows about; a disconnected row keeps only its remembered name.
    static func stream(_ rows: [ControllerStreamSelection.Row], families: [InputDeviceID: ControllerFamily]) -> [ControllerOrderRow] {
        rows.map { row in
            ControllerOrderRow(id: row.id, name: row.name,
                               slotLabel: slotLabel(for: row.state),
                               detail: detail(for: row.state, family: families[row.id]),
                               isEnabled: row.isEnabled,
                               showsEnableToggle: row.state != .disconnected,
                               isDimmed: row.state == .disconnected)
        }
    }

    static func slotLabel(for state: ControllerStreamSelection.RowState) -> String {
        switch state {
        case .active(let playerIndex): "PLAYER \(playerIndex + 1)"
        case .waiting: "WAITING"
        case .disabled: "OFF"
        case .newlyIdentified: "NEW"
        case .disconnected: "OFFLINE"
        }
    }

    static func detail(for state: ControllerStreamSelection.RowState, family: ControllerFamily?) -> String {
        switch state {
        case .active: family?.label ?? "Controller"
        case .waiting: "Waiting — four players already active"
        case .disabled: "Disabled in this stream"
        case .newlyIdentified: "New controller — enable in this stream"
        case .disconnected: "Disconnected — remembered for this session"
        }
    }
}
