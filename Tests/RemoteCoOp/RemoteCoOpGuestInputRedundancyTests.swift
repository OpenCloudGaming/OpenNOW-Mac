//  The redundancy policy drives the guest input sender's timer, so its timing is the whole cost of
//  that safety net. These tests run the sender's arm/tick loop against a simulated clock: the policy
//  decides when the next copy is due, the loop counts the wakeups a real `DispatchSourceTimer` would
//  have taken to deliver it, and the sends it produced are checked against the two properties that
//  matter - a change reaches the host three times, and the host is never left holding a state for
//  longer than the documented ceiling.
//

import Foundation
import Testing
@testable import OpenNOW

/// Mirrors `OPNRemoteCoOpNativeGuestInputSender`'s timer: a change is sent from the HID callback,
/// then a one-shot timer is armed for exactly the moment `nextSendDelayNanoseconds` names, fires
/// once, and re-arms. `wakeups` is what the fixed 200 Hz poll used to spend unconditionally.
private struct SafetyNetSimulation {
    static let redundantSendIntervalNanoseconds: UInt64 = 20_000_000

    private(set) var nowNanoseconds: UInt64 = 0
    private(set) var wakeups = 0
    private(set) var sendNanoseconds: [UInt64] = []
    private var policy = OPNRemoteCoOpGuestInputRedundancyPolicy()

    /// The HID callback: a state change goes out immediately.
    mutating func changeState(at nanoseconds: UInt64) {
        nowNanoseconds = nanoseconds
        send(isChanged: true, allowRedundantSend: false)
    }

    /// Everything the timer does between `nowNanoseconds` and `endNanoseconds`, including the wakeups
    /// it would have taken. Stops early when the policy has nothing outstanding, which is what leaves
    /// the real timer unarmed.
    mutating func runTimer(until endNanoseconds: UInt64) {
        while let delay = policy.nextSendDelayNanoseconds(
            nowNanoseconds: nowNanoseconds,
            redundantSendIntervalNanoseconds: Self.redundantSendIntervalNanoseconds
        ) {
            nowNanoseconds += delay
            guard nowNanoseconds <= endNanoseconds else { return }
            wakeups += 1
            send(isChanged: false, allowRedundantSend: true)
        }
    }

    private mutating func send(isChanged: Bool, allowRedundantSend: Bool) {
        let shouldSend = policy.shouldSend(isChanged: isChanged,
                                           allowRedundantSend: allowRedundantSend,
                                           nowNanoseconds: nowNanoseconds)
        guard shouldSend else { return }
        sendNanoseconds.append(nowNanoseconds)
    }
}

@Suite struct RemoteCoOpGuestInputRedundancyTests {
    private let ceiling = OPNRemoteCoOpGuestInputRedundancyPolicy.keepaliveNanoseconds

    /// The reason the safety net exists: the channel is UDP with no retransmits, so one lost packet
    /// is a stuck input. A change must therefore go out more than once, and the copies must not be
    /// back to back or one burst loss takes all of them.
    @Test func aChangeIsSentImmediatelyAndThenTwiceMore() {
        var simulation = SafetyNetSimulation()
        simulation.changeState(at: 0)
        simulation.runTimer(until: 100_000_000)

        #expect(simulation.sendNanoseconds.prefix(3) == [0, 20_000_000, 40_000_000])
    }

    /// The second copy of a change that was itself replaced describes a state the guest has already
    /// left, so it is dropped rather than sent late.
    @Test func aNewChangeReplacesTheCopiesOfTheOneBeforeIt() {
        var simulation = SafetyNetSimulation()
        simulation.changeState(at: 0)
        simulation.changeState(at: 5_000_000)
        simulation.runTimer(until: 200_000_000)

        #expect(simulation.sendNanoseconds.prefix(4) == [0, 5_000_000, 25_000_000, 45_000_000])
    }

