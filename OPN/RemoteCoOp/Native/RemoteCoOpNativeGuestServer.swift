//  Host-side listener for native Remote Co-Op guests: another OpenNOW instance on the same
//  network or a shared VPN, speaking the browser's wire protocol over a plain TCP socket
//  instead of a WebSocket.
//
//  The server *is* the `OPNRemoteCoOpSignalingSession` for these guests: a guest's join request
//  arrives here and becomes a signaling event, and commands from the coordinator are routed back
//  to the right connection. Nothing above this file - the host session, the approval flow, the
//  peer controller - knows the guest is not a browser.
//
//  Trust model: any guest that can reach the listener receives the current invite token (the
//  same token the browser guest gets from the invite link), so host approval - not the signed
//  invite - is what gates who actually plays here. Media is protected by DTLS-SRTP inside WebRTC;
//  the signaling socket itself is plaintext, acceptable on a LAN/VPN but the reason this transport
//  is not an internet exposure point and the reason the relay credentials are withheld until the
//  host session has accepted the guest.
//

import Foundation
import Network

public final class OPNRemoteCoOpNativeGuestServer: OPNRemoteCoOpSignalingSession, @unchecked Sendable {
    public static let serviceType = "_opennow-coop._tcp"
    public static let defaultPort: UInt16 = 32189
    /// Far above the three guests a seat allows, and low enough that an unauthenticated peer cannot
    /// make the host hold descriptors indefinitely. Matches the browser-facing server.
    static let maximumConnections = 64

    /// One accepted socket. `participantID` is learned from the guest's join request and is what
    /// `send(_:)` routes targeted commands by.
    private final class Connection: @unchecked Sendable {
        let id: UUID
        let handle: NWConnection
        var codec = OPNRemoteCoOpNativeFrameCodec()
        var participantID: UUID?
        /// Last time anything arrived on this socket, for the idle sweep. Guarded by the server's
        /// `lock`, like `participantID`.
        var lastActivityAt = Date()

        init(handle: NWConnection) {
            self.id = UUID()
            self.handle = handle
        }
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "io.github.opencloudgaming.opennow.remote-coop.native-server")
    private let inviteProvider: @Sendable () async -> OPNRemoteCoOpInvite?
    /// Mutable: Transport and Latency can change mid-session, and a guest joining afterwards was being
    /// handed the configuration from invite-creation time.
    private var networkConfiguration: OPNRemoteCoOpNetworkConfiguration
    private let logger: @Sendable (String) -> Void
    private var listener: NWListener?
    private var connections: [UUID: Connection] = [:]
    /// Participants whose invite has verified and who have therefore been given the ICE
    /// configuration. Cleared with the socket, so a reconnect has to re-verify before it is handed
    /// the relay credentials again.
    private var participantsGivenNetworkConfiguration: Set<UUID> = []
    private var idleSweepTask: Task<Void, Never>?
    private var eventContinuations: [UUID: AsyncStream<OPNRemoteCoOpSignalingEvent>.Continuation] = [:]
    private var isClosed = false
    private var didRetryOnEphemeralPort = false
    private var boundPort: UInt16?

    public init(inviteProvider: @escaping @Sendable () async -> OPNRemoteCoOpInvite?,
                networkConfiguration: OPNRemoteCoOpNetworkConfiguration,
                logger: @escaping @Sendable (String) -> Void = { _ in }) {
        self.inviteProvider = inviteProvider
        self.networkConfiguration = networkConfiguration
        self.logger = logger
    }

    public func updateNetworkConfiguration(_ configuration: OPNRemoteCoOpNetworkConfiguration) {
        lock.withLock { networkConfiguration = configuration }
    }

    /// The port the listener actually bound. Useful for tests and diagnostics; Bonjour carries
    /// it to real guests.
    public var port: UInt16? {
        lock.withLock { boundPort }
    }

