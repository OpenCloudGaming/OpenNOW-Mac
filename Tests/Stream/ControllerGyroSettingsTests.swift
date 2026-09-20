import Foundation
import Testing
@testable import OpenNOW

@Suite struct ControllerGyroSettingsTests {
    @Test func roundTripPreservesEverySetting() throws {
        var settings = ControllerGyroSettings(mode: .mouse,
                                              activationStyle: .toggle,
                                              activationSource: .gripSenseLeft,
                                              sensitivity: 2.5,
                                              verticalScale: 0.4,
                                              horizontalScale: 1.3,
                                              invertX: true,
                                              invertY: true,
                                              useNaturalSensitivity: false,
                                              pixelsPer360: 1440,
                                              conversion: .worldSpace,
                                              smoothing: 0.7,
                                              speedDeadzoneDegreesPerSecond: 3.5,
                                              precisionZoneDegreesPerSecond: 11,
                                              momentumHorizontal: 0.25,
                                              momentumVertical: 0.1,
                                              joystickPowerCurve: 1.8,
                                              antiDeadzone: 0.2,
                                              maxTurnRateDegreesPerSecond: 300,
                                              catchUp: false,
                                              lockExtents: true,
                                              deflectionAngleDegrees: 90,
                                              flickStickSensitivity: 1.4,
                                              flickStickSnap: false,
                                              flickStickActivationThreshold: 0.6,
                                              calibrationMode: .manual,
                                              biasX: 0.5,
                                              biasY: -0.25,
                                              biasZ: 0.125)
        settings.activationSource = .control(.rightGrip2)

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ControllerGyroSettings.self, from: data)
        #expect(decoded == settings)
    }

    @Test func activationControlSurvivesTheKindAndControlSplit() throws {
        let settings = ControllerGyroSettings(activationSource: .control(.leftShoulder))
        let data = try JSONEncoder().encode(settings)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("leftShoulder"))
        let decoded = try JSONDecoder().decode(ControllerGyroSettings.self, from: data)
        #expect(decoded.activationSource == .control(.leftShoulder))
    }

    @Test func missingKeysDecodeToDefaults() throws {
        let decoded = try JSONDecoder().decode(ControllerGyroSettings.self, from: Data("{}".utf8))
        #expect(decoded == ControllerGyroSettings())
        #expect(decoded.mode == .off)
        #expect(decoded.activationSource == .gripSenseEither)
    }

    @Test func unknownActivationKindFallsBackInsteadOfThrowing() throws {
        let decoded = try JSONDecoder().decode(ControllerGyroSettings.self,
                                               from: Data(#"{"activationSource":"fromTheFuture"}"#.utf8))
        #expect(decoded.activationSource == ControllerGyroSettings().activationSource)
    }

    @Test func initClampsOutOfRangeValues() {
        let settings = ControllerGyroSettings(sensitivity: -4,
                                              verticalScale: 99,
                                              horizontalScale: 0,
                                              pixelsPer360: 1_000_000,
                                              smoothing: 5,
                                              joystickPowerCurve: 0,
                                              antiDeadzone: 9,
                                              maxTurnRateDegreesPerSecond: 1)
        #expect(settings.sensitivity > 0)
        #expect(settings.verticalScale <= 4)
        #expect(settings.horizontalScale > 0)
        #expect(settings.pixelsPer360 == ControllerGyroSettings.maximumPixelsPer360)
        #expect(settings.smoothing == 1)
        #expect(settings.antiDeadzone <= 0.6)
        #expect(settings.joystickPowerCurve >= 0.25)
        #expect(settings.maxTurnRateDegreesPerSecond >= 10)
    }

    @Test func decodingClampsBecausePropertyAssignmentBypassesInit() throws {
        let decoded = try JSONDecoder().decode(ControllerGyroSettings.self,
                                               from: Data(#"{"smoothing":42}"#.utf8))
        #expect(decoded.smoothing == 1)
    }

    @Test func profileWithoutGyroKeyLoadsWithGyroOff() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","name":"Legacy","family":"steam"}
        """
        let profile = try JSONDecoder().decode(ControllerMappingProfile.self, from: Data(legacy.utf8))
        #expect(profile.gyro == ControllerGyroSettings())
        #expect(profile.gyro.isEnabled == false)
    }

    @Test func profileRoundTripCarriesGyroSettings() throws {
        var profile = ControllerMappingProfile(name: "Gyro")
        profile.gyro.mode = .mouse
        profile.gyro.pixelsPer360 = 1234
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ControllerMappingProfile.self, from: data)
        #expect(decoded.gyro.mode == .mouse)
        #expect(decoded.gyro.pixelsPer360 == 1234)
    }

    @Test func motionReportingIsOnlyRequestedWhenGyroIsOn() {
        var profile = ControllerMappingProfile(name: "Idle")
        #expect(profile.gyro.needsMotionReporting == false)
        profile.gyro.mode = .joystickCamera
        #expect(profile.gyro.needsMotionReporting)
    }

    @Test func rightStickIsSharedOnlyByTheStickModes() {
        #expect(ControllerGyroSettings(mode: .joystickCamera).drivesRightStick)
        #expect(ControllerGyroSettings(mode: .joystickDeflection).drivesRightStick)
        #expect(ControllerGyroSettings(mode: .mouse).drivesRightStick == false)
        #expect(ControllerGyroSettings(mode: .off).drivesRightStick == false)
    }
}
