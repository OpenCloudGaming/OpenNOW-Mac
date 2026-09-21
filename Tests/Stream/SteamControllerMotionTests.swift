import Foundation
import Testing
@testable import OpenNOW

private let gyroDevice: InputDeviceID = "gyro-controller"
private let gyroStamp = MediaTimestamp(nanoseconds: 0)
private let gyroClock = ContinuousClock()

/// A 54-byte report `0x42` with the button block and the IMU block at their documented offsets.
private func tritonMotionReport(buttons: UInt32 = 0,
                                gyro: (Int16, Int16, Int16) = (0, 0, 0),
                                accel: (Int16, Int16, Int16) = (0, 0, -2048),
                                sensorTick: UInt32 = 0,
                                reportID: UInt8 = 0x42) -> [UInt8] {
    var report = [UInt8](repeating: 0, count: 54)
    report[0] = reportID
    report[1] = 1
    report[2] = UInt8(buttons & 0xff)
    report[3] = UInt8((buttons >> 8) & 0xff)
    report[4] = UInt8((buttons >> 16) & 0xff)
    report[5] = UInt8((buttons >> 24) & 0xff)
    // Report 0x47 inserts a 16-bit trackpad timestamp, shifting the pad and IMU blocks by two.
    let padOffset = reportID == 0x47 ? 20 : 18
    let motionOffset = padOffset + 12
    writeGyroInt16(&report, at: motionOffset, value: Int16(truncatingIfNeeded: sensorTick))
    writeGyroInt16(&report, at: motionOffset + 2, value: Int16(truncatingIfNeeded: sensorTick >> 16))
    writeGyroInt16(&report, at: motionOffset + 4, value: accel.0)
    writeGyroInt16(&report, at: motionOffset + 6, value: accel.1)
    writeGyroInt16(&report, at: motionOffset + 8, value: accel.2)
    writeGyroInt16(&report, at: motionOffset + 10, value: gyro.0)
    writeGyroInt16(&report, at: motionOffset + 12, value: gyro.1)
    writeGyroInt16(&report, at: motionOffset + 14, value: gyro.2)
    return report
}

private func writeGyroInt16(_ report: inout [UInt8], at index: Int, value: Int16) {
    let bits = UInt16(bitPattern: value)
    report[index] = UInt8(bits & 0xff)
    report[index + 1] = UInt8((bits >> 8) & 0xff)
}

private func tritonMotionSnapshot(_ report: [UInt8]) -> ControllerInputSnapshot? {
    guard case .state(let snapshot) = SteamControllerReport.parse(report,
                                                                 previous: ControllerInputSnapshot(),
                                                                 model: .triton) else { return nil }
    return snapshot
}

private func gyroGamepadState(in events: [UserInputEvent]) -> GamepadState? {
    for event in events { if case .gamepad(let state) = event { return state } }
    return nil
}

private func gyroMouseMovement(in events: [UserInputEvent]) -> (Int16, Int16)? {
    for event in events {
        if case .mouse(.moved(_, let dx, let dy, _)) = event { return (dx, dy) }
    }
    return nil
}

@Suite struct SteamControllerMotionReportTests {
    @Test func motionIsDormantInAnUnmodifiedReport() {
        // The firmware repeats the previous values verbatim with the IMU off, so an all-zero
        // motion block must read as "available but still", not as missing data.
        let snapshot = tritonMotionSnapshot(tritonMotionReport())
        #expect(snapshot?.motion != nil)
        #expect(snapshot?.motion?.gyroMagnitude == 0)
    }

    @Test func gyroIsDecodedFromTheDocumentedOffsets() {
        let raw: Int16 = 16384
        let snapshot = tritonMotionSnapshot(tritonMotionReport(gyro: (raw, 0, 0)))
        // ±2000 deg/s is the derived full scale (`SteamControllerReport.rate`): this pins the
        // conversion arithmetic, not the range. A differently measured range moves this expected
        // value without the parse being wrong.
        #expect(abs((snapshot?.motion?.gyroX ?? 0) - 1000) < 0.01)
    }

    @Test func accelerometerIsDecodedAlongside() {
        let snapshot = tritonMotionSnapshot(tritonMotionReport(accel: (0, 0, -32768)))
        #expect(snapshot?.motion?.accelZ == -32768)
    }

    @Test func sensorTickIsCarriedThrough() {
        let snapshot = tritonMotionSnapshot(tritonMotionReport(sensorTick: 0x0001_0203))
        #expect(snapshot?.motion?.timestampMicroseconds == 0x0001_0203)
    }

    @Test func timestampedReportShiftsTheMotionBlockToo() {
        let raw: Int16 = 16384
        let snapshot = tritonMotionSnapshot(tritonMotionReport(gyro: (0, raw, 0), reportID: 0x47))
        #expect(abs((snapshot?.motion?.gyroY ?? 0) - 1000) < 0.01)
    }

