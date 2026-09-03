//  The embedded server end to end: a real TLS listener, a real WebSocket upgrade, and the
//  authorisation cases that decide whether a guest may act as a participant at all.
//
//  Split from `RemoteCoOpServerProtocolTests.swift`, which held eight independent suites. The wire
//  layers stayed there; everything that stands a server up lives here.
//

import Foundation
import Security
import Testing
@testable import OpenNOW

@Suite struct RemoteCoOpEmbeddedServerTests {
    /// Trusts the server's self-signed certificate, which is exactly what a guest does after
    /// clicking through the browser warning.
    private final class TrustingDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
            return (.useCredential, URLCredential(trust: trust))
        }
    }

    private func makeDocumentRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("coop-doc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<html>guest</html>".utf8).write(to: root.appendingPathComponent("index.html"))
        return root
    }

    /// A port in the ephemeral range, varied per test so a lingering listener from a previous run
    /// cannot make this fail for an unrelated reason.
    private func makeServer(root: URL,
                           networkConfiguration: OPNRemoteCoOpNetworkConfiguration? = nil) async throws -> (OPNRemoteCoOpEmbeddedServer, OPNRemoteCoOpEmbeddedServerEndpoint, URLSession) {
        let configuration = networkConfiguration ?? OPNRemoteCoOpNetworkConfiguration(transportMode: .directOnly, latencyMode: .lowLatency)
        let server = OPNRemoteCoOpEmbeddedServer(documentRoot: root, networkConfiguration: configuration)
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("coop-tls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let p12 = try OPNRemoteCoOpTLSIdentity.generateP12(host: "127.0.0.1", passphrase: "pass", directory: scratch)
        let identity = try OPNRemoteCoOpTLSIdentity.importIdentity(p12: p12, passphrase: "pass")

        // Port 0: the system picks a free one and `start` reports which. Random ports in a fixed range
        // collided between tests running in parallel, and the losing one saw "could not connect"
        // rather than a bind failure, because the listener failed asynchronously after start returned.
        let endpoint = try await server.start(port: 0, advertisedHost: "127.0.0.1", identity: identity)
        let session = URLSession(configuration: .ephemeral, delegate: TrustingDelegate(), delegateQueue: nil)
        return (server, endpoint, session)
    }

    @Test func servesTheGuestPageOverHTTPS() async throws {
        let root = try makeDocumentRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (server, endpoint, session) = try await makeServer(root: root)
        defer { Task { await server.stop() } }

        let (data, response) = try await session.data(from: try #require(URL(string: endpoint.guestJoinBaseURL)))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == "<html>guest</html>")
        // The page and the socket share an origin, which is what makes one accepted certificate
        // cover both.
        #expect(endpoint.signalingServerURL.contains("\(endpoint.port)"))
        #expect(endpoint.certificateFingerprint?.isEmpty == false)
    }

    /// The real shipped `Resources/RemoteCoOp/browser` directory rather than `bundledDocumentRoot()`,
    /// which resolves through `Bundle.main` and finds nothing useful in a test runner - it only
    /// resolves inside the built app. Located via `#filePath`, which is where this test file itself
    /// lives, so the path holds regardless of the working directory a run starts from.
    private static let realBrowserDocumentRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/RemoteCoOp/browser")

    /// The vendored Ably SDK is a real file the server has to be able to serve, not a copy that only
    /// exists in this test's fixture - a guest page that references a script the server cannot find
    /// fails silently in the browser console, which nothing else here would catch.
    @Test func servesTheVendoredAblySDK() async throws {
        let root = Self.realBrowserDocumentRoot
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("index.html").path) else {
            Issue.record("Resources/RemoteCoOp/browser did not resolve to \(root.path) - the #filePath layout assumption is wrong")
            return
        }
        let (server, endpoint, session) = try await makeServer(root: root)
        defer { Task { await server.stop() } }

        let url = try #require(URL(string: endpoint.guestJoinBaseURL + "vendor/ably.min.js"))
        let (data, response) = try await session.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.contains("javascript") == true)

        let onDisk = try Data(contentsOf: root.appendingPathComponent("vendor/ably.min.js"))
        #expect(data == onDisk)
        #expect(!data.isEmpty)
    }

    /// `index.html` must actually reference the vendored script by the path the server serves it at,
    /// or the two drift silently: the file could exist and never be loaded.
    @Test func indexPageReferencesTheVendoredSDKAtItsRealPath() throws {
        let html = try String(contentsOf: Self.realBrowserDocumentRoot.appendingPathComponent("index.html"), encoding: .utf8)
        #expect(html.contains(#"src="./vendor/ably.min.js""#))
        // Loaded as a plain script rather than a module, so it attaches `Ably` to `window` for
        // app.js's module scope to read - a module-scoped script would not be visible to it.
        #expect(!html.contains(#"type="module" src="./vendor/ably.min.js""#))
    }

    @Test func refusesPathsOutsideTheGuestPage() async throws {
        let root = try makeDocumentRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (server, endpoint, session) = try await makeServer(root: root)
        defer { Task { await server.stop() } }

        let url = try #require(URL(string: endpoint.guestJoinBaseURL + "nope.js"))
        let (_, response) = try await session.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 404)
    }

    /// The join a browser performs: upgrade on the same origin, send `guestJoinRequested`, and
    /// receive the network configuration the guest page waits for before it builds a peer
    /// connection. The host-side event must surface with the guest's own participant ID.
    @Test func completesAGuestJoinOverWSS() async throws {
        let root = try makeDocumentRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (server, endpoint, session) = try await makeServer(root: root)
        defer { Task { await server.stop() } }

        let events = await server.events()
        let received = Task { () -> OPNRemoteCoOpSignalingEvent? in
            for await event in events { return event }
            return nil
        }

        let socket = session.webSocketTask(with: try #require(URL(string: endpoint.signalingServerURL)))
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        let participantID = UUID()
        let join = OPNRemoteCoOpWireMessage(
            kind: .guestJoinRequested,
            roomID: UUID(),
            participantID: participantID,
            inviteToken: "token.signature",
            displayName: "Tester"
        )
        try await socket.send(.string(try OPNRemoteCoOpWireCodec.encode(join)))

        // No reply yet: the ICE configuration is not sent until the invite has verified, and this
        // socket's token has not been. The host-side event is what fires first.
        let event = try #require(await received.value)
        guard case .guestJoinRequested(let eventParticipantID, _, let displayName) = event else {
            Issue.record("expected a guest join event, got \(event)")
            return
        }
        #expect(eventParticipantID == participantID)
        #expect(displayName == "Tester")

        // Verification is the coordinator's job, and `participantUpdated` is how it reports success.
        // Only then does the configuration go out - ahead of the update, because the guest builds its
        // peer connection from it.
        await server.send(.participantUpdated(OPNRemoteCoOpParticipant(
            id: participantID, displayName: "Tester", role: .guest, connectionState: .connected, inputEnabled: true, playerIndex: 1
        )))
        guard case .string(let text) = try await socket.receive() else {
            Issue.record("expected a text frame")
            return
        }
        let reply = try OPNRemoteCoOpWireCodec.decode(text)
        #expect(reply.kind == .networkConfiguration)
        #expect(reply.networkConfiguration?.transportMode == .directOnly)
        // Direct Only withholds relay candidates; the guest page reads this to configure ICE.
        #expect(reply.networkConfiguration?.iceTransportPolicy == .all)
    }

    /// Relay credentials must not reach a socket whose invite has not verified.
    ///
    /// The join guard only checks the token is non-empty; the signature is checked later by the host
    /// session. While `iceServers` carried only public STUN URLs that was harmless, but they now
    /// carry a relay username and credential - and the tunnel feature exposes this port to the
    /// internet, so replying on join handed anyone who could reach it the host's relay allowance.
    @Test func withholdsRelayCredentialsUntilTheInviteVerifies() async throws {
        let root = try makeDocumentRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let relay = OPNRemoteCoOpNetworkConfiguration(
            transportMode: .automatic,
            iceServers: [OPNRemoteCoOpICEServer(urls: ["turns:relay.example:443"], username: "u", credential: "SENTINEL")]
        )
        let (server, endpoint, session) = try await makeServer(root: root, networkConfiguration: relay)
        defer { Task { await server.stop() } }

        let socket = session.webSocketTask(with: try #require(URL(string: endpoint.signalingServerURL)))
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        let (collector, reader) = startCollecting(socket)
        defer { reader.cancel() }

        let participantID = UUID()
        try await socket.send(.string(try OPNRemoteCoOpWireCodec.encode(OPNRemoteCoOpWireMessage(
            kind: .guestJoinRequested,
            roomID: UUID(),
            participantID: participantID,
            inviteToken: "not-a-real-signature",
            displayName: "Attacker"
        ))))

        await settle()
        #expect(!collector.texts().contains { $0.contains("SENTINEL") },
                "relay credential sent to a socket whose invite never verified")

        // Positive control, and the point of the test: the same socket does receive the configuration
        // once the coordinator reports the invite good. Without this, the assertion above would also
        // pass if the socket were simply dead - which is how the first version of this test passed
        // while guarding nothing at all.
        await server.send(.participantUpdated(OPNRemoteCoOpParticipant(
            id: participantID, displayName: "Attacker", role: .guest, connectionState: .connected, inputEnabled: true, playerIndex: 1
        )))
        await settle()
        #expect(collector.texts().contains { $0.contains("SENTINEL") },
                "configuration never arrived even after verification, so the check above proves nothing")
    }

    /// A heartbeat is absorbed, never answered.
    ///
    /// Both guest clients reply to every heartbeat they receive, so echoing one started an unbounded
    /// ping-pong bounded only by round-trip time, on the machine playing the game.
    @Test func doesNotAnswerAGuestHeartbeat() async throws {
        let root = try makeDocumentRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (server, endpoint, session) = try await makeServer(root: root)
        defer { Task { await server.stop() } }

        let socket = session.webSocketTask(with: try #require(URL(string: endpoint.signalingServerURL)))
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        let (collector, reader) = startCollecting(socket)
        defer { reader.cancel() }

        // Joined first only so the positive control below has a participant to address. The join
        // itself releases nothing: the configuration waits for `participantUpdated`.
        let participantID = UUID()
        try await socket.send(.string(try OPNRemoteCoOpWireCodec.encode(OPNRemoteCoOpWireMessage(
            kind: .guestJoinRequested,
            roomID: UUID(),
            participantID: participantID,
            inviteToken: "token.signature",
            displayName: "Tester"
        ))))
        try await socket.send(.string(try OPNRemoteCoOpWireCodec.encode(
            OPNRemoteCoOpWireMessage(kind: .heartbeat, roomID: UUID())
        )))
        await settle()
        #expect(!collector.texts().contains { $0.contains("heartbeat") },
                "server echoed a heartbeat, which both guest clients answer")

        // Positive control: the socket does deliver server-originated frames, so the silence above is
        // the server declining to answer rather than a connection that was never alive. `guestRejected`
        // rather than `inviteEnded`, because that one cancels every socket immediately after
        // broadcasting and so races its own flush.
        await server.send(.guestRejected(participantID: participantID, reason: "control"))
        await settle()
        #expect(collector.texts().contains { $0.contains("guestRejected") },
                "socket delivered nothing at all, so the heartbeat assertion proves nothing")
    }

    /// One reader for the whole test, sampled at checkpoints.
    ///
    /// Assertions about what must *not* arrive need a continuous reader: a single `receive` cannot
    /// distinguish "nothing was sent" from "the socket is broken". It has to be one reader rather
    /// than one per checkpoint, because cancelling a Task does not cancel an in-flight
    /// `URLSessionWebSocketTask.receive` - the abandoned call stays registered and swallows the next
    /// frame, which is exactly what made the first version of these positive controls fail.
    private func startCollecting(_ socket: URLSessionWebSocketTask) -> (OPNRemoteCoOpTextCollector, Task<Void, Never>) {
        let collector = OPNRemoteCoOpTextCollector()
        let reader = Task {
            while !Task.isCancelled {
                guard case .string(let text) = try? await socket.receive() else { return }
                collector.append(text)
            }
        }
        return (collector, reader)
    }

    private func settle(_ duration: Duration = .milliseconds(700)) async {
        try? await Task.sleep(for: duration)
    }

    /// A socket that has not joined must not be able to act as a participant it does not own,
    /// otherwise a second guest could send input or peer signals as the first.
    @Test func ignoresSignalingForAParticipantTheSocketDoesNotOwn() async throws {
        let root = try makeDocumentRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (server, endpoint, session) = try await makeServer(root: root)
        defer { Task { await server.stop() } }

        let events = await server.events()
        let collected = Task { () -> [OPNRemoteCoOpSignalingEvent] in
            var result: [OPNRemoteCoOpSignalingEvent] = []
            for await event in events {
                result.append(event)
                if result.count == 2 { break }
            }
            return result
        }

        let socket = session.webSocketTask(with: try #require(URL(string: endpoint.signalingServerURL)))
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        let owner = UUID()
        try await socket.send(.string(try OPNRemoteCoOpWireCodec.encode(OPNRemoteCoOpWireMessage(
            kind: .guestJoinRequested, roomID: UUID(), participantID: owner, inviteToken: "a.b", displayName: "Owner"))))
        _ = try await socket.receive()

        // Same socket, a different participant's disconnect. Must be dropped.
        try await socket.send(.string(try OPNRemoteCoOpWireCodec.encode(OPNRemoteCoOpWireMessage(
            kind: .guestDisconnected, roomID: nil, participantID: UUID()))))
        try await socket.send(.string(try OPNRemoteCoOpWireCodec.encode(OPNRemoteCoOpWireMessage(
            kind: .guestDisconnected, roomID: nil, participantID: owner))))

        let events2 = await collected.value
        #expect(events2.count == 2)
        guard case .guestJoinRequested = events2.first else {
            Issue.record("expected the join first")
            return
        }
        guard case .guestDisconnected(let disconnected) = events2.last else {
            Issue.record("expected a disconnect second")
            return
        }
        // The forged one was dropped, so the only disconnect through is the socket's own.
        #expect(disconnected == owner)
    }
}

