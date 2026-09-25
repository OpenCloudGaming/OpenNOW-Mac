/// QUIC Frame Type Definitions
///
/// Detailed structures for each QUIC frame type.

import Foundation

// MARK: - ACK Frame

/// ACK frame (RFC 9000 Section 19.3)
public struct AckFrame: Sendable, Hashable {
    /// Largest packet number being acknowledged
    public let largestAcknowledged: UInt64

    /// Time since the largest acknowledged packet was received (in microseconds)
    public let ackDelay: UInt64

    /// Acknowledged packet number ranges
    public let ackRanges: [AckRange]

    /// ECN counts (if present)
    public let ecnCounts: ECNCounts?

    /// Creates an ACK frame
    public init(
        largestAcknowledged: UInt64,
        ackDelay: UInt64,
        ackRanges: [AckRange],
        ecnCounts: ECNCounts? = nil
    ) {
        self.largestAcknowledged = largestAcknowledged
        self.ackDelay = ackDelay
        self.ackRanges = ackRanges
        self.ecnCounts = ecnCounts
    }
}

/// A range of acknowledged packet numbers
public struct AckRange: Sendable, Hashable {
    /// Gap before this range (number of unacknowledged packets)
    public let gap: UInt64

    /// Length of this acknowledged range
    public let rangeLength: UInt64

    public init(gap: UInt64, rangeLength: UInt64) {
        self.gap = gap
        self.rangeLength = rangeLength
    }
}

/// ECN (Explicit Congestion Notification) counts
public struct ECNCounts: Sendable, Hashable {
    public let ect0Count: UInt64
    public let ect1Count: UInt64
    public let ecnCECount: UInt64

    public init(ect0Count: UInt64, ect1Count: UInt64, ecnCECount: UInt64) {
        self.ect0Count = ect0Count
        self.ect1Count = ect1Count
        self.ecnCECount = ecnCECount
    }
}

// MARK: - STREAM Frame

/// STREAM frame (RFC 9000 Section 19.8)
public struct StreamFrame: Sendable, Hashable {
    /// Stream identifier
    public let streamID: UInt64

    /// Byte offset in the stream
    public let offset: UInt64

    /// Stream data
    public let data: Data

    /// Whether this is the final data on the stream
    public let fin: Bool

    /// Whether the frame includes an explicit length field.
    /// If false, the frame consumes all remaining bytes in the packet
    /// and must be the last frame (per RFC 9000 Section 12.4).
    public let hasLength: Bool

    /// Creates a STREAM frame
    public init(
        streamID: UInt64,
        offset: UInt64,
        data: Data,
        fin: Bool = false,
        hasLength: Bool = true
    ) {
        self.streamID = streamID
        self.offset = offset
        self.data = data
        self.fin = fin
        self.hasLength = hasLength
    }

    /// The frame type byte (0x08 with flags)
    public var frameTypeByte: UInt8 {
        var byte: UInt8 = 0x08
        if offset > 0 { byte |= 0x04 }  // OFF bit
        if hasLength { byte |= 0x02 }    // LEN bit
        if fin { byte |= 0x01 }          // FIN bit
        return byte
    }
}

// MARK: - CRYPTO Frame

/// CRYPTO frame (RFC 9000 Section 19.6)
public struct CryptoFrame: Sendable, Hashable {
    /// Byte offset in the crypto stream
    public let offset: UInt64

    /// Cryptographic handshake data
    public let data: Data

    /// Creates a CRYPTO frame
    public init(offset: UInt64, data: Data) {
        self.offset = offset
        self.data = data
    }
}

// MARK: - RESET_STREAM Frame

/// RESET_STREAM frame (RFC 9000 Section 19.4)
public struct ResetStreamFrame: Sendable, Hashable {
    /// Stream identifier
    public let streamID: UInt64

    /// Application protocol error code
    public let applicationErrorCode: UInt64

    /// Final size of the stream
    public let finalSize: UInt64

    public init(streamID: UInt64, applicationErrorCode: UInt64, finalSize: UInt64) {
        self.streamID = streamID
        self.applicationErrorCode = applicationErrorCode
        self.finalSize = finalSize
    }
}

// MARK: - STOP_SENDING Frame

/// STOP_SENDING frame (RFC 9000 Section 19.5)
public struct StopSendingFrame: Sendable, Hashable {
    /// Stream identifier
    public let streamID: UInt64

    /// Application protocol error code
    public let applicationErrorCode: UInt64

    public init(streamID: UInt64, applicationErrorCode: UInt64) {
        self.streamID = streamID
        self.applicationErrorCode = applicationErrorCode
    }
}

// MARK: - MAX_DATA Frame

/// MAX_DATA frame (RFC 9000 Section 19.9)
public struct MaxDataFrame: Sendable, Hashable {
    /// Maximum amount of data that can be sent on the connection
    public let maxData: UInt64

    public init(maxData: UInt64) {
        self.maxData = maxData
    }
}

// MARK: - MAX_STREAM_DATA Frame

/// MAX_STREAM_DATA frame (RFC 9000 Section 19.10)
public struct MaxStreamDataFrame: Sendable, Hashable {
    /// Stream identifier
    public let streamID: UInt64

    /// Maximum amount of data that can be sent
    public let maxStreamData: UInt64

    public init(streamID: UInt64, maxStreamData: UInt64) {
        self.streamID = streamID
        self.maxStreamData = maxStreamData
    }
}

// MARK: - MAX_STREAMS Frame

