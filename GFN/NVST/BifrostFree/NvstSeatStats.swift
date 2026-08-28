import Foundation

/// The seat's own periodic statistics message, command `0x0101` ("qos-info", 80-byte payload).
///
/// Decoded from live captures on 2026-08-27 (5K/120 HEVC sessions): the double at payload
/// offset +32 tracked the game's render rate (120.89, 121.11 while the title ran uncapped at
/// 120), which is the number the vendored client showed as GAME FPS and this client had
/// hardcoded to `--`. The float at +40 is a small seconds-scale figure (34 ms and 59 ms during
/// session start) modelled as the seat-side latency estimate; the surrounding floats sit at
/// -1/+1 sentinels. The integers at +4 and +28 move with load and are carried raw for
/// calibration until their meaning is pinned.
public struct NvstSeatStats: Equatable, Sendable {
    public static let commandCode: UInt16 = 0x0101
    /// Payload length in every captured message.
    static let payloadLength = 80

    /// The game's render rate as the seat measures it.
    public let gameFramesPerSecond: Double
    /// Seconds-scale latency figure at +40; -1 when the seat marks it unavailable.
    public let latencySeconds: Double
    /// Uninterpreted counters at +4 and +28, for the calibration log.
    public let counterA: UInt32
    public let counterB: UInt32

    public static func from(_ command: NvstControlCommand) -> NvstSeatStats? {
        guard command.code == commandCode, command.payload.count >= payloadLength else { return nil }
        let bytes = [UInt8](command.payload)
        func uint32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }
        func uint64(_ offset: Int) -> UInt64 {
            UInt64(uint32(offset)) | UInt64(uint32(offset + 4)) << 32
        }
        let gameFps = Double(bitPattern: uint64(32))
        let latency = Float(bitPattern: uint32(40))
        // A stats message with an implausible rate is a misread, not a measurement.
        guard gameFps.isFinite, gameFps >= 0, gameFps < 1000 else { return nil }
        return NvstSeatStats(
            gameFramesPerSecond: gameFps,
            latencySeconds: latency.isFinite ? Double(latency) : -1,
            counterA: uint32(4),
            counterB: uint32(28)
        )
    }

    public var summary: String {
        String(format: "seatStats gameFps=%.1f latency=%.1fms a=%u b=%u",
               gameFramesPerSecond, latencySeconds * 1000, counterA, counterB)
    }
}
