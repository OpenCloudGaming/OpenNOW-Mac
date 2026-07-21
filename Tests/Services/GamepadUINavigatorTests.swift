import Foundation
import Testing
@testable import MacForceNow

@Suite @MainActor struct GamepadUINavigatorTests {
    private let activeDeviceID = InputDeviceID("steam-controller-test-device")

    private func makeSnapshot(buttons: GamepadButtons = [],
                              leftStickX: Float = 0,
                              leftStickY: Float = 0) -> SteamControllerInputSnapshot {
        SteamControllerInputSnapshot(buttons: buttons, leftStickX: leftStickX, leftStickY: leftStickY)
    }

    private func drive(_ navigator: GamepadUINavigator, snapshots: [SteamControllerInputSnapshot]) {
        let navigatorKey = ObjectIdentifier(navigator)
        SteamControllerHIDMonitor.shared.register(
            navigator,
            onControllersChanged: {},
            onInputState: { _, _ in }
        )
        defer { SteamControllerHIDMonitor.shared.unregister(key: navigatorKey) }

        for snapshot in snapshots {
            navigator.processSnapshot(deviceID: activeDeviceID, snapshot: snapshot, isActiveOverride: true)
        }
    }

    @Test func mapsFaceShoulderAndDpadButtonsToCommands() {
        #expect(GamepadUINavigator.command(for: .dpadUp) == .move(.up))
        #expect(GamepadUINavigator.command(for: .dpadDown) == .move(.down))
        #expect(GamepadUINavigator.command(for: .dpadLeft) == .move(.left))
        #expect(GamepadUINavigator.command(for: .dpadRight) == .move(.right))
        #expect(GamepadUINavigator.command(for: .south) == .confirm)
        #expect(GamepadUINavigator.command(for: .east) == .back)
        #expect(GamepadUINavigator.command(for: .west) == .search)
        #expect(GamepadUINavigator.command(for: .north) == .actions)
        #expect(GamepadUINavigator.command(for: .start) == .menu)
        #expect(GamepadUINavigator.command(for: .select) == .actions)
        #expect(GamepadUINavigator.command(for: .leftShoulder) == .pageLeft)
        #expect(GamepadUINavigator.command(for: .rightShoulder) == .pageRight)
    }

    @Test func ignoresNonNavigableButtons() {
        #expect(GamepadUINavigator.command(for: .leftStick) == nil)
        #expect(GamepadUINavigator.command(for: .rightStick) == nil)
        #expect(GamepadUINavigator.command(for: .leftGrip) == nil)
        #expect(GamepadUINavigator.command(for: .rightGrip) == nil)
        #expect(GamepadUINavigator.command(for: .leftGrip2) == nil)
        #expect(GamepadUINavigator.command(for: .rightGrip2) == nil)
        #expect(GamepadUINavigator.command(for: .mode) == nil)
        #expect(GamepadUINavigator.command(for: .quickAccess) == nil)
    }

    @Test func firesCommandOnceOnButtonPressEdge() {
        let navigator = GamepadUINavigator()
        var captured: [ControllerInputCommand] = []
        navigator.onCommand = { captured.append($0) }
        drive(navigator, snapshots: [
            makeSnapshot(),
            makeSnapshot(buttons: [.south]),
            makeSnapshot(buttons: [.south]),
        ])
        #expect(captured == [.confirm])
    }

    @Test func firesCommandAgainOnReleaseThenPress() {
        let navigator = GamepadUINavigator()
        var captured: [ControllerInputCommand] = []
        navigator.onCommand = { captured.append($0) }
        drive(navigator, snapshots: [
            makeSnapshot(),
            makeSnapshot(buttons: [.south]),
            makeSnapshot(),
            makeSnapshot(buttons: [.south]),
        ])
        #expect(captured == [.confirm, .confirm])
    }

