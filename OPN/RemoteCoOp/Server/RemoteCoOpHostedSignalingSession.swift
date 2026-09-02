//
//  RemoteCoOpHostedSignalingSession.swift
//  OpenNOW
//
//  Signaling over a hosted pub/sub channel, so the host needs no inbound reachability at all.
//
//  This is a fallback, never the preferred path: a guest that can reach the host directly has no
//  reason to involve a third party, or to spend messages doing it. The host may run this alongside
//  the embedded server and the native listener, and the invite says which one a given guest should
//  use.
//
//  The channel is abstracted rather than used directly so the behaviour here is testable without a
//  network or an account. `OPNRemoteCoOpSignalingChannel` is the whole surface this needs: publish,
//  subscribe, know when someone leaves, detach.
//

import Foundation

/// The slice of a hosted channel this transport uses.
///
/// Deliberately tiny and string-shaped: the wire format is already JSON, so nothing here needs to
/// know what a message means, and a stub in a test is a few lines rather than a mock framework.
public protocol OPNRemoteCoOpSignalingChannel: AnyObject, Sendable {
    /// `name` separates the two directions on one channel. Both parties publish to the same place,
    /// and each subscribes only to the other's name, so a host never consumes its own commands
    /// regardless of whether the provider echoes them back.
    func publish(name: String, text: String)
    func subscribe(name: String, handler: @escaping @Sendable (_ text: String, _ senderID: String) -> Void)
    /// Fired when a guest's connection goes away, gracefully or not. This is what replaces the
    /// heartbeat and the idle sweep the socket transports need.
    func onLeave(handler: @escaping @Sendable (_ senderID: String) -> Void)
    func detach()
}

public enum OPNRemoteCoOpHostedSignalingName {
    /// Published by the host, consumed by guests.
    public static let host = "host"
    /// Published by guests, consumed by the host.
    public static let guest = "guest"
}

public final class OPNRemoteCoOpHostedSignalingSession: OPNRemoteCoOpSignalingSession, @unchecked Sendable {
    private let channel: any OPNRemoteCoOpSignalingChannel
    private let logger: (@Sendable (String) -> Void)?
    private let lock = NSLock()
    private var eventContinuations: [UUID: AsyncStream<OPNRemoteCoOpSignalingEvent>.Continuation] = [:]
    /// Which participant a sender has claimed.
    ///
    /// The equivalent of a socket's `participantID`, and the reason the shared gate can be used
    /// unchanged: it asks who owns this connection, and here a connection is a sender.
    private var participantsBySender: [String: UUID] = [:]
    /// The ICE configuration handed to a guest once its invite has verified. Carried here because
    /// nothing else on this transport has it, and without it a hosted guest is never given a relay.
    private var networkConfiguration: OPNRemoteCoOpNetworkConfiguration
    /// Sent once per verified participant, like the embedded server. Re-sending on every later update
    /// would put the relay credentials back on the wire for no reason.
    private var participantsGivenNetworkConfiguration: Set<UUID> = []
    private var isClosed = false

    public init(channel: any OPNRemoteCoOpSignalingChannel,
                networkConfiguration: OPNRemoteCoOpNetworkConfiguration = OPNRemoteCoOpNetworkConfiguration(transportMode: .automatic),
                logger: (@Sendable (String) -> Void)? = nil) {
        self.channel = channel
        self.networkConfiguration = networkConfiguration
        self.logger = logger
        channel.subscribe(name: OPNRemoteCoOpHostedSignalingName.guest) { [weak self] text, senderID in
            self?.ingest(text: text, senderID: senderID)
        }
        channel.onLeave { [weak self] senderID in
            self?.handleLeave(senderID: senderID)
        }
    }