    /// What a native guest should type into its "connect by address" field, or nil before the
    /// listener has bound.
    ///
    /// The tailnet address wins when there is one. A guest on the LAN can use either, but a guest
    /// anywhere else can only use the tailnet address - and someone reading this off a host's screen
    /// to send to a friend is almost always in the second case. Bonjour covers the LAN without anyone
    /// having to read an address at all, because multicast reaches every guest that address would
    /// have served; it is the tunnel Bonjour cannot cross that needs this.
    public var guestAddressHint: String? {
        guard let port else { return nil }
        guard let host = OPNRemoteCoOpLocalAddress.tailscaleIPv4() ?? OPNRemoteCoOpLocalAddress.primaryIPv4() else { return nil }
        return port == Self.defaultPort ? host : "\(host):\(port)"
    }

    /// Matches the browser-facing server, and for the same reason: a guest whose Mac sleeps leaves a
    /// TCP connection that never closes, holding its slot, its announced pad and its share of
    /// `maximumConnections` until the host tears the session down by hand. TCP alone does not notice -
    /// there is no keepalive here - so the host asks, and drops what stops answering. Both guest
    /// clients reply to `heartbeat`.
    static let heartbeatInterval: Duration = .seconds(15)
    static let socketIdleTimeout: TimeInterval = 60

    public func start() {
        listen(on: Self.defaultPort)
        startIdleSweep()
    }

