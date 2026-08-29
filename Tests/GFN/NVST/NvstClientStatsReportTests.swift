import Foundation
import Testing
@testable import OpenNOW

/// Byte-exact pins for the client statistics reports recovered from libBifrost2 disassembly
/// (see `docs/NVST/OfficialClientAudit.md` and `/tmp/gfnre/qos-layouts.md`). Every offset and
/// endianness here comes from the official builders' store instructions and the embedded
/// `RM_BLOB_DEF` telemetry schema, not from inference.
@Suite
struct NvstClientStatsReportTests {

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    @Test func theRtpStatsReportMatchesTheOfficialLayout() {
        let report = NvstRtpStatsReport(frameNumber: 1,
                                        totalReceivedPackets: 2,
                                        outOfOrderPackets: 3,
                                        dropEvents: 4,
                                        latePackets: 5,
                                        droppedPackets: 6,
                                        recoveredPackets: 7,
                                        maxDropBurstLength: 8,
                                        maxWaitingQueueDepth: 9,
                                        duplicatePackets: 10)
        #expect(report.command.code == 0x208)
        // Version 4, stream 0, then the blob-54 field order, all little-endian; the fields this
        // pipeline has no analog for are the zeros in the middle.
        #expect(hex(report.payload) ==
                "04000000" + "01000000" + "0200000000000000" +
                "03000000" + "04000000" + "05000000" + "06000000" + "07000000" +
                "00000000" + "00000000" + "08000000" + "09000000" + "00000000" +
                "0000000000000000" + "00000000" + "0a000000")
        #expect(report.payload.count == NvstRtpStatsReport.payloadLength)
    }

    @Test func theRtpNackStatsReportMatchesTheOfficialLayout() {
        let report = NvstRtpNackStatsReport(frameNumber: 1,
                                            nackRequestsSent: 2,
                                            nackedPacketsRequested: 3,
                                            nackedPacketsReceived: 4,
                                            nackedPacketsUtilized: 5,
                                            nackedPacketsRetried: 6)
        #expect(report.command.code == 0x20a)
        #expect(hex(report.payload) ==
                "02000000" + "01000000" + "02000000" + "03000000" +
                "04000000" + "05000000" + "06000000")
        #expect(report.payload.count == NvstRtpNackStatsReport.payloadLength)
    }

    @Test func theRlFeedbackReportMatchesTheOfficialLayout() {
        let report = NvstRlFeedbackReport(entries: [
            NvstRlFeedbackEntry(frameNumber: 7,
                                bandwidthEstimateKbps: 25_000,
                                latePackets: 2,
                                bandwidthUtilizationTenthsPercent: 15),
            NvstRlFeedbackEntry(frameNumber: 8,
                                bandwidthEstimateKbps: 24_000,
                                latePackets: 0,
                                bandwidthUtilizationTenthsPercent: 0),
        ])
        #expect(report.command.code == 0x209)
        // Header: version 3, stream 0, count 2. Entries: frame, bandwidth estimate,
        // late-packet count zero-extended to u32, u16 utilization, two zero bytes where the
        // official library leaves stale staging memory.
        #expect(hex(report.payload) ==
                "03000000" + "00000000" + "02000000" +
                "07000000" + "a8610000" + "02000000" + "0f000000" +
                "08000000" + "c05d0000" + "00000000" + "00000000")
        #expect(report.payload.count == 12 + 16 * 2)
    }

    @Test func rlFeedbackClampsToTheOfficialBatchLimit() {
        let entries = (0..<20).map {
            NvstRlFeedbackEntry(frameNumber: UInt32($0),
                                bandwidthEstimateKbps: 1,
                                latePackets: 0,
                                bandwidthUtilizationTenthsPercent: 0)
        }
        let report = NvstRlFeedbackReport(entries: entries)
        #expect(report.entries.count == NvstRlFeedbackReport.maxEntries)
        #expect(report.payload.count == 12 + 16 * 16)
    }

    @Test func theEcnFeedbackReportMatchesTheOfficialLayout() {
        let report = NvstEcnFeedbackReport(entries: [
            .init(frameNumber: 9, ceMarkedPercent: 42),
            .init(frameNumber: 10, ceMarkedPercent: 7),
        ])
        #expect(report.command.code == 0x210)
        // Header: stream 0, reserved zero, count 2; entries pack to five bytes each.
        #expect(hex(report.payload) ==
                "00000000" + "00000000" + "02000000" +
                "090000002a" + "0a00000007")
        #expect(report.payload.count == 12 + 5 * 2)
    }

    @Test func theControlChannelStatsReportMatchesTheOfficialLayout() {
        let report = NvstControlChannelStatsReport(
            timestampMicroseconds: 0x0102_0304_0506_0708,
            totalMessagesSent: 5,
            totalMessagesFailed: 1,
            totalBytesSent: 1000,
            commands: [NvstControlChannelCommandStats(commandCode: 0x207,
                                                      messagesSent: 5,
                                                      messagesFailed: 1,
                                                      aggregatedBytes: 1000)])
        #expect(report.command.code == 0x313)
        // Header: version 2 (ServerControl's constructor writes it), u64 microsecond timestamp,
        // totals; then one 20-byte per-command record.
        #expect(hex(report.payload) ==
                "02000000" + "0807060504030201" + "05000000" + "01000000" +
                "e803000000000000" +
                "07020000" + "05000000" + "01000000" + "e803000000000000")
        #expect(report.payload.count == 28 + 20)
    }

    @Test func theAudioJitterBufferStatsMatchTheOfficialLayout() {
        var stats = NvstAudioJitterBufferStats()
        stats.totalPackets = 1
        stats.lostPackets = 2
        stats.averageJitter = 3
        stats.currentThreshold = 4
        stats.renderDelayMilliseconds = 5
        stats.decoderDelayMilliseconds = 6
        stats.writeDelayMilliseconds = 7
        let payload = stats.payload
        #expect(stats.command.code == 0x202)
        #expect(payload.count == NvstAudioJitterBufferStats.payloadLength)
        var reader = NvstByteReader(payload)
        #expect((try? reader.u32LE()) == NvstAudioJitterBufferStats.version)
        #expect((try? reader.u32LE()) == 1)                       // +0x04 total packets
        _ = try? reader.skip(0x20)
        #expect((try? reader.u32LE()) == 2)                       // +0x28 lost packets
        _ = try? reader.skip(0x18)
        #expect((try? reader.u32LE()) == 3)                       // +0x44 average jitter ms
        _ = try? reader.skip(8)
        #expect((try? reader.u16LE()) == 4)                       // +0x50 current threshold
        _ = try? reader.skip(0x16)
        #expect((try? reader.u8()) == 5)                          // +0x68 render delay ms
        #expect((try? reader.u8()) == 6)                          // +0x69 decoder delay ms
        #expect((try? reader.u8()) == 7)                          // +0x6a write delay ms
    }
}
