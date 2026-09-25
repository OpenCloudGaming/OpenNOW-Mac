/// QLOG Event Types
///
/// Event types for QUIC logging following the QLOG specification:
/// https://datatracker.ietf.org/doc/draft-ietf-quic-qlog-main-schema/
///
/// QLOG provides a standardized format for logging QUIC events,
/// enabling interoperability with analysis tools like qvis.

import Foundation

// MARK: - QLOG Event Protocol

/// Protocol for all QLOG events
public protocol QLOGEvent: Sendable, Encodable {
    /// Event category (connectivity, transport, recovery, security)
    var category: QLOGCategory { get }

    /// Event name (e.g., "packet_sent", "connection_started")
    var name: String { get }

    /// Timestamp in microseconds since connection start
    var time: UInt64 { get }
}

// MARK: - Event Categories

/// QLOG event categories
public enum QLOGCategory: String, Sendable, Encodable {
    /// Connection lifecycle events
    case connectivity

    /// Transport layer events (packets, frames)
    case transport

    /// Loss detection and congestion control events
    case recovery

    /// TLS and key management events
    case security
}

// MARK: - Connectivity Events

/// Connection started event
public struct ConnectionStartedEvent: QLOGEvent, Sendable {
    public let category = QLOGCategory.connectivity
    public let name = "connection_started"
    public let time: UInt64

    /// Connection role ("client" or "server")
    public let role: String

    /// Source connection ID (hex)
    public let srcCID: String

    /// Destination connection ID (hex)
    public let dstCID: String

    /// QUIC version
    public let version: String

    public init(time: UInt64, role: String, srcCID: String, dstCID: String, version: String) {
        self.time = time
        self.role = role
        self.srcCID = srcCID
        self.dstCID = dstCID
        self.version = version
    }
}

/// Connection closed event
public struct ConnectionClosedEvent: QLOGEvent, Sendable {
    public let category = QLOGCategory.connectivity
    public let name = "connection_closed"
    public let time: UInt64

    /// Who initiated the close ("local" or "remote")
    public let owner: String

    /// Error code if any
    public let errorCode: UInt64?

    /// Human-readable reason
    public let reason: String?

    public init(time: UInt64, owner: String, errorCode: UInt64? = nil, reason: String? = nil) {
        self.time = time
        self.owner = owner
        self.errorCode = errorCode
        self.reason = reason
    }
}

/// Connection state updated event
public struct ConnectionStateUpdatedEvent: QLOGEvent, Sendable {
    public let category = QLOGCategory.connectivity
    public let name = "connection_state_updated"
    public let time: UInt64

    /// Old state
    public let oldState: String

    /// New state
    public let newState: String

    public init(time: UInt64, oldState: String, newState: String) {
        self.time = time
        self.oldState = oldState
        self.newState = newState
    }
}

// MARK: - Transport Events

/// Packet header info for QLOG
public struct QLOGPacketHeader: Sendable, Encodable {
    /// Packet type ("initial", "handshake", "0rtt", "1rtt")
    public let packetType: String

    /// Packet number
    public let packetNumber: UInt64

    /// Destination connection ID (hex)
    public let dcid: String

    /// Source connection ID (hex, nil for short header)
    public let scid: String?

    public init(packetType: String, packetNumber: UInt64, dcid: String, scid: String? = nil) {
        self.packetType = packetType
        self.packetNumber = packetNumber
        self.dcid = dcid
        self.scid = scid
    }
}

/// Frame info for QLOG
public struct QLOGFrameInfo: Sendable, Encodable {
    /// Frame type name
    public let frameType: String

    /// Frame payload length (if applicable)
    public let length: Int?

    public init(frameType: String, length: Int? = nil) {
        self.frameType = frameType
        self.length = length
    }
}

/// Packet sent event
public struct PacketSentEvent: QLOGEvent, Sendable {
    public let category = QLOGCategory.transport
    public let name = "packet_sent"
    public let time: UInt64

    /// Packet header information
    public let header: QLOGPacketHeader

    /// Frames in the packet
    public let frames: [QLOGFrameInfo]

    /// Raw packet length in bytes
    public let rawLength: Int

    /// Whether this packet is coalesced with others
    public let isCoalesced: Bool

    public init(time: UInt64, header: QLOGPacketHeader, frames: [QLOGFrameInfo], rawLength: Int, isCoalesced: Bool = false) {
        self.time = time
        self.header = header
        self.frames = frames
        self.rawLength = rawLength
        self.isCoalesced = isCoalesced
    }
}

/// Packet received event
public struct PacketReceivedEvent: QLOGEvent, Sendable {
    public let category = QLOGCategory.transport
    public let name = "packet_received"
    public let time: UInt64

