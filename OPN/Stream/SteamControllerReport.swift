import Foundation

public struct SteamControllerTrackpadState: Equatable, Sendable {
    public var x: Float
    public var y: Float
    public var pressure: Float
    public var touched: Bool
    public var pressed: Bool

    public init(x: Float = 0,
                y: Float = 0,
                pressure: Float = 0,
                touched: Bool = false,
                pressed: Bool = false) {
        self.x = x
        self.y = y
        self.pressure = pressure
        self.touched = touched
        self.pressed = pressed
    }
}

public struct SteamControllerInputSnapshot: Equatable, Sendable {
    public var buttons: GamepadButtons
    public var leftTrigger: Float
    public var rightTrigger: Float
    public var leftStickX: Float
    public var leftStickY: Float
    public var rightStickX: Float
    public var rightStickY: Float
    public var leftPad: SteamControllerTrackpadState
    public var rightPad: SteamControllerTrackpadState

    public init(buttons: GamepadButtons = [],
                leftTrigger: Float = 0,
                rightTrigger: Float = 0,
                leftStickX: Float = 0,
                leftStickY: Float = 0,
                rightStickX: Float = 0,
                rightStickY: Float = 0,
                leftPad: SteamControllerTrackpadState = SteamControllerTrackpadState(),
                rightPad: SteamControllerTrackpadState = SteamControllerTrackpadState()) {
        self.buttons = buttons
        self.leftTrigger = leftTrigger
        self.rightTrigger = rightTrigger
        self.leftStickX = leftStickX
        self.leftStickY = leftStickY
        self.rightStickX = rightStickX
        self.rightStickY = rightStickY
        self.leftPad = leftPad
        self.rightPad = rightPad
    }
}

public enum SteamControllerReportEvent: Equatable, Sendable {
    case state(SteamControllerInputSnapshot)
    case connected
    case disconnected
    case battery(level: UInt8, charging: Bool)
    case ignored
}

public enum SteamControllerModel: Equatable, Sendable {
    case legacy
    case triton

    public init?(productID: Int) {
        guard let traits = SteamControllerReport.productTraits[productID] else { return nil }
        self = traits.model
    }
}

public struct SteamControllerFeatureReport: Equatable, Sendable {
    /// Which HID report pipe carries it. Commands are feature reports; the 2026 controller's
    /// haptics are output reports.
    public enum Kind: Equatable, Sendable { case feature, output }

    public let reportID: Int
    public let bytes: [UInt8]
    public var kind: Kind = .feature
}

public enum SteamControllerReport {
    public static let vendorID = 0x28de
    public static let wiredProductID = 0x1102
    public static let dongleProductID = 0x1142
    public static let tritonWiredProductID = 0x1302
    public static let tritonBLEProductID = 0x1303
    public static let proteusDongleProductID = 0x1304
    public static let nereidDongleProductID = 0x1305
    public static let vendorUsagePage = 0xff00
    public static let vendorUsage = 1
    public static let gamepadUsagePage = 1
    public static let gamepadUsage = 5
    public static let reportLength = 64

    static let productTraits: [Int: (model: SteamControllerModel, isWirelessReceiver: Bool)] = [
        wiredProductID: (.legacy, false),
        dongleProductID: (.legacy, true),
        tritonWiredProductID: (.triton, false),
        tritonBLEProductID: (.triton, false),
        proteusDongleProductID: (.triton, true),
        nereidDongleProductID: (.triton, true),
    ]

    public static var matchedProductIDs: [Int] {
        productTraits.keys.sorted()
    }

    public static func isWirelessReceiver(productID: Int) -> Bool {
        productTraits[productID]?.isWirelessReceiver == true
    }

    private static let headerVersion: UInt8 = 0x01
    private static let inputEventType: UInt8 = 0x01
    private static let connectionEventType: UInt8 = 0x03
    private static let connectionDetailDisconnected: UInt8 = 0x01
    private static let connectionDetailConnected: UInt8 = 0x02