    /// The `0x45` block is captured nowhere in this repository: motion is decoded by shifting the
    /// `0x42` layout one motion block along. This pins that derivation, not a measured BLE layout —
    /// the end-to-end hardware pass did not cover it separately.
    @Test func bleReportIsDecodedFromTheDerivedWiredLayout() {
        let raw: Int16 = 16384
        let snapshot = tritonMotionSnapshot(tritonMotionReport(gyro: (0, 0, raw), reportID: 0x45))
        #expect(abs((snapshot?.motion?.gyroZ ?? 0) - 1000) < 0.01)
    }

    @Test func gripSenseBitsBecomeCapacitiveFlagsNotButtons() {
        let left = tritonMotionSnapshot(tritonMotionReport(buttons: 0x2000_0000))
        #expect(left?.leftGripSense == true)
        #expect(left?.rightGripSense == false)
        // Grip Sense is contact, not a press: it must never leak into the forwarded button set.
        #expect(left?.buttons.isEmpty == true)

        let right = tritonMotionSnapshot(tritonMotionReport(buttons: 0x1000_0000))
        #expect(right?.rightGripSense == true)
    }

    @Test func thumbstickTouchBitsBecomeFlagsNotButtons() {
        let left = tritonMotionSnapshot(tritonMotionReport(buttons: 0x0100_0000))
        #expect(left?.leftStickTouched == true)
        #expect(left?.buttons.isEmpty == true)

        let right = tritonMotionSnapshot(tritonMotionReport(buttons: 0x0010_0000))
        #expect(right?.rightStickTouched == true)
    }

    @Test func rearGripButtonsRemainDistinctFromGripSense() {
        let snapshot = tritonMotionSnapshot(tritonMotionReport(buttons: 0x0002_0000))
        #expect(snapshot?.buttons.contains(.leftGrip) == true)
        #expect(snapshot?.leftGripSense == false)
    }

    @Test func motionReportingEnableUsesTheSettingsRegister() {
        let enable = SteamControllerReport.tritonMotionReportingReports(enabled: true)
        #expect(enable.count == 1)
        let bytes = enable[0].bytes
        #expect(bytes[0] == 0x01)
        #expect(bytes[1] == 0x87)
        #expect(bytes[2] == 0x03)
        #expect(bytes[3] == 48)
        #expect(bytes[4] == 0x18)
        #expect(bytes[5] == 0x00)

        let disable = SteamControllerReport.tritonMotionReportingReports(enabled: false)
        #expect(disable[0].bytes[4] == 0x00)
    }

    @Test func onlyThe2026ControllerCanSwitchMotionReporting() {
        #expect(SteamControllerReport.supportsMotionReporting(model: .triton))
        #expect(SteamControllerReport.supportsMotionReporting(model: .legacy) == false)
    }
}

@Suite struct ControllerBindingEngineGyroTests {
    private func stickProfile(_ configure: (inout ControllerGyroSettings) -> Void = { _ in }) -> ControllerMappingProfile {
        var profile = ControllerMappingProfile(name: "Gyro Stick", family: .steam)
        var settings = ControllerGyroSettings(mode: .joystickCamera,
                                              activationStyle: .always,
                                              conversion: .yaw,
                                              smoothing: 0,
                                              speedDeadzoneDegreesPerSecond: 0,
                                              precisionZoneDegreesPerSecond: 0,
                                              joystickPowerCurve: 1,
                                              antiDeadzone: 0,
                                              maxTurnRateDegreesPerSecond: 200)
        configure(&settings)
        profile.gyro = settings
        return profile
    }

    private func snapshot(gyroY: Float = 0,
                          gripSense: Bool = false,
                          rightStickX: Float = 0,
                          motion: Bool = true) -> ControllerInputSnapshot {
        ControllerInputSnapshot(rightStickX: rightStickX,
                                rightGripSense: gripSense,
                                motion: motion ? ControllerMotionSample(gyroY: gyroY, accelZ: -2048) : nil)
    }

    @Test func gyroStickOutputReachesTheForwardedRightStick() {
        var engine = ControllerBindingEngine()
        let result = engine.applyDiscreteControls(profile: stickProfile(),
                                                 snapshot: snapshot(gyroY: 100),
                                                 deviceID: gyroDevice,
                                                 playerIndex: 0,
                                                 now: gyroClock.now,
                                                 timestamp: gyroStamp)
        let state = gyroGamepadState(in: result.events)
        #expect(abs((state?.rightStickX ?? 0) - 0.5) < 0.001)
    }

    @Test func gyroIsSummedWithThePhysicalStickRatherThanReplacingIt() {
        var engine = ControllerBindingEngine()
        let result = engine.applyDiscreteControls(profile: stickProfile(),
                                                 snapshot: snapshot(gyroY: 100, rightStickX: 0.25),
                                                 deviceID: gyroDevice,
                                                 playerIndex: 0,
                                                 now: gyroClock.now,
                                                 timestamp: gyroStamp)
        let state = gyroGamepadState(in: result.events)
        #expect(abs((state?.rightStickX ?? 0) - 0.75) < 0.001)
    }

