/// QUIC Protocol Limits (RFC 9000 Compliance)
///
/// Defines maximum values for various QUIC protocol fields.
/// These limits ensure safe parsing of untrusted network data
/// and prevent memory exhaustion attacks.
///
/// Some limits are mandated by RFC 9000, others are implementation
/// choices based on practical considerations (e.g., UDP MTU constraints).
///
/// ## RFC Constants vs Configurable Values
///
/// Values in this file are **protocol-mandated constants** that MUST NOT
/// change regardless of configuration.  Runtime-configurable sizes (such
/// as the active path MTU) belong in ``QUICConfiguration`` and are plumbed
/// through the connection stack at initialisation time.

import Foundation

/// Protocol-defined limits for QUIC fields
public enum ProtocolLimits {

    // MARK: - Datagram Size (RFC 9000 Section 14)

    /// Minimum UDP payload size that all QUIC implementations MUST support.
    ///
    /// RFC 9000 Section 14:
    /// > "QUIC MUST NOT be used if the network path cannot support a
    /// >  maximum datagram size of at least 1200 bytes."
    ///
    /// This is the absolute floor for `max_udp_payload_size` and the
    /// minimum size to which Initial packets MUST be padded.
    /// It is an RFC constant and MUST NOT be made configurable.
    public static let minimumMaximumDatagramSize = 1200

    /// Minimum UDP datagram size for Initial packets (RFC 9000 Section 14.1).
    ///
    /// > "A client MUST expand the payload of all UDP datagrams carrying
    /// >  Initial packets to at least the smallest maximum datagram size
    /// >  of 1200 bytes."
    ///
    /// Equivalent to ``minimumMaximumDatagramSize``; kept as a separate
    /// name for call-site clarity when padding Initial packets.
    public static let minimumInitialPacketSize = minimumMaximumDatagramSize

    // MARK: - Connection ID (RFC 9000 Section 17.2)

    /// Maximum length of a Connection ID
    /// RFC 9000: "Connection IDs MUST NOT be more than 20 bytes"
    public static let maxConnectionIDLength = 20

    // MARK: - Stateless Reset (RFC 9000 Section 10.3)

    /// Length of a Stateless Reset Token (fixed)
    /// RFC 9000: "The Stateless Reset Token is 16 bytes"
    public static let statelessResetTokenLength = 16

    // MARK: - Packet Limits

    /// Maximum length of an Initial packet token.
    ///
    /// Not specified by RFC, but bounded by the minimum datagram size
    /// (``minimumMaximumDatagramSize``) minus header overhead.
    public static let maxInitialTokenLength = minimumMaximumDatagramSize

    /// Maximum packet payload length
    /// Based on maximum UDP datagram size minus headers
    /// 65535 (max UDP) - 8 (UDP header) - 20 (IP header minimum)
    public static let maxPacketPayloadLength = 65507

    /// Maximum Long Header length field value
    /// Length field includes packet number (1-4 bytes) and encrypted payload
    /// We use a practical limit to prevent memory exhaustion
    public static let maxLongHeaderLength = 65535

    // MARK: - Frame Limits

    /// Maximum CRYPTO frame data length
    /// TLS handshake messages are typically a few KB
    /// We allow up to 64KB to handle large certificate chains
    public static let maxCryptoDataLength = 65535

    /// Maximum STREAM frame data length
    /// Limited by packet size, but we enforce a maximum
    public static let maxStreamDataLength = 65535

    /// Maximum NEW_TOKEN frame token length.
    ///
    /// Bounded by ``minimumMaximumDatagramSize`` to guarantee the token
    /// fits in the smallest compliant datagram.
    public static let maxNewTokenLength = minimumMaximumDatagramSize

    /// Maximum CONNECTION_CLOSE reason phrase length
    /// RFC 9000 does not specify, but reason phrases should be human-readable
    /// and reasonably short
    public static let maxReasonPhraseLength = 1024

    /// Maximum DATAGRAM frame data length
    /// RFC 9221 does not specify, limited by packet size
    public static let maxDatagramLength = 65535

    /// Maximum number of ACK ranges in an ACK frame
    /// Prevents memory exhaustion from malicious ACK frames
    /// Typical implementations use much smaller values
    public static let maxAckRanges: UInt64 = 256

    // MARK: - Transport Parameters (RFC 9000 Section 18)

    /// Maximum transport parameter value length
    /// Most parameters are varints (8 bytes max), but some like
    /// preferred_address are larger
    public static let maxTransportParameterLength = 65535

    /// Maximum length of preferred_address parameter
    /// IPv6 address (16) + port (2) + CID length (1) + CID (20) + token (16) = 55
    /// Plus IPv4 components
    public static let maxPreferredAddressLength = 128

    // MARK: - Retry (RFC 9000 Section 17.2.5)

    /// Length of Retry Integrity Tag (fixed)
    /// RFC 9000: "The value in Retry Integrity Tag is computed as..."
    /// using AEAD which produces 16-byte tags
    public static let retryIntegrityTagLength = 16

    // MARK: - Utility Methods

    /// Validates a length value against a specified limit
    /// - Parameters:
    ///   - length: The length value to validate
    ///   - limit: The maximum allowed value
    ///   - context: Description for error messages
    /// - Throws: If length exceeds limit
    @inlinable
    public static func validateLength(
        _ length: UInt64,
        maxAllowed limit: Int,
        context: String
    ) throws {
        guard length <= UInt64(limit) else {
            throw ConversionError.exceedsLimit(
                value: length,
                limit: limit,
                context: context
            )
        }
    }
}
