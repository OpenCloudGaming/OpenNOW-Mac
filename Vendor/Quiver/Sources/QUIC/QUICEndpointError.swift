/// QUIC Endpoint Errors
///
/// Error types produced by `QUICEndpoint` operations.

import QUICCore

// MARK: - Errors

/// Errors from QUICEndpoint
public enum QUICEndpointError: Error, Sendable {
    /// Server endpoint cannot initiate connections
    case serverCannotConnect

    /// Connection not found for the given DCID
    case connectionNotFound(ConnectionID)

    /// Unexpected packet received
    case unexpectedPacket

    /// Endpoint is already running
    case alreadyRunning

    /// Endpoint is not running
    case notRunning

    /// Handshake timed out
    case handshakeTimeout
}