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
    /// Player indices occupied by controllers plugged into the host, kept current by the caller
    /// (`syncRemoteCoOpGamepadTopology` / the WebRTC surface) whenever the local topology changes.
    ///
    /// A guest's slot is assigned from the same 4-pad space the seat gives local controllers, and
    /// the two were assigned independently: a single local pad sits on index 0 and a guest took 1,
    /// which never collided, but a *second* local controller also lands on index 1 - the first
    /// index `NativeWebRTCGamepadMonitor.update` hands out to a newly connected pad. Approving a
    /// guest at that point silently doubled up the local player's controller and the guest's,
    /// because both `NvstGamepadPacket` and the WebRTC path's `controllerId` key on the index alone
    /// with no notion of "already spoken for by someone else."
    private var reservedLocalPlayerIndices: Set<Int> = []
    private let inviteSigner: OPNRemoteCoOpInviteTokenSigner
    private let inputRouter = OPNRemoteCoOpInputRouter()

    public init(preferences: OPNRemoteCoOpPreferences = OPNRemoteCoOpPreferencesStore.load(), inviteSigner: OPNRemoteCoOpInviteTokenSigner = OPNRemoteCoOpInviteTokenSigner.perSession()) {
        self.preferences = preferences
        self.inviteSigner = inviteSigner
    }

    public func updatePreferences(_ preferences: OPNRemoteCoOpPreferences) async {
        self.preferences = preferences
        await inputRouter.replaceParticipants(participants)
    }

    /// Tells the session which indices a local controller already holds, so a guest is never handed
    /// one of them. Safe to call at any point in the session's life, including before an invite
    /// exists or after guests are already connected - it only changes what the *next* assignment
    /// avoids, never an index already given out.
    public func updateReservedLocalPlayerIndices(_ indices: Set<Int>) {
        reservedLocalPlayerIndices = indices
    }

    public func snapshot() -> OPNRemoteCoOpHostSnapshot {
        OPNRemoteCoOpHostSnapshot(preferences: preferences, invite: invite, participants: participants.sorted { $0.joinedAt < $1.joinedAt })
    }

    public func startInvite(applicationID: String = "", title: String = "", joinBaseURL: URL? = nil, signalingServerURL: String = "", lifetimeSeconds: TimeInterval = 3_600) throws -> OPNRemoteCoOpInvite {
        guard preferences.isAvailable else { throw OPNRemoteCoOpHostSessionError.disabled }
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
            joinURL: Self.joinURL(baseURL: joinBaseURL, token: token, signalingServerURL: signalingServerURL),
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

    /// How long a slot is held for a guest whose socket dropped.
    ///
    /// A Wi-Fi roam or a sleeping laptop closes the WebSocket in well under a second, and releasing
    /// the slot immediately meant the guest came back as a stranger needing fresh approval - or
    /// found the slot gone entirely. Long enough to ride out a blip, short enough that a guest who
    /// actually left frees the slot while the host is still in the same game.
    public static let disconnectGraceSeconds: TimeInterval = 45

    public func registerGuest(displayName: String, inviteToken: String, participantID: UUID = UUID(), now: Date = Date()) async throws -> OPNRemoteCoOpParticipant {
        guard preferences.isAvailable else { throw OPNRemoteCoOpHostSessionError.disabled }
        guard let invite, invite.expiresAt > now else { throw OPNRemoteCoOpHostSessionError.inviteExpired }
        try validate(inviteToken: inviteToken, expectedInvite: invite, now: now)
        removeStaleDisconnectedParticipants(now: now)
        // A returning guest keeps the identity, the slot and the approval it already had. The guest
        // page reuses its participant ID across a reconnect precisely so this can happen.
        if let index = participants.firstIndex(where: { $0.id == participantID }) {
            if participants[index].connectionState == .disconnected {
                // Approval survives, so an approved guest resumes playing rather than queueing for
                // the host again. Input is re-enabled only if it was enabled before.
                participants[index].connectionState = participants[index].playerIndex == nil ? .waitingForApproval : .connected
                participants[index].inputEnabled = participants[index].playerIndex != nil
                participants[index].lastActivityAt = now
                let restored = participants[index]
                await inputRouter.upsertParticipant(restored)
                return restored
            }
            return participants[index]
        }
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

    /// Marks a guest's socket as gone while keeping their slot reserved, and returns the neutral pad
    /// states the caller must deliver.
    ///
    /// Neutral state goes out immediately even though the slot is held: whatever the guest was
    /// holding when their connection dropped would otherwise stay pressed in the game for the whole
    /// grace period.
    public func noteGuestDisconnected(_ id: UUID, now: Date = Date()) async -> [UserInputEvent] {
        guard let index = participants.firstIndex(where: { $0.id == id }) else { return [] }
        guard participants[index].connectionState != .disconnected else { return [] }
        participants[index].connectionState = .disconnected
        participants[index].inputEnabled = false
        participants[index].lastActivityAt = now
        let participant = participants[index]
        await inputRouter.upsertParticipant(participant)
        guard let playerIndex = participant.playerIndex else { return [] }
        return [.gamepad(GamepadState(
            deviceID: InputDeviceID("remote-coop-\(participant.id.uuidString)"),
            playerIndex: playerIndex,
            timestamp: MediaTimestamp(nanoseconds: DispatchTime.now().uptimeNanoseconds)
        ))]
    }

    /// Releases slots held for guests who never came back. Returns the participants dropped so the
    /// caller can re-announce the gamepad topology.
    @discardableResult
    public func expireDisconnectedParticipants(now: Date = Date()) async -> [OPNRemoteCoOpParticipant] {
        let expired = staleDisconnectedParticipants(now: now)
        guard !expired.isEmpty else { return [] }
        removeStaleDisconnectedParticipants(now: now)
        for participant in expired { await inputRouter.removeParticipant(participant.id) }
        return expired
    }

    private func staleDisconnectedParticipants(now: Date) -> [OPNRemoteCoOpParticipant] {
        participants.filter {
            $0.connectionState == .disconnected && now.timeIntervalSince($0.lastActivityAt) >= Self.disconnectGraceSeconds
        }
    }

    private func removeStaleDisconnectedParticipants(now: Date) {
        let stale = Set(staleDisconnectedParticipants(now: now).map(\.id))
        guard !stale.isEmpty else { return }
        participants.removeAll { stale.contains($0.id) }
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
        }).union(reservedLocalPlayerIndices)
        // 1...3 on the assumption that index 0 is the host: reserved controller slots are
        // advertised to GeForce NOW before launch specifically so the seat sets aside a pad the
        // host is not already using. A guest can still land on 1, 2 or 3 if a local controller is
        // occupying one of them - `used` is what actually decides, this range is only the ceiling.
        for playerIndex in 1...min(3, maximumGuestSlots) where !used.contains(playerIndex) {
            return playerIndex
        }
        throw OPNRemoteCoOpHostSessionError.noAvailablePlayerSlots
    }

    /// Every guest must present a token this host signed.
    ///
    /// There used to be an escape here that accepted a bare six-character code and skipped the
    /// signature check entirely, added when invite links carried only the code. Links now carry the
    /// full signed token, and the broker never accepted a bare code anyway - its own verifier
    /// requires two dot-separated segments - so the escape only ever widened what the host would
    /// take: roughly a billion guesses against a code that is also printed in the HUD, versus an
    /// HMAC.
    private func validate(inviteToken: String, expectedInvite: OPNRemoteCoOpInvite, now: Date) throws {
        do {
            let payload = try inviteSigner.verify(inviteToken, now: now)
            guard payload.inviteID == expectedInvite.id, payload.code == expectedInvite.code else { throw OPNRemoteCoOpHostSessionError.invalidInviteToken }
        } catch let error as OPNRemoteCoOpHostSessionError {
            throw error
        } catch {
            throw OPNRemoteCoOpHostSessionError.invalidInviteToken
        }
    }

    /// The link a guest opens.
    ///
    /// `invite` carries the **signed token**, not the six-character code. The broker verifies the
    /// signature before it will put a guest in a room, and a bare code cannot verify: its
    /// `verifyInviteToken` requires two dot-separated segments and returns nil for anything else,
    /// so the room lookup that would have accepted a code sits behind a gate the code can never
    /// pass. Links carrying only the code were therefore rejected by every broker, which looked
    /// from the host like a guest that joined and then waited forever.
    ///
    /// The guest page handles this: a token in the URL is parsed for its payload, and the input
    /// normalisation that would uppercase it (and corrupt the base64url) is skipped for values that
    /// came from the query string. The short code is still what it displays.
    private static func joinURL(baseURL: URL?, token: String, signalingServerURL: String) -> URL? {
        guard let baseURL else { return nil }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSignalingServerURL = signalingServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var items = components?.queryItems ?? []
        items.removeAll { $0.name == "invite" }
        items.removeAll { $0.name == "server" }
        items.append(URLQueryItem(name: "invite", value: trimmedToken))
        if Self.shouldAppendSignalingServer(baseURL: baseURL, signalingServerURL: trimmedSignalingServerURL) {
            items.append(URLQueryItem(name: "server", value: trimmedSignalingServerURL))
        }
        components?.queryItems = items.isEmpty ? nil : items
        return components?.url
    }

    private static func shouldAppendSignalingServer(baseURL: URL, signalingServerURL: String) -> Bool {
        guard !signalingServerURL.isEmpty else { return false }
        guard let signalingURL = URL(string: signalingServerURL), signalingURL.scheme?.hasPrefix("ws") == true else { return true }
        guard let baseHost = baseURL.host?.lowercased(), let signalingHost = signalingURL.host?.lowercased(), baseHost == signalingHost else { return true }
        let expectedScheme = baseURL.scheme == "https" ? "wss" : "ws"
        guard signalingURL.scheme == expectedScheme else { return true }
        guard Self.effectivePort(baseURL) == Self.effectivePort(signalingURL) else { return true }
        return signalingURL.path != "/remote-coop"
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme {
        case "http", "ws": return 80
        case "https", "wss": return 443
        default: return nil
        }
    }

    private static func makeInviteCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<6).map { _ in alphabet.randomElement(using: &generator) ?? "X" })
    }
}
