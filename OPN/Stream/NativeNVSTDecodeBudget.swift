import Foundation

/// How the client's decode time compares with the frame interval the session negotiated.
///
/// The seat paces to what the client reports it can decode: every frame-pacing report carries the
/// measured client frame time, and the seat's dynamic frame controller lowers the stream rate when
/// that runs past the target (`dfc.decodeFpsAdjPercent`). Measured 2026-09-04: 5K 10-bit 4:4:4
/// decodes in 10.0 ms mean against an 8.33 ms frame, 1525 of 1526 pacing reports were overruns,
/// and the stream settled at ~108 fps with the game following to 105. 4:2:0 at the same size
/// decodes in 7.7 ms and holds 120. This turns that into a HUD reading instead of a mystery.
enum NativeNVSTDecodeBudget {
    enum Level: Equatable, Sendable {
        case unknown
        /// Under 90% of the frame interval.
        case comfortable
        /// 90% or more: the next content spike will overrun.
        case tight
        /// At or past the interval: the seat is already lowering the frame rate to match.
        case over
    }

    static let tightFraction = 0.9

    static func frameIntervalMilliseconds(framesPerSecond: Double) -> Double? {
        guard framesPerSecond > 0 else { return nil }
        return 1000 / framesPerSecond
    }

    static func level(decodeMilliseconds: Double, framesPerSecond: Double) -> Level {
        guard decodeMilliseconds >= 0, let interval = frameIntervalMilliseconds(framesPerSecond: framesPerSecond) else { return .unknown }
        if decodeMilliseconds >= interval { return .over }
        if decodeMilliseconds >= interval * tightFraction { return .tight }
        return .comfortable
    }

    static func level(for snapshot: NativeNVSTPerformanceSnapshot) -> Level {
        guard snapshot.available else { return .unknown }
        return level(decodeMilliseconds: snapshot.decodeMilliseconds, framesPerSecond: snapshot.negotiatedFramesPerSecond)
    }

    /// The warning for an over-budget decode. Names bitrate as the lever, not the pixel format:
    /// measured 2026-09-05, Cyberpunk at 60–80 Mbps decoded in 7.3–9.4 ms at 3840x2160 and
    /// 5120x2160 alike, while Streets of Rage at the same 4K decoded in 7.0 ms — hardware decode
    /// time follows the bytes in the bitstream more than the pixels in the frame. 4:4:4 adds
    /// ~2 ms on top; that part the format does decide.
    static func warning(for snapshot: NativeNVSTPerformanceSnapshot) -> String? {
        guard level(for: snapshot) == .over,
              let interval = frameIntervalMilliseconds(framesPerSecond: snapshot.negotiatedFramesPerSecond) else { return nil }
        let format = snapshot.bitstreamFormat.isEmpty ? "" : " (\(snapshot.bitstreamFormat))"
        let bitrate = snapshot.bitrateMegabitsPerSecond > 0 ? String(format: " at %.0f Mbps", snapshot.bitrateMegabitsPerSecond) : ""
        let hint = snapshot.bitstreamFormat.contains("4:4:4") ? "A lower bitrate cap, a lower frame rate, or 4:2:0 fits it." : "A lower bitrate cap or a lower frame rate fits it."
        return String(format: "Decoding%@%@ takes %.1f ms per frame against a %.1f ms frame; the seat lowers the frame rate to match. %@",
                      format, bitrate, snapshot.decodeMilliseconds, interval, hint)
    }
}
