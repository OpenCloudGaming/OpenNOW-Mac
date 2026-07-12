import Foundation

public enum OPNRemoteCoOpWireMessageKind: String, Codable, Equatable, Sendable {
    case hostHello
    case inviteEnded
    case participantUpdated
    case participantRemoved
    case guestRejected
    case inputRejected
    case guestJoinRequested
    case guestInput
    case guestDisconnected
    case heartbeat
    case peerSignal
    case networkConfiguration
    case error
}

public enum OPNRemoteCoOpWireInputRoutingRejection: String, Codable, Equatable, Sendable {
    case participantNotFound
    case inputDisabled
    case stalePacket
    case invalidPlayerSlot

    public init?(_ result: OPNRemoteCoOpInputRoutingResult) {
        switch result {
        case .routed:
            return nil
        case .participantNotFound:
            self = .participantNotFound
        case .inputDisabled:
            self = .inputDisabled
        case .stalePacket:
            self = .stalePacket
        case .invalidPlayerSlot:
            self = .invalidPlayerSlot
        }
    }
}

public enum OPNRemoteCoOpWirePeerSignalKind: String, Codable, Equatable, Sendable {
    case offer
    case answer
    case iceCandidate
}

public struct OPNRemoteCoOpWirePeerSignal: Codable, Equatable, Sendable {
    public var kind: OPNRemoteCoOpWirePeerSignalKind
    public var sdp: String?
    public var candidate: String?
    public var sdpMid: String?
    public var sdpMLineIndex: Int?

    public init(kind: OPNRemoteCoOpWirePeerSignalKind,
                sdp: String? = nil,
                candidate: String? = nil,
                sdpMid: String? = nil,
                sdpMLineIndex: Int? = nil) {
        self.kind = kind
        self.sdp = sdp
        self.candidate = candidate
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
    }
}

