/// QUIC Stream State Machine
///
/// Manages the lifecycle of individual QUIC streams.

import Foundation
import QUICCore

// MARK: - Stream ID

/// Utilities for working with QUIC stream IDs
public enum StreamID {
    /// Stream type based on ID
    public enum StreamType: Sendable {
        case clientInitiatedBidirectional
        case serverInitiatedBidirectional
        case clientInitiatedUnidirectional
        case serverInitiatedUnidirectional
    }

    /// Gets the stream type from a stream ID
    public static func streamType(for id: UInt64) -> StreamType {
        switch id & 0x03 {
        case 0x00: return .clientInitiatedBidirectional
        case 0x01: return .serverInitiatedBidirectional
        case 0x02: return .clientInitiatedUnidirectional
        case 0x03: return .serverInitiatedUnidirectional
        default: fatalError("Unreachable")
        }
    }

    /// Whether the stream is bidirectional
    public static func isBidirectional(_ id: UInt64) -> Bool {
        (id & 0x02) == 0
    }

    /// Whether the stream is unidirectional
    public static func isUnidirectional(_ id: UInt64) -> Bool {
        (id & 0x02) != 0
    }

    /// Whether the stream was initiated by the client
    public static func isClientInitiated(_ id: UInt64) -> Bool {
        (id & 0x01) == 0
    }

    /// Whether the stream was initiated by the server
    public static func isServerInitiated(_ id: UInt64) -> Bool {
        (id & 0x01) != 0
    }

    /// Creates a stream ID
    /// - Parameters:
    ///   - index: The stream index (0, 1, 2, ...)
    ///   - isClient: Whether this is a client-initiated stream
    ///   - isBidirectional: Whether this is a bidirectional stream
    public static func make(index: UInt64, isClient: Bool, isBidirectional: Bool) -> UInt64 {
        var id = index << 2
        if !isClient { id |= 0x01 }
        if !isBidirectional { id |= 0x02 }
        return id
    }
}

// MARK: - Stream State

/// Send-side stream state
@frozen
public enum SendState: Sendable, Hashable {
    case ready
    case send
    case dataSent
    case dataRecvd
    case resetSent
    case resetRecvd
}

/// Receive-side stream state
@frozen
public enum RecvState: Sendable, Hashable {
    case recv
    case sizeKnown
    case dataRecvd
    case dataRead
    case resetRecvd
    case resetRead
}

// MARK: - Stream

/// State for a single QUIC stream
public struct StreamState: Sendable {
    /// Stream ID
    public let id: UInt64

    /// Send state (for outgoing data)
    public var sendState: SendState

    /// Receive state (for incoming data)
    public var recvState: RecvState

    /// Send offset (next byte to send)
    public var sendOffset: UInt64

    /// Receive offset (next byte expected)
    public var recvOffset: UInt64

    /// Send flow control limit
    public var sendMaxData: UInt64

    /// Receive flow control limit
    public var recvMaxData: UInt64

    /// Whether FIN has been sent
    public var finSent: Bool

    /// Whether FIN has been received
    public var finReceived: Bool

    /// Final size (if known)
    public var finalSize: UInt64?

    /// Creates a new stream state
    public init(
        id: UInt64,
        initialSendMaxData: UInt64,
        initialRecvMaxData: UInt64
    ) {
        self.id = id
        self.sendState = .ready
        self.recvState = .recv
        self.sendOffset = 0
        self.recvOffset = 0
        self.sendMaxData = initialSendMaxData
        self.recvMaxData = initialRecvMaxData
        self.finSent = false
        self.finReceived = false
        self.finalSize = nil
    }

    /// Whether this stream is bidirectional
    public var isBidirectional: Bool {
        StreamID.isBidirectional(id)
    }

    /// Whether this stream is unidirectional
    public var isUnidirectional: Bool {
        StreamID.isUnidirectional(id)
    }

    /// Whether this stream can send data
    public var canSend: Bool {
        switch sendState {
        case .ready, .send:
            return true
        default:
            return false
        }
    }

    /// Whether this stream can receive data
    public var canReceive: Bool {
        switch recvState {
        case .recv, .sizeKnown:
            return true
        default:
            return false
        }
    }

    /// Available send capacity
    public var sendCapacity: UInt64 {
        guard sendMaxData > sendOffset else { return 0 }
        return sendMaxData - sendOffset
    }
}
