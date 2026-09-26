import Foundation

/// What the mapping sheet edits. Bounded to controller types: resolution is keyed on type × game.
enum ControllerMappingSelection: Equatable {
    case none
    case family(ControllerFamily)

    /// Any family is editable while a pad is connected, so a type's default can be prepared before
    /// that pad arrives; with nothing connected the sheet shows its disconnected message instead.
    func resolved(devices: [ControllerMappingDevice]) -> Self {
        guard let firstDevice = devices.first else { return .none }
        guard case .family = self else { return .family(firstDevice.family) }
        return self
    }
}
