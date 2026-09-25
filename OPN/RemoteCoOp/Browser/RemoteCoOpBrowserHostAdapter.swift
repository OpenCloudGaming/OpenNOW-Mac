import Foundation

/// The browser egress's view of host policy.
///
/// It exists rather than conforming `OPNRemoteCoOpHostSession` directly because guest input has to
/// reach the game, not merely the router: `route` returns the gamepad event the seat needs, and
/// something has to hand that event to the input dispatcher without hopping onto the main actor for
/// every packet. This is the same delivery the native peer controller performs, arranged for the
/// browser transport.
final class OPNRemoteCoOpBrowserHostAdapter: OPNRemoteCoOpBrowserEgressHost, @unchecked Sendable {
    private let session: OPNRemoteCoOpHostSession
    private let forwarder: OPNRemoteCoOpBrowserInputForwarder

    init(session: OPNRemoteCoOpHostSession,
         forwardInput: @escaping @Sendable (UserInputEvent) -> Void) {
        self.session = session
        self.forwarder = OPNRemoteCoOpBrowserInputForwarder(session: session, forwardInput: forwardInput)
    }

    func browserGuestDidRequestJoin(token: String,
                                    displayName: String,
                                    participantID: UUID?,
                                    reconnectToken: String?) async throws -> OPNRemoteCoOpParticipant {
        try await session.registerGuest(displayName: displayName,
                                        inviteToken: token,
                                        participantID: participantID ?? UUID(),
                                        reconnectToken: reconnectToken)
    }

    func browserGuestDidSendInput(_ packet: OPNRemoteCoOpInputPacket) async {
        await forwarder.receive(packet)
    }

    func browserGuestDidDisconnect(participantID: UUID) async -> [UserInputEvent] {
        await session.noteGuestDisconnected(participantID)
    }
}

/// Serialises each browser guest packet's route and delivery.
///
/// The datagram channel is unordered, so two packets can be in flight at once. Routing and forwarding
/// inside one actor keeps a stale packet from being delivered after a newer one, which is the same
/// ordering guarantee the native data channel's scheduler provides.
private actor OPNRemoteCoOpBrowserInputForwarder {
    private let session: OPNRemoteCoOpHostSession
    private let forwardInput: @Sendable (UserInputEvent) -> Void

    init(session: OPNRemoteCoOpHostSession, forwardInput: @escaping @Sendable (UserInputEvent) -> Void) {
        self.session = session
        self.forwardInput = forwardInput
    }

    func receive(_ packet: OPNRemoteCoOpInputPacket) async {
        guard case .routed(let event) = await session.route(packet) else { return }
        forwardInput(event)
    }
}
