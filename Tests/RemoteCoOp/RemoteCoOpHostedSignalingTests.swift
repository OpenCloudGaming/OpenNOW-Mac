//  The hosted signaling transport, driven through a stub channel so nothing here needs a network or
//  an Ably account.
//

import CryptoKit
import Foundation
import Testing
@testable import OpenNOW

/// Records what the host published and lets a test play the part of a guest.
private final class StubSignalingChannel: OPNRemoteCoOpSignalingChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var published: [(name: String, text: String)] = []
    private var guestHandler: (@Sendable (String, String) -> Void)?
    private var leaveHandler: (@Sendable (String) -> Void)?
    private(set) var didDetach = false

    func publish(name: String, text: String) {
        lock.lock()
        published.append((name, text))
        lock.unlock()
    }

    func subscribe(name: String, handler: @escaping @Sendable (String, String) -> Void) {
        lock.lock()
        if name == OPNRemoteCoOpHostedSignalingName.guest { guestHandler = handler }
        lock.unlock()
    }

    func onLeave(handler: @escaping @Sendable (String) -> Void) {
        lock.lock()
        leaveHandler = handler
        lock.unlock()
    }

    func detach() {
        lock.lock()
        didDetach = true
        lock.unlock()
    }

    // MARK: - Test driving

    func messages() -> [(name: String, text: String)] {
        lock.lock()
        defer { lock.unlock() }
        return published
    }

    func deliverFromGuest(_ message: OPNRemoteCoOpWireMessage, senderID: String) throws {
        let handler = lock.withLock { guestHandler }
        try #require(handler != nil, "the session never subscribed to guest messages")
        handler?(try OPNRemoteCoOpWireCodec.encode(message), senderID)
    }

    func deliverLeave(senderID: String) {
        lock.withLock { leaveHandler }?(senderID)
    }
}

@Suite struct RemoteCoOpHostedSignalingTests {
    private let participantID = UUID()
    private let stranger = UUID()

    private func makeSession() -> (OPNRemoteCoOpHostedSignalingSession, StubSignalingChannel, OPNRemoteCoOpParticipantOwnership) {
        let channel = StubSignalingChannel()
        let ownership = OPNRemoteCoOpParticipantOwnership()
        return (OPNRemoteCoOpHostedSignalingSession(channel: channel, participantOwnership: ownership), channel, ownership)
    }

    private func join(_ id: UUID, token: String = "token.signature") -> OPNRemoteCoOpWireMessage {
        OPNRemoteCoOpWireMessage(kind: .guestJoinRequested, participantID: id, inviteToken: token, displayName: "Guest")
    }

    /// Collects for a window rather than taking the first: assertions about what must *not* arrive
    /// cannot be written against a single-element read.
    private func collect(_ session: OPNRemoteCoOpHostedSignalingSession,
                         while body: () throws -> Void) async rethrows -> [OPNRemoteCoOpSignalingEvent] {
        let events = session.events()
        let box = EventBox()
        let drain = Task { for await event in events { box.append(event) } }
        try body()
        try? await Task.sleep(for: .milliseconds(120))
        drain.cancel()
        return box.events()
    }

    // MARK: - Claim release

