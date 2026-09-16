import Foundation
import GameController
import os
import Testing
@testable import OpenNOW

@MainActor
@Suite struct NativeGamepadMappingTests {
    @Test func identicalControllersReceiveStableDistinctConnectionIDs() throws {
        let first = GCController.withExtendedGamepad()
        let second = GCController.withExtendedGamepad()
        #expect(first.vendorName == second.vendorName)
        var connections = ControllerConnectionIDs()
        let firstObject = ObjectIdentifier(first)
        let secondObject = ObjectIdentifier(second)
        let original = connections.update([firstObject, secondObject])
        #expect(original[firstObject] != original[secondObject])
        #expect(connections.update([secondObject, firstObject]) == original)
        _ = connections.update([secondObject])
        let reconnected = connections.update([firstObject, secondObject])
        #expect(reconnected[firstObject] != original[firstObject])
        #expect(reconnected[secondObject] == original[secondObject])
    }

    @Test func nativePollDisconnectAndPauseReleaseMappedInput() throws {
        let controller = GCController.withExtendedGamepad()
        let gamepad = try #require(controller.extendedGamepad)
        let key = ObjectIdentifier(controller)
        let state = NativeGamepadPollState()
        state.cachedControllers = [controller]
        state.controllerSlots = [key: 0]
        let profile = ControllerMappingProfile(name: "Custom", family: .generic,
                                               bindings: [.faceA: .keyboardKey(keyCode: 49, modifiers: [])])
        let configuration = [key: NativeControllerMappingConfiguration(deviceID: "test-native", playerIndex: 0, profile: profile)]
        _ = state.configureMappings(configuration)
        gamepad.buttonA.setValue(1)
        let captured = OSAllocatedUnfairLock(initialState: [UserInputEvent]())
        state.pollAndEmit(onEvents: { events in captured.withLock { $0 += events } }, onBatteryChange: { _ in })
        #expect(captured.withLock { $0 }.contains { if case .keyboard(let key) = $0 { key.isPressed } else { false } })
        let paused = state.resetMappings()
        #expect(paused.contains { if case .keyboard(let key) = $0 { !key.isPressed } else { false } })
        captured.withLock { $0.removeAll() }
        state.pollAndEmit(onEvents: { events in captured.withLock { $0 += events } }, onBatteryChange: { _ in })
        #expect(captured.withLock { $0 }.contains { if case .keyboard(let key) = $0 { key.isPressed } else { false } })
        let disconnected = state.configureMappings([:])
        #expect(disconnected.contains { if case .keyboard(let key) = $0 { !key.isPressed } else { false } })
    }

    @Test func suspendedSteamMappingsKeepGuideButtonReserved() throws {
        let suite = "NativeGamepadMappingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitor = NativeWebRTCGamepadMonitor(mappingProvider: ControllerMappingStore(defaults: defaults))
        monitor.mappingsEnabled = false
        var events: [UserInputEvent] = []
        monitor.onInputEvent = { events.append($0) }
        let snapshot = ControllerInputSnapshot(buttons: [.mode, .south], leftTrigger: 0.375, rightStickX: -0.625)
        monitor.applyBindingEngine(deviceID: "test-steam", playerIndex: 0, snapshot: snapshot, includePointerMotion: false)
        let event = try #require(events.last)
        guard case .gamepad(let state) = event else {
            Issue.record("Expected a gamepad event")
            return
        }
        #expect(state.buttons == [.south])
        #expect(state.leftTrigger == snapshot.leftTrigger)
        #expect(state.rightStickX == snapshot.rightStickX)
    }

    @Test func nativePollingTicksMappedSticksWithoutChangedState() throws {
        let controller = GCController.withExtendedGamepad()
        let gamepad = try #require(controller.extendedGamepad)
        let key = ObjectIdentifier(controller)
        let state = NativeGamepadPollState()
        state.cachedControllers = [controller]
        state.controllerSlots = [key: 0]
        var profile = ControllerMappingProfile(name: "Mouse", family: .generic)
        profile.leftStick.mode = .mouse
        _ = state.configureMappings([key: NativeControllerMappingConfiguration(deviceID: "test-native", playerIndex: 0, profile: profile)])
        gamepad.leftThumbstick.xAxis.setValue(1)
        let captured = OSAllocatedUnfairLock(initialState: [UserInputEvent]())
        for _ in 0..<3 {
            state.pollAndEmit(onEvents: { events in captured.withLock { $0 += events } }, onBatteryChange: { _ in })
        }
        let moves = captured.withLock { $0 }.filter { if case .mouse(.moved) = $0 { true } else { false } }
        #expect(moves.count == 3)
    }
}
