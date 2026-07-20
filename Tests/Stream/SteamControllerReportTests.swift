import Foundation
import Testing
@testable import MacForceNow

private func inputReport(buttons: (UInt8, UInt8, UInt8) = (0, 0, 0),
                         leftTrigger: UInt8 = 0,
                         rightTrigger: UInt8 = 0,
                         leftPadX: Int16 = 0,
                         leftPadY: Int16 = 0,
                         rightPadX: Int16 = 0,
                         rightPadY: Int16 = 0) -> [UInt8] {
    var report = [UInt8](repeating: 0, count: SteamControllerReport.reportLength)
    report[0] = 0x01
    report[2] = 0x01
    report[3] = 0x3c
    report[8] = buttons.0
    report[9] = buttons.1
    report[10] = buttons.2
    report[11] = leftTrigger
    report[12] = rightTrigger
    writeInt16(&report, at: 16, value: leftPadX)
    writeInt16(&report, at: 18, value: leftPadY)
    writeInt16(&report, at: 20, value: rightPadX)
    writeInt16(&report, at: 22, value: rightPadY)
    return report
}

private func writeInt16(_ report: inout [UInt8], at index: Int, value: Int16) {
    let bits = UInt16(bitPattern: value)
    report[index] = UInt8(bits & 0xff)
    report[index + 1] = UInt8(bits >> 8)
}

private func writeUInt16(_ report: inout [UInt8], at index: Int, value: UInt16) {
    report[index] = UInt8(value & 0xff)
    report[index + 1] = UInt8(value >> 8)
}

private func connectionReport(detail: UInt8) -> [UInt8] {
    var report = [UInt8](repeating: 0, count: SteamControllerReport.reportLength)
    report[0] = 0x01
    report[2] = 0x03
    report[3] = 0x01
    report[4] = detail
    return report
}

private func parsedState(_ report: [UInt8], previous: SteamControllerInputSnapshot = SteamControllerInputSnapshot(), model: SteamControllerModel = .legacy) -> SteamControllerInputSnapshot {
    guard case .state(let snapshot) = SteamControllerReport.parse(report, previous: previous, model: model) else {
        Issue.record("Expected a state event")
        return SteamControllerInputSnapshot()
    }
    return snapshot
}

@Suite struct SteamControllerReportTests {
    @Test func mapsFaceAndShoulderButtons() {
        let snapshot = parsedState(inputReport(buttons: (0b1111_1100, 0, 0)))
        #expect(snapshot.buttons.contains(.south))
        #expect(snapshot.buttons.contains(.east))
        #expect(snapshot.buttons.contains(.west))
        #expect(snapshot.buttons.contains(.north))
        #expect(snapshot.buttons.contains(.leftShoulder))
        #expect(snapshot.buttons.contains(.rightShoulder))
    }

    @Test func mapsDpadAndMenuButtons() {
        let snapshot = parsedState(inputReport(buttons: (0, 0b0101_1111, 0)))
        #expect(snapshot.buttons.contains(.dpadUp))
        #expect(snapshot.buttons.contains(.dpadRight))
        #expect(snapshot.buttons.contains(.dpadLeft))
        #expect(snapshot.buttons.contains(.dpadDown))
        #expect(snapshot.buttons.contains(.select))
        #expect(snapshot.buttons.contains(.start))
    }

    @Test func mapsStickAndRightPadClicks() {
        let snapshot = parsedState(inputReport(buttons: (0, 0, 0b0100_0100)))
        #expect(snapshot.buttons.contains(.leftStick))
        #expect(snapshot.buttons.contains(.rightStick))
    }

    @Test func mapsSteamButton() {
        let snapshot = parsedState(inputReport(buttons: (0, 0b0010_0000, 0)))
        #expect(snapshot.buttons.contains(.mode))
        #expect(parsedState(inputReport()).buttons.contains(.mode) == false)
    }

