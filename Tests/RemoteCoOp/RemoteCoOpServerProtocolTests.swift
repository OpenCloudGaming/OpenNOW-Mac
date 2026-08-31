//
//  RemoteCoOpServerProtocolTests.swift
//  OpenNOW
//
//  The wire layers the embedded Remote Co-Op server implements itself: RFC 6455 framing, the HTTP
//  request head, and static file resolution. Every one of these faces a browser directly on a
//  machine that is also running a game, so the cases here are mostly the hostile ones.
//

import Foundation
import Security
import Testing
@testable import OpenNOW

@Suite struct RemoteCoOpWebSocketFrameTests {
    /// A client frame, masked as RFC 6455 requires. Built the way a browser builds one so the
    /// decoder is tested against the real shape rather than against its own encoder.
    private func clientFrame(opcode: OPNRemoteCoOpWebSocketOpcode, payload: Data, mask: [UInt8] = [0x37, 0xFA, 0x21, 0x3D]) -> Data {
        var frame = Data([0x80 | opcode.rawValue])
        let count = payload.count
        if count < 126 {
            frame.append(UInt8(count) | 0x80)
        } else if count <= 0xFFFF {
            frame.append(126 | 0x80)
            frame.append(UInt8(truncatingIfNeeded: count >> 8))
            frame.append(UInt8(truncatingIfNeeded: count))
        } else {
            frame.append(127 | 0x80)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8(truncatingIfNeeded: count >> shift)) }
        }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        return frame
    }

    /// The value is fixed by the spec; a browser rejects the handshake if it differs. This vector is
    /// the one from RFC 6455 section 1.3.
    @Test func acceptTokenMatchesTheSpecVector() {
        #expect(OPNRemoteCoOpWebSocketCodec.acceptToken(forKey: "dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    @Test func decodesAMaskedTextFrame() throws {
        var buffer = clientFrame(opcode: .text, payload: Data("Hello".utf8))
        let frames = try OPNRemoteCoOpWebSocketCodec.decodeFrames(from: &buffer)
        #expect(frames.count == 1)
        #expect(frames.first?.opcode == .text)
        #expect(frames.first.map { String(decoding: $0.payload, as: UTF8.self) } == "Hello")
        #expect(buffer.isEmpty)
    }

    /// TCP gives no message boundaries. A frame split across reads must be held, not treated as
    /// corrupt - getting this wrong drops signaling traffic that was merely still in flight.
    @Test func aFrameSplitAcrossReadsIsHeldUntilComplete() throws {
        let whole = clientFrame(opcode: .text, payload: Data("split me".utf8))
        var buffer = whole.prefix(5)
        #expect(try OPNRemoteCoOpWebSocketCodec.decodeFrames(from: &buffer).isEmpty)
        #expect(buffer.count == 5)

        buffer.append(whole.dropFirst(5))
        let frames = try OPNRemoteCoOpWebSocketCodec.decodeFrames(from: &buffer)
        #expect(frames.map { String(decoding: $0.payload, as: UTF8.self) } == ["split me"])
        #expect(buffer.isEmpty)
    }

    @Test func decodesSeveralFramesArrivingInOneRead() throws {
        var buffer = clientFrame(opcode: .text, payload: Data("one".utf8))
        buffer.append(clientFrame(opcode: .text, payload: Data("two".utf8)))
        buffer.append(clientFrame(opcode: .ping, payload: Data()))
        let frames = try OPNRemoteCoOpWebSocketCodec.decodeFrames(from: &buffer)
        #expect(frames.map(\.opcode) == [.text, .text, .ping])
        #expect(buffer.isEmpty)
    }

    /// Extended payload lengths use different header shapes; SDP answers routinely exceed 125 bytes
    /// and land in the 16-bit form.
    @Test func decodesExtendedPayloadLengths() throws {
        let medium = Data(repeating: 0x41, count: 400)
        var buffer = clientFrame(opcode: .text, payload: medium)
        #expect(try OPNRemoteCoOpWebSocketCodec.decodeFrames(from: &buffer).first?.payload == medium)

        let large = Data(repeating: 0x42, count: 70_000)
        var largeBuffer = clientFrame(opcode: .binary, payload: large)
        #expect(try OPNRemoteCoOpWebSocketCodec.decodeFrames(from: &largeBuffer).first?.payload == large)
    }

    /// RFC 6455 requires clients to mask. An unmasked client frame is a broken client or an attempt
    /// to smuggle bytes past an intermediary, and the spec says fail rather than guess.
    @Test func rejectsAnUnmaskedClientFrame() {
        var buffer = Data([0x81, 0x05]) + Data("Hello".utf8)
        #expect(throws: OPNRemoteCoOpWebSocketError.unmaskedClientFrame) {
            _ = try OPNRemoteCoOpWebSocketCodec.decodeFrames(from: &buffer)
        }
    }

    /// A declared length beyond the cap is refused from the header alone, without waiting for the
    /// payload - otherwise a single frame header could make the host buffer arbitrarily.
    @Test func rejectsAnOversizedDeclaredLength() {
        var buffer = Data([0x81, 127 | 0x80])
        for shift in stride(from: 56, through: 0, by: -8) {
            buffer.append(UInt8(truncatingIfNeeded: (OPNRemoteCoOpWebSocketCodec.maximumPayloadBytes + 1) >> UInt64(shift)))
        }
        #expect(throws: (any Error).self) { _ = try OPNRemoteCoOpWebSocketCodec.decodeFrames(from: &buffer) }
    }

    /// Server frames are never masked, and must round-trip through the same length encodings.
    @Test func serverFramesAreUnmaskedAndCorrectlyFramed() {
        let small = OPNRemoteCoOpWebSocketCodec.encodeText("hi")
        #expect(small[0] == 0x81)
        #expect(small[1] == 2)
        #expect(small[1] & 0x80 == 0)

        let medium = OPNRemoteCoOpWebSocketCodec.encodeText(String(repeating: "a", count: 300))
        #expect(medium[1] == 126)
        #expect((Int(medium[2]) << 8 | Int(medium[3])) == 300)
    }
}

