import Foundation
import GameController
import Testing
@testable import OpenNOW

@MainActor
@Suite struct OPNStreamControllerPresetTests {
    private func makeStore() throws -> (store: ControllerMappingStore, defaults: UserDefaults, suite: String) {
        let suite = "OPNStreamControllerPresetTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (ControllerMappingStore(defaults: defaults), defaults, suite)
    }

    @Test func aStoredSelectionIsHandedOverOnceUnderItsAccount() {
        let preset = OPNStreamControllerPreset()
        let selection = OPNStreamControllerSelection(disabled: ["pad-a"], takesPadsFromOtherStreams: true)
        preset.store(selection, forAccount: "account-a")
        #expect(preset.peek(forAccount: "account-a") == selection)
        #expect(preset.peek(forAccount: "account-b") == OPNStreamControllerSelection())
        #expect(preset.take(forAccount: "account-a") == selection)
        #expect(preset.take(forAccount: "account-a") == OPNStreamControllerSelection())
    }

    @Test func anEmptySelectionClearsWhatWasStored() {
        let preset = OPNStreamControllerPreset()
        preset.store(OPNStreamControllerSelection(disabled: ["pad-a"]), forAccount: "account-a")
        preset.store(OPNStreamControllerSelection(), forAccount: "account-a")
        #expect(preset.peek(forAccount: "account-a") == OPNStreamControllerSelection())
    }

    @Test func theHandOffIsTheConnectedPadsThisStreamKeepsAndOnlyWhenAsked() {
        let connected: [InputDeviceID] = ["pad-a", "pad-b", "pad-c"]
        let off = OPNStreamControllerSelection(disabled: ["pad-a"], takesPadsFromOtherStreams: false)
        let on = OPNStreamControllerSelection(disabled: ["pad-a"], takesPadsFromOtherStreams: true)
        #expect(off.handedOff(connected: connected).isEmpty)
        #expect(on.handedOff(connected: connected) == ["pad-b", "pad-c"])
    }

    @Test func disabledPadsAreOutOfAStreamBeforeItsFirstSlotIsPublished() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = GCController.withExtendedGamepad()
        let second = GCController.withExtendedGamepad()
        let registry = ControllerMappingDevices(discovery: .init(nativeControllers: { [first, second] }, steamDeviceIDs: { [] }))
        let monitor = NativeGamepadMonitor(mappingProvider: store, registry: registry)
        let firstID = try #require(registry.id(for: first))
        let secondID = try #require(registry.id(for: second))

        monitor.disableForStream([firstID])

        #expect(monitor.topology.playerIndices == [0])
        #expect(monitor.streamControllerRows.first { $0.id == firstID }?.state == .disabled)
        #expect(monitor.streamControllerRows.first { $0.id == secondID }?.playerIndex == 0)
        monitor.stop()
    }

    @Test func otherStreamsLoseThePadsTheNewStreamKeeps() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = GCController.withExtendedGamepad()
        let second = GCController.withExtendedGamepad()
        let registry = ControllerMappingDevices(discovery: .init(nativeControllers: { [first, second] }, steamDeviceIDs: { [] }))
        let running = NativeGamepadMonitor(mappingProvider: store, registry: registry)
        let firstID = try #require(registry.id(for: first))
        let secondID = try #require(registry.id(for: second))
        let selection = OPNStreamControllerSelection(disabled: [firstID], takesPadsFromOtherStreams: true)

        running.disableForStream(selection.handedOff(connected: registry.orderedDevices.map(\.id)))

        #expect(running.streamControllerRows.first { $0.id == firstID }?.isEnabled == true)
        #expect(running.streamControllerRows.first { $0.id == secondID }?.isEnabled == false)
        running.stop()
    }

    @Test func aReconnectedPadKeepsItsStreamState() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = GCController.withExtendedGamepad()
        var attached = [first]
        let registry = ControllerMappingDevices(discovery: .init(nativeControllers: { attached }, steamDeviceIDs: { [] }))
        let monitor = NativeGamepadMonitor(mappingProvider: store, registry: registry)
        let firstID = try #require(registry.id(for: first))
        monitor.disableForStream([firstID])

        attached = []
        registry.refresh()
        attached = [first]
        registry.refresh()
        monitor.setStreamEnabled(false, for: firstID)

        #expect(monitor.streamControllerRows.first { $0.id == firstID }?.isEnabled == false)
        monitor.stop()
    }

    @Test func disablingAnUnknownPadChangesNothing() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = ControllerMappingDevices(discovery: .init(nativeControllers: { [] }, steamDeviceIDs: { [] }))
        let monitor = NativeGamepadMonitor(mappingProvider: store, registry: registry)
        monitor.disableForStream(["not-connected"])
        #expect(monitor.streamControllerRows.isEmpty)
        monitor.stop()
    }
}
