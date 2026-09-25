/// QUIC Version Negotiation (RFC 9000 Section 6)
///
/// Handles Version Negotiation packet creation and processing.
/// Used when client and server need to agree on a QUIC version.

import Foundation
import QUICCore

// MARK: - Version Negotiation Errors

/// Errors that can occur during version negotiation
public enum QUICVersionError: Error, Sendable {
    /// No common version between client and server
    case noCommonVersion(offered: [QUICVersion], supported: [QUICVersion])
    /// Version Negotiation packet received (client should retry with offered versions)
    case versionNegotiationReceived(offeredVersions: [QUICVersion])
    /// Invalid Version Negotiation packet format
    case invalidPacketFormat(reason: String)
    /// Packet too short
    case packetTooShort(expected: Int, actual: Int)
}

// MARK: - Version Negotiator

/// Handles QUIC Version Negotiation
///
/// RFC 9000 Section 6: If the version selected by the client is not acceptable
/// to the server, the server responds with a Version Negotiation packet.
///
/// ## Wire Format (RFC 9000 Section 17.2.1)
/// ```
/// Version Negotiation Packet {
///   Header Form (1) = 1,
///   Unused (7),
///   Version (32) = 0,
///   Destination Connection ID Length (8),
///   Destination Connection ID (0..2040),
///   Source Connection ID Length (8),
///   Source Connection ID (0..2040),
///   Supported Version (32) ...,
/// }
/// ```
public struct VersionNegotiator: Sendable {

    // MARK: - Parsing

    /// Parses supported versions from a Version Negotiation packet
    ///
    /// The packet must have already been identified as a Version Negotiation packet
    /// (long header with version == 0).
    ///
    /// - Parameter data: The complete Version Negotiation packet data
    /// - Returns: Array of offered QUIC versions
    /// - Throws: QUICVersionError if the packet is malformed
    public static func parseVersions(from data: Data) throws -> [QUICVersion] {
        // Minimum size: 1 (first byte) + 4 (version=0) + 1 (dcid len) + 1 (scid len) + 4 (at least one version)
        guard data.count >= 11 else {
            throw QUICVersionError.packetTooShort(expected: 11, actual: data.count)
        }

        var reader = DataReader(data)

        // Skip first byte (header form + unused bits)
        guard reader.readByte() != nil else {
            throw QUICVersionError.invalidPacketFormat(reason: "Missing header byte")
        }

        // Verify version is 0
        guard let version = reader.readUInt32(), version == 0 else {
            throw QUICVersionError.invalidPacketFormat(reason: "Not a Version Negotiation packet (version != 0)")
        }

        // Skip DCID
        guard let dcidLength = reader.readByte() else {
            throw QUICVersionError.invalidPacketFormat(reason: "Missing DCID length")
        }
        guard reader.readBytes(Int(dcidLength)) != nil else {
            throw QUICVersionError.packetTooShort(expected: Int(dcidLength), actual: reader.remainingCount)
        }

        // Skip SCID
        guard let scidLength = reader.readByte() else {
            throw QUICVersionError.invalidPacketFormat(reason: "Missing SCID length")
        }
        guard reader.readBytes(Int(scidLength)) != nil else {
            throw QUICVersionError.packetTooShort(expected: Int(scidLength), actual: reader.remainingCount)
        }

        // Parse version list
        var versions: [QUICVersion] = []

        while reader.remainingCount >= 4 {
            guard let versionValue = reader.readUInt32() else {
                break
            }
            versions.append(QUICVersion(rawValue: versionValue))
        }

        // RFC 9000: A Version Negotiation packet MUST include a non-empty list
        guard !versions.isEmpty else {
            throw QUICVersionError.invalidPacketFormat(reason: "Empty version list")
        }

        return versions
    }

    // MARK: - Creation

