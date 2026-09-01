import Foundation

public enum OPNRemoteCoOpSignalingEvent: Equatable, Sendable {
    case guestJoinRequested(participantID: UUID, inviteToken: String, displayName: String)
    case guestInput(OPNRemoteCoOpInputPacket)
    /// A guest asking to lower their own stream. Nil clears the request. Never raises past what the
    /// host allowed - the clamp lives in the coordinator, not on the guest's side of the wire.
    case guestQualityRequested(participantID: UUID, preset: OPNRemoteCoOpQualityPreset?)
    case guestDisconnected(UUID)
    case peerSignal(participantID: UUID, signal: OPNRemoteCoOpWirePeerSignal)
    case networkConfiguration(OPNRemoteCoOpNetworkConfiguration)
    /// The signaling channel refused something. Previously dropped on the floor, which made a
    /// refusal indistinguishable from a healthy session: the HUD showed "Invite Ready" while nothing
    /// was listening, and every guest sat waiting for a host that was never going to arrive.
    ///
    /// Named for the broker when a Node process owned signaling. That is gone - this process hosts it
    /// - and the name reached the HUD as user-facing text, so it says what it means now.
    case signalingError(String)
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
    let lock = NSLock()
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
    let signaling: any OPNRemoteCoOpSignalingSession
    /// The last rejection each guest was told about, so a steady stream of identically-rejected
    /// packets is answered once rather than per packet. Cleared when a packet routes, so the next
    /// rejection after a working spell is reported again.
    private var lastReportedInputRejection: [UUID: OPNRemoteCoOpInputRoutingResult] = [:]

    public init(hostSession: OPNRemoteCoOpHostSession, signaling: any OPNRemoteCoOpSignalingSession) {
        self.hostSession = hostSession
        self.signaling = signaling
    }

    public func snapshot() async -> OPNRemoteCoOpHostSnapshot {
        await hostSession.snapshot()
    }

    public func startInvite(inviteID: UUID = UUID(), applicationID: String = "", title: String = "", joinBaseURL: URL? = nil, signalingServerURL: String = "", lifetimeSeconds: TimeInterval = 3_600,
                            hostedSignaling: (@Sendable (UUID, Date) -> OPNRemoteCoOpInviteSignaling?)? = nil) async throws -> OPNRemoteCoOpInvite {
        let invite = try await hostSession.startInvite(inviteID: inviteID, applicationID: applicationID, title: title, joinBaseURL: joinBaseURL, signalingServerURL: signalingServerURL, lifetimeSeconds: lifetimeSeconds, hostedSignaling: hostedSignaling)
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

    public func setQualityPreset(_ preset: OPNRemoteCoOpQualityPreset?, for id: UUID) async throws -> OPNRemoteCoOpParticipant {
        let participant = try await hostSession.setQualityPreset(preset, for: id)
        await signaling.send(.participantUpdated(participant))
        return participant
    }

    public func setGuestRequestedQualityPreset(_ preset: OPNRemoteCoOpQualityPreset?, for id: UUID) async throws -> OPNRemoteCoOpParticipant {
        let participant = try await hostSession.setGuestRequestedQualityPreset(preset, for: id)
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
            if case .routed(let event) = result {
                lastReportedInputRejection[packet.participantID] = nil
                return [event]
            }
            // On transition only.
            //
            // A guest the host has benched stays `.connected`, so its sender keeps forwarding at up
            // to 200 Hz and every packet was refused *and answered*. The reply fans out to every
            // transport in the composite - on the hosted path that is 200 billed Ably publishes a
            // second, enough to hit the per-channel rate limit - and tells the guest nothing it was
            // not told by the first one.
            guard lastReportedInputRejection[packet.participantID] != result else { return [] }
            lastReportedInputRejection[packet.participantID] = result
            await signaling.send(.inputRejected(participantID: packet.participantID, result: result))
            return []
        case .guestQualityRequested(let participantID, let preset):
            // Recorded, not obeyed. `effectiveQualityPreset` takes the lower of this and the host's
            // allowance, so a guest asking for more than they were given simply stays where they are.
            do {
                let participant = try await hostSession.setGuestRequestedQualityPreset(preset, for: participantID)
                await signaling.send(.participantUpdated(participant))
            } catch {
                // Answered with the record as it stands rather than swallowed. Not `guestRejected`:
                // that ejects the guest, and a preset the host would not apply is no reason to end
                // their session - but leaving the request unanswered made a failure look identical
                // to a change that landed.
                if let participant = await hostSession.snapshot().participants.first(where: { $0.id == participantID }) {
                    await signaling.send(.participantUpdated(participant))
                }
            }
            return []
        case .guestDisconnected(let participantID):
            lastReportedInputRejection[participantID] = nil
            // The slot is held rather than released: a dropped socket is usually a blip, and the
            // guest page reconnects with the same participant ID to reclaim it. Neutral pad state
            // still goes out now so nothing stays held during the grace period.
            //
            // No `participantRemoved` either - that tells the guest page it was ejected and stops
            // it reconnecting. `expireDisconnectedParticipants` is what eventually gives up.
            return await hostSession.noteGuestDisconnected(participantID)
        case .peerSignal, .networkConfiguration, .signalingError:
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
