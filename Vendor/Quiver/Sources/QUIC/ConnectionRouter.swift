/// Connection Router
///
/// Routes incoming packets to the appropriate connection based on
/// Destination Connection ID (DCID).

import Foundation
import Logging
import Synchronization
import QUICCore

// MARK: - Connection Router

/// Routes packets to connections based on DCID
///
/// Maintains a mapping of connection IDs to connections and handles:
/// - Known connection routing (by DCID)
/// - New connection creation (for Initial packets to server)
/// - Connection ID retirement and rotation
public final class ConnectionRouter: Sendable {
    private static let logger = QuiverLogging.logger(label: "quic.connection.router")
    // MARK: - Types

    /// Result of routing a packet
    public enum RouteResult: Sendable {
        /// Packet routed to existing connection
        case routed(ManagedConnection)

        /// New connection should be created (Initial packet to server)
        case newConnection(IncomingConnectionInfo)

        /// Connection not found and cannot create new
        case notFound(ConnectionID)

        /// Invalid packet (cannot extract DCID)
        case invalid(Error)
    }

    /// Information about an incoming connection request
    public struct IncomingConnectionInfo: Sendable {
        /// The destination connection ID from the packet
        public let destinationConnectionID: ConnectionID

        /// The source connection ID from the packet (client's chosen ID)
        public let sourceConnectionID: ConnectionID

        /// The packet type
        public let packetType: PacketType

        /// Remote address
        public let remoteAddress: SocketAddress

        /// The raw packet data
        public let data: Data
    }

    // MARK: - Properties

    /// Connection ID to connection mapping
    private let connections: Mutex<[ConnectionID: ManagedConnection]>

    /// Reverse mapping: Connection to its registered CIDs
    /// This is the single source of truth for which CIDs belong to which connection.
    private let connectionCIDs: Mutex<[ObjectIdentifier: Set<ConnectionID>]>

    /// Whether this is a server (can accept new connections)
    private let isServer: Bool

    /// Packet processor for DCID extraction
    private let packetProcessor: PacketProcessor

    // MARK: - Initialization

    /// Creates a connection router
    /// - Parameters:
    ///   - isServer: Whether this router is for a server endpoint
    ///   - dcidLength: Expected DCID length for short headers
    public init(isServer: Bool, dcidLength: Int = 8) {
        self.connections = Mutex([:])
        self.connectionCIDs = Mutex([:])
        self.isServer = isServer
        self.packetProcessor = PacketProcessor(dcidLength: dcidLength)
    }

    // MARK: - Routing

    /// Routes a packet to the appropriate connection
    /// - Parameters:
    ///   - data: The packet data
    ///   - remoteAddress: Where the packet came from
    /// - Returns: The routing result
    public func route(data: Data, from remoteAddress: SocketAddress) -> RouteResult {
        // Extract header info in a single pass (optimized path)
        let headerInfo: PacketProcessor.HeaderInfo
        do {
            headerInfo = try packetProcessor.extractHeaderInfo(from: data)
        } catch {
            return .invalid(error)
        }

        let dcid = headerInfo.dcid
        let packetType = headerInfo.packetType

        // Look up connection by DCID
        if let connection = connections.withLock({ $0[dcid] }) {
            return .routed(connection)
        }

        // No existing connection found
        Self.logger.debug("Connection not found for DCID: \(dcid)")
        Self.logger.debug("Registered DCIDs: \(connections.withLock { Array($0.keys) })")

        // For servers, Initial packets create new connections
        if isServer && packetType == .initial {
            // Note: length 8 is always valid (0-20), so random() always succeeds
            let scid = headerInfo.scid ?? ConnectionID.random(length: 8) ?? .empty
            return .newConnection(IncomingConnectionInfo(
                destinationConnectionID: dcid,
                sourceConnectionID: scid,
                packetType: packetType,
                remoteAddress: remoteAddress,
                data: data
            ))
        }

        return .notFound(dcid)
    }

    // MARK: - Connection Management