    @Test func mapsAnalogTriggers() {
        let snapshot = parsedState(inputReport(leftTrigger: 255, rightTrigger: 128))
        #expect(snapshot.leftTrigger == 1.0)
        #expect(abs(snapshot.rightTrigger - 128.0 / 255.0) < 0.001)
    }

    @Test func mapsJoystickWhenLeftPadUntouched() {
        let snapshot = parsedState(inputReport(leftPadX: Int16.max, leftPadY: Int16.min))
        #expect(snapshot.leftStickX == 1.0)
        #expect(snapshot.leftStickY == -1.0)
    }

    @Test func centersJoystickWhenOnlyLeftPadTouched() {
        let previous = SteamControllerInputSnapshot(leftStickX: 0.5, leftStickY: 0.5)
        let snapshot = parsedState(inputReport(buttons: (0, 0, 0b0000_1000), leftPadX: 1000, leftPadY: 1000), previous: previous)
        #expect(snapshot.leftStickX == 0)
        #expect(snapshot.leftStickY == 0)
    }

    @Test func preservesJoystickDuringInterleavedPadFrames() {
        let previous = SteamControllerInputSnapshot(leftStickX: 0.5, leftStickY: -0.5)
        let snapshot = parsedState(inputReport(buttons: (0, 0, 0b1000_1000), leftPadX: 1000, leftPadY: 1000), previous: previous)
        #expect(snapshot.leftStickX == 0.5)
        #expect(snapshot.leftStickY == -0.5)
    }

    @Test func mapsRightPadToRightStickOnlyWhileTouched() {
        let touched = parsedState(inputReport(buttons: (0, 0, 0b0001_0000), rightPadX: Int16.max, rightPadY: Int16.max))
        #expect(touched.rightStickX == 1.0)
        #expect(touched.rightStickY == 1.0)

        let untouched = parsedState(inputReport(rightPadX: Int16.max, rightPadY: Int16.max), previous: touched)
        #expect(untouched.rightStickX == 0)
        #expect(untouched.rightStickY == 0)
    }

    @Test func parsesWirelessConnectionEvents() {
        #expect(SteamControllerReport.parse(connectionReport(detail: 0x02), previous: SteamControllerInputSnapshot(), model: .legacy) == .connected)
        #expect(SteamControllerReport.parse(connectionReport(detail: 0x01), previous: SteamControllerInputSnapshot(), model: .legacy) == .disconnected)
    }

    @Test func ignoresUnknownReports() {
        var battery = [UInt8](repeating: 0, count: SteamControllerReport.reportLength)
        battery[0] = 0x01
        battery[2] = 0x04
        #expect(SteamControllerReport.parse(battery, previous: SteamControllerInputSnapshot(), model: .legacy) == .ignored)
        #expect(SteamControllerReport.parse([0xde, 0xad], previous: SteamControllerInputSnapshot(), model: .legacy) == .ignored)
        #expect(SteamControllerReport.parse([], previous: SteamControllerInputSnapshot(), model: .legacy) == .ignored)
    }

    @Test func lizardModeReportsAreWellFormed() {
        let reports = SteamControllerReport.lizardModeDisableReports(model: .legacy)
        #expect(reports.count == 2)
        #expect(reports.allSatisfy { $0.bytes.count == SteamControllerReport.reportLength })
        #expect(reports.allSatisfy { $0.reportID == 0 })
        #expect(reports[0].bytes[0] == 0x81)
        #expect(reports[1].bytes[0] == 0x87)

        let heartbeat = SteamControllerReport.lizardModeHeartbeatReport(model: .legacy)
        #expect(heartbeat.bytes.count == SteamControllerReport.reportLength)
        #expect(heartbeat.bytes[0] == 0x81)
    }
}

