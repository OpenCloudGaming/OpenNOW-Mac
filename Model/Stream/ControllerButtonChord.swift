import Foundation

public struct ControllerButtonChord: Codable, Equatable, Sendable {
    public var buttons: GamepadButtons
    public var leftTrigger: Bool
    public var rightTrigger: Bool

    public init(buttons: GamepadButtons = [], leftTrigger: Bool = false, rightTrigger: Bool = false) {
        self.buttons = buttons.intersection(ControllerChordTarget.assignableButtons)
        self.leftTrigger = leftTrigger
        self.rightTrigger = rightTrigger
    }

    public var isEmpty: Bool {
        buttons.isEmpty && !leftTrigger && !rightTrigger
    }

    public func contains(_ element: ControllerChordElement) -> Bool {
        switch element {
        case .button(let button): buttons.contains(button)
        case .leftTrigger: leftTrigger
        case .rightTrigger: rightTrigger
        }
    }

    public mutating func toggle(_ element: ControllerChordElement) {
        switch element {
        case .button(let button):
            guard buttons.contains(button) else {
                buttons.formUnion(button)
                return
            }
            buttons.remove(button)
        case .leftTrigger:
            leftTrigger.toggle()
        case .rightTrigger:
            rightTrigger.toggle()
        }
    }
}

public enum ControllerChordElement: Equatable, Sendable {
    case button(GamepadButtons)
    case leftTrigger
    case rightTrigger
}

public struct ControllerChordTarget: Equatable, Identifiable, Sendable {
    public let label: String
    public let element: ControllerChordElement

    public var id: String { label }

    public static let all: [ControllerChordTarget] = [
        ControllerChordTarget(label: "A", element: .button(.south)),
        ControllerChordTarget(label: "B", element: .button(.east)),
        ControllerChordTarget(label: "X", element: .button(.west)),
        ControllerChordTarget(label: "Y", element: .button(.north)),
        ControllerChordTarget(label: "L1", element: .button(.leftShoulder)),
        ControllerChordTarget(label: "R1", element: .button(.rightShoulder)),
        ControllerChordTarget(label: "L2", element: .leftTrigger),
        ControllerChordTarget(label: "R2", element: .rightTrigger),
        ControllerChordTarget(label: "L3", element: .button(.leftStick)),
        ControllerChordTarget(label: "R3", element: .button(.rightStick)),
        ControllerChordTarget(label: "D-Up", element: .button(.dpadUp)),
        ControllerChordTarget(label: "D-Down", element: .button(.dpadDown)),
        ControllerChordTarget(label: "D-Left", element: .button(.dpadLeft)),
        ControllerChordTarget(label: "D-Right", element: .button(.dpadRight)),
        ControllerChordTarget(label: "Start", element: .button(.start)),
        ControllerChordTarget(label: "Select", element: .button(.select)),
    ]

    public static let assignableButtons: GamepadButtons = all.reduce(into: []) { result, target in
        if case .button(let button) = target.element {
            result.formUnion(button)
        }
    }

    public static func comboLabel(for combo: ControllerButtonChord) -> String {
        let parts = all.filter { combo.contains($0.element) }.map(\.label)
        return parts.isEmpty ? "Unassigned" : parts.joined(separator: " + ")
    }
}