    private static let clearDigitalMappingsCommand: UInt8 = 0x81
    private static let defaultDigitalMappingsCommand: UInt8 = 0x85
    private static let setSettingsCommand: UInt8 = 0x87
    private static let defaultSettingsCommand: UInt8 = 0x8e
    private static let rumbleCommand: UInt8 = 0x8f
    private static let powerOffCommand: UInt8 = 0x9f
    private static let rightPadModeRegister: UInt8 = 0x08
    private static let rightPadModeOff: UInt8 = 0x07
    private static let rightPadMarginRegister: UInt8 = 0x18
    private static let rightPadMarginOff: UInt8 = 0x00

    private static let tritonStateReportID: UInt8 = 0x42
    private static let tritonBatteryReportID: UInt8 = 0x43
    private static let tritonBLEStateReportID: UInt8 = 0x45
    private static let tritonWirelessStatusXReportID: UInt8 = 0x46
    private static let tritonTimestampedStateReportID: UInt8 = 0x47
    private static let tritonWirelessStatusReportID: UInt8 = 0x79
    private static let tritonFeatureReportID = 1
    private static let tritonLizardModeSetting: UInt8 = 0x09
    private static let tritonLizardModeOff: UInt8 = 0x00
    private static let tritonLizardModeOn: UInt8 = 0x01
    public static let deckStateReportID: UInt8 = 0x09

    private static func parseLegacy(_ report: [UInt8], previous: SteamControllerInputSnapshot) -> SteamControllerReportEvent {
        guard report.count >= 5, report[0] == headerVersion, report[1] == 0x00 else { return .ignored }
        switch report[2] {
        case connectionEventType:
            return connectionEvent(detail: report[4])
        case inputEventType:
            guard report.count >= 24 else { return .ignored }
            return .state(legacyInputState(from: report, previous: previous))
        default:
            return .ignored
        }
    }

    private static func parseTriton(_ report: [UInt8], previous: SteamControllerInputSnapshot) -> SteamControllerReportEvent {
        guard let reportID = report.first else { return .ignored }
        switch reportID {
        case tritonStateReportID, tritonBLEStateReportID:
            guard report.count >= 18 else { return .ignored }
            return .state(tritonInputState(from: report, padOffset: 18))
        case tritonTimestampedStateReportID:
            // The timestamped report inserts a 16-bit trackpad timestamp before the pad data.
            guard report.count >= 18 else { return .ignored }
            return .state(tritonInputState(from: report, padOffset: 20))
        case tritonWirelessStatusReportID, tritonWirelessStatusXReportID:
            guard report.count >= 2 else { return .ignored }
            return connectionEvent(detail: report[1])
        case tritonBatteryReportID:
            guard report.count >= 3 else { return .ignored }
            // The level byte is already a percentage, not a 0-255 fraction:
            // scaling it by 100/255 capped a fully charged pad at 39%, so the
            // HUD never read above 40% on hardware.
            let charging = report[1] == 0x04
            return .battery(level: min(100, report[2]), charging: charging)
        case 0x7B:
            return .ignored
        default:
            if reportID != tritonStateReportID, reportID != tritonBLEStateReportID, reportID != tritonTimestampedStateReportID {
                let hex = report.prefix(min(8, report.count)).map { String(format: "%02X", $0) }.joined(separator: " ")
                OpenNOWLog.debug(.controller, "Unknown Triton reportID=0x\(String(format: "%02X", reportID)) length=\(report.count) bytes=\(hex)")
            }
            return .ignored
        }
    }

    public static func parseDeckState(_ report: [UInt8], previous: SteamControllerInputSnapshot) -> SteamControllerReportEvent {
        guard report.count >= 60, report.first == deckStateReportID else { return .ignored }
        return .state(deckInputState(from: report))
    }

    private static func connectionEvent(detail: UInt8) -> SteamControllerReportEvent {
        switch detail {
        case connectionDetailDisconnected: .disconnected
        case connectionDetailConnected: .connected
        default: .ignored
        }
    }

