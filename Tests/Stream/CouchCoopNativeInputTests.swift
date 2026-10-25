import AppKit
import GameController
import Testing
@testable import OpenNOW

@MainActor
@Suite(.serialized, .streamLifecycleExclusive, .timeLimit(.minutes(1)))
struct CouchCoopNativeInputTests {
    @Test func focusLossReleasesSharedMappedDesktopHoldsBeforeUnlockWithoutResettingPads() async throws {
        let fixture = try CouchCoopNativeInputFixture()
        defer { fixture.close() }
        let mapped = GCController.withExtendedGamepad()
        let physical = GCController.withExtendedGamepad()
        let mappedPad = try #require(mapped.extendedGamepad)
        let physicalPad = try #require(physical.extendedGamepad)
        fixture.configureNativeControllers([
            ("mapped-native", mapped, fixture.store.profile(for: .generic)),
            ("physical-native", physical, nil),
        ])
        fixture.view.setPointerLocked(true)
        mappedPad.buttonA.setValue(1)
        mappedPad.buttonB.setValue(1)
        mappedPad.buttonX.setValue(1)
        physicalPad.buttonA.setValue(1)
        physicalPad.leftThumbstick.xAxis.setValue(0.5)
        fixture.pollNativeControllers()
        fixture.sendSteam(ControllerInputSnapshot(buttons: [.south, .east, .west]))
        fixture.view.gamepadMonitor.refreshInputState()
        let initial = try await fixture.recordedInputs()
        #expect(desktopInputs(initial).count == 2)
        #expect(gamepads(initial).count == 3, "\(fixture.routingDiagnostics); received=\(gamepads(initial))")
        #expect(fixture.view.pressedMouseButtons.isEmpty)
        #expect(fixture.view.pressedKeyboardEvents.isEmpty)

        let releases = CouchCoopFocusReleaseRecorder(view: fixture.view)
        fixture.focus.isWindowKey = false
        fixture.view.handleFocusLoss()
        fixture.view.handleFocusLoss()

        let released = try await fixture.recordedInputs()
        #expect(releases.sequence == ["key-release", "mouse-release", "unlock"])
        #expect(releases.releaseCaptureStates == [true, true])
        #expect(desktopInputs(Array(released.dropFirst(initial.count))).count == 2)
        #expect(gamepads(released) == gamepads(initial))
        #expect(fixture.view.activeGamepadStates[0]?.buttons == .north)
        #expect(fixture.view.activeGamepadStates[1]?.leftStickX == 0.5)
        #expect(fixture.view.activeGamepadStates[2]?.buttons == .north)
        #expect(fixture.view.gamepadMonitor.mappingsEnabled)

        fixture.view.gamepadMonitor.refreshInputState()
        physicalPad.leftThumbstick.xAxis.setValue(0.75)
        fixture.pollNativeControllers()
        fixture.sendSteam(ControllerInputSnapshot(buttons: [.south, .east, .west], leftTrigger: 0.75))
        let background = Array(try await fixture.recordedInputs().dropFirst(released.count))
        #expect(desktopInputs(background).isEmpty)
        #expect(gamepads(background).contains { $0.deviceID == "physical-native" && $0.leftStickX == 0.75 }, "\(fixture.routingDiagnostics)")
        #expect(gamepads(background).contains { $0.deviceID == "mapped-native" && $0.buttons == .north }, "\(fixture.routingDiagnostics)")
        #expect(gamepads(background).contains { $0.deviceID == "steam-input-test" && $0.buttons == .north })
        #expect(gamepads(background).allSatisfy { !$0.buttons.isEmpty })
    }