private func tritonReport(reportID: UInt8 = 0x42,
                          buttons: UInt32 = 0,
                          leftTrigger: Int16 = 0,
                          rightTrigger: Int16 = 0,
                          leftStickX: Int16 = 0,
                          leftStickY: Int16 = 0,
                          rightStickX: Int16 = 0,
                          rightStickY: Int16 = 0,
                          leftPadX: Int16 = 0,
                          leftPadY: Int16 = 0,
                          leftPadPressure: UInt16 = 0,
                          rightPadX: Int16 = 0,
                          rightPadY: Int16 = 0,
                          rightPadPressure: UInt16 = 0) -> [UInt8] {
    var report = [UInt8](repeating: 0, count: 54)
    report[0] = reportID
    report[1] = 1
    report[2] = UInt8(buttons & 0xff)
    report[3] = UInt8((buttons >> 8) & 0xff)
    report[4] = UInt8((buttons >> 16) & 0xff)
    report[5] = UInt8((buttons >> 24) & 0xff)
    writeInt16(&report, at: 6, value: leftTrigger)
    writeInt16(&report, at: 8, value: rightTrigger)
    writeInt16(&report, at: 10, value: leftStickX)
    writeInt16(&report, at: 12, value: leftStickY)
    writeInt16(&report, at: 14, value: rightStickX)
    writeInt16(&report, at: 16, value: rightStickY)
    // Report 0x47 carries a 16-bit trackpad timestamp before the pad data.
    let padOffset = reportID == 0x47 ? 20 : 18
    writeInt16(&report, at: padOffset, value: leftPadX)
    writeInt16(&report, at: padOffset + 2, value: leftPadY)
    writeInt16(&report, at: padOffset + 4, value: Int16(bitPattern: leftPadPressure))
    writeInt16(&report, at: padOffset + 6, value: rightPadX)
    writeInt16(&report, at: padOffset + 8, value: rightPadY)
    writeInt16(&report, at: padOffset + 10, value: Int16(bitPattern: rightPadPressure))
    return report
}

@Suite struct SteamControllerTritonReportTests {
    @Test func resolvesModelsFromProductIDs() {
        #expect(SteamControllerModel(productID: 0x1102) == .legacy)
        #expect(SteamControllerModel(productID: 0x1142) == .legacy)
        #expect(SteamControllerModel(productID: 0x1302) == .triton)
        #expect(SteamControllerModel(productID: 0x1303) == .triton)
        #expect(SteamControllerModel(productID: 0x1304) == .triton)
        #expect(SteamControllerModel(productID: 0x1305) == .triton)
        #expect(SteamControllerModel(productID: 0x1205) == nil)
    }

    @Test func mapsFaceButtonsAndShoulders() {
        let snapshot = parsedState(tritonReport(buttons: 0x0008_020f), model: .triton)
        #expect(snapshot.buttons.contains(.south))
        #expect(snapshot.buttons.contains(.east))
        #expect(snapshot.buttons.contains(.west))
        #expect(snapshot.buttons.contains(.north))
        #expect(snapshot.buttons.contains(.leftShoulder))
        #expect(snapshot.buttons.contains(.rightShoulder))
    }

    @Test func mapsBackGripButtons() {
        #expect(parsedState(tritonReport(buttons: 0x0002_0000), model: .triton).buttons.contains(.leftGrip))
        #expect(parsedState(tritonReport(buttons: 0x0004_0000), model: .triton).buttons.contains(.leftGrip2))
        #expect(parsedState(tritonReport(buttons: 0x0000_0080), model: .triton).buttons.contains(.rightGrip))
        #expect(parsedState(tritonReport(buttons: 0x0000_0100), model: .triton).buttons.contains(.rightGrip2))
    }

    @Test func mapsSteamAndQuickAccessButtons() {
        let snapshot = parsedState(tritonReport(buttons: 0x0001_0010), model: .triton)
        #expect(snapshot.buttons.contains(.mode))
        #expect(snapshot.buttons.contains(.quickAccess))

        let steamOnly = parsedState(tritonReport(buttons: 0x0001_0000), model: .triton)
        #expect(steamOnly.buttons.contains(.mode))
        #expect(steamOnly.buttons.contains(.quickAccess) == false)
    }

