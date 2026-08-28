import Foundation

/// The client's per-frame report, command `0x204`.
///
/// Recovered from 1790 captured reports from the native stack on a 30 s session that delivered
/// 1789 frames — one per frame, plus one at startup. `videoSplitEncodeStripsPerFrame` and the
/// seat's own telemetry (`FramePacingMode` = `1`) confirm the seat is running the client-fed frame
/// pacer that `video[0].framePacing.mode:1` and `framePacing.feedbackMode:1` ask for, and this is
/// what feeds it. Sending none is why the seat encoded 8.7 frames per second for us against 60.05
/// for the native stack on identical content: without a client cadence to pace to, the pacer has
/// nothing to open up against.
///
/// Two corroborations that the field reading is right: the frame sizes at `+72` sum to 2,914,715
/// bytes across the capture against the 2,925,246 the QoS report's own cumulative counter
/// reports, and the millisecond clock at `+12` advances 16.653 ms per frame, which is 60.05 fps.
public struct NvstFrameAck: Equatable, Sendable {
    public static let commandCode: UInt16 = 0x204
    public static let payloadLength = 102
    /// Constant in every captured report.
    static let version: UInt16 = 1
    static let fieldCount: UInt16 = 9
    /// A constant whose meaning the capture does not reveal; it never moves off 0x4000.
    static let constantAt84: UInt32 = 16384

    /// 1-based, one per frame.
    public let frameNumber: UInt32
    /// Client clock in milliseconds. Only the delta matters to the pacer, so any monotonic
    /// millisecond origin works.
    public let clientTimeMilliseconds: Double
    /// The assembled frame's size in bytes.
    public let frameBytes: UInt32
    /// Measured interval since the previous frame, microseconds. The capture centres this on
    /// 15905 µs — the pacer's view of the cadence the client is actually sustaining.
    public let interFrameMicroseconds: UInt32
    /// Five non-decreasing per-frame latency marks in milliseconds: the capture holds a rising
    /// series like 29.31, 31.01, 31.40, 31.45, 33.34 for one frame, so these are pipeline stage
    /// times measured from the same frame origin.
    public let stageMilliseconds: [Float]
    /// The remaining per-frame float measurements, in payload order at +20, +24, +52, +56, +60
    /// and +64. The capture's ranges are small millisecond figures.
    public let auxiliaryMilliseconds: [Float]

    public init(frameNumber: UInt32,
                clientTimeMilliseconds: Double,
                frameBytes: UInt32,
                interFrameMicroseconds: UInt32,
                stageMilliseconds: [Float],
                auxiliaryMilliseconds: [Float] = [0, 0, 0, 0, 0, 0]) {
        self.frameNumber = frameNumber
        self.clientTimeMilliseconds = clientTimeMilliseconds
        self.frameBytes = frameBytes
        self.interFrameMicroseconds = interFrameMicroseconds
        self.stageMilliseconds = stageMilliseconds
        self.auxiliaryMilliseconds = auxiliaryMilliseconds
    }

    public var payload: Data {
        var data = Data(repeating: 0, count: Self.payloadLength)
        func put16(_ value: UInt16, at offset: Int) {
            data[offset] = UInt8(truncatingIfNeeded: value)
            data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        }
        func put32(_ value: UInt32, at offset: Int) {
            for byte in 0..<4 { data[offset + byte] = UInt8(truncatingIfNeeded: value >> UInt32(byte * 8)) }
        }
        func putFloat(_ value: Float, at offset: Int) { put32(value.bitPattern, at: offset) }
        func putDouble(_ value: Double, at offset: Int) {
            let bits = value.bitPattern
            for byte in 0..<8 { data[offset + byte] = UInt8(truncatingIfNeeded: bits >> UInt64(byte * 8)) }
        }

        put16(Self.version, at: 0)
        put16(Self.fieldCount, at: 2)
        put32(frameNumber, at: 4)
        putDouble(clientTimeMilliseconds, at: 12)

        let aux = auxiliaryMilliseconds + Array(repeating: 0, count: max(0, 6 - auxiliaryMilliseconds.count))
        putFloat(aux[0], at: 20)
        putFloat(aux[1], at: 24)

        // Five rising stage marks. A short series repeats its last value rather than reporting a
        // stage as instantaneous, which would read as a pipeline that skipped it.
        var stages = stageMilliseconds
        if stages.isEmpty { stages = [0] }
        for index in 0..<5 { putFloat(stages[min(index, stages.count - 1)], at: 28 + index * 4) }

        putFloat(-1, at: 48)
        putFloat(aux[2], at: 52)
        putFloat(aux[3], at: 56)
        putFloat(aux[4], at: 60)
        putFloat(aux[5], at: 64)
        put32(frameBytes, at: 72)
        put32(Self.constantAt84, at: 84)
        put32(interFrameMicroseconds, at: 96)
        return data
    }

    public var command: NvstControlCommand {
        NvstControlCommand(code: Self.commandCode, payload: payload)
    }
}
