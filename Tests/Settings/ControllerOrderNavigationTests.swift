import Foundation
import Testing
@testable import OpenNOW

@MainActor
@Suite struct ControllerOrderNavigationTests {
    @Test func gamepadSelectsAndActivatesAvailableMoveArrows() {
        let navigation = ControllerOrderNavigationModel()
        let ids: [InputDeviceID] = ["first", "second", "third"]
        navigation.reconcile(ids)
        #expect(navigation.focus == .init(deviceID: "first", direction: .later))
        #expect(navigation.process(.activate, deviceIDs: ids) == .move("first", .later))
        #expect(navigation.process(.move(.down), deviceIDs: ids) == nil)
        #expect(navigation.process(.move(.left), deviceIDs: ids) == nil)
        #expect(navigation.process(.activate, deviceIDs: ids) == .move("second", .earlier))
        #expect(navigation.process(.back, deviceIDs: ids) == .close)
    }

    @Test func focusStaysWithMovedControllerAndSkipsDisabledArrows() {
        let navigation = ControllerOrderNavigationModel()
        navigation.reconcile(["first", "second"])
        navigation.reconcile(["second", "first"])
        #expect(navigation.focus == .init(deviceID: "first", direction: .earlier))
        #expect(navigation.process(.move(.right), deviceIDs: ["second", "first"]) == nil)
        #expect(navigation.focus?.direction == .earlier)
        navigation.reconcile(["second"])
        #expect(navigation.focus == nil)
        #expect(navigation.process(.back, deviceIDs: ["second"]) == .close)
    }

    @Test func openingButtonDoesNotImmediatelyReorder() {
        let navigation = ControllerOrderNavigationModel()
        let ids: [InputDeviceID] = ["first", "second"]
        let pressed = GamepadState(deviceID: "first", playerIndex: 0, buttons: [.south], timestamp: MediaTimestamp(nanoseconds: 0))
        let released = GamepadState(deviceID: "first", playerIndex: 0, timestamp: MediaTimestamp(nanoseconds: 0))
        #expect(navigation.process(pressed, deviceIDs: ids) == nil)
        #expect(navigation.process(released, deviceIDs: ids) == nil)
        #expect(navigation.process(pressed, deviceIDs: ids) == .move("first", .later))
    }

    @Test func controllerOrderSearchFindsSharedTools() throws {
        let result = try #require(SettingsSearchIndex.results(for: "reorder").first)
        #expect(result.title == "Controller Order")
        #expect(result.group == .input)
        #expect(result.sectionID == "controller-tools")
    }
}
