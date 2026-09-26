import Foundation

public enum ControllerFamily: String, Codable, CaseIterable, Identifiable, Sendable {
    case steam, generic, dualShock4

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .steam: "Steam Controller"
        case .generic: "Generic Controller"
        case .dualShock4: "DualShock 4"
        }
    }

    public var controls: [ControllerControl] {
        ControllerControl.allCases.filter { control in
            switch control {
            case .leftGrip, .leftGrip2, .rightGrip, .rightGrip2, .leftPadClick, .rightPadClick,
                 .leftGripSense, .rightGripSense, .leftStickTouch, .rightStickTouch, .gyro:
                self == .steam
            case .touchpadClick:
                self == .dualShock4
            default:
                true
            }
        }
    }

    public func label(for control: ControllerControl) -> String {
        if control == .guide {
            switch self {
            case .steam: return "Steam"
            case .generic: return "Guide"
            case .dualShock4: return "PS"
            }
        }
        guard self == .dualShock4 else { return control.label }
        switch control {
        case .faceA: return "×"
        case .faceB: return "○"
        case .faceX: return "□"
        case .faceY: return "△"
        case .select: return "SHARE"
        case .start: return "OPTIONS"
        default: return control.label
        }
    }
}