    public func events() -> AsyncStream<OPNRemoteCoOpSignalingEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            let closed = lock.withLock { () -> Bool in
                guard !isClosed else { return true }
                eventContinuations[id] = continuation
                return false
            }
            if closed {
                continuation.finish()
                return
            }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { self?.eventContinuations[id] = nil }
            }
        }
    }

    /// Replaces the ICE configuration handed to guests that verify after this point.
    public func updateNetworkConfiguration(_ configuration: OPNRemoteCoOpNetworkConfiguration) {
        lock.withLock { networkConfiguration = configuration }
    }

    public func send(_ command: OPNRemoteCoOpSignalingCommand) async {
        guard !lock.withLock({ isClosed }) else { return }
        // The host channel carries every guest of an invite, so a targeted command still reaches all
        // of them; the addressee is inside the message and each guest ignores what is not theirs.
        // Guests cannot publish here - their token grants `subscribe` only on this channel - so a
        // message arriving on it is the host's.
        //
        // The relay credentials are the one thing worth being careful with, and they are only sent
        // after `registerGuest` has verified the signed invite, which is what `participantUpdated`
        // means. They are still readable by the invite's other holders, which is inherent to a shared
        // invite and recorded on `mintGuestToken`.
        if case .participantUpdated(let participant) = command {
            sendNetworkConfigurationIfNeeded(to: participant.id)
        }
        // A refused join releases its claim, for the same reason the socket transports do: the gate
        // binds on a non-empty token and only `registerGuest` checks the signature, so a sender that
        // presented a garbage one would otherwise keep owning that participant.
        if case .guestRejected(let participantID, _) = command {
            lock.withLock {
                participantsGivenNetworkConfiguration.remove(participantID)
                for (sender, claimed) in participantsBySender where claimed == participantID {
                    participantsBySender[sender] = nil
                }
            }
        }
        guard let message = OPNRemoteCoOpWireMessage.message(for: command, roomID: nil, sessionQualityPreset: nil),
              let text = try? OPNRemoteCoOpWireCodec.encode(message) else { return }
        channel.publish(name: OPNRemoteCoOpHostedSignalingName.host, text: text)
    }

    /// The hosted transport used to send this not at all - `message(for:)` has no case that produces
    /// it - so a hosted guest never received ICE servers and could not connect from any network that
    /// blocks a direct route, which is the exact case this transport exists to serve.
    private func sendNetworkConfigurationIfNeeded(to participantID: UUID) {
        let configuration = lock.withLock { () -> OPNRemoteCoOpNetworkConfiguration? in
            guard !participantsGivenNetworkConfiguration.contains(participantID) else { return nil }
            participantsGivenNetworkConfiguration.insert(participantID)
            return networkConfiguration
        }
        guard let configuration,
              let text = try? OPNRemoteCoOpWireCodec.encode(OPNRemoteCoOpWireMessage(
                  kind: .networkConfiguration,
                  roomID: nil,
                  participantID: participantID,
                  networkConfiguration: configuration
              )) else { return }
        channel.publish(name: OPNRemoteCoOpHostedSignalingName.host, text: text)
    }

    public func close() async {
        let continuations = lock.withLock { () -> [AsyncStream<OPNRemoteCoOpSignalingEvent>.Continuation] in
            guard !isClosed else { return [] }
            isClosed = true
            let existing = Array(eventContinuations.values)
            eventContinuations.removeAll()
            participantsBySender.removeAll()
            return existing
        }
        channel.detach()
        for continuation in continuations { continuation.finish() }
    }

    private func ingest(text: String, senderID: String) {
        guard let message = try? OPNRemoteCoOpWireCodec.decode(text) else { return }

        // The same gate both socket listeners use. A third transport must not carry a third variant
        // of who may say what.
        //
        // Worth being clear about what this can and cannot do here: on a socket the transport owns the
        // connection's identity, whereas a sender ID on a hosted channel is asserted by the client. So
        // the claim guard is doing more work on this transport than on the others, and the real gate
        // remains the signed invite verified by `registerGuest`, plus host approval.
        let decision = lock.withLock { () -> OPNRemoteCoOpGuestMessageGate.Decision in
            let decision = OPNRemoteCoOpGuestMessageGate.decide(
                message: message,
                owner: participantsBySender[senderID],
                isHeldByAnotherConnection: { participantID in
                    participantsBySender.contains { $0.key != senderID && $0.value == participantID }
                }
            )
            // Bound inside the same critical section that tested the claim, so two senders racing the
            // same participant cannot both be told it is free.
            if case .claimThenDeliver(let participantID) = decision {
                participantsBySender[senderID] = participantID
            }
            return decision
        }

        switch decision {
        case .ignore:
            return
        case .dropConnection(let reason):
            // There is no socket to close. Refusing to bind is the whole remedy available, and it is
            // the one that matters: the claimant never becomes the participant.
            logger?("Remote Co-Op refused a hosted sender that \(reason)")
            return
        case .claimThenDeliver, .deliver:
            break
        }

        guard let event = message.signalingEvent() else { return }
        publish(event)
    }

    /// Presence, rather than a heartbeat.
    ///
    /// The socket transports need a liveness sweep because a dropped TCP connection can stay silent;
    /// a hosted channel reports the departure itself. That removes the machinery three of the review's
    /// findings lived in — the heartbeat echo loop, the missing native sweep, and the wall-clock idle
    /// timeout.
    private func handleLeave(senderID: String) {
        let participantID = lock.withLock { () -> UUID? in
            guard let participantID = participantsBySender.removeValue(forKey: senderID) else { return nil }
            // Cleared with the sender, so a reconnect has to re-verify before it is handed the relay
            // credentials again - the same rule the embedded server applies on socket close.
            participantsGivenNetworkConfiguration.remove(participantID)
            return participantID
        }
        guard let participantID else { return }
        publish(.guestDisconnected(participantID))
    }

    private func publish(_ event: OPNRemoteCoOpSignalingEvent) {
        let continuations = lock.withLock { Array(eventContinuations.values) }
        for continuation in continuations { continuation.yield(event) }
    }
}
