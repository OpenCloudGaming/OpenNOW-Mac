public enum GeronimoInputEventType: UInt32, CaseIterable, Sendable {
    case heartbeat = 2
    case keyDown = 3
    case keyUp = 4
    case mouseRelative = 7
    case mouseButtonDown = 8
    case mouseButtonUp = 9
    case mouseWheel = 10
    case gamepad = 12
    case utf8Text = 23
}

public enum GeronimoInputChannel: Sendable {
    public static let reliableLabel = "input_channel_v1"
    public static let partiallyReliableLabel = "input_channel_partially_reliable"
    public static let partialReliableInputLifetimeMs: Int32 = 5
    public static let partialReliableInputBacklogLimitBytes: UInt64 = 16 * 1024
    public static let mouseInputBacklogLimitBytes: UInt64 = 512
    public static let gamepadInputBacklogLimitBytes: UInt64 = 512
}

public enum GeronimoInputEnvelope: Sendable {
    public static let headerByte: UInt8 = 0x23
    public static let lengthPrefixedPayloadTag: UInt8 = 0x21
    public static let singleReliablePayloadTag: UInt8 = 0x22
    public static let partiallyReliablePayloadTag: UInt8 = 0x26
}

public enum GeronimoInputHandshake: Sendable {
    public static let littleEndianVersionMarker: UInt16 = 526
    public static let leadingVersionByte: UInt8 = 0x0e
}
