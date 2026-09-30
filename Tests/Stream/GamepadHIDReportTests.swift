import Foundation
import GameController
import os
import Testing
@testable import OpenNOW

@Suite struct GamepadHIDReportTests {
    private func sonyReport(id: UInt8, count: Int, offset: Int) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: count)
        report[0] = id
        for index in offset..<(offset + 4) { report[index] = 128 }
        return report
    }

    /// The values this parser produces are the pad's raw report, so they must carry the source that
    /// tells the wire to send them without the client deadzone.
    @Test func parsedReportsCarryTheGamepadAPISource() throws {
        let report = sonyReport(id: 0x01, count: 64, offset: 1)
        let snapshot = try #require(GamepadHIDReport.parse(report, family: .dualSense, previous: nil))
        #expect(snapshot.inputSource == .gamepadAPI)
    }

    @Test func axesAreCenteredAndReachBothEnds() {
        #expect(GamepadHIDReport.axis(UInt8(128)) == 0)
        #expect(GamepadHIDReport.axis(UInt8(0)) == -1)
        #expect(GamepadHIDReport.axis(UInt8(255)) == 1)
        #expect(GamepadHIDReport.axis(UInt16(32768)) == 0)
        #expect(GamepadHIDReport.axis(UInt16(0)) == -1)
        #expect(GamepadHIDReport.axis(UInt16(65535)) == 1)
    }

    @Test func smallStickDeflectionIsNotZeroed() throws {
        var report = sonyReport(id: 0x01, count: 64, offset: 1)
        report[1] = 131
        report[8] = 0x08
        let snapshot = try #require(GamepadHIDReport.parse(report, family: .dualSense, previous: nil))
        #expect(snapshot.leftStickX > 0)
        #expect(snapshot.leftStickX < 0.05)
    }

    @Test func dualSenseUSBReport() throws {
        var report = sonyReport(id: 0x01, count: 64, offset: 1)
        report[1] = 255
        report[2] = 0
        report[5] = 255
        report[8] = 0x00 | 0x20
        report[9] = 0x01 | 0x20
        report[10] = 0x01
        let snapshot = try #require(GamepadHIDReport.parse(report, family: .dualSense, previous: nil))
        #expect(snapshot.leftStickX == 1)
        #expect(snapshot.leftStickY == 1)
        #expect(snapshot.rightStickX == 0)
        #expect(snapshot.leftTrigger == 1)
        #expect(snapshot.rightTrigger == 0)
        #expect(snapshot.buttons == [.dpadUp, .south, .leftShoulder, .start, .mode])
        #expect(snapshot.touchpad == nil)
    }

    @Test func dualSenseBluetoothExtendedReport() throws {
        var report = sonyReport(id: 0x31, count: 78, offset: 2)
        report[5] = 0
        report[9] = 0x08 | 0x80
        report[10] = 0x10
        let snapshot = try #require(GamepadHIDReport.parse(report, family: .dualSense, previous: nil))
        #expect(snapshot.rightStickY == 1)
        #expect(snapshot.buttons == [.north, .select])
    }

    @Test func dualSenseBluetoothSimpleReport() throws {
        var report = sonyReport(id: 0x01, count: 10, offset: 1)
        report[5] = 0x06 | 0x10
        report[6] = 0x80
        report[9] = 255
        let snapshot = try #require(GamepadHIDReport.parse(report, family: .dualSense, previous: nil))
        #expect(snapshot.buttons == [.dpadLeft, .west, .rightStick])
        #expect(snapshot.rightTrigger == 1)
    }

    @Test func dualShock4USBReportCarriesTouchpad() throws {
        var report = sonyReport(id: 0x01, count: 64, offset: 1)
        report[5] = 0x03 | 0x40
        report[7] = 0x02
        report[35] = 0x00
        report[36] = 0x7F
        report[37] = 0x07
        report[38] = 0x00
        let snapshot = try #require(GamepadHIDReport.parse(report, family: .dualShock4, previous: nil))
        #expect(snapshot.buttons == [.dpadDown, .dpadRight, .east])
        let touchpad = try #require(snapshot.touchpad)
        #expect(touchpad.touched)
        #expect(touchpad.pressed)
        #expect(touchpad.x == 1)
        #expect(touchpad.y == 1)
    }

    @Test func dualShock4BluetoothReportNeedsInputFlag() throws {
        var report = sonyReport(id: 0x11, count: 78, offset: 3)
        report[3] = 0
        #expect(GamepadHIDReport.parse(report, family: .dualShock4, previous: nil) == nil)
        report[1] = 0xC0
        report[7] = 0x08
        report[37] = 0x80
        let snapshot = try #require(GamepadHIDReport.parse(report, family: .dualShock4, previous: nil))
        #expect(snapshot.leftStickX == -1)
        #expect(snapshot.buttons.isEmpty)
        #expect(snapshot.touchpad?.touched == false)
    }

    @Test func xboxBluetoothReport() throws {
        var report = [UInt8](repeating: 0, count: 17)
        report[0] = 0x01
        report[1] = 0xFF
        report[2] = 0xFF
        report[3] = 0x00
        report[4] = 0x00
        report[6] = 0x80
        report[8] = 0x80
        report[9] = 0xFF
        report[10] = 0x03
        report[13] = 3
        report[14] = 0x01 | 0x08
        report[15] = 0x04 | 0x10
        let snapshot = try #require(GamepadHIDReport.parse(report, family: .xbox, previous: nil))
        #expect(snapshot.leftStickX == 1)
        #expect(snapshot.leftStickY == 1)
        #expect(snapshot.rightStickX == 0)
        #expect(snapshot.rightStickY == 0)
        #expect(snapshot.leftTrigger == 1)
        #expect(snapshot.rightTrigger == 0)
        #expect(snapshot.buttons == [.dpadRight, .south, .west, .select, .mode])
    }

    @Test func capturedXboxSeriesReportsDecode() throws {
        let yPressed: [UInt8] = [0x01, 0x12, 0x84, 0x50, 0x7B, 0x57, 0x7B, 0xD4, 0x82, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00]
        let dpadRight: [UInt8] = [0x01, 0xFB, 0x7C, 0xCE, 0x7B, 0x46, 0x7F, 0x80, 0x82, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00]
        let north = try #require(GamepadHIDReport.parse(yPressed, family: .xbox, previous: nil))
        #expect(north.buttons == [.north])
        #expect(north.leftStickX > 0.03 && north.leftStickX < 0.04)
        #expect(north.leftTrigger == 0)
        let right = try #require(GamepadHIDReport.parse(dpadRight, family: .xbox, previous: north))
        #expect(right.buttons == [.dpadRight])
        #expect(right.leftStickX < 0)
    }

    @Test func xboxLegacyReportTakesGuideFromItsOwnReport() throws {
        var report = [UInt8](repeating: 0, count: 16)
        report[0] = 0x01
        report[14] = 0x04 | 0x80
        report[15] = 0x02
        let first = try #require(GamepadHIDReport.parse(report, family: .xbox, previous: nil))
        #expect(first.buttons == [.west, .start, .rightStick])
        let guide = try #require(GamepadHIDReport.parse([0x02, 0x01], family: .xbox, previous: first))
        #expect(guide.buttons.contains(.mode))
        let held = try #require(GamepadHIDReport.parse(report, family: .xbox, previous: guide))
        #expect(held.buttons.contains(.mode))
        let released = try #require(GamepadHIDReport.parse([0x02, 0x00], family: .xbox, previous: held))
        #expect(!released.buttons.contains(.mode))
    }

    @Test func unknownOrShortReportsAreIgnored() {
        #expect(GamepadHIDReport.parse([], family: .xbox, previous: nil) == nil)
        #expect(GamepadHIDReport.parse([0x01, 0x00], family: .xbox, previous: nil) == nil)
        #expect(GamepadHIDReport.parse([0x05] + [UInt8](repeating: 0, count: 63), family: .dualSense, previous: nil) == nil)
        #expect(GamepadHIDReport.parse([0x02, 0x01], family: .xbox, previous: nil) == nil)
    }

    @Test func familiesFromDeviceIdentity() {
        #expect(GamepadHIDFamily(vendorID: 0x054C, productID: 0x0CE6, transport: "USB") == .dualSense)
        #expect(GamepadHIDFamily(vendorID: 0x054C, productID: 0x0DF2, transport: "Bluetooth") == .dualSense)
        #expect(GamepadHIDFamily(vendorID: 0x054C, productID: 0x09CC, transport: "Bluetooth") == .dualShock4)
        #expect(GamepadHIDFamily(vendorID: 0x045E, productID: 0x0B13, transport: "Bluetooth Low Energy") == .xbox)
        #expect(GamepadHIDFamily(vendorID: 0x045E, productID: 0x0B12, transport: "USB") == nil)
        #expect(GamepadHIDFamily(vendorID: 0x054C, productID: 0x0268, transport: "USB") == nil)
    }
}

