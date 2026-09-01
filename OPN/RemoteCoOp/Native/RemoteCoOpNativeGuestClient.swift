//
//  RemoteCoOpNativeGuestClient.swift
//  OpenNOW
//
//  The guest half of native Remote Co-Op: find hosts on the local network (or a shared VPN)
//  with Bonjour, then speak the browser's wire protocol over a plain TCP socket.
//

import Foundation
import Network

/// A host found by Bonjour. `endpoint` is retained so the guest can connect without resolving
/// anything itself - the service name in it is enough for Network.framework.
public struct OPNRemoteCoOpNativeDiscoveredHost: Identifiable, Equatable, @unchecked Sendable {
    public let id: String
    public let name: String
    public let endpoint: NWEndpoint

    public init(endpoint: NWEndpoint) {
        self.endpoint = endpoint
        switch endpoint {
        case .service(let name, let type, let domain, _):
            self.name = name
            self.id = "\(name).\(type)\(domain)"
        default:
            self.name = endpoint.debugDescription
            self.id = endpoint.debugDescription
        }
    }

    /// A host typed in by hand rather than discovered.
    ///
    /// Bonjour is how hosts are found on a LAN, and it is the only way that needs no configuration -
    /// but it works by multicast, and multicast does not cross a WireGuard tunnel. A guest joining
    /// over Tailscale (or any VPN, or a forwarded port) sees an empty browser list no matter how
    /// reachable the host actually is, because nothing on that path carries mDNS.
    ///
    /// So the address is accepted directly. `host` may be an IPv4 or IPv6 literal or a DNS name -
    /// a tailnet's MagicDNS name works, as does the `100.x.y.z` address behind it. A missing port
    /// means the default the host's listener prefers.
    public init?(address: String) {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let parsed = Self.parseHostAndPort(trimmed) else { return nil }
        guard let port = NWEndpoint.Port(rawValue: parsed.port) else { return nil }
        endpoint = .hostPort(host: NWEndpoint.Host(parsed.host), port: port)
        name = parsed.port == OPNRemoteCoOpNativeGuestServer.defaultPort ? parsed.host : "\(parsed.host):\(parsed.port)"
        id = "manual-\(parsed.host):\(parsed.port)"
    }

    /// Splits `host`, `host:port`, `[v6]` and `[v6]:port`. Bracket form is required for a port on an
    /// IPv6 literal, because a bare `fd00::1:32189` is ambiguous - the last group could be either.
    static func parseHostAndPort(_ address: String) -> (host: String, port: UInt16)? {
        if address.hasPrefix("[") {
            guard let closingIndex = address.firstIndex(of: "]") else { return nil }
            let host = String(address[address.index(after: address.startIndex)..<closingIndex])
            guard !host.isEmpty else { return nil }
            let remainder = address[address.index(after: closingIndex)...]
            if remainder.isEmpty { return (host, OPNRemoteCoOpNativeGuestServer.defaultPort) }
            guard remainder.hasPrefix(":"), let port = UInt16(remainder.dropFirst()), port > 0 else { return nil }
            return (host, port)
        }
        let components = address.split(separator: ":", omittingEmptySubsequences: false)
        switch components.count {
        case 1:
            return (String(components[0]), OPNRemoteCoOpNativeGuestServer.defaultPort)
        case 2:
            guard let port = UInt16(components[1]), port > 0, !components[0].isEmpty else { return nil }
            return (String(components[0]), port)
        default:
            // Three or more colons and no brackets: an unbracketed IPv6 literal, which cannot carry
            // a port. Taken whole at the default.
            return (address, OPNRemoteCoOpNativeGuestServer.defaultPort)
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name
    }
}

public final class OPNRemoteCoOpNativeHostBrowser: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "io.github.opencloudgaming.opennow.remote-coop.native-browser")
    private var browser: NWBrowser?
    public var onUpdate: (@Sendable ([OPNRemoteCoOpNativeDiscoveredHost]) -> Void)?

    public init() {}

    public func start() {
        stop()
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: OPNRemoteCoOpNativeGuestServer.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let hosts = results.map { OPNRemoteCoOpNativeDiscoveredHost(endpoint: $0.endpoint) }.sorted { $0.name < $1.name }
            self?.onUpdate?(hosts)
        }
        lock.withLock { self.browser = browser }
        browser.start(queue: queue)
    }

    public func stop() {
        let browser = lock.withLock { () -> NWBrowser? in
            let browser = self.browser
            self.browser = nil
            return browser
        }
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
    }
}

public enum OPNRemoteCoOpNativeConnectionError: LocalizedError, Equatable, Sendable {
    case connectFailed(String)
    case closed

    public var errorDescription: String? {
        switch self {
        case .connectFailed(let message): message
        case .closed: "The connection to the Remote Co-Op host closed."
        }
    }
}