/// MAX_STREAMS frame (RFC 9000 Section 19.11)
public struct MaxStreamsFrame: Sendable, Hashable {
    /// Maximum number of streams
    public let maxStreams: UInt64

    /// Whether this applies to bidirectional streams
    public let isBidirectional: Bool

    public init(maxStreams: UInt64, isBidirectional: Bool) {
        self.maxStreams = maxStreams
        self.isBidirectional = isBidirectional
    }
}

// MARK: - DATA_BLOCKED Frame

/// DATA_BLOCKED frame (RFC 9000 Section 19.12)
public struct DataBlockedFrame: Sendable, Hashable {
    /// Connection data limit at which blocking occurred
    public let dataLimit: UInt64

    public init(dataLimit: UInt64) {
        self.dataLimit = dataLimit
    }
}

// MARK: - STREAM_DATA_BLOCKED Frame

/// STREAM_DATA_BLOCKED frame (RFC 9000 Section 19.13)
public struct StreamDataBlockedFrame: Sendable, Hashable {
    /// Stream identifier
    public let streamID: UInt64

    /// Stream data limit at which blocking occurred
    public let streamDataLimit: UInt64

    public init(streamID: UInt64, streamDataLimit: UInt64) {
        self.streamID = streamID
        self.streamDataLimit = streamDataLimit
    }
}

// MARK: - STREAMS_BLOCKED Frame

/// STREAMS_BLOCKED frame (RFC 9000 Section 19.14)
public struct StreamsBlockedFrame: Sendable, Hashable {
    /// Stream limit at which blocking occurred
    public let streamLimit: UInt64

    /// Whether this applies to bidirectional streams
    public let isBidirectional: Bool

    public init(streamLimit: UInt64, isBidirectional: Bool) {
        self.streamLimit = streamLimit
        self.isBidirectional = isBidirectional
    }
}

// MARK: - NEW_CONNECTION_ID Frame

/// NEW_CONNECTION_ID frame (RFC 9000 Section 19.15)
public struct NewConnectionIDFrame: Sendable, Hashable {
    /// Sequence number for this connection ID
    public let sequenceNumber: UInt64

    /// Sequence number of the connection ID being retired
    public let retirePriorTo: UInt64

    /// The new connection ID
    public let connectionID: ConnectionID

    /// Stateless reset token (16 bytes)
    public let statelessResetToken: Data

    /// Creates a NEW_CONNECTION_ID frame with validation
    ///
    /// - Parameters:
    ///   - sequenceNumber: Sequence number for this connection ID
    ///   - retirePriorTo: Sequence number of the connection ID being retired
    ///   - connectionID: The new connection ID
    ///   - statelessResetToken: Stateless reset token (must be exactly 16 bytes)
    /// - Throws: `FrameError.invalidStatelessResetTokenLength` if token is not 16 bytes
    public init(
        sequenceNumber: UInt64,
        retirePriorTo: UInt64,
        connectionID: ConnectionID,
        statelessResetToken: Data
    ) throws {
        guard statelessResetToken.count == ProtocolLimits.statelessResetTokenLength else {
            throw FrameError.invalidStatelessResetTokenLength(
                actual: statelessResetToken.count,
                expected: ProtocolLimits.statelessResetTokenLength
            )
        }
        self.sequenceNumber = sequenceNumber
        self.retirePriorTo = retirePriorTo
        self.connectionID = connectionID
        self.statelessResetToken = statelessResetToken
    }

    /// Creates a NEW_CONNECTION_ID frame without validation (internal use)
    ///
    /// Use this only when the token is known to be valid (e.g., locally generated).
    internal init(
        unchecked sequenceNumber: UInt64,
        retirePriorTo: UInt64,
        connectionID: ConnectionID,
        statelessResetToken: Data
    ) {
        assert(statelessResetToken.count == ProtocolLimits.statelessResetTokenLength,
               "Stateless reset token must be \(ProtocolLimits.statelessResetTokenLength) bytes")
        self.sequenceNumber = sequenceNumber
        self.retirePriorTo = retirePriorTo
        self.connectionID = connectionID
        self.statelessResetToken = statelessResetToken
    }
}

/// Errors that can occur when creating frames
public enum FrameError: Error, Sendable, Equatable {
    /// Stateless reset token has invalid length
    case invalidStatelessResetTokenLength(actual: Int, expected: Int)
}

// MARK: - CONNECTION_CLOSE Frame

/// CONNECTION_CLOSE frame (RFC 9000 Section 19.19)
public struct ConnectionCloseFrame: Sendable, Hashable {
    /// Error code
    public let errorCode: UInt64

    /// Frame type that triggered the error (for transport errors)
    public let frameType: UInt64?

    /// Human-readable reason phrase
    public let reasonPhrase: String

    /// Whether this is an application-level error (type 0x1d) vs transport error (type 0x1c)
    public let isApplicationError: Bool

    public init(
        errorCode: UInt64,
        frameType: UInt64? = nil,
        reasonPhrase: String = "",
        isApplicationError: Bool = false
    ) {
        self.errorCode = errorCode
        self.frameType = isApplicationError ? nil : frameType
        self.reasonPhrase = reasonPhrase
        self.isApplicationError = isApplicationError
    }
}

// MARK: - DATAGRAM Frame

/// DATAGRAM frame (RFC 9221)
public struct DatagramFrame: Sendable, Hashable {
    /// Datagram data
    public let data: Data

    /// Whether the frame includes an explicit length field
    public let hasLength: Bool

    public init(data: Data, hasLength: Bool = true) {
        self.data = data
        self.hasLength = hasLength
    }
}
