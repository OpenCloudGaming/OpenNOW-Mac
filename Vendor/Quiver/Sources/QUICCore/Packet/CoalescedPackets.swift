/// QUIC Coalesced Packets (RFC 9000 Section 12.2)
///
/// Multiple QUIC packets can be coalesced into a single UDP datagram.
/// This is particularly useful during connection establishment when
/// Initial, Handshake, and 1-RTT packets may be sent together.

import Foundation

// MARK: - Coalesced Packet Builder

/// Builds a coalesced packet from multiple QUIC packets
public struct CoalescedPacketBuilder: Sendable {
    /// Maximum UDP datagram size
    public let maxDatagramSize: Int

    /// Accumulated packets
    private var packets: [Data]

    /// Current total size
    private var currentSize: Int

    /// Creates a coalesced packet builder
    /// - Parameter maxDatagramSize: Maximum size of the UDP datagram.
    ///   Callers must supply the configured path MTU explicitly.
    public init(maxDatagramSize: Int) {
        self.maxDatagramSize = maxDatagramSize
        // Pre-allocate for typical case of 2-3 coalesced packets
        self.packets = []
        self.packets.reserveCapacity(3)
        self.currentSize = 0
    }

    /// Adds a packet to the coalesced packet
    /// - Parameter packet: The encoded packet data
    /// - Returns: true if the packet was added, false if it wouldn't fit
    public mutating func addPacket(_ packet: Data) -> Bool {
        guard currentSize + packet.count <= maxDatagramSize else {
            return false
        }
        packets.append(packet)
        currentSize += packet.count
        return true
    }

    /// Returns the number of packets currently added
    public var packetCount: Int {
        packets.count
    }

    /// Returns the current total size
    public var totalSize: Int {
        currentSize
    }

    /// Returns the remaining space in the datagram
    public var remainingSpace: Int {
        maxDatagramSize - currentSize
    }

    /// Whether the builder has any packets
    public var isEmpty: Bool {
        packets.isEmpty
    }

    /// Builds the coalesced packet data
    /// - Returns: The combined packet data
    public func build() -> Data {
        var result = Data(capacity: currentSize)
        for packet in packets {
            result.append(packet)
        }
        return result
    }

    /// Clears all packets
    public mutating func clear() {
        packets.removeAll()
        currentSize = 0
    }
}

// MARK: - Coalesced Packet Parser

/// Parses coalesced packets from a single UDP datagram
public struct CoalescedPacketParser: Sendable {
    /// Errors that can occur during parsing
    public enum ParseError: Error, Sendable {
        case emptyDatagram
        case invalidPacketHeader
        case packetLengthExceedsDatagram
        case insufficientData
    }

    /// Information about a packet found in the datagram
    public struct PacketInfo: Sendable {
        /// The packet data
        public let data: Data
        /// Whether this is a long header packet
        public let isLongHeader: Bool
        /// The offset in the original datagram
        public let offset: Int
    }

    /// Parses all packets from a coalesced datagram
    /// - Parameters:
    ///   - datagram: The UDP datagram data
    ///   - dcidLength: Expected DCID length for short header packets
    /// - Returns: Array of packet info for each packet found
    public static func parse(datagram: Data, dcidLength: Int = 0) throws -> [PacketInfo] {
        guard !datagram.isEmpty else {
            throw ParseError.emptyDatagram
        }

        // Pre-allocate for typical case of 2-3 coalesced packets
        var packets: [PacketInfo] = []
        packets.reserveCapacity(3)
        var offset = datagram.startIndex

        while offset < datagram.endIndex {
            let firstByte = datagram[offset]
            let isLongHeader = (firstByte & 0x80) != 0

            // Determine packet length
            let packetLength: Int
            let packetStart = offset

            if isLongHeader {
                // Long header packet - need to parse to find the length
                packetLength = try parseLongHeaderPacketLength(
                    datagram: datagram,
                    startOffset: offset
                )
            } else {
                // Short header packet - consumes rest of datagram
                // Per RFC 9000: "A short header packet always includes
                // a Destination Connection ID following the short header."
                // And: "A short header packet MUST be the last packet
                // included in a UDP datagram."
                packetLength = datagram.endIndex - offset
            }

            guard packetStart + packetLength <= datagram.endIndex else {
                throw ParseError.packetLengthExceedsDatagram
            }

            // Use slice directly without copying - Data slices share the underlying storage
            // via copy-on-write semantics, avoiding unnecessary allocations
            let packetData = datagram[packetStart..<(packetStart + packetLength)]
            packets.append(PacketInfo(
                data: packetData,  // Slice, not copy
                isLongHeader: isLongHeader,
                offset: packetStart - datagram.startIndex
            ))

            offset = packetStart + packetLength

            // Short header packets must be last
            if !isLongHeader {
                break
            }
        }

        return packets
    }

