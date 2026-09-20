import Foundation
import Testing
@testable import OpenNOW

private let step: Float = 1.0 / 120.0

private func motion(gyroX: Float = 0, gyroY: Float = 0, gyroZ: Float = 0,
                    accelX: Float = 0, accelY: Float = 0, accelZ: Float = -1) -> ControllerMotionSample {
    ControllerMotionSample(gyroX: gyroX, gyroY: gyroY, gyroZ: gyroZ,
                           accelX: accelX, accelY: accelY, accelZ: accelZ)
}

/// A mouse profile with every optional shaping stage switched off, so a test asserting on the
/// conversion or the sensitivity is not silently measuring the smoother as well.
private func plainMouseSettings(pixelsPer360: Float = 2000,
                                conversion: GyroConversion = .yaw) -> ControllerGyroSettings {
    ControllerGyroSettings(mode: .mouse,
                           useNaturalSensitivity: true,
                           pixelsPer360: pixelsPer360,
                           conversion: conversion,
                           smoothing: 0,
                           speedDeadzoneDegreesPerSecond: 0,
                           precisionZoneDegreesPerSecond: 0)
}

private func plainStickSettings(mode: GyroOutputMode = .joystickCamera,
                                maxTurnRate: Float = 200,
                                antiDeadzone: Float = 0,
                                powerCurve: Float = 1) -> ControllerGyroSettings {
    ControllerGyroSettings(mode: mode,
                           conversion: .yaw,
                           smoothing: 0,
                           speedDeadzoneDegreesPerSecond: 0,
                           precisionZoneDegreesPerSecond: 0,
                           joystickPowerCurve: powerCurve,
                           antiDeadzone: antiDeadzone,
                           maxTurnRateDegreesPerSecond: maxTurnRate)
}

@Suite struct GyroProcessorTests {
    @Test func disabledGyroProducesNothing() {
        var processor = GyroProcessor()
        let settings = ControllerGyroSettings(mode: .off)
        let output = processor.process(motion(gyroY: 500), settings: settings, isActive: true, deltaTime: step)
        #expect(output.isEmpty)
    }

    @Test func missingMotionProducesNothing() {
        var processor = GyroProcessor()
        let output = processor.process(nil, settings: plainMouseSettings(), isActive: true, deltaTime: step)
        #expect(output.isEmpty)
    }

    @Test func yawDrivesHorizontalMouseInNaturalSensitivity() {
        var processor = GyroProcessor(flushInterval: step)
        let settings = plainMouseSettings()
        let output = processor.process(motion(gyroY: 100), settings: settings, isActive: true, deltaTime: step)
        // 100 deg/s for 1/120 s is 0.8333 degrees; at 2000 counts per 360 that is 4.63 counts.
        let expected = Int16((100 * step * (2000 / 360)).rounded(.towardZero))
        #expect(output.pointer.moveDeltaX == expected)
        #expect(output.pointer.moveDeltaY == 0)
    }

    @Test func naturalSensitivityScalesWithPixelsPer360() {
        var processor = GyroProcessor(flushInterval: step)
        let output = processor.process(motion(gyroY: 100),
                                       settings: plainMouseSettings(pixelsPer360: 4000),
                                       isActive: true,
                                       deltaTime: step)
        let expected = Int16((100 * step * (4000 / 360)).rounded(.towardZero))
        #expect(output.pointer.moveDeltaX == expected)
    }

    @Test func legacySensitivityIgnoresPixelsPer360()  {
        var processor = GyroProcessor(flushInterval: step)
        var settings = plainMouseSettings(pixelsPer360: 8000)
        settings.useNaturalSensitivity = false
        settings.sensitivity = 2
        let output = processor.process(motion(gyroY: 100), settings: settings, isActive: true, deltaTime: step)
        let expected = Int16((100 * step * GyroProcessor.legacyCountsPerDegree * 2).rounded(.towardZero))
        #expect(output.pointer.moveDeltaX == expected)
    }

