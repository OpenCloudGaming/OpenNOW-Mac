import Foundation
import Testing
@testable import OpenNOW

private let device: InputDeviceID = "test-controller"
private let otherDevice: InputDeviceID = "other-controller"

@Suite struct StreamOSKChordTrackerTests {
    @Test func quickAccessPressTogglesUnifiedHUDImmediately() {
        var tracker = StreamOSKChordTracker()
        let press = tracker.process(buttons: [.quickAccess], deviceID: device)
        #expect(press.command == .toggleUnifiedHUD)
        #expect(!press.buttons.contains(.quickAccess))
        let held = tracker.process(buttons: [.quickAccess], deviceID: device)
        #expect(held.command == nil)
        let release = tracker.process(buttons: [], deviceID: device)
        #expect(release.command == nil)
    }

    @Test func steamButtonAloneFiresNothingAndIsNotStripped() {
        var tracker = StreamOSKChordTracker()
        let press = tracker.process(buttons: [.mode], deviceID: device)
        #expect(press.command == nil)
        #expect(press.buttons.contains(.mode))
        let release = tracker.process(buttons: [], deviceID: device)
        #expect(release.command == nil)
    }

    @Test func steamPlusXTogglesKeyboardAndConsumesX() {
        var tracker = StreamOSKChordTracker()
        _ = tracker.process(buttons: [.mode], deviceID: device)
        let chord = tracker.process(buttons: [.mode, .west], deviceID: device)
        #expect(chord.command == .toggleOnScreenKeyboard)
        #expect(!chord.buttons.contains(.west))
        #expect(chord.buttons.contains(.mode))
        let held = tracker.process(buttons: [.mode, .west], deviceID: device)
        #expect(held.command == nil)
        #expect(!held.buttons.contains(.west))
        let release = tracker.process(buttons: [], deviceID: device)
        #expect(release.command == nil)
    }

    @Test func xHeldBeforeSteamPressDoesNotChord() {
        var tracker = StreamOSKChordTracker()
        _ = tracker.process(buttons: [.west], deviceID: device)
        let steam = tracker.process(buttons: [.mode, .west], deviceID: device)
        #expect(steam.command == nil)
        #expect(steam.buttons.contains(.west))
        let release = tracker.process(buttons: [.west], deviceID: device)
        #expect(release.command == nil)
        #expect(release.buttons.contains(.west))
    }

    @Test func repeatedXWhileSteamHeldTogglesAgain() {
        var tracker = StreamOSKChordTracker()
        _ = tracker.process(buttons: [.mode], deviceID: device)
        _ = tracker.process(buttons: [.mode, .west], deviceID: device)
        _ = tracker.process(buttons: [.mode], deviceID: device)
        let second = tracker.process(buttons: [.mode, .west], deviceID: device)
        #expect(second.command == .toggleOnScreenKeyboard)
    }

    @Test func otherButtonsPassThroughDuringChord() {
        var tracker = StreamOSKChordTracker()
        _ = tracker.process(buttons: [.mode], deviceID: device)
        let result = tracker.process(buttons: [.mode, .south], deviceID: device)
        #expect(result.command == nil)
        #expect(result.buttons.contains(.south))
    }

    @Test func quickAccessTogglesHUDWhileSteamHeld() {
        var tracker = StreamOSKChordTracker()
        _ = tracker.process(buttons: [.mode], deviceID: device)
        let result = tracker.process(buttons: [.mode, .quickAccess], deviceID: device)
        #expect(result.command == .toggleUnifiedHUD)
        #expect(result.buttons.contains(.mode))
        #expect(!result.buttons.contains(.quickAccess))
    }

    @Test func devicesAreTrackedIndependently() {
        var tracker = StreamOSKChordTracker()
        _ = tracker.process(buttons: [.mode], deviceID: device)
        _ = tracker.process(buttons: [.mode], deviceID: otherDevice)
        let other = tracker.process(buttons: [.mode, .west], deviceID: otherDevice)
        #expect(other.command == .toggleOnScreenKeyboard)
        let press = tracker.process(buttons: [.quickAccess], deviceID: device)
        #expect(press.command == .toggleUnifiedHUD)
    }

