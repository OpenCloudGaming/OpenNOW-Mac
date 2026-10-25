import Foundation
import Testing
@testable import OpenNOW

@Suite struct NvstBifrostFreePerformanceSnapshotTests {
    private func deliver(_ sequence: UInt16, to receiver: NvstMjolnirReceiver, handoff: NVSTVideoHandoff) throws {
        let packet = NvstReceiverFixtures.packet(sequence: sequence,
                                                frameIndex: UInt32(sequence),
                                                flags: 0x07,
                                                media: [0, 0, 0, 1, 0x65])
        _ = receiver.receiver.process(datagram: try NvstReceiverFixtures.seal(packet, sequence: sequence, handoff: handoff))
    }

    @Test func localReplayRejectionsDoNotCountAsPacketLoss() async throws {
        let handoff = NvstReceiverFixtures.makeHandoff()
        let receiver = try NvstMjolnirReceiver(handoff: handoff)
        let transport = NvstBifrostFreeTransport()
        await transport.attachPerformanceReceiver(receiver)

        try deliver(1, to: receiver, handoff: handoff)
        try deliver(1, to: receiver, handoff: handoff)
        #expect(receiver.stats.replayedPackets == 1)
        #expect(receiver.stats.droppedPackets == 1)

        let snapshot = try #require(await transport.performanceSnapshot())
        #expect(snapshot.available)
        #expect(snapshot.packetLoss == 0)
        #expect(snapshot.totalPacketLoss == 0)
        #expect(snapshot.packetLossPercent == 0)
    }

    @Test func aRecoveredIntervalClearsActiveLossWithoutErasingTheSessionTotal() async throws {
        let handoff = NvstReceiverFixtures.makeHandoff(reorderWindow: 1)
        let receiver = try NvstMjolnirReceiver(handoff: handoff)
        let transport = NvstBifrostFreeTransport()
        await transport.attachPerformanceReceiver(receiver)

        try deliver(1, to: receiver, handoff: handoff)
        try deliver(4, to: receiver, handoff: handoff)
        #expect(receiver.stats.finalizedLossPackets == 2)
        #expect(receiver.stats.lastCumulativeLost == 0)

        let affected = try #require(await transport.performanceSnapshot())
        #expect(affected.packetLoss == 2)
        #expect(affected.totalPacketLoss == 2)
        #expect(affected.packetLossPercent == 50)

        try deliver(5, to: receiver, handoff: handoff)
        try deliver(5, to: receiver, handoff: handoff)
        let recovered = try #require(await transport.performanceSnapshot())
        #expect(recovered.packetLoss == 0)
        #expect(recovered.totalPacketLoss == 2)
        #expect(recovered.packetLossPercent == 0)

        let idle = try #require(await transport.performanceSnapshot())
        #expect(idle.packetLoss == 0)
        #expect(idle.totalPacketLoss == 2)
        #expect(idle.packetLossPercent == 0)
    }

    @Test func aGapStillWaitingForReorderedPacketsIsNotFinalizedLoss() async throws {
        let handoff = NvstReceiverFixtures.makeHandoff()
        let receiver = try NvstMjolnirReceiver(handoff: handoff)
        let transport = NvstBifrostFreeTransport()
        await transport.attachPerformanceReceiver(receiver)

        try deliver(1, to: receiver, handoff: handoff)
        try deliver(3, to: receiver, handoff: handoff)
        _ = receiver.receiver.receiverReportBlock(interval: 0)
        #expect(receiver.stats.lastCumulativeLost == 1)

        let pending = try #require(await transport.performanceSnapshot())
        #expect(pending.packetLoss == 0)
        #expect(pending.totalPacketLoss == 0)
        #expect(pending.packetLossPercent == 0)

        try deliver(2, to: receiver, handoff: handoff)
        let repaired = try #require(await transport.performanceSnapshot())
        #expect(repaired.packetLoss == 0)
        #expect(repaired.totalPacketLoss == 0)
        #expect(repaired.packetLossPercent == 0)
    }
}

private extension NvstBifrostFreeTransport {
    func attachPerformanceReceiver(_ receiver: NvstMjolnirReceiver) {
        self.receiver = receiver
        clock.start()
    }
}