    /// An axis held at a constant value produces no HID reports, so the host has nothing but the
    /// keepalive to rely on. It has to arrive inside the documented ceiling, not on the next change.
    @Test func aHeldAxisIsKeptAliveAtTheDocumentedCeiling() {
        var simulation = SafetyNetSimulation()
        simulation.changeState(at: 0)
        simulation.runTimer(until: 1_000_000_000)

        let keepalives = simulation.sendNanoseconds.filter { $0 > 40_000_000 }
        #expect(keepalives == [140_000_000, 240_000_000, 340_000_000, 440_000_000,
                               540_000_000, 640_000_000, 740_000_000, 840_000_000, 940_000_000])
    }

    /// The acceptance criterion for this issue: a session that is being held, not driven, used to
    /// wake a timer 200 times a second for the whole session. The demand-driven timer wakes it ten
    /// times a second once the copies of the last change are out.
    @Test func aHeldAxisCostsTenWakeupsASecondInsteadOfTwoHundred() {
        let seconds: UInt64 = 10
        var simulation = SafetyNetSimulation()
        simulation.changeState(at: 0)
        simulation.runTimer(until: seconds * 1_000_000_000)

        // 10 keepalives a second, plus the two copies of the change.
        #expect(simulation.wakeups <= Int(seconds) * 10 + 2)
        // A 200 Hz poll would have spent 2000 in the same window.
        #expect(simulation.wakeups < Int(seconds) * 200 / 10)
    }

    /// The other half of the criterion: with nothing to keep alive there is no timer to wake at all,
    /// which is the state a guest session sits in before anyone touches a pad.
    @Test func aSessionWithNothingToKeepAliveArmsNoTimer() {
        var simulation = SafetyNetSimulation()
        simulation.runTimer(until: 60_000_000_000)

        #expect(simulation.wakeups == 0)
        #expect(simulation.sendNanoseconds.isEmpty)
    }

    /// A controller unplugged mid-hold leaves the seat holding whatever it had, so the release is
    /// synthesised and then has to survive the same unreliable channel as anything else.
    @Test func aDisconnectMidHoldKeepsResendingTheRelease() {
        var simulation = SafetyNetSimulation()
        simulation.changeState(at: 0)
        simulation.runTimer(until: 500_000_000)
        simulation.changeState(at: 500_000_000)
        simulation.runTimer(until: 1_000_000_000)

        let release = simulation.sendNanoseconds.filter { $0 >= 500_000_000 }
        #expect(release.prefix(3) == [500_000_000, 520_000_000, 540_000_000])
        #expect(release.last == 940_000_000)
    }

    /// The property both of the above rest on, checked over a scripted session: once anything has
    /// been sent, no gap between sends may exceed the ceiling the policy documents.
    @Test func noGapBetweenSendsEverExceedsTheKeepaliveCeiling() {
        var simulation = SafetyNetSimulation()
        simulation.changeState(at: 0)
        simulation.runTimer(until: 200_000_000)
        simulation.changeState(at: 200_000_000)
        simulation.changeState(at: 205_000_000)
        simulation.runTimer(until: 1_500_000_000)
        simulation.changeState(at: 1_500_000_000)
        simulation.runTimer(until: 3_000_000_000)

        let sends = simulation.sendNanoseconds
        #expect(sends.count > 3)
        for (previous, next) in zip(sends, sends.dropFirst()) {
            #expect(next - previous <= ceiling)
        }
    }

    /// `DispatchTime.now().uptimeNanoseconds` is documented as monotonic, but the keepalive guard
    /// exists because a stale reading used to underflow the unsigned subtraction and fire a
    /// keepalive on every tick. The delay must not go the same way.
    @Test func aStaleClockDoesNotShortenTheKeepalive() {
        var policy = OPNRemoteCoOpGuestInputRedundancyPolicy()
        _ = policy.shouldSend(isChanged: true, allowRedundantSend: false, nowNanoseconds: 1_000_000_000)
        _ = policy.shouldSend(isChanged: false, allowRedundantSend: true, nowNanoseconds: 1_020_000_000)
        _ = policy.shouldSend(isChanged: false, allowRedundantSend: true, nowNanoseconds: 1_040_000_000)

        #expect(policy.nextSendDelayNanoseconds(nowNanoseconds: 500_000_000,
                                                redundantSendIntervalNanoseconds: 20_000_000) == ceiling)
    }

    /// What the sender reads to arm the timer: the redundant interval while a copy is pending, and
    /// what is left of the keepalive once they are out.
    @Test func theNextDelayIsTheRedundantIntervalThenWhatIsLeftOfTheKeepalive() {
        var policy = OPNRemoteCoOpGuestInputRedundancyPolicy()
        #expect(policy.nextSendDelayNanoseconds(nowNanoseconds: 0,
                                                redundantSendIntervalNanoseconds: 20_000_000) == nil)

        _ = policy.shouldSend(isChanged: true, allowRedundantSend: false, nowNanoseconds: 0)
        #expect(policy.nextSendDelayNanoseconds(nowNanoseconds: 0,
                                                redundantSendIntervalNanoseconds: 20_000_000) == 20_000_000)

        _ = policy.shouldSend(isChanged: false, allowRedundantSend: true, nowNanoseconds: 20_000_000)
        _ = policy.shouldSend(isChanged: false, allowRedundantSend: true, nowNanoseconds: 40_000_000)
        #expect(policy.nextSendDelayNanoseconds(nowNanoseconds: 40_000_000,
                                                redundantSendIntervalNanoseconds: 20_000_000) == 100_000_000)
        #expect(policy.nextSendDelayNanoseconds(nowNanoseconds: 90_000_000,
                                                redundantSendIntervalNanoseconds: 20_000_000) == 50_000_000)
        #expect(policy.nextSendDelayNanoseconds(nowNanoseconds: 140_000_000,
                                                redundantSendIntervalNanoseconds: 20_000_000) == 0)
    }

    /// A repeat cadence of zero would spin the sender; the interval is a floor, not a suggestion.
    @Test func aZeroRedundantIntervalStillYieldsAtLeastOneNanosecond() {
        var policy = OPNRemoteCoOpGuestInputRedundancyPolicy()
        _ = policy.shouldSend(isChanged: true, allowRedundantSend: false, nowNanoseconds: 0)

        #expect(policy.nextSendDelayNanoseconds(nowNanoseconds: 0,
                                                redundantSendIntervalNanoseconds: 0) == 1)
    }
}
