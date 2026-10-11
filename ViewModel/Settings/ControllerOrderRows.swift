import Foundation

/// One rendered row of the controller panel, built from either the app-wide order (Settings) or a
/// stream's selection (the HUD), so the panel itself stays a renderer.
struct ControllerOrderRow: Identifiable, Equatable {
    let id: InputDeviceID
    let name: String
    /// The effective slot, never the position in the shared order.
    let slotLabel: String
    let statusDetail: String
    /// The remembered choice, read-only once the device is disconnected.
    let isEnabled: Bool
    let isEnableToggleShown: Bool
    let isDimmed: Bool
}

/// The two ways the controller panel's rows are built. Kept out of the view so the strings a player
/// reads, and the state each is derived from, are covered without rendering.
enum ControllerOrderRows {
    /// The app-wide order alone: nothing here is per-stream, so every connected device is enabled and
    /// its slot is simply its position.
    static func order(_ devices: [ControllerMappingDevice]) -> [ControllerOrderRow] {
        devices.enumerated().map { index, device in
            let isActive = index < ControllerPlayerOrder.maximumPlayers
            return ControllerOrderRow(id: device.id, name: device.name,
                                      slotLabel: isActive ? "PLAYER \(index + 1)" : "WAITING",
                                      statusDetail: isActive ? device.family.label : "Move into the first four to use in the stream",
                                      isEnabled: true, isEnableToggleShown: false, isDimmed: false)
        }
    }

    /// A stream's selection: the effective player each enabled device occupies, then the remembered
    /// rows for whatever is disabled, waiting or gone. A disconnected row keeps its remembered name.
    static func stream(_ rows: [ControllerStreamSelection.Row], families: [InputDeviceID: ControllerFamily]) -> [ControllerOrderRow] {
        rows.map { row in
            ControllerOrderRow(id: row.id, name: row.name,
                               slotLabel: slotLabel(for: row.state),
                               statusDetail: statusDetail(for: row.state, family: families[row.id]),
                               isEnabled: row.isEnabled,
                               isEnableToggleShown: row.state != .disconnected,
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

    static func statusDetail(for state: ControllerStreamSelection.RowState, family: ControllerFamily?) -> String {
        switch state {
        case .active: family?.label ?? "Controller"
        case .waiting: "Waiting — four players already active"
        case .disabled: "Disabled in this stream"
        case .newlyIdentified: "New controller — enable in this stream"
        case .disconnected: "Disconnected — remembered for this session"
        }
    }
}
