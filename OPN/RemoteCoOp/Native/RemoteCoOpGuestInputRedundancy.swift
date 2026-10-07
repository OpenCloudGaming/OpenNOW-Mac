//  The input channel is unordered with no retransmits, and the sender emits only on change - so one
//  lost packet is a *stuck* input, not a dropped one, and re-polling cannot recover it because the
//  poll sees the state it believes it already sent. Fixed by sending each state more than once:
//  packets carry absolute pad state, so a duplicate is a no-op.
//
//  This policy is the entire reason the guest input sender owns a timer. It is not a sampler -
//  `valueChangedHandler` is - and it is not a fixed cadence either: `nextSendDelayNanoseconds`
//  reports when the next copy is actually due and the sender arms a one-shot timer for exactly that
//  moment, and `nil` once there is nothing outstanding, which leaves that timer unarmed. Delivering
//  the copies on a fixed 200 Hz poll instead cost 200 wakeups a second for a channel that is idle
//  almost all of the time, and the copies themselves only ever need to arrive within the keepalive.
//

import Foundation

public struct OPNRemoteCoOpGuestInputRedundancyPolicy: Equatable, Sendable {
    public static let redundantSendCount = 2
    /// Ceiling on how long a lost packet can leave the host holding something the guest let go of.
    public static let keepaliveNanoseconds: UInt64 = 100_000_000

    private var pendingRedundantSends = 0
    private var lastSentAtNanoseconds: UInt64?

    public init() {}

    /// When the caller should next tick this policy, or `nil` when it has nothing outstanding and
    /// should leave its timer unarmed.
    ///
    /// `redundantSendIntervalNanoseconds` is the gap between the copies of one change. They are
    /// spread rather than sent back to back on purpose: a burst loss that takes the original takes
    /// an immediate copy with it. It is also what bounds the repeat packet rate, which is why it is
    /// a time and not a count - a pad reporting at 1 kHz must not get 1 kHz of repeats.
    public func nextSendDelayNanoseconds(nowNanoseconds: UInt64,
                                         redundantSendIntervalNanoseconds: UInt64) -> UInt64? {
        guard let lastSentAtNanoseconds else { return nil }
        if pendingRedundantSends > 0 { return max(1, redundantSendIntervalNanoseconds) }
        // Guarded against a backwards reading, exactly as `shouldSend` is.
        guard nowNanoseconds >= lastSentAtNanoseconds else { return Self.keepaliveNanoseconds }
        let elapsed = nowNanoseconds - lastSentAtNanoseconds
        return elapsed >= Self.keepaliveNanoseconds ? 0 : Self.keepaliveNanoseconds - elapsed
    }

    /// `allowRedundantSend` is true only from the safety timer; repeating from the HID callback would
    /// multiply the pad's own report rate.
    public mutating func shouldSend(isChanged: Bool, allowRedundantSend: Bool, nowNanoseconds: UInt64) -> Bool {
        if isChanged {
            // Resets any burst in flight: those copies describe a state the guest has already left.
            pendingRedundantSends = Self.redundantSendCount
            lastSentAtNanoseconds = nowNanoseconds
            return true
        }
        guard allowRedundantSend else { return false }
        if pendingRedundantSends > 0 {
            pendingRedundantSends -= 1
            lastSentAtNanoseconds = nowNanoseconds
            return true
        }
        // Guarded against a backwards reading: unsigned subtraction on a stale value from the other
        // thread would underflow and fire a keepalive every tick.
        guard let lastSentAtNanoseconds else {
            self.lastSentAtNanoseconds = nowNanoseconds
            return true
        }
        guard nowNanoseconds >= lastSentAtNanoseconds, nowNanoseconds - lastSentAtNanoseconds >= Self.keepaliveNanoseconds else { return false }
        self.lastSentAtNanoseconds = nowNanoseconds
        return true
    }
}