    private static func legacyInputState(from report: [UInt8], previous: SteamControllerInputSnapshot) -> SteamControllerInputSnapshot {
        var snapshot = previous
        snapshot.buttons = legacyButtons(highBits: report[8], midBits: report[9], lowBits: report[10])
        snapshot.leftTrigger = Float(report[11]) / 255
        snapshot.rightTrigger = Float(report[12]) / 255

        let leftPadTouched = report[10] & LegacyButtonMask.leftPadTouch != 0
        let leftPadAndStick = report[10] & LegacyButtonMask.leftPadAndStick != 0
        if !leftPadTouched {
            snapshot.leftStickX = axis(report, at: 16)
            snapshot.leftStickY = axis(report, at: 18)
        } else if !leftPadAndStick {
            snapshot.leftStickX = 0
            snapshot.leftStickY = 0
        }

        let rightPadTouched = report[10] & LegacyButtonMask.rightPadTouch != 0
        snapshot.rightStickX = rightPadTouched ? axis(report, at: 20) : 0
        snapshot.rightStickY = rightPadTouched ? axis(report, at: 22) : 0
        return snapshot
    }

    private static func tritonInputState(from report: [UInt8], padOffset: Int) -> SteamControllerInputSnapshot {
        let buttons = UInt32(report[2]) | (UInt32(report[3]) << 8) | (UInt32(report[4]) << 16) | (UInt32(report[5]) << 24)
        var snapshot = SteamControllerInputSnapshot(
            buttons: tritonButtons(buttons),
            leftTrigger: max(0, axis(report, at: 6)),
            rightTrigger: max(0, axis(report, at: 8)),
            leftStickX: axis(report, at: 10),
            // Stick Y is passed through un-negated on purpose. The Linux hid-steam Ibex axis table
            // applies sign -1 to ABS_Y/ABS_RY, but only to match evdev's down-positive convention;
            // XInput wants up-positive, and the raw report is already up-positive (confirmed on
            // hardware: physical up -> +32767). Negating here to "match the kernel" would invert Y.
            leftStickY: axis(report, at: 12),
            rightStickX: axis(report, at: 14),
            rightStickY: axis(report, at: 16)
        )
        if report.count >= padOffset + 12 {
            snapshot.leftPad = SteamControllerTrackpadState(
                x: axis(report, at: padOffset),
                y: axis(report, at: padOffset + 2),
                pressure: pressure(report, at: padOffset + 4),
                touched: buttons & TritonButtonMask.leftPadTouch != 0,
                pressed: buttons & TritonButtonMask.leftPadClick != 0
            )
            snapshot.rightPad = SteamControllerTrackpadState(
                x: axis(report, at: padOffset + 6),
                y: axis(report, at: padOffset + 8),
                pressure: pressure(report, at: padOffset + 10),
                touched: buttons & TritonButtonMask.rightPadTouch != 0,
                pressed: buttons & TritonButtonMask.rightPadClick != 0
            )
        }
        return snapshot
    }

    /// Folds a report's button bits through a mask table.
    private static func buttons<Bits: FixedWidthInteger>(_ bits: Bits, _ table: [(mask: Bits, button: GamepadButtons)]) -> GamepadButtons {
        table.reduce(into: GamepadButtons()) { result, entry in
            if bits & entry.mask != 0 { result.insert(entry.button) }
        }
    }

    private static let legacyHighButtons: [(mask: UInt8, button: GamepadButtons)] = [
        (LegacyButtonMask.south, .south),
        (LegacyButtonMask.east, .east),
        (LegacyButtonMask.west, .west),
        (LegacyButtonMask.north, .north),
        (LegacyButtonMask.leftShoulder, .leftShoulder),
        (LegacyButtonMask.rightShoulder, .rightShoulder)
    ]

    private static let legacyMidButtons: [(mask: UInt8, button: GamepadButtons)] = [
        (LegacyButtonMask.dpadUp, .dpadUp),
        (LegacyButtonMask.dpadRight, .dpadRight),
        (LegacyButtonMask.dpadLeft, .dpadLeft),
        (LegacyButtonMask.dpadDown, .dpadDown),
        (LegacyButtonMask.select, .select),
        (LegacyButtonMask.steam, .mode),
        (LegacyButtonMask.start, .start)
    ]

    private static let legacyLowButtons: [(mask: UInt8, button: GamepadButtons)] = [
        (LegacyButtonMask.stickClick, .leftStick),
        (LegacyButtonMask.rightPadClick, .rightStick)
    ]

    private static func legacyButtons(highBits: UInt8, midBits: UInt8, lowBits: UInt8) -> GamepadButtons {
        buttons(highBits, legacyHighButtons)
            .union(buttons(midBits, legacyMidButtons))
            .union(buttons(lowBits, legacyLowButtons))
    }

