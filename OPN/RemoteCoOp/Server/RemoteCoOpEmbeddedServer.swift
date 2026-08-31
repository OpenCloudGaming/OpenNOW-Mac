//
//  RemoteCoOpEmbeddedServer.swift
//  OpenNOW
//
//  Remote Co-Op hosted by OpenNOW itself: no Node broker, no deployed host, no shared secret.
//
//  The Node broker in `RemoteCoOp/` exists because a rendezvous both sides dial *out* to works from
//  behind any NAT. This server trades that for having no infrastructure at all: the guest connects
//  *in* to the host, which is unconditional on a LAN and needs a forwarded port across the
//  internet. Both remain supported; this is the one that needs no setup.
//
//  Hosting locally also removes a whole class of failure. When the app is the broker it both signs
//  and verifies invites, so there is no secret to distribute and none to mismatch - the failure
//  that made every join to a foreign broker fail with "Invalid or expired invite token".
//
//  One port serves both the page and the socket, deliberately: same origin is what lets a guest
//  accept the self-signed certificate once on a top-level navigation and have it cover the
//  WebSocket. See `RemoteCoOpTLSIdentity`.
//

import Foundation
import Network

public struct OPNRemoteCoOpEmbeddedServerEndpoint: Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public let certificateFingerprint: String?

    public var guestJoinBaseURL: String { "https://\(host):\(port)/" }
    public var signalingServerURL: String { "wss://\(host):\(port)/remote-coop" }
}

public enum OPNRemoteCoOpEmbeddedServerError: LocalizedError {
    case listenerFailed(String)

    public var errorDescription: String? {
        switch self {
        case .listenerFailed(let message): return "Remote Co-Op could not start its local server: \(message)"
        }
    }
}

