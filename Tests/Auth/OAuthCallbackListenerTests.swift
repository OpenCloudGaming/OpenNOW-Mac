import Darwin
import Foundation
import Testing
@testable import OpenNOW

private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if didResume { return false }
        didResume = true
        return true
    }
}

private final class ConnectionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var didConnect = false

    func record(_ value: Bool) {
        lock.lock()
        didConnect = value
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didConnect
    }
}

private func loopbackAddress(port: Int) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
    address.sin_port = in_port_t(port).bigEndian
    return address
}

private func connectLoopback(_ descriptor: Int32, port: Int) -> Bool {
    var address = loopbackAddress(port: port)
    return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
        }
    }
}

private func sendLoopbackRequest(port: Int, requestLine: String) {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return }
    defer { close(descriptor) }
    guard connectLoopback(descriptor, port: port) else { return }
    let request = "\(requestLine)\r\nHost: localhost\r\nConnection: close\r\n\r\n"
    _ = request.withCString { send(descriptor, $0, strlen($0), 0) }
    var buffer = [UInt8](repeating: 0, count: 4096)
    _ = recv(descriptor, &buffer, buffer.count, 0)
}

/// Serialized: `findAvailablePort` hands out the same port to whoever asks first, and these tests
/// bind it for real.
@Suite("Loopback OAuth callback listener", .serialized)
struct OAuthCallbackListenerTests {
    /// Any process on this machine can reach the loopback port. A single-shot listener accepts
    /// once and closes, so the first connection — a favicon request, a preconnect, a request
    /// crafted to abort the sign-in — consumed the callback and left the real one refused.
    @Test("unrelated loopback requests cannot consume or hijack the callback", .timeLimit(.minutes(1)))
    func unrelatedLoopbackRequestsDoNotConsumeTheCallback() async throws {
        let service = OPNAuthService.shared
        let port = service.findAvailablePort()
        #expect(port > 0)
        let expectedState = "state-" + UUID().uuidString
        let expectedQuery = "code=real-code&state=\(expectedState)"
        let resumeGuard = ResumeGuard()

        let query = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            service.startOAuthCallbackListener(port: port, expectedState: expectedState) { result in
                guard resumeGuard.claim() else { return }
                continuation.resume(with: result)
            } readyHandler: {
                DispatchQueue.global().async {
                    sendLoopbackRequest(port: port, requestLine: "GET /favicon.ico HTTP/1.1")
                    sendLoopbackRequest(port: port, requestLine: "GET /?code=injected&state=someone-elses-state HTTP/1.1")
                    sendLoopbackRequest(port: port, requestLine: "GET /?\(expectedQuery) HTTP/1.1")
                }
            }
        }

        #expect(query == expectedQuery)
    }

    /// The accepted socket has to carry a receive deadline: a peer that connects and says nothing
    /// otherwise holds the whole browser leg open, and the sign-in never completes.
    @Test("a peer that connects and sends nothing cannot stall the sign-in", .timeLimit(.minutes(2)))
    func aSilentPeerDoesNotStallTheCallback() async throws {
        let service = OPNAuthService.shared
        let port = service.findAvailablePort()
        #expect(port > 0)
        let expectedState = "state-" + UUID().uuidString
        let expectedQuery = "code=real-code&state=\(expectedState)"
        let resumeGuard = ResumeGuard()
        let probe = ConnectionProbe()

        let silentPeer = socket(AF_INET, SOCK_STREAM, 0)
        #expect(silentPeer >= 0)
        defer { close(silentPeer) }

        let query = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            service.startOAuthCallbackListener(port: port, expectedState: expectedState) { result in
                guard resumeGuard.claim() else { return }
                continuation.resume(with: result)
            } readyHandler: {
                probe.record(connectLoopback(silentPeer, port: port))
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                    sendLoopbackRequest(port: port, requestLine: "GET /?\(expectedQuery) HTTP/1.1")
                }
            }
        }

        #expect(probe.value)
        #expect(query == expectedQuery)
    }
}