public struct OPNRemoteCoOpWireMessage: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var kind: OPNRemoteCoOpWireMessageKind
    public var roomID: UUID?
    public var participantID: UUID?
    public var inviteToken: String?
    public var displayName: String?
    public var invite: OPNRemoteCoOpInvite?
    public var participant: OPNRemoteCoOpParticipant?
    public var input: OPNRemoteCoOpInputPacket?
    public var inputRejection: OPNRemoteCoOpWireInputRoutingRejection?
    public var reason: String?
    public var peerSignal: OPNRemoteCoOpWirePeerSignal?
    public var networkConfiguration: OPNRemoteCoOpNetworkConfiguration?
    public var sentAtEpochMilliseconds: Int64

    public init(kind: OPNRemoteCoOpWireMessageKind,
                roomID: UUID? = nil,
                participantID: UUID? = nil,
                inviteToken: String? = nil,
                displayName: String? = nil,
                invite: OPNRemoteCoOpInvite? = nil,
                participant: OPNRemoteCoOpParticipant? = nil,
                input: OPNRemoteCoOpInputPacket? = nil,
                inputRejection: OPNRemoteCoOpWireInputRoutingRejection? = nil,
                reason: String? = nil,
                peerSignal: OPNRemoteCoOpWirePeerSignal? = nil,
                networkConfiguration: OPNRemoteCoOpNetworkConfiguration? = nil,
                sentAt: Date = Date()) {
        self.protocolVersion = 1
        self.kind = kind
        self.roomID = roomID
        self.participantID = participantID
        self.inviteToken = inviteToken
        self.displayName = displayName
        self.invite = invite
        self.participant = participant
        self.input = input
        self.inputRejection = inputRejection
        self.reason = reason
        self.peerSignal = peerSignal
        self.networkConfiguration = networkConfiguration
        self.sentAtEpochMilliseconds = Int64((sentAt.timeIntervalSince1970 * 1_000).rounded())
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? 1
        kind = try container.decode(OPNRemoteCoOpWireMessageKind.self, forKey: .kind)
        roomID = try container.decodeIfPresent(UUID.self, forKey: .roomID)
        participantID = try container.decodeIfPresent(UUID.self, forKey: .participantID)
        inviteToken = try container.decodeIfPresent(String.self, forKey: .inviteToken)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        invite = try container.decodeIfPresent(OPNRemoteCoOpInvite.self, forKey: .invite)
        participant = try container.decodeIfPresent(OPNRemoteCoOpParticipant.self, forKey: .participant)
        input = try container.decodeIfPresent(OPNRemoteCoOpInputPacket.self, forKey: .input)
        inputRejection = try container.decodeIfPresent(OPNRemoteCoOpWireInputRoutingRejection.self, forKey: .inputRejection)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        peerSignal = try container.decodeIfPresent(OPNRemoteCoOpWirePeerSignal.self, forKey: .peerSignal)
        networkConfiguration = try container.decodeIfPresent(OPNRemoteCoOpNetworkConfiguration.self, forKey: .networkConfiguration)
        sentAtEpochMilliseconds = try container.decodeIfPresent(Int64.self, forKey: .sentAtEpochMilliseconds) ?? Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }

    public func signalingEvent() -> OPNRemoteCoOpSignalingEvent? {
        switch kind {
        case .guestJoinRequested:
            guard let participantID, let inviteToken else { return nil }
            return .guestJoinRequested(participantID: participantID, inviteToken: inviteToken, displayName: displayName ?? "Guest")
        case .guestInput:
            guard let input else { return nil }
            return .guestInput(input)
        case .guestDisconnected:
            guard let participantID else { return nil }
            return .guestDisconnected(participantID)
        case .peerSignal:
            guard let participantID, let peerSignal else { return nil }
            return .peerSignal(participantID: participantID, signal: peerSignal)
        case .networkConfiguration:
            guard let networkConfiguration else { return nil }
            return .networkConfiguration(networkConfiguration)
        case .hostHello, .inviteEnded, .participantUpdated, .participantRemoved, .guestRejected, .inputRejected, .heartbeat, .error:
            return nil
        }
    }

    public static func message(for command: OPNRemoteCoOpSignalingCommand, roomID fallbackRoomID: UUID? = nil) -> OPNRemoteCoOpWireMessage? {
        switch command {
        case .inviteCreated(let invite):
            return OPNRemoteCoOpWireMessage(kind: .hostHello, roomID: invite.id, invite: invite)
        case .inviteEnded:
            return OPNRemoteCoOpWireMessage(kind: .inviteEnded, roomID: fallbackRoomID)
        case .participantUpdated(let participant):
            return OPNRemoteCoOpWireMessage(kind: .participantUpdated, roomID: fallbackRoomID, participantID: participant.id, participant: participant)
        case .participantRemoved(let participantID):
            return OPNRemoteCoOpWireMessage(kind: .participantRemoved, roomID: fallbackRoomID, participantID: participantID)
        case .guestRejected(let participantID, let reason):
            return OPNRemoteCoOpWireMessage(kind: .guestRejected, roomID: fallbackRoomID, participantID: participantID, reason: reason)
        case .inputRejected(let participantID, let result):
            guard let rejection = OPNRemoteCoOpWireInputRoutingRejection(result) else { return nil }
            return OPNRemoteCoOpWireMessage(kind: .inputRejected, roomID: fallbackRoomID, participantID: participantID, inputRejection: rejection)
        case .peerSignal(let participantID, let signal):
            return OPNRemoteCoOpWireMessage(kind: .peerSignal, roomID: fallbackRoomID, participantID: participantID, peerSignal: signal)
        }
    }
}

public enum OPNRemoteCoOpWireCodec {
    public static func encode(_ message: OPNRemoteCoOpWireMessage) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(message)
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ text: String) throws -> OPNRemoteCoOpWireMessage {
        let data = Data(text.utf8)
        return try JSONDecoder().decode(OPNRemoteCoOpWireMessage.self, from: data)
    }

    public static func decode(_ data: Data) throws -> OPNRemoteCoOpWireMessage {
        try JSONDecoder().decode(OPNRemoteCoOpWireMessage.self, from: data)
    }
}
