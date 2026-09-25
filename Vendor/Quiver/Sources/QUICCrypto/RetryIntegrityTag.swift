/// QUIC Retry Integrity Tag (RFC 9001 Section 5.8)
///
/// Provides cryptographic integrity protection for Retry packets.
/// Uses AES-128-GCM with version-specific fixed keys.

import Foundation
import Crypto
import QUICCore

// MARK: - Retry Errors

/// Errors that can occur during Retry processing
public enum QUICRetryError: Error, Sendable {
    /// Retry Integrity Tag verification failed
    case integrityTagMismatch
    /// Missing Retry Token in packet
    case missingRetryToken
    /// Invalid packet format
    case invalidPacketFormat(reason: String)
    /// Unsupported QUIC version for Retry
    case unsupportedVersion(QUICVersion)
}

// MARK: - Retry Integrity Tag

/// Handles Retry Integrity Tag computation and verification
///
/// RFC 9001 Section 5.8: A server that sends a Retry packet MUST include
/// a Retry Integrity Tag at the end of the packet. The tag is computed
/// over a pseudo-packet that includes the Original DCID.
///
/// ## Pseudo-Packet Format
/// ```
/// Retry Pseudo-Packet {
///   ODCID Length (8),
///   Original Destination Connection ID (0..160),
///   Header Form (1) = 1,
///   Fixed Bit (1) = 1,
///   Long Packet Type (2) = 3,
///   Unused (4),
///   Version (32),
///   DCID Len (8),
///   Destination Connection ID (..),
///   SCID Len (8),
///   Source Connection ID (..),
///   Retry Token (..),
/// }
/// ```
public struct RetryIntegrityTag: Sendable {

    /// Tag length is always 16 bytes (AES-128-GCM tag)
    public static let tagLength = 16

    // MARK: - Computation

    /// Computes the Retry Integrity Tag for a Retry packet
    ///
    /// RFC 9001 Section 5.8: The tag is computed using AES-128-GCM with
    /// version-specific key and nonce.
    ///
    /// - Parameters:
    ///   - originalDCID: The original Destination Connection ID from client's Initial
    ///   - retryPacket: The Retry packet data (without the integrity tag)
    ///   - version: The QUIC version
    /// - Returns: 16-byte Retry Integrity Tag
    /// - Throws: QUICRetryError if computation fails
    public static func compute(
        originalDCID: ConnectionID,
        retryPacket: Data,
        version: QUICVersion
    ) throws -> Data {
        // Get version-specific key and nonce
        guard let key = version.retryIntegrityKey,
              let nonce = version.retryIntegrityNonce else {
            throw QUICRetryError.unsupportedVersion(version)
        }

        // Build the pseudo-packet
        let pseudoPacket = buildPseudoPacket(originalDCID: originalDCID, retryPacket: retryPacket)

        // Compute AEAD tag using AES-128-GCM
        // Empty plaintext, pseudo-packet as AAD
        let symmetricKey = SymmetricKey(data: key)
        let nonceObj = try AES.GCM.Nonce(data: nonce)

        let sealedBox = try AES.GCM.seal(
            Data(),  // Empty plaintext
            using: symmetricKey,
            nonce: nonceObj,
            authenticating: pseudoPacket
        )

        return sealedBox.tag
    }

    // MARK: - Verification

    /// Verifies the Retry Integrity Tag
    ///
    /// RFC 9001 Section 5.8: A client that receives a Retry packet MUST
    /// validate the Retry Integrity Tag.
    ///
    /// - Parameters:
    ///   - tag: The received integrity tag (16 bytes)
    ///   - originalDCID: The original DCID the client sent
    ///   - retryPacketWithoutTag: The Retry packet without the tag
    ///   - version: The QUIC version
    /// - Returns: True if verification succeeds
    /// - Throws: QUICRetryError if verification fails
    public static func verify(
        tag: Data,
        originalDCID: ConnectionID,
        retryPacketWithoutTag: Data,
        version: QUICVersion
    ) throws -> Bool {
        guard tag.count == tagLength else {
            throw QUICRetryError.invalidPacketFormat(reason: "Invalid tag length: \(tag.count)")
        }

        // Compute expected tag
        let expectedTag = try compute(
            originalDCID: originalDCID,
            retryPacket: retryPacketWithoutTag,
            version: version
        )

        // Constant-time comparison
        return constantTimeCompare(tag, expectedTag)
    }

    // MARK: - Pseudo-Packet Building

    /// Builds the pseudo-packet for integrity tag computation
    ///
    /// The pseudo-packet prepends the original DCID (with length prefix)
    /// to the Retry packet.
    private static func buildPseudoPacket(originalDCID: ConnectionID, retryPacket: Data) -> Data {
        var pseudoPacket = Data()

        // ODCID Length (1 byte)
        pseudoPacket.append(UInt8(originalDCID.length))

        // Original Destination Connection ID
        pseudoPacket.append(originalDCID.bytes)

        // Rest of the Retry packet
        pseudoPacket.append(retryPacket)

        return pseudoPacket
    }

    // MARK: - Retry Packet Creation

