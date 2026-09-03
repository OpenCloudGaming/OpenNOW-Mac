//  The native guest transport: frame framing, the loopback path between the host listener and a
//  guest connection, and the composite session that serves browser and native guests at once.
//

import Foundation
import Network
import Testing
@testable import OpenNOW

@Suite("Native Remote Co-Op guest", .serialized)
struct RemoteCoOpNativeGuestTests {
    // MARK: - Framing

    @Test("frame codec round-trips a message")
    func frameCodecRoundTrip() throws {
        var codec = OPNRemoteCoOpNativeFrameCodec()
        let message = OPNRemoteCoOpWireMessage(kind: .guestJoinRequested, participantID: UUID(), inviteToken: "token.123", displayName: "Mia")
        let frame = try OPNRemoteCoOpNativeFrameCodec.encode(message)
        let decoded = try codec.append(frame)
        #expect(decoded == [message])
    }

    @Test("frame codec handles frames split across and coalesced within reads")
    func frameCodecSplitAndCoalesced() throws {
        var codec = OPNRemoteCoOpNativeFrameCodec()
        let first = OPNRemoteCoOpWireMessage(kind: .hostHello)
        let second = OPNRemoteCoOpWireMessage(kind: .inviteEnded, participantID: UUID())
        let combined = try OPNRemoteCoOpNativeFrameCodec.encode(first) + OPNRemoteCoOpNativeFrameCodec.encode(second)

        // Split at an arbitrary byte: nothing decodes until the delimiter arrives whole.
        let split = combined.index(combined.startIndex, offsetBy: 7)
        #expect(try codec.append(Data(combined[..<split])).isEmpty)
        let decoded = try codec.append(Data(combined[split...]))
        #expect(decoded == [first, second])
    }

    @Test("frame codec rejects an unterminated oversized frame")
    func frameCodecRejectsOversizedFrame() throws {
        var codec = OPNRemoteCoOpNativeFrameCodec()
        do {
            _ = try codec.append(Data(repeating: 0x41, count: OPNRemoteCoOpNativeFrameCodec.maximumFrameBytes + 1))
            Issue.record("Expected the oversized frame to be rejected")
        } catch {
            #expect(error as? OPNRemoteCoOpNativeFrameError == .frameTooLarge)
        }
    }

    // MARK: - Loopback