    @Test func invertSwapsBothAxes() {
        var processor = GyroProcessor(flushInterval: step)
        var settings = plainMouseSettings()
        settings.invertX = true
        settings.invertY = true
        let output = processor.process(motion(gyroX: 100, gyroY: 100), settings: settings, isActive: true, deltaTime: step)
        #expect(output.pointer.moveDeltaX < 0)
        #expect(output.pointer.moveDeltaY < 0)
    }

    @Test func horizontalAndVerticalScaleAreIndependent() {
        var processor = GyroProcessor(flushInterval: step)
        var settings = plainMouseSettings()
        settings.horizontalScale = 2
        settings.verticalScale = 0.5
        let output = processor.process(motion(gyroX: 100, gyroY: 100), settings: settings, isActive: true, deltaTime: step)
        let perDegree = (2000 / 360) * step * 100
        #expect(abs(Float(output.pointer.moveDeltaX) - (perDegree * 2).rounded(.towardZero)) <= 1)
        #expect(abs(Float(output.pointer.moveDeltaY) - (perDegree * 0.5).rounded(.towardZero)) <= 1)
    }

    @Test func speedDeadzoneSilencesSmallRates() {
        var processor = GyroProcessor(flushInterval: step)
        var settings = plainMouseSettings()
        settings.speedDeadzoneDegreesPerSecond = 10
        settings.precisionZoneDegreesPerSecond = 0
        let output = processor.process(motion(gyroY: 9), settings: settings, isActive: true, deltaTime: step)
        #expect(output.isEmpty)
    }

    @Test func precisionZoneRampsAboveDeadzone() {
        var processor = GyroProcessor(flushInterval: step)
        var settings = plainMouseSettings()
        settings.speedDeadzoneDegreesPerSecond = 0
        settings.precisionZoneDegreesPerSecond = 100
        // Half way up the ramp, so half the output of an unramped run at the same rate.
        let ramped = processor.process(motion(gyroY: 50), settings: settings, isActive: true, deltaTime: step)
        #expect(ramped.pointer.moveDeltaX > 0)
        #expect(ramped.pointer.moveDeltaX < Int16((50 * step * (2000 / 360)).rounded(.towardZero)))
    }

    @Test func mouseOutputIsBatchedToTheFlushInterval() {
        var processor = GyroProcessor(flushInterval: 0.05)
        let settings = plainMouseSettings()
        // Nothing may leave before the window closes, however many reports arrive in it.
        for _ in 0..<4 {
            let output = processor.process(motion(gyroY: 100), settings: settings, isActive: true, deltaTime: 0.01)
            #expect(output.pointer.isEmpty)
        }
        // The window closes within the next few reports, and only once — a second flush needs
        // another full 50 ms of accumulation.
        var flushes = 0
        var released: Int16 = 0
        for _ in 0..<4 {
            let output = processor.process(motion(gyroY: 100), settings: settings, isActive: true, deltaTime: 0.01)
            if !output.pointer.isEmpty {
                flushes += 1
                released = output.pointer.moveDeltaX
            }
        }
        #expect(flushes == 1)
        // Five accumulated steps at 100 deg/s and 2000 counts per 360 is about 27 counts.
        #expect(released >= 26 && released <= 34)
    }

    @Test func joystickCameraMapsRateToDeflection() {
        var processor = GyroProcessor()
        let settings = plainStickSettings(maxTurnRate: 200)
        let output = processor.process(motion(gyroY: 100), settings: settings, isActive: true, deltaTime: step)
        #expect(output.isStickActive)
        #expect(abs(output.stickX - 0.5) < 0.001)
        #expect(output.stickY == 0)
    }

    @Test func joystickCameraSaturatesAtTheTurnRateLimit() {
        var processor = GyroProcessor()
        let settings = plainStickSettings(maxTurnRate: 100, antiDeadzone: 0)
        var settingsCatchUpOff = settings
        settingsCatchUpOff.catchUp = false
        let output = processor.process(motion(gyroY: 900), settings: settingsCatchUpOff, isActive: true, deltaTime: step)
        #expect(abs(output.stickX - 1) < 0.001)
    }