@Suite struct GamepadHIDPairingTests {
    private typealias Pairing = GamepadHIDPairing<Int, String>

    @Test func singleControllerPairsByFamily() {
        var pairing = Pairing()
        pairing.update(controllers: [.init(id: 1, family: .xbox, buttons: []), .init(id: 2, family: .dualSense, buttons: [])],
                       devices: [.init(id: "ds", family: .dualSense, buttons: []), .init(id: "xb", family: .xbox, buttons: [])])
        #expect(pairing.pairs == [1: "xb", 2: "ds"])
    }

    @Test func identicalControllersPairOnPress() {
        var pairing = Pairing()
        let devices: [Pairing.Device] = [.init(id: "a", family: .dualSense, buttons: []), .init(id: "b", family: .dualSense, buttons: [.south])]
        pairing.update(controllers: [.init(id: 1, family: .dualSense, buttons: []), .init(id: 2, family: .dualSense, buttons: [])],
                       devices: devices.map { .init(id: $0.id, family: $0.family, buttons: []) })
        #expect(pairing.pairs.isEmpty)
        pairing.update(controllers: [.init(id: 1, family: .dualSense, buttons: []), .init(id: 2, family: .dualSense, buttons: [.south])],
                       devices: devices)
        #expect(pairing.pairs[2] == "b")
        #expect(pairing.pairs[1] == "a")
    }

