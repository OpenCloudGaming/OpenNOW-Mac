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
