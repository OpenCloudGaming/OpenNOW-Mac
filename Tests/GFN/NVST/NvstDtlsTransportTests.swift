import Darwin
import Foundation
import Testing
@testable import OpenNOW

/// Drives the transport over real UDP sockets on loopback: two endpoints, a real handshake with the
/// retransmission clock, the key split, and application datagrams both ways.
///
/// The memory-BIO test proves the state machine. This proves the socket plumbing and the timing
/// around it, which is where a handshake against a real seat would fail first.
@Suite(.serialized) struct NvstDtlsTransportTests {
    private static let loopback = "127.0.0.1"

    private static func bindLoopbackSocket() throws -> (descriptor: Int32, port: UInt16) {
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw NvstDtlsTransport.TransportError.socketUnavailable("socket() failed") }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr(loopback)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
                bind(descriptor, addressPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            Darwin.close(descriptor)
            throw NvstDtlsTransport.TransportError.socketUnavailable("bind() failed")
        }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
                getsockname(descriptor, addressPointer, &length)
            }
        }
        guard named == 0 else {
            Darwin.close(descriptor)
            throw NvstDtlsTransport.TransportError.socketUnavailable("getsockname() failed")
        }
        return (descriptor, UInt16(bigEndian: local.sin_port))
    }

    /// A reference type so the background endpoint can publish its result back.
    private final class Outcome: @unchecked Sendable {
        var keys: NvstBundleSrtpKeys?
        var error: Error?
    }

    /// Runs a client and a server endpoint against each other. The server runs on its own queue
    /// because both ends block on their sockets while the handshake is in flight.
    private func makePair() throws -> (client: NvstDtlsTransport, server: NvstDtlsTransport, serverOutcome: Outcome, done: DispatchSemaphore) {
        let serverSocket = try Self.bindLoopbackSocket()
        let clientSocket = try Self.bindLoopbackSocket()
        let clientIdentity = try NvstDtlsIdentity()
        let serverIdentity = try NvstDtlsIdentity()
        let client = try NvstDtlsTransport(
            handshake: try NvstDtlsHandshake(role: .client, identity: clientIdentity, expectedPeerFingerprint: serverIdentity.fingerprint),
            descriptor: clientSocket.descriptor,
            localAddress: Self.loopback,
            localPort: clientSocket.port,
            peerAddress: Self.loopback,
            peerPort: serverSocket.port
        )
        let server = try NvstDtlsTransport(
            handshake: try NvstDtlsHandshake(role: .server, identity: serverIdentity, expectedPeerFingerprint: clientIdentity.fingerprint),
            descriptor: serverSocket.descriptor,
            localAddress: Self.loopback,
            localPort: serverSocket.port,
            peerAddress: Self.loopback,
            peerPort: clientSocket.port
        )
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue(label: "dtls.loopback.server").async {
            do { outcome.keys = try server.completeHandshake(timeout: 15) } catch { outcome.error = error }
            done.signal()
        }
        return (client, server, outcome, done)
    }

    @Test func theHandshakeCompletesOverRealSocketsAndBothEndsAgreeOnKeys() throws {
        let pair = try makePair()
        let clientKeys = try pair.client.completeHandshake(timeout: 15)
        #expect(pair.done.wait(timeout: .now() + 20) == .success, "the server endpoint never finished")
        let serverKeys = try #require(pair.serverOutcome.keys, "server error: \(String(describing: pair.serverOutcome.error))")
        #expect(clientKeys == serverKeys, "the two endpoints disagree on the SRTP master keys")
        #expect(clientKeys.clientMasterKey.count == 32)
        #expect(clientKeys.clientMasterSalt.count == 12)
    }

    @Test func applicationDatagramsRoundTripBothWays() throws {
        let pair = try makePair()
        _ = try pair.client.completeHandshake(timeout: 15)
        #expect(pair.done.wait(timeout: .now() + 20) == .success)
        #expect(pair.serverOutcome.error == nil)

        let ping = Data("nvst-control-ping".utf8)
        try pair.client.sendEncrypted(ping)
        #expect(try pair.server.receive(timeout: 5) == ping)

        let pong = Data("nvst-control-pong".utf8)
        try pair.server.sendEncrypted(pong)
        #expect(try pair.client.receive(timeout: 5) == pong)
    }

    @Test func dtlsProfilesKeepTheStandardTagLengthIndependentOfTheVideoProfile() {
        #expect(NvstDtlsTransport.profile(forOpenSSLName: "SRTP_AEAD_AES_256_GCM") == .aeadAes256Gcm)
        #expect(NvstDtlsTransport.profile(forOpenSSLName: "SRTP_AES128_CM_SHA1_80") == .aesCm128HmacSha1_80)
        #expect(NvstDtlsTransport.profile(forOpenSSLName: "SRTP_AEAD_AES_128_GCM") == .aeadAes128Gcm)
        #expect(NvstDtlsTransport.profile(forOpenSSLName: "SRTP_SOMETHING_ELSE") == nil)
    }

    @Test func aPeerThatNeverAnswersTimesOut() throws {
        let socket = try Self.bindLoopbackSocket()
        let unused = try Self.bindLoopbackSocket()
        let identity = try NvstDtlsIdentity()
        let transport = try NvstDtlsTransport(
            handshake: try NvstDtlsHandshake(role: .client, identity: identity, expectedPeerFingerprint: nil),
            descriptor: socket.descriptor,
            localAddress: Self.loopback,
            localPort: socket.port,
            peerAddress: Self.loopback,
            peerPort: unused.port
        )
        defer { _ = Darwin.close(unused.descriptor) }
        #expect(throws: NvstDtlsTransport.TransportError.handshakeTimedOut) {
            try transport.completeHandshake(timeout: 1.0)
        }
    }

    /// The seat's front end routes the bundle socket by the STUN username, so the punch must be the
    /// first thing on the wire — a ClientHello sent without it is never forwarded to the bundle
    /// service, which is exactly how the first live run failed.
    @Test func theBundlePunchesWithStunBeforeTheClientHello() throws {
        let peer = try Self.bindLoopbackSocket()
        defer { _ = Darwin.close(peer.descriptor) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(peer.descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let local = try Self.bindLoopbackSocket()
        let identity = try NvstDtlsIdentity()
        let transport = try NvstDtlsTransport(
            handshake: try NvstDtlsHandshake(role: .client, identity: identity, expectedPeerFingerprint: nil),
            descriptor: local.descriptor,
            localAddress: Self.loopback,
            localPort: local.port,
            peerAddress: Self.loopback,
            peerPort: peer.port
        )
        transport.natt = NvstDtlsTransport.NattIdentity(
            remoteUfrag: "e503c1fe47999",
            localUfrag: "abcd",
            integrityKey: Data("remote-pass".utf8)
        )
        transport.start()
        defer { transport.close() }

        var buffer = [UInt8](repeating: 0, count: 2048)
        var source = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let received = withUnsafeMutablePointer(to: &source) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                recvfrom(peer.descriptor, &buffer, buffer.count, 0, address, &length)
            }
        }
        try #require(received > 0, "the transport sent nothing")
        let datagram = Data(buffer[0..<received])
        guard case .stun = NvstBundleDatagramDemux.classify(datagram) else {
            Issue.record("the first datagram was not a STUN punch: \(datagram.prefix(4).map { String(format: "%02x", $0) }.joined())")
            return
        }
    }
}
