import Foundation

public enum OPNRemoteCoOpInputRoutingResult: Equatable, Sendable {
    case routed(UserInputEvent)
    case participantNotFound
    case inputDisabled
    case stalePacket
    case invalidPlayerSlot
}

public actor OPNRemoteCoOpInputRouter {
    private var participantsByID: [UUID: OPNRemoteCoOpParticipant] = [:]
    private var lastSequenceByParticipantID: [UUID: UInt64] = [:]

    public init(participants: [OPNRemoteCoOpParticipant] = []) {
        for participant in participants {
            participantsByID[participant.id] = participant
        }
    }

    public func replaceParticipants(_ participants: [OPNRemoteCoOpParticipant]) {
        participantsByID = Dictionary(uniqueKeysWithValues: participants.map { ($0.id, $0) })
        lastSequenceByParticipantID = lastSequenceByParticipantID.filter { participantsByID[$0.key] != nil }
    }

    public func upsertParticipant(_ participant: OPNRemoteCoOpParticipant) {
        participantsByID[participant.id] = participant
    }

    public func removeParticipant(_ id: UUID) {
        participantsByID[id] = nil
        lastSequenceByParticipantID[id] = nil
    }

    public func route(_ packet: OPNRemoteCoOpInputPacket, receivedAtNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) -> OPNRemoteCoOpInputRoutingResult {
        guard var participant = participantsByID[packet.participantID] else { return .participantNotFound }
        guard participant.inputEnabled else { return .inputDisabled }
        guard let playerIndex = participant.playerIndex, (1...3).contains(playerIndex) else { return .invalidPlayerSlot }
        if let lastSequence = lastSequenceByParticipantID[packet.participantID], packet.sequenceNumber <= lastSequence {
            return .stalePacket
        }

        lastSequenceByParticipantID[packet.participantID] = packet.sequenceNumber
        participant.lastActivityAt = Date()
        participantsByID[packet.participantID] = participant

        let state = GamepadState(
            deviceID: InputDeviceID("remote-coop-\(packet.participantID.uuidString)"),
            playerIndex: playerIndex,
            buttons: packet.buttons,
            leftTrigger: packet.leftTrigger,
            rightTrigger: packet.rightTrigger,
            leftStickX: packet.leftStickX,
            leftStickY: packet.leftStickY,
            rightStickX: packet.rightStickX,
            rightStickY: packet.rightStickY,
            timestamp: MediaTimestamp(nanoseconds: receivedAtNanoseconds)
        )
        return .routed(.gamepad(state))
    }

    public func neutralInputEventsForDisconnectedParticipants() -> [UserInputEvent] {
        participantsByID.values.compactMap { participant in
            guard let playerIndex = participant.playerIndex, (1...3).contains(playerIndex) else { return nil }
            return .gamepad(GamepadState(
                deviceID: InputDeviceID("remote-coop-\(participant.id.uuidString)"),
                playerIndex: playerIndex,
                timestamp: MediaTimestamp(nanoseconds: DispatchTime.now().uptimeNanoseconds)
            ))
        }
    }
}
