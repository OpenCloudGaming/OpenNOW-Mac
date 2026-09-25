/// HTTP3Connection — WebTransport Session Management
///
/// Extension containing WebTransport-related functionality:
/// - Session registration/unregistration
/// - Session creation (server and client)
/// - Stream ownership checks
/// - Unidirectional stream routing
/// - Datagram routing

import Foundation
import QUIC
import QUICCore

// MARK: - WebTransport Session Management

extension HTTP3Connection {

    /// Registers a WebTransport session in the connection's session registry.
    ///
    /// Once registered, incoming bidirectional and unidirectional streams
    /// with a matching session ID will be routed to the session automatically.
    /// Datagrams with a matching quarter stream ID will also be routed.
    ///
    /// - Parameter session: The WebTransport session to register
    public func registerWebTransportSession(_ session: WebTransportSession) {
        let sessionID = session.sessionID
        webTransportSessions[sessionID] = session

        Self.logger.info(
            "Registered WebTransport session",
            metadata: [
                "sessionID": "\(sessionID)",
                "activeSessions": "\(webTransportSessions.count)",
            ]
        )

        // Start datagram routing if this is the first session and settings support it
        if webTransportSessions.count == 1 && datagramRoutingTask == nil {
            startDatagramRouting()
        }

        // Deliver to the incoming sessions stream
        incomingWebTransportSessionContinuation?.yield(session)
    }

    /// Attempts to register a WebTransport session, enforcing the per-connection
    /// session quota from `localSettings.webtransportMaxSessions`.
    ///
    /// Unlike `registerWebTransportSession`, this method checks the quota
    /// before registering and returns `false` if the limit is reached.
    ///
    /// - Parameter session: The session to register
    /// - Returns: `true` if registered successfully, `false` if quota exceeded
    @discardableResult
    public func tryRegisterWebTransportSession(_ session: WebTransportSession) -> Bool {
        let maxSessions = localSettings.webtransportMaxSessions ?? 0
        if maxSessions > 0 && webTransportSessions.count >= Int(maxSessions) {
            Self.logger.warning(
                "WebTransport session quota exceeded",
                metadata: [
                    "sessionID": "\(session.sessionID)",
                    "activeSessions": "\(webTransportSessions.count)",
                    "limit": "\(maxSessions)",
                ]
            )
            return false
        }

        registerWebTransportSession(session)
        return true
    }

    /// Unregisters a WebTransport session from the connection's session registry.
    ///
    /// After unregistration, streams and datagrams for this session ID
    /// will no longer be routed to it. The session should already be
    /// closed or closing when this is called.
    ///
    /// - Parameter sessionID: The session ID to unregister
    @discardableResult
    public func unregisterWebTransportSession(_ sessionID: UInt64) -> WebTransportSession? {
        let session = webTransportSessions.removeValue(forKey: sessionID)

        if session != nil {
            Self.logger.info(
                "Unregistered WebTransport session",
                metadata: [
                    "sessionID": "\(sessionID)",
                    "activeSessions": "\(webTransportSessions.count)",
                ]
            )
        }

        // Stop datagram routing if no more sessions
        if webTransportSessions.isEmpty {
            datagramRoutingTask?.cancel()
            datagramRoutingTask = nil
        }

        return session
    }

    /// Returns the WebTransport session for the given session ID, if any.
    ///
    /// - Parameter sessionID: The session ID to look up
    /// - Returns: The session, or `nil` if no session is registered with that ID
    public func webTransportSession(for sessionID: UInt64) -> WebTransportSession? {
        webTransportSessions[sessionID]
    }

    /// The number of active WebTransport sessions on this connection.
    public var activeWebTransportSessionCount: Int {
        webTransportSessions.count
    }

    // MARK: - Session Creation

    /// Creates a new WebTransport session from a server-side accepted
    /// Extended CONNECT context.
    ///
    /// This convenience method:
    /// 1. Creates a `WebTransportSession` from the accepted context
    /// 2. Registers it in the session registry
    /// 3. Starts the session (transitions to `.established`)
    ///
    /// - Parameters:
    ///   - context: The accepted Extended CONNECT context
    ///   - role: The role of this endpoint (default: `.server`)
    /// - Returns: The started `WebTransportSession`
    /// - Throws: `WebTransportError` if the session cannot be created or started
    public func createWebTransportSession(
        from context: ExtendedConnectContext,
        role: WebTransportSession.Role = .server
    ) async throws -> WebTransportSession {
        let session = WebTransportSession(
            connectStream: context.stream,
            connection: self,
            role: role
        )

        // Enforce per-connection session quota
        guard tryRegisterWebTransportSession(session) else {
            throw WebTransportError.maxSessionsExceeded(
                limit: localSettings.webtransportMaxSessions ?? 0
            )
        }

        try await session.start()

        return session
    }

