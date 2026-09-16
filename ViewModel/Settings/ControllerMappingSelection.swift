import Foundation

enum ControllerMappingSelection: Equatable {
    case none
    case steamDefaults
    case device(InputDeviceID)

    func resolved(devices: [ControllerMappingDevice]) -> Self {
        guard let first = devices.first else { return .none }
        switch self {
        case .steamDefaults where devices.contains(where: { $0.family == .steam }):
            return .steamDefaults
        case .device(let id) where devices.contains(where: { $0.id == id }):
            return self
        default:
            return .device(first.id)
        }
    }
}
