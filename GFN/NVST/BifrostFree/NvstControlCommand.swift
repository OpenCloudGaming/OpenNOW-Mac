import Foundation

/// One NVST control-plane command packet.
///
/// The wire format is fixed by `ReadCommandPacket`/`CommandPacketWrite` in NVIDIA's control
/// plane: a little-endian 16-bit command code, a little-endian 16-bit payload length, then the
/// payload. Several packets can share one SCTP message, so parsing walks the buffer.
public struct NvstControlCommand: Equatable, Sendable {
    public static let headerLength = 4

    public let code: UInt16
    public let payload: Data

    public init(code: UInt16, payload: Data) {
        self.code = code
        self.payload = payload
    }

    /// Parses every command packet in one channel message. A truncated trailing packet is
    /// reported through `trailing` rather than dropped, because a short read is itself evidence
    /// that the framing assumption is wrong.
    public static func parse(_ data: Data) -> (commands: [NvstControlCommand], trailing: Data) {
        var commands: [NvstControlCommand] = []
        var cursor = data.startIndex
        while data.distance(from: cursor, to: data.endIndex) >= headerLength {
            let bytes = [UInt8](data[cursor..<data.index(cursor, offsetBy: headerLength)])
            let code = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
            let length = Int(UInt16(bytes[2]) | UInt16(bytes[3]) << 8)
            let bodyStart = data.index(cursor, offsetBy: headerLength)
            guard data.distance(from: bodyStart, to: data.endIndex) >= length else { break }
            let bodyEnd = data.index(bodyStart, offsetBy: length)
            commands.append(NvstControlCommand(code: code, payload: Data(data[bodyStart..<bodyEnd])))
            cursor = bodyEnd
        }
        return (commands, Data(data[cursor..<data.endIndex]))
    }

    /// The packet as it goes on the wire.
    public var encoded: Data {
        var data = Data(capacity: Self.headerLength + payload.count)
        data.append(UInt8(code & 0xff))
        data.append(UInt8(code >> 8))
        let length = UInt16(clamping: payload.count)
        data.append(UInt8(length & 0xff))
        data.append(UInt8(length >> 8))
        data.append(payload)
        return data
    }

    /// The control-channel keepalive. `ServerControl::sendPingBackACK` writes command `0x200` with
    /// a single 32-bit stream value; the seat ends the session with `NVST_NETERR_CLIENT_TIMED_OUT`
    /// when it does not arrive inside `general.enetControlChannel.pingBackTimeoutMs` (10 s, with
    /// the client sending every 3 s).
    public static let pingBackAckCode: UInt16 = 0x200
    public static let pingBackIntervalSeconds: TimeInterval = 3

    public static func pingBackAck(streamValue: UInt32) -> NvstControlCommand {
        var payload = Data(capacity: 4)
        payload.append(UInt8(streamValue & 0xff))
        payload.append(UInt8((streamValue >> 8) & 0xff))
        payload.append(UInt8((streamValue >> 16) & 0xff))
        payload.append(UInt8((streamValue >> 24) & 0xff))
        return NvstControlCommand(code: pingBackAckCode, payload: payload)
    }

    /// `ServerControl::sendIdrRequest`: command `0x302` with the stream index as a 16-bit
    /// little-endian payload. This is how a keyframe is asked for when the seat never opens
    /// `rtcp_on_sctp_private`, so a PLI has nowhere to go.
    public static let idrRequestCode: UInt16 = 0x302

    public static func idrRequest(streamIndex: UInt16 = 0) -> NvstControlCommand {
        NvstControlCommand(code: idrRequestCode,
                           payload: Data([UInt8(streamIndex & 0xff), UInt8(streamIndex >> 8)]))
    }

    /// `ServerControl::sendFrameInvalidationRange`: command `0x301` with three 64-bit
    /// little-endian words — first frame, last frame, stream index. This is the recovery the
    /// official client is configured for (`video[0].refPicInvalidation:1`): rather than demanding a
    /// full IDR, it names the frames it could not decode so the encoder stops referencing them.
    public static let frameInvalidationRangeCode: UInt16 = 0x301

    public static func frameInvalidationRange(first: UInt64, last: UInt64, streamIndex: UInt64 = 0) -> NvstControlCommand {
        var payload = Data(capacity: 24)
        for word in [first, last, streamIndex] {
            for shift in stride(from: 0, through: 56, by: 8) {
                payload.append(UInt8((word >> UInt64(shift)) & 0xff))
            }
        }
        return NvstControlCommand(code: frameInvalidationRangeCode, payload: payload)
    }

    /// `ServerControl::sendWindowStateChange` / `sendSystemStateChange`: commands `0x320` and
    /// `0x321`, each a 12-byte payload of three little-endian 32-bit words. The official client
    /// sends both exactly once, shortly after PLAY, with zeros — its log reads
    /// `Window State Change: 0 requested at frame number: 0`.
    public static let windowStateChangeCode: UInt16 = 0x320
    public static let systemStateChangeCode: UInt16 = 0x321

    /// Three little-endian `UInt32`s: stream index, requested state, frame number — in that order.
    /// We previously wrote the state into the FIRST word, which only looked right because every
    /// value we sent was zero. It matters now that the window state is non-zero.
    static func stateChange(code: UInt16, streamIndex: UInt32 = 0, state: UInt32, frameNumber: UInt32) -> NvstControlCommand {
        var payload = Data(capacity: 12)
        for word in [streamIndex, state, frameNumber] {
            for shift in stride(from: 0, through: 24, by: 8) {
                payload.append(UInt8(truncatingIfNeeded: word >> UInt32(shift)))
            }
        }
        return NvstControlCommand(code: code, payload: payload)
    }