@Suite struct RemoteCoOpHTTPParserTests {
    @Test func parsesARequestHeadAndKeepsTrailingBytes() throws {
        var buffer = Data("GET /app.js?v=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: https://127.0.0.1:32188\r\n\r\nLEFTOVER".utf8)
        let request = try #require(try OPNRemoteCoOpHTTPParser.parseRequest(from: &buffer))
        #expect(request.method == "GET")
        #expect(request.path == "/app.js?v=1")
        #expect(request.normalizedPath == "/app.js")
        #expect(request.header("origin") == "https://127.0.0.1:32188")
        #expect(String(decoding: buffer, as: UTF8.self) == "LEFTOVER")
    }

    /// Field names are case-insensitive and browsers disagree in practice on `Sec-WebSocket-Key`.
    @Test func headerLookupIsCaseInsensitive() throws {
        var buffer = Data("GET / HTTP/1.1\r\nSEC-WEBSOCKET-KEY: abc\r\nUpGrAdE: WebSocket\r\nConnection: keep-alive, Upgrade\r\n\r\n".utf8)
        let request = try #require(try OPNRemoteCoOpHTTPParser.parseRequest(from: &buffer))
        #expect(request.header("Sec-WebSocket-Key") == "abc")
        #expect(request.isWebSocketUpgrade)
    }

    @Test func anIncompleteHeadIsHeldRatherThanRejected() throws {
        var buffer = Data("GET / HTTP/1.1\r\nHost: local".utf8)
        #expect(try OPNRemoteCoOpHTTPParser.parseRequest(from: &buffer) == nil)
        buffer.append(Data("host\r\n\r\n".utf8))
        #expect(try OPNRemoteCoOpHTTPParser.parseRequest(from: &buffer) != nil)
    }

    /// A client that never sends the blank line must not be able to grow the buffer without bound.
    @Test func anEndlessHeadIsRefused() {
        var buffer = Data("GET / HTTP/1.1\r\n".utf8)
        buffer.append(Data(repeating: 0x41, count: OPNRemoteCoOpHTTPParser.maximumHeadBytes + 1))
        #expect(throws: OPNRemoteCoOpHTTPParser.ParseError.headTooLarge) {
            _ = try OPNRemoteCoOpHTTPParser.parseRequest(from: &buffer)
        }
    }

    @Test func aPlainGetIsNotMistakenForAnUpgrade() throws {
        var buffer = Data("GET / HTTP/1.1\r\nHost: x\r\n\r\n".utf8)
        let request = try #require(try OPNRemoteCoOpHTTPParser.parseRequest(from: &buffer))
        #expect(!request.isWebSocketUpgrade)
    }
}

@Suite struct RemoteCoOpStaticFileStoreTests {
    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("coop-root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<html></html>".utf8).write(to: root.appendingPathComponent("index.html"))
        try Data("body{}".utf8).write(to: root.appendingPathComponent("styles.css"))
        return root
    }

    @Test func servesTheIndexForTheRootPath() throws {
        let store = OPNRemoteCoOpStaticFileStore(documentRoot: try makeRoot())
        let file = try #require(store.file(for: "/"))
        #expect(String(decoding: file.data, as: UTF8.self) == "<html></html>")
        #expect(file.contentType == "text/html; charset=utf-8")
    }

    @Test func servesNamedFilesWithTheirContentType() throws {
        let store = OPNRemoteCoOpStaticFileStore(documentRoot: try makeRoot())
        #expect(store.file(for: "/styles.css")?.contentType == "text/css; charset=utf-8")
        #expect(store.file(for: "/missing.js") == nil)
    }

    /// This server listens on a machine holding the user's GeForce NOW session tokens. Traversal is
    /// checked on the resolved path rather than by filtering the request string, because
    /// percent-encoding and redundant separators both produce a path that looks clean and resolves
    /// somewhere else.
    @Test func refusesToEscapeTheDocumentRoot() throws {
        let root = try makeRoot()
        let secret = root.deletingLastPathComponent().appendingPathComponent("outside-secret.txt")
        try Data("do not serve".utf8).write(to: secret)
        defer { try? FileManager.default.removeItem(at: secret) }
        let store = OPNRemoteCoOpStaticFileStore(documentRoot: root)

        #expect(store.file(for: "/../outside-secret.txt") == nil)
        #expect(store.file(for: "/%2e%2e/outside-secret.txt") == nil)
        #expect(store.file(for: "/..%2Foutside-secret.txt") == nil)
        #expect(store.file(for: "//../outside-secret.txt") == nil)
        #expect(store.file(for: "/subdir/../../outside-secret.txt") == nil)
    }
}

