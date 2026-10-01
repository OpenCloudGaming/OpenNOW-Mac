import Foundation

enum GamepadHIDFamily: String, CaseIterable, Sendable {
    case xbox
    case dualSense
    case dualShock4

    static let microsoftVendorID = 0x045E
    static let sonyVendorID = 0x054C

    init?(vendorID: Int, productID: Int, transport: String) {
        switch (vendorID, productID) {
        case (Self.sonyVendorID, 0x0CE6), (Self.sonyVendorID, 0x0DF2):
            self = .dualSense
        case (Self.sonyVendorID, 0x05C4), (Self.sonyVendorID, 0x09CC), (Self.sonyVendorID, 0x0BA0):
            self = .dualShock4
        // Only the Bluetooth report layout is known; a wired Xbox pad stays on GameController.
        case (Self.microsoftVendorID, _) where transport.localizedCaseInsensitiveContains("bluetooth"):
            self = .xbox
        default:
            return nil
        }
    }
}

enum GamepadHIDReport {
    private struct ButtonBit {
        let byte: Int
        let mask: UInt8
        let button: GamepadButtons
    }

    static func parse(_ report: [UInt8], family: GamepadHIDFamily, previous: ControllerInputSnapshot?) -> ControllerInputSnapshot? {
        let snapshot: ControllerInputSnapshot? = switch family {
        case .xbox: parseXbox(report, previous: previous)
        case .dualSense: parseDualSense(report)
        case .dualShock4: parseDualShock4(report)
        }
        guard var snapshot else { return nil }
        // These are the pad's raw report values, so the client deadzone must not be applied to them.
        // Stamped here so the decision travels with the values, not with the app-wide preference.
        snapshot.inputSource = .gamepadAPI
        return snapshot
    }

    static func axis(_ value: UInt8) -> Float {
        let centered = Int(value) - 128
        return Float(centered) / (centered < 0 ? 128 : 127)
    }

    static func axis(_ value: UInt16) -> Float {
        let centered = Int(value) - 32768
        return Float(centered) / (centered < 0 ? 32768 : 32767)
    }

    private static func parseXbox(_ report: [UInt8], previous: ControllerInputSnapshot?) -> ControllerInputSnapshot? {
        switch report.first {
        case 0x01 where report.count >= 16:
            return ControllerInputSnapshot(
                buttons: hat(Int(report[13]) - 1).union(xboxBitButtons(report, previous: previous)),
                leftTrigger: Float(word(report, 9) & 0x3FF) / 1023,
                rightTrigger: Float(word(report, 11) & 0x3FF) / 1023,
                leftStickX: axis(word(report, 1)),
                leftStickY: -axis(word(report, 3)),
                rightStickX: axis(word(report, 5)),
                rightStickY: -axis(word(report, 7))
            )
        case 0x02 where report.count >= 2:
            return xboxGuideState(report, previous: previous)
        default:
            return nil
        }
    }

    /// Pre-BLE firmware packs the buttons into 16-byte reports and sends the guide button alone.
    private static func xboxBitButtons(_ report: [UInt8], previous: ControllerInputSnapshot?) -> GamepadButtons {
        guard report.count == 16 else { return buttons(report, xboxButtonBits) }
        var legacy = buttons(report, xboxLegacyButtonBits)
        if previous?.buttons.contains(.mode) == true { legacy.insert(.mode) }
        return legacy
    }

    /// Report 0x02 carries the guide bit only, so it edits the previous snapshot rather than a new one.
    private static func xboxGuideState(_ report: [UInt8], previous: ControllerInputSnapshot?) -> ControllerInputSnapshot? {
        guard var snapshot = previous else { return nil }
        snapshot.buttons.remove(.mode)
        guard report[1] & 0x01 != 0 else { return snapshot }
        snapshot.buttons.insert(.mode)
        return snapshot
    }

    private static func parseDualSense(_ report: [UInt8]) -> ControllerInputSnapshot? {
        switch report.first {
        case 0x01 where report.count >= 64:
            dualSenseExtended(report, at: 1)
        case 0x01 where report.count >= 10:
            sonyCompact(report, at: 1)
        case 0x31 where report.count >= 12:
            dualSenseExtended(report, at: 2)
        default:
            nil
        }
    }

    private static func parseDualShock4(_ report: [UInt8]) -> ControllerInputSnapshot? {
        let offset: Int
        switch report.first {
        case 0x01 where report.count >= 10:
            offset = 1
        case .some(0x11...0x19) where report.count >= 12 && report[1] & 0x80 != 0:
            offset = 3
        default:
            return nil
        }
        var snapshot = sonyCompact(report, at: offset)
        snapshot.touchpad = dualShock4Touchpad(report, at: offset)
        return snapshot
    }

    private static func dualSenseExtended(_ report: [UInt8], at offset: Int) -> ControllerInputSnapshot {
        ControllerInputSnapshot(
            buttons: sonyButtons(report, at: offset + 7),
            leftTrigger: Float(report[offset + 4]) / 255,
            rightTrigger: Float(report[offset + 5]) / 255,
            leftStickX: axis(report[offset]),
            leftStickY: -axis(report[offset + 1]),
            rightStickX: axis(report[offset + 2]),
            rightStickY: -axis(report[offset + 3])
        )
    }

