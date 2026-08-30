import Foundation
import Network

/// The RTSP control channel the negotiator drives. Abstracted so the handshake can be
/// exercised against recorded seat responses without a socket.
public protocol NvstRtspControlChannel: Sendable {
    func connect(sessionID: String?) async throws
    @discardableResult
    func request(method: String, uri: String, headers: [(String, String)], body: String) async throws -> NvstRtspResponse
    /// Keeps the control connection alive for the life of the session. A transport that has no such
    /// notion can ignore it.
    func startKeepAlive() async
    /// Latest keepalive round trip in milliseconds; -1 when the channel cannot measure one.
    /// A protocol requirement, not just an extension default: the callers hold existentials, and
    /// an extension-only method dispatches statically to the default, silently shadowing the
    /// real implementation.
    func measuredRoundTripMilliseconds() async -> Double
    /// Keepalive ping/pong counters for the diagnostic log.
    func keepAliveSummary() async -> String
    func close() async
}

public extension NvstRtspControlChannel {
    func startKeepAlive() async {}
    /// Latest keepalive round trip in milliseconds; -1 when the channel cannot measure one.
    func measuredRoundTripMilliseconds() async -> Double { -1 }
    func keepAliveSummary() async -> String { "" }
}

public extension NvstRtspControlChannel {
    @discardableResult
    func request(method: String, uri: String, headers: [(String, String)] = []) async throws -> NvstRtspResponse {
        try await request(method: method, uri: uri, headers: headers, body: "")
    }
}

