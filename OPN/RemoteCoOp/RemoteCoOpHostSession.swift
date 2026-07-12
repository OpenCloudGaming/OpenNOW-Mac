import Foundation

public enum OPNRemoteCoOpHostSessionError: LocalizedError, Equatable, Sendable {
    case disabled
    case inviteExpired
    case participantNotFound
    case noAvailablePlayerSlots

    public var errorDescription: String? {
        switch self {
        case .disabled: "Remote Co-Op is disabled."
        case .inviteExpired: "Remote Co-Op invite has expired."
        case .participantNotFound: "Remote Co-Op participant was not found."
        case .noAvailablePlayerSlots: "No Remote Co-Op player slots are available."
        }
    }
}

public struct OPNRemoteCoOpHostSnapshot: Equatable, Sendable {
    public var preferences: OPNRemoteCoOpPreferences
    public var invite: OPNRemoteCoOpInvite?
    public var participants: [OPNRemoteCoOpParticipant]

    public init(preferences: OPNRemoteCoOpPreferences,
                invite: OPNRemoteCoOpInvite?,
                participants: [OPNRemoteCoOpParticipant]) {
        self.preferences = preferences
        self.invite = invite
        self.participants = participants
    }

    public var statusText: String {
        guard preferences.isEnabled else { return "Off" }
        if let invite, invite.isExpired { return "Expired" }
        if invite != nil { return participants.isEmpty ? "Inviting" : "Active" }
        return "Ready"
    }

    public var connectedParticipantCount: Int {
        participants.filter { $0.connectionState == .connected }.count
    }
}

public actor OPNRemoteCoOpHostSession {
    private var preferences: OPNRemoteCoOpPreferences
    private var invite: OPNRemoteCoOpInvite?
    private var participants: [OPNRemoteCoOpParticipant] = []
    private let inputRouter = OPNRemoteCoOpInputRouter()

    public init(preferences: OPNRemoteCoOpPreferences = OPNRemoteCoOpPreferencesStore.load()) {
        self.preferences = preferences
    }

    public func updatePreferences(_ preferences: OPNRemoteCoOpPreferences) async {
        self.preferences = preferences
        await inputRouter.replaceParticipants(participants)
    }

    public func snapshot() -> OPNRemoteCoOpHostSnapshot {
        OPNRemoteCoOpHostSnapshot(preferences: preferences, invite: invite, participants: participants.sorted { $0.joinedAt < $1.joinedAt })
    }

    public func startInvite(lifetimeSeconds: TimeInterval = 3_600) throws -> OPNRemoteCoOpInvite {
        guard preferences.isEnabled else { throw OPNRemoteCoOpHostSessionError.disabled }
        guard preferences.effectiveReservedGuestSlots > 0 else { throw OPNRemoteCoOpHostSessionError.noAvailablePlayerSlots }
        let now = Date()
        let invite = OPNRemoteCoOpInvite(code: Self.makeInviteCode(), createdAt: now, expiresAt: now.addingTimeInterval(max(60, lifetimeSeconds)))
        self.invite = invite
        return invite
    }

    public func stopInvite() async -> [UserInputEvent] {
        let neutralEvents = await inputRouter.neutralInputEventsForDisconnectedParticipants()
        invite = nil
        participants.removeAll()
        await inputRouter.replaceParticipants([])
        return neutralEvents
    }

    public func registerGuest(displayName: String, now: Date = Date()) async throws -> OPNRemoteCoOpParticipant {
        guard preferences.isEnabled else { throw OPNRemoteCoOpHostSessionError.disabled }
        guard let invite, invite.expiresAt > now else { throw OPNRemoteCoOpHostSessionError.inviteExpired }
        var participant = OPNRemoteCoOpParticipant(
            displayName: displayName,
            role: .guest,
            connectionState: preferences.requireHostApproval ? .waitingForApproval : .connected,
            inputEnabled: false,
            joinedAt: now,
            lastActivityAt: now
        )
        if !preferences.requireHostApproval {
            participant.playerIndex = try nextAvailablePlayerIndex()
            participant.inputEnabled = true
        }
        participants.append(participant)
        await inputRouter.upsertParticipant(participant)
        return participant
    }

    public func approveParticipant(_ id: UUID) async throws -> OPNRemoteCoOpParticipant {
        guard let index = participants.firstIndex(where: { $0.id == id }) else { throw OPNRemoteCoOpHostSessionError.participantNotFound }
        participants[index].connectionState = .connected
        if participants[index].playerIndex == nil {
            participants[index].playerIndex = try nextAvailablePlayerIndex(excludingParticipantID: id)
        }
        participants[index].inputEnabled = true
        participants[index].lastActivityAt = Date()
        let participant = participants[index]
        await inputRouter.upsertParticipant(participant)
        return participant
    }

    public func setInputEnabled(_ enabled: Bool, for id: UUID) async throws -> OPNRemoteCoOpParticipant {
        guard let index = participants.firstIndex(where: { $0.id == id }) else { throw OPNRemoteCoOpHostSessionError.participantNotFound }
        participants[index].inputEnabled = enabled
        participants[index].lastActivityAt = Date()
        let participant = participants[index]
        await inputRouter.upsertParticipant(participant)
        return participant
    }

    public func removeParticipant(_ id: UUID) async throws -> [UserInputEvent] {
        guard let index = participants.firstIndex(where: { $0.id == id }) else { throw OPNRemoteCoOpHostSessionError.participantNotFound }
        let removed = participants.remove(at: index)
        await inputRouter.removeParticipant(id)
        guard let playerIndex = removed.playerIndex else { return [] }
        return [.gamepad(GamepadState(
            deviceID: InputDeviceID("remote-coop-\(removed.id.uuidString)"),
            playerIndex: playerIndex,
            timestamp: MediaTimestamp(nanoseconds: DispatchTime.now().uptimeNanoseconds)
        ))]
    }

    public func route(_ packet: OPNRemoteCoOpInputPacket, receivedAtNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) async -> OPNRemoteCoOpInputRoutingResult {
        await inputRouter.route(packet, receivedAtNanoseconds: receivedAtNanoseconds)
    }

    private func nextAvailablePlayerIndex(excludingParticipantID: UUID? = nil) throws -> Int {
        let maximumGuestSlots = preferences.effectiveReservedGuestSlots
        guard maximumGuestSlots > 0 else { throw OPNRemoteCoOpHostSessionError.noAvailablePlayerSlots }
        let used = Set(participants.compactMap { participant -> Int? in
            guard participant.id != excludingParticipantID else { return nil }
            return participant.playerIndex
        })
        for playerIndex in 1...min(3, maximumGuestSlots) where !used.contains(playerIndex) {
            return playerIndex
        }
        throw OPNRemoteCoOpHostSessionError.noAvailablePlayerSlots
    }

    private static func makeInviteCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<8).map { _ in alphabet.randomElement(using: &generator) ?? "X" })
    }
}