/// One socket to a host. Decoding is incremental (`OPNRemoteCoOpNativeFrameCodec`), so a frame
/// split across packets or several frames in one packet both decode correctly.
public final class OPNRemoteCoOpNativeGuestConnection: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "io.github.opencloudgaming.opennow.remote-coop.native-guest")
    private let endpoint: NWEndpoint
    private var connection: NWConnection?
    private var codec = OPNRemoteCoOpNativeFrameCodec()
    private var messageContinuations: [UUID: AsyncStream<OPNRemoteCoOpWireMessage>.Continuation] = [:]
    private var isClosed = false

    public init(endpoint: NWEndpoint) {
        self.endpoint = endpoint
    }

    /// How long to sit in `.waiting` before giving up.
    ///
    /// `NWConnection` reports an unreachable host or a filtered port as `.waiting` and stays there
    /// indefinitely, retrying - which is right for a roaming phone and wrong here, where the usual
    /// cause is a typo in the address field. Without this the guest window sat on "Connecting to …"
    /// with no error and nothing above it timing out.
    private static let connectTimeout = Duration.seconds(10)

    /// Resolves once the socket is ready to use.
    public func connect() async throws {
        let connection = NWConnection(to: endpoint, using: .tcp)
        let box = OPNContinuationBox()
        lock.withLock { self.connection = connection }
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.connectTimeout)
            guard !Task.isCancelled else { return }
            box.resume(throwing: OPNRemoteCoOpNativeConnectionError.connectFailed("Could not reach the host. Check the address and that the host has an invite open."))
            self?.close()
        }
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            box.adopt(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.resume(returning: ())
                case .failed(let error):
                    box.resume(throwing: OPNRemoteCoOpNativeConnectionError.connectFailed(error.localizedDescription))
                case .cancelled:
                    // `close()` during a connect, which would otherwise leave this awaiting forever.
                    box.resume(throwing: OPNRemoteCoOpNativeConnectionError.closed)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            receive(on: connection)
        }
    }

    public func messages() -> AsyncStream<OPNRemoteCoOpWireMessage> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(240)) { continuation in
            lock.withLock {
                if isClosed {
                    continuation.finish()
                } else {
                    messageContinuations[id] = continuation
                }
            }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { self?.messageContinuations[id] = nil }
            }
        }
    }

    public func send(_ message: OPNRemoteCoOpWireMessage) async throws {
        guard !lock.withLock({ isClosed }) else { throw OPNRemoteCoOpNativeConnectionError.closed }
        let frame = try OPNRemoteCoOpNativeFrameCodec.encode(message)
        let connection = lock.withLock { self.connection }
        guard let connection else { throw OPNRemoteCoOpNativeConnectionError.closed }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: OPNRemoteCoOpNativeConnectionError.connectFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func close() {
        let state = lock.withLock { () -> (NWConnection?, [AsyncStream<OPNRemoteCoOpWireMessage>.Continuation]) in
            guard !isClosed else { return (nil, []) }
            isClosed = true
            let connection = self.connection
            let continuations = Array(messageContinuations.values)
            self.connection = nil
            messageContinuations.removeAll()
            return (connection, continuations)
        }
        state.0?.stateUpdateHandler = nil
        state.0?.cancel()
        for continuation in state.1 { continuation.finish() }
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    let messages = try codec.append(data)
                    publish(messages)
                } catch {
                    close()
                    return
                }
            }
            if isComplete || error != nil {
                close()
                return
            }
            receive(on: connection)
        }
    }

    private func publish(_ messages: [OPNRemoteCoOpWireMessage]) {
        let continuations = lock.withLock { Array(messageContinuations.values) }
        for message in messages {
            for continuation in continuations { continuation.yield(message) }
        }
    }
}

/// A `stateUpdateHandler` can deliver `.ready` and then a later `.failed`; only the first outcome
/// may resume the continuation. Void-only because that is all `connect()` needs, and a generic
/// would make every resume a cross-isolation `sending` question.
private final class OPNContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    /// An outcome that arrived before the continuation did, which the timeout task can do.
    private var pending: Result<Void, Error>?

    init() {}

    func adopt(_ continuation: CheckedContinuation<Void, Error>) {
        let pending = lock.withLock { () -> Result<Void, Error>? in
            guard let pending = self.pending else {
                self.continuation = continuation
                return nil
            }
            self.pending = nil
            return pending
        }
        guard let pending else { return }
        continuation.resume(with: pending)
    }

    func resume(returning value: Void) {
        take(.success(()))?()
    }

    func resume(throwing error: Error) {
        take(.failure(error))?()
    }

    private func take(_ result: Result<Void, Error>) -> (() -> Void)? {
        lock.withLock { () -> (() -> Void)? in
            guard let continuation else {
                if pending == nil { pending = result }
                return nil
            }
            self.continuation = nil
            return { continuation.resume(with: result) }
        }
    }
}
