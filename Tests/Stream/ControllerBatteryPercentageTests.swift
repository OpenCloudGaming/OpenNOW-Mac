import GameController
import Testing
@testable import OpenNOW

@Suite struct ControllerBatteryPercentageTests {
    @Test func unknownStateDoesNotReportAnEmptyBattery() {
        #expect(ControllerBatteryInfo.percentage(level: 0, state: .unknown) == nil)
        #expect(ControllerBatteryInfo.percentage(level: 0.5, state: .unknown) == nil)
    }

    @Test func knownStatesPreserveValidReadings() {
        #expect(ControllerBatteryInfo.percentage(level: 0, state: .discharging) == 0)
        #expect(ControllerBatteryInfo.percentage(level: 0.75, state: .discharging) == 75)
        #expect(ControllerBatteryInfo.percentage(level: 0.5, state: .charging) == 50)
        #expect(ControllerBatteryInfo.percentage(level: 1, state: .full) == 100)
    }

    @Test(arguments: [Float.nan, Float.infinity, -Float.infinity, -1, 1.1])
    func invalidLevelsRemainUnknown(level: Float) {
        #expect(ControllerBatteryInfo.percentage(level: level, state: .discharging) == nil)
    }
}