    @Test("guest join request over the loopback socket becomes a signaling event")
    func loopbackJoinRequest() async throws {
        let invite = OPNRemoteCoOpInvite(code: "ABC123", expiresAt: Date().addingTimeInterval(600), token: "signed-token")
        let server = OPNRemoteCoOpNativeGuestServer(
            inviteProvider: { invite },
            networkConfiguration: OPNRemoteCoOpNetworkConfiguration(transportMode: .directOnly)
        )
        server.start()
        let port = try await waitForPort(on: server)
        defer { Task { await server.close() } }

        // Subscribed before the guest connects so the event cannot beat the subscription.
        let events = server.events()
        let connection = OPNRemoteCoOpNativeGuestConnection(endpoint: .hostPort(host: "127.0.0.1", port: try #require(NWEndpoint.Port(rawValue: port))))
        try await connection.connect()
        defer { connection.close() }

        let participantID = UUID()
        try await connection.send(OPNRemoteCoOpWireMessage(kind: .guestJoinRequested, participantID: participantID, inviteToken: invite.token, displayName: "Mia"))

        let event = try await firstEvent(in: events) { candidate in
            if case .guestJoinRequested = candidate { return true }
            return false
        }
        guard case .guestJoinRequested(let joinedID, let token, let name) = event else {
            Issue.record("Expected a guestJoinRequested event, got \(event)")
            return
        }
        #expect(joinedID == participantID)
        #expect(token == invite.token)
        #expect(name == "Mia")
    }

    @Test("guest receives the invite on connect, but not the relay credentials")
    func guestReceivesGreeting() async throws {
        let invite = OPNRemoteCoOpInvite(code: "XYZ789", expiresAt: Date().addingTimeInterval(600), token: "signed-token")
        let server = OPNRemoteCoOpNativeGuestServer(
            inviteProvider: { invite },
            networkConfiguration: OPNRemoteCoOpNetworkConfiguration(transportMode: .directOnly)
        )
        server.start()
        let port = try await waitForPort(on: server)
        defer { Task { await server.close() } }

        let connection = OPNRemoteCoOpNativeGuestConnection(endpoint: .hostPort(host: "127.0.0.1", port: try #require(NWEndpoint.Port(rawValue: port))))
        // Subscribed before connect: the greeting is the first thing the server sends, and a
        // stream created afterwards can miss it.
        let messages = connection.messages()
        try await connection.connect()
        defer { connection.close() }

        // Drained for a window rather than counted.
        //
        // `collectMessages(count: 1)` breaks after the first message, so the array held `hostHello`
        // by construction and "does not contain networkConfiguration" was true whatever the server
        // sent second - the assertion passed with the leak restored, which is the worst kind of
        // regression test. Collecting everything that arrives in a window makes a second message
        // visible, and `hostHello` doubles as the positive control: seeing it proves this stream
        // would have surfaced a configuration had one been sent.
        let greeting = try await collectMessages(from: messages, until: .hostHello, thenFor: .milliseconds(300))
        #expect(greeting.contains { $0.kind == .hostHello && $0.invite?.token == invite.token })
        #expect(!greeting.contains { $0.kind == .networkConfiguration },
                "relay credentials sent in the greeting, before the guest presented anything")
    }

    @Test("targeted commands reach only the addressed guest's connection, broadcasts reach everyone")
    func targetedAndBroadcastRouting() async throws {
        let invite = OPNRemoteCoOpInvite(code: "DEF456", expiresAt: Date().addingTimeInterval(600), token: "signed-token")
        let server = OPNRemoteCoOpNativeGuestServer(
            inviteProvider: { invite },
            networkConfiguration: OPNRemoteCoOpNetworkConfiguration(transportMode: .directOnly)
        )
        server.start()
        let port = try await waitForPort(on: server)
        defer { Task { await server.close() } }

        let guestA = OPNRemoteCoOpNativeGuestConnection(endpoint: .hostPort(host: "127.0.0.1", port: try #require(NWEndpoint.Port(rawValue: port))))
        let guestB = OPNRemoteCoOpNativeGuestConnection(endpoint: .hostPort(host: "127.0.0.1", port: try #require(NWEndpoint.Port(rawValue: port))))
        let streamA = guestA.messages()
        let streamB = guestB.messages()
        try await guestA.connect()
        try await guestB.connect()
        defer { guestA.close(); guestB.close() }

        // Each connection's greeting is `hostHello` alone; the network configuration is withheld
        // until the guest's invite verifies.
        _ = try await collectMessages(from: streamA, count: 1)
        _ = try await collectMessages(from: streamB, count: 1)

        let idA = UUID()
        let idB = UUID()
        try await guestA.send(OPNRemoteCoOpWireMessage(kind: .guestJoinRequested, participantID: idA, inviteToken: invite.token, displayName: "A"))
        try await guestB.send(OPNRemoteCoOpWireMessage(kind: .guestJoinRequested, participantID: idB, inviteToken: invite.token, displayName: "B"))
        // Give the server a turn to learn the participant-to-connection mapping before commands.
        try await Task.sleep(nanoseconds: 200_000_000)

        await server.send(.guestRejected(participantID: idA, reason: "No room"))

        let rejection = try await firstMessage(in: streamA) { $0.kind == .guestRejected }
        #expect(rejection.reason == "No room")

        // The same window must not deliver A's rejection to B; assert via B receiving the later
        // broadcast without a rejection in between.
        await server.send(.participantRemoved(idB))
        let sawRejectionOnB = OPNRemoteCoOpMessageBox()
        let broadcast = try await firstMessage(in: streamB) { message in
            if message.kind == .guestRejected { sawRejectionOnB.mark() }
            return message.kind == .participantRemoved
        }
        #expect(broadcast.participantID == idB)
        #expect(!sawRejectionOnB.wasMarked)
    }

    // MARK: - Composite

    @Test("composite session merges events and fans commands out")
    func compositeSessionFanOut() async throws {
        let first = OPNInProcessRemoteCoOpSignalingSession()
        let second = OPNInProcessRemoteCoOpSignalingSession()
        let composite = OPNRemoteCoOpCompositeSignalingSession(sessions: [first, second])

        let events = composite.events()
        // The composite forwards each child session's events from a task; give those tasks a run
        // loop turn to subscribe before publishing, or the events land before anyone listens.
        try await Task.sleep(nanoseconds: 100_000_000)
        first.publish(.guestDisconnected(UUID()))
        second.publish(.guestDisconnected(UUID()))
        let merged = try await withTimeout { () -> [OPNRemoteCoOpSignalingEvent] in
            var collected: [OPNRemoteCoOpSignalingEvent] = []
            for await event in events {
                collected.append(event)
                if collected.count == 2 { break }
            }
            return collected
        }
        #expect(merged.count == 2)

        await composite.send(.inviteEnded)
        #expect(first.commandHistory().contains(.inviteEnded))
        #expect(second.commandHistory().contains(.inviteEnded))
        await composite.close()
    }

    // MARK: - Helpers

    private func waitForPort(on server: OPNRemoteCoOpNativeGuestServer) async throws -> UInt16 {
        for _ in 0..<100 {
            if let port = server.port { return port }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        Issue.record("Native guest server never bound a port")
        throw OPNRemoteCoOpNativeConnectionError.closed
    }

    private func firstEvent(in events: AsyncStream<OPNRemoteCoOpSignalingEvent>,
                            matching predicate: @escaping @Sendable (OPNRemoteCoOpSignalingEvent) -> Bool) async throws -> OPNRemoteCoOpSignalingEvent {
        try await withTimeout {
            for await event in events where predicate(event) {
                return event
            }
            throw OPNRemoteCoOpNativeConnectionError.closed
        }
    }

    /// Everything that arrives within `duration`, rather than the first N.
    ///
    /// Needed wherever the assertion is that something must *not* arrive: a count-based collect
    /// cannot see the message it is meant to rule out.
    /// Waits for the message that proves the stream is live, then keeps draining for a short window
    /// so an *absence* can still be asserted.
    ///
    /// A fixed window alone was a flake: the greeting is sent from a Task on the server, and under
    /// full-suite load 700ms could pass before it arrived, failing a test about content with a
    /// timing failure. Adding a `print` to diagnose it made it pass, which is the tell. Waiting for
    /// the anchor removes the race; the trailing window is what makes "and nothing followed"
    /// meaningful, and only runs once the anchor is in hand.
    private func collectMessages(from stream: AsyncStream<OPNRemoteCoOpWireMessage>,
                                 until anchor: OPNRemoteCoOpWireMessageKind,
                                 thenFor trailing: Duration) async throws -> [OPNRemoteCoOpWireMessage] {
        let box = OPNRemoteCoOpMessageCollector()
        let drain = Task {
            for await message in stream { box.append(message) }
        }
        defer { drain.cancel() }
        try await withTimeout {
            while !box.messages().contains(where: { $0.kind == anchor }) {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try? await Task.sleep(for: trailing)
        return box.messages()
    }

    private func collectMessages(from stream: AsyncStream<OPNRemoteCoOpWireMessage>,
                                 for duration: Duration) async -> [OPNRemoteCoOpWireMessage] {
        let box = OPNRemoteCoOpMessageCollector()
        let drain = Task {
            for await message in stream { box.append(message) }
        }
        try? await Task.sleep(for: duration)
        drain.cancel()
        return box.messages()
    }

    private func collectMessages(from stream: AsyncStream<OPNRemoteCoOpWireMessage>, count: Int) async throws -> [OPNRemoteCoOpWireMessage] {
        try await withTimeout {
            var messages: [OPNRemoteCoOpWireMessage] = []
            for await message in stream {
                messages.append(message)
                if messages.count == count { break }
            }
            return messages
        }
    }

    private func firstMessage(in messages: AsyncStream<OPNRemoteCoOpWireMessage>,
                              matching predicate: @escaping @Sendable (OPNRemoteCoOpWireMessage) -> Bool) async throws -> OPNRemoteCoOpWireMessage {
        try await withTimeout {
            for await message in messages {
                if predicate(message) { return message }
            }
            throw OPNRemoteCoOpNativeConnectionError.closed
        }
    }

    private func withTimeout<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                throw OPNRemoteCoOpNativeConnectionError.closed
            }
            guard let result = try await group.next() else { throw OPNRemoteCoOpNativeConnectionError.closed }
            group.cancelAll()
            return result
        }
    }
}

/// Crosses the `@Sendable` predicate boundary in `firstMessage` so a test can assert a message
/// never arrived without mutating a captured var.
private final class OPNRemoteCoOpMessageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var marked = false

    func mark() {
        lock.lock()
        marked = true
        lock.unlock()
    }

    var wasMarked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return marked
    }
}

/// Collects across a cancelled drain task, so the caller can assert on what did *not* arrive.
private final class OPNRemoteCoOpMessageCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [OPNRemoteCoOpWireMessage] = []

    func append(_ message: OPNRemoteCoOpWireMessage) {
        lock.lock()
        collected.append(message)
        lock.unlock()
    }

    func messages() -> [OPNRemoteCoOpWireMessage] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }
}