    /// A refused join must not leave the sender owning that participant.
    ///
    /// The gate binds on a non-empty token; only `registerGuest` checks the signature. Without
    /// releasing on rejection, a sender that presented a garbage token stayed the owner - so it kept
    /// receiving that participant's `participantUpdated` and `peerSignal` (their SDP), was handed the
    /// relay credentials on the first update, and the real guest could not take the participant back.
    @Test func aRefusedJoinReleasesItsClaim() async throws {
        let (session, channel, _) = makeSession()

        // Squatter claims the participant, then the host refuses it.
        _ = try await collect(session) { try channel.deliverFromGuest(self.join(self.participantID), senderID: "squatter") }
        await session.send(.guestRejected(participantID: participantID, reason: "bad token"))

        // Input from the squatter is now ignored: it owns nothing.
        let afterRejection = try await collect(session) {
            try channel.deliverFromGuest(
                OPNRemoteCoOpWireMessage(kind: .guestQualityRequested, participantID: self.participantID, qualityPreset: .p720f60),
                senderID: "squatter"
            )
        }
        #expect(afterRejection.isEmpty, "a rejected sender still owns the participant it claimed")

        // And the real guest can claim it.
        let realJoin = try await collect(session) { try channel.deliverFromGuest(self.join(self.participantID), senderID: "real-guest") }
        #expect(realJoin.contains { event in
            if case .guestJoinRequested(let id, _, _, _) = event { return id == self.participantID }
            return false
        }, "the real guest was refused a participant nobody holds")
    }

    // MARK: - Directions

    /// One channel carries both directions, separated by name. The host must never consume its own
    /// commands, whether or not the provider echoes them.
    @Test func hostCommandsArePublishedUnderTheHostName() async throws {
        let (session, channel, ownership) = makeSession()
        // A rejection this transport never owns is dropped entirely - see the cross-transport
        // isolation tests below - so this has to claim the participant first, matching how a real
        // `guestJoinRequested` binds it before `registerGuest` ever gets a chance to reject it.
        ownership.claim(participantID: participantID, for: OPNRemoteCoOpConnectionHandle(transport: .hosted, connectionID: "sender-a"))
        await session.send(.guestRejected(participantID: participantID, reason: "full"))
        let published = try #require(channel.messages().first)
        #expect(published.name == OPNRemoteCoOpHostedSignalingName.host)
        #expect(published.text.contains("guestRejected"))
        #expect(channel.messages().count == 1)
    }

    @Test func guestMessagesBecomeEvents() async throws {
        let (session, channel, _) = makeSession()
        let events = try await collect(session) {
            try channel.deliverFromGuest(join(participantID), senderID: "sender-a")
        }
        guard case .guestJoinRequested(let id, _, let name, _)? = events.first else {
            Issue.record("the join never surfaced, got \(events)")
            return
        }
        #expect(id == participantID)
        #expect(name == "Guest")
    }

    // MARK: - Authorisation

    /// The transport must not carry its own copy of the policy, so the checks the gate makes are
    /// asserted here through it rather than reimplemented.
    @Test func aSenderThatNeverJoinedCannotAct() async throws {
        let (session, channel, _) = makeSession()
        let events = try await collect(session) {
            try channel.deliverFromGuest(
                OPNRemoteCoOpWireMessage(kind: .guestQualityRequested, participantID: participantID, qualityPreset: .p720f60),
                senderID: "sender-a"
            )
        }
        #expect(events.isEmpty, "a sender with no join acted as a participant")
    }

    @Test func aJoinedSenderCannotActAsAnother() async throws {
        let (session, channel, _) = makeSession()
        let events = try await collect(session) {
            try channel.deliverFromGuest(join(participantID), senderID: "sender-a")
            try channel.deliverFromGuest(
                OPNRemoteCoOpWireMessage(kind: .guestQualityRequested, participantID: stranger, qualityPreset: .p720f60),
                senderID: "sender-a"
            )
        }
        // The join lands; the impersonation does not.
        #expect(events.count == 1)
        #expect(events.contains { if case .guestJoinRequested = $0 { return true } else { return false } })
    }

    /// A second sender naming a participant someone else holds is refused. There is no socket to
    /// close here, so refusing to bind is the whole remedy — and it is the one that matters.
    @Test func aParticipantHeldByAnotherSenderIsNotUpForGrabs() async throws {
        let (session, channel, _) = makeSession()
        let events = try await collect(session) {
            try channel.deliverFromGuest(join(participantID), senderID: "sender-a")
            try channel.deliverFromGuest(join(participantID), senderID: "sender-b")
        }
        #expect(events.count == 1, "a held participant was handed to a second sender")
    }

    /// A second sender using the same `connectionId` as the first is treated as the same connection,
    /// so it cannot claim a different participant on the shared channel. This is the hosted R1 fix:
    /// identity is the Ably connection, not the guest-asserted clientId.
    @Test func aSenderReusingAnotherConnectionIdCannotClaimADifferentParticipant() async throws {
        let (session, channel, _) = makeSession()
        let events = try await collect(session) {
            try channel.deliverFromGuest(join(participantID), senderID: "sender-a")
            try channel.deliverFromGuest(join(stranger), senderID: "sender-a")
        }
        let joins = events.filter { if case .guestJoinRequested = $0 { return true } else { return false } }
        #expect(joins.count == 1, "a sender claimed a second participant")
    }

    /// Host-originated kinds have no producer on the guest side of the channel.
    @Test func hostKindsArrivingFromAGuestAreRefused() async throws {
        let (session, channel, _) = makeSession()
        let events = try await collect(session) {
            try channel.deliverFromGuest(join(participantID), senderID: "sender-a")
            try channel.deliverFromGuest(
                OPNRemoteCoOpWireMessage(kind: .networkConfiguration, participantID: participantID,
                                         networkConfiguration: OPNRemoteCoOpNetworkConfiguration(transportMode: .directOnly)),
                senderID: "sender-a"
            )
        }
        #expect(!events.contains { if case .networkConfiguration = $0 { return true } else { return false } },
                "a guest replaced the session's ICE configuration")
    }

    // MARK: - Presence

    /// Presence is what replaces the heartbeat and the idle sweep: the channel reports a departure
    /// rather than the host inferring one from silence.
    @Test func aSenderLeavingDisconnectsItsParticipant() async throws {
        let (session, channel, _) = makeSession()
        let events = try await collect(session) {
            try channel.deliverFromGuest(join(participantID), senderID: "sender-a")
            channel.deliverLeave(senderID: "sender-a")
        }
        #expect(events.contains { $0 == .guestDisconnected(participantID) })
    }

    @Test func aLeaveFromAnUnknownSenderDisconnectsNobody() async throws {
        let (session, channel, _) = makeSession()
        let events = try await collect(session) {
            try channel.deliverFromGuest(join(participantID), senderID: "sender-a")
            channel.deliverLeave(senderID: "sender-unknown")
        }
        #expect(!events.contains { if case .guestDisconnected = $0 { return true } else { return false } })
    }

    /// A guest that left and came back must be able to claim its participant again — the binding is
    /// released with the departure, so the claim guard does not lock them out of their own session.
    @Test func aParticipantIsReleasedOnLeaveSoTheGuestCanReturn() async throws {
        let (session, channel, _) = makeSession()
        let events = try await collect(session) {
            try channel.deliverFromGuest(join(participantID), senderID: "sender-a")
            channel.deliverLeave(senderID: "sender-a")
            try channel.deliverFromGuest(join(participantID), senderID: "sender-b")
        }
        let joins = events.filter { if case .guestJoinRequested = $0 { return true } else { return false } }
        #expect(joins.count == 2, "a returning guest was refused its own participant")
    }

    // MARK: - Sealing secrets from the shared channel

    /// Every guest on an invite subscribes to the same host channel, so a reconnect token or TURN
    /// credential sent in the clear on `participantUpdated`/`networkConfiguration` is readable by all
    /// of them, not just the participant it names. Once a guest has sent its ECDH public key in
    /// `guestJoinRequested`, the host must seal both fields instead of publishing them in the clear.
    @Test func participantUpdatedSealsTheReconnectTokenWhenTheGuestSentAKey() async throws {
        let (session, channel, _) = makeSession()
        let guestPrivateKey = P256.KeyAgreement.PrivateKey()

        _ = try await collect(session) {
            try channel.deliverFromGuest(
                OPNRemoteCoOpWireMessage(kind: .guestJoinRequested, participantID: self.participantID,
                                         inviteToken: "token.signature", displayName: "Guest",
                                         guestPublicKey: guestPrivateKey.publicKey.rawRepresentation.base64EncodedString()),
                senderID: "sender-a"
            )
        }

        let participant = OPNRemoteCoOpParticipant(id: participantID, displayName: "Guest", role: .guest,
                                                     connectionState: .connected, inputEnabled: true, playerIndex: 1,
                                                     reconnectToken: "super-secret-reconnect-token")
        await session.send(.participantUpdated(participant))

        let published = try #require(channel.messages().last { $0.text.contains("participantUpdated") })
        #expect(!published.text.contains("super-secret-reconnect-token"),
                "the reconnect token was still readable in the clear on the shared channel")
        let message = try OPNRemoteCoOpWireCodec.decode(published.text)
        #expect(message.reconnectToken == nil)
        let envelope = try #require(message.encryptedReconnectToken)
        let recovered: String = try unseal(envelope, with: guestPrivateKey)
        #expect(recovered == "super-secret-reconnect-token")
    }

    /// Same shared-channel exposure, for the TURN username and password `networkConfiguration`
    /// carries. Sent once a participant is connected and input-enabled, from the same `send` call.
    @Test func networkConfigurationSealsTheTurnCredentialsWhenTheGuestSentAKey() async throws {
        let (session, channel, _) = makeSession()
        let guestPrivateKey = P256.KeyAgreement.PrivateKey()

        _ = try await collect(session) {
            try channel.deliverFromGuest(
                OPNRemoteCoOpWireMessage(kind: .guestJoinRequested, participantID: self.participantID,
                                         inviteToken: "token.signature", displayName: "Guest",
                                         guestPublicKey: guestPrivateKey.publicKey.rawRepresentation.base64EncodedString()),
                senderID: "sender-a"
            )
        }

        let configuration = OPNRemoteCoOpNetworkConfiguration(
            transportMode: .automatic,
            iceServers: [OPNRemoteCoOpICEServer(urls: ["turn:example.com:3478"], username: "turn-user", credential: "turn-secret")]
        )
        session.updateNetworkConfiguration(configuration)
        let participant = OPNRemoteCoOpParticipant(id: participantID, displayName: "Guest", role: .guest,
                                                     connectionState: .connected, inputEnabled: true, playerIndex: 1)
        await session.send(.participantUpdated(participant))

        let published = try #require(channel.messages().last { $0.text.contains("networkConfiguration") })
        #expect(!published.text.contains("turn-secret"), "the TURN credential was still readable in the clear")
        let message = try OPNRemoteCoOpWireCodec.decode(published.text)
        #expect(message.networkConfiguration == nil)
        let envelope = try #require(message.encryptedNetworkConfiguration)
        let recovered: OPNRemoteCoOpNetworkConfiguration = try unseal(envelope, with: guestPrivateKey)
        #expect(recovered.iceServers.first?.credential == "turn-secret")
    }

    /// A guest with no key on file - an older cached page, or an attacker deliberately omitting one -
    /// must get no reconnect token at all, never a plaintext one: this transport has no way to seal
    /// to it, and falling back to plaintext would broadcast the token to every other invite holder
    /// reading the same channel regardless of whether *they* ever sent a key.
    @Test func participantUpdatedWithholdsTheReconnectTokenWithoutAGuestKey() async throws {
        let (session, channel, _) = makeSession()
        _ = try await collect(session) { try channel.deliverFromGuest(self.join(self.participantID), senderID: "sender-a") }

        let participant = OPNRemoteCoOpParticipant(id: participantID, displayName: "Guest", role: .guest,
                                                     connectionState: .connected, inputEnabled: true, playerIndex: 1,
                                                     reconnectToken: "plain-reconnect-token")
        await session.send(.participantUpdated(participant))

        let published = try #require(channel.messages().last { $0.text.contains("participantUpdated") })
        #expect(!published.text.contains("plain-reconnect-token"),
                "the reconnect token was sent in the clear to a guest with no key on file")
        let message = try OPNRemoteCoOpWireCodec.decode(published.text)
        #expect(message.reconnectToken == nil)
        #expect(message.participant?.reconnectToken == nil)
        #expect(message.encryptedReconnectToken == nil)
    }

    /// Same failure mode for the TURN credentials: no key on file means no `networkConfiguration`
    /// message goes out at all, sealed or not, rather than one in the clear.
    @Test func networkConfigurationIsWithheldWithoutAGuestKey() async throws {
        let (session, channel, _) = makeSession()
        _ = try await collect(session) { try channel.deliverFromGuest(self.join(self.participantID), senderID: "sender-a") }

        session.updateNetworkConfiguration(OPNRemoteCoOpNetworkConfiguration(
            transportMode: .automatic,
            iceServers: [OPNRemoteCoOpICEServer(urls: ["turn:example.com:3478"], username: "turn-user", credential: "turn-secret")]
        ))
        let participant = OPNRemoteCoOpParticipant(id: participantID, displayName: "Guest", role: .guest,
                                                     connectionState: .connected, inputEnabled: true, playerIndex: 1)
        await session.send(.participantUpdated(participant))

        #expect(!channel.messages().contains { $0.text.contains("networkConfiguration") },
                "the TURN credentials were published to a guest with no key on file")
    }

    /// A key that arrives after the first `participantUpdated` (a slow key exchange, or a retried
    /// join) must still get the TURN credentials once it does - withholding must not be permanent.
    @Test func networkConfigurationIsSentOnceTheGuestsKeyArrives() async throws {
        let (session, channel, _) = makeSession()
        _ = try await collect(session) { try channel.deliverFromGuest(self.join(self.participantID), senderID: "sender-a") }

        session.updateNetworkConfiguration(OPNRemoteCoOpNetworkConfiguration(
            transportMode: .automatic,
            iceServers: [OPNRemoteCoOpICEServer(urls: ["turn:example.com:3478"], username: "turn-user", credential: "turn-secret")]
        ))
        let participant = OPNRemoteCoOpParticipant(id: participantID, displayName: "Guest", role: .guest,
                                                     connectionState: .connected, inputEnabled: true, playerIndex: 1)
        await session.send(.participantUpdated(participant))
        #expect(!channel.messages().contains { $0.text.contains("networkConfiguration") })

        let guestPrivateKey = P256.KeyAgreement.PrivateKey()
        _ = try await collect(session) {
            try channel.deliverFromGuest(
                OPNRemoteCoOpWireMessage(kind: .guestJoinRequested, participantID: self.participantID,
                                         inviteToken: "token.signature", displayName: "Guest",
                                         guestPublicKey: guestPrivateKey.publicKey.rawRepresentation.base64EncodedString()),
                senderID: "sender-a"
            )
        }
        await session.send(.participantUpdated(participant))

        let published = try #require(channel.messages().last { $0.text.contains("networkConfiguration") })
        let message = try OPNRemoteCoOpWireCodec.decode(published.text)
        let envelope = try #require(message.encryptedNetworkConfiguration)
        let recovered: OPNRemoteCoOpNetworkConfiguration = try unseal(envelope, with: guestPrivateKey)
        #expect(recovered.iceServers.first?.credential == "turn-secret")
    }

    // MARK: - Cross-transport isolation

    /// `OPNRemoteCoOpCompositeSignalingSession` fans every command out to every transport. A
    /// participant who joined over the embedded server or the native listener never sent this
    /// transport a key - it never even saw their `guestJoinRequested` - so a command naming them must
    /// be dropped here entirely, not sent in the clear because sealing is impossible.
    @Test func participantUpdatedForAnotherTransportsGuestIsDroppedEntirely() async throws {
        let (session, channel, ownership) = makeSession()
        ownership.claim(participantID: participantID, for: OPNRemoteCoOpConnectionHandle(transport: .embedded, connectionID: "embedded-conn"))

        let participant = OPNRemoteCoOpParticipant(id: participantID, displayName: "Guest", role: .guest,
                                                     connectionState: .connected, inputEnabled: true, playerIndex: 1,
                                                     reconnectToken: "embedded-guests-secret-token")
        await session.send(.participantUpdated(participant))

        #expect(channel.messages().isEmpty, "a command about another transport's guest reached the hosted broadcast channel")
    }

    /// Same isolation for `networkConfiguration`: TURN credentials meant for an embedded guest must
    /// never be pushed onto the hosted channel just because Composite fanned the command out here too.
    @Test func networkConfigurationForAnotherTransportsGuestIsDroppedEntirely() async throws {
        let (session, channel, ownership) = makeSession()
        ownership.claim(participantID: participantID, for: OPNRemoteCoOpConnectionHandle(transport: .native, connectionID: "native-conn"))
        session.updateNetworkConfiguration(OPNRemoteCoOpNetworkConfiguration(
            transportMode: .automatic,
            iceServers: [OPNRemoteCoOpICEServer(urls: ["turn:example.com:3478"], username: "turn-user", credential: "turn-secret")]
        ))

        let participant = OPNRemoteCoOpParticipant(id: participantID, displayName: "Guest", role: .guest,
                                                     connectionState: .connected, inputEnabled: true, playerIndex: 1)
        await session.send(.participantUpdated(participant))

        #expect(channel.messages().isEmpty, "another transport's TURN credentials reached the hosted broadcast channel")
    }

    /// `peerSignal` carries WebRTC SDP - just as much another transport's business as the two secrets
    /// above, and the same fan-out reaches it.
    @Test func peerSignalForAnotherTransportsGuestIsDroppedEntirely() async throws {
        let (session, channel, ownership) = makeSession()
        ownership.claim(participantID: participantID, for: OPNRemoteCoOpConnectionHandle(transport: .embedded, connectionID: "embedded-conn"))

        await session.send(.peerSignal(participantID: participantID, signal: OPNRemoteCoOpWirePeerSignal(kind: .offer, sdp: "v=0…")))

        #expect(channel.messages().isEmpty, "another transport's SDP reached the hosted broadcast channel")
    }

    /// Mirrors the browser guest's `unsealEnvelope`: ECDH(P-256) with the host's one-time public key,
    /// HKDF-SHA256 (empty salt, this info string), AES-256-GCM. Any drift here from
    /// `OPNRemoteCoOpHostedSignalingSession.seal` would break every hosted guest silently.
    private func unseal<T: Decodable>(_ envelope: OPNRemoteCoOpWireEncryptedEnvelope,
                                       with guestPrivateKey: P256.KeyAgreement.PrivateKey) throws -> T {
        let hostPublicKeyData = try #require(Data(base64Encoded: envelope.ephemeralPublicKey))
        let hostPublicKey = try P256.KeyAgreement.PublicKey(rawRepresentation: hostPublicKeyData)
        let sharedSecret = try guestPrivateKey.sharedSecretFromKeyAgreement(with: hostPublicKey)
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: Data(), sharedInfo: Data("OpenNOW.RemoteCoOp.Hosted".utf8), outputByteCount: 32
        )
        let ciphertextAndTag = try #require(Data(base64Encoded: envelope.ciphertext))
        let nonceData = try #require(Data(base64Encoded: envelope.nonce))
        let tagLength = 16
        let ciphertext = ciphertextAndTag.prefix(ciphertextAndTag.count - tagLength)
        let tag = ciphertextAndTag.suffix(tagLength)
        let sealedBox = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonceData), ciphertext: ciphertext, tag: tag)
        let plaintext = try AES.GCM.open(sealedBox, using: symmetricKey)
        return try JSONDecoder().decode(T.self, from: plaintext)
    }

    // MARK: - Lifecycle

    @Test func closingDetachesTheChannelAndEndsTheStream() async throws {
        let (session, channel, _) = makeSession()
        let events = session.events()
        await session.close()
        #expect(channel.didDetach)

        var received = 0
        for await _ in events { received += 1 }
        #expect(received == 0, "the event stream outlived close()")
    }

    @Test func nothingIsPublishedAfterClose() async throws {
        let (session, channel, _) = makeSession()
        await session.close()
        await session.send(.guestRejected(participantID: participantID, reason: "late"))
        #expect(channel.messages().isEmpty)
    }
}

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [OPNRemoteCoOpSignalingEvent] = []

    func append(_ event: OPNRemoteCoOpSignalingEvent) {
        lock.lock()
        collected.append(event)
        lock.unlock()
    }

    func events() -> [OPNRemoteCoOpSignalingEvent] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }
}