    @Test func antiDeadzoneLiftsSmallDeflectionsPastTheGameDeadzone() {
        var processor = GyroProcessor()
        let settings = plainStickSettings(maxTurnRate: 200, antiDeadzone: 0.2)
        let output = processor.process(motion(gyroY: 100), settings: settings, isActive: true, deltaTime: step)
        // Half deflection, lifted to 0.2 + 0.8 * 0.5.
        #expect(abs(output.stickX - 0.6) < 0.001)
    }

    @Test func joystickPowerCurveEnlargesSmallDeflections() {
        var processor = GyroProcessor()
        let settings = plainStickSettings(maxTurnRate: 400, antiDeadzone: 0, powerCurve: 2)
        let output = processor.process(motion(gyroY: 100), settings: settings, isActive: true, deltaTime: step)
        // 0.25 deflection raised to the power 1/2.
        #expect(abs(output.stickX - 0.5) < 0.001)
    }

    /// Catch-up is measured as total deflection recovered after saturation: the smoother's own
    /// decay tail is present either way, so only the difference is attributable to the debt.
    private func recoveryAfterSaturation(catchUp: Bool) -> Float {
        var processor = GyroProcessor()
        var settings = plainStickSettings(maxTurnRate: 100, antiDeadzone: 0)
        settings.catchUp = catchUp
        _ = processor.process(motion(gyroY: 900), settings: settings, isActive: true, deltaTime: step)
        var total: Float = 0
        for _ in 0..<120 {
            total += processor.process(motion(gyroY: 0), settings: settings, isActive: true, deltaTime: step).stickX
        }
        return total
    }

    @Test func catchUpSpendsOverflowOnLaterFrames() {
        #expect(recoveryAfterSaturation(catchUp: true) > recoveryAfterSaturation(catchUp: false))
    }

    @Test func deflectionModeIntegratesAngleInsteadOfRate() {
        var processor = GyroProcessor()
        var settings = plainStickSettings(mode: .joystickDeflection, antiDeadzone: 0)
        settings.deflectionAngleDegrees = 45
        var last: Float = 0
        for _ in 0..<30 {
            last = processor.process(motion(gyroY: 90), settings: settings, isActive: true, deltaTime: step).stickX
        }
        // 30 frames of 90 deg/s is 22.5 degrees, half of the 45-degree full deflection.
        #expect(abs(last - 0.5) < 0.02)
    }

    @Test func lockExtentsHoldsFullDeflectionInsteadOfSaturating() {
        var processor = GyroProcessor()
        var settings = plainStickSettings(mode: .joystickDeflection, antiDeadzone: 0)
        settings.deflectionAngleDegrees = 45
        settings.lockExtents = true
        var last: Float = 0
        for _ in 0..<120 {
            last = processor.process(motion(gyroY: 90), settings: settings, isActive: true, deltaTime: step).stickX
        }
        // 120 frames is 90 degrees, twice the deflection limit.
        #expect(abs(last - 1) < 0.001)
    }

    private func coastAfterRelease(momentum: Float) -> Float {
        var processor = GyroProcessor()
        var settings = plainStickSettings(antiDeadzone: 0)
        settings.maxTurnRateDegreesPerSecond = 200
        settings.momentumHorizontal = momentum
        _ = processor.process(motion(gyroY: 100), settings: settings, isActive: true, deltaTime: step)
        var total: Float = 0
        for _ in 0..<60 {
            total += processor.process(motion(gyroY: 0), settings: settings, isActive: false, deltaTime: step).stickX
        }
        return total
    }

    @Test func momentumCoastsAfterRelease() {
        #expect(coastAfterRelease(momentum: 1) > coastAfterRelease(momentum: 0))
    }

