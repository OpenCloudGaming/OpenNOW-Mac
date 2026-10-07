//  The redundancy policy drives the guest input sender's timer, so its timing is the whole cost of
//  that safety net. These tests run the sender's arm/tick loop against a simulated clock.
//

import Foundation
import Testing
@testable import OpenNOW

/// Mirrors the sender's timer: a change is sent from the HID callback, then a one-shot timer is armed
/// for exactly the moment `nextSendDelayNanoseconds` names, fires once, and re-arms.
private struct SafetyNetSimulation {
    static let redundantSendIntervalNanoseconds: UInt64 = 20_000_000

    private(set) var nowNanoseconds: UInt64 = 0
    private(set) var timerWakeupCount = 0
    private(set) var sendTimestampsNanoseconds: [UInt64] = []
    private var policy = OPNRemoteCoOpGuestInputRedundancyPolicy()

    mutating func sendAStateChange(at nanoseconds: UInt64) {
        nowNanoseconds = nanoseconds
        recordASend(isChanged: true, isRedundantSendAllowed: false)
    }

    /// Runs the timer to `endNanoseconds`, counting the wakeups a real `DispatchSourceTimer` would
    /// have taken. Stops early when the policy has nothing outstanding, which is what leaves it unarmed.
    mutating func runTheTimer(until endNanoseconds: UInt64) {
        while let delayNanoseconds = policy.nextSendDelayNanoseconds(
            nowNanoseconds: nowNanoseconds,
            redundantSendIntervalNanoseconds: Self.redundantSendIntervalNanoseconds
        ) {
            nowNanoseconds += delayNanoseconds
            guard nowNanoseconds <= endNanoseconds else { return }
            timerWakeupCount += 1
            recordASend(isChanged: false, isRedundantSendAllowed: true)
        }
    }

    private mutating func recordASend(isChanged: Bool, isRedundantSendAllowed: Bool) {
        let shouldSend = policy.shouldSend(isChanged: isChanged,
                                           allowRedundantSend: isRedundantSendAllowed,
                                           nowNanoseconds: nowNanoseconds)
        guard shouldSend else { return }
        sendTimestampsNanoseconds.append(nowNanoseconds)
    }
}

@Suite("Remote Co-Op guest input redundancy")
struct RemoteCoOpGuestInputRedundancyTests {
    private let keepaliveCeilingNanoseconds = OPNRemoteCoOpGuestInputRedundancyPolicy.keepaliveNanoseconds

    /// One lost packet is a stuck input, so a change has to go out three times - and not back to
    /// back, or a single burst loss takes all three.
    @Test func aChangeReachesTheHostThreeTimes() {
        var simulation = SafetyNetSimulation()
        simulation.sendAStateChange(at: 0)
        simulation.runTheTimer(until: 100_000_000)

        #expect(simulation.sendTimestampsNanoseconds == [0, 20_000_000, 40_000_000])
    }

    /// The copies of a state the guest has already left are dropped rather than sent late.
    @Test func aSupersededChangeIsNeverSentAgain() {
        var simulation = SafetyNetSimulation()
        simulation.sendAStateChange(at: 0)
        simulation.sendAStateChange(at: 5_000_000)
        simulation.runTheTimer(until: 200_000_000)

        #expect(simulation.sendTimestampsNanoseconds.prefix(4) == [0, 5_000_000, 25_000_000, 45_000_000])
    }