/// The embedded server's pre-auth surface. It listens on the machine playing the game and holding
/// the user's session tokens, so what an unauthenticated peer can reach matters.
@Suite struct RemoteCoOpEmbeddedServerHardeningTests {
    private func allowed(_ origin: String?, additional: [String] = []) -> Bool {
        OPNRemoteCoOpEmbeddedServer.isOriginAllowed(origin, port: 32_188, additional: additional.map { $0.lowercased() })
    }

    /// A WebSocket is not subject to the same-origin policy the way `fetch` is - any page in any tab
    /// can open one and the browser will send it - so an unrelated site must not get as far as
    /// speaking the protocol.
    @Test func anUnrelatedWebsiteCannotOpenTheSignalingSocket() {
        #expect(!allowed("https://evil.example.com"))
        #expect(!allowed("https://evil.example.com:32188"))
        #expect(!allowed("http://localhost:32188"))
        // A public address on the right port is still refused: something is proxying, and that has
        // to be named as a tunnel origin rather than inferred.
        #expect(!allowed("https://203.0.113.10:32188"))
    }

    /// Every form a browser produces for this machine's own listener.
    @Test func thisMachinesOwnOriginsAreAllowed() {
        #expect(allowed("https://localhost:32188"))
        #expect(allowed("https://127.0.0.1:32188"))
        #expect(allowed("https://192.168.1.25:32188"))
        #expect(allowed("https://10.0.0.4:32188"))
        #expect(allowed("https://172.16.9.9:32188"))
        // Case is not significant in an origin.
        #expect(allowed("HTTPS://LOCALHOST:32188"))
    }