    @Test func removedDeviceForgetsHeldState() {
        var tracker = StreamOSKChordTracker()
        _ = tracker.process(buttons: [.quickAccess], deviceID: device)
        tracker.removeDevice(device)
        let press = tracker.process(buttons: [.quickAccess], deviceID: device)
        #expect(press.command == .toggleUnifiedHUD)
    }
}

@Suite struct StreamOSKStateTests {
    @Test func leftPadTopLeftAimsFirstKey() {
        var state = StreamOSKState()
        state.updatePadCursor(.left, x: -1, y: 1)
        #expect(state.leftPadCursor == StreamOSKCursor(row: 0, column: 0))
        #expect(state.activatePadCursor(.left) == .output(.text("1")))
    }

    @Test func rightPadTopRightAimsLastKeyOfRow() {
        var state = StreamOSKState()
        state.updatePadCursor(.right, x: 1, y: 1)
        #expect(state.rightPadCursor == StreamOSKCursor(row: 0, column: 9))
        #expect(state.activatePadCursor(.right) == .output(.text("0")))
    }

    @Test func leftPadNeverCrossesIntoRightHalf() {
        var state = StreamOSKState()
        state.updatePadCursor(.left, x: 1, y: -1)
        #expect(state.leftPadCursor == StreamOSKCursor(row: 3, column: 4))
        state.updatePadCursor(.right, x: -1, y: -1)
        #expect(state.rightPadCursor == StreamOSKCursor(row: 3, column: 5))
    }

    @Test func padCursorWithoutTouchDoesNotType() {
        var state = StreamOSKState()
        #expect(state.activatePadCursor(.left) == .none)
    }

    @Test func shiftLatchUppercasesOneLetter() {
        var state = StreamOSKState()
        _ = state.activateKey(.shift)
        #expect(state.shiftLatched)
        #expect(state.activateKey(.character("q")) == .output(.text("Q")))
        #expect(!state.shiftLatched)
        #expect(state.activateKey(.character("q")) == .output(.text("q")))
    }

    @Test func symbolsLayerSwapsGridAndBack() {
        var state = StreamOSKState()
        _ = state.activateKey(.symbols)
        #expect(state.layer == .symbols)
        state.updatePadCursor(.left, x: -1, y: 1)
        #expect(state.activatePadCursor(.left) == .output(.text("!")))
        _ = state.activateKey(.symbols)
        #expect(state.layer == .letters)
        #expect(state.activatePadCursor(.left) == .output(.text("1")))
    }

    @Test func backspaceTrimsEchoAndEmitsKeyPress() {
        var state = StreamOSKState()
        _ = state.activateKey(.character("a"))
        _ = state.activateKey(.character("b"))
        #expect(state.echo == "ab")
        #expect(state.activateKey(.backspace) == .output(.keyPress(51)))
        #expect(state.echo == "a")
    }

    @Test func enterClearsEchoAndEmitsReturn() {
        var state = StreamOSKState()
        _ = state.activateKey(.character("a"))
        #expect(state.activateKey(.enter) == .output(.keyPress(36)))
        #expect(state.echo.isEmpty)
    }

    @Test func echoIsCapped() {
        var state = StreamOSKState()
        for _ in 0..<(StreamOSKState.echoLimit + 10) {
            _ = state.activateKey(.character("x"))
        }
        #expect(state.echo.count == StreamOSKState.echoLimit)
    }

    @Test func dismissKeyRequestsDismissal() {
        var state = StreamOSKState()
        #expect(state.activateKey(.dismiss) == .dismiss)
    }

    @Test func gridCursorMovesIntoAndOutOfBar() {
        var state = StreamOSKState()
        state.moveGridCursor(dx: 0, dy: 10)
        #expect(state.gridCursorInBar)
        state.moveGridCursor(dx: 10, dy: 0)
        #expect(state.barIndex == StreamOSKLayout.barItems.count - 1)
        #expect(state.activateGridCursor() == .dismiss)
        state.moveGridCursor(dx: 0, dy: -1)
        #expect(!state.gridCursorInBar)
        #expect(state.gridCursor.row == 1)
    }

