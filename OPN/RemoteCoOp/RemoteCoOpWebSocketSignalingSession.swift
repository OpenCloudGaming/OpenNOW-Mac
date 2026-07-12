import Foundation

public final class OPNRemoteCoOpWebSocketSignalingSession: OPNRemoteCoOpSignalingSession, @unchecked Sendable {
    private let serverURL: URL
    private let urlSession: URLSession
    private let lock = NSLock()
    private var eventContinuations: [UUID: AsyncStream<OPNRemoteCoOpSignalingEvent>.Continuation] = [:]
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var roomID: UUID?
    private var isClosed = false

    public init(serverURL: URL, urlSession: URLSession = .shared) {
        self.serverURL = serverURL
        self.urlSession = urlSession
    }

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
        if case .inviteCreated(let invite) = command {
            lock.withLock { roomID = invite.id }
        }
        let currentRoomID = lock.withLock { roomID }
        guard let message = OPNRemoteCoOpWireMessage.message(for: command, roomID: currentRoomID) else { return }
        await send(message)
    }

    public func close() async {
        let state = lock.withLock {
            isClosed = true
            let continuations = Array(eventContinuations.values)
            eventContinuations.removeAll()
            let task = webSocketTask
            webSocketTask = nil
            let receiveTask = receiveTask
            self.receiveTask = nil
            return (continuations, task, receiveTask)
        }
        state.2?.cancel()
        state.1?.cancel(with: .normalClosure, reason: nil)
        for continuation in state.0 { continuation.finish() }
    }

    private func send(_ message: OPNRemoteCoOpWireMessage) async {
        do {
            let task = try await connectedTask()
            try await task.send(.string(OPNRemoteCoOpWireCodec.encode(message)))
        } catch {
            await close()
        }
    }

    private func connectedTask() async throws -> URLSessionWebSocketTask {
        if let task = lock.withLock({ webSocketTask }), task.state == .running { return task }
        let task = urlSession.webSocketTask(with: serverURL)
        lock.withLock {
            webSocketTask = task
            isClosed = false
        }
        task.resume()
        startReceiveLoop(task)
        return task
    }

    private func startReceiveLoop(_ task: URLSessionWebSocketTask) {
        let loop = Task { [weak self, weak task] in
            while !Task.isCancelled {
                guard let self, let task else { return }
                do {
                    let message = try await task.receive()
                    await self.handle(message)
                } catch {
                    await self.close()
                    return
                }
            }
        }
        lock.withLock {
            receiveTask?.cancel()
            receiveTask = loop
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) async {
        let wireMessage: OPNRemoteCoOpWireMessage?
        switch message {
        case .string(let text):
            wireMessage = try? OPNRemoteCoOpWireCodec.decode(text)
        case .data(let data):
            wireMessage = try? OPNRemoteCoOpWireCodec.decode(data)
        @unknown default:
            wireMessage = nil
        }
        guard let wireMessage else { return }
        if wireMessage.kind == .heartbeat {
            await send(OPNRemoteCoOpWireMessage(kind: .heartbeat, roomID: wireMessage.roomID))
            return
        }
        guard let event = wireMessage.signalingEvent() else { return }
        yield(event)
    }

    private func yield(_ event: OPNRemoteCoOpSignalingEvent) {
        let continuations = lock.withLock { isClosed ? [] : Array(eventContinuations.values) }
        for continuation in continuations { continuation.yield(event) }
    }
}
