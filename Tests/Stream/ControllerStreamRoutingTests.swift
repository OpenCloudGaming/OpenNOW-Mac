import Foundation
import GameController
import os
import Testing
@testable import OpenNOW

/// Stream selection seen from the transport boundary: what the seat is told, which slots exist, and
/// what happens to held input when a device loses its slot to a disable or a disconnect.
/// Discovery is scripted, so these prove the model and routing contract without hardware attached.
@MainActor
@Suite struct ControllerStreamRoutingTests {
    private func makeStore() throws -> (store: ControllerMappingStore, defaults: UserDefaults, suite: String) {
        let suite = "ControllerStreamRoutingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (ControllerMappingStore(defaults: defaults), defaults, suite)
    }

    @Test func disablingADeviceCompactsTheSlotMapWithoutTouchingTheSharedOrder() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = GCController.withExtendedGamepad()
        let second = GCController.withExtendedGamepad()
        let registry = ControllerMappingDevices(discovery: .init(nativeControllers: { [first, second] }, steamDeviceIDs: { [] }))
        let monitor = NativeGamepadMonitor(mappingProvider: store, registry: registry)
        let firstID = try #require(registry.id(for: first))
        let secondID = try #require(registry.id(for: second))
        #expect(monitor.inputPaths().map(\.playerIndex) == [0, 1])
        #expect(monitor.topology.playerIndices == [0, 1])

        monitor.setStreamEnabled(false, for: secondID)
        #expect(monitor.topology.playerIndices == [0])
        #expect(monitor.inputPaths().map(\.playerIndex) == [0])
        #expect(monitor.streamControllerRows.first { $0.id == secondID }?.state == .disabled)
        #expect(monitor.streamControllerRows.first { $0.id == secondID }?.playerIndex == nil)
        // Disabling is stream-local: the shared order keeps both devices where they were.
        #expect(registry.playerOrder.deviceIDs == [firstID, secondID])

        monitor.setStreamEnabled(true, for: secondID)
        #expect(monitor.topology.playerIndices == [0, 1])
        #expect(monitor.inputPaths().map(\.playerIndex) == [0, 1])
        monitor.stop()
    }

    @Test func everyDeviceDisabledProducesAnEmptyLocalSlotMap() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = GCController.withExtendedGamepad()
        let registry = ControllerMappingDevices(discovery: .init(nativeControllers: { [first] }, steamDeviceIDs: { [] }))
        let monitor = NativeGamepadMonitor(mappingProvider: store, registry: registry)
        let firstID = try #require(registry.id(for: first))
        #expect(monitor.topology.playerIndices == [0])

        monitor.setStreamEnabled(false, for: firstID)
        #expect(monitor.topology.playerIndices.isEmpty)
        #expect(monitor.inputPaths().isEmpty)
        monitor.stop()
    }

    @Test func midStreamArrivalIsAdmittedDisabledUntilThisStreamEnablesIt() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = GCController.withExtendedGamepad()
        var natives: [GCController] = [first]
        let registry = ControllerMappingDevices(discovery: .init(nativeControllers: { natives }, steamDeviceIDs: { [] }))
        let monitor = NativeGamepadMonitor(mappingProvider: store, registry: registry)
        let firstID = try #require(registry.id(for: first))
        #expect(monitor.inputPaths().map(\.playerIndex) == [0])

        let second = GCController.withExtendedGamepad()
        natives = [first, second]
        var arrivals: [String] = []
        monitor.onStreamControllerArrival = { arrivals.append($0) }
        monitor.refreshInputState()
        let secondID = try #require(registry.id(for: second))
        #expect(arrivals.count == 1)
        #expect(monitor.streamControllerRows.first { $0.id == secondID }?.state == .newlyIdentified)
        #expect(monitor.inputPaths().map(\.playerIndex) == [0])

        monitor.setStreamEnabled(true, for: secondID)
        #expect(monitor.topology.playerIndices == [0, 1])
        #expect(registry.playerOrder.deviceIDs == [firstID, secondID])
        monitor.stop()
    }

    @Test func disableNeutralizesTheOldSlotBeforeTheCompactedMapIsConfigured() throws {
        let controller = GCController.withExtendedGamepad()
        let gamepad = try #require(controller.extendedGamepad)
        let id = ObjectIdentifier(controller)
        let state = NativeGamepadPollState()
        state.cachedControllers = [controller]
        state.controllerSlots = [id: 1]
        let profile = ControllerMappingProfile(name: "Keyboard", family: .generic,
                                               bindings: [.faceA: .keyboardKey(keyCode: 49, modifiers: [])])
        _ = state.configureMappings([id: NativeControllerMappingConfiguration(deviceID: "pad", playerIndex: 1, profile: profile)])
        gamepad.buttonA.setValue(1)
        let captured = OSAllocatedUnfairLock(initialState: [UserInputEvent]())
        state.pollAndEmit(onEvents: { events in captured.withLock { $0 += events } }, onBatteryChange: { _ in })
        state.pendingEvents = captured.withLock { $0 }

        // The stream disables the device: the queued press is delivered, then the old slot is
        // neutralized and its owned key released — before any replacement map exists.
        let releases = state.prepareForSlotChange()
        #expect(keyStates(releases) == [true, false])
        #expect(gamepads(releases).allSatisfy { $0.playerIndex == 1 && $0.buttons.isEmpty })

        state.controllerSlots = [:]
        state.cachedControllers = []
        captured.withLock { $0.removeAll() }
        state.pollAndEmit(onEvents: { events in captured.withLock { $0 += events } }, onBatteryChange: { _ in })
        #expect(captured.withLock { $0 }.isEmpty)
    }

    private func keyStates(_ events: [UserInputEvent]) -> [Bool] {
        events.compactMap {
            switch $0 {
            case .keyboard(let key): key.isPressed
            default: nil
            }
        }
    }

    private func gamepads(_ events: [UserInputEvent]) -> [GamepadState] {
        events.compactMap {
            switch $0 {
            case .gamepad(let state): state
            default: nil
            }
        }
    }
}