    @Test func mapsTrackpads() {
        let touchBits: UInt32 = 0x0200_0000 | 0x0020_0000
        let snapshot = parsedState(
            tritonReport(buttons: touchBits,
                         leftPadX: Int16.max,
                         leftPadY: Int16.min,
                         leftPadPressure: 16384,
                         rightPadX: -16384,
                         rightPadY: 16384,
                         rightPadPressure: 32768),
            model: .triton
        )
        #expect(snapshot.leftPad.touched)
        #expect(snapshot.leftPad.pressed == false)
        #expect(snapshot.leftPad.x == 1.0)
        #expect(snapshot.leftPad.y == -1.0)
        #expect(abs(snapshot.leftPad.pressure - 0.5) < 0.001)
        #expect(snapshot.rightPad.touched)
        #expect(abs(snapshot.rightPad.x + 0.5) < 0.001)
        #expect(abs(snapshot.rightPad.y - 0.5) < 0.001)
        #expect(snapshot.rightPad.pressure == 1.0)
    }

    @Test func mapsTrackpadClicks() {
        let clickBits: UInt32 = 0x0400_0000 | 0x0040_0000
        let snapshot = parsedState(tritonReport(buttons: clickBits), model: .triton)
        #expect(snapshot.leftPad.pressed)
        #expect(snapshot.rightPad.pressed)
    }

    @Test func mapsTrackpadsInTimestampedReport() {
        let snapshot = parsedState(
            tritonReport(reportID: 0x47, buttons: 0x0200_0000, leftPadX: Int16.max, rightPadY: Int16.max),
            model: .triton
        )
        #expect(snapshot.leftPad.touched)
        #expect(snapshot.leftPad.x == 1.0)
        #expect(snapshot.rightPad.y == 1.0)
    }

    @Test func mapsDpadMenuAndStickClicks() {
        let snapshot = parsedState(tritonReport(buttons: 0x0000_fc60), model: .triton)
        #expect(snapshot.buttons.contains(.dpadDown))
        #expect(snapshot.buttons.contains(.dpadRight))
        #expect(snapshot.buttons.contains(.dpadLeft))
        #expect(snapshot.buttons.contains(.dpadUp))
        #expect(snapshot.buttons.contains(.select))
        #expect(snapshot.buttons.contains(.start))
        #expect(snapshot.buttons.contains(.leftStick))
        #expect(snapshot.buttons.contains(.rightStick))
    }

    @Test func mapsAnalogTriggersAndSticks() {
        let snapshot = parsedState(tritonReport(leftTrigger: Int16.max, rightTrigger: 16384, leftStickX: Int16.max, leftStickY: Int16.min, rightStickX: -16384, rightStickY: Int16.max), model: .triton)
        #expect(snapshot.leftTrigger == 1.0)
        #expect(abs(snapshot.rightTrigger - 0.5) < 0.001)
        #expect(snapshot.leftStickX == 1.0)
        #expect(snapshot.leftStickY == -1.0)
        #expect(abs(snapshot.rightStickX + 0.5) < 0.001)
        #expect(snapshot.rightStickY == 1.0)
    }

    @Test func acceptsAllStateReportVariants() {
        for reportID: UInt8 in [0x42, 0x45, 0x47] {
            let event = SteamControllerReport.parse(tritonReport(reportID: reportID, buttons: 0x1), previous: SteamControllerInputSnapshot(), model: .triton)
            guard case .state(let snapshot) = event else {
                Issue.record("Expected state for report \(reportID)")
                continue
            }
            #expect(snapshot.buttons.contains(.south))
        }
    }

    @Test func parsesWirelessStatusEvents() {
        for reportID: UInt8 in [0x79, 0x46] {
            #expect(SteamControllerReport.parse([reportID, 0x02], previous: SteamControllerInputSnapshot(), model: .triton) == .connected)
            #expect(SteamControllerReport.parse([reportID, 0x01], previous: SteamControllerInputSnapshot(), model: .triton) == .disconnected)
        }
    }