    /// Creates a complete Retry packet with integrity tag
    ///
    /// - Parameters:
    ///   - originalDCID: The DCID from the client's Initial packet
    ///   - destinationCID: The CID to send to client (typically client's SCID)
    ///   - sourceCID: The new CID the server wants the client to use
    ///   - retryToken: The retry token for address validation
    ///   - version: The QUIC version
    /// - Returns: Complete Retry packet with integrity tag
    /// - Throws: QUICRetryError if creation fails
    public static func createRetryPacket(
        originalDCID: ConnectionID,
        destinationCID: ConnectionID,
        sourceCID: ConnectionID,
        retryToken: Data,
        version: QUICVersion
    ) throws -> Data {
        // Build Retry packet without tag
        var packet = Data()

        // First byte: Form=1, Fixed=1, Type=11 (Retry), Unused=0000
        packet.append(0xF0)

        // Version
        version.encode(to: &packet)

        // DCID Length + DCID
        packet.append(UInt8(destinationCID.length))
        packet.append(destinationCID.bytes)

        // SCID Length + SCID
        packet.append(UInt8(sourceCID.length))
        packet.append(sourceCID.bytes)

        // Retry Token
        packet.append(retryToken)

        // Compute and append integrity tag
        let tag = try compute(originalDCID: originalDCID, retryPacket: packet, version: version)
        packet.append(tag)

        return packet
    }

    // MARK: - Parsing

    /// Parses a Retry packet and extracts components
    ///
    /// - Parameter data: The complete Retry packet data
    /// - Returns: Tuple of (version, destinationCID, sourceCID, retryToken, integrityTag)
    /// - Throws: QUICRetryError if parsing fails
    public static func parseRetryPacket(
        _ data: Data
    ) throws -> (
        version: QUICVersion,
        destinationCID: ConnectionID,
        sourceCID: ConnectionID,
        retryToken: Data,
        integrityTag: Data
    ) {
        // Minimum: 1 (first) + 4 (version) + 1 (dcid len) + 1 (scid len) + 16 (tag)
        guard data.count >= 23 else {
            throw QUICRetryError.invalidPacketFormat(reason: "Packet too short")
        }

        var reader = DataReader(data)

        // First byte
        guard let firstByte = reader.readByte() else {
            throw QUICRetryError.invalidPacketFormat(reason: "Missing header")
        }

        // Verify it's a long header packet (form bit = 1)
        guard (firstByte & 0x80) != 0 else {
            throw QUICRetryError.invalidPacketFormat(reason: "Not a long header packet")
        }

        // Version
        guard let version = QUICVersion.decode(from: &reader) else {
            throw QUICRetryError.invalidPacketFormat(reason: "Cannot read version")
        }

        // DCID
        guard let dcidLength = reader.readByte() else {
            throw QUICRetryError.invalidPacketFormat(reason: "Missing DCID length")
        }
        guard let dcidBytes = reader.readBytes(Int(dcidLength)) else {
            throw QUICRetryError.invalidPacketFormat(reason: "Cannot read DCID")
        }

        // SCID
        guard let scidLength = reader.readByte() else {
            throw QUICRetryError.invalidPacketFormat(reason: "Missing SCID length")
        }
        guard let scidBytes = reader.readBytes(Int(scidLength)) else {
            throw QUICRetryError.invalidPacketFormat(reason: "Cannot read SCID")
        }

        // Remaining data = Retry Token + Integrity Tag (last 16 bytes)
        guard reader.remainingCount >= tagLength else {
            throw QUICRetryError.invalidPacketFormat(reason: "Missing integrity tag")
        }

        let tokenLength = reader.remainingCount - tagLength
        let retryToken: Data
        if tokenLength > 0 {
            guard let tokenBytes = reader.readBytes(tokenLength) else {
                throw QUICRetryError.invalidPacketFormat(reason: "Cannot read retry token")
            }
            retryToken = tokenBytes
        } else {
            retryToken = Data()
        }

        // Integrity Tag
        guard let tag = reader.readBytes(tagLength) else {
            throw QUICRetryError.invalidPacketFormat(reason: "Cannot read integrity tag")
        }

        return (
            version: version,
            destinationCID: try ConnectionID(bytes: dcidBytes),
            sourceCID: try ConnectionID(bytes: scidBytes),
            retryToken: retryToken,
            integrityTag: tag
        )
    }

    /// Extracts the Retry packet without the integrity tag
    ///
    /// - Parameter data: The complete Retry packet
    /// - Returns: The packet data without the last 16 bytes (tag)
    public static func retryPacketWithoutTag(_ data: Data) -> Data {
        guard data.count > tagLength else {
            return data
        }
        return data.prefix(data.count - tagLength)
    }

    // MARK: - Utility

    /// Constant-time comparison of two Data objects
    private static func constantTimeCompare(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }

        var result: UInt8 = 0
        for i in 0..<lhs.count {
            result |= lhs[lhs.startIndex + i] ^ rhs[rhs.startIndex + i]
        }
        return result == 0
    }
}

// MARK: - Detection

extension RetryIntegrityTag {
    /// Checks if a packet is a Retry packet
    ///
    /// - Parameter data: The packet data
    /// - Returns: True if this is likely a Retry packet
    public static func isRetryPacket(_ data: Data) -> Bool {
        // Must have at least: first byte + 4 bytes version + 1 dcid len + 1 scid len + 16 tag
        guard data.count >= 23 else { return false }

        // Check long header format (first bit = 1)
        guard (data[0] & 0x80) != 0 else { return false }

        // Check version is not 0 (that's Version Negotiation)
        let version = UInt32(data[1]) << 24 | UInt32(data[2]) << 16 |
                      UInt32(data[3]) << 8 | UInt32(data[4])
        guard version != 0 else { return false }

        // Check packet type is Retry (type bits = 11)
        let packetType = (data[0] >> 4) & 0x03
        return packetType == 0x03
    }
}