    /// A tunnel's public hostname has to be accepted explicitly, because guests arrive with the
    /// tunnel's origin rather than this machine's.
    @Test func aConfiguredTunnelOriginIsAllowed() {
        #expect(allowed("https://abc123.ngrok-free.app", additional: ["https://abc123.ngrok-free.app"]))
        // Only the configured one.
        #expect(!allowed("https://other.ngrok-free.app", additional: ["https://abc123.ngrok-free.app"]))
    }

    /// Non-browser clients omit `Origin` entirely, and the guest page is not the only legitimate
    /// client - the smoke checks and test harness connect directly.
    @Test func aMissingOriginIsAllowed() {
        #expect(allowed(nil))
        #expect(allowed(""))
    }

    @Test func privateAddressDetectionMatchesRFC1918() {
        #expect(OPNRemoteCoOpEmbeddedServer.isPrivateIPv4("10.1.2.3"))
        #expect(OPNRemoteCoOpEmbeddedServer.isPrivateIPv4("192.168.0.1"))
        #expect(OPNRemoteCoOpEmbeddedServer.isPrivateIPv4("172.31.255.255"))
        #expect(OPNRemoteCoOpEmbeddedServer.isPrivateIPv4("169.254.1.1"))
        #expect(!OPNRemoteCoOpEmbeddedServer.isPrivateIPv4("172.32.0.1"))
        #expect(!OPNRemoteCoOpEmbeddedServer.isPrivateIPv4("8.8.8.8"))
        #expect(!OPNRemoteCoOpEmbeddedServer.isPrivateIPv4("198.12.95.48"))
        #expect(!OPNRemoteCoOpEmbeddedServer.isPrivateIPv4("not-an-address"))
    }

