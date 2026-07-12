import Foundation

public enum OPNRemoteCoOpSignalingEvent: Equatable, Sendable {
    case guestJoinRequested(participantID: UUID, inviteToken: String, displayName: String)
    case guestInput(OPNRemoteCoOpInputPacket)
    case guestDisconnected(UUID)
    case peerSignal(participantID: UUID, signal: OPNRemoteCoOpWirePeerSignal)
}

public enum OPNRemoteCoOpSignalingCommand: Equatable, Sendable {
    case inviteCreated(OPNRemoteCoOpInvite)
    case inviteEnded
    case participantUpdated(OPNRemoteCoOpParticipant)
    case participantRemoved(UUID)
    case guestRejected(participantID: UUID, reason: String)
    case inputRejected(participantID: UUID, result: OPNRemoteCoOpInputRoutingResult)
    case peerSignal(participantID: UUID, signal: OPNRemoteCoOpWirePeerSignal)
}

public protocol OPNRemoteCoOpSignalingSession: Sendable {
    func events() -> AsyncStream<OPNRemoteCoOpSignalingEvent>
    func send(_ command: OPNRemoteCoOpSignalingCommand) async
    func close() async
}

public final class OPNInProcessRemoteCoOpSignalingSession: OPNRemoteCoOpSignalingSession, @unchecked Sendable {
    private let lock = NSLock()
    private var eventContinuations: [UUID: AsyncStream<OPNRemoteCoOpSignalingEvent>.Continuation] = [:]
    private var commandContinuations: [UUID: AsyncStream<OPNRemoteCoOpSignalingCommand>.Continuation] = [:]
    private var sentCommands: [OPNRemoteCoOpSignalingCommand] = []
    private var isClosed = false

    public init() {}

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

    public func commands() -> AsyncStream<OPNRemoteCoOpSignalingCommand> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(240)) { continuation in
            lock.withLock {
                if isClosed {
                    continuation.finish()
                } else {
                    commandContinuations[id] = continuation
                }
            }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { self?.commandContinuations[id] = nil }
            }
        }
    }

    public func publish(_ event: OPNRemoteCoOpSignalingEvent) {
        let continuations = lock.withLock { isClosed ? [] : Array(eventContinuations.values) }
        for continuation in continuations { continuation.yield(event) }
    }

    public func commandHistory() -> [OPNRemoteCoOpSignalingCommand] {
        lock.withLock { sentCommands }
    }

    public func send(_ command: OPNRemoteCoOpSignalingCommand) async {
        let continuations: [AsyncStream<OPNRemoteCoOpSignalingCommand>.Continuation] = lock.withLock {
            guard !isClosed else { return [] }
            sentCommands.append(command)
            return Array(commandContinuations.values)
        }
        for continuation in continuations { continuation.yield(command) }
    }

    public func close() async {
        let continuations = lock.withLock {
            isClosed = true
            let continuations = (Array(eventContinuations.values), Array(commandContinuations.values))
            eventContinuations.removeAll()
            commandContinuations.removeAll()
            sentCommands.removeAll()
            return continuations
        }
        for continuation in continuations.0 { continuation.finish() }
        for continuation in continuations.1 { continuation.finish() }
    }
}

public actor OPNRemoteCoOpHostCoordinator {
    private let hostSession: OPNRemoteCoOpHostSession
    private let signaling: any OPNRemoteCoOpSignalingSession

    public init(hostSession: OPNRemoteCoOpHostSession, signaling: any OPNRemoteCoOpSignalingSession) {
        self.hostSession = hostSession
        self.signaling = signaling
    }

    public func snapshot() async -> OPNRemoteCoOpHostSnapshot {
        await hostSession.snapshot()
    }

    public func startInvite(applicationID: String = "", title: String = "", joinBaseURL: URL? = nil, signalingServerURL: String = "", lifetimeSeconds: TimeInterval = 3_600) async throws -> OPNRemoteCoOpInvite {
        let invite = try await hostSession.startInvite(applicationID: applicationID, title: title, joinBaseURL: joinBaseURL, signalingServerURL: signalingServerURL, lifetimeSeconds: lifetimeSeconds)
        await signaling.send(.inviteCreated(invite))
        return invite
    }

    public func stopInvite() async -> [UserInputEvent] {
        let events = await hostSession.stopInvite()
        await signaling.send(.inviteEnded)
        return events
    }

    public func approveParticipant(_ id: UUID) async throws -> OPNRemoteCoOpParticipant {
        let participant = try await hostSession.approveParticipant(id)
        await signaling.send(.participantUpdated(participant))
        return participant
    }

    public func setInputEnabled(_ enabled: Bool, for id: UUID) async throws -> OPNRemoteCoOpParticipant {
        let participant = try await hostSession.setInputEnabled(enabled, for: id)
        await signaling.send(.participantUpdated(participant))
        return participant
    }

    public func removeParticipant(_ id: UUID) async throws -> [UserInputEvent] {
        let events = try await hostSession.removeParticipant(id)
        await signaling.send(.participantRemoved(id))
        return events
    }

    public func handle(_ event: OPNRemoteCoOpSignalingEvent) async -> [UserInputEvent] {
        switch event {
        case .guestJoinRequested(let participantID, let inviteToken, let displayName):
            do {
                let participant = try await hostSession.registerGuest(displayName: displayName, inviteToken: inviteToken, participantID: participantID)
                await signaling.send(.participantUpdated(participant))
            } catch {
                await signaling.send(.guestRejected(participantID: participantID, reason: Self.message(for: error)))
            }
            return []
        case .guestInput(let packet):
            let result = await hostSession.route(packet)
            if case .routed(let event) = result { return [event] }
            await signaling.send(.inputRejected(participantID: packet.participantID, result: result))
            return []
        case .guestDisconnected(let participantID):
            do {
                let events = try await hostSession.removeParticipant(participantID)
                await signaling.send(.participantRemoved(participantID))
                return events
            } catch {
                await signaling.send(.guestRejected(participantID: participantID, reason: Self.message(for: error)))
                return []
            }
        case .peerSignal:
            return []
        }
    }

    public func listen(forwardInput: @escaping @Sendable (UserInputEvent) async -> Void) -> Task<Void, Never> {
        Task {
            for await event in signaling.events() {
                let routedEvents = await handle(event)
                for routedEvent in routedEvents { await forwardInput(routedEvent) }
            }
        }
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription, !description.isEmpty { return description }
        return error.localizedDescription
    }
}
