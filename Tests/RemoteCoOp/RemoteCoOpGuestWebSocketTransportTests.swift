//
//  RemoteCoOpGuestWebSocketTransportTests.swift
//  OpenNOW
//
//  The native guest's WebSocket transport against a real embedded server.
//
//  This is the route that makes a tunnel work for guests running OpenNOW, and it is the half that
//  parsing an invite link cannot prove: the socket has to actually upgrade, carry the join, and get
//  the network configuration back. Everything here runs against `OPNRemoteCoOpEmbeddedServer` on
//  loopback rather than a stub, because the point is that the two speak the same protocol.
//

import Foundation
import Testing
@testable import OpenNOW

@Suite("Remote Co-Op guest WebSocket transport", .serialized)
struct RemoteCoOpGuestWebSocketTransportTests {
    /// The embedded server's certificate is self-signed by construction - there is no authority that
    /// will issue one for a private address - so a test client has to accept it. Production does not
    /// take this path: `OPNRemoteCoOpNativeGuestWebSocketConnection` validates normally unless a
    /// session is injected, which only tests do.
    private final class TrustingDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
            return (.useCredential, URLCredential(trust: trust))
        }
    }

    private func startServer() async throws -> (OPNRemoteCoOpEmbeddedServer, OPNRemoteCoOpEmbeddedServerEndpoint, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("coop-ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<html>guest</html>".utf8).write(to: root.appendingPathComponent("index.html"))
        let server = OPNRemoteCoOpEmbeddedServer(
            documentRoot: root,
            networkConfiguration: OPNRemoteCoOpNetworkConfiguration(transportMode: .automatic, latencyMode: .lowLatency)
        )
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("coop-ws-tls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let p12 = try OPNRemoteCoOpTLSIdentity.generateP12(host: "127.0.0.1", passphrase: "pass", directory: scratch)
        let identity = try OPNRemoteCoOpTLSIdentity.importIdentity(p12: p12, passphrase: "pass")
        // Port 0, so the system guarantees a free one.
        //
        // Hand-allocated ports were not enough: the listener sets `allowLocalEndpointReuse`, so two
        // servers on the same port both bind successfully and connections go to whichever the kernel
        // picks. That surfaces as a TLS error - the client validating a certificate minted by another
        // test's server - which reads as a transport bug rather than a port collision.
        let endpoint = try await server.start(port: 0, advertisedHost: "127.0.0.1", identity: identity)
        return (server, endpoint, root)
    }

    private func makeConnection(_ endpoint: OPNRemoteCoOpEmbeddedServerEndpoint) throws -> OPNRemoteCoOpNativeGuestWebSocketConnection {
        let url = try #require(URL(string: endpoint.signalingServerURL))
        return OPNRemoteCoOpNativeGuestWebSocketConnection(signalingURL: url) { configuration in
            URLSession(configuration: configuration, delegate: TrustingDelegate(), delegateQueue: nil)
        }
    }

    /// Waits for the first message of a kind, rather than assuming it is the first message at all.
    private func firstMessage(ofKind kind: OPNRemoteCoOpWireMessageKind,
                              from messages: AsyncStream<OPNRemoteCoOpWireMessage>,
                              timeout: Duration = .seconds(10)) async -> OPNRemoteCoOpWireMessage? {
        await withTaskGroup(of: OPNRemoteCoOpWireMessage?.self) { group in
            group.addTask {
                for await message in messages where message.kind == kind { return message }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    @Test("a guest joins over the WebSocket and is given the session's network configuration")
    func guestJoinsOverWebSocket() async throws {
        let (server, endpoint, root) = try await startServer()
        defer { try? FileManager.default.removeItem(at: root) }
        let hostSession = OPNRemoteCoOpHostSession(preferences: OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 1, requireHostApproval: true))
        let coordinator = OPNRemoteCoOpHostCoordinator(hostSession: hostSession, signaling: OPNEmbeddedRemoteCoOpSignalingSession(server: server))
        let invite = try await coordinator.startInvite(lifetimeSeconds: 120)

        // The host's listen loop is what drives the coordinator in production; without it here the
        // join is never verified, and an unverified join is deliberately given nothing.
        let events = await server.events()
        let pump = Task { for await event in events { _ = await coordinator.handle(event) } }
        defer { pump.cancel() }

        let connection = try makeConnection(endpoint)
        let messages = connection.messages()
        try await connection.connect()

        let participantID = UUID()
        try await connection.send(OPNRemoteCoOpWireMessage(
            kind: .guestJoinRequested,
            participantID: participantID,
            inviteToken: invite.token,
            displayName: "Native Guest"
        ))

        // The WebSocket server never greets with `hostHello` - a browser reads the token out of its
        // own URL - so this is the first thing a guest hears back, and it is what starts their peer
        // connection. It arrives once the coordinator has verified the invite, never before: the
        // configuration carries relay credentials.
        let configuration = await firstMessage(ofKind: .networkConfiguration, from: messages)
        let received = try #require(configuration, "no networkConfiguration came back from the join")
        #expect(received.participantID == participantID)
        #expect(received.networkConfiguration?.latencyMode == .lowLatency)

        connection.close()
        await server.stop()
    }

    @Test("the guest's join reaches the host session as a real participant")
    func joinRegistersParticipant() async throws {
        let (server, endpoint, root) = try await startServer()
        defer { try? FileManager.default.removeItem(at: root) }
        let hostSession = OPNRemoteCoOpHostSession(preferences: OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 1, requireHostApproval: true))
        let signaling = OPNEmbeddedRemoteCoOpSignalingSession(server: server)
        let coordinator = OPNRemoteCoOpHostCoordinator(hostSession: hostSession, signaling: signaling)
        let invite = try await coordinator.startInvite(lifetimeSeconds: 120)

        // The host side of a real session: signaling events are handled by the coordinator, which is
        // what turns a join request into a participant.
        let listener = Task {
            for await event in signaling.events() {
                _ = await coordinator.handle(event)
            }
        }
        defer { listener.cancel() }

        let connection = try makeConnection(endpoint)
        let messages = connection.messages()
        try await connection.connect()
        let participantID = UUID()
        try await connection.send(OPNRemoteCoOpWireMessage(
            kind: .guestJoinRequested,
            participantID: participantID,
            inviteToken: invite.token,
            displayName: "Native Guest"
        ))
        _ = await firstMessage(ofKind: .participantUpdated, from: messages)

        let participants = await hostSession.snapshot().participants
        #expect(participants.contains { $0.id == participantID && $0.displayName == "Native Guest" })

        connection.close()
        await server.stop()
    }

    @Test("a join with a token the host never issued is rejected")
    func joinWithBadTokenIsRejected() async throws {
        let (server, endpoint, root) = try await startServer()
        defer { try? FileManager.default.removeItem(at: root) }
        let hostSession = OPNRemoteCoOpHostSession(preferences: OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 1, requireHostApproval: true))
        let signaling = OPNEmbeddedRemoteCoOpSignalingSession(server: server)
        let coordinator = OPNRemoteCoOpHostCoordinator(hostSession: hostSession, signaling: signaling)
        _ = try await coordinator.startInvite(lifetimeSeconds: 120)
        let listener = Task {
            for await event in signaling.events() {
                _ = await coordinator.handle(event)
            }
        }
        defer { listener.cancel() }

        let connection = try makeConnection(endpoint)
        let messages = connection.messages()
        try await connection.connect()
        let participantID = UUID()
        // Reaching the socket is not authorisation. The invite is signed, so a guest who found the
        // tunnel without being given the link gets no further than this.
        try await connection.send(OPNRemoteCoOpWireMessage(
            kind: .guestJoinRequested,
            participantID: participantID,
            inviteToken: "not-a-real-token",
            displayName: "Uninvited"
        ))
        let rejection = await firstMessage(ofKind: .guestRejected, from: messages)
        #expect(rejection != nil, "an unsigned token should be rejected, not ignored")
        #expect(await hostSession.snapshot().participants.isEmpty)

        connection.close()
        await server.stop()
    }

    @Test("closing the transport ends its message stream")
    func closingEndsTheStream() async throws {
        let (server, endpoint, root) = try await startServer()
        defer { try? FileManager.default.removeItem(at: root) }
        let connection = try makeConnection(endpoint)
        let messages = connection.messages()
        try await connection.connect()
        connection.close()

        // The guest view model's pump exits on stream end; a stream that never finished would leave
        // the join screen believing it was still connected.
        var delivered = 0
        for await _ in messages { delivered += 1 }
        #expect(delivered == 0)
        await #expect(throws: (any Error).self) {
            try await connection.send(OPNRemoteCoOpWireMessage(kind: .heartbeat))
        }
        await server.stop()
    }
}
