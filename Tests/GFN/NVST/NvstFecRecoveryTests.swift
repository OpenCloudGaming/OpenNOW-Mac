import Foundation
import Testing
@testable import OpenNOW

@Suite struct NvstReedSolomonTests {
    /// Field anchors from nanors' generated tables (polynomial 285): if these hold, the whole
    /// GF(2^8) arithmetic matches the implementation NVIDIA's FEC is known to decode with.
    @Test func gfInverseMatchesTheReferenceTables() {
        #expect(NvstReedSolomon.inverse(1) == 1)
        #expect(NvstReedSolomon.inverse(2) == 142)
        #expect(NvstReedSolomon.inverse(3) == 244)
        #expect(NvstReedSolomon.inverse(4) == 71)
        #expect(NvstReedSolomon.inverse(5) == 167)
        for value in 1...255 {
            let byte = UInt8(value)
            #expect(NvstReedSolomon.multiply(byte, NvstReedSolomon.inverse(byte)) == 1)
        }
    }

    /// The nanors generator matrix: parity row j, data column i is inverse((ps + i) XOR j).
    @Test func parityMatrixIsTheNanorsCauchyMatrix() {
        #expect(NvstReedSolomon.parityCoefficient(parityCount: 2, dataIndex: 0, parityIndex: 0)
                == NvstReedSolomon.inverse(2))
        #expect(NvstReedSolomon.parityCoefficient(parityCount: 2, dataIndex: 3, parityIndex: 1)
                == NvstReedSolomon.inverse(5 ^ 1))
    }

    @Test func anyLostShardsWithinParityBudgetAreRecovered() throws {
        let size = 64
        var generator = SystemRandomNumberGenerator()
        let data: [[UInt8]] = (0..<10).map { _ in (0..<size).map { _ in UInt8.random(in: 0...255, using: &generator) } }
        let parity = try #require(NvstReedSolomon.encode(data: data, parityCount: 3, size: size))

        var shards: [[UInt8]?] = (data + parity).map { $0 }
        // Lose three shards: two data, one parity — exactly the parity budget.
        shards[1] = nil
        shards[7] = nil
        shards[11] = nil
        let recovered = try #require(NvstReedSolomon.recover(shards: &shards, dataCount: 10, parityCount: 3, size: size))
        #expect(recovered[1] == data[1])
        #expect(recovered[7] == data[7])
        #expect(recovered.count == 2)
    }

    @Test func moreLossesThanParityIsRefusedNotGuessed() throws {
        let size = 16
        let data: [[UInt8]] = (0..<4).map { index in [UInt8](repeating: UInt8(index + 1), count: size) }
        let parity = try #require(NvstReedSolomon.encode(data: data, parityCount: 1, size: size))
        var shards: [[UInt8]?] = (data + parity).map { $0 }
        shards[0] = nil
        shards[2] = nil
        #expect(NvstReedSolomon.recover(shards: &shards, dataCount: 4, parityCount: 1, size: size) == nil)
    }
}

@Suite struct NvstFecRecoveryTests {
    /// Builds the plaintext of one video packet the way the receiver sees it after SRTP: RTP
    /// header + GS extension + payload.
    private func plaintext(sequence: UInt16, frameIndex: UInt32, flags: UInt8, media: [UInt8],
                           fecIndex: UInt32, sourcePackets: UInt32, percentage: UInt32) -> Data {
        let fecWord = (percentage << 4) | (fecIndex << 12) | (sourcePackets << 22)
        return NvstVideoPacketTests.buildPacket(sequence: sequence, frameIndex: frameIndex,
                                                flags: flags, media: media, fecWord: fecWord)
    }

    private func parsed(_ data: Data) throws -> NvstRtpVideoPacket {
        try NvstVideoPacketParser.parse(data)
    }

