import Foundation

public enum OPNRemoteCoOpHostSessionError: LocalizedError, Equatable, Sendable {
    case disabled
    case inviteExpired
    case invalidInviteToken
    case participantNotFound
    case noAvailablePlayerSlots

    public var errorDescription: String? {
        switch self {
        case .disabled: "Remote Co-Op is disabled."
        case .inviteExpired: "Remote Co-Op invite has expired."
        case .invalidInviteToken: "Remote Co-Op invite token is invalid."
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
    private let inviteSigner: OPNRemoteCoOpInviteTokenSigner
    private let inputRouter = OPNRemoteCoOpInputRouter()

    public init(preferences: OPNRemoteCoOpPreferences = OPNRemoteCoOpPreferencesStore.load(), inviteSigner: OPNRemoteCoOpInviteTokenSigner = OPNRemoteCoOpInviteTokenSigner()) {
        self.preferences = preferences
        self.inviteSigner = inviteSigner
    }

    public func updatePreferences(_ preferences: OPNRemoteCoOpPreferences) async {
        self.preferences = preferences
        await inputRouter.replaceParticipants(participants)
    }

    public func snapshot() -> OPNRemoteCoOpHostSnapshot {
        OPNRemoteCoOpHostSnapshot(preferences: preferences, invite: invite, participants: participants.sorted { $0.joinedAt < $1.joinedAt })
    }

    public func startInvite(applicationID: String = "", title: String = "", joinBaseURL: URL? = nil, signalingServerURL: String = "", lifetimeSeconds: TimeInterval = 3_600) throws -> OPNRemoteCoOpInvite {
        guard preferences.isEnabled else { throw OPNRemoteCoOpHostSessionError.disabled }
        guard preferences.effectiveReservedGuestSlots > 0 else { throw OPNRemoteCoOpHostSessionError.noAvailablePlayerSlots }
        let now = Date()
        let inviteID = UUID()
        let code = Self.makeInviteCode()
        let expiresAt = now.addingTimeInterval(max(60, lifetimeSeconds))
        let payload = OPNRemoteCoOpInviteTokenPayload(
            inviteID: inviteID,
            code: code,
            applicationID: applicationID,
            title: title,
            createdAt: now,
            expiresAt: expiresAt,
            preferences: preferences
        )
        let token = try inviteSigner.token(for: payload)
        let invite = OPNRemoteCoOpInvite(
            id: inviteID,
            code: code,
            createdAt: now,
            expiresAt: expiresAt,
            token: token,
            joinURL: Self.joinURL(baseURL: joinBaseURL, code: code, signalingServerURL: signalingServerURL),
            applicationID: applicationID,
            title: title,
            hideGuestInviteDetails: preferences.hideGuestInviteDetails
        )
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

    public func registerGuest(displayName: String, inviteToken: String, participantID: UUID = UUID(), now: Date = Date()) async throws -> OPNRemoteCoOpParticipant {
        guard preferences.isEnabled else { throw OPNRemoteCoOpHostSessionError.disabled }
        guard let invite, invite.expiresAt > now else { throw OPNRemoteCoOpHostSessionError.inviteExpired }
        try validate(inviteToken: inviteToken, expectedInvite: invite, now: now)
        if let existing = participants.first(where: { $0.id == participantID }) { return existing }
        guard participants.count < preferences.effectiveReservedGuestSlots else { throw OPNRemoteCoOpHostSessionError.noAvailablePlayerSlots }
        var participant = OPNRemoteCoOpParticipant(
            id: participantID,
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

    private func validate(inviteToken: String, expectedInvite: OPNRemoteCoOpInvite, now: Date) throws {
        do {
            if inviteToken == expectedInvite.code { return }
            let payload = try inviteSigner.verify(inviteToken, now: now)
            guard payload.inviteID == expectedInvite.id, payload.code == expectedInvite.code else { throw OPNRemoteCoOpHostSessionError.invalidInviteToken }
        } catch let error as OPNRemoteCoOpHostSessionError {
            throw error
        } catch {
            throw OPNRemoteCoOpHostSessionError.invalidInviteToken
        }
    }

    private static func joinURL(baseURL: URL?, code: String, signalingServerURL: String) -> URL? {
        guard let baseURL else { return nil }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let trimmedCode = String(code.trimmingCharacters(in: .whitespacesAndNewlines).prefix(6))
        var items = components?.queryItems ?? []
        items.removeAll { $0.name == "invite" }
        items.removeAll { $0.name == "server" }
        items.append(URLQueryItem(name: "invite", value: trimmedCode))
        if !signalingServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(URLQueryItem(name: "server", value: signalingServerURL))
        }
        components?.queryItems = items.isEmpty ? nil : items
        return components?.url
    }

    private static func makeInviteCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<6).map { _ in alphabet.randomElement(using: &generator) ?? "X" })
    }
}