    @Test func mapsMultipleSimultaneousEdgePresses() {
        let navigator = GamepadUINavigator()
        var captured: [ControllerInputCommand] = []
        navigator.onCommand = { captured.append($0) }
        drive(navigator, snapshots: [
            makeSnapshot(),
            makeSnapshot(buttons: [.south, .east, .dpadUp]),
        ])
        #expect(captured == [.move(.up), .confirm, .back])
    }

    @Test func firesMoveImmediatelyOnStickExceedingDeadzone() {
        let navigator = GamepadUINavigator()
        var captured: [ControllerInputCommand] = []
        navigator.onCommand = { captured.append($0) }
        drive(navigator, snapshots: [
            makeSnapshot(leftStickX: 0.95, leftStickY: 0),
        ])
        #expect(captured == [.move(.right)])
    }

    @Test func ignoresStickBelowDeadzone() {
        let navigator = GamepadUINavigator()
        var captured: [ControllerInputCommand] = []
        navigator.onCommand = { captured.append($0) }
        drive(navigator, snapshots: [
            makeSnapshot(leftStickX: 0.10, leftStickY: 0.20),
        ])
        #expect(captured.isEmpty)
    }

    @Test func sticksToDominantAxis() {
        let navigator = GamepadUINavigator()
        var captured: [ControllerInputCommand] = []
        navigator.onCommand = { captured.append($0) }
        drive(navigator, snapshots: [
            makeSnapshot(leftStickX: 0.8, leftStickY: 0.3),
        ])
        #expect(captured == [.move(.right)])
    }

    @Test func emitsStickRepeatAfterInterval() {
        let navigator = GamepadUINavigator()
        var captured: [ControllerInputCommand] = []
        navigator.onCommand = { captured.append($0) }
        drive(navigator, snapshots: [
            makeSnapshot(leftStickX: 0.95, leftStickY: 0),
        ])
        #expect(captured == [.move(.right)])
        captured.removeAll()

        Thread.sleep(forTimeInterval: GamepadUINavigator.thumbstickRepeatInterval + 0.05)
        drive(navigator, snapshots: [
            makeSnapshot(leftStickX: 0.95, leftStickY: 0),
        ])
        #expect(captured == [.move(.right)])
        captured.removeAll()

        drive(navigator, snapshots: [
            makeSnapshot(leftStickX: 0.95, leftStickY: 0),
        ])
        #expect(captured.isEmpty)
    }

    @Test func clearingStickEmptiesRepeatState() {
        let navigator = GamepadUINavigator()
        var captured: [ControllerInputCommand] = []
        navigator.onCommand = { captured.append($0) }
        drive(navigator, snapshots: [
            makeSnapshot(leftStickX: 0.95, leftStickY: 0),
            makeSnapshot(),
            makeSnapshot(leftStickX: 0.95, leftStickY: 0),
        ])
        #expect(captured == [.move(.right), .move(.right)])
    }

    @Test func noCommandWhenDeviceInactive() {
        let navigator = GamepadUINavigator()
        var captured: [ControllerInputCommand] = []
        navigator.onCommand = { captured.append($0) }
        navigator.processSnapshot(deviceID: activeDeviceID, snapshot: makeSnapshot(buttons: [.south]), isActiveOverride: false)
        #expect(captured.isEmpty)
    }

    @Test func multipleSequentialDpadEdgesMapToMoveCommands() {
        let navigator = GamepadUINavigator()
        var captured: [ControllerInputCommand] = []
        navigator.onCommand = { captured.append($0) }
        drive(navigator, snapshots: [
            makeSnapshot(),
            makeSnapshot(buttons: [.dpadRight]),
            makeSnapshot(),
            makeSnapshot(buttons: [.dpadDown]),
            makeSnapshot(),
            makeSnapshot(buttons: [.dpadLeft]),
            makeSnapshot(),
            makeSnapshot(buttons: [.dpadUp]),
        ])
        #expect(captured == [.move(.right), .move(.down), .move(.left), .move(.up)])
    }
}