    private static func sonyCompact(_ report: [UInt8], at offset: Int) -> ControllerInputSnapshot {
        ControllerInputSnapshot(
            buttons: sonyButtons(report, at: offset + 4),
            leftTrigger: Float(report[offset + 7]) / 255,
            rightTrigger: Float(report[offset + 8]) / 255,
            leftStickX: axis(report[offset]),
            leftStickY: -axis(report[offset + 1]),
            rightStickX: axis(report[offset + 2]),
            rightStickY: -axis(report[offset + 3])
        )
    }

    private static func sonyButtons(_ report: [UInt8], at offset: Int) -> GamepadButtons {
        hat(Int(report[offset] & 0x0F)).union(buttons(report, sonyButtonBits, offset: offset))
    }

    private static func dualShock4Touchpad(_ report: [UInt8], at offset: Int) -> ControllerTrackpadState {
        var touchpad = ControllerTrackpadState(pressed: report[offset + 6] & 0x02 != 0)
        let point = offset + 34
        guard report.count >= point + 4, report[point] & 0x80 == 0 else { return touchpad }
        let x = Int(report[point + 1]) | Int(report[point + 2] & 0x0F) << 8
        let y = Int(report[point + 2] >> 4) | Int(report[point + 3]) << 4
        touchpad.touched = true
        touchpad.x = min(max(Float(x) / 1919 * 2 - 1, -1), 1)
        touchpad.y = min(max(1 - Float(y) / 941 * 2, -1), 1)
        return touchpad
    }

    private static let hatDirections: [GamepadButtons] = [
        .dpadUp, [.dpadUp, .dpadRight], .dpadRight, [.dpadDown, .dpadRight],
        .dpadDown, [.dpadDown, .dpadLeft], .dpadLeft, [.dpadUp, .dpadLeft],
    ]

    private static func hat(_ index: Int) -> GamepadButtons {
        hatDirections.indices.contains(index) ? hatDirections[index] : []
    }

    private static func word(_ report: [UInt8], _ index: Int) -> UInt16 {
        UInt16(report[index]) | UInt16(report[index + 1]) << 8
    }

    private static func buttons(_ report: [UInt8], _ bits: [ButtonBit], offset: Int = 0) -> GamepadButtons {
        bits.reduce(into: GamepadButtons()) { result, bit in
            if report[offset + bit.byte] & bit.mask != 0 { result.insert(bit.button) }
        }
    }

    private static let xboxButtonBits: [ButtonBit] = [
        ButtonBit(byte: 14, mask: 0x01, button: .south),
        ButtonBit(byte: 14, mask: 0x02, button: .east),
        ButtonBit(byte: 14, mask: 0x08, button: .west),
        ButtonBit(byte: 14, mask: 0x10, button: .north),
        ButtonBit(byte: 14, mask: 0x40, button: .leftShoulder),
        ButtonBit(byte: 14, mask: 0x80, button: .rightShoulder),
        ButtonBit(byte: 15, mask: 0x04, button: .select),
        ButtonBit(byte: 15, mask: 0x08, button: .start),
        ButtonBit(byte: 15, mask: 0x10, button: .mode),
        ButtonBit(byte: 15, mask: 0x20, button: .leftStick),
        ButtonBit(byte: 15, mask: 0x40, button: .rightStick),
    ]

    private static let xboxLegacyButtonBits: [ButtonBit] = [
        ButtonBit(byte: 14, mask: 0x01, button: .south),
        ButtonBit(byte: 14, mask: 0x02, button: .east),
        ButtonBit(byte: 14, mask: 0x04, button: .west),
        ButtonBit(byte: 14, mask: 0x08, button: .north),
        ButtonBit(byte: 14, mask: 0x10, button: .leftShoulder),
        ButtonBit(byte: 14, mask: 0x20, button: .rightShoulder),
        ButtonBit(byte: 14, mask: 0x40, button: .select),
        ButtonBit(byte: 14, mask: 0x80, button: .start),
        ButtonBit(byte: 15, mask: 0x01, button: .leftStick),
        ButtonBit(byte: 15, mask: 0x02, button: .rightStick),
    ]

    private static let sonyButtonBits: [ButtonBit] = [
        ButtonBit(byte: 0, mask: 0x10, button: .west),
        ButtonBit(byte: 0, mask: 0x20, button: .south),
        ButtonBit(byte: 0, mask: 0x40, button: .east),
        ButtonBit(byte: 0, mask: 0x80, button: .north),
        ButtonBit(byte: 1, mask: 0x01, button: .leftShoulder),
        ButtonBit(byte: 1, mask: 0x02, button: .rightShoulder),
        ButtonBit(byte: 1, mask: 0x10, button: .select),
        ButtonBit(byte: 1, mask: 0x20, button: .start),
        ButtonBit(byte: 1, mask: 0x40, button: .leftStick),
        ButtonBit(byte: 1, mask: 0x80, button: .rightStick),
        ButtonBit(byte: 2, mask: 0x01, button: .mode),
    ]
}