    /// Packet header information
    public let header: QLOGPacketHeader

    /// Frames in the packet
    public let frames: [QLOGFrameInfo]

    /// Raw packet length in bytes
    public let rawLength: Int

    /// Trigger type ("ack_eliciting" or "non_ack_eliciting")
    public let triggerType: String?

    public init(time: UInt64, header: QLOGPacketHeader, frames: [QLOGFrameInfo], rawLength: Int, triggerType: String? = nil) {
        self.time = time
        self.header = header
        self.frames = frames
        self.rawLength = rawLength
        self.triggerType = triggerType
    }
}

/// Packet dropped event
public struct PacketDroppedEvent: QLOGEvent, Sendable {
    public let category = QLOGCategory.transport
    public let name = "packet_dropped"
    public let time: UInt64

    /// Packet type if known
    public let packetType: String?

    /// Raw packet length
    public let rawLength: Int

    /// Reason for dropping
    public let reason: String

    public init(time: UInt64, packetType: String? = nil, rawLength: Int, reason: String) {
        self.time = time
        self.packetType = packetType
        self.rawLength = rawLength
        self.reason = reason
    }
}

// MARK: - Recovery Events

/// Recovery metrics updated event
public struct RecoveryMetricsUpdatedEvent: QLOGEvent, Sendable {
    public let category = QLOGCategory.recovery
    public let name = "metrics_updated"
    public let time: UInt64

    /// Minimum RTT in microseconds
    public let minRTT: UInt64?

    /// Smoothed RTT in microseconds
    public let smoothedRTT: UInt64?

    /// Latest RTT sample in microseconds
    public let latestRTT: UInt64?

    /// RTT variance in microseconds
    public let rttVariance: UInt64?

    /// Congestion window in bytes
    public let congestionWindow: UInt64?

    /// Bytes currently in flight
    public let bytesInFlight: UInt64?

    /// Packets currently in flight
    public let packetsInFlight: UInt64?

    public init(
        time: UInt64,
        minRTT: UInt64? = nil,
        smoothedRTT: UInt64? = nil,
        latestRTT: UInt64? = nil,
        rttVariance: UInt64? = nil,
        congestionWindow: UInt64? = nil,
        bytesInFlight: UInt64? = nil,
        packetsInFlight: UInt64? = nil
    ) {
        self.time = time
        self.minRTT = minRTT
        self.smoothedRTT = smoothedRTT
        self.latestRTT = latestRTT
        self.rttVariance = rttVariance
        self.congestionWindow = congestionWindow
        self.bytesInFlight = bytesInFlight
        self.packetsInFlight = packetsInFlight
    }
}

/// Lost packet info
public struct QLOGLostPacketInfo: Sendable, Encodable {
    /// Packet number
    public let packetNumber: UInt64

    /// Packet type
    public let packetType: String

    public init(packetNumber: UInt64, packetType: String) {
        self.packetNumber = packetNumber
        self.packetType = packetType
    }
}

/// Packets lost event
public struct PacketsLostEvent: QLOGEvent, Sendable {
    public let category = QLOGCategory.recovery
    public let name = "packets_lost"
    public let time: UInt64

    /// List of lost packets
    public let lostPackets: [QLOGLostPacketInfo]

    public init(time: UInt64, lostPackets: [QLOGLostPacketInfo]) {
        self.time = time
        self.lostPackets = lostPackets
    }
}

/// Congestion state updated event
public struct CongestionStateUpdatedEvent: QLOGEvent, Sendable {
    public let category = QLOGCategory.recovery
    public let name = "congestion_state_updated"
    public let time: UInt64

    /// Old state
    public let oldState: String

    /// New state
    public let newState: String

    public init(time: UInt64, oldState: String, newState: String) {
        self.time = time
        self.oldState = oldState
        self.newState = newState
    }
}

// MARK: - Security Events

/// Key updated event
public struct KeyUpdatedEvent: QLOGEvent, Sendable {
    public let category = QLOGCategory.security
    public let name = "key_updated"
    public let time: UInt64

    /// Key type (e.g., "client_initial", "server_handshake", "client_1rtt")
    public let keyType: String

    /// Key generation/phase
    public let generation: UInt64?

    public init(time: UInt64, keyType: String, generation: UInt64? = nil) {
        self.time = time
        self.keyType = keyType
        self.generation = generation
    }
}

/// Key discarded event
public struct KeyDiscardedEvent: QLOGEvent, Sendable {
    public let category = QLOGCategory.security
    public let name = "key_discarded"
    public let time: UInt64

    /// Key type being discarded
    public let keyType: String

    public init(time: UInt64, keyType: String) {
        self.time = time
        self.keyType = keyType
    }
}