    @Test func returningFocusDoesNotReplayDesktopPressesHeldInTheBackground() async throws {
        let fixture = try CouchCoopNativeInputFixture()
        defer { fixture.close() }
        let held = ControllerInputSnapshot(buttons: [.south, .east, .west])
        fixture.view.setPointerLocked(true)
        fixture.sendSteam(held)
        fixture.focus.isWindowKey = false
        fixture.view.handleFocusLoss()
        fixture.sendSteam(ControllerInputSnapshot())
        fixture.sendSteam(held)
        let background = try await fixture.recordedInputs()
        #expect(desktopInputs(background).count == 4)

        fixture.focus.isWindowKey = true
        fixture.view.locksPointerWhenRelativeModeSelected = true
        fixture.view.handleFocusGain()
        fixture.sendSteam(held)
        let restored = try await fixture.recordedInputs()
        #expect(desktopInputs(restored) == desktopInputs(background))
        #expect(fixture.view.isPointerLocked)
        fixture.sendSteam(ControllerInputSnapshot())
        fixture.sendSteam(held)
        let pressedAgain = try await fixture.recordedInputs()
        #expect(desktopInputs(Array(pressedAgain.dropFirst(restored.count))).count == 2)
    }

    @Test func aMappedRelativeReleaseReachesTheHostAfterUnlockWithoutRecapturing() async throws {
        let fixture = try CouchCoopNativeInputFixture()
        defer { fixture.close() }
        fixture.view.setPointerLocked(true)
        fixture.sendSteam(ControllerInputSnapshot(buttons: [.south, .east]))
        let pressed = try await fixture.recordedInputs()
        #expect(desktopInputs(pressed).count == 2)
        fixture.view.setPointerLocked(false)
        fixture.focus.isWindowKey = false
        fixture.sendSteam(ControllerInputSnapshot())
        let released = Array(try await fixture.recordedInputs().dropFirst(pressed.count))

        #expect(desktopInputs(released).count == 2)
        #expect(desktopInputs(released).allSatisfy(NativeNVSTInputDispatcher.isNeutralizing))
        #expect(fixture.view.mouseInputMode == .relative)
        #expect(!fixture.view.isPointerLocked)
        #expect(fixture.cursorAssociations == [false, true])
    }

    @Test(arguments: BlockingOverlay.allCases)
    func overlayTransitionsReleaseMappedHoldsButRejectNewGameInput(_ overlay: BlockingOverlay) async throws {
        let fixture = try CouchCoopNativeInputFixture()
        defer { fixture.close() }
        fixture.view.setPointerLocked(true)
        fixture.sendSteam(ControllerInputSnapshot(buttons: [.south, .east, .west]))
        let initial = try await fixture.recordedInputs()
        switch overlay {
        case .hud:
            fixture.model.unifiedHUDVisible = true
            fixture.view.remoteInputEnabled = false
        case .quitMenu:
            fixture.model.streamControlsVisible = true
            fixture.view.remoteInputEnabled = false
        case .keyboard:
            fixture.view.localOverlayCapturesInput = true
            fixture.view.setPointerLocked(false)
        }
        let transition = Array(try await fixture.recordedInputs().dropFirst(initial.count))
        #expect(desktopInputs(transition).count == 2)
        #expect(desktopInputs(transition).allSatisfy(NativeNVSTInputDispatcher.isNeutralizing))
        #expect(!fixture.view.gamepadMonitor.mappingsEnabled)
        let stamp = MediaTimestamp(nanoseconds: 1)
        fixture.model.routeInputEvent(.mouse(.button(deviceID: "blocked", button: .right, isPressed: true, timestamp: stamp)), view: fixture.view)
        fixture.model.routeInputEvent(.keyboard(KeyboardEvent(deviceID: "blocked", keyCode: 0, scanCode: 0, isPressed: true, timestamp: stamp)), view: fixture.view)
        fixture.model.routeInputEvent(.gamepad(GamepadState(deviceID: "blocked", playerIndex: 3, buttons: .south, timestamp: stamp)), view: fixture.view)
        let blocked = try await fixture.recordedInputs()
        #expect(blocked.count == initial.count + transition.count)
        #expect(!fixture.view.isPointerLocked)
        #expect(fixture.cursorAssociations == [false, true])
    }

