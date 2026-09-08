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

import CryptoKit
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
    private let participantOwnership: OPNRemoteCoOpParticipantOwnership
    private let logger: (@Sendable (String) -> Void)?
    private let lock = NSLock()
    private var eventContinuations: [UUID: AsyncStream<OPNRemoteCoOpSignalingEvent>.Continuation] = [:]
    /// Which participant a sender has claimed.
    ///
    /// The equivalent of a socket's `participantID`, and the reason the shared gate can be used
    /// unchanged: it asks who owns this connection, and here a connection is a sender. The shared
    /// registry is the authoritative source; this table is kept only for local routing lookups.
    private var participantsBySender: [String: UUID] = [:]
    /// The ICE configuration handed to a guest once its invite has verified. Carried here because
    /// nothing else on this transport has it, and without it a hosted guest is never given a relay.
    private var networkConfiguration: OPNRemoteCoOpNetworkConfiguration
    /// Sent once per verified participant, like the embedded server. Re-sending on every later update
    /// would put the relay credentials back on the wire for no reason.
    private var participantsGivenNetworkConfiguration: Set<UUID> = []
    /// Captured from `guestJoinRequested`. Every other invite holder shares read access to the host
    /// channel this transport publishes on, so a reconnect token or TURN credential sent in the clear
    /// is visible to all of them, not just the guest it names - `send` and
    /// `sendNetworkConfigurationIfNeeded` seal to this key instead of trusting that. A guest with no
    /// key on file gets neither secret at all, never a plaintext copy: falling back to plaintext for
    /// one missing key would have undone the seal for every other guest reading the same broadcast.
    private var participantPublicKeys: [UUID: P256.KeyAgreement.PublicKey] = [:]
    private var isClosed = false
    private static let sealInfo = Data("OpenNOW.RemoteCoOp.Hosted".utf8)

    public init(channel: any OPNRemoteCoOpSignalingChannel,
                participantOwnership: OPNRemoteCoOpParticipantOwnership,
                networkConfiguration: OPNRemoteCoOpNetworkConfiguration = OPNRemoteCoOpNetworkConfiguration(transportMode: .automatic),
                logger: (@Sendable (String) -> Void)? = nil) {
        self.channel = channel
        self.participantOwnership = participantOwnership
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
        // `OPNRemoteCoOpCompositeSignalingSession` fans every command out to every transport, so a
        // command about a guest who joined over the embedded server or the native listener reaches
        // here too. Nothing about them belongs on this channel: this transport never learned a key
        // for them, so encrypting on their behalf is impossible, and sending their reconnect token,
        // TURN credentials or SDP in the clear would broadcast another transport's secrets to every
        // hosted invite holder, none of whom have any relationship to that guest at all.
        guard isTargetedAtThisTransport(command) else { return }
        // The relay credentials are only released once the host has accepted the guest: the
        // participant must be marked connected and input enabled. This closes the window where a
        // guest that has only verified its invite token but has not yet been approved could obtain
        // the TURN username and password.
        if case .participantUpdated(let participant) = command {
            sendNetworkConfigurationIfNeeded(to: participant)
        }
        // A refused join releases its claim, for the same reason the socket transports do: the gate
        // binds on a non-empty token and only `registerGuest` checks the signature, so a sender that
        // presented a garbage one would otherwise keep owning that participant.
        if case .guestRejected(let participantID, _) = command {
            lock.withLock {
                participantsGivenNetworkConfiguration.remove(participantID)
                participantPublicKeys.removeValue(forKey: participantID)
                participantsBySender = participantsBySender.filter { $0.value != participantID }
            }
            if let handle = participantOwnership.owner(of: participantID), handle.transport == .hosted {
                participantOwnership.release(handle)
            }
        }
        guard var message = OPNRemoteCoOpWireMessage.message(for: command, roomID: nil, sessionQualityPreset: nil) else { return }
        if case .participantUpdated(let participant) = command {
            sealReconnectToken(on: &message, participantID: participant.id)
        }
        guard let text = try? OPNRemoteCoOpWireCodec.encode(message) else { return }
        channel.publish(name: OPNRemoteCoOpHostedSignalingName.host, text: text)
    }

    /// Whether `participantID` actually joined over this transport, rather than merely being named in
    /// a command `OPNRemoteCoOpCompositeSignalingSession` fanned out to every transport.
    private func ownsHosted(_ participantID: UUID) -> Bool {
        guard let handle = participantOwnership.owner(of: participantID) else { return false }
        return handle.transport == .hosted
    }

    /// Invite-wide commands go out unconditionally; every per-participant command is dropped here
    /// unless that participant is actually this transport's own guest. See the comment in `send`.
    private func isTargetedAtThisTransport(_ command: OPNRemoteCoOpSignalingCommand) -> Bool {
        switch command {
        case .inviteCreated, .inviteEnded:
            return true
        case .participantUpdated(let participant):
            return ownsHosted(participant.id)
        case .participantRemoved(let participantID),
             .guestRejected(let participantID, _),
             .inputRejected(let participantID, _),
             .peerSignal(let participantID, _):
            return ownsHosted(participantID)
        }
    }

    /// Moves `participantUpdated`'s reconnect token into a sealed envelope once the guest's public key
    /// is known - that token is what lets anyone reclaim this participant, so leaving it in the clear
    /// on the shared channel would hand every other invite holder a way to steal the identity during
    /// this guest's disconnect grace period.
    ///
    /// A guest with no key on file gets no token at all, never a plaintext one: a page that never
    /// sent a key - or an attacker deliberately omitting one to force a plaintext copy onto the
    /// channel every other invite holder reads - loses reconnect continuity rather than the token
    /// being handed out to everyone regardless.
    private func sealReconnectToken(on message: inout OPNRemoteCoOpWireMessage, participantID: UUID) {
        guard let plaintextToken = message.reconnectToken else { return }
        message.reconnectToken = nil
        // `message(for:)` copies the token into the embedded `participant` too - the same value,
        // reachable a second way - so both have to be cleared or the seal is decorative.
        message.participant?.reconnectToken = nil
        guard let key = lock.withLock({ participantPublicKeys[participantID] }),
              let envelope = seal(plaintextToken, for: key) else { return }
        message.encryptedReconnectToken = envelope
    }

    /// Not locking - called only from within `lock`'s critical section, in `ingest`.
    private func rememberGuestPublicKey(from message: OPNRemoteCoOpWireMessage, participantID: UUID) {
        guard let encoded = message.guestPublicKey,
              let data = Data(base64Encoded: encoded),
              let key = try? P256.KeyAgreement.PublicKey(rawRepresentation: data) else { return }
        participantPublicKeys[participantID] = key
    }

    /// ECDH (P-256, a fresh host key every call) + HKDF-SHA256 + AES-256-GCM, sealed to one guest's
    /// public key. Must match the browser guest's `unsealEnvelope` exactly.
    private func seal<T: Encodable>(_ payload: T, for guestPublicKey: P256.KeyAgreement.PublicKey) -> OPNRemoteCoOpWireEncryptedEnvelope? {
        guard let plaintext = try? JSONEncoder().encode(payload) else { return nil }
        let ephemeralPrivateKey = P256.KeyAgreement.PrivateKey()
        guard let sharedSecret = try? ephemeralPrivateKey.sharedSecretFromKeyAgreement(with: guestPublicKey) else { return nil }
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: Self.sealInfo,
            outputByteCount: 32
        )
        guard let sealed = try? AES.GCM.seal(plaintext, using: symmetricKey) else { return nil }
        return OPNRemoteCoOpWireEncryptedEnvelope(
            ephemeralPublicKey: ephemeralPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            nonce: Data(sealed.nonce).base64EncodedString(),
            ciphertext: (sealed.ciphertext + sealed.tag).base64EncodedString()
        )
    }

    /// The hosted transport used to send this not at all - `message(for:)` has no case that produces
    /// it - so a hosted guest never received ICE servers and could not connect from any network that
    /// blocks a direct route, which is the exact case this transport exists to serve.
    ///
    /// Withheld, not sent in the clear, until a guest key is on file: the TURN username and password
    /// are gated on approval precisely so an invite holder who has not been approved cannot get them
    /// early, and a plaintext copy on this shared channel handed them to every such holder regardless
    /// - approved or not - the moment any one guest lacked a key. Not marked "given" until it is
    /// actually sealed and sent, so a guest whose key arrives after this first runs still gets one.
    private func sendNetworkConfigurationIfNeeded(to participant: OPNRemoteCoOpParticipant) {
        guard let key = lock.withLock({ participantPublicKeys[participant.id] }) else { return }
        let configuration = lock.withLock { () -> OPNRemoteCoOpNetworkConfiguration? in
            guard participant.connectionState == .connected && participant.inputEnabled,
                  !participantsGivenNetworkConfiguration.contains(participant.id) else { return nil }
            participantsGivenNetworkConfiguration.insert(participant.id)
            return networkConfiguration
        }
        guard let configuration, let envelope = seal(configuration, for: key) else { return }
        var message = OPNRemoteCoOpWireMessage(kind: .networkConfiguration, roomID: nil, participantID: participant.id)
        message.encryptedNetworkConfiguration = envelope
        guard let text = try? OPNRemoteCoOpWireCodec.encode(message) else { return }
        channel.publish(name: OPNRemoteCoOpHostedSignalingName.host, text: text)
    }

    public func close() async {
        let (continuations, senders) = lock.withLock { () -> ([AsyncStream<OPNRemoteCoOpSignalingEvent>.Continuation], [String]) in
            guard !isClosed else { return ([], []) }
            isClosed = true
            let existing = Array(eventContinuations.values)
            eventContinuations.removeAll()
            let senders = Array(participantsBySender.keys)
            participantsBySender.removeAll()
            participantPublicKeys.removeAll()
            return (existing, senders)
        }
        // Finish outside the lock: termination handlers may re-enter the lock.
        for continuation in continuations { continuation.finish() }
        // Release all hosted bindings. The registry is shared, but each transport only owns its own
        // handles; releasing handles this transport never created is a no-op.
        for sender in senders {
            participantOwnership.release(.init(transport: .hosted, connectionID: sender))
        }
        channel.detach()
    }

    private func ingest(text: String, senderID: String) {
        guard let message = try? OPNRemoteCoOpWireCodec.decode(text) else { return }

        // The same gate both socket listeners use. A third transport must not carry a third variant
        // of who may say what.
        //
        // The `senderID` passed by the channel is Ably's `connectionId`, not the guest-asserted
        // `clientId`. Using `connectionId` means a second invite holder on the same channel cannot
        // impersonate another guest by simply claiming their participant ID.
        let handle = OPNRemoteCoOpConnectionHandle(transport: .hosted, connectionID: senderID)
        let decision = lock.withLock { () -> OPNRemoteCoOpGuestMessageGate.Decision in
            let decision = OPNRemoteCoOpGuestMessageGate.decide(
                message: message,
                connection: handle,
                registry: participantOwnership
            )
            // Bound inside the same critical section that tested the claim, so two senders racing the
            // same participant cannot both be told it is free.
            if case .claimThenDeliver(let participantID) = decision {
                participantsBySender[senderID] = participantID
                participantOwnership.claim(participantID: participantID, for: handle)
                rememberGuestPublicKey(from: message, participantID: participantID)
            } else if decision == .deliver, message.kind == .guestJoinRequested, let participantID = message.participantID {
                // A retried join: the guest may have regenerated its key pair before the host's reply
                // arrived, so keep the newest one rather than sealing to a key nobody holds any more.
                rememberGuestPublicKey(from: message, participantID: participantID)
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
            participantPublicKeys.removeValue(forKey: participantID)
            return participantID
        }
        participantOwnership.release(.init(transport: .hosted, connectionID: senderID))
        guard let participantID else { return }
        publish(.guestDisconnected(participantID))
    }

    private func publish(_ event: OPNRemoteCoOpSignalingEvent) {
        let continuations = lock.withLock { Array(eventContinuations.values) }
        for continuation in continuations { continuation.yield(event) }
    }
}
