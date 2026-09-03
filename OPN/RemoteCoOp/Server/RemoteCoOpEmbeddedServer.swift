//  Remote Co-Op hosted by OpenNOW itself: no deployed server, no shared secret.
//
//  A Node broker in `RemoteCoOp/` used to be the alternative, because a rendezvous both sides dial
//  *out* to works from behind any NAT. It is gone. This server trades that reach for having no
//  infrastructure at all: the guest connects *in* to the host, which is unconditional on a LAN and
//  needs a tunnel across the internet. `RemoteCoOpHostedSignalingSession` is what covers the case a
//  tunnel cannot.
//
//  Hosting locally also removes a whole class of failure: the app both signs and verifies invites,
//  so there is no secret to distribute and none to mismatch - the failure that made every join to a
//  foreign broker fail with "Invalid or expired invite token".
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

/// One-shot resume for a handler that fires repeatedly.
///
/// `NWListener`'s state handler can report `.ready` and later `.failed`, and `stop()` can cancel the
/// listener while `start` is still awaiting; resuming a continuation twice traps.
private final class OPNRemoteCoOpListenerReadiness: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?
    private var resolvedPort: UInt16?
    private var failure: Error?
    private var isFinished = false

    func arm(_ continuation: CheckedContinuation<UInt16, Error>) {
        lock.lock()
        // A listener that became ready before `arm` ran must not be lost.
        if isFinished {
            let port = resolvedPort
            let error = failure
            lock.unlock()
            if let port {
                continuation.resume(returning: port)
            } else {
                continuation.resume(throwing: error ?? OPNRemoteCoOpEmbeddedServerError.listenerFailed("the listener did not start"))
            }
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func succeed(port: UInt16) {
        lock.lock()
        if isFinished {
            lock.unlock()
            return
        }
        isFinished = true
        resolvedPort = port
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: port)
    }

    func fail(_ message: String) {
        lock.lock()
        if isFinished {
            lock.unlock()
            return
        }
        isFinished = true
        let error = OPNRemoteCoOpEmbeddedServerError.listenerFailed(message)
        failure = error
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(throwing: error)
    }
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
/// One accepted socket. At file scope rather than nested in the actor: it carries no actor state,
/// and nesting it only counted its lines against the actor's size budget.
private final class Connection {
    let id = UUID()
    let connection: NWConnection
    var buffer = Data()
    var isWebSocket = false
    var participantID: UUID?
    /// A message split across frames. `isFinal` was decoded and ignored, so the first fragment was
    /// handled as a whole message - truncated JSON the decoder rejects - and the rest were dropped.
    /// SDP offers are the largest guest-originated payload and the plausible trigger.
    var fragmentOpcode: OPNRemoteCoOpWebSocketOpcode?
    var fragmentPayload = Data()
    var lastActivityAt = Date()

    init(connection: NWConnection) { self.connection = connection }
}

public actor OPNRemoteCoOpEmbeddedServer {
    private let documentRoot: URL
    private let logger: (@Sendable (String) -> Void)?
    private var listener: NWListener?
    private var heartbeatTask: Task<Void, Never>?
    private var connections: [UUID: Connection] = [:]
    /// Guest participant ID to the socket carrying it. A socket appears here only once it has sent
    /// a join naming itself, so an unidentified connection can never be sent another guest's
    /// signaling.
    private var guestConnections: [UUID: UUID] = [:]
    /// Participants whose invite has verified and who have therefore been given the ICE
    /// configuration, so a reconnect earns it again but a routine update does not resend it.
    private var participantsGivenNetworkConfiguration: Set<UUID> = []
    /// Keyed rather than single-slot: a second `events()` call used to orphan the first stream, whose
    /// consumer then waited forever.
    private var eventContinuations: [UUID: AsyncStream<OPNRemoteCoOpSignalingEvent>.Continuation] = [:]
    private var networkConfiguration: OPNRemoteCoOpNetworkConfiguration
    /// Origins beyond this machine's own that may open a signaling socket - a tunnel's public
    /// hostname, when one is advertising this server.
    private let additionalAllowedOrigins: [String]
    private(set) var endpoint: OPNRemoteCoOpEmbeddedServerEndpoint?

    /// Caps for a listener that runs on the machine playing the game.
    ///
    /// The seat allows three guests, and each holds one socket plus a short-lived one for the page
    /// fetch. This is far above that and still low enough that an unauthenticated peer cannot make
    /// the host hold file descriptors indefinitely.
    static let maximumConnections = 64
    /// A connection that opens TCP and never finishes a request head is dropped. Well beyond any
    /// real handshake, short enough that idle sockets do not accumulate.
    static let handshakeTimeout: Duration = .seconds(15)
    /// How often every live socket is asked to prove it is still there.
    ///
    /// Once a socket upgrades, the handshake timeout stops applying to it and gameplay input rides
    /// the data channel, so a guest whose machine sleeps or drops off Wi-Fi without a FIN leaves an
    /// `NWConnection` that never reports anything. Its slot, its announced pad and its share of
    /// `maximumConnections` were all held until the host tore the session down by hand.
    static let heartbeatInterval: Duration = .seconds(15)
    /// How long a socket may go without a byte from the peer. Several heartbeats wide, so a stalled
    /// network is not mistaken for a departed guest.
    static let socketIdleTimeout: TimeInterval = 60

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

    /// RFC 1918, link-local, and the 100.64.0.0/10 CGNAT block a tailnet addresses hosts from -
    /// every address a guest on the same network or the same VPN can reach this Mac at. Deliberately
    /// not a general "is this a LAN address" helper: a routable public address here means something
    /// is proxying, and that has to be named explicitly as a tunnel origin.
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
        // Tailscale, which is the documented way to reach a host across networks. Without it a
        // browser guest on the tailnet loaded the page and was then 403'd on the upgrade.
        case (100, 64...127): return true
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
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(240)) { continuation in
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventContinuation(id) }
            }
        }
    }

    private func removeEventContinuation(_ id: UUID) {
        eventContinuations[id] = nil
    }

    public func updateNetworkConfiguration(_ configuration: OPNRemoteCoOpNetworkConfiguration) {
        networkConfiguration = configuration
    }

    /// Binds the listener and returns the address a guest should be sent to.
    ///
    /// `advertisedHost` is what goes in the invite link and in the certificate. It is not
    /// necessarily what the listener binds - the listener always takes every interface, because a
    /// guest on the LAN and a guest on the same machine arrive on different ones.
    /// Returns once the listener is actually accepting, or throws.
    ///
    /// `NWListener.start` is asynchronous: it returns immediately and the listener reaches `.ready` or
    /// `.failed` later. Returning the endpoint straight after calling it therefore reported success
    /// for a listener that might never come up - a port already in use logged "listening" and handed
    /// out an invite nobody could connect to, and made the server tests fail roughly one run in three
    /// when two of them picked the same random port.
    ///
    /// Passing port 0 asks the system for a free one; the endpoint carries whichever port it assigned.
    public func start(port: UInt16, advertisedHost: String, identity: SecIdentity) async throws -> OPNRemoteCoOpEmbeddedServerEndpoint {
        stop()
        let options = NWProtocolTLS.Options()
        // `sec_identity_create` returns nil for an identity whose private key is not usable, which a
        // truncated PKCS#12 on disk produces; force-unwrapping it crashed the app mid-stream.
        guard let secIdentity = sec_identity_create(identity) else {
            throw OPNRemoteCoOpEmbeddedServerError.listenerFailed("the Remote Co-Op certificate has no usable private key")
        }
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, secIdentity)
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

        let readiness = OPNRemoteCoOpListenerReadiness()
        let resolvedPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            readiness.arm(continuation)
            // The state handler fires more than once, and `stop()` can cancel the listener while this
            // is still waiting, so the resume is one-shot.
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    readiness.succeed(port: listener.port?.rawValue ?? port)
                case .failed(let error):
                    readiness.fail(error.localizedDescription)
                case .cancelled:
                    readiness.fail("the listener was cancelled before it was ready")
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }

        // Only now does a failure mean "it broke", rather than "it never started".
        listener.stateUpdateHandler = { [weak self] state in
            guard case .failed(let error) = state else { return }
            Task { await self?.handleListenerFailure(error) }
        }
        self.listener = listener

        let endpoint = OPNRemoteCoOpEmbeddedServerEndpoint(
            host: advertisedHost,
            port: resolvedPort,
            certificateFingerprint: OPNRemoteCoOpTLSIdentity.fingerprint(for: identity)
        )
        self.endpoint = endpoint
        startHeartbeat()
        logger?("Remote Co-Op local server listening on \(endpoint.guestJoinBaseURL)")
        return endpoint
    }

    public func stop() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        // Finished, not just dropped: the adapter's forwarding task otherwise never completes and only
        // ends by cancellation.
        for continuation in eventContinuations.values { continuation.finish() }
        eventContinuations.removeAll()
        for connection in connections.values { connection.connection.cancel() }
        connections.removeAll()
        guestConnections.removeAll()
        listener?.cancel()
        listener = nil
        endpoint = nil
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeatInterval)
                guard !Task.isCancelled else { return }
                await self?.sweepIdleConnections()
            }
        }
    }

    /// Asks every signaling socket to answer, and drops the ones that stopped answering.
    ///
    /// Both guest clients reply to `heartbeat`, so silence past `socketIdleTimeout` means the peer is
    /// gone rather than quiet. Dropping it here is what publishes `.guestDisconnected`, which starts
    /// the grace period and eventually frees the slot.
    private func sweepIdleConnections() {
        let now = Date()
        let heartbeat = OPNRemoteCoOpWireMessage(kind: .heartbeat, roomID: nil)
        for connection in connections.values where connection.isWebSocket {
            guard now.timeIntervalSince(connection.lastActivityAt) < Self.socketIdleTimeout else {
                logger?("Remote Co-Op dropped a signaling socket that stopped answering")
                close(connection.id)
                continue
            }
            sendWire(connection, heartbeat)
        }
    }

    /// Sends a host-side command to the guest it names.
    ///
    /// No room bookkeeping: there is exactly one invite and this process owns it, so a command is
    /// addressed to a participant rather than routed through a room the way the deployed broker's
    /// relay had to.
    public func send(_ command: OPNRemoteCoOpSignalingCommand) {
        switch command {
        // Nothing to do: guests read the token from their own URL or the native greeting, and this
        // server verifies nothing itself - `registerGuest` does.
        case .inviteCreated:
            break
        case .inviteEnded:
            broadcast(OPNRemoteCoOpWireMessage(kind: .inviteEnded, roomID: nil, reason: "Host ended the invite."))
            for connection in connections.values where connection.isWebSocket { connection.connection.cancel() }
        case .participantUpdated(let participant):
            // First update for a participant means the host session accepted their invite token, so
            // this is the earliest point at which they have earned the ICE configuration. It has to
            // precede the update itself: the guest builds its peer connection from it, and the offer
            // follows immediately behind.
            sendNetworkConfigurationIfNeeded(to: participant.id)
            sendToGuest(participant.id, OPNRemoteCoOpWireMessage.message(for: command, roomID: nil, sessionQualityPreset: networkConfiguration.sessionQualityPreset))
        case .participantRemoved(let participantID):
            sendToGuest(participantID, OPNRemoteCoOpWireMessage.message(for: command, roomID: nil, sessionQualityPreset: networkConfiguration.sessionQualityPreset))
        case .guestRejected(let participantID, _):
            sendToGuest(participantID, OPNRemoteCoOpWireMessage.message(for: command, roomID: nil, sessionQualityPreset: networkConfiguration.sessionQualityPreset))
            // The claim is released here, not left standing.
            //
            // The gate binds a participant on a non-empty token; the *signature* is verified later by
            // `registerGuest`, and a rejection used to leave the binding in place - so a socket that
            // presented a garbage token kept ownership of that participant's routing, received their
            // `participantUpdated`, their SDP and (on the first update) the relay credentials, and
            // locked the real guest out of reconnecting for as long as it stayed connected.
            releaseClaim(on: participantID)
        case .inputRejected(let participantID, _), .peerSignal(let participantID, _):
            sendToGuest(participantID, OPNRemoteCoOpWireMessage.message(for: command, roomID: nil, sessionQualityPreset: networkConfiguration.sessionQualityPreset))
        }
    }

    /// Drops a participant binding after the host refused the join, so the connection that made the
    /// unverified claim stops owning that participant's routing.
    private func releaseClaim(on participantID: UUID) {
        guard let connectionID = guestConnections.removeValue(forKey: participantID) else { return }
        participantsGivenNetworkConfiguration.remove(participantID)
        guard let connection = connections[connectionID], connection.participantID == participantID else { return }
        connection.participantID = nil
    }

    /// Sent once per verified participant. Re-sending on every later update would put the relay
    /// credentials back on the wire for no reason.
    private func sendNetworkConfigurationIfNeeded(to participantID: UUID) {
        guard !participantsGivenNetworkConfiguration.contains(participantID),
              let connectionID = guestConnections[participantID],
              let connection = connections[connectionID] else { return }
        participantsGivenNetworkConfiguration.insert(participantID)
        sendWire(connection, OPNRemoteCoOpWireMessage(
            kind: .networkConfiguration,
            roomID: nil,
            participantID: participantID,
            networkConfiguration: networkConfiguration
        ))
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
        connection.lastActivityAt = Date()
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
                guard frame.isFinal else {
                    connection.fragmentOpcode = frame.opcode
                    connection.fragmentPayload = frame.payload
                    guard connection.fragmentPayload.count <= Int(OPNRemoteCoOpWebSocketCodec.maximumPayloadBytes) else {
                        logger?("Remote Co-Op local server dropped a guest socket: oversized fragmented message")
                        connection.connection.cancel()
                        return
                    }
                    continue
                }
                handleGuestMessage(connection, payload: frame.payload)
            case .continuation:
                guard connection.fragmentOpcode != nil else { continue }
                connection.fragmentPayload.append(frame.payload)
                guard connection.fragmentPayload.count <= Int(OPNRemoteCoOpWebSocketCodec.maximumPayloadBytes) else {
                    logger?("Remote Co-Op local server dropped a guest socket: oversized fragmented message")
                    connection.connection.cancel()
                    return
                }
                guard frame.isFinal else { continue }
                let payload = connection.fragmentPayload
                connection.fragmentOpcode = nil
                connection.fragmentPayload = Data()
                handleGuestMessage(connection, payload: payload)
            case .ping:
                send(connection, OPNRemoteCoOpWebSocketCodec.encodeFrame(opcode: .pong, payload: frame.payload))
            case .close:
                connection.connection.cancel()
            case .pong:
                break
            }
        }
    }

    private func handleGuestMessage(_ connection: Connection, payload: Data) {
        guard let message = try? OPNRemoteCoOpWireCodec.decode(payload) else { return }
        // Received and dropped, never echoed.
        //
        // Both guest clients reply to every heartbeat they receive, so answering one started an
        // unbounded ping-pong: the 15s sweep pinged, the guest replied, this echoed, the guest
        // replied again, bounded only by round-trip time. The echo had no consumer either -
        // `ingest` already refreshed `lastActivityAt` before this ran, which is the whole point of
        // the message. The native listener has always dropped it, and was right to.
        if message.kind == .heartbeat { return }
        // Authorisation lives in `OPNRemoteCoOpGuestMessageGate`, not here.
        //
        // Both listeners implemented the same rules independently, and that has drifted before: this
        // listener's allowlist and claim guard had to be hand-copied into the native one after it
        // shipped without them. One decision, two transports.
        switch OPNRemoteCoOpGuestMessageGate.decide(
            message: message,
            owner: connection.participantID,
            isHeldByAnotherConnection: { participantID in
                guard let existing = guestConnections[participantID], existing != connection.id else { return false }
                return connections[existing] != nil
            }
        ) {
        case .ignore:
            return
        case .dropConnection(let reason):
            logger?("Remote Co-Op refused a socket that \(reason)")
            connection.connection.cancel()
            return
        case .claimThenDeliver(let participantID):
            // The previous binding goes with it. Without this, a connection that had claimed another
            // participant left `guestConnections` still pointing here for the old ID, so that
            // participant's host commands - including their SDP - kept arriving on this socket.
            if let previous = connection.participantID, previous != participantID {
                guestConnections[previous] = nil
                participantsGivenNetworkConfiguration.remove(previous)
            }
            connection.participantID = participantID
            guestConnections[participantID] = connection.id
            // The ICE configuration is deliberately NOT sent here. The gate only checked that the
            // token is non-empty; the signature is verified later, by `registerGuest`. Those servers
            // now carry relay credentials, so replying here handed anyone who could reach this port
            // the means to spend the host's relay allowance - and the tunnel deliberately exposes it.
            // It goes out with `participantUpdated`, which follows verification.
        case .deliver:
            break
        }
        guard let event = message.signalingEvent() else { return }
        for continuation in eventContinuations.values { continuation.yield(event) }
    }

    private func close(_ id: UUID) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.connection.cancel()
        guard let participantID = connection.participantID else { return }
        guestConnections[participantID] = nil
        // Cleared with the socket, so a reconnect has to re-verify before it is handed the relay
        // credentials again.
        participantsGivenNetworkConfiguration.remove(participantID)
        for continuation in eventContinuations.values { continuation.yield(.guestDisconnected(participantID)) }
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