    @Test func backgroundSteamAndNativeCaptureCommandsNeverTakeTheOtherStreamsPointer() async throws {
        let background = try CouchCoopNativeInputFixture()
        let foreground = try CouchCoopNativeInputFixture()
        defer {
            background.close()
            foreground.close()
        }
        background.focus.isWindowKey = false
        background.view.handleFocusLoss()
        foreground.view.setPointerLocked(true)
        let native = GCController.withExtendedGamepad()
        let pad = try #require(native.extendedGamepad)
        background.configureNativeControllers([("native-command", native, background.store.profile(for: .generic))])
        background.sendSteam(ControllerInputSnapshot(buttons: [.north, .west]))
        pad.buttonY.setValue(1)
        pad.buttonX.setValue(1)
        background.pollNativeControllers()
        background.model.handleNativeCommand(.togglePointerCapture)
        background.view.setRemoteCursorVisible(false)
        background.view.cursorPolicy = .stream

        #expect(!background.view.isCursorCaptured)
        #expect(!background.view.manualPointerCaptureOverride)
        #expect(background.cursorAssociations.isEmpty)
        #expect(foreground.view.isPointerLocked)
        #expect(foreground.cursorAssociations == [false])
        let admitted = gamepads(try await background.recordedInputs())
        #expect(admitted.contains { $0.deviceID == "steam-input-test" && $0.buttons == .north })
        #expect(admitted.contains { $0.deviceID == "native-command" && $0.buttons == .north })

        background.sendSteam(ControllerInputSnapshot(buttons: .quickAccess))
        #expect(background.model.unifiedHUDVisible)
        #expect(!background.view.remoteInputEnabled)
        #expect(foreground.view.isPointerLocked)
        #expect(background.cursorAssociations.isEmpty)
        let afterQuickAccess = gamepads(try await background.recordedInputs())
        #expect(afterQuickAccess.allSatisfy { !$0.buttons.contains(.quickAccess) })
    }

    @Test(arguments: CaptureBlocker.allCases)
    func everyCaptureEntryPointHonorsOwnershipWhileUnlockRemainsPossible(_ blocker: CaptureBlocker) throws {
        let fixture = try CouchCoopNativeInputFixture()
        defer { fixture.close() }
        fixture.view.setPointerLocked(true)
        switch blocker {
        case .inactiveApplication: fixture.focus.isApplicationActive = false
        case .otherKeyWindow: fixture.focus.isWindowKey = false
        case .remoteInputDisabled: fixture.view.remoteInputEnabled = false
        case .keyboardOverlay: fixture.view.localOverlayCapturesInput = true
        case .pictureInPicture: fixture.view.isPictureInPictureMode = true
        case .actualNonKeyWindow:
            fixture.view.inputFocusProvider = nil
            #expect(!fixture.window.isKeyWindow)
        }
        fixture.view.setPointerLocked(false)
        #expect(!fixture.view.isCursorCaptured)
        #expect(fixture.cursorAssociations == [false, true])
        fixture.view.setPointerLocked(true)
        fixture.view.enablePointerLock()
        fixture.view.setManualPointerCapture(true)
        fixture.view.setRemoteCursorVisible(false)
        fixture.view.restoreInputFocus()
        fixture.view.mouseInputMode = .absolute
        fixture.view.confinesCursorToWindowInAbsoluteMode = true
        fixture.view.captureAbsoluteCursorIfNeeded()

        #expect(fixture.cursorAssociations == [false, true])
        #expect(!fixture.view.isCursorCaptured)
        #expect(!fixture.view.manualPointerCaptureOverride)
    }