    private func startIdleSweep() {
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeatInterval)
                guard let self, !Task.isCancelled else { return }
                sweepIdleConnections()
            }
        }
        lock.withLock { idleSweepTask = task }
    }

    /// Asks every socket to answer, and drops the ones that stopped.
    private func sweepIdleConnections() {
        let now = Date()
        let heartbeat = OPNRemoteCoOpWireMessage(kind: .heartbeat)
        let (idle, live) = lock.withLock { () -> ([Connection], [Connection]) in
            guard !isClosed else { return ([], []) }
            var idle: [Connection] = []
            var live: [Connection] = []
            for connection in connections.values {
                if now.timeIntervalSince(connection.lastActivityAt) >= Self.socketIdleTimeout {
                    idle.append(connection)
                } else {
                    live.append(connection)
                }
            }
            return (idle, live)
        }
        for connection in idle {
            logger("Native Remote Co-Op dropped a socket that stopped answering")
            drop(connection)
        }
        // Outside the lock: `send` reaches Network.framework.
        for connection in live { send(heartbeat, to: connection) }
    }

    private func listen(on port: UInt16) {
        let endpointPort = port == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: port) ?? .any
        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp, on: endpointPort)
        } catch {
            logger("Native Remote Co-Op listener failed to bind port \(port): \(error.localizedDescription)")
            retryOnEphemeralPort(after: port)
            return
        }
        listener.service = NWListener.Service(
            name: Host.current().localizedName ?? "OpenNOW Host",
            type: Self.serviceType,
            txtRecord: NWTXTRecord(["v": "1"])
        )
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            self?.handleListenerState(state, attemptedPort: port, boundPort: listener?.port?.rawValue)
        }
        listener.newConnectionHandler = { [weak self] handle in
            self?.accept(handle)
        }
        lock.withLock { self.listener = listener }
        listener.start(queue: queue)
    }

    private func handleListenerState(_ state: NWListener.State, attemptedPort: UInt16, boundPort listenerPort: UInt16?) {
        switch state {
        case .ready:
            lock.withLock { boundPort = listenerPort }
            logger("Native Remote Co-Op listener ready on port \(listenerPort.map(String.init) ?? "unknown")")
        case .failed(let error):
            logger("Native Remote Co-Op listener failed on port \(attemptedPort): \(error.localizedDescription)")
            retryOnEphemeralPort(after: attemptedPort)
        default:
            break
        }
    }

    /// A fixed port keeps a guest's muscle memory stable, but a second OpenNOW instance on the
    /// same Mac - exactly the PoC setup - already holds it, so fall back to an ephemeral one.
    /// Bonjour still tells guests where to connect.
    private func retryOnEphemeralPort(after attemptedPort: UInt16) {
        let shouldRetry = lock.withLock { () -> Bool in
            guard !isClosed, attemptedPort != 0, !didRetryOnEphemeralPort else { return false }
            didRetryOnEphemeralPort = true
            // Cancelled, not just dropped: a failed NWListener is terminal but still holds its
            // resources until it is told to let go of them.
            listener?.cancel()
            listener = nil
            return true
        }
        guard shouldRetry else { return }
        logger("Native Remote Co-Op retrying on an ephemeral port")
        listen(on: 0)
    }

    private func accept(_ handle: NWConnection) {
        let connection = Connection(handle: handle)
        let accepted = lock.withLock { () -> Bool in
            // Capped like the browser-facing listener. Anything that can reach this port could open
            // sockets without limit, and each one costs a file descriptor and a greeting; refusing
            // before the connection is tracked means a flood cannot grow the table, and refusing the
            // newcomer rather than evicting means no established guest is dropped mid-game.
            guard !isClosed, connections.count < Self.maximumConnections else { return false }
            connections[connection.id] = connection
            return true
        }
        guard accepted else {
            handle.cancel()
            return
        }
        handle.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.greet(connection) }
        }
        handle.start(queue: queue)
        receive(on: connection)
    }

    /// On-connect handshake: the current invite, with its signed token, exactly what an invite link
    /// hands a browser.
    ///
    /// The network configuration is deliberately not part of the greeting. `iceServers` now carries
    /// relay credentials - Cloudflare-minted, or a host's non-expiring username and password - and a
    /// greeting is sent before the guest has presented anything, so it went to whatever opened the
    /// socket. It goes out with the first `participantUpdated` instead, which the coordinator only
    /// sends once the invite signature has verified.
    private func greet(_ connection: Connection) {
        Task { [weak self] in
            guard let self else { return }
            let invite = await inviteProvider()
            send(OPNRemoteCoOpWireMessage(kind: .hostHello, invite: invite), to: connection)
        }
    }

    private func receive(on connection: Connection) {
        connection.handle.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    lock.withLock { connection.lastActivityAt = Date() }
                    let messages = try connection.codec.append(data)
                    for message in messages { route(message, from: connection) }
                } catch {
                    logger("Native Remote Co-Op dropping a corrupt frame: \(error.localizedDescription)")
                    drop(connection)
                    return
                }
            }
            if isComplete || error != nil {
                drop(connection)
                return
            }
            receive(on: connection)
        }
    }

    private func route(_ message: OPNRemoteCoOpWireMessage, from connection: Connection) {
        // Authorisation lives in `OPNRemoteCoOpGuestMessageGate`, not here.
        //
        // These rules were written out independently in both listeners, and this one shipped without
        // the kind allowlist and the claim guard until they were hand-copied across. One decision,
        // two transports, so a third cannot introduce a third variant.
        let decision = lock.withLock { () -> OPNRemoteCoOpGuestMessageGate.Decision in
            let decision = OPNRemoteCoOpGuestMessageGate.decide(
                message: message,
                owner: connection.participantID,
                isHeldByAnotherConnection: { participantID in
                    connections.values.contains { $0.participantID == participantID && $0 !== connection }
                }
            )
            // Bound inside the same critical section that tested the claim, so two sockets racing the
            // same participant cannot both be told it is free.
            if case .claimThenDeliver(let participantID) = decision {
                connection.participantID = participantID
            }
            return decision
        }
        switch decision {
        case .ignore:
            return
        case .dropConnection(let reason):
            logger("Native Remote Co-Op refused a socket that \(reason)")
            drop(connection)
            return
        case .claimThenDeliver, .deliver:
            break
        }
        guard let event = message.signalingEvent() else { return }
        publish(event)
    }

    private func drop(_ connection: Connection) {
        let participantID = lock.withLock { () -> UUID? in
            guard connections.removeValue(forKey: connection.id) != nil else { return nil }
            if let participantID = connection.participantID { participantsGivenNetworkConfiguration.remove(participantID) }
            return connection.participantID
        }
        connection.handle.stateUpdateHandler = nil
        connection.handle.cancel()
        // Mirror the browser socket drop: the slot is held through a grace period, and the
        // coordinator is what decides the guest is gone for good.
        if let participantID { publish(.guestDisconnected(participantID)) }
    }

    // MARK: - OPNRemoteCoOpSignalingSession

    public func events() -> AsyncStream<OPNRemoteCoOpSignalingEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(240)) { continuation in
            lock.withLock {
                if isClosed {
                    continuation.finish()
                } else {
                    eventContinuations[id] = continuation
                }
            }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { self?.eventContinuations[id] = nil }
            }
        }
    }

    public func send(_ command: OPNRemoteCoOpSignalingCommand) async {
        let sessionPreset = lock.withLock { networkConfiguration.sessionQualityPreset }
        // The first update for a participant means the host session accepted their invite token, so
        // it is the earliest point at which they have earned the ICE configuration. It precedes the
        // update itself: the guest builds its peer connection from it, and the offer follows.
        if case .participantUpdated(let participant) = command { sendNetworkConfigurationIfNeeded(to: participant.id) }
        guard let message = OPNRemoteCoOpWireMessage.message(for: command, sessionQualityPreset: sessionPreset) else { return }
        let targets: [Connection] = lock.withLock {
            switch command {
            // Addressed to their own guest, matching the browser-facing server. Broadcasting a
            // `participantUpdated` put another guest's whole record - display name, player slot,
            // quality - on the wire to every peer that could reach the listener.
            case .guestRejected(let participantID, _), .inputRejected(let participantID, _),
                 .peerSignal(let participantID, _), .participantRemoved(let participantID):
                return connections.values.filter { $0.participantID == participantID }
            case .participantUpdated(let participant):
                return connections.values.filter { $0.participantID == participant.id }
            case .inviteCreated, .inviteEnded:
                return Array(connections.values)
            }
        }
        for connection in targets { send(message, to: connection) }
        // Release the binding a refused join left behind. The gate binds on a non-empty token and the
        // signature is only checked later by `registerGuest`, so without this a connection that
        // presented a garbage token kept owning that participant: it stayed the target of their
        // `participantUpdated`, their SDP and the relay credentials, and the real guest could not
        // reconnect while it lived.
        if case .guestRejected(let participantID, _) = command {
            lock.withLock {
                participantsGivenNetworkConfiguration.remove(participantID)
                for connection in connections.values where connection.participantID == participantID {
                    connection.participantID = nil
                }
            }
        }
    }

    public func close() async {
        let state = lock.withLock { () -> (NWListener?, [Connection], [AsyncStream<OPNRemoteCoOpSignalingEvent>.Continuation]) in
            guard !isClosed else { return (nil, [], []) }
            isClosed = true
            let listener = listener
            let connections = Array(self.connections.values)
            let continuations = Array(eventContinuations.values)
            self.listener = nil
            self.connections.removeAll()
            self.eventContinuations.removeAll()
            idleSweepTask?.cancel()
            idleSweepTask = nil
            return (listener, connections, continuations)
        }
        state.0?.cancel()
        for connection in state.1 {
            connection.handle.stateUpdateHandler = nil
            connection.handle.cancel()
        }
        for continuation in state.2 { continuation.finish() }
    }

    // MARK: - Sending

    /// Sent once per verified participant. Re-sending on every later update would put the relay
    /// credentials back on the wire for no reason.
    private func sendNetworkConfigurationIfNeeded(to participantID: UUID) {
        let target = lock.withLock { () -> (Connection, OPNRemoteCoOpNetworkConfiguration)? in
            guard !participantsGivenNetworkConfiguration.contains(participantID),
                  let connection = connections.values.first(where: { $0.participantID == participantID }) else { return nil }
            participantsGivenNetworkConfiguration.insert(participantID)
            return (connection, networkConfiguration)
        }
        guard let target else { return }
        send(OPNRemoteCoOpWireMessage(kind: .networkConfiguration, networkConfiguration: target.1), to: target.0)
    }

    private func send(_ message: OPNRemoteCoOpWireMessage, to connection: Connection) {
        guard let frame = try? OPNRemoteCoOpNativeFrameCodec.encode(message) else { return }
        connection.handle.send(content: frame, completion: .contentProcessed { [weak self] error in
            if let error { self?.logger("Native Remote Co-Op send failed: \(error.localizedDescription)") }
        })
    }

    private func publish(_ event: OPNRemoteCoOpSignalingEvent) {
        let continuations = lock.withLock { isClosed ? [] : Array(eventContinuations.values) }
        for continuation in continuations { continuation.yield(event) }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