/// The certificate the embedded server presents. Exercised against the system's real `openssl` and
/// `SecPKCS12Import`, because both have already surprised us: macOS ships LibreSSL, where the
/// `-legacy` flag that OpenSSL 3 needs for a Security.framework-readable PKCS#12 does not exist and
/// fails the whole command.
@Suite struct RemoteCoOpTLSIdentityTests {
    private func scratchDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("coop-tls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func generatesAPKCS12SecurityFrameworkCanImport() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let p12 = try OPNRemoteCoOpTLSIdentity.generateP12(host: "127.0.0.1", passphrase: "test-passphrase", directory: directory)
        #expect(!p12.isEmpty)

        let identity = try OPNRemoteCoOpTLSIdentity.importIdentity(p12: p12, passphrase: "test-passphrase")
        var certificate: SecCertificate?
        #expect(SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess)
        let summary = certificate.flatMap { SecCertificateCopySubjectSummary($0) as String? }
        #expect(summary == "127.0.0.1")
    }

    /// The fingerprint is what a host reads out so a guest can confirm the certificate they
    /// accepted is the one the host is presenting, rather than something in between.
    @Test func exposesAStableColonSeparatedFingerprint() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let p12 = try OPNRemoteCoOpTLSIdentity.generateP12(host: "127.0.0.1", passphrase: "pass", directory: directory)
        let identity = try OPNRemoteCoOpTLSIdentity.importIdentity(p12: p12, passphrase: "pass")
        let fingerprint = try #require(OPNRemoteCoOpTLSIdentity.fingerprint(for: identity))

        #expect(fingerprint.split(separator: ":").count == 32)
        #expect(fingerprint == fingerprint.uppercased())
        #expect(OPNRemoteCoOpTLSIdentity.fingerprint(for: identity) == fingerprint)
    }

    @Test func aWrongPassphraseIsRejected() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let p12 = try OPNRemoteCoOpTLSIdentity.generateP12(host: "127.0.0.1", passphrase: "right", directory: directory)
        #expect(throws: (any Error).self) {
            _ = try OPNRemoteCoOpTLSIdentity.importIdentity(p12: p12, passphrase: "wrong")
        }
    }
}

/// The embedded server end to end: a real TLS listener, a real HTTPS fetch of the guest page, and a
/// real WebSocket handshake and join over that same origin.
///
/// Driven with `URLSession` rather than the server's own codec, so the handshake and framing are
/// checked against an independent implementation - the same thing a browser will do.
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
    private func makeServer(root: URL) async throws -> (OPNRemoteCoOpEmbeddedServer, OPNRemoteCoOpEmbeddedServerEndpoint, URLSession) {
        let configuration = OPNRemoteCoOpNetworkConfiguration(transportMode: .directOnly, latencyMode: .lowLatency)
        let server = OPNRemoteCoOpEmbeddedServer(documentRoot: root, networkConfiguration: configuration)
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("coop-tls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let p12 = try OPNRemoteCoOpTLSIdentity.generateP12(host: "127.0.0.1", passphrase: "pass", directory: scratch)
        let identity = try OPNRemoteCoOpTLSIdentity.importIdentity(p12: p12, passphrase: "pass")

        let port = UInt16.random(in: 49_200...49_900)
        let endpoint = try await server.start(port: port, advertisedHost: "127.0.0.1", identity: identity)
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

        guard case .string(let text) = try await socket.receive() else {
            Issue.record("expected a text frame")
            return
        }
        let reply = try OPNRemoteCoOpWireCodec.decode(text)
        #expect(reply.kind == .networkConfiguration)
        #expect(reply.networkConfiguration?.transportMode == .directOnly)
        // Direct Only withholds relay candidates; the guest page reads this to configure ICE.
        #expect(reply.networkConfiguration?.iceTransportPolicy == .all)

        let event = try #require(await received.value)
        guard case .guestJoinRequested(let eventParticipantID, _, let displayName) = event else {
            Issue.record("expected a guest join event, got \(event)")
            return
        }
        #expect(eventParticipantID == participantID)
        #expect(displayName == "Tester")
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
        let endpoint = try await server.start(port: UInt16.random(in: 49_200...49_900), advertisedHost: "127.0.0.1", identity: identity)
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
