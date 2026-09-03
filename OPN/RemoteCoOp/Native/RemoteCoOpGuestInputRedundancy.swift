//  The input channel is unordered with no retransmits, and the sender emits only on change - so one
//  lost packet is a *stuck* input, not a dropped one, and re-polling cannot recover it because the
//  poll sees the state it believes it already sent. Fixed by sending each state more than once:
//  packets carry absolute pad state, so a duplicate is a no-op.
//
//  Split from the sender because the sender needs a physical controller to test and this does not.
//

import Foundation

public struct OPNRemoteCoOpGuestInputRedundancyPolicy: Equatable, Sendable {
    public static let redundantSendCount = 2
    /// Ceiling on how long a lost packet can leave the host holding something the guest let go of.
    public static let keepaliveNanoseconds: UInt64 = 100_000_000

    private var pendingRedundantSends = 0
    private var lastSentAtNanoseconds: UInt64?

    public init() {}

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
