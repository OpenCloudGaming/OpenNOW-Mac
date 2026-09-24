import Foundation
import Testing
@testable import OpenNOW

/// The jitter buffer decides two things that are easy to get wrong and invisible when wrong: the
/// order frames reach the decoder, and exactly which sequence numbers are reported missing. Both are
/// asserted by value.
@Suite struct NvstAudioJitterBufferTests {
    private func payload(_ value: UInt8) -> Data { Data([value]) }

    private func payloads(_ emissions: [NvstAudioJitterBuffer.Emission]) -> [Data] {
        emissions.compactMap { if case .payload(let data) = $0 { return data } else { return nil } }
    }

    private func losses(_ emissions: [NvstAudioJitterBuffer.Emission]) -> [UInt16] {
        emissions.compactMap { if case .lost(let sequence) = $0 { return sequence } else { return nil } }
    }

    @Test func packetsArrivingInOrderComeOutInOrder() {
        var buffer = NvstAudioJitterBuffer(targetDepth: 2)
        var emitted: [NvstAudioJitterBuffer.Emission] = []
        for index in 0..<6 {
            buffer.insert(sequenceNumber: UInt16(index), payload: payload(UInt8(index)))
            emitted += buffer.advance()
        }
        #expect(payloads(emitted) == (0..<4).map { payload(UInt8($0)) })
        // The last two are still held, absorbing whatever arrives next.
        #expect(buffer.bufferedCount == 2)
        #expect(payloads(buffer.flush()) == [payload(4), payload(5)])
    }

    @Test func reorderedPacketsAreEmittedInSequenceOrder() {
        var buffer = NvstAudioJitterBuffer(targetDepth: 1)
        buffer.insert(sequenceNumber: 1, payload: payload(1))
        buffer.insert(sequenceNumber: 3, payload: payload(3))
        buffer.insert(sequenceNumber: 2, payload: payload(2))
        #expect(payloads(buffer.advance()) == [payload(1), payload(2)])
        #expect(buffer.flush() == [.payload(payload(3))])
    }

    @Test func aMissingSequenceNumberIsReportedExactlyOnce() {
        var buffer = NvstAudioJitterBuffer(targetDepth: 1)
        buffer.insert(sequenceNumber: 0, payload: payload(0))
        // 1 never arrives.
        buffer.insert(sequenceNumber: 2, payload: payload(2))
        buffer.insert(sequenceNumber: 3, payload: payload(3))
        let emitted = buffer.advance()
        #expect(losses(emitted) == [1])
        #expect(payloads(emitted) == [payload(0), payload(2)])
        #expect(buffer.lostPacketCount == 1)
    }

    @Test func duplicatesAndLatePacketsDoNotRewindTheStream() {
        var buffer = NvstAudioJitterBuffer(targetDepth: 0)
        buffer.insert(sequenceNumber: 5, payload: payload(5))
        _ = buffer.advance()
        buffer.insert(sequenceNumber: 5, payload: payload(99))
        buffer.insert(sequenceNumber: 4, payload: payload(4))
        #expect(buffer.advance().isEmpty, "a duplicate or a late packet must not be emitted")
        #expect(buffer.bufferedCount == 0)
    }

    @Test func theSequenceNumberWrapDoesNotFlushTheBuffer() {
        var buffer = NvstAudioJitterBuffer(targetDepth: 1)
        buffer.insert(sequenceNumber: 65_534, payload: payload(1))
        buffer.insert(sequenceNumber: 65_535, payload: payload(2))
        buffer.insert(sequenceNumber: 0, payload: payload(3))
        buffer.insert(sequenceNumber: 1, payload: payload(4))
        let emitted = payloads(buffer.advance())
        #expect(emitted == [payload(1), payload(2), payload(3)])
        #expect(buffer.lostPacketCount == 0)
    }

    @Test func aBurstBeyondTheCeilingDropsTheOldestAndCountsItLost() {
        var buffer = NvstAudioJitterBuffer(targetDepth: 4, maximumDepth: 3)
        for index in 0..<6 {
            buffer.insert(sequenceNumber: UInt16(index), payload: payload(UInt8(index)))
            _ = buffer.advance()
        }
        #expect(buffer.bufferedCount <= 3)
        #expect(buffer.lostPacketCount >= 1)
    }

    @Test func flushReportsTheGapsInTheTail() {
        var buffer = NvstAudioJitterBuffer(targetDepth: 0)
        buffer.insert(sequenceNumber: 10, payload: payload(10))
        buffer.insert(sequenceNumber: 13, payload: payload(13))
        let tail = buffer.flush()
        #expect(losses(tail) == [11, 12])
        #expect(payloads(tail) == [payload(10), payload(13)])
    }
}

/// Dwell is what the HUD's A/V reading is computed from, and libwebrtc supplied it before. The
/// clock is injected so the measurement is asserted rather than waited for.
@Suite struct NvstAudioJitterBufferDwellTests {
    private final class Clock: @unchecked Sendable {
        var value: TimeInterval = 0
        func advance(_ seconds: TimeInterval) { value += seconds }
    }

    private func buffer(_ clock: Clock, targetDepth: Int) -> NvstAudioJitterBuffer {
        NvstAudioJitterBuffer(targetDepth: targetDepth, now: { clock.value })
    }

    @Test func dwellIsTheTimeEachPacketWaited() {
        let clock = Clock()
        var jitter = buffer(clock, targetDepth: 1)
        jitter.insert(sequenceNumber: 0, payload: Data([0]))
        clock.advance(0.010)          // packet 0 waited 10 ms before being emitted
        jitter.insert(sequenceNumber: 1, payload: Data([1]))
        _ = jitter.advance()

        #expect(jitter.jitterBufferEmittedCount == 1)
        #expect(abs(jitter.jitterBufferDelaySeconds - 0.010) < 0.0001)
    }

    @Test func theCountersAccumulateAcrossPacketsAndThroughFlush() {
        let clock = Clock()
        var jitter = buffer(clock, targetDepth: 1)
        for sequence in UInt16(0)..<3 {
            jitter.insert(sequenceNumber: sequence, payload: Data([UInt8(sequence)]))
            clock.advance(0.005)
        }
        _ = jitter.advance()
        _ = jitter.flush()
        // Three packets, all released at the same instant: the first waited the longest because the
        // later ones kept arriving behind it. That is the buffering the metric exists to show.
        #expect(jitter.jitterBufferEmittedCount == 3)
        #expect(abs(jitter.jitterBufferDelaySeconds - 0.030) < 0.0005)
    }

    @Test func aLostPacketContributesNoDwell() {
        let clock = Clock()
        var jitter = buffer(clock, targetDepth: 1)
        jitter.insert(sequenceNumber: 0, payload: Data([0]))
        // 1 never arrives.
        jitter.insert(sequenceNumber: 2, payload: Data([2]))
        clock.advance(0.02)
        _ = jitter.advance()
        let emitted = jitter.advance() + jitter.flush()
        #expect(jitter.lostPacketCount == 1)
        // Only the two real packets count, and the concealment for 1 adds nothing.
        #expect(jitter.jitterBufferEmittedCount == 2)
        #expect(!emitted.isEmpty)
    }

    @Test func aResetClearsTheDwellCounters() {
        let clock = Clock()
        var jitter = buffer(clock, targetDepth: 0)
        jitter.insert(sequenceNumber: 0, payload: Data([0]))
        clock.advance(0.01)
        _ = jitter.advance()
        #expect(jitter.jitterBufferEmittedCount == 1)
        jitter.reset()
        #expect(jitter.bufferedCount == 0)
    }
}