/// RTSP-over-WSS control connection to the NVST seat (`:322`).
///
/// A stock HTTP client cannot be used: the seat only accepts the exact Poco-shaped upgrade
/// (`GET /rtsp`, `Content-Length: 0`, `x-nv-sessionid`) and answers anything else with HTTP 400.
/// So the TLS socket is driven directly and the WebSocket framing is done here.
public actor NvstRtspConnection: NvstRtspControlChannel {
    public enum ConnectionError: LocalizedError, Equatable, Sendable {
        case connectFailed(String)
        case upgradeRejected(Int)
        case invalidAccept
        case closed
        case timedOut(String)
        case overlappingRequest

        public var errorDescription: String? {
            switch self {
            case .connectFailed(let reason): "NVST RTSPS connect failed: \(reason)"
            case .upgradeRejected(let code): "NVST RTSPS WebSocket upgrade rejected with HTTP \(code)."
            case .invalidAccept: "NVST RTSPS WebSocket upgrade returned an invalid Sec-WebSocket-Accept."
            case .closed: "The NVST RTSPS control connection is closed."
            case .timedOut(let method): "NVST RTSPS \(method) timed out."
            case .overlappingRequest: "Overlapping NVST RTSPS requests are not supported."
            }
        }
    }

    private let target: NvstRtspEndpoints.Target
    private let timeout: Duration
    let logger: (@Sendable (String) -> Void)?
    private var connection: NWConnection?
    private var frameReader = NvstWebSocketFrameReader()
    private var responseBuffer = Data()
    private var pendingResponses: [NvstRtspResponse] = []
    private var responseWaiter: CheckedContinuation<NvstRtspResponse, Error>?
    private var failure: Error?
    private var cseq = 0
    private var keepAliveTask: Task<Void, Never>?
    private var pingsSent = 0

    public init(target: NvstRtspEndpoints.Target,
                timeout: Duration = .seconds(20),
                logger: (@Sendable (String) -> Void)? = nil) {
        self.target = target
        self.timeout = timeout
        self.logger = logger
    }

    // MARK: - Lifecycle

    public func connect(sessionID: String?) async throws {
        let parameters = NWParameters(tls: tlsOptions(), tcp: NWProtocolTCP.Options())
        let endpoint = NWEndpoint.hostPort(host: .init(target.host), port: .init(integerLiteral: target.port))
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection
        // NWConnection has no connect deadline of its own: an unroutable seat would sit in
        // `.waiting` forever. Cancelling on the deadline is what makes the state handler fire —
        // racing the continuation against a sleep would leave the continuation unresumed.
        let timedOut = OneShotFlag()
        let timeoutTask = Task { [timeout] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            timedOut.set()
            connection.cancel()
        }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let resumed = OneShot(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: resumed.resume(.success(()))
                    case .failed(let error): resumed.resume(.failure(ConnectionError.connectFailed(error.localizedDescription)))
                    case .cancelled: resumed.resume(.failure(timedOut.isSet ? ConnectionError.timedOut("CONNECT") : ConnectionError.closed))
                    default: break
                    }
                }
                connection.start(queue: Self.queue)
            }
            timeoutTask.cancel()
        } catch {
            timeoutTask.cancel()
            connection.cancel()
            self.connection = nil
            throw error
        }
        logger?("NVST RTSPS TLS connected to \(target.host):\(target.port)")
        try await performUpgrade(connection: connection, sessionID: sessionID)
        receiveLoop(connection: connection)
    }

    public func close() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
        connection?.cancel()
        connection = nil
        if let responseWaiter {
            self.responseWaiter = nil
            responseWaiter.resume(throwing: ConnectionError.closed)
        }
    }

    // MARK: - Requests

    @discardableResult
    public func request(method: String,
                        uri: String,
                        headers: [(String, String)],
                        body: String) async throws -> NvstRtspResponse {
        guard let connection else { throw ConnectionError.closed }
        if let failure { throw failure }
        guard responseWaiter == nil else { throw ConnectionError.overlappingRequest }
        cseq += 1
        let message = NvstRtspMessage.buildRequest(method: method, uri: uri, headers: headers, body: body, cseq: cseq)
        try await send(connection: connection, data: NvstWebSocketFrame.encodeText(Data(message.utf8)))
        return try await nextResponse(method: method)
    }

    /// Starts the WebSocket ping keepalive the official client runs for the life of the session.
    /// Nothing else travels on this connection between PLAY and teardown, so without it the seat
    /// sees an idle control session while video continues on its own socket.
    /// The exact-arity witness for the protocol requirement: the `(interval:)` overload with a
    /// defaulted parameter does NOT witness `startKeepAlive()`, so an existential caller was
    /// silently getting the protocol extension's empty default — no keepalive ping was ever sent.
    public func startKeepAlive() {
        startKeepAlive(interval: Self.keepAliveInterval)
    }

    public func startKeepAlive(interval: TimeInterval) {
        guard keepAliveTask == nil else { return }
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, await self.sendPing() else { return }
            }
        }
    }

    /// Captured cadence: 23 pings across a ~45 s session.
    public static let keepAliveInterval: TimeInterval = 2

    @discardableResult
    func sendPing() async -> Bool {
        guard let connection, failure == nil else { return false }
        do {
            try await send(connection: connection, data: NvstWebSocketFrame.encodePing())
            pingsSent += 1
            lastPingSentAt = DispatchTime.now().uptimeNanoseconds
            return true
        } catch {
            return false
        }
    }

    public var keepAlivePingsSent: Int { pingsSent }

    /// Round trip of the most recent keepalive ping/pong on this control connection, in
    /// milliseconds, or -1 before the first pong. The seat's WebSocket layer answers pings
    /// mandatorily, so this measures the network path without adding any traffic — the pings
    /// were already being sent every `keepAliveInterval`.
    public var roundTripMilliseconds: Double { lastRoundTripMilliseconds }
    public func measuredRoundTripMilliseconds() -> Double { lastRoundTripMilliseconds }
    /// Keepalive health for the diagnostic log: whether pings go out and pongs come back at all.
    public func keepAliveSummary() -> String {
        "pings=\(pingsSent) pongs=\(frameReader.pongsSeen) answered=\(pongsAnswered)"
            + " failed=\(failure.map { _ in 1 } ?? 0) rtt=\(String(format: "%.1f", lastRoundTripMilliseconds))"
    }
    private var lastPingSentAt: UInt64?
    var lastRoundTripMilliseconds: Double = -1
    private var pongsAccounted = 0

    private func notePongs() {
        let seen = frameReader.pongsSeen
        guard seen > pongsAccounted else { return }
        pongsAccounted = seen
        guard let sentAt = lastPingSentAt else { return }
        lastPingSentAt = nil
        let now = DispatchTime.now().uptimeNanoseconds
        guard now > sentAt else { return }
        lastRoundTripMilliseconds = Double(now - sentAt) / 1_000_000
    }

    private func nextResponse(method: String) async throws -> NvstRtspResponse {
        if !pendingResponses.isEmpty { return pendingResponses.removeFirst() }
        if let failure { throw failure }
        let deadline = timeout
        return try await withThrowingTaskGroup(of: NvstRtspResponse.self) { group in
            group.addTask { [weak self] in
                guard let self else { throw ConnectionError.closed }
                return try await self.awaitResponse()
            }
            group.addTask { [weak self] in
                try await Task.sleep(for: deadline)
                // Resume the waiting continuation too: leaving it pending would deadlock the
                // group, which cannot return until every child task finishes.
                await self?.failPending(ConnectionError.timedOut(method))
                throw ConnectionError.timedOut(method)
            }
            guard let response = try await group.next() else {
                throw ConnectionError.timedOut(method)
            }
            group.cancelAll()
            return response
        }
    }

    /// Fails a pending request without tearing down the connection.
    private func failPending(_ error: Error) {
        guard let waiter = responseWaiter else { return }
        responseWaiter = nil
        waiter.resume(throwing: error)
    }

    private func awaitResponse() async throws -> NvstRtspResponse {
        try await withCheckedThrowingContinuation { continuation in
            if !pendingResponses.isEmpty {
                continuation.resume(returning: pendingResponses.removeFirst())
                return
            }
            if let failure {
                continuation.resume(throwing: failure)
                return
            }
            responseWaiter = continuation
        }
    }

    // MARK: - Internals

    static let queue = DispatchQueue(label: "com.opennow.nvst.rtsp")

    private func tlsOptions() -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(options.securityProtocolOptions, target.host)
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
        return options
    }

    private func performUpgrade(connection: NWConnection, sessionID: String?) async throws {
        let key = NvstWebSocketUpgrade.generateKey()
        let request = NvstWebSocketUpgrade.request(host: target.host, port: target.port, secWebSocketKey: key, sessionID: sessionID)
        try await send(connection: connection, data: Data(request.utf8))
        var buffer = Data()
        while true {
            let chunk = try await receive(connection: connection)
            buffer.append(chunk)
            guard let response = NvstWebSocketUpgrade.parseResponse(buffer) else {
                guard buffer.count <= 16_384 else { throw ConnectionError.upgradeRejected(0) }
                continue
            }
            guard response.statusCode == 101 else { throw ConnectionError.upgradeRejected(response.statusCode) }
            guard response.headers["sec-websocket-accept"] == NvstWebSocketUpgrade.expectedAccept(for: key) else {
                throw ConnectionError.invalidAccept
            }
            if !response.leftover.isEmpty {
                ingest(response.leftover)
            }
            logger?("NVST RTSPS WebSocket upgraded (GET \(NvstWebSocketUpgrade.requestTarget))")
            return
        }
    }

    private func receiveLoop(connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            Task {
                if let content, !content.isEmpty {
                    await self.ingest(content)
                }
                if let error {
                    await self.fail(ConnectionError.connectFailed(error.localizedDescription))
                    return
                }
                if isComplete {
                    await self.fail(ConnectionError.closed)
                    return
                }
                await self.resumeReceiveLoop()
            }
        }
    }

    private func resumeReceiveLoop() {
        guard let connection else { return }
        receiveLoop(connection: connection)
    }

    private func ingest(_ chunk: Data) {
        do {
            for payload in try frameReader.push(chunk) {
                responseBuffer.append(payload)
                while let response = try NvstRtspMessage.extractResponse(from: &responseBuffer) {
                    deliver(response)
                }
            }
            notePongs()
            // The seat pings this connection and closes it when no pong comes back — Poco's
            // client answered these automatically, so never answering was invisible until the
            // keepalive tried to use the socket the seat had already abandoned.
            let pings = frameReader.takePings()
            if !pings.isEmpty, let connection {
                pongsAnswered += pings.count
                for ping in pings {
                    Task { try? await self.send(connection: connection, data: NvstWebSocketFrame.encodePong(payload: ping)) }
                }
            }
        } catch {
            fail(error)
        }
    }
    private var pongsAnswered = 0

    private func deliver(_ response: NvstRtspResponse) {
        if let responseWaiter {
            self.responseWaiter = nil
            responseWaiter.resume(returning: response)
        } else {
            pendingResponses.append(response)
        }
    }

    private func fail(_ error: Error) {
        failure = error
        if let responseWaiter {
            self.responseWaiter = nil
            responseWaiter.resume(throwing: error)
        }
    }

    private func send(connection: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = OneShot(continuation)
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    resumed.resume(.failure(ConnectionError.connectFailed(error.localizedDescription)))
                } else {
                    resumed.resume(.success(()))
                }
            })
        }
    }

    private func receive(connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let resumed = OneShot(continuation)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { content, _, isComplete, error in
                if let error {
                    resumed.resume(.failure(ConnectionError.connectFailed(error.localizedDescription)))
                    return
                }
                if let content, !content.isEmpty {
                    resumed.resume(.success(content))
                    return
                }
                resumed.resume(.failure(isComplete ? ConnectionError.closed : ConnectionError.connectFailed("empty read")))
            }
        }
    }
}

/// A set-once flag shared with a timeout task.
private final class OneShotFlag: @unchecked Sendable {
    let lock = NSLock()
    private var value = false

    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Guards a `CheckedContinuation` that Network.framework callbacks may invoke more than once.
private final class OneShot<Value: Sendable>: @unchecked Sendable {
    let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<Value, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        pending.resume(with: result)
    }
}
