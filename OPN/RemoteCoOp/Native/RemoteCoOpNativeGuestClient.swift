//  The guest half of native Remote Co-Op: find hosts on the local network (or a shared VPN)
//  with Bonjour, then speak the browser's wire protocol over a plain TCP socket.
//

import Foundation
import Network
import Security

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

    /// A host resolved from Bonjour to a concrete address, keeping the service's friendly name.
    ///
    /// The identity is the service name, not the address, so a host that changes IP keeps a stable key
    /// for the pinned certificate and reconnect token.
    public init(endpoint: NWEndpoint, serviceName: String) {
        self.endpoint = endpoint
        self.name = serviceName
        self.id = "bonjour-\(serviceName)"
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
        guard let parsed = Self.parseAddress(trimmed) else { return nil }
        guard let port = NWEndpoint.Port(rawValue: parsed.port) else { return nil }
        endpoint = .hostPort(host: NWEndpoint.Host(parsed.host), port: port)
        name = parsed.port == OPNRemoteCoOpNativeGuestServer.defaultPort ? parsed.host : "\(parsed.host):\(parsed.port)"
        id = "manual-\(parsed.host):\(parsed.port)"
    }

    /// Splits `host`, `host:port`, `[v6]` and `[v6]:port`. Bracket form is required for a port on an
    /// IPv6 literal, because a bare `fd00::1:32189` is ambiguous - the last group could be either.
    static func parseAddress(_ address: String) -> (host: String, port: UInt16)? {
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

public final class OPNRemoteCoOpNativeHostBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var serviceBrowser: NetServiceBrowser?
    private var resolving: [String: NetService] = [:]
    private var hosts: [String: OPNRemoteCoOpNativeDiscoveredHost] = [:]
    public var onUpdate: (@Sendable ([OPNRemoteCoOpNativeDiscoveredHost]) -> Void)?

    public override init() { super.init() }

    public func start() {
        stop()
        let browser = NetServiceBrowser()
        browser.delegate = self
        lock.withLock { serviceBrowser = browser }
        browser.schedule(in: .main, forMode: .common)
        browser.searchForServices(ofType: OPNRemoteCoOpNativeGuestServer.serviceType + ".", inDomain: "local.")
    }

    public func stop() {
        let browser = lock.withLock { () -> NetServiceBrowser? in
            let browser = serviceBrowser
            serviceBrowser = nil
            return browser
        }
        browser?.delegate = nil
        browser?.stop()
        lock.withLock {
            for service in resolving.values {
                service.delegate = nil
                service.stop()
            }
            resolving.removeAll()
            hosts.removeAll()
        }
    }

    // MARK: - NetServiceBrowserDelegate

    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        service.schedule(in: .main, forMode: .common)
        lock.withLock { resolving[service.name] = service }
        service.resolve(withTimeout: 5)
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        lock.withLock {
            resolving[service.name]?.delegate = nil
            resolving[service.name] = nil
            hosts[service.name] = nil
        }
        publish()
    }

    // MARK: - NetServiceDelegate

    /// Resolving returns the host's addresses and port directly, which is what lets a guest on the
    /// host's own Mac connect: the `.local` name never has to be resolved by the connecting socket.
    public func netServiceDidResolveAddress(_ sender: NetService) {
        guard let address = Self.ipv4Address(of: sender),
              let port = NWEndpoint.Port(rawValue: UInt16(truncatingIfNeeded: sender.port)) else { return }
        let host = OPNRemoteCoOpNativeDiscoveredHost(endpoint: .hostPort(host: NWEndpoint.Host(address), port: port),
                                                     serviceName: sender.name)
        lock.withLock { hosts[sender.name] = host }
        publish()
    }

    public func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        lock.withLock { resolving[sender.name] = nil }
    }

    private func publish() {
        let current = lock.withLock { Array(hosts.values) }.sorted { $0.name < $1.name }
        onUpdate?(current)
    }

    /// The first IPv4 address the service resolved to, as a dotted string.
    static func ipv4Address(of service: NetService) -> String? {
        guard let addresses = service.addresses else { return nil }
        for data in addresses {
            let family = data.withUnsafeBytes { $0.load(as: sockaddr.self).sa_family }
            guard family == sa_family_t(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = data.withUnsafeBytes { raw -> Int32 in
                guard let base = raw.bindMemory(to: sockaddr.self).baseAddress else { return -1 }
                return getnameinfo(base, socklen_t(data.count), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            }
            guard result == 0 else { continue }
            let bytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            return String(decoding: bytes, as: UTF8.self)
        }
        return nil
    }
}

public enum OPNRemoteCoOpNativeConnectionError: LocalizedError, Equatable, Sendable {
    case connectFailed(String)
    case closed
    /// The media peer connection went away while the signaling socket was still open — a host that
    /// slept or lost its network without closing anything.
    case peerConnectionLost(String)

    public var errorDescription: String? {
        switch self {
        case .connectFailed(let message): message
        case .closed: "The connection to the Remote Co-Op host closed."
        case .peerConnectionLost(let reason): reason
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

    /// Resolves once the TLS socket is ready to use, returning the host's certificate fingerprint.
    ///
    /// `expectedFingerprint` pins the connection to a previously seen certificate. When nil, the
    /// connection uses trust-on-first-use and the caller is responsible for remembering the
    /// returned fingerprint for the next connection. A mismatch is reported as a connection
    /// failure so the caller can warn the user rather than silently accepting a different host.
    public func connect(expectedFingerprint: String? = nil) async throws -> String {
        let fingerprintBox = FingerprintBox()
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { metadata, _, completion in
            let fingerprint = Self.fingerprint(from: metadata)
            fingerprintBox.set(fingerprint)
            if let expectedFingerprint {
                completion(fingerprint == expectedFingerprint)
            } else {
                completion(true)
            }
        }, DispatchQueue.global())
        let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        let connection = NWConnection(to: endpoint, using: parameters)
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
        return fingerprintBox.get() ?? ""
    }

    private static func fingerprint(from metadata: sec_protocol_metadata_t) -> String {
        let box = FingerprintBox()
        sec_protocol_metadata_access_peer_certificate_chain(metadata) { certificate in
            guard box.get() == nil else { return }
            let secCertificate = sec_certificate_copy_ref(certificate).takeRetainedValue()
            let data = SecCertificateCopyData(secCertificate) as Data
            box.set(OPNRemoteCoOpSHA256Fingerprint.hex(of: data))
        }
        return box.get() ?? ""
    }

    private final class FingerprintBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        func set(_ value: String) {
            lock.lock()
            self.value = value
            lock.unlock()
        }
        func get() -> String? {
            lock.lock()
            defer { lock.unlock() }
            return value
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