    @Test func homeButtonAloneDoesNotPair() {
        var pairing = Pairing()
        pairing.update(controllers: [.init(id: 1, family: .xbox, buttons: [.mode]), .init(id: 2, family: .xbox, buttons: [])],
                       devices: [.init(id: "a", family: .xbox, buttons: [.mode])])
        #expect(pairing.pairs.isEmpty)
    }

    @Test func pairsAreDroppedWhenEitherSideDisappears() {
        var pairing = Pairing()
        pairing.update(controllers: [.init(id: 1, family: .xbox, buttons: [])], devices: [.init(id: "a", family: .xbox, buttons: [])])
        #expect(pairing.pairs == [1: "a"])
        pairing.update(controllers: [.init(id: 1, family: .xbox, buttons: [])], devices: [])
        #expect(pairing.pairs.isEmpty)
    }

    @Test func unknownFamilyNeverPairs() {
        var pairing = Pairing()
        pairing.update(controllers: [.init(id: 1, family: nil, buttons: [.south])], devices: [.init(id: "a", family: .xbox, buttons: [.south])])
        #expect(pairing.pairs.isEmpty)
    }
}

@MainActor
@Suite struct GamepadHIDPollTests {
    @Test func rawSnapshotReplacesGameControllerValues() throws {
        let controller = GCController.withExtendedGamepad()
        let key = ObjectIdentifier(controller)
        let state = NativeGamepadPollState()
        state.cachedControllers = [controller]
        state.controllerSlots = [key: 0]
        state.hidSnapshots = { [key: ControllerInputSnapshot(leftStickX: 0.03, inputSource: .gamepadAPI)] }
        _ = state.configureMappings([key: NativeControllerMappingConfiguration(deviceID: "test-native", playerIndex: 0, profile: nil)])
        let captured = OSAllocatedUnfairLock(initialState: [UserInputEvent]())
        state.pollAndEmit(onEvents: { events in captured.withLock { $0 += events } }, onBatteryChange: { _ in })
        let gamepadState = captured.withLock { $0 }.compactMap { event -> GamepadState? in
            if case .gamepad(let state) = event { state } else { nil }
        }.last
        #expect(gamepadState?.leftStickX == 0.03)
        // The source travels with the values, so the wire can decide per pad.
        #expect(gamepadState?.inputSource == .gamepadAPI)
    }