    /// Registers a connection with its connection IDs
    ///
    /// This is the primary method for registering a connection.
    /// The router tracks all CIDs internally via reverse mapping.
    ///
    /// - Parameters:
    ///   - connection: The connection to register
    ///   - connectionIDs: The connection IDs to associate with this connection
    public func register(_ connection: ManagedConnection, for connectionIDs: [ConnectionID]) {
        Self.logger.debug("Registering connection for CIDs: \(connectionIDs)")
        let connID = ObjectIdentifier(connection)
        connections.withLock { conns in
            for cid in connectionIDs {
                conns[cid] = connection
            }
        }
        connectionCIDs.withLock { $0[connID, default: []].formUnion(connectionIDs) }
    }

    /// Registers a connection with its source connection ID
    /// - Parameter connection: The connection to register
    public func register(_ connection: ManagedConnection) {
        let scid = connection.sourceConnectionID
        register(connection, for: [scid])
    }

    /// Unregisters a connection and all its associated CIDs
    ///
    /// Uses the internal reverse mapping to find all CIDs,
    /// ensuring complete cleanup regardless of how many CIDs were registered.
    ///
    /// - Parameter connection: The connection to unregister
    public func unregister(_ connection: ManagedConnection) {
        let connID = ObjectIdentifier(connection)
        let scid = connection.sourceConnectionID
        // Get all CIDs from our tracking (single source of truth)
        let cids = connectionCIDs.withLock { $0.removeValue(forKey: connID) } ?? []
        let remainingCount = connections.withLock { conns -> Int in
            for cid in cids {
                conns.removeValue(forKey: cid)
            }
            return conns.count
        }
        Self.logger.debug("UNREGISTER connection SCID=\(scid) removed CIDs: \(cids) (remaining: \(remainingCount))")
    }

    /// Adds a new connection ID for an existing connection
    /// - Parameters:
    ///   - connectionID: The new connection ID
    ///   - connection: The connection to associate
    public func addConnectionID(_ connectionID: ConnectionID, for connection: ManagedConnection) {
        let connID = ObjectIdentifier(connection)
        connections.withLock { $0[connectionID] = connection }
        _ = connectionCIDs.withLock { $0[connID, default: []].insert(connectionID) }
    }

    /// Retires a connection ID with proper tracking
    /// - Parameters:
    ///   - connectionID: The ID to retire
    ///   - connection: The connection that owns this ID
    public func retireConnectionID(_ connectionID: ConnectionID, for connection: ManagedConnection) {
        let connID = ObjectIdentifier(connection)
        _ = connections.withLock { $0.removeValue(forKey: connectionID) }
        _ = connectionCIDs.withLock { $0[connID]?.remove(connectionID) }
    }

    /// Gets all registered CIDs for a connection
    /// - Parameter connection: The connection
    /// - Returns: Set of connection IDs registered for this connection
    public func registeredConnectionIDs(for connection: ManagedConnection) -> Set<ConnectionID> {
        let connID = ObjectIdentifier(connection)
        return connectionCIDs.withLock { $0[connID] ?? [] }
    }

    /// Gets a connection by its ID
    /// - Parameter connectionID: The connection ID
    /// - Returns: The connection, if found
    public func connection(for connectionID: ConnectionID) -> ManagedConnection? {
        connections.withLock { $0[connectionID] }
    }

    /// Gets all active connections
    public var allConnections: [ManagedConnection] {
        connections.withLock { Array(Set($0.values)) }
    }

    /// Number of registered connection IDs
    public var connectionIDCount: Int {
        connections.withLock { $0.count }
    }

    /// Number of unique connections
    public var connectionCount: Int {
        connections.withLock { Set($0.values).count }
    }

}

// MARK: - Hashable for ManagedConnection

extension ManagedConnection: Hashable {
    public static func == (lhs: ManagedConnection, rhs: ManagedConnection) -> Bool {
        lhs.sourceConnectionID == rhs.sourceConnectionID
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(sourceConnectionID)
    }
}