    /// A hostname is not an address, however much of one it contains.
    ///
    /// The check used to sift numeric labels out of the name and ignore the rest, so a registerable
    /// domain beginning with a private-range quad passed as a LAN address. That let an attacker page
    /// on a domain they own present an allowed `Origin`.
    @Test func aHostnameContainingAPrivateQuadIsNotAPrivateAddress() {
        for host in ["10.0.0.1.evil.com", "192.168.1.1.attacker.io", "evil.10.0.0.1.com", "10.0.0.1.", "10.0.0", "10.0.0.1.2"] {
            #expect(!OPNRemoteCoOpEmbeddedServer.isPrivateIPv4(host), "\(host) must not count as a private address")
        }
        for origin in ["https://10.0.0.1.evil.com", "https://192.168.1.1.attacker.io:32188"] {
            #expect(!OPNRemoteCoOpEmbeddedServer.isOriginAllowed(origin, port: 32_188, additional: []), "\(origin) must not be allowed")
        }
        // The real thing still passes.
        #expect(OPNRemoteCoOpEmbeddedServer.isPrivateIPv4("192.168.1.25"))
        #expect(OPNRemoteCoOpEmbeddedServer.isOriginAllowed("https://192.168.1.25:32188", port: 32_188, additional: []))
    }

    /// The caps exist so an unauthenticated peer cannot make the host hold resources. The seat
    /// allows three guests, so the connection cap has to be comfortably above that.
    @Test func theConnectionCapLeavesRoomForEveryGuest() {
        #expect(OPNRemoteCoOpEmbeddedServer.maximumConnections > 3 * 4)
        #expect(OPNRemoteCoOpEmbeddedServer.handshakeTimeout > .seconds(1))
    }
}