    @Test func summedStickIsClampedToTheWireRange() {
        var engine = ControllerBindingEngine()
        let result = engine.applyDiscreteControls(profile: stickProfile(),
                                                 snapshot: snapshot(gyroY: 400, rightStickX: 0.9),
                                                 deviceID: gyroDevice,
                                                 playerIndex: 0,
                                                 now: gyroClock.now,
                                                 timestamp: gyroStamp)
        #expect(gyroGamepadState(in: result.events)?.rightStickX == 1)
    }

    @Test func mouseModeEmitsMouseMovementAndLeavesTheStickAlone() {
        var engine = ControllerBindingEngine()
        var profile = stickProfile()
        profile.gyro.mode = .mouse
        let result = engine.applyDiscreteControls(profile: profile,
                                                 snapshot: snapshot(gyroY: 100),
                                                 deviceID: gyroDevice,
                                                 playerIndex: 0,
                                                 now: gyroClock.now,
                                                 timestamp: gyroStamp)
        #expect((gyroMouseMovement(in: result.events)?.0 ?? 0) > 0)
        #expect(gyroGamepadState(in: result.events)?.rightStickX == 0)
    }

    @Test func gatedGyroStaysSilentUntilTheGripIsHeld() {
        var engine = ControllerBindingEngine()
        var profile = stickProfile { $0.activationStyle = .hold; $0.activationSource = .gripSenseEither }
        let idle = engine.applyDiscreteControls(profile: profile,
                                               snapshot: snapshot(gyroY: 400),
                                               deviceID: gyroDevice,
                                               playerIndex: 0,
                                               now: gyroClock.now,
                                               timestamp: gyroStamp)
        #expect(gyroGamepadState(in: idle.events)?.rightStickX == 0)

        let held = engine.applyDiscreteControls(profile: profile,
                                                snapshot: snapshot(gyroY: 400, gripSense: true),
                                                deviceID: gyroDevice,
                                                playerIndex: 0,
                                                now: gyroClock.now,
                                                timestamp: gyroStamp)
        #expect((gyroGamepadState(in: held.events)?.rightStickX ?? 0) > 0)
    }

    @Test func motionlessSnapshotFromAGyroProfileOutputsNothing() {
        var engine = ControllerBindingEngine()
        let result = engine.applyDiscreteControls(profile: stickProfile(),
                                                 snapshot: snapshot(motion: false),
                                                 deviceID: gyroDevice,
                                                 playerIndex: 0,
                                                 now: gyroClock.now,
                                                 timestamp: gyroStamp)
        #expect(gyroGamepadState(in: result.events)?.rightStickX == 0)
    }

    @Test func gyroOffProfileIsCompletelyInert() {
        var engine = ControllerBindingEngine()
        var profile = stickProfile()
        profile.gyro.mode = .off
        let result = engine.applyDiscreteControls(profile: profile,
                                                 snapshot: snapshot(gyroY: 400),
                                                 deviceID: gyroDevice,
                                                 playerIndex: 0,
                                                 now: gyroClock.now,
                                                 timestamp: gyroStamp)
        #expect(gyroGamepadState(in: result.events)?.rightStickX == 0)
    }

    @Test func gripSenseCanBeBoundLikeAnyOtherControl() {
        var engine = ControllerBindingEngine()
        let profile = ControllerMappingProfile(name: "Bound",
                                               family: .steam,
                                               bindings: [.rightGripSense: .keyboardKey(keyCode: 42, modifiers: [])])
        let result = engine.applyDiscreteControls(profile: profile,
                                                 snapshot: snapshot(gripSense: true),
                                                 deviceID: gyroDevice,
                                                 playerIndex: 0,
                                                 now: gyroClock.now,
                                                 timestamp: gyroStamp)
        let pressed = result.events.contains { event in
            if case .keyboard(let key) = event { return key.keyCode == 42 && key.isPressed }
            return false
        }
        #expect(pressed)
    }

    @Test func flickStickOwnsTheRightStickAndNeverForwardsIt() {
        var engine = ControllerBindingEngine()
        var profile = stickProfile()
        profile.gyro.mode = .off
        profile.rightStick = ControllerPadSettings(mode: .flickStick)
        let forward = engine.applyDiscreteControls(profile: profile,
                                                  snapshot: snapshot(rightStickX: 0.8, motion: false),
                                                  deviceID: gyroDevice,
                                                  playerIndex: 0,
                                                  now: gyroClock.now,
                                                  timestamp: gyroStamp)
        #expect(gyroGamepadState(in: forward.events)?.rightStickX == 0)
    }
}
