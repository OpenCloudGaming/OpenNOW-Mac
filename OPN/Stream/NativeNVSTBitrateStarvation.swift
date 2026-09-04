import Foundation

/// Decides when a low inbound bitrate is worth warning about on the NVST transport.
///
/// Bitrate alone is not a signal here: the seat skips unchanged frames, so a menu or a paused game
/// encodes at a few hundred bytes a frame with the link perfectly healthy, and the old "under
/// 5 Mbps" rule fired on every one of them. Nor is a low frame rate on its own — a static scene
/// measured live at 1.0 Mbps and 40 stream fps with the game rendering 116, zero loss: the seat
/// simply had nothing new to send. What a starved link adds that a quiet scene never does is
/// loss or jitter on the packets that do arrive. So the shape is all three — low bitrate, a frame
/// rate well under the negotiated one, and loss or jitter in the same interval — held for
/// `holdSeconds`.
struct NativeNVSTBitrateStarvationTracker: Equatable, Sendable {
    /// Seconds the starved shape has to persist before it counts. A scene cut or a loading screen
    /// dips both numbers for a moment; a throttled link keeps them down.
    static let holdSeconds: TimeInterval = 10
    static let lowBitrateMegabitsPerSecond = 5.0
    /// Fraction of the negotiated frame rate below which frames count as arriving short.
    static let frameRateShortfall = 0.8
    /// Interval jitter that counts as the network struggling, matching the HUD's "Fair" threshold.
    static let jitterMilliseconds = 20.0

    private(set) var since: Date?
    private(set) var isStarved = false

    static func looksStarved(_ snapshot: NativeNVSTPerformanceSnapshot) -> Bool {
        guard snapshot.available,
              snapshot.bitrateMegabitsPerSecond >= 0,
              snapshot.bitrateMegabitsPerSecond < lowBitrateMegabitsPerSecond,
              snapshot.negotiatedFramesPerSecond > 0,
              snapshot.streamFramesPerSecond < snapshot.negotiatedFramesPerSecond * frameRateShortfall else { return false }
        return snapshot.packetLossPercent > 0 || snapshot.jitterMilliseconds >= jitterMilliseconds
    }

    /// Feeds one HUD sample; returns the current verdict.
    @discardableResult
    mutating func update(_ snapshot: NativeNVSTPerformanceSnapshot, now: Date = Date()) -> Bool {
        guard Self.looksStarved(snapshot) else {
            since = nil
            isStarved = false
            return false
        }
        let start = since ?? now
        since = start
        isStarved = now.timeIntervalSince(start) >= Self.holdSeconds
        return isStarved
    }

    mutating func reset() {
        since = nil
        isStarved = false
    }
}