    /// A held axis produces no HID reports, so the host has only the keepalive to rely on and it has
    /// to arrive inside the documented ceiling rather than on the next change.
    @Test func aHeldAxisIsKeptAliveAtTheDocumentedCeiling() {
        var simulation = SafetyNetSimulation()
        simulation.sendAStateChange(at: 0)
        simulation.runTheTimer(until: 1_000_000_000)

        let keepaliveTimestamps = simulation.sendTimestampsNanoseconds.filter { $0 > 40_000_000 }
        #expect(keepaliveTimestamps == [140_000_000, 240_000_000, 340_000_000, 440_000_000,
                                        540_000_000, 640_000_000, 740_000_000, 840_000_000, 940_000_000])
    }

    /// A held session used to wake a timer 200 times a second for its whole length.
    @Test func aHeldAxisWakesTheTimerTenTimesASecondInsteadOfTwoHundred() {
        let heldSeconds: UInt64 = 10
        var simulation = SafetyNetSimulation()
        simulation.sendAStateChange(at: 0)
        simulation.runTheTimer(until: heldSeconds * 1_000_000_000)

        // Ten keepalives a second plus the two copies of the change; a 200 Hz poll spends 2000.
        #expect(simulation.timerWakeupCount <= Int(heldSeconds) * 10 + 2)
        #expect(simulation.timerWakeupCount < Int(heldSeconds) * 20)
    }

    /// With nothing to keep alive there is no timer at all, which is where a guest session sits
    /// before anyone touches a pad.
    @Test func anUntouchedSessionArmsNoTimer() {
        var simulation = SafetyNetSimulation()
        simulation.runTheTimer(until: 60_000_000_000)

        #expect(simulation.timerWakeupCount == 0)
        #expect(simulation.sendTimestampsNanoseconds.isEmpty)
    }

    /// A pad unplugged mid-hold leaves the seat holding whatever it had, so the synthesised release
    /// has to survive the same unreliable channel as anything else.
    @Test func aReleaseSynthesisedByADisconnectIsRepeatedThenKeptAlive() {
        var simulation = SafetyNetSimulation()
        simulation.sendAStateChange(at: 0)
        simulation.runTheTimer(until: 500_000_000)
        simulation.sendAStateChange(at: 500_000_000)
        simulation.runTheTimer(until: 1_000_000_000)

        let releaseTimestamps = simulation.sendTimestampsNanoseconds.filter { $0 >= 500_000_000 }
        #expect(releaseTimestamps.prefix(3) == [500_000_000, 520_000_000, 540_000_000])
        #expect(releaseTimestamps.last == 940_000_000)
    }

    /// The property the held-axis and disconnect scenarios rest on: once anything has been sent, no
    /// gap between sends may exceed the ceiling the policy documents.
    @Test func theHostIsNeverLeftHoldingAStatePastTheCeiling() {
        var simulation = SafetyNetSimulation()
        simulation.sendAStateChange(at: 0)
        simulation.runTheTimer(until: 200_000_000)
        simulation.sendAStateChange(at: 200_000_000)
        simulation.sendAStateChange(at: 205_000_000)
        simulation.runTheTimer(until: 1_500_000_000)
        simulation.sendAStateChange(at: 1_500_000_000)
        simulation.runTheTimer(until: 3_000_000_000)

        let sendTimestamps = simulation.sendTimestampsNanoseconds
        #expect(sendTimestamps.count > 3)
        for (previous, next) in zip(sendTimestamps, sendTimestamps.dropFirst()) {
            #expect(next - previous <= keepaliveCeilingNanoseconds)
        }
    }

    /// A stale clock reading used to underflow the unsigned subtraction and fire a keepalive every
    /// tick. The delay the timer is armed with must not go the same way.
    @Test func aStaleClockReadingDoesNotShortenTheKeepalive() {
        var policy = OPNRemoteCoOpGuestInputRedundancyPolicy()
        _ = policy.shouldSend(isChanged: true, allowRedundantSend: false, nowNanoseconds: 1_000_000_000)
        _ = policy.shouldSend(isChanged: false, allowRedundantSend: true, nowNanoseconds: 1_020_000_000)
        _ = policy.shouldSend(isChanged: false, allowRedundantSend: true, nowNanoseconds: 1_040_000_000)

        #expect(policy.nextSendDelayNanoseconds(nowNanoseconds: 500_000_000,
                                                redundantSendIntervalNanoseconds: 20_000_000) == keepaliveCeilingNanoseconds)
    }

    /// A repeat interval of zero would put the copies back to back, so it is a floor.
    @Test func aZeroRepeatIntervalStillSpreadsTheCopies() {
        var policy = OPNRemoteCoOpGuestInputRedundancyPolicy()
        _ = policy.shouldSend(isChanged: true, allowRedundantSend: false, nowNanoseconds: 0)

        #expect(policy.nextSendDelayNanoseconds(nowNanoseconds: 0,
                                                redundantSendIntervalNanoseconds: 0) == 1)
    }
}