    /// The deadzone is a property of the pad, not of the app-wide preference: with Gamepad API
    /// selected, a Steam Controller and a wired Xbox pad are still read through their own paths
    /// and must keep the only deadzone they get.
    @Test func theClientDeadzoneIsDecidedPerPad() {
        let state = GamepadState(deviceID: "pad", playerIndex: 0, leftStickX: 0.1, rightStickY: -1, timestamp: MediaTimestamp(nanoseconds: 0))
        let framework = NvstBifrostFreeTransport.wireSticks(state, source: .appleFramework)
        #expect(framework.leftX == 0)
        #expect(framework.rightY == -1)
        let steam = NvstBifrostFreeTransport.wireSticks(state, source: .steamHID)
        #expect(steam.leftX == 0)
        #expect(steam.rightY == -1)
        let raw = NvstBifrostFreeTransport.wireSticks(state, source: .gamepadAPI)
        #expect(raw.leftX == 0.1)
        #expect(raw.rightY == -1)
    }

    @Test func onlyTheGamepadAPIReaderSkipsTheClientDeadzone() {
        #expect(ControllerInputSource.allCases.filter(\.appliesClientDeadzone) == [.appleFramework, .steamHID])
        #expect(!ControllerInputSource.gamepadAPI.appliesClientDeadzone)
    }

    @Test func aReadingOlderThanThePadStopsReportingExpires() {
        let now = DispatchTime.now()
        let reading = GamepadHIDReading(family: .dualSense, snapshot: ControllerInputSnapshot(), receivedAt: now)
        #expect(reading.isFresh(at: now))
        #expect(reading.isFresh(at: now + .milliseconds(400)))
        #expect(!reading.isFresh(at: now + GamepadHIDReading.maximumAge + .milliseconds(1)))
    }

    @Test func inputPathsReportTheFrameworkForAnUnpairedController() throws {
        let suite = "GamepadHIDPollTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitor = NativeGamepadMonitor(mappingProvider: ControllerMappingStore(defaults: defaults))
        let controller = GCController.withExtendedGamepad()
        monitor.pollState.cachedControllers = [controller]
        monitor.pollState.controllerSlots = [ObjectIdentifier(controller): 1]
        let paths = monitor.inputPaths()
        #expect(paths.map(\.playerIndex) == [1])
        #expect(paths.map(\.source) == [.appleFramework])
    }

    @Test func stickOutputShowsSignedValues() {
        #expect(NativeNVSTHostViewModel.stickOutputText((0.032, -0.021, 0, 1)) == "L +0.032 -0.021   R +0.000 +1.000")
    }

    @Test func backendPreferenceDefaultsToAppleFramework() throws {
        let suite = "GamepadHIDPollTests.BackendPreference.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = OPNAppPreferenceStorage(defaults: defaults, defaultsDomain: suite)
        // The name says what it asserts: on a store nothing has written to, the default is the
        // protected path. The label/rawValue checks below are a separate contract.
        #expect(ControllerInputBackendPreference.load(from: storage) == .appleFramework)
        ControllerInputBackendPreference.save(.gamepadAPI, to: storage)
        #expect(ControllerInputBackendPreference.load(from: storage) == .gamepadAPI)
        #expect(ControllerInputBackend(rawValue: "unknown") == nil)
        #expect(ControllerInputBackend.allCases.map(\.label) == ["Apple Framework", "Gamepad API"])
    }
}