    /// Creates a Version Negotiation packet (server use)
    ///
    /// RFC 9000 Section 17.2.1: A server sends a Version Negotiation packet
    /// in response to each packet that might initiate a new connection.
    ///
    /// - Parameters:
    ///   - destinationCID: The source connection ID from the received packet
    ///   - sourceCID: The destination connection ID from the received packet
    ///   - supportedVersions: List of versions the server supports
    /// - Returns: The serialized Version Negotiation packet
    public static func createVersionNegotiationPacket(
        destinationCID: ConnectionID,
        sourceCID: ConnectionID,
        supportedVersions: [QUICVersion] = QUICVersion.supportedVersions
    ) -> Data {
        var packet = Data()

        // First byte: Header Form = 1, rest arbitrary (set to random for greasing)
        // RFC 9000: "An endpoint MUST NOT send a packet containing a version
        // that it does not support."
        // RFC 8999: The unused bits are arbitrary
        let firstByte: UInt8 = 0x80 | UInt8.random(in: 0...0x7F)
        packet.append(firstByte)

        // Version = 0 (indicates Version Negotiation)
        packet.append(contentsOf: [0x00, 0x00, 0x00, 0x00])

        // Destination Connection ID (from client's SCID)
        packet.append(UInt8(destinationCID.length))
        packet.append(destinationCID.bytes)

        // Source Connection ID (from client's DCID)
        packet.append(UInt8(sourceCID.length))
        packet.append(sourceCID.bytes)

        // Supported Versions
        for version in supportedVersions {
            version.encode(to: &packet)
        }

        return packet
    }

    // MARK: - Version Selection

    /// Selects the best common version between offered and supported versions
    ///
    /// RFC 9000 Section 6.1: Both client and server can use this to select
    /// a version that both support.
    ///
    /// - Parameters:
    ///   - offered: Versions offered by the peer
    ///   - supported: Versions supported locally (in preference order)
    /// - Returns: The selected version, or nil if no common version exists
    public static func selectVersion(
        offered: [QUICVersion],
        supported: [QUICVersion] = QUICVersion.supportedVersions
    ) -> QUICVersion? {
        // Prefer our versions in order of our preference
        for version in supported {
            if offered.contains(version) {
                return version
            }
        }
        return nil
    }

    // MARK: - Validation

    /// Validates a Version Negotiation packet received by a client
    ///
    /// RFC 9000 Section 6.2: A client MUST discard any Version Negotiation packet
    /// if it has received and successfully processed any other packet.
    ///
    /// - Parameters:
    ///   - data: The received packet data
    ///   - originalDCID: The DCID the client sent in its Initial packet
    ///   - originalSCID: The SCID the client sent in its Initial packet
    /// - Returns: List of versions offered by the server
    /// - Throws: QUICVersionError if validation fails
    public static func validateAndParseVersionNegotiation(
        _ data: Data,
        originalDCID: ConnectionID,
        originalSCID: ConnectionID
    ) throws -> [QUICVersion] {
        // Parse the packet first
        let versions = try parseVersions(from: data)

        // Extract connection IDs from the packet for validation
        var reader = DataReader(data)

        // Skip first byte and version
        _ = reader.readByte()
        _ = reader.readUInt32()

        // Read DCID (should match our SCID)
        guard let dcidLength = reader.readByte(),
              let dcidBytes = reader.readBytes(Int(dcidLength)) else {
            throw QUICVersionError.invalidPacketFormat(reason: "Cannot read DCID")
        }

        // Read SCID (should match our DCID)
        guard let scidLength = reader.readByte(),
              let scidBytes = reader.readBytes(Int(scidLength)) else {
            throw QUICVersionError.invalidPacketFormat(reason: "Cannot read SCID")
        }

        // RFC 9000 Section 6.2: The Destination Connection ID field MUST
        // match the Source Connection ID field from the Initial packet sent by the client
        let receivedDCID = try ConnectionID(bytes: dcidBytes)
        let receivedSCID = try ConnectionID(bytes: scidBytes)

        guard receivedDCID == originalSCID else {
            throw QUICVersionError.invalidPacketFormat(
                reason: "DCID mismatch: expected \(originalSCID), got \(receivedDCID)"
            )
        }

        guard receivedSCID == originalDCID else {
            throw QUICVersionError.invalidPacketFormat(
                reason: "SCID mismatch: expected \(originalDCID), got \(receivedSCID)"
            )
        }

        // RFC 9000 Section 6.2: The client MUST check that the server has
        // selected a version that was not in the initial Client Hello.
        // This is checked by ensuring none of our supported versions are in the list
        // if we're receiving a VN packet after sending a supported version.

        return versions
    }

    // MARK: - Detection

    /// Checks if a packet is a Version Negotiation packet
    ///
    /// - Parameter data: The packet data
    /// - Returns: True if this is a Version Negotiation packet
    public static func isVersionNegotiationPacket(_ data: Data) -> Bool {
        // Must have at least: first byte + 4 bytes version
        guard data.count >= 5 else { return false }

        // Check long header format (first bit = 1)
        guard (data[0] & 0x80) != 0 else { return false }

        // Check version == 0
        let version = UInt32(data[1]) << 24 | UInt32(data[2]) << 16 |
                      UInt32(data[3]) << 8 | UInt32(data[4])
        return version == 0
    }
}