    /// The desktop client announces window state 19 at frame zero once input is activated. An
    /// all-zero window state leaves the session looking inactive to the seat, which then never
    /// sends its system-cursor mode updates — so the client cannot know when to hide its own
    /// pointer. That silence is half of the double-cursor bug.
    public static let activeWindowState: UInt32 = 19

    public static func windowStateChange(state: UInt32 = activeWindowState, frameNumber: UInt32 = 0) -> NvstControlCommand {
        stateChange(code: windowStateChangeCode, state: state, frameNumber: frameNumber)
    }

    public static func systemStateChange(state: UInt32 = 0, frameNumber: UInt32 = 0) -> NvstControlCommand {
        stateChange(code: systemStateChangeCode, state: state, frameNumber: frameNumber)
    }

    /// Names recovered from the control-plane dispatcher. Server-to-client notifications occupy
    /// `0x1xx`; the `0x2xx`/`0x3xx`/`0x4xx` ranges are what the client sends.
    public static func name(for code: UInt16) -> String? {
        switch code {
        case 0x101: "qos-info"
        case 0x102: "command-outcome"
        case 0x103, 0x104, 0x105: "termination-timer"
        case 0x106: "gamepad-handling"
        case 0x109: "termination"
        case 0x10a: "ri-packet"
        case 0x10b: "controller-scheme-info"
        case 0x10d: "hdr-mode"
        case 0x10e, 0x10f: "cursor-info"
        case 0x110: "video-stream-progress"
        case 0x111: "frame-pacing"
        case 0x113: "ri-packet"
        case 0x200: "ping-back-ack"
        case 0x202: "audio-stats"
        case 0x203: "client-processing-times"
        case 0x204: "frame-decoded-stats"
        case 0x205: "dc-stats"
        case 0x206: "cursor-detail"
        case 0x207: "qos-feedback"
        case 0x20b: "rtp-nack-toggle"
        case 0x20c: "fec-update"
        case 0x211: "client-blob-containers"
        case 0x300: "disconnect-notification"
        case 0x301: "frame-invalidation-range"
        case 0x302: "idr-request"
        case 0x303: "frame-rate-change"
        case 0x304: "stats-recording"
        case 0x305: "etw-trace-control"
        case 0x306: "network-capture"
        case 0x308: "mouse-cursor-capture"
        case 0x30c: "nvwac-invalidation"
        case 0x30d: "mimic-remote-cursor"
        case 0x30e: "server-content-capture"
        case 0x30f: "resolution-change"
        case 0x310: "frame-generic-stats"
        case 0x311: "remote-trace-print"
        case 0x312: "recovery-mode"
        case 0x314: "perf-indicator"
        case 0x315: "network-throttling"
        case 0x316: "packet-size-change"
        case 0x317: "rtp-nack-request"
        case 0x318: "max-bitrate-change"
        case 0x31e: "remote-trace-print-pair"
        case 0x31f: "gs-blob-defs"
        case 0x320: "window-state-change"
        case 0x321: "system-state-change"
        case 0x322: "mimic-cursor-strategy"
        case 0x323: "l4s-state-change"
        case 0x324: "video-quality-snapshot"
        case 0x325: "vqs-response"
        case 0x327: "qp-delta-map"
        case 0x329: "qos-preference-change"
        case 0x405: "stutter-indicator"
        case 0x406: "ri-device-overlay"
        case 0x408: "audio-surround-info"
        default: nil
        }
    }

    /// The termination notification carries its `NvstResult_t` as a big-endian 32-bit word — the
    /// dispatcher byte-swaps it before formatting, so the wire order is network order.
    public var terminationReason: UInt32? {
        guard code == 0x109, payload.count >= 4 else { return nil }
        let bytes = [UInt8](payload.prefix(4))
        return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    }

    /// The command the server is reporting on, plus its outcome.
    public var commandOutcome: (command: UInt16, outcome: UInt16)? {
        guard code == 0x102, payload.count >= 4 else { return nil }
        let bytes = [UInt8](payload.prefix(4))
        return (UInt16(bytes[0]) | UInt16(bytes[1]) << 8, UInt16(bytes[2]) | UInt16(bytes[3]) << 8)
    }

    /// Whether the payload is printable text — the seat sends some control messages as JSON.
    public var isTextual: Bool {
        guard payload.count >= 2 else { return false }
        let sample = payload.prefix(64)
        let printable = sample.filter { $0 == 0x09 || $0 == 0x0a || $0 == 0x0d || ($0 >= 0x20 && $0 < 0x7f) }
        return printable.count == sample.count && (payload.first == UInt8(ascii: "{") || payload.first == UInt8(ascii: "["))
    }

    /// The payload decoded as UTF-8, bounded so one message cannot flood the log.
    public func text(limit: Int = 600) -> String {
        let body = payload.prefix(limit)
        let decoded = String(decoding: body, as: UTF8.self)
        return payload.count > limit ? decoded + "…(\(payload.count) bytes)" : decoded
    }

    /// A single log-line description: named code, payload size, and the decoded fields that say
    /// why a session is ending.
    public var summary: String {
        var text = String(format: "0x%04x", code)
        if let name = Self.name(for: code) { text += " (\(name))" }
        text += " len=\(payload.count)"
        if let reason = terminationReason { text += " reason=\(NvstResultCode.describe(reason))" }
        if let outcome = commandOutcome {
            text += String(format: " forCommand=0x%04x outcome=%u", outcome.command, outcome.outcome)
        }
        return text
    }
}