/// A tunnel changes only the address guests are told to use. These pin the derivation, because
/// getting the scheme wrong is exactly what made the previous deployment unusable: `http://` is not
/// a secure context, so the guest page cannot construct an `RTCPeerConnection` at all.
@Suite struct RemoteCoOpTunnelAddressTests {
    private func preferences(publicAddress: String) -> OPNRemoteCoOpPreferences {
        OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 1, publicAddress: publicAddress)
    }

    @Test func anHTTPSTunnelAddressIsUsed() throws {
        let url = try #require(preferences(publicAddress: "https://abc123.ngrok-free.app").effectivePublicAddress)
        #expect(url.host == "abc123.ngrok-free.app")
    }

    /// Plaintext is refused rather than passed through. A guest reaching a tunnel over `http://`
    /// would load the page and then fail to build a peer connection, with nothing to explain why.
    @Test func aPlaintextTunnelAddressIsRefused() {
        #expect(preferences(publicAddress: "http://abc123.ngrok-free.app").effectivePublicAddress == nil)
        #expect(preferences(publicAddress: "abc123.ngrok-free.app").effectivePublicAddress == nil)
        #expect(preferences(publicAddress: "").effectivePublicAddress == nil)
        #expect(preferences(publicAddress: "   ").effectivePublicAddress == nil)
    }

    /// The signaling socket must share the tunnel's origin, which is what lets one accepted
    /// certificate cover both the page and the socket.
    @Test func theSignalingURLSharesTheTunnelOrigin() throws {
        let tunnel = try #require(URL(string: "https://abc123.ngrok-free.app"))
        #expect(OPNRemoteCoOpHostingEndpoint.signalingURL(forTunnel: tunnel) == "wss://abc123.ngrok-free.app/remote-coop")

        let withPort = try #require(URL(string: "https://tunnel.example.com:8443"))
        #expect(OPNRemoteCoOpHostingEndpoint.signalingURL(forTunnel: withPort) == "wss://tunnel.example.com:8443/remote-coop")

        // A path or query on the configured address must not end up in the socket URL.
        let messy = try #require(URL(string: "https://abc.ngrok-free.app/?x=1"))
        #expect(OPNRemoteCoOpHostingEndpoint.signalingURL(forTunnel: messy) == "wss://abc.ngrok-free.app/remote-coop")
    }

    /// The origin string has to match what a browser actually sends, or the allowlist rejects every
    /// guest arriving through the tunnel.
    @Test func theTunnelOriginOmitsTheDefaultPort() throws {
        #expect(OPNRemoteCoOpHostingEndpoint.originString(for: try #require(URL(string: "https://abc.ngrok-free.app"))) == "https://abc.ngrok-free.app")
        #expect(OPNRemoteCoOpHostingEndpoint.originString(for: try #require(URL(string: "https://abc.ngrok-free.app:443"))) == "https://abc.ngrok-free.app")
        #expect(OPNRemoteCoOpHostingEndpoint.originString(for: try #require(URL(string: "https://abc.example.com:8443"))) == "https://abc.example.com:8443")
        #expect(OPNRemoteCoOpHostingEndpoint.originString(for: try #require(URL(string: "https://abc.ngrok-free.app/path"))) == "https://abc.ngrok-free.app")
    }
}

