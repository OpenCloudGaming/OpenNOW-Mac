import Foundation
import GameController
import os
import Testing
@testable import OpenNOW

@MainActor
@Suite struct ControllerOrderTransitionTests {
    @Test func nativeReorderDrainsOldInputAndReleasesBeforeNewSlot() throws {
        let controller = GCController.withExtendedGamepad()
        let gamepad = try #require(controller.extendedGamepad)
        let id = ObjectIdentifier(controller)
        let state = NativeGamepadPollState()
        state.cachedControllers = [controller]
        state.controllerSlots = [id: 0]
        let profile = ControllerMappingProfile(name: "Keyboard", family: .generic,
                                               bindings: [.faceA: .keyboardKey(keyCode: 49, modifiers: [])])
        _ = state.configureMappings([id: NativeControllerMappingConfiguration(deviceID: "pad", playerIndex: 0, profile: profile)])
        gamepad.buttonA.setValue(1)
        let captured = OSAllocatedUnfairLock(initialState: [UserInputEvent]())
        state.pollAndEmit(onEvents: { events in captured.withLock { $0 += events } }, onBatteryChange: { _ in })
        state.pendingEvents = captured.withLock { $0 }
        state.lastBatteryLevels[id] = 75
        let releases = state.prepareForSlotChange()
        #expect(state.pendingEvents.isEmpty)
        #expect(state.lastBatteryLevels.isEmpty)
        #expect(keyStates(releases) == [true, false])
        #expect(gamepads(releases).allSatisfy { $0.playerIndex == 0 })
        #expect(gamepads(releases).last?.buttons.isEmpty == true)
        state.controllerSlots = [id: 1]
        #expect(state.configureMappings([id: NativeControllerMappingConfiguration(deviceID: "pad", playerIndex: 1, profile: profile)]).isEmpty)
        captured.withLock { $0.removeAll() }
        state.pollAndEmit(onEvents: { events in captured.withLock { $0 += events } }, onBatteryChange: { _ in })
        let resumed = captured.withLock { $0 }
        #expect(keyStates(resumed) == [true])
        #expect(gamepads(resumed).allSatisfy { $0.playerIndex == 1 && $0.deviceID == "pad" })
    }

    @Test func steamReorderReleasesOldSlotEvenWhenMappingsAreSuspended() throws {
        let suite = "ControllerOrderTransitionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ControllerMappingStore(defaults: defaults)
        var profile = store.createProfile(named: "Steam keyboard")
        profile.bindings[.faceA] = .keyboardKey(keyCode: 49, modifiers: [])
        store.updateProfile(profile)
        let monitor = NativeGamepadMonitor(mappingProvider: store)
        monitor.pollingAllowed = true
        monitor.mappingsEnabled = true
        monitor.pollState.steamControllerSlots = ["steam": 0, "suspended-steam": 1]
        var captured: [UserInputEvent] = []
        monitor.onInputEvent = { captured.append($0) }
        monitor.applyBindingEngine(deviceID: "steam", playerIndex: 0, snapshot: ControllerInputSnapshot(buttons: [.south]), includePointerMotion: false)
        captured.removeAll()
        monitor.prepareForControllerSlotChange()
        #expect(keyStates(captured) == [false])
        #expect(Set(gamepads(captured).map(\.playerIndex)) == [0, 1])
        #expect(gamepads(captured).allSatisfy { $0.buttons.isEmpty })
        #expect(monitor.bindingEngines.isEmpty)
        monitor.pollState.steamControllerSlots = ["steam": 1, "suspended-steam": 0]
        captured.removeAll()
        monitor.applyBindingEngine(deviceID: "steam", playerIndex: 1, snapshot: ControllerInputSnapshot(buttons: [.south]), includePointerMotion: false)
        #expect(keyStates(captured) == [true])
        #expect(gamepads(captured).allSatisfy { $0.playerIndex == 1 })
        monitor.stop()
    }

    @Test func orderingDoesNotChangeWhichTypeProfileApplies() throws {
        let suite = "ControllerOrderProfileTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ControllerMappingStore(defaults: defaults)
        let profile = store.createProfile(named: "Generic pads", family: .generic)
        var order = ControllerPlayerOrder()
        order.update(connectedIDs: ["first", "second"])
        order.move("second", direction: .earlier)
        // Resolution is keyed on the controller type, so both pads keep the type default no matter
        // how the player order changes.
        #expect(store.profile(for: .generic)?.id == profile.id)
        #expect(store.profile(for: .steam)?.id != profile.id)
    }

    @Test func bothUnmappedControllersAreNeutralizedBeforeSwappedState() throws {
        let first = GCController.withExtendedGamepad()
        let second = GCController.withExtendedGamepad()
        let firstPad = try #require(first.extendedGamepad)
        let secondPad = try #require(second.extendedGamepad)
        firstPad.buttonA.setValue(1)
        firstPad.leftThumbstick.xAxis.setValue(0.75)
        secondPad.buttonB.setValue(1)
        secondPad.rightTrigger.setValue(0.5)
        let firstID = ObjectIdentifier(first)
        let secondID = ObjectIdentifier(second)
        let state = NativeGamepadPollState()
        state.cachedControllers = [first, second]
        state.controllerSlots = [firstID: 0, secondID: 1]
        _ = state.configureMappings([
            firstID: NativeControllerMappingConfiguration(deviceID: "first", playerIndex: 0, profile: nil),
            secondID: NativeControllerMappingConfiguration(deviceID: "second", playerIndex: 1, profile: nil),
        ])
        let captured = OSAllocatedUnfairLock(initialState: [UserInputEvent]())
        state.pollAndEmit(onEvents: { events in captured.withLock { $0 += events } }, onBatteryChange: { _ in })
        state.pendingEvents = captured.withLock { $0 }
        let old = gamepads(state.prepareForSlotChange())
        #expect(old.count == 4)
        #expect(old.suffix(2).allSatisfy { $0.buttons.isEmpty && $0.leftStickX == 0 && $0.rightTrigger == 0 })
        #expect(Set(old.suffix(2).map(\.playerIndex)) == [0, 1])
        state.controllerSlots = [firstID: 1, secondID: 0]
        _ = state.configureMappings([
            firstID: NativeControllerMappingConfiguration(deviceID: "first", playerIndex: 1, profile: nil),
            secondID: NativeControllerMappingConfiguration(deviceID: "second", playerIndex: 0, profile: nil),
        ])
        captured.withLock { $0.removeAll() }
        state.pollAndEmit(onEvents: { events in captured.withLock { $0 += events } }, onBatteryChange: { _ in })
        let next = gamepads(captured.withLock { $0 })
        #expect(next.first { $0.deviceID == "first" }?.playerIndex == 1)
        #expect(next.first { $0.deviceID == "first" }?.leftStickX == 0.75)
        #expect(next.first { $0.deviceID == "second" }?.playerIndex == 0)
        #expect(next.first { $0.deviceID == "second" }?.rightTrigger == 0.5)
    }

    private func keyStates(_ events: [UserInputEvent]) -> [Bool] {
        events.compactMap { if case .keyboard(let key) = $0 { key.isPressed } else { nil } }
    }

    private func gamepads(_ events: [UserInputEvent]) -> [GamepadState] {
        events.compactMap { if case .gamepad(let state) = $0 { state } else { nil } }
    }
}
