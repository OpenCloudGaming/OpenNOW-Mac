import Foundation
import os
import Testing
@testable import OpenNOW

/// The retransmission wait: how long a gap is held for a resend, and when it stops being held.
@Suite(.serialized)
struct NvstRetransmissionWaitTests {
    /// The hold follows the measured round trip: a short one ends the wait well inside the official
    /// client's flat 52 ms, so the fallback to a keyframe starts as soon as the answer could have
    /// arrived instead of after a wait that outlasts it.
    @Test func aShorterRoundTripEndsTheWaitSooner() throws {
        let handoff = NvstReceiverFixtures.makeHandoff(reorderWindow: 4)
        let clock = OSAllocatedUnfairLock(initialState: UInt64(0))
        let receiver = try NvstVideoReceiver(handoff: handoff, uptimeNanoseconds: { clock.withLock { $0 } })
        // A 4 ms round trip derives a 17 ms hold: two round trips plus the initial delay, floored.
        receiver.useRetransmissionRoundTrip(milliseconds: 4)
        let media: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x65]
        func feed(_ sequence: UInt16) throws -> [NvstReceiveEvent] {
            receiver.process(datagram: try NvstReceiverFixtures.seal(
                NvstReceiverFixtures.packet(sequence: sequence, frameIndex: UInt32(sequence), flags: 0x07, media: media),
                sequence: sequence, handoff: handoff))
        }
        _ = try feed(1)
        _ = try feed(3)
        clock.withLock { $0 = NvstNackTracker.initialDelayNanoseconds }
        _ = try feed(4)
        // Past the 17 ms hold but inside the flat 52 ms one, so only the derived hold ends the wait.
        clock.withLock { $0 = 20_000_000 }
        #expect(NvstReceiverFixtures.recoveries(try feed(5)) == 0)
        #expect(NvstReceiverFixtures.recoveries(try feed(6)) == 1)
    }

    /// A seat that has repaired none of the requests it was sent is not going to. After enough of
    /// them the wait is switched off, so a gap falls back as it did before the requests existed
    /// rather than holding a frame for an answer that never comes.
    @Test func aSeatThatNeverRepairsStopsTheWaitFromHoldingGaps() throws {
        let handoff = NvstReceiverFixtures.makeHandoff(reorderWindow: 4)
        let clock = OSAllocatedUnfairLock(initialState: UInt64(0))
        let receiver = try NvstVideoReceiver(handoff: handoff, uptimeNanoseconds: { clock.withLock { $0 } })
        receiver.useRetransmissionRoundTrip(milliseconds: 4)
        let media: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x65]
        func feed(_ sequence: UInt16) throws -> [NvstReceiveEvent] {
            receiver.process(datagram: try NvstReceiverFixtures.seal(
                NvstReceiverFixtures.packet(sequence: sequence, frameIndex: UInt32(sequence), flags: 0x07, media: media),
                sequence: sequence, handoff: handoff))
        }
        // One gap per round, each requested once and never answered.
        var sequence: UInt16 = 1
        for _ in 0..<8 {
            let base = sequence
            sequence += 8
            clock.withLock { $0 += 30_000_000 }
            _ = try feed(base)
            _ = try feed(base &+ 2)
            clock.withLock { $0 += NvstNackTracker.initialDelayNanoseconds }
            _ = try feed(base &+ 3)
            for offset in UInt16(4)...6 { _ = try feed(base &+ offset) }
        }
        let stats = receiver.snapshot
        #expect(stats.retransmissionRequestsSent >= NvstVideoReceiver.retransmissionWaitDisableRequestCount)
        #expect(stats.retransmissionRepairedPackets == 0)
        #expect(stats.retransmissionWaitDisabled)

        // The next gap is no longer held: it is loss as soon as the reorder window passes it.
        let base = sequence
        _ = try feed(base)
        _ = try feed(base &+ 2)
        clock.withLock { $0 += NvstNackTracker.initialDelayNanoseconds }
        _ = try feed(base &+ 3)
        var recoveries = 0
        for offset in UInt16(4)...6 { recoveries += NvstReceiverFixtures.recoveries(try feed(base &+ offset)) }
        #expect(recoveries == 1)
    }

    /// The verdict is reached on time, not only when another request happens to go out: eight
    /// requests, no repair, 200 ms, and the next scan ends the wait even though it sends nothing.
    @Test func theWaitIsDisabledWithoutAnotherRequestGoingOut() throws {
        let handoff = NvstReceiverFixtures.makeHandoff(reorderWindow: 4)
        let clock = OSAllocatedUnfairLock(initialState: UInt64(0))
        let receiver = try NvstVideoReceiver(handoff: handoff, uptimeNanoseconds: { clock.withLock { $0 } })
        // A measured round trip, so a retry brings the request count up inside a few short gaps.
        receiver.useRetransmissionRoundTrip(milliseconds: 4)
        let retryInterval = NvstNackTracker.extraRetryWaitNanoseconds + 4_000_000
        let media: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x65]
        func feed(_ sequence: UInt16) throws -> [NvstReceiveEvent] {
            receiver.process(datagram: try NvstReceiverFixtures.seal(
                NvstReceiverFixtures.packet(sequence: sequence, frameIndex: UInt32(sequence), flags: 0x07, media: media),
                sequence: sequence, handoff: handoff))
        }
        var sequence: UInt16 = 1
        _ = try feed(sequence)
        // Four one-packet holes, each requested and retried once before its hold expires. Every
        // request goes out inside the first 70 ms and none of them is ever repaired.
        for _ in 0..<4 {
            sequence += 2
            _ = try feed(sequence)
            clock.withLock { $0 += NvstNackTracker.initialDelayNanoseconds }
            sequence += 1
            _ = try feed(sequence)
            clock.withLock { $0 += retryInterval }
            sequence += 1
            _ = try feed(sequence)
            clock.withLock { $0 += retryInterval }
            sequence += 1
            _ = try feed(sequence)
        }
        let asked = receiver.snapshot
        #expect(asked.retransmissionRequestsSent == NvstVideoReceiver.retransmissionWaitDisableRequestCount)
        #expect(asked.retransmissionRepairedPackets == 0)
        #expect(!asked.retransmissionWaitDisabled)

        // Past the delay, the next scan sends nothing and still ends the wait.
        clock.withLock { $0 = 202_000_000 }
        sequence += 2
        _ = try feed(sequence)
        let stats = receiver.snapshot
        #expect(stats.retransmissionRequestsSent == asked.retransmissionRequestsSent)
        #expect(stats.retransmissionWaitDisabled)
    }

    /// A packet the seat never sent but FEC rebuilt is not a retransmission arriving: crediting it
    /// would keep the wait enabled for a seat that answers nothing, and overstate the repair count.
    @Test func anFecRebuildOfARequestedPacketIsNotCreditedToTheRequest() throws {
        let handoff = NvstReceiverFixtures.makeHandoff(reorderWindow: 4)
        let clock = OSAllocatedUnfairLock(initialState: UInt64(0))
        let receiver = try NvstVideoReceiver(handoff: handoff, uptimeNanoseconds: { clock.withLock { $0 } })

        func fecWord(index: UInt32) -> UInt32 { (50 << 4) | (index << 12) | (2 << 22) }
        func blockPackets(frameIndex: UInt32, baseSequence: UInt16, seed: UInt8) -> [(UInt16, Data)] {
            let sof = NvstReceiverFixtures.packet(sequence: baseSequence, frameIndex: frameIndex, flags: 0x05,
                             media: [0x00, 0x00, 0x00, 0x01, 0x65, seed], fecWord: fecWord(index: 0))
            let eof = NvstReceiverFixtures.packet(sequence: baseSequence + 1, frameIndex: frameIndex, flags: 0x03,
                             media: [0xbb, seed, 0xcc], fecWord: fecWord(index: 1))
            let size = max(sof.count, eof.count)
            let shards = [sof, eof].map { source -> [UInt8] in
                let bytes = [UInt8](source)
                return bytes.count == size ? bytes : bytes + [UInt8](repeating: 0, count: size - bytes.count)
            }
            let parity = NvstReedSolomon.encode(data: shards, parityCount: 1, size: size)!
            let parityHeader = NvstReceiverFixtures.packet(sequence: baseSequence + 2, frameIndex: frameIndex, flags: 0x00,
                                      media: [], fecWord: fecWord(index: 2))
            return [(baseSequence, sof), (baseSequence + 1, eof),
                    (baseSequence + 2, parityHeader + Data(parity[0][NvstFecRecovery.headerLength...]))]
        }
        // Clean blocks first: recovery arms only after verifying the scheme against this stream.
        for round in 0..<NvstFecRecovery.verificationTarget {
            for (sequence, plain) in blockPackets(frameIndex: UInt32(round + 1),
                                                  baseSequence: UInt16(round * 3 + 1),
                                                  seed: UInt8(round)) {
                _ = receiver.process(datagram: try NvstReceiverFixtures.seal(plain, sequence: sequence, handoff: handoff))
            }
        }
        #expect(receiver.fecFindings.isArmed)

        // The start-of-frame packet never arrives; the end-of-frame packet opens the gap and the
        // parity packet rebuilds it.
        let base = UInt16(NvstFecRecovery.verificationTarget * 3 + 1)
        let lossy = blockPackets(frameIndex: UInt32(NvstFecRecovery.verificationTarget + 1), baseSequence: base, seed: 0x42)
        _ = receiver.process(datagram: try NvstReceiverFixtures.seal(lossy[1].1, sequence: lossy[1].0, handoff: handoff))
        clock.withLock { $0 = NvstNackTracker.initialDelayNanoseconds }
        let events = receiver.process(datagram: try NvstReceiverFixtures.seal(lossy[2].1, sequence: lossy[2].0, handoff: handoff))
        #expect(NvstReceiverFixtures.frames(events).count == 1)
        #expect(NvstReceiverFixtures.recoveries(events) == 0)
        let stats = receiver.snapshot
        #expect(stats.retransmissionRequestsSent == 1)
        #expect(stats.retransmissionRepairedPackets == 0)
        #expect(stats.recoveredPackets == 1)
    }

}
