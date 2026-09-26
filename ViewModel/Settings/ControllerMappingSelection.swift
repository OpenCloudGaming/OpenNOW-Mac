import Foundation

/// What the mapping sheet is currently editing. Bounded to controller *types*, not physical pads:
/// resolution is keyed on (type × game), so there is nothing per-device to point at.
enum ControllerMappingSelection: Equatable {
    case none
    case family(ControllerFamily)

    /// Any family can be edited while a pad is connected — choosing the DualShock 4 tab with only a
    /// Steam Controller plugged in has to work, or a type's default could never be prepared ahead
    /// of the pad arriving. With nothing connected there is no live diagram to draw, so the sheet
    /// shows its disconnected message.
    func resolved(devices: [ControllerMappingDevice]) -> Self {
        guard let first = devices.first else { return .none }
        if case .family = self { return self }
        return .family(first.family)
    }
}