/// The guest-facing half of a locally hosted session.
///
/// Owns the listener and every guest socket. It speaks the same JSON wire protocol as the Node
/// broker, so `Resources/RemoteCoOp/browser` runs unchanged against either.
public actor OPNRemoteCoOpEmbeddedServer {
    private let documentRoot: URL
    private let logger: (@Sendable (String) -> Void)?
    private var listener: NWListener?
    private var connections: [UUID: Connection] = [:]
    /// Guest participant ID to the socket carrying it. A socket appears here only once it has sent
    /// a join naming itself, so an unidentified connection can never be sent another guest's
    /// signaling.
    private var guestConnections: [UUID: UUID] = [:]
    private var eventContinuation: AsyncStream<OPNRemoteCoOpSignalingEvent>.Continuation?
    private var networkConfiguration: OPNRemoteCoOpNetworkConfiguration
    private var inviteToken: String?
    private(set) var endpoint: OPNRemoteCoOpEmbeddedServerEndpoint?

    private final class Connection {
        let id = UUID()
        let connection: NWConnection
        var buffer = Data()
        var isWebSocket = false
        var participantID: UUID?

        init(connection: NWConnection) { self.connection = connection }
    }

    public init(documentRoot: URL,
                networkConfiguration: OPNRemoteCoOpNetworkConfiguration,
                logger: (@Sendable (String) -> Void)? = nil) {
        self.documentRoot = documentRoot
        self.networkConfiguration = networkConfiguration
        self.logger = logger
    }

    /// The guest page shipped inside the app bundle. Serving the same files the Node broker serves
    /// means the page cannot drift from the protocol the host speaks.
    public static func bundledDocumentRoot() -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let candidates = [
            resources.appendingPathComponent("Resources/RemoteCoOp/browser"),
            resources.appendingPathComponent("RemoteCoOp/browser")
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path) }
    }

    public func events() -> AsyncStream<OPNRemoteCoOpSignalingEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(240)) { continuation in
            eventContinuation = continuation
        }
    }

    public func updateNetworkConfiguration(_ configuration: OPNRemoteCoOpNetworkConfiguration) {
        networkConfiguration = configuration
    }

    public func setInviteToken(_ token: String?) {
        inviteToken = token
    }

    /// Binds the listener and returns the address a guest should be sent to.
    ///
    /// `advertisedHost` is what goes in the invite link and in the certificate. It is not
    /// necessarily what the listener binds - the listener always takes every interface, because a
    /// guest on the LAN and a guest on the same machine arrive on different ones.
    public func start(port: UInt16, advertisedHost: String, identity: SecIdentity) throws -> OPNRemoteCoOpEmbeddedServerEndpoint {
        stop()
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, sec_identity_create(identity)!)
        let parameters = NWParameters(tls: options, tcp: NWProtocolTCP.Options())
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw OPNRemoteCoOpEmbeddedServerError.listenerFailed("port \(port) is not valid")
        }
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: nwPort)
        } catch {
            throw OPNRemoteCoOpEmbeddedServerError.listenerFailed(error.localizedDescription)
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard case .failed(let error) = state else { return }
            Task { await self?.handleListenerFailure(error) }
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener

        let endpoint = OPNRemoteCoOpEmbeddedServerEndpoint(
            host: advertisedHost,
            port: port,
            certificateFingerprint: OPNRemoteCoOpTLSIdentity.fingerprint(for: identity)
        )
        self.endpoint = endpoint
        logger?("Remote Co-Op local server listening on \(endpoint.guestJoinBaseURL)")
        return endpoint
    }

    public func stop() {
        for connection in connections.values { connection.connection.cancel() }
        connections.removeAll()
        guestConnections.removeAll()
        listener?.cancel()
        listener = nil
        endpoint = nil
    }

    /// Sends a host-side command to the guest it names. Mirrors the broker's relay, minus the room
    /// bookkeeping: there is exactly one room, and this process owns it.
    public func send(_ command: OPNRemoteCoOpSignalingCommand) {
        switch command {
        case .inviteCreated(let invite):
            inviteToken = invite.token
        case .inviteEnded:
            broadcast(OPNRemoteCoOpWireMessage(kind: .inviteEnded, roomID: nil, reason: "Host ended the invite."))
            inviteToken = nil
            for connection in connections.values where connection.isWebSocket { connection.connection.cancel() }
        case .participantUpdated(let participant):
            sendToGuest(participant.id, OPNRemoteCoOpWireMessage.message(for: command, roomID: nil))
        case .participantRemoved(let participantID):
            sendToGuest(participantID, OPNRemoteCoOpWireMessage.message(for: command, roomID: nil))
        case .guestRejected(let participantID, _), .inputRejected(let participantID, _), .peerSignal(let participantID, _):
            sendToGuest(participantID, OPNRemoteCoOpWireMessage.message(for: command, roomID: nil))
        }
    }

    // MARK: - Connections

    private func handleListenerFailure(_ error: NWError) {
        logger?("Remote Co-Op local server failed: \(error.localizedDescription)")
        stop()
    }

    private func accept(_ nwConnection: NWConnection) {
        let connection = Connection(connection: nwConnection)
        let id = connection.id
        connections[id] = connection
        // Only the id crosses into the handler. `Connection` owns the read buffer and is actor
        // state; capturing it would hand mutable state to Network.framework's callback queue.
        nwConnection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { await self?.close(id) }
            default:
                break
            }
        }
        nwConnection.start(queue: .global(qos: .userInitiated))
        receive(id)
    }

    private func receive(_ id: UUID) {
        guard let connection = connections[id] else { return }
        connection.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task {
                if let data, !data.isEmpty { await self?.ingest(id, data: data) }
                if isComplete || error != nil {
                    await self?.close(id)
                } else {
                    await self?.receive(id)
                }
            }
        }
    }

    private func ingest(_ id: UUID, data: Data) {
        guard let connection = connections[id] else { return }
        connection.buffer.append(data)
        if connection.isWebSocket {
            drainWebSocketFrames(connection)
        } else {
            handleHTTP(connection)
        }
    }

    private func handleHTTP(_ connection: Connection) {
        do {
            guard let request = try OPNRemoteCoOpHTTPParser.parseRequest(from: &connection.buffer) else { return }
            if request.isWebSocketUpgrade {
                guard request.normalizedPath == "/remote-coop", let key = request.header("sec-websocket-key") else {
                    return respond(connection, OPNRemoteCoOpHTTPParser.response(status: 404, reason: "Not Found"), close: true)
                }
                connection.isWebSocket = true
                send(connection, OPNRemoteCoOpHTTPParser.webSocketAcceptResponse(key: key))
                // A browser can pipeline frames immediately after the handshake, and those bytes are
                // already sitting in the buffer.
                drainWebSocketFrames(connection)
                return
            }
            guard request.method == "GET" else {
                return respond(connection, OPNRemoteCoOpHTTPParser.response(status: 405, reason: "Method Not Allowed"), close: true)
            }
            let store = OPNRemoteCoOpStaticFileStore(documentRoot: documentRoot)
            guard let file = store.file(for: request.normalizedPath) else {
                return respond(connection, OPNRemoteCoOpHTTPParser.response(status: 404, reason: "Not Found"), close: true)
            }
            respond(connection, OPNRemoteCoOpHTTPParser.response(status: 200, reason: "OK", contentType: file.contentType, body: file.data), close: true)
        } catch {
            respond(connection, OPNRemoteCoOpHTTPParser.response(status: 400, reason: "Bad Request"), close: true)
        }
    }

    private func drainWebSocketFrames(_ connection: Connection) {
        let frames: [OPNRemoteCoOpWebSocketFrame]
        do {
            frames = try OPNRemoteCoOpWebSocketCodec.decodeFrames(from: &connection.buffer)
        } catch {
            logger?("Remote Co-Op local server dropped a guest socket: \(error.localizedDescription)")
            connection.connection.cancel()
            return
        }
        for frame in frames {
            switch frame.opcode {
            case .text, .binary:
                handleGuestMessage(connection, payload: frame.payload)
            case .ping:
                send(connection, OPNRemoteCoOpWebSocketCodec.encodeFrame(opcode: .pong, payload: frame.payload))
            case .close:
                connection.connection.cancel()
            case .pong, .continuation:
                break
            }
        }
    }

    private func handleGuestMessage(_ connection: Connection, payload: Data) {
        guard let message = try? OPNRemoteCoOpWireCodec.decode(payload) else { return }
        if message.kind == .heartbeat {
            send(connection, OPNRemoteCoOpWebSocketCodec.encodeText((try? OPNRemoteCoOpWireCodec.encode(OPNRemoteCoOpWireMessage(kind: .heartbeat, roomID: message.roomID))) ?? ""))
            return
        }
        if message.kind == .guestJoinRequested, let participantID = message.participantID {
            // Binds this socket to the participant before anything is routed to it, so a later
            // message naming a different participant cannot be used to read someone else's
            // signaling.
            connection.participantID = participantID
            guestConnections[participantID] = connection.id
            sendWire(connection, OPNRemoteCoOpWireMessage(
                kind: .networkConfiguration,
                roomID: nil,
                participantID: participantID,
                networkConfiguration: networkConfiguration
            ))
        }
        guard let event = message.signalingEvent() else { return }
        // Everything after the join must come from the socket that owns the participant. Without
        // this a second guest could send input or peer signals as the first.
        if let claimed = message.participantID, let owner = connection.participantID, claimed != owner { return }
        eventContinuation?.yield(event)
    }

    private func close(_ id: UUID) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.connection.cancel()
        guard let participantID = connection.participantID else { return }
        guestConnections[participantID] = nil
        eventContinuation?.yield(.guestDisconnected(participantID))
    }

    // MARK: - Sending

    private func sendToGuest(_ participantID: UUID, _ message: OPNRemoteCoOpWireMessage?) {
        guard let message,
              let connectionID = guestConnections[participantID],
              let connection = connections[connectionID] else { return }
        sendWire(connection, message)
    }

    private func broadcast(_ message: OPNRemoteCoOpWireMessage) {
        for connection in connections.values where connection.isWebSocket {
            sendWire(connection, message)
        }
    }

    private func sendWire(_ connection: Connection, _ message: OPNRemoteCoOpWireMessage) {
        guard let text = try? OPNRemoteCoOpWireCodec.encode(message) else { return }
        send(connection, OPNRemoteCoOpWebSocketCodec.encodeText(text))
    }

    private func respond(_ connection: Connection, _ data: Data, close: Bool) {
        // Only the `NWConnection` crosses into the completion handler. The `Connection` wrapper
        // holds the read buffer and is actor state; letting it escape would hand a mutable buffer
        // to whatever queue Network.framework calls back on.
        let socket = connection.connection
        socket.send(content: data, completion: .contentProcessed { _ in
            if close { socket.cancel() }
        })
    }

    private func send(_ connection: Connection, _ data: Data) {
        connection.connection.send(content: data, completion: .idempotent)
    }
}