    @Test func aFrontmostRealInputRetriesRejectedCaptureAndNativeCommandsStillToggleIt() async throws {
        let fixture = try CouchCoopNativeInputFixture()
        defer { fixture.close() }
        var associations: [Bool] = []
        fixture.view.cursorAssociationHandler = { isAssociated in
            associations.append(isAssociated)
            return associations.count == 1 ? .failure : .success
        }
        fixture.view.locksPointerWhenRelativeModeSelected = true
        fixture.view.handleFocusGain()
        #expect(!fixture.view.isPointerLocked)
        let motion = UserInputEvent.mouse(.moved(deviceID: "mouse", deltaX: 3, deltaY: -2, timestamp: MediaTimestamp(nanoseconds: 1)))
        fixture.model.routeInputEvent(motion, view: fixture.view)

        #expect(fixture.view.isPointerLocked)
        #expect(associations == [false, false])
        #expect(try await fixture.recordedInputs() == [motion])
        fixture.model.handleNativeCommand(.togglePointerCapture)
        #expect(!fixture.view.isPointerLocked)
        fixture.model.handleNativeCommand(.togglePointerCapture)
        #expect(fixture.view.isPointerLocked)
        #expect(fixture.view.manualPointerCaptureOverride)
    }

    @Test func pictureInPictureStillAdmitsAnUnfocusedPhysicalPadWithoutCapturing() async throws {
        let fixture = try CouchCoopNativeInputFixture()
        defer { fixture.close() }
        fixture.focus.isWindowKey = false
        fixture.view.allowsBackgroundGamepadInput = false
        fixture.view.isPictureInPictureMode = true
        fixture.model.isPictureInPicture = true
        #expect(try await fixture.recordedInputs().isEmpty)
        let native = GCController.withExtendedGamepad()
        let pad = try #require(native.extendedGamepad)
        fixture.configureNativeControllers([("pip-pad", native, nil)])
        pad.buttonA.setValue(1)
        pad.leftThumbstick.xAxis.setValue(0.75)
        fixture.pollNativeControllers()
        fixture.model.handleNativeCommand(.togglePointerCapture)

        let admitted = gamepads(try await fixture.recordedInputs())
        #expect(admitted.count == 1)
        #expect(admitted.first?.buttons == .south)
        #expect(admitted.first?.leftStickX == 0.75)
        #expect(!fixture.view.isCursorCaptured)
        #expect(fixture.cursorAssociations.isEmpty)
    }

    @Test func aRecordingBarrierReturnsItsOrderedPrefixEvenWhenTheReaderRunsLater() async throws {
        let recorder = CouchCoopNativeInputRecorder()
        let stamp = MediaTimestamp(nanoseconds: 1)
        let first = UserInputEvent.gamepad(GamepadState(deviceID: "first", playerIndex: 0, buttons: .south, timestamp: stamp))
        let later = UserInputEvent.gamepad(GamepadState(deviceID: "later", playerIndex: 1, buttons: .east, timestamp: stamp))
        await recorder.append(.event(first))
        await recorder.append(.event(.text(deviceID: "input-test-barrier", value: "first-prefix", timestamp: stamp)))
        await recorder.append(.event(later))
        await recorder.append(.event(.text(deviceID: "input-test-barrier", value: "second-prefix", timestamp: stamp)))

        #expect(try await recorder.snapshot(at: "first-prefix") == [first])
        #expect(try await recorder.snapshot(at: "second-prefix") == [first, later])
    }

    @Test func cancellingARecordingBarrierPropagatesCancellation() async {
        let recorder = CouchCoopNativeInputRecorder()
        let waiter = Task { try await recorder.snapshot(at: "cancelled-prefix") }
        waiter.cancel()

        await #expect(throws: CancellationError.self) { try await waiter.value }
    }

    private func desktopInputs(_ inputs: [UserInputEvent]) -> [UserInputEvent] {
        inputs.filter {
            switch $0 {
            case .keyboard, .mouse: true
            default: false
            }
        }
    }

    private func gamepads(_ inputs: [UserInputEvent]) -> [GamepadState] {
        inputs.compactMap {
            guard case .gamepad(let state) = $0 else { return nil }
            return state
        }
    }

    enum BlockingOverlay: CaseIterable, Sendable {
        case hud, quitMenu, keyboard
    }

    enum CaptureBlocker: CaseIterable, Sendable {
        case inactiveApplication, otherKeyWindow, remoteInputDisabled, keyboardOverlay, pictureInPicture, actualNonKeyWindow
    }
}