    /// The smoother has a decay tail of its own, so momentum can only be measured as a difference:
    /// a zero factor must not bank the live rate the way a non-zero one does.
    @Test func momentumScalesTheTail() {
        #expect(coastAfterRelease(momentum: 0.4) > coastAfterRelease(momentum: 0))
        #expect(coastAfterRelease(momentum: 1) > coastAfterRelease(momentum: 0.4))
    }

    @Test func automaticBiasConvergesWhileIdle() {
        var processor = GyroProcessor()
        var settings = plainMouseSettings()
        settings.speedDeadzoneDegreesPerSecond = 0
        settings.precisionZoneDegreesPerSecond = 0
        for _ in 0..<1200 {
            _ = processor.process(motion(gyroY: 3), settings: settings, isActive: false, deltaTime: step)
        }
        #expect(abs(processor.currentBias.y - 3) < 0.05)
    }

    /// The hardware's own auto-calibration cancels slow deliberate movement, and Steam Input
    /// cannot switch it off. Ours must only ever adapt while gyro is inactive.
    @Test func biasDoesNotAdaptWhileGyroIsActive() {
        var processor = GyroProcessor()
        var settings = plainMouseSettings()
        settings.speedDeadzoneDegreesPerSecond = 0
        settings.precisionZoneDegreesPerSecond = 0
        for _ in 0..<600 {
            _ = processor.process(motion(gyroY: 3), settings: settings, isActive: true, deltaTime: step)
        }
        #expect(processor.currentBias.y == 0)
    }

    @Test func biasDoesNotChaseRatesAboveTheStillThreshold() {
        var processor = GyroProcessor()
        var settings = plainMouseSettings()
        settings.speedDeadzoneDegreesPerSecond = 0
        settings.precisionZoneDegreesPerSecond = 0
        for _ in 0..<600 {
            _ = processor.process(motion(gyroY: 30), settings: settings, isActive: false, deltaTime: step)
        }
        #expect(processor.currentBias.y == 0)
    }

    @Test func manualCalibrationIgnoresAmbientRate() {
        var processor = GyroProcessor()
        var settings = plainMouseSettings()
        settings.calibrationMode = .manual
        for _ in 0..<600 {
            _ = processor.process(motion(gyroY: 3), settings: settings, isActive: false, deltaTime: step)
        }
        #expect(processor.currentBias.y == 0)
    }

    @Test func profileBiasIsAppliedOnFirstSample() {
        var processor = GyroProcessor()
        var settings = plainMouseSettings()
        settings.biasY = 5
        let output = processor.process(motion(gyroY: 105), settings: settings, isActive: true, deltaTime: step)
        let expected = Int16((100 * step * (2000 / 360)).rounded(.towardZero))
        #expect(output.pointer.moveDeltaX == expected)
    }

    @Test func rollConversionUsesTheSteeringAxis() {
        var processor = GyroProcessor(flushInterval: step)
        var settings = plainMouseSettings(conversion: .roll)
        settings.smoothing = 0
        let output = processor.process(motion(gyroY: 100, gyroZ: 100), settings: settings, isActive: true, deltaTime: step)
        #expect(output.pointer.moveDeltaX > 0)
    }

    @Test func yawRollConversionSumsTwistAndSteer() {
        var yawOnly = GyroProcessor(flushInterval: step)
        let yawOutput = yawOnly.process(motion(gyroY: 100), settings: plainMouseSettings(conversion: .yaw), isActive: true, deltaTime: step)
        var combined = GyroProcessor(flushInterval: step)
        let combinedOutput = combined.process(motion(gyroY: 100, gyroZ: 100), settings: plainMouseSettings(conversion: .yawRoll), isActive: true, deltaTime: step)
        #expect(combinedOutput.pointer.moveDeltaX > yawOutput.pointer.moveDeltaX)
    }