    @Test func ignoresBatteryAndUnknownReports() {
        #expect(SteamControllerReport.parse([0x43, 0x01, 0x50], previous: SteamControllerInputSnapshot(), model: .triton) == .ignored)
        #expect(SteamControllerReport.parse([], previous: SteamControllerInputSnapshot(), model: .triton) == .ignored)
        #expect(SteamControllerReport.parse([0x42, 0x00], previous: SteamControllerInputSnapshot(), model: .triton) == .ignored)
    }

    @Test func lizardModeReportUsesFeatureReportOne() {
        let reports = SteamControllerReport.lizardModeDisableReports(model: .triton)
        #expect(reports.count == 2)
        #expect(reports[0].reportID == 1)
        #expect(reports[0].bytes.count == SteamControllerReport.reportLength)
        #expect(Array(reports[0].bytes[0...2]) == [0x01, 0x81, 0x00])
        #expect(reports[1].reportID == 1)
        #expect(reports[1].bytes.count == SteamControllerReport.reportLength)
        #expect(Array(reports[1].bytes[0...5]) == [0x01, 0x87, 0x03, 0x09, 0x00, 0x00])
        #expect(SteamControllerReport.lizardModeHeartbeatReport(model: .triton) == reports[1])
    }
}

private func deckStateReport(buttons: UInt64 = 0,
                             leftTrigger: UInt16 = 0,
                             rightTrigger: UInt16 = 0,
                             leftStickX: Int16 = 0,
                             leftStickY: Int16 = 0,
                             rightStickX: Int16 = 0,
                             rightStickY: Int16 = 0,
                             leftPadX: Int16 = 0,
                             leftPadY: Int16 = 0,
                             rightPadX: Int16 = 0,
                             rightPadY: Int16 = 0,
                             leftPadPressure: UInt16 = 0,
                             rightPadPressure: UInt16 = 0) -> [UInt8] {
    var report = [UInt8](repeating: 0, count: 60)
    report[0] = 0x09
    report[8] = UInt8(buttons & 0xff)
    report[9] = UInt8((buttons >> 8) & 0xff)
    report[10] = UInt8((buttons >> 16) & 0xff)
    report[11] = UInt8((buttons >> 24) & 0xff)
    report[12] = UInt8((buttons >> 32) & 0xff)
    report[13] = UInt8((buttons >> 40) & 0xff)
    report[14] = UInt8((buttons >> 48) & 0xff)
    report[15] = UInt8((buttons >> 56) & 0xff)
    writeInt16(&report, at: 16, value: leftPadX)
    writeInt16(&report, at: 18, value: leftPadY)
    writeInt16(&report, at: 20, value: rightPadX)
    writeInt16(&report, at: 22, value: rightPadY)
    writeUInt16(&report, at: 44, value: leftTrigger)
    writeUInt16(&report, at: 46, value: rightTrigger)
    writeInt16(&report, at: 48, value: leftStickX)
    writeInt16(&report, at: 50, value: leftStickY)
    writeInt16(&report, at: 52, value: rightStickX)
    writeInt16(&report, at: 54, value: rightStickY)
    writeUInt16(&report, at: 56, value: leftPadPressure)
    writeUInt16(&report, at: 58, value: rightPadPressure)
    return report
}

private func parsedDeckState(_ report: [UInt8]) -> SteamControllerInputSnapshot {
    guard case .state(let snapshot) = SteamControllerReport.parseDeckState(report, previous: SteamControllerInputSnapshot()) else {
        Issue.record("Expected a deck state event")
        return SteamControllerInputSnapshot()
    }
    return snapshot
}