    @Test func gridCursorClampsAtGridEdges() {
        var state = StreamOSKState()
        state.moveGridCursor(dx: -10, dy: -10)
        #expect(state.gridCursor == StreamOSKCursor(row: 0, column: 0))
        state.moveGridCursor(dx: 10, dy: 0)
        #expect(state.gridCursor == StreamOSKCursor(row: 0, column: 9))
    }

    @Test func mouseActivationMovesGridCursor() {
        var state = StreamOSKState()
        #expect(state.activateGridKey(row: 1, column: 6) == .output(.text("u")))
        #expect(state.gridCursor == StreamOSKCursor(row: 1, column: 6))
    }

    @Test func barSpaceActivatesFromMouse() {
        var state = StreamOSKState()
        #expect(state.activateBarItem(1) == .output(.text(" ")))
        #expect(state.gridCursorInBar)
    }
}

@Suite struct StreamOSKGamepadNavigatorTests {
    @Test func dpadEdgesMoveGridCursor() {
        var navigator = StreamOSKGamepadNavigator()
        #expect(navigator.action(deviceID: device, buttons: [.dpadRight], leftStickX: 0, leftStickY: 0) == .move(dx: 1, dy: 0))
        #expect(navigator.action(deviceID: device, buttons: [.dpadRight], leftStickX: 0, leftStickY: 0) == nil)
        #expect(navigator.action(deviceID: device, buttons: [], leftStickX: 0, leftStickY: 0) == nil)
        #expect(navigator.action(deviceID: device, buttons: [.dpadDown], leftStickX: 0, leftStickY: 0) == .move(dx: 0, dy: 1))
    }

    @Test func faceButtonsMapToKeyboardActions() {
        var navigator = StreamOSKGamepadNavigator()
        #expect(navigator.action(deviceID: device, buttons: [.south], leftStickX: 0, leftStickY: 0) == .activate)
        #expect(navigator.action(deviceID: device, buttons: [.east], leftStickX: 0, leftStickY: 0) == .backspace)
        #expect(navigator.action(deviceID: device, buttons: [.west], leftStickX: 0, leftStickY: 0) == .space)
        #expect(navigator.action(deviceID: device, buttons: [.north], leftStickX: 0, leftStickY: 0) == .shift)
        #expect(navigator.action(deviceID: device, buttons: [.start], leftStickX: 0, leftStickY: 0) == .enter)
        #expect(navigator.action(deviceID: device, buttons: [.select], leftStickX: 0, leftStickY: 0) == .dismiss)
    }

    @Test func stickMovesOnEdgeOnly() {
        var navigator = StreamOSKGamepadNavigator()
        #expect(navigator.action(deviceID: device, buttons: [], leftStickX: 0.8, leftStickY: 0) == .move(dx: 1, dy: 0))
        #expect(navigator.action(deviceID: device, buttons: [], leftStickX: 0.9, leftStickY: 0) == nil)
        #expect(navigator.action(deviceID: device, buttons: [], leftStickX: 0, leftStickY: 0) == nil)
        #expect(navigator.action(deviceID: device, buttons: [], leftStickX: 0, leftStickY: -0.8) == .move(dx: 0, dy: 1))
    }

    @Test func heldButtonDoesNotRetrigger() {
        var navigator = StreamOSKGamepadNavigator()
        #expect(navigator.action(deviceID: device, buttons: [.south], leftStickX: 0, leftStickY: 0) == .activate)
        #expect(navigator.action(deviceID: device, buttons: [.south], leftStickX: 0, leftStickY: 0) == nil)
    }

    @Test func devicesAreTrackedIndependently() {
        var navigator = StreamOSKGamepadNavigator()
        #expect(navigator.action(deviceID: device, buttons: [.south], leftStickX: 0, leftStickY: 0) == .activate)
        #expect(navigator.action(deviceID: otherDevice, buttons: [.south], leftStickX: 0, leftStickY: 0) == .activate)
        navigator.removeDevice(device)
        #expect(navigator.action(deviceID: device, buttons: [.south], leftStickX: 0, leftStickY: 0) == .activate)
    }
}