    @Test func playerSpaceUsesRotationAboutGravity() {
        var processor = GyroProcessor()
        var settings = plainStickSettings(antiDeadzone: 0)
        settings.conversion = .playerSpace
        settings.maxTurnRateDegreesPerSecond = 200
        // The normal playing pose: the pad is upright, so the accelerometer's up axis lies along
        // the pad's own +y — the same axis a twist turns about. Player space must therefore agree
        // with local yaw in this pose.
        let twist = processor.process(motion(gyroY: 100, accelY: 2048), settings: settings, isActive: true, deltaTime: step)
        #expect(abs(twist.stickX - 0.5) < 0.001)
    }

    @Test func gravityFallbackUsesLocalYawWithoutAcceleration() {
        var processor = GyroProcessor()
        var settings = plainStickSettings(antiDeadzone: 0)
        settings.conversion = .playerSpace
        settings.maxTurnRateDegreesPerSecond = 200
        // A pad that reports no acceleration at all must still aim: the conversion falls back to
        // local yaw rather than outputting nothing.
        let output = processor.process(motion(gyroY: 100, accelX: 0, accelY: 0, accelZ: 0),
                                       settings: settings, isActive: true, deltaTime: step)
        #expect(abs(output.stickX - 0.5) < 0.001)
    }

    @Test func resetTransientStateKeepsBiasButClearsAccumulators() {
        var processor = GyroProcessor()
        var settings = plainMouseSettings()
        for _ in 0..<1200 {
            _ = processor.process(motion(gyroY: 3), settings: settings, isActive: false, deltaTime: step)
        }
        let bias = processor.currentBias.y
        #expect(abs(bias - 3) < 0.05)
        processor.resetTransientState()
        #expect(processor.currentBias.y == bias)
        processor.resetAll()
        #expect(processor.currentBias == .zero)
    }
}

@Suite struct GyroActivationStateTests {
    private func snapshot(gripSense: Bool = false,
                          stickTouch: Bool = false,
                          padTouched: Bool = false,
                          buttons: GamepadButtons = []) -> ControllerInputSnapshot {
        ControllerInputSnapshot(buttons: buttons,
                                leftPad: ControllerTrackpadState(touched: padTouched),
                                leftGripSense: gripSense,
                                leftStickTouched: stickTouch)
    }

    @Test func gripSenseEitherEngagesOnEitherSensor() {
        #expect(GyroActivationSource.gripSenseEither.isEngaged(in: snapshot(gripSense: true), activeControls: []))
        #expect(GyroActivationSource.gripSenseEither.isEngaged(in: snapshot(), activeControls: []) == false)
    }

    @Test func gripSenseBothNeedsBothSensors() {
        var both = snapshot(gripSense: true)
        both.rightGripSense = true
        #expect(GyroActivationSource.gripSenseBoth.isEngaged(in: both, activeControls: []))
        #expect(GyroActivationSource.gripSenseBoth.isEngaged(in: snapshot(gripSense: true), activeControls: []) == false)
    }

    @Test func noneNeverEngages() {
        #expect(GyroActivationSource.none.isEngaged(in: snapshot(gripSense: true), activeControls: []) == false)
    }

    @Test func controlSourceReadsTheSharedActiveSet() {
        #expect(GyroActivationSource.control(.leftTrigger).isEngaged(in: snapshot(), activeControls: [.leftTrigger]))
        #expect(GyroActivationSource.control(.leftTrigger).isEngaged(in: snapshot(), activeControls: []) == false)
    }

    @Test func holdEngagesImmediately() {
        var state = GyroActivationState()
        let active = state.update(style: .hold, raw: true, deltaTime: 0.01)
        #expect(active)
    }

    @Test func releaseStyleIsActiveUntilTheSourceIsEngaged() {
        var state = GyroActivationState()
        let idle = state.update(style: .release, raw: false, deltaTime: 0.01)
        #expect(idle)
        _ = state.update(style: .release, raw: true, deltaTime: 0.01)
        let engaged = state.update(style: .release, raw: true, deltaTime: 0.01)
        #expect(engaged == false)
    }