    /// The Triton has NO physical D-pad: the four direction bits come from the LEFT TRACKPAD, which
    /// reports a direction the moment a thumb rests on it. These were briefly gated behind
    /// `leftPadClick`, to stop a character that walked on its own — but that walking turned out to
    /// be the MOUSE path (the trackpad maps to mouse by default, and a resting thumb emits
    /// continuous deltas), and gamepad input was dead at the time for an unrelated reason: the
    /// state packet's envelope was malformed. The gate therefore rested on nothing observed while
    /// silently dropping the only directions this pad can produce. If a real thumb-rest drift shows
    /// up now that state packets are well-formed, re-add the click requirement with that evidence
    /// rather than on the old premise.
    private static let tritonButtonTable: [(mask: UInt32, button: GamepadButtons)] = [
        (TritonButtonMask.south, .south),
        (TritonButtonMask.east, .east),
        (TritonButtonMask.west, .west),
        (TritonButtonMask.north, .north),
        (TritonButtonMask.leftShoulder, .leftShoulder),
        (TritonButtonMask.rightShoulder, .rightShoulder),
        (TritonButtonMask.select, .select),
        (TritonButtonMask.start, .start),
        (TritonButtonMask.leftStick, .leftStick),
        (TritonButtonMask.rightStick, .rightStick),
        (TritonButtonMask.dpadUp, .dpadUp),
        (TritonButtonMask.dpadDown, .dpadDown),
        (TritonButtonMask.dpadLeft, .dpadLeft),
        (TritonButtonMask.dpadRight, .dpadRight),
        (TritonButtonMask.leftGrip, .leftGrip),
        (TritonButtonMask.rightGrip, .rightGrip),
        (TritonButtonMask.leftGrip2, .leftGrip2),
        (TritonButtonMask.rightGrip2, .rightGrip2),
        (TritonButtonMask.steam, .mode),
        (TritonButtonMask.quickAccess, .quickAccess)
    ]

    private static func tritonButtons(_ bits: UInt32) -> GamepadButtons {
        buttons(bits, tritonButtonTable)
    }

    private static func deckInputState(from report: [UInt8]) -> SteamControllerInputSnapshot {
        let buttons = UInt64(report[8]) | (UInt64(report[9]) << 8) | (UInt64(report[10]) << 16) | (UInt64(report[11]) << 24) | (UInt64(report[12]) << 32) | (UInt64(report[13]) << 40) | (UInt64(report[14]) << 48) | (UInt64(report[15]) << 56)
        return SteamControllerInputSnapshot(
            buttons: deckButtons(buttons),
            leftTrigger: Float(UInt16(report[44]) | (UInt16(report[45]) << 8)) / Float(UInt16.max),
            rightTrigger: Float(UInt16(report[46]) | (UInt16(report[47]) << 8)) / Float(UInt16.max),
            leftStickX: axis(report, at: 48),
            leftStickY: axis(report, at: 50),
            rightStickX: axis(report, at: 52),
            rightStickY: axis(report, at: 54),
            leftPad: SteamControllerTrackpadState(
                x: axis(report, at: 16),
                y: axis(report, at: 18),
                pressure: pressure(report, at: 56),
                touched: buttons & DeckStateButtonMask.leftPadTouched != 0,
                pressed: buttons & DeckStateButtonMask.leftPadPressed != 0
            ),
            rightPad: SteamControllerTrackpadState(
                x: axis(report, at: 20),
                y: axis(report, at: 22),
                pressure: pressure(report, at: 58),
                touched: buttons & DeckStateButtonMask.rightPadTouched != 0,
                pressed: buttons & DeckStateButtonMask.rightPadPressed != 0
            )
        )
    }

