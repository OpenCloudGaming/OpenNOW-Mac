import Foundation

public struct SteamControllerTrackpadMouseActions: Equatable, Sendable {
    public struct ButtonTransition: Equatable, Sendable {
        public let button: MouseButton
        public let isPressed: Bool

        public init(button: MouseButton, isPressed: Bool) {
            self.button = button
            self.isPressed = isPressed
        }
    }

    public var moveDeltaX: Int16 = 0
    public var moveDeltaY: Int16 = 0
    public var wheelDelta: Int16 = 0
    public var buttonTransitions: [ButtonTransition] = []

    public init() {}

    public var isEmpty: Bool {
        moveDeltaX == 0 && moveDeltaY == 0 && wheelDelta == 0 && buttonTransitions.isEmpty
    }
}

public struct SteamControllerTrackpadMouseTranslator: Sendable {
    public static let pointsPerPadUnit: Float = 700
    public static let wheelUnitsPerPadUnit: Float = 300

    private var previous = SteamControllerInputSnapshot()
    private var moveRemainderX: Float = 0
    private var moveRemainderY: Float = 0
    private var wheelRemainder: Float = 0

    public init() {}

    public mutating func translate(_ snapshot: SteamControllerInputSnapshot) -> SteamControllerTrackpadMouseActions {
        var actions = SteamControllerTrackpadMouseActions()

        if snapshot.rightPad.touched, previous.rightPad.touched {
            let scaledX = (snapshot.rightPad.x - previous.rightPad.x) * Self.pointsPerPadUnit + moveRemainderX
            let scaledY = -(snapshot.rightPad.y - previous.rightPad.y) * Self.pointsPerPadUnit + moveRemainderY
            let wholeX = scaledX.rounded(.towardZero)
            let wholeY = scaledY.rounded(.towardZero)
            moveRemainderX = scaledX - wholeX
            moveRemainderY = scaledY - wholeY
            actions.moveDeltaX = Self.clampedInt16(wholeX)
            actions.moveDeltaY = Self.clampedInt16(wholeY)
        } else {
            moveRemainderX = 0
            moveRemainderY = 0
        }

        if snapshot.leftPad.touched, previous.leftPad.touched {
            let scaledWheel = (snapshot.leftPad.y - previous.leftPad.y) * Self.wheelUnitsPerPadUnit + wheelRemainder
            let wholeWheel = scaledWheel.rounded(.towardZero)
            wheelRemainder = scaledWheel - wholeWheel
            actions.wheelDelta = Self.clampedInt16(wholeWheel)
        } else {
            wheelRemainder = 0
        }

        if snapshot.rightPad.pressed != previous.rightPad.pressed {
            actions.buttonTransitions.append(SteamControllerTrackpadMouseActions.ButtonTransition(button: .left, isPressed: snapshot.rightPad.pressed))
        }
        if snapshot.leftPad.pressed != previous.leftPad.pressed {
            actions.buttonTransitions.append(SteamControllerTrackpadMouseActions.ButtonTransition(button: .middle, isPressed: snapshot.leftPad.pressed))
        }

        previous = snapshot
        return actions
    }

    private static func clampedInt16(_ value: Float) -> Int16 {
        Int16(max(Float(Int16.min), min(Float(Int16.max), value)))
    }
}
