//  The hosted signaling transport, driven through a stub channel so nothing here needs a network or
//  an Ably account.
//

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

    private func makeSession() -> (OPNRemoteCoOpHostedSignalingSession, StubSignalingChannel) {
        let channel = StubSignalingChannel()
        return (OPNRemoteCoOpHostedSignalingSession(channel: channel), channel)
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
        let (session, channel) = makeSession()

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
            if case .guestJoinRequested(let id, _, _) = event { return id == self.participantID }
            return false
        }, "the real guest was refused a participant nobody holds")
    }

    // MARK: - Directions

    /// One channel carries both directions, separated by name. The host must never consume its own
    /// commands, whether or not the provider echoes them.
    @Test func hostCommandsArePublishedUnderTheHostName() async throws {
        let (session, channel) = makeSession()
        await session.send(.guestRejected(participantID: participantID, reason: "full"))
        let published = try #require(channel.messages().first)
        #expect(published.name == OPNRemoteCoOpHostedSignalingName.host)
        #expect(published.text.contains("guestRejected"))
        #expect(channel.messages().count == 1)
    }

    @Test func guestMessagesBecomeEvents() async throws {
        let (session, channel) = makeSession()
        let events = try await collect(session) {
            try channel.deliverFromGuest(join(participantID), senderID: "sender-a")
        }
        guard case .guestJoinRequested(let id, _, let name)? = events.first else {
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
        let (session, channel) = makeSession()
        let events = try await collect(session) {
            try channel.deliverFromGuest(
                OPNRemoteCoOpWireMessage(kind: .guestQualityRequested, participantID: participantID, qualityPreset: .p720f60),
                senderID: "sender-a"
            )
        }
        #expect(events.isEmpty, "a sender with no join acted as a participant")
    }

    @Test func aJoinedSenderCannotActAsAnother() async throws {
        let (session, channel) = makeSession()
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
        let (session, channel) = makeSession()
        let events = try await collect(session) {
            try channel.deliverFromGuest(join(participantID), senderID: "sender-a")
            try channel.deliverFromGuest(join(participantID), senderID: "sender-b")
        }
        #expect(events.count == 1, "a held participant was handed to a second sender")
    }

    /// Host-originated kinds have no producer on the guest side of the channel.
    @Test func hostKindsArrivingFromAGuestAreRefused() async throws {
        let (session, channel) = makeSession()
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
        let (session, channel) = makeSession()
        let events = try await collect(session) {
            try channel.deliverFromGuest(join(participantID), senderID: "sender-a")
            channel.deliverLeave(senderID: "sender-a")
        }
        #expect(events.contains { $0 == .guestDisconnected(participantID) })
    }

    @Test func aLeaveFromAnUnknownSenderDisconnectsNobody() async throws {
        let (session, channel) = makeSession()
        let events = try await collect(session) {
            try channel.deliverFromGuest(join(participantID), senderID: "sender-a")
            channel.deliverLeave(senderID: "sender-unknown")
        }
        #expect(!events.contains { if case .guestDisconnected = $0 { return true } else { return false } })
    }

    /// A guest that left and came back must be able to claim its participant again — the binding is
    /// released with the departure, so the claim guard does not lock them out of their own session.
    @Test func aParticipantIsReleasedOnLeaveSoTheGuestCanReturn() async throws {
        let (session, channel) = makeSession()
        let events = try await collect(session) {
            try channel.deliverFromGuest(join(participantID), senderID: "sender-a")
            channel.deliverLeave(senderID: "sender-a")
            try channel.deliverFromGuest(join(participantID), senderID: "sender-b")
        }
        let joins = events.filter { if case .guestJoinRequested = $0 { return true } else { return false } }
        #expect(joins.count == 2, "a returning guest was refused its own participant")
    }

    // MARK: - Lifecycle

    @Test func closingDetachesTheChannelAndEndsTheStream() async throws {
        let (session, channel) = makeSession()
        let events = session.events()
        await session.close()
        #expect(channel.didDetach)

        var received = 0
        for await _ in events { received += 1 }
        #expect(received == 0, "the event stream outlived close()")
    }

    @Test func nothingIsPublishedAfterClose() async throws {
        let (session, channel) = makeSession()
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