    private static let deckButtonTable: [(mask: UInt64, button: GamepadButtons)] = [
        (DeckStateButtonMask.south, .south),
        (DeckStateButtonMask.east, .east),
        (DeckStateButtonMask.west, .west),
        (DeckStateButtonMask.north, .north),
        (DeckStateButtonMask.leftShoulder, .leftShoulder),
        (DeckStateButtonMask.rightShoulder, .rightShoulder),
        (DeckStateButtonMask.select, .select),
        (DeckStateButtonMask.start, .start),
        (DeckStateButtonMask.leftStick, .leftStick),
        (DeckStateButtonMask.rightStick, .rightStick),
        (DeckStateButtonMask.dpadUp, .dpadUp),
        (DeckStateButtonMask.dpadDown, .dpadDown),
        (DeckStateButtonMask.dpadLeft, .dpadLeft),
        (DeckStateButtonMask.dpadRight, .dpadRight),
        (DeckStateButtonMask.leftGrip, .leftGrip),
        (DeckStateButtonMask.rightGrip, .rightGrip),
        (DeckStateButtonMask.leftGrip2, .leftGrip2),
        (DeckStateButtonMask.rightGrip2, .rightGrip2),
        (DeckStateButtonMask.mode, .mode),
        (DeckStateButtonMask.quickAccess, .quickAccess)
    ]

    private static func deckButtons(_ bits: UInt64) -> GamepadButtons {
        buttons(bits, deckButtonTable)
    }

    private static func axis(_ report: [UInt8], at index: Int) -> Float {
        let raw = Int16(bitPattern: UInt16(report[index]) | (UInt16(report[index + 1]) << 8))
        return max(-1, min(1, Float(raw) / Float(Int16.max)))
    }

    private static func pressure(_ report: [UInt8], at index: Int) -> Float {
        let raw = UInt16(report[index]) | (UInt16(report[index + 1]) << 8)
        return min(1, Float(raw) / 32768)
    }

    private static func legacyFeatureReport(_ bytes: [UInt8]) -> SteamControllerFeatureReport {
        var buffer = [UInt8](repeating: 0, count: reportLength)
        buffer.replaceSubrange(0..<bytes.count, with: bytes)
        return SteamControllerFeatureReport(reportID: 0, bytes: buffer)
    }

    private static func tritonClearDigitalMappingsReport() -> SteamControllerFeatureReport {
        tritonCommandReport(clearDigitalMappingsCommand)
    }

    private static func tritonCommandReport(_ command: UInt8) -> SteamControllerFeatureReport {
        var buffer = [UInt8](repeating: 0, count: reportLength)
        buffer[0] = UInt8(tritonFeatureReportID)
        buffer[1] = command
        buffer[2] = 0x00
        return SteamControllerFeatureReport(reportID: tritonFeatureReportID, bytes: buffer)
    }

    private static func tritonLizardModeDisableReport() -> SteamControllerFeatureReport {
        tritonLizardModeSettingReport(tritonLizardModeOff)
    }

    private static func tritonLizardModeSettingReport(_ value: UInt8) -> SteamControllerFeatureReport {
        var buffer = [UInt8](repeating: 0, count: reportLength)
        buffer[0] = UInt8(tritonFeatureReportID)
        buffer[1] = setSettingsCommand
        buffer[2] = 0x03
        buffer[3] = tritonLizardModeSetting
        buffer[4] = value
        buffer[5] = 0x00
        return SteamControllerFeatureReport(reportID: tritonFeatureReportID, bytes: buffer)
    }

    /// The 2026 controller ("Ibex" in Linux `hid-steam`; the Puck is `USB_DEVICE_ID_STEAM_CONTROLLER_PROTEUS`
    /// 0x1304, `STEAM_QUIRK_IBEX | WIRELESS`) does not take the Steam Deck's `0xEB` feature-report
    /// rumble — the firmware accepts the write and ignores it (2026-09-05, `-> 0x00000000`, no
    /// motion). Its haptics are HID **output** reports: `REPORT_ID_HAPTIC_RUMBLE` 0x80 followed by
    /// `steam_ibex_haptic_rumble { u8 type; u16 LE intensity; { u16 LE speed; u8 gain } left, right }`
    /// (9 bytes, `static_assert`ed in the driver), sent with `hid_hw_output_report` as 10 bytes.
    /// SDL's own Triton driver (`SDL_hidapi_steam_triton.c`, `ID_OUT_REPORT_HAPTIC_RUMBLE`,
    /// `HID_RUMBLE_OUTPUT_REPORT_BYTES 10`) writes type 0, intensity 0 and both gains 0 (dB) with
    /// `hid_write`; that is the layout used here. **The firmware stops the motors ~50 ms after the
    /// last command** ("hardware safety timeout"), so the driver re-sends every 40 ms while a rumble
    /// is active — `SteamControllerHIDMonitor.sendRumble` does the same.
    private static let tritonHapticRumbleReportID = 0x80
    /// SDL's `TRITON_RUMBLE_RESEND_INTERVAL_MS`.
    public static let tritonRumbleResendMilliseconds = 40

