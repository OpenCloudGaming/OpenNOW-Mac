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
    /// Origins beyond this machine's own that may open a signaling socket - a tunnel's public
    /// hostname, when one is advertising this server.
    private let additionalAllowedOrigins: [String]
    private(set) var endpoint: OPNRemoteCoOpEmbeddedServerEndpoint?

    private final class Connection {
        let id = UUID()
        let connection: NWConnection
        var buffer = Data()
        var isWebSocket = false
        var participantID: UUID?

        init(connection: NWConnection) { self.connection = connection }
    }

    /// Caps for a listener that runs on the machine playing the game.
    ///
    /// The seat allows three guests, and each holds one socket plus a short-lived one for the page
    /// fetch. This is far above that and still low enough that an unauthenticated peer cannot make
    /// the host hold file descriptors indefinitely.
    static let maximumConnections = 64
    /// A connection that opens TCP and never finishes a request head is dropped. Well beyond any
    /// real handshake, short enough that idle sockets do not accumulate.
    static let handshakeTimeout: Duration = .seconds(15)

    public init(documentRoot: URL,
                networkConfiguration: OPNRemoteCoOpNetworkConfiguration,
                additionalAllowedOrigins: [String] = [],
                logger: (@Sendable (String) -> Void)? = nil) {
        self.documentRoot = documentRoot
        self.networkConfiguration = networkConfiguration
        self.additionalAllowedOrigins = additionalAllowedOrigins.map { $0.lowercased() }
        self.logger = logger
    }

    /// Whether a browser at `origin` may open the signaling socket.
    ///
    /// A WebSocket is not subject to the same-origin policy the way `fetch` is: any page in any tab
    /// can open one to this server, and the browser will send it. The invite token gates anything
    /// meaningful, but this listener runs on the machine playing the game, so an unrelated page
    /// should not get as far as speaking the protocol.
    ///
    /// A missing `Origin` is allowed: non-browser clients omit it entirely, and the guest page is
    /// not the only legitimate client (the test harness and the smoke checks connect directly).
    static func isOriginAllowed(_ origin: String?, port: UInt16, additional: [String]) -> Bool {
        guard let origin, !origin.isEmpty else { return true }
        let normalized = origin.lowercased()
        if additional.contains(normalized) { return true }
        // Every form a browser can produce for this machine's own listener.
        for host in ["localhost", "127.0.0.1", "[::1]"] {
            if normalized == "https://\(host):\(port)" || normalized == "https://\(host)" { return true }
        }
        // A LAN address cannot be enumerated ahead of time - the interface list can change while a
        // session is live - so any private-range host on this listener's port is accepted.
        guard let url = URL(string: normalized),
              url.scheme == "https",
              let host = url.host,
              url.port == Int(port) || url.port == nil else { return false }
        return isPrivateIPv4(host)
    }

    /// RFC 1918 plus link-local, which is every address a guest on the same network can reach this
    /// Mac at. Deliberately not a general "is this a LAN address" helper: a public address here
    /// means something is proxying, and that has to be named explicitly as a tunnel origin.
    static func isPrivateIPv4(_ host: String) -> Bool {
        // Every label has to parse, not just four of them. `compactMap` silently discarded the
        // labels that were not numbers, so `10.0.0.1.evil.com` produced `[10, 0, 0, 1]` and was
        // classified as a LAN address - a registerable domain matching a private-range prefix.
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count == 4 else { return false }
        let parts = labels.compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _): return true
        case (192, 168): return true
        case (172, 16...31): return true
        case (169, 254): return true
        default: return false
        }
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
        // Refused before the connection is tracked, so a flood cannot grow this dictionary. An
        // established guest is never displaced by a newcomer: dropping the new one degrades to
        // "cannot join", while evicting an old one would drop someone mid-game.
        guard connections.count < Self.maximumConnections else {
            logger?("Remote Co-Op refused a connection: \(Self.maximumConnections) already open")
            nwConnection.cancel()
            return
        }
        let connection = Connection(connection: nwConnection)
        let id = connection.id
        connections[id] = connection
        scheduleHandshakeTimeout(for: id)
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

    /// Drops a connection that never completed a WebSocket handshake or a request.
    ///
    /// Static files answer and close well inside the window, so anything still here without having
    /// upgraded is either a stalled client or a socket being held open deliberately.
    private func scheduleHandshakeTimeout(for id: UUID) {
        Task { [weak self] in
            try? await Task.sleep(for: Self.handshakeTimeout)
            await self?.dropIfHandshakeIncomplete(id)
        }
    }

    private func dropIfHandshakeIncomplete(_ id: UUID) {
        guard let connection = connections[id], !connection.isWebSocket else { return }
        logger?("Remote Co-Op dropped a connection that never completed a handshake")
        close(id)
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
                guard Self.isOriginAllowed(request.header("origin"), port: endpoint?.port ?? 0, additional: additionalAllowedOrigins) else {
                    logger?("Remote Co-Op rejected a signaling socket from origin \(request.header("origin") ?? "unknown")")
                    return respond(connection, OPNRemoteCoOpHTTPParser.response(status: 403, reason: "Forbidden"), close: true)
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
            // A participant already held by another live socket is not up for grabs. The binding
            // used to be an unconditional overwrite, so a second socket naming an existing
            // participant took over its routing - every host `peerSignal` for that guest, and on
            // reconnect its already-approved player slot. Only reachable by someone who knew the
            // victim's participant UUID, but nothing in the routing logic required them not to.
            if let existing = guestConnections[participantID], existing != connection.id, connections[existing] != nil {
                logger?("Remote Co-Op refused a socket claiming a participant that is already connected")
                connection.connection.cancel()
                return
            }
            // Bound before anything is routed to it, so a later message naming a different
            // participant cannot be used to read someone else's signaling.
            connection.participantID = participantID
            guestConnections[participantID] = connection.id
            sendWire(connection, OPNRemoteCoOpWireMessage(
                kind: .networkConfiguration,
                roomID: nil,
                participantID: participantID,
                networkConfiguration: networkConfiguration
            ))
        }
        // Only the kinds a guest legitimately originates. This is the boundary between the two
        // directions of the protocol, and it has to be explicit.
        //
        // `networkConfiguration` and `error` used to arrive on the *host's* outbound socket from the
        // trusted Node broker. With the broker gone the only socket left is guest-facing, and
        // `signalingEvent()` still decoded both - so an unauthenticated peer could send a
        // `networkConfiguration` and replace the ICE servers and transport policy of every peer
        // connection the host built afterwards, forcing guest media through a relay of their
        // choosing. Neither kind has any producer in this architecture.
        switch message.kind {
        case .guestJoinRequested, .guestInput, .guestDisconnected, .peerSignal:
            break
        case .hostHello, .inviteEnded, .participantUpdated, .participantRemoved,
             .guestRejected, .inputRejected, .heartbeat, .networkConfiguration, .error:
            return
        }
        guard let event = message.signalingEvent() else { return }
        // A socket that has not joined owns no participant, so it may not act as one. Previously an
        // un-joined socket passed the ownership check by omitting the field, and the only thing
        // standing in its way was not knowing a victim's participant UUID.
        guard let owner = connection.participantID else { return }
        // Everything after the join must come from the socket that owns the participant. Checked on
        // the packet's own identity too, because that is the one the input router keys off.
        if let claimed = message.participantID, claimed != owner { return }
        if let claimed = message.input?.participantID, claimed != owner { return }
        if message.inputs?.contains(where: { $0.participantID != owner }) == true { return }
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