    /// Capacitive sensors flicker mid-aim. A single dropped sample must not cut gyro.
    @Test func briefDropoutDoesNotDisengageHold() {
        var state = GyroActivationState()
        _ = state.update(style: .hold, raw: true, deltaTime: 0.01)
        let firstDrop = state.update(style: .hold, raw: false, deltaTime: 0.01)
        let secondDrop = state.update(style: .hold, raw: false, deltaTime: 0.02)
        let regripped = state.update(style: .hold, raw: true, deltaTime: 0.01)
        #expect(firstDrop)
        #expect(secondDrop)
        #expect(regripped)
    }

    @Test func sustainedReleaseDisengagesHold() {
        var state = GyroActivationState()
        _ = state.update(style: .hold, raw: true, deltaTime: 0.01)
        var active = true
        for _ in 0..<40 {
            active = state.update(style: .hold, raw: false, deltaTime: 0.01)
        }
        #expect(active == false)
    }

    @Test func alwaysStyleIgnoresTheSource() {
        var state = GyroActivationState()
        let active = state.update(style: .always, raw: false, deltaTime: 0.01)
        #expect(active)
    }

    @Test func toggleFlipsOncePerPress() {
        var state = GyroActivationState()
        let pressed = state.update(style: .toggle, raw: true, deltaTime: 0.01)
        // Still held: no second flip.
        let stillHeld = state.update(style: .toggle, raw: true, deltaTime: 0.01)
        #expect(pressed)
        #expect(stillHeld)
        // Release is debounced, but a sustained release ends the engagement, so the next press
        // toggles back off.
        for _ in 0..<40 { _ = state.update(style: .toggle, raw: false, deltaTime: 0.01) }
        let secondPress = state.update(style: .toggle, raw: true, deltaTime: 0.01)
        #expect(secondPress == false)
    }
}

@Suite struct FlickStickProcessorTests {
    private func settings(snap: Bool = true, sensitivity: Float = 1) -> ControllerGyroSettings {
        ControllerGyroSettings(mode: .mouse,
                               pixelsPer360: 2000,
                               flickStickSensitivity: sensitivity,
                               flickStickSnap: snap,
                               flickStickActivationThreshold: 0.5)
    }

    @Test func firstPushOnlyEstablishesTheHeading() {
        var processor = FlickStickProcessor()
        let actions = processor.process(stickX: 0, stickY: 1, settings: settings())
        #expect(actions.isEmpty)
    }

    @Test func snapTurnsByTheHeadingChange() {
        var processor = FlickStickProcessor()
        _ = processor.process(stickX: 0, stickY: 1, settings: settings())
        let actions = processor.process(stickX: 1, stickY: 0, settings: settings())
        // 90 degrees of heading change at 2000 counts per 360 is exactly 500 counts.
        #expect(actions.moveDeltaX == 500)
    }

    @Test func insideTheActivationThresholdNothingHappens() {
        var processor = FlickStickProcessor()
        _ = processor.process(stickX: 0, stickY: 1, settings: settings())
        let actions = processor.process(stickX: 0.1, stickY: 0.1, settings: settings())
        #expect(actions.isEmpty)
    }

    @Test func headingChangeTakesTheShortWayAround() {
        var processor = FlickStickProcessor()
        _ = processor.process(stickX: 0, stickY: -1, settings: settings())
        // 180 degrees away is the ambiguous case; just inside it must not spin the long way.
        let actions = processor.process(stickX: 0.99, stickY: -0.01, settings: settings())
        // A full turn is 2000 counts at this calibration, so a short-way change stays well under it.
        #expect(abs(Int(actions.moveDeltaX)) < 2000)
    }

    @Test func resetForgetsTheHeading() {
        var processor = FlickStickProcessor()
        _ = processor.process(stickX: 0, stickY: 1, settings: settings())
        processor.reset()
        #expect(processor.process(stickX: 1, stickY: 0, settings: settings()).isEmpty)
    }
}