    private static func tritonRumbleReport(leftAmplitude: UInt16, rightAmplitude: UInt16) -> SteamControllerFeatureReport {
        let bytes: [UInt8] = [
            UInt8(tritonHapticRumbleReportID),
            0, // type: plain motor speeds
            0, 0, // intensity, unused by that type
            UInt8(leftAmplitude & 0xff), UInt8((leftAmplitude >> 8) & 0xff),
            0, // left gain, dB — 0 as SDL sends it; the speed field alone scales felt strength (tester verified)
            UInt8(rightAmplitude & 0xff), UInt8((rightAmplitude >> 8) & 0xff),
            0, // right gain, dB
        ]
        return SteamControllerFeatureReport(reportID: tritonHapticRumbleReportID, bytes: bytes, kind: .output)
    }
}

// MARK: - Report bit layouts

extension SteamControllerReport {
    private enum LegacyButtonMask {
        static let rightShoulder: UInt8 = 0x04
        static let leftShoulder: UInt8 = 0x08
        static let north: UInt8 = 0x10
        static let east: UInt8 = 0x20
        static let west: UInt8 = 0x40
        static let south: UInt8 = 0x80

        static let dpadUp: UInt8 = 0x01
        static let dpadRight: UInt8 = 0x02
        static let dpadLeft: UInt8 = 0x04
        static let dpadDown: UInt8 = 0x08
        static let select: UInt8 = 0x10
        static let steam: UInt8 = 0x20
        static let start: UInt8 = 0x40

        static let rightPadClick: UInt8 = 0x04
        static let leftPadTouch: UInt8 = 0x08
        static let rightPadTouch: UInt8 = 0x10
        static let stickClick: UInt8 = 0x40
        static let leftPadAndStick: UInt8 = 0x80
    }

    private enum TritonButtonMask {
        static let south: UInt32 = 0x0000_0001
        static let east: UInt32 = 0x0000_0002
        static let west: UInt32 = 0x0000_0004
        static let north: UInt32 = 0x0000_0008
        // HARDWARE WINS over the kernel table here. Linux hid-steam.c maps byte2 bit4 (0x10) to
        // BTN_BASE (Steam) and byte4 bit0 (0x10000) to BTN_MODE ("..."), and we swapped ours to
        // match — but on THIS dongle that was wrong and broke both buttons, so it is reverted.
        // The Puck evidently does not emit these two bits the way the wired Ibex driver expects.
        // Do not "fix" this against the kernel again without a raw capture of these two presses.
        static let quickAccess: UInt32 = 0x0000_0010
        static let rightStick: UInt32 = 0x0000_0020
        static let start: UInt32 = 0x0000_0040
        static let rightShoulder: UInt32 = 0x0000_0200
        static let dpadDown: UInt32 = 0x0000_0400
        static let dpadRight: UInt32 = 0x0000_0800
        static let dpadLeft: UInt32 = 0x0000_1000
        static let dpadUp: UInt32 = 0x0000_2000
        static let select: UInt32 = 0x0000_4000
        static let leftStick: UInt32 = 0x0000_8000
        static let steam: UInt32 = 0x0001_0000
        static let leftShoulder: UInt32 = 0x0008_0000
        // Digital full-pull of each trigger (we drive triggers from the analog axes, but the seat
        // and some games read these bits): TR2 byte4 bit7, TL2 byte5 bit3.
        static let rightTriggerFull: UInt32 = 0x0080_0000
        static let leftTriggerFull: UInt32 = 0x0800_0000
        static let leftGrip: UInt32 = 0x0002_0000
        static let rightGrip: UInt32 = 0x0000_0080
        static let leftGrip2: UInt32 = 0x0004_0000
        static let rightGrip2: UInt32 = 0x0000_0100
        static let rightPadTouch: UInt32 = 0x0020_0000
        static let rightPadClick: UInt32 = 0x0040_0000
        static let leftPadTouch: UInt32 = 0x0200_0000
        static let leftPadClick: UInt32 = 0x0400_0000
    }