/// The direction boundary of the signaling protocol.
///
/// `networkConfiguration` and `error` used to arrive on the host's *outbound* socket from the trusted
/// Node broker. With the broker gone the only socket left is guest-facing, and both kinds still
/// decoded inbound - so an unauthenticated peer could send a `networkConfiguration` and replace the
/// ICE servers and transport policy of every peer connection the host built afterwards, forcing
/// guest media through a relay of their choosing. No invite token was needed to reach it.
@Suite struct RemoteCoOpGuestMessageDirectionTests {
    private final class TrustingDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
            return (.useCredential, URLCredential(trust: trust))
        }
    }

    private func startServer() async throws -> (OPNRemoteCoOpEmbeddedServer, OPNRemoteCoOpEmbeddedServerEndpoint, URLSession, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("coop-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<html></html>".utf8).write(to: root.appendingPathComponent("index.html"))

        let server = OPNRemoteCoOpEmbeddedServer(
            documentRoot: root,
            networkConfiguration: OPNRemoteCoOpNetworkConfiguration(transportMode: .automatic, latencyMode: .lowLatency)
        )
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("coop-tls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let p12 = try OPNRemoteCoOpTLSIdentity.generateP12(host: "127.0.0.1", passphrase: "pass", directory: scratch)
        let identity = try OPNRemoteCoOpTLSIdentity.importIdentity(p12: p12, passphrase: "pass")
        let endpoint = try await server.start(port: 0, advertisedHost: "127.0.0.1", identity: identity)
        let session = URLSession(configuration: .ephemeral, delegate: TrustingDelegate(), delegateQueue: nil)
        return (server, endpoint, session, root)
    }

    /// The attack: no invite token, no join, one message. It must produce no host-side event at all.
    @Test func aGuestCannotInjectNetworkConfiguration() async throws {
        let (server, endpoint, session, root) = try await startServer()
        defer {
            Task { await server.stop() }
            try? FileManager.default.removeItem(at: root)
        }

        let events = await server.events()
        let collected = Task { () -> OPNRemoteCoOpSignalingEvent? in
            for await event in events { return event }
            return nil
        }

        let socket = session.webSocketTask(with: try #require(URL(string: endpoint.signalingServerURL)))
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        let poisoned = OPNRemoteCoOpNetworkConfiguration(
            transportMode: .automatic,
            latencyMode: .quality,
            iceServers: [OPNRemoteCoOpICEServer(urls: ["turn:attacker.example:3478"], username: "a", credential: "b")]
        )
        try await socket.send(.string(try OPNRemoteCoOpWireCodec.encode(
            OPNRemoteCoOpWireMessage(kind: .networkConfiguration, roomID: nil, networkConfiguration: poisoned))))
        // An `error` message likewise: it reached the host's on-stream HUD as attacker-authored text.
        try await socket.send(.string(try OPNRemoteCoOpWireCodec.encode(
            OPNRemoteCoOpWireMessage(kind: .error, roomID: nil, reason: "Session ended, re-share your invite at evil.example"))))

        // Then a legitimate join, which must be the first and only event the host sees.
        let participantID = UUID()
        try await socket.send(.string(try OPNRemoteCoOpWireCodec.encode(OPNRemoteCoOpWireMessage(
            kind: .guestJoinRequested, roomID: UUID(), participantID: participantID, inviteToken: "a.b", displayName: "Guest"))))

        let event = try #require(await collected.value)
        guard case .guestJoinRequested(let seen, _, _) = event else {
            Issue.record("the host must not receive a guest-sent \(event)")
            return
        }
        #expect(seen == participantID)
    }

    /// A socket that never joined owns no participant, so it may not act as one. This used to pass by
    /// omitting the top-level participant field, leaving an unguessable UUID as the only obstacle.
    @Test func anUnjoinedSocketCannotSendInput() async throws {
        let (server, endpoint, session, root) = try await startServer()
        defer {
            Task { await server.stop() }
            try? FileManager.default.removeItem(at: root)
        }

        let events = await server.events()
        let collected = Task { () -> OPNRemoteCoOpSignalingEvent? in
            for await event in events { return event }
            return nil
        }

        let socket = session.webSocketTask(with: try #require(URL(string: endpoint.signalingServerURL)))
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        // Input as some other participant, with no top-level participantID to check against.
        let victim = UUID()
        try await socket.send(.string(try OPNRemoteCoOpWireCodec.encode(OPNRemoteCoOpWireMessage(
            kind: .guestInput,
            roomID: nil,
            input: OPNRemoteCoOpInputPacket(participantID: victim, sequenceNumber: 1, buttons: [.south])))))

        let owner = UUID()
        try await socket.send(.string(try OPNRemoteCoOpWireCodec.encode(OPNRemoteCoOpWireMessage(
            kind: .guestJoinRequested, roomID: UUID(), participantID: owner, inviteToken: "a.b", displayName: "Guest"))))

        let event = try #require(await collected.value)
        guard case .guestJoinRequested(let seen, _, _) = event else {
            Issue.record("input from an unjoined socket must be dropped, got \(event)")
            return
        }
        #expect(seen == owner)
    }

    /// Once bound, a socket may only speak as its own participant - including in the input packet,
    /// which is the identity the router actually keys off.
    @Test func aJoinedSocketCannotSendInputAsAnotherParticipant() async throws {
        let (server, endpoint, session, root) = try await startServer()
        defer {
            Task { await server.stop() }
            try? FileManager.default.removeItem(at: root)
        }

        let events = await server.events()
        let collected = Task { () -> [OPNRemoteCoOpSignalingEvent] in
            var result: [OPNRemoteCoOpSignalingEvent] = []
            for await event in events {
                result.append(event)
                if result.count == 2 { break }
            }
            return result
        }

        let socket = session.webSocketTask(with: try #require(URL(string: endpoint.signalingServerURL)))
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        let owner = UUID()
        try await socket.send(.string(try OPNRemoteCoOpWireCodec.encode(OPNRemoteCoOpWireMessage(
            kind: .guestJoinRequested, roomID: UUID(), participantID: owner, inviteToken: "a.b", displayName: "Owner"))))
        _ = try await socket.receive()

        // Someone else's input, then its own. Only the second may arrive.
        try await socket.send(.string(try OPNRemoteCoOpWireCodec.encode(OPNRemoteCoOpWireMessage(
            kind: .guestInput, roomID: nil,
            input: OPNRemoteCoOpInputPacket(participantID: UUID(), sequenceNumber: 1, buttons: [.north])))))
        try await socket.send(.string(try OPNRemoteCoOpWireCodec.encode(OPNRemoteCoOpWireMessage(
            kind: .guestInput, roomID: nil,
            input: OPNRemoteCoOpInputPacket(participantID: owner, sequenceNumber: 2, buttons: [.south])))))

        let received = await collected.value
        #expect(received.count == 2)
        guard case .guestInput(let packet) = received.last else {
            Issue.record("expected the socket's own input, got \(String(describing: received.last))")
            return
        }
        #expect(packet.participantID == owner)
        #expect(packet.sequenceNumber == 2)
    }
}

/// Accumulates frames across a cancelled reader task.
private final class OPNRemoteCoOpTextCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [String] = []

    func append(_ text: String) {
        lock.lock()
        collected.append(text)
        lock.unlock()
    }

    func texts() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }
}