    /// Creates a new client-side WebTransport session after a successful
    /// Extended CONNECT.
    ///
    /// - Parameters:
    ///   - connectStream: The QUIC stream from the Extended CONNECT
    ///   - response: The HTTP/3 response (should be 200)
    /// - Returns: The started `WebTransportSession`
    /// - Throws: `WebTransportError` if the response is not 200 or setup fails
    public func createClientWebTransportSession(
        connectStream: any QUICStreamProtocol,
        response: borrowing HTTP3ResponseHead
    ) async throws -> WebTransportSession {
        guard response.isSuccess else {
            throw WebTransportError.sessionRejected(
                status: response.status,
                reason: response.statusText
            )
        }

        let session = WebTransportSession(
            connectStream: connectStream,
            connection: self,
            role: .client
        )

        // Enforce per-connection session quota (client side)
        guard tryRegisterWebTransportSession(session) else {
            throw WebTransportError.maxSessionsExceeded(
                limit: localSettings.webtransportMaxSessions ?? 0
            )
        }

        try await session.start()

        return session
    }

    // MARK: - Stream Ownership

    /// Finds the HTTP3Connection that owns a given QUIC stream ID.
    ///
    /// This is a convenience method for the `serve()` codepath where
    /// the WebTransportServer needs to find the correct HTTP3Connection
    /// for a given stream (e.g., from the Extended CONNECT handler).
    ///
    /// Since `ExtendedConnectContext` already carries a `connection` reference,
    /// this method is primarily useful for external lookup scenarios.
    ///
    /// - Parameter streamID: The QUIC stream ID to look up
    /// - Returns: `true` if this connection owns the stream
    public func ownsStream(_ streamID: UInt64) -> Bool {
        // Check if the stream matches our QUIC connection's stream ID space.
        // Client-initiated bidi streams are even (0, 4, 8, ...),
        // Server-initiated bidi streams are 1, 5, 9, ...
        // The connection owns any stream routed through it.
        webTransportSessions.keys.contains(streamID) ||
        localControlStream?.id == streamID
    }

    // MARK: - WebTransport Stream Routing

    /// Routes an incoming WebTransport unidirectional stream to the
    /// appropriate session.
    ///
    /// The stream type (0x54) has already been consumed. This method
    /// reads the session ID varint and delivers the stream to the
    /// matching session.
    func routeWebTransportUniStream(
        _ stream: any QUICStreamProtocol,
        initialData: Data
    ) async {
        // We need the session ID varint from the initial data.
        // If the initial data is empty, read more from the stream.
        var data = initialData
        if data.isEmpty {
            do {
                let moreData = try await stream.read()
                guard !moreData.isEmpty else {
                    Self.logger.warning("WebTransport uni stream \(stream.id): empty after stream type")
                    return
                }
                data = moreData
            } catch {
                Self.logger.warning("WebTransport uni stream \(stream.id): read error: \(error)")
                return
            }
        }

        do {
            guard let (sessionID, remaining) = try WebTransportStreamFraming.readUnidirectionalSessionID(from: data) else {
                Self.logger.warning("WebTransport uni stream \(stream.id): insufficient data for session ID")
                await stream.reset(errorCode: WebTransportStreamErrorCode.toHTTP3ErrorCode(0))
                return
            }

            guard let session = webTransportSessions[sessionID] else {
                Self.logger.warning("WebTransport uni stream \(stream.id): unknown session ID \(sessionID)")
                await stream.reset(errorCode: WebTransportStreamErrorCode.toHTTP3ErrorCode(0))
                return
            }

            await session.deliverIncomingUnidirectionalStream(stream, initialData: remaining)

        } catch {
            Self.logger.warning("WebTransport uni stream \(stream.id): session ID decode error: \(error)")
            await stream.reset(errorCode: WebTransportStreamErrorCode.toHTTP3ErrorCode(0))
        }
    }

    // MARK: - WebTransport Datagram Routing

    /// Starts the background task that routes incoming QUIC DATAGRAMs
    /// to WebTransport sessions based on the quarter stream ID prefix.
    func startDatagramRouting() {
        guard datagramRoutingTask == nil else { return }

        let connection = self.quicConnection
        datagramRoutingTask = Task { [weak self] in
            for await datagramPayload in connection.incomingDatagrams {
                guard let self = self else { break }

                do {
                    guard let (quarterStreamID, appPayload) = try WebTransportSession.parseDatagram(datagramPayload) else {
                        continue
                    }

                    // Convert quarter stream ID back to session ID
                    let sessionID = quarterStreamID * 4

                    if let session = await self.webTransportSession(for: sessionID) {
                        await session.deliverDatagram(appPayload)
                    } else {
                        Self.logger.trace(
                            "Datagram for unknown session",
                            metadata: [
                                "quarterStreamID": "\(quarterStreamID)",
                                "sessionID": "\(sessionID)",
                            ]
                        )
                    }
                } catch {
                    Self.logger.trace("Datagram parse error: \(error)")
                }
            }
        }
    }
}
