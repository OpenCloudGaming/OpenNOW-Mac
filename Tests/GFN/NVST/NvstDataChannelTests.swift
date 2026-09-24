import Foundation
import Testing
@testable import OpenNOW

/// The channel table and the DCEP exchange are the parts of SCTP that the seat validates directly.
/// A wrong stream id or reliability here is what made a live seat reset every stream, so both are
/// pinned by value rather than derived.
@Suite struct NvstDataChannelTests {
    @Test func theEightChannelsKeepTheirLabelsAndEvenStreamIDs() {
        let channels = NvstSctpChannelProfile.official
        #expect(channels.count == 8)
        #expect(channels.map(\.label) == [
            "control_channel_reliable",
            "custom_message_on_sctp_private_reliable",
            "custom_message_on_sctp_private_partially_reliable",
            "control_channel_partially_reliable",
            "control_channel_unreliable",
            "input_channel_partially_reliable",
            "cursor_channel",
            "rtcp_on_sctp_private",
        ])
        // As the DTLS client we are handed the even ids in creation order.
        #expect(channels.map(\.streamID) == [0, 2, 4, 6, 8, 10, 12, 14])
    }

    @Test func theReliabilityOfEachChannelMatchesTheSeatsProfile() {
        #expect(NvstSctpChannelProfile.channel(labelled: "control_channel_reliable")?.reliability == .reliable)
        #expect(NvstSctpChannelProfile.channel(labelled: "control_channel_partially_reliable")?.reliability == .partialReliableTimed(300))
        #expect(NvstSctpChannelProfile.channel(labelled: "input_channel_partially_reliable")?.reliability == .partialReliableTimed(300))
        #expect(NvstSctpChannelProfile.channel(labelled: "custom_message_on_sctp_private_partially_reliable")?.reliability == .partialReliableTimed(300))
        #expect(NvstSctpChannelProfile.channel(labelled: "control_channel_unreliable")?.reliability == .partialReliableRetransmits(0))
        #expect(NvstSctpChannelProfile.channel(labelled: "rtcp_on_sctp_private")?.reliability == .reliable)
        #expect(NvstSctpChannelProfile.channel(labelled: "no_such_channel") == nil)
    }

    @Test func aReliableOpenMatchesTheRfc8832Layout() throws {
        let channel = try #require(NvstSctpChannelProfile.channel(labelled: "control_channel_reliable"))
        let encoded = NvstDataChannelProtocol.encodedOpen(for: channel, priority: 0)
        let label = Array("control_channel_reliable".utf8)
        var expected: [UInt8] = [0x03, 0x00]
        expected += [0x00, 0x00]                        // priority
        expected += [0x00, 0x00, 0x00, 0x00]            // reliability parameter
        expected += [UInt8(label.count >> 8), UInt8(label.count & 0xFF)]
        expected += [0x00, 0x00]                        // protocol length
        expected += label
        #expect(Array(encoded) == expected)
    }

    @Test func theTimedChannelOpensWithItsMillisecondLifetime() throws {
        let channel = try #require(NvstSctpChannelProfile.channel(labelled: "input_channel_partially_reliable"))
        let encoded = Array(NvstDataChannelProtocol.encodedOpen(for: channel))
        #expect(encoded[0] == 0x03, "RFC 8832 section 5.1 OPEN")
        #expect(encoded[1] == 0x02, "partial-reliable-timed")
        // Reliability parameter is the 300 ms lifetime, big-endian.
        #expect(encoded[4...7] == [0x00, 0x00, 0x01, 0x2C])
    }

    @Test func theUnreliableChannelOpensAsZeroRetransmits() throws {
        let channel = try #require(NvstSctpChannelProfile.channel(labelled: "control_channel_unreliable"))
        let encoded = Array(NvstDataChannelProtocol.encodedOpen(for: channel))
        #expect(encoded[1] == 0x01, "partial-reliable-retransmits")
        #expect(encoded[4...7] == [0x00, 0x00, 0x00, 0x00])
    }

    @Test func everyOpenRoundTripsBackToTheChannelItNames() throws {
        for channel in NvstSctpChannelProfile.official {
            let encoded = NvstDataChannelProtocol.encodedOpen(for: channel)
            let decoded = try #require(NvstDataChannelProtocol.decode(encoded))
            #expect(decoded.type == .open)
            let open = try #require(decoded.open)
            #expect(open.label == channel.label)
            #expect(open.channelType == NvstDataChannelProtocol.ChannelType.forReliability(channel.reliability))
            #expect(open.reliabilityParameter == NvstDataChannelProtocol.reliabilityParameter(for: channel.reliability))
        }
    }

    @Test func anAckAndGarbageAreDistinguished() throws {
        #expect(NvstDataChannelProtocol.encodedAck() == Data([0x02]))
        let ack = NvstDataChannelProtocol.decode(Data([0x02]))
        #expect(ack?.type == .ack)
        #expect(ack?.open == nil)
        #expect(NvstDataChannelProtocol.decode(Data()) == nil)
        #expect(NvstDataChannelProtocol.decode(Data([0x00])) == nil)
        #expect(NvstDataChannelProtocol.decode(Data([0x01])) == nil)
        #expect(NvstDataChannelProtocol.decode(Data([0x02, 0x00])) == nil)
        // A truncated OPEN must be refused rather than half-parsed.
        let truncated = NvstDataChannelProtocol.encodedOpen(for: NvstSctpChannelProfile.official[0]).prefix(8)
        #expect(NvstDataChannelProtocol.decode(Data(truncated)) == nil)
        // An unknown message type is not DCEP traffic.
        #expect(NvstDataChannelProtocol.decode(Data([0x7F])) == nil)
    }

    @Test func dcepRidesItsOwnPayloadProtocolIdentifier() {
        // DCEP is 50; the channel payload PPIDs are 53 (binary) and 54/56 (empty).
        #expect(NvstDataChannelProtocol.ppid == 50)
    }
}