    private enum DeckStateButtonMask {
        static let rightTriggerFull: UInt64 = 1 << 0
        static let leftTriggerFull: UInt64 = 1 << 1
        static let rightShoulder: UInt64 = 1 << 2
        static let leftShoulder: UInt64 = 1 << 3
        static let north: UInt64 = 1 << 4
        static let east: UInt64 = 1 << 5
        static let west: UInt64 = 1 << 6
        static let south: UInt64 = 1 << 7
        static let dpadUp: UInt64 = 1 << 8
        static let dpadRight: UInt64 = 1 << 9
        static let dpadLeft: UInt64 = 1 << 10
        static let dpadDown: UInt64 = 1 << 11
        static let select: UInt64 = 1 << 12
        static let mode: UInt64 = 1 << 13
        static let start: UInt64 = 1 << 14
        static let leftGrip2: UInt64 = 1 << 15
        static let rightGrip2: UInt64 = 1 << 16
        static let leftPadPressed: UInt64 = 1 << 17
        static let rightPadPressed: UInt64 = 1 << 18
        static let leftPadTouched: UInt64 = 1 << 19
        static let rightPadTouched: UInt64 = 1 << 20
        static let leftStick: UInt64 = 1 << 22
        static let rightStick: UInt64 = 1 << 26
        static let leftGrip: UInt64 = 1 << 41
        static let rightGrip: UInt64 = 1 << 42
        static let quickAccess: UInt64 = 1 << 50
    }

    public static func parse(_ report: [UInt8], previous: SteamControllerInputSnapshot, model: SteamControllerModel) -> SteamControllerReportEvent {
        switch model {
        case .legacy: parseLegacy(report, previous: previous)
        case .triton: parseTriton(report, previous: previous)
        }
    }

    public static func lizardModeDisableReports(model: SteamControllerModel) -> [SteamControllerFeatureReport] {
        switch model {
        case .legacy:
            [
                legacyFeatureReport([clearDigitalMappingsCommand, 0x00]),
                legacyFeatureReport([
                    setSettingsCommand, 0x06,
                    rightPadModeRegister, rightPadModeOff, 0x00,
                    rightPadMarginRegister, rightPadMarginOff, 0x00,
                ]),
            ]
        case .triton:
            [
                tritonClearDigitalMappingsReport(),
                tritonLizardModeDisableReport(),
            ]
        }
    }

    public static func lizardModeHeartbeatReport(model: SteamControllerModel) -> SteamControllerFeatureReport {
        switch model {
        case .legacy: legacyFeatureReport([clearDigitalMappingsCommand, 0x00])
        case .triton: tritonLizardModeDisableReport()
        }
    }

    public static func powerOffReport(model: SteamControllerModel) -> SteamControllerFeatureReport {
        switch model {
        case .legacy: legacyFeatureReport([powerOffCommand, 0x00])
        case .triton: tritonCommandReport(powerOffCommand)
        }
    }

    public static func rumbleReport(model: SteamControllerModel, leftAmplitude: UInt16, rightAmplitude: UInt16) -> SteamControllerFeatureReport {
        switch model {
        case .legacy:
            legacyFeatureReport([
                rumbleCommand, 0x00,
                UInt8(leftAmplitude & 0xff), UInt8((leftAmplitude >> 8) & 0xff),
                UInt8(rightAmplitude & 0xff), UInt8((rightAmplitude >> 8) & 0xff),
            ])
        case .triton:
            tritonRumbleReport(leftAmplitude: leftAmplitude, rightAmplitude: rightAmplitude)
        }
    }

    public static func lizardModeEnableReports(model: SteamControllerModel) -> [SteamControllerFeatureReport] {
        switch model {
        case .legacy:
            [
                legacyFeatureReport([defaultDigitalMappingsCommand, 0x00]),
                legacyFeatureReport([defaultSettingsCommand, 0x00]),
            ]
        case .triton:
            [
                tritonCommandReport(defaultDigitalMappingsCommand),
                tritonLizardModeSettingReport(tritonLizardModeOn),
            ]
        }
    }
}