    /// Parses the length of a long header packet
    ///
    /// Optimized to create DataReader directly from slice (avoids advance overhead),
    /// use `readVarintValue()` instead of `readVarint()` for performance.
    private static func parseLongHeaderPacketLength(
        datagram: Data,
        startOffset: Data.Index
    ) throws -> Int {
        // Create reader directly from slice at startOffset - avoids advance() overhead
        let packetSlice = datagram[startOffset...]
        var reader = DataReader(packetSlice)

        guard let firstByte = reader.readByte() else {
            throw ParseError.insufficientData
        }

        // Read version
        guard let version = reader.readUInt32() else {
            throw ParseError.insufficientData
        }

        // Check if this is Version Negotiation (version == 0)
        if version == 0 {
            // Version Negotiation packets have no length field
            // They consume the rest of the datagram after the header
            // Header: 1 + 4 + 1 + DCID + 1 + SCID + versions...
            // We need to read DCID and SCID lengths
            guard let dcidLen = reader.readByte() else {
                throw ParseError.insufficientData
            }
            guard reader.remainingCount >= Int(dcidLen) else {
                throw ParseError.insufficientData
            }
            reader.advance(by: Int(dcidLen))  // Skip DCID bytes without allocating

            guard let scidLen = reader.readByte() else {
                throw ParseError.insufficientData
            }
            guard reader.remainingCount >= Int(scidLen) else {
                throw ParseError.insufficientData
            }
            reader.advance(by: Int(scidLen))  // Skip SCID bytes without allocating
            // Version Negotiation consumes the rest
            return packetSlice.count
        }

        // Read DCID length and skip DCID
        guard let dcidLen = reader.readByte() else {
            throw ParseError.insufficientData
        }
        guard reader.remainingCount >= Int(dcidLen) else {
            throw ParseError.insufficientData
        }
        reader.advance(by: Int(dcidLen))  // Skip DCID bytes without allocating

        // Read SCID length and skip SCID
        guard let scidLen = reader.readByte() else {
            throw ParseError.insufficientData
        }
        guard reader.remainingCount >= Int(scidLen) else {
            throw ParseError.insufficientData
        }
        reader.advance(by: Int(scidLen))  // Skip SCID bytes without allocating

        // Determine packet type
        let packetType = (firstByte >> 4) & 0x03

        switch packetType {
        case 0x00:  // Initial
            // Read token length and skip token
            let tokenLength = try reader.readVarintValue()
            let safeTokenLength = try SafeConversions.toInt(
                tokenLength,
                maxAllowed: ProtocolLimits.maxInitialTokenLength,
                context: "Initial packet token length (coalesced)"
            )
            guard reader.remainingCount >= safeTokenLength else {
                throw ParseError.insufficientData
            }
            reader.advance(by: safeTokenLength)  // Skip token bytes without allocating

            // Read Length field
            let length = try reader.readVarintValue()
            // Total length: header bytes read + payload length (currentPosition is relative to slice)
            let safeLength = try SafeConversions.toInt(
                length,
                maxAllowed: ProtocolLimits.maxLongHeaderLength,
                context: "Initial packet length field"
            )
            return try SafeConversions.add(reader.currentPosition, safeLength)

        case 0x01:  // 0-RTT
            // Read Length field
            let length = try reader.readVarintValue()
            let safeLength = try SafeConversions.toInt(
                length,
                maxAllowed: ProtocolLimits.maxLongHeaderLength,
                context: "0-RTT packet length field"
            )
            return try SafeConversions.add(reader.currentPosition, safeLength)

        case 0x02:  // Handshake
            // Read Length field
            let length = try reader.readVarintValue()
            let safeLength = try SafeConversions.toInt(
                length,
                maxAllowed: ProtocolLimits.maxLongHeaderLength,
                context: "Handshake packet length field"
            )
            return try SafeConversions.add(reader.currentPosition, safeLength)

        case 0x03:  // Retry
            // Retry packets have no Length field
            // They end at the integrity tag (16 bytes at the end)
            // Retry consumes the rest of the datagram
            return packetSlice.count

        default:
            throw ParseError.invalidPacketHeader
        }
    }
}

// MARK: - Convenience Extensions

extension CoalescedPacketBuilder {
    /// Creates a coalesced packet from an array of packet data
    /// - Parameters:
    ///   - packets: Array of encoded packet data
    ///   - maxDatagramSize: Maximum datagram size.  Callers must supply the
    ///     configured path MTU explicitly.
    /// - Returns: The coalesced packet data, or nil if no packets fit
    public static func coalesce(
        packets: [Data],
        maxDatagramSize: Int
    ) -> Data? {
        var builder = CoalescedPacketBuilder(maxDatagramSize: maxDatagramSize)
        for packet in packets {
            if !builder.addPacket(packet) {
                break
            }
        }
        return builder.isEmpty ? nil : builder.build()
    }
}

extension CoalescedPacketParser {
    /// Convenience method to parse and return just the packet data
    /// - Parameters:
    ///   - datagram: The UDP datagram
    ///   - dcidLength: Expected DCID length for short headers
    /// - Returns: Array of packet data
    public static func splitPackets(
        datagram: Data,
        dcidLength: Int = 0
    ) throws -> [Data] {
        try parse(datagram: datagram, dcidLength: dcidLength).map(\.data)
    }
}

// MARK: - Packet Ordering

/// Utility for ordering coalesced packets
public enum CoalescedPacketOrder {
    /// Returns the recommended order for coalescing packets
    ///
    /// RFC 9000 Section 12.2: "Senders SHOULD NOT coalesce QUIC packets
    /// with different connection IDs into a single UDP datagram."
    ///
    /// Order: Initial -> Handshake -> 0-RTT -> 1-RTT
    public static func sortOrder(for packetType: PacketType) -> Int {
        switch packetType {
        case .initial: return 0
        case .handshake: return 1
        case .zeroRTT: return 2
        case .oneRTT: return 3
        case .retry: return 4  // Retry shouldn't be coalesced
        case .versionNegotiation: return 5  // VN shouldn't be coalesced
        }
    }

    /// Sorts packets by recommended coalescing order
    /// - Parameter packets: Array of (packetType, packetData) tuples
    /// - Returns: Sorted array
    public static func sort(
        packets: [(packetType: PacketType, data: Data)]
    ) -> [(packetType: PacketType, data: Data)] {
        packets.sorted { sortOrder(for: $0.packetType) < sortOrder(for: $1.packetType) }
    }
}