    /// One frame = one FEC block: `sources` source packets plus the seat's parity, all equal size.
    /// 50% of 2 sources = 1 parity shard.
    private func block(frameIndex: UInt32, baseSequence: UInt16, payloadA: [UInt8], payloadB: [UInt8]) throws -> [Data] {
        let sources = [
            plaintext(sequence: baseSequence, frameIndex: frameIndex, flags: 0x05, media: payloadA,
                      fecIndex: 0, sourcePackets: 2, percentage: 50),
            plaintext(sequence: baseSequence + 1, frameIndex: frameIndex, flags: 0x03, media: payloadB,
                      fecIndex: 1, sourcePackets: 2, percentage: 50),
        ]
        let size = sources.map(\.count).max() ?? 0
        let shards = sources.map { source -> [UInt8] in
            let bytes = [UInt8](source)
            return bytes.count == size ? bytes : bytes + [UInt8](repeating: 0, count: size - bytes.count)
        }
        guard let parity = NvstReedSolomon.encode(data: shards, parityCount: 1, size: size) else { return [] }
        // The parity packet the way the seat sends it: real transport headers overlaid on the
        // parity shard, so only the payload region carries parity bytes.
        let parityHeader = plaintext(sequence: baseSequence + 2, frameIndex: frameIndex, flags: 0x00,
                                     media: [], fecIndex: 2, sourcePackets: 2, percentage: 50)
        let parityPacket = parityHeader + Data(parity[0][NvstFecRecovery.headerLength...])
        return sources + [parityPacket]
    }

    @Test func recoveryArmsOnlyAfterCleanVerificationBlocks() throws {
        let recovery = NvstFecRecovery()
        for round in 0..<NvstFecRecovery.verificationTarget {
            let packets = try block(frameIndex: UInt32(round + 1), baseSequence: UInt16(round * 3 + 1),
                                    payloadA: [0x00, 0x00, 0x00, 0x01, 0x65, UInt8(round)],
                                    payloadB: [0xbb, UInt8(round)])
            #expect(packets.count == 3)
            for packet in packets {
                #expect(recovery.observe(plaintext: packet, packet: try parsed(packet)).isEmpty)
            }
        }
        let findings = recovery.snapshot
        #expect(findings.verifiedBlocks == NvstFecRecovery.verificationTarget)
        #expect(findings.mismatchedBlocks == 0)
        #expect(findings.isArmed)
    }

    @Test func aLostSourcePacketIsReconstructedByteForByte() throws {
        let recovery = NvstFecRecovery()
        for round in 0..<NvstFecRecovery.verificationTarget {
            let packets = try block(frameIndex: UInt32(round + 1), baseSequence: UInt16(round * 3 + 1),
                                    payloadA: [0x00, 0x00, 0x00, 0x01, 0x65, UInt8(round)],
                                    payloadB: [0xbb, UInt8(round)])
            for packet in packets { _ = recovery.observe(plaintext: packet, packet: try parsed(packet)) }
        }
        // A lossy block: the second source never arrives; the parity packet must reproduce it.
        let lossy = try block(frameIndex: 99, baseSequence: 200,
                              payloadA: [0x00, 0x00, 0x00, 0x01, 0x65, 0x42],
                              payloadB: [0xbb, 0x42, 0x43])
        #expect(recovery.observe(plaintext: lossy[0], packet: try parsed(lossy[0])).isEmpty)
        let repaired = recovery.observe(plaintext: lossy[2], packet: try parsed(lossy[2]))
        #expect(repaired.count == 1)
        // The reconstruction is the dropped packet, zero-padded to the block's uniform shard size.
        let expected = lossy[1] + Data(repeating: 0, count: (lossy.map(\.count).max() ?? 0) - lossy[1].count)
        #expect(repaired.first == expected)
        #expect(recovery.snapshot.recoveredPackets == 1)
    }

    @Test func aParityMismatchDisablesRecoveryForTheSession() throws {
        let recovery = NvstFecRecovery()
        var packets = try block(frameIndex: 1, baseSequence: 1,
                                payloadA: [0x00, 0x00, 0x00, 0x01, 0x65],
                                payloadB: [0xbb])
        // Corrupt the parity payload: the scheme check must fail closed.
        packets[2][packets[2].count - 1] ^= 0x5a
        for packet in packets { _ = recovery.observe(plaintext: packet, packet: try parsed(packet)) }
        let findings = recovery.snapshot
        #expect(findings.mismatchedBlocks == 1)
        #expect(!findings.isArmed)
    }
}