@Suite struct SteamControllerDeckReportTests {
    @Test func mapsFaceButtonsAndShoulders() {
        let snapshot = parsedDeckState(deckStateReport(buttons: 0x0000_0000_0000_00ff))
        #expect(snapshot.buttons.contains(.south))
        #expect(snapshot.buttons.contains(.east))
        #expect(snapshot.buttons.contains(.west))
        #expect(snapshot.buttons.contains(.north))
        #expect(snapshot.buttons.contains(.leftShoulder))
        #expect(snapshot.buttons.contains(.rightShoulder))
    }

    @Test func mapsAllBackGrips() {
        let snapshot = parsedDeckState(deckStateReport(buttons: (1 << 41) | (1 << 42) | (1 << 15) | (1 << 16)))
        #expect(snapshot.buttons.contains(.leftGrip))
        #expect(snapshot.buttons.contains(.rightGrip))
        #expect(snapshot.buttons.contains(.leftGrip2))
        #expect(snapshot.buttons.contains(.rightGrip2))
    }

    @Test func mapsSteamAndQuickAccessButtons() {
        let snapshot = parsedDeckState(deckStateReport(buttons: (1 << 13) | (1 << 50)))
        #expect(snapshot.buttons.contains(.mode))
        #expect(snapshot.buttons.contains(.quickAccess))
        #expect(parsedDeckState(deckStateReport()).buttons.contains(.mode) == false)
    }

    @Test func mapsTrackpads() {
        let touchAndClickBits: UInt64 = (1 << 19) | (1 << 20) | (1 << 17)
        let snapshot = parsedDeckState(
            deckStateReport(buttons: touchAndClickBits,
                            leftPadX: Int16.max,
                            leftPadY: Int16.min,
                            rightPadX: -16384,
                            rightPadY: 16384,
                            leftPadPressure: 32768,
                            rightPadPressure: 16384)
        )
        #expect(snapshot.leftPad.touched)
        #expect(snapshot.leftPad.pressed)
        #expect(snapshot.rightPad.touched)
        #expect(snapshot.rightPad.pressed == false)
        #expect(snapshot.leftPad.x == 1.0)
        #expect(snapshot.leftPad.y == -1.0)
        #expect(snapshot.leftPad.pressure == 1.0)
        #expect(abs(snapshot.rightPad.x + 0.5) < 0.001)
        #expect(abs(snapshot.rightPad.y - 0.5) < 0.001)
        #expect(abs(snapshot.rightPad.pressure - 0.5) < 0.001)
    }

    @Test func mapsDpadMenuAndStickClicks() {
        let snapshot = parsedDeckState(deckStateReport(buttons: 0x0000_0000_0440_5f00))
        #expect(snapshot.buttons.contains(.dpadUp))
        #expect(snapshot.buttons.contains(.dpadRight))
        #expect(snapshot.buttons.contains(.dpadLeft))
        #expect(snapshot.buttons.contains(.dpadDown))
        #expect(snapshot.buttons.contains(.select))
        #expect(snapshot.buttons.contains(.start))
        #expect(snapshot.buttons.contains(.leftStick))
        #expect(snapshot.buttons.contains(.rightStick))
    }

    @Test func mapsAnalogTriggersAndSticks() {
        let snapshot = parsedDeckState(deckStateReport(leftTrigger: UInt16.max, rightTrigger: 32768, leftStickX: Int16.max, leftStickY: Int16.min, rightStickX: -16384, rightStickY: Int16.max))
        #expect(snapshot.leftTrigger == 1.0)
        #expect(abs(snapshot.rightTrigger - 0.5) < 0.001)
        #expect(snapshot.leftStickX == 1.0)
        #expect(snapshot.leftStickY == -1.0)
        #expect(abs(snapshot.rightStickX + 0.5) < 0.001)
        #expect(snapshot.rightStickY == 1.0)
    }

    @Test func ignoresShortReports() {
        #expect(SteamControllerReport.parseDeckState([0x09], previous: SteamControllerInputSnapshot()) == .ignored)
    }
}
