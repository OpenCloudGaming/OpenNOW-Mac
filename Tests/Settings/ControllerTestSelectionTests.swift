import GameController
import Testing
@testable import OpenNOW

@MainActor
@Suite struct ControllerTestSelectionTests {
    @Test func selectionStaysWithDeviceAcrossDiscoveryAndPlayerOrderChanges() {
        var selection = ControllerTestSelection()
        selection.reconcile(connectedIDs: ["steam-1", "native-1", "native-2"])
        #expect(selection.deviceID == "steam-1")
        selection.select("native-2", connectedIDs: ["steam-1", "native-1", "native-2"])
        selection.reconcile(connectedIDs: ["steam-2", "native-2", "steam-1", "native-1"])
        #expect(selection.deviceID == "native-2")
    }

    @Test func disconnectFallsBackAndEmptyListClearsSelection() {
        var selection = ControllerTestSelection()
        selection.reconcile(connectedIDs: ["first", "second"])
        selection.reconcile(connectedIDs: ["second"])
        #expect(selection.deviceID == "second")
        selection.reconcile(connectedIDs: [])
        #expect(selection.deviceID == nil)
        selection.reconcile(connectedIDs: ["new"])
        #expect(selection.deviceID == "new")
    }

    @Test func stalePickerEntryCannotSelectDisconnectedDevice() {
        var selection = ControllerTestSelection()
        selection.reconcile(connectedIDs: ["connected"])
        selection.select("disconnected", connectedIDs: ["connected"])
        #expect(selection.deviceID == "connected")
    }

    @Test func steamInputAndBatteryOnlyComeFromSelectedDevice() {
        let model = SteamControllerTestModel()
        model.selectDevice("selected")
        var selected = ControllerInputSnapshot()
        selected.buttons = [.south]
        selected.leftTrigger = 0.75
        model.receiveSnapshot(selected, from: "selected")
        model.receiveBattery(71, charging: true, from: "selected")
        model.receiveSnapshot(ControllerInputSnapshot(), from: "other")
        model.receiveBattery(10, charging: false, from: "other")
        #expect(model.deviceID == "selected")
        #expect(model.snapshot == selected)
        #expect(model.batteryLevel == 71)
        #expect(model.isCharging)
        #expect(model.isConnected)
    }

    @Test func switchingSteamDevicesClearsOldTelemetryAndRejectsLateReports() {
        let model = SteamControllerTestModel()
        model.selectDevice("first")
        var held = ControllerInputSnapshot()
        held.buttons = [.south]
        model.receiveSnapshot(held, from: "first")
        model.receiveBattery(80, charging: true, from: "first")
        model.selectDevice("second")
        model.receiveSnapshot(held, from: "first")
        model.receiveBattery(80, charging: true, from: "first")
        #expect(model.snapshot == ControllerInputSnapshot())
        #expect(model.batteryLevel == nil)
        #expect(!model.isCharging)
        #expect(!model.isConnected)
        model.receiveSnapshot(held, from: "second")
        #expect(model.deviceID == "second")
        model.selectDevice(nil)
        model.receiveSnapshot(held, from: "second")
        #expect(!model.isConnected)
        #expect(model.snapshot == ControllerInputSnapshot())
    }

    @Test func rumbleNeverFallsBackToAnotherSteamController() {
        let model = SteamControllerTestModel()
        model.selectDevice("second")
        model.receiveSnapshot(ControllerInputSnapshot(), from: "second")
        #expect(model.rumbleDeviceID(connectedIDs: ["first", "second"]) == "second")
        #expect(model.rumbleDeviceID(connectedIDs: ["first"]) == nil)
        model.stop()
        #expect(model.rumbleDeviceID(connectedIDs: ["first", "second"]) == nil)
    }

    @Test func nativeSelectionSwitchesSnapshotsWithoutTakingHandlers() throws {
        let first = GCController.withExtendedGamepad()
        let second = GCController.withExtendedGamepad()
        let firstPad = try #require(first.extendedGamepad)
        let secondPad = try #require(second.extendedGamepad)
        firstPad.valueChangedHandler = { _, _ in }
        secondPad.valueChangedHandler = { _, _ in }
        firstPad.buttonA.setValue(1)
        secondPad.buttonB.setValue(1)
        let model = GenericControllerTestModel()
        model.start()
        defer { model.stop() }
        model.selectController(first)
        #expect(model.snapshot.buttons == [.south])
        model.selectController(second)
        #expect(model.snapshot.buttons == [.east])
        #expect(model.batteryPercent == nil)
        model.selectController(nil)
        #expect(!model.isConnected)
        #expect(model.snapshot == GenericControllerInputSnapshot())
        #expect(firstPad.valueChangedHandler != nil)
        #expect(secondPad.valueChangedHandler != nil)
    }
}
