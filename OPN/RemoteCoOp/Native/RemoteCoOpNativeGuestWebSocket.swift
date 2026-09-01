//
//  RemoteCoOpNativeGuestWebSocket.swift
//  OpenNOW
//
//  Lets a guest running OpenNOW join over the same WebSocket a browser guest uses.
//
//  Tunnels forward HTTP and point at the embedded server on 32188, not the native listener's raw TCP
//  on 32189 - so a tunnelled host was reachable by browsers only. Rather than tunnel a second port,
//  the guest speaks the transport the tunnel already carries; the wire protocol above it is identical.
//
//  One asymmetry: the native listener greets with `hostHello` carrying the invite, and this one does
//  not (a browser reads the token from its own URL), so the token must come from the link.
//

import Foundation

public struct OPNRemoteCoOpGuestInviteLink: Equatable, Sendable {
    /// The `wss://…/remote-coop` socket to open.
    public let signalingURL: URL
    /// The signed invite token, presented in the join request.
    public let token: String

    /// Parses `https://<host>/?invite=<token>[&server=<wss url>]`. `server` wins when present: the page
    /// and the socket need not share an origin, though a tunnel serves both from one hostname.
    public init?(link: String) {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return nil }
        // TLS only. A link carries the signed invite token in its query string, so accepting
        // `http`/`ws` handed that token - and every keystroke of gameplay input after it - to
        // anything on the path. The host never mints a plaintext link; one arriving is not the
        // host's.
        guard ["https", "wss"].contains(scheme) else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        let token = queryItems.first { $0.name == "invite" }?.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else { return nil }
        self.token = token

        if let server = queryItems.first(where: { $0.name == "server" })?.value,
           let serverURL = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines)),
           serverURL.scheme?.lowercased() == "wss" {
            signalingURL = serverURL
            return
        }
        guard let derived = Self.signalingURL(fromPageURL: url) else { return nil }
        signalingURL = derived
    }

    /// `https://host[:port]/anything` -> `wss://host[:port]/remote-coop`.
    static func signalingURL(fromPageURL url: URL) -> URL? {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        switch components?.scheme?.lowercased() {
        case "https", "wss": components?.scheme = "wss"
        default: return nil
        }
        components?.path = "/remote-coop"
        components?.query = nil
        components?.fragment = nil
        return components?.url
    }
}

/// Both ways a native guest can reach a host, so the message pump does not care which it got.
public protocol OPNRemoteCoOpNativeGuestTransport: Sendable {
    func connect() async throws
    func messages() -> AsyncStream<OPNRemoteCoOpWireMessage>
    func send(_ message: OPNRemoteCoOpWireMessage) async throws
    func close()
}

extension OPNRemoteCoOpNativeGuestConnection: OPNRemoteCoOpNativeGuestTransport {}

/// TLS is validated normally, deliberately: this exists for the tunnel case, where the certificate is
/// real and the guest has no prior relationship with the host to pin against. A LAN host's self-signed
/// certificate correctly fails here - that guest has Bonjour and the raw listener.
public final class OPNRemoteCoOpNativeGuestWebSocketConnection: OPNRemoteCoOpNativeGuestTransport, @unchecked Sendable {
    private let url: URL
    private let makeSession: @Sendable (URLSessionConfiguration) -> URLSession
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var messageContinuations: [UUID: AsyncStream<OPNRemoteCoOpWireMessage>.Continuation] = [:]
    private var isClosed = false

    /// `makeSession` is a test-only seam for reaching a self-signed server. Production never passes it.
    public init(signalingURL: URL, makeSession: (@Sendable (URLSessionConfiguration) -> URLSession)? = nil) {
        url = signalingURL
        self.makeSession = makeSession ?? { URLSession(configuration: $0) }
    }

    public func connect() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        // A guest waiting for approval is quiet, not idle; the socket must not be reaped for it.
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = .greatestFiniteMagnitude
        let session = makeSession(configuration)
        let task = session.webSocketTask(with: url)
        lock.withLock {
            self.session = session
            self.task = task
        }
        task.resume()
        receive(on: task)
        // `resume()` does not wait for the upgrade and there is no callback for it without a task
        // delegate; a ping completes only once the socket is open.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = OPNRemoteCoOpWebSocketContinuationBox(continuation)
            task.sendPing { error in
                if let error {
                    box.resume(throwing: OPNRemoteCoOpNativeConnectionError.connectFailed(error.localizedDescription))
                } else {
                    box.resume(returning: ())
                }
            }
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
        guard let task = lock.withLock({ self.task }) else { throw OPNRemoteCoOpNativeConnectionError.closed }
        let text = try OPNRemoteCoOpWireCodec.encode(message)
        // Boxed for the same reason `sendPing` is: the completion can fire more than once across a
        // cancellation, and `close()` cancels the task with `.goingAway` while a peer signal may
        // still be in flight. A continuation resumed twice is not an error to handle, it is a trap.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = OPNRemoteCoOpWebSocketContinuationBox(continuation)
            task.send(.string(text)) { error in
                if let error {
                    box.resume(throwing: OPNRemoteCoOpNativeConnectionError.connectFailed(error.localizedDescription))
                } else {
                    box.resume(returning: ())
                }
            }
        }
    }

    public func close() {
        let state = lock.withLock { () -> (URLSessionWebSocketTask?, URLSession?, [AsyncStream<OPNRemoteCoOpWireMessage>.Continuation]) in
            guard !isClosed else { return (nil, nil, []) }
            isClosed = true
            let task = self.task
            let session = self.session
            let continuations = Array(messageContinuations.values)
            self.task = nil
            self.session = nil
            messageContinuations.removeAll()
            return (task, session, continuations)
        }
        state.0?.cancel(with: .goingAway, reason: nil)
        // An uninvalidated `URLSession` leaks itself and its delegate; finished rather than invalidated
        // so the cancel above flushes.
        state.1?.finishTasksAndInvalidate()
        for continuation in state.2 { continuation.finish() }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    publish(text)
                case .data(let data):
                    publish(String(decoding: data, as: UTF8.self))
                @unknown default:
                    break
                }
                guard !lock.withLock({ isClosed }) else { return }
                receive(on: task)
            case .failure:
                close()
            }
        }
    }

    /// Undecodable frames are skipped: the server may add kinds this build does not know.
    private func publish(_ text: String) {
        guard let message = try? OPNRemoteCoOpWireCodec.decode(text) else { return }
        let continuations = lock.withLock { Array(messageContinuations.values) }
        for continuation in continuations { continuation.yield(message) }
    }
}

/// `sendPing`'s completion can fire more than once across cancellation; a continuation may not.
private final class OPNRemoteCoOpWebSocketContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Void) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let continuation = self.continuation
        self.continuation = nil
        return continuation
    }
}
