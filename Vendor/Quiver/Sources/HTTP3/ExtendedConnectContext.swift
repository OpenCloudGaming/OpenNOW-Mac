/// Extended CONNECT Context (RFC 9220)
///
/// Provides context for handling incoming Extended CONNECT requests,
/// allowing servers to accept or reject WebTransport and other
/// tunneled protocol sessions.

import Foundation
import QUIC
import QUICCore

// MARK: - Extended CONNECT Context

/// Context for an incoming Extended CONNECT request (RFC 9220).
///
/// Wraps an Extended CONNECT request with the underlying QUIC stream,
/// allowing the server to accept (200) or reject the request.
/// When accepted, the CONNECT stream remains open for the session lifetime
/// (e.g., for WebTransport session use).
///
/// ## Usage
///
/// ```swift
/// for await context in connection.incomingExtendedConnect {
///     if context.request.isWebTransportConnect {
///         // Accept the WebTransport session
///         try await context.accept()
///         // The stream is now open for WebTransport session use
///         let sessionStream = context.stream
///     } else {
///         // Reject unknown protocols
///         try await context.reject(status: 501)
///     }
/// }
/// ```
public struct ExtendedConnectContext: Sendable {
    /// The received Extended CONNECT request
    public let request: HTTP3Request

    /// The QUIC stream ID this request arrived on (the CONNECT stream)
    public let streamID: UInt64

    /// The underlying QUIC stream. After acceptance, this stream remains
    /// open and serves as the session's control channel.
    public let stream: any QUICStreamProtocol

    /// The HTTP/3 connection that owns this stream.
    ///
    /// This reference enables higher-level code (e.g. `WebTransportServer`)
    /// to create sessions on the correct connection without a fragile
    /// stream→connection lookup. Because `HTTP3Connection` is an actor,
    /// the reference is `Sendable`-safe.
    public let connection: HTTP3Connection

    /// Internal closure to send headers on the stream
    internal let _sendResponse: @Sendable (consuming HTTP3ResponseHead) async throws -> Void

    /// Creates an Extended CONNECT context.
    ///
    /// - Parameters:
    ///   - request: The Extended CONNECT request
    ///   - streamID: The QUIC stream ID
    ///   - stream: The underlying QUIC stream
    ///   - connection: The HTTP/3 connection that received this request
    ///   - sendResponse: Closure to send a response (without closing the stream)
    public init(
        request: HTTP3Request,
        streamID: UInt64,
        stream: any QUICStreamProtocol,
        connection: HTTP3Connection,
        sendResponse: @escaping @Sendable (HTTP3ResponseHead) async throws -> Void
    ) {
        self.request = request
        self.streamID = streamID
        self.stream = stream
        self.connection = connection
        self._sendResponse = sendResponse
    }

    /// Accepts the Extended CONNECT request by sending a 200 response.
    ///
    /// After acceptance, the CONNECT stream stays open. The caller can
    /// use `stream` for the session lifetime (e.g., WebTransport).
    ///
    /// - Parameter headers: Additional response headers (default: empty)
    /// - Throws: If sending the response fails
    public func accept(headers: [(String, String)] = []) async throws {
        let response = HTTP3ResponseHead(
            status: 200,
            headers: headers
        )
        try await _sendResponse(response)
    }
    /// Rejects the Extended CONNECT request with an error status.
    ///
    /// After rejection, the CONNECT stream is closed.
    ///
    /// - Parameters:
    ///   - status: HTTP status code (e.g., 400, 403, 501)
    ///   - headers: Additional response headers (default: empty)
    ///   - body: Optional response body (default: empty)
    /// - Throws: If sending the response fails
    public func reject(
        status: Int,
        headers: [(String, String)] = []
    ) async throws {
        let response = HTTP3ResponseHead(
            status: status,
            headers: headers
        )
        try await _sendResponse(response)
        try await stream.closeWrite()
    }
}
