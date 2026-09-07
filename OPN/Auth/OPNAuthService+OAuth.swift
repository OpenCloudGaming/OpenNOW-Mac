//  The browser OAuth leg: token exchange, the loopback callback listener and the PKCE material it
//  is keyed by.
//

import AppKit
import CryptoKit
import Darwin
import Foundation

extension OPNAuthService {
    func doOAuthTokenExchange(
        authCode: String,
        codeVerifier: String,
        redirectUri: String,
        providerIdpId: String,
        completion: @escaping OPNAuthCallback
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let session = Self.opnSession(from: try await self.starfleetService.exchangeAuthorizationCode(authCode: authCode, redirectURI: redirectUri, codeVerifier: codeVerifier, providerIdpId: providerIdpId))
                await self.jarvisAuthService.setSession(session)
                self.saveSession(session)
                _ = await self.jarvisAuthService.finishLogin(success: true)
                Task { @MainActor in completion(true, session, "") }
            } catch {
                _ = await self.jarvisAuthService.finishLogin(success: false)
                Task { @MainActor in completion(false, OPNAuthSession(), error.localizedDescription) }
            }
        }
    }

    func syncBackendSessions(_ session: OPNAuthSession) async {
        await jarvisAuthService.setSession(session)
        await starfleetService.setSession(Self.starfleetSession(from: session))
    }

    func handleStarfleetFailure(_ error: Error) async {
        guard (error as? StarfleetAuthError)?.category == .authorization else { return }
        _ = await jarvisAuthService.finishLogin(success: false)
    }

    func dictionary(from userInfo: StarfleetUserInfo) -> NSDictionary {
        let dictionary = NSMutableDictionary()
        put(userInfo.userId, key: "sub", into: dictionary)
        put(userInfo.userId, key: "userId", into: dictionary)
        put(userInfo.externalId, key: "external_id", into: dictionary)
        put(userInfo.externalId, key: "externalId", into: dictionary)
        put(userInfo.idpId, key: "idp_id", into: dictionary)
        put(userInfo.idpId, key: "idpId", into: dictionary)
        put(userInfo.preferredUsername, key: "preferred_username", into: dictionary)
        put(userInfo.displayName, key: "name", into: dictionary)
        put(userInfo.displayName, key: "displayName", into: dictionary)
        put(userInfo.email, key: "email", into: dictionary)
        return dictionary
    }

    /// The browser leg's budget: long enough for a person to type a password and a second factor,
    /// short enough that an abandoned sign-in still releases the port.
    static let oauthCallbackWindow: TimeInterval = 300
    /// Bound on a single request read. Without it a peer that connects and says nothing holds the
    /// leg open for the whole window.
    static let oauthCallbackReceiveTimeout: TimeInterval = 10

    static let oauthCallbackCompletePage = "<!doctype html><html><head><meta charset=\"utf-8\"><title>OpenNOW Sign In</title></head><body style=\"background:#050807;color:#f1fff7;font:16px -apple-system,BlinkMacSystemFont,sans-serif;display:grid;place-items:center;min-height:100vh;margin:0\"><main><h1>Sign in complete</h1><p>You can close this window and return to OpenNOW.</p></main><script>setTimeout(function(){window.close()},1200)</script></body></html>"
    static let oauthCallbackCancelledPage = "<!doctype html><html><head><meta charset=\"utf-8\"><title>OpenNOW Sign In</title></head><body style=\"background:#050807;color:#f1fff7;font:16px -apple-system,BlinkMacSystemFont,sans-serif;display:grid;place-items:center;min-height:100vh;margin:0\"><main><h1>Sign in cancelled</h1><p>Return to OpenNOW to try again.</p></main><script>setTimeout(function(){window.close()},1200)</script></body></html>"

    /// The loopback leg of the browser sign-in. The listener stays open until the authorization
    /// response arrives or the window closes.
    ///
    /// Any process on this machine can connect to this port, so a single-shot listener is a denial
    /// of service waiting to happen: accepting once and closing lets a stray connection — a
    /// preconnect, a favicon request, anything — consume the callback and leave the real one with
    /// a refused connection. Requests that are not the authorization response are answered and
    /// dropped, and the leg keeps waiting.
    func startOAuthCallbackListener(
        port: Int,
        expectedState: String,
        completion: @escaping @Sendable (Result<String, Error>) -> Void,
        readyHandler: @escaping @Sendable () -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard socketDescriptor >= 0 else {
                completion(.failure(ServiceError("Failed to create OAuth callback listener")))
                return
            }
            defer { close(socketDescriptor) }
            var reuse = Int32(1)
            setsockopt(socketDescriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
            address.sin_port = in_port_t(port).bigEndian
            let bindResult = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0, listen(socketDescriptor, 8) == 0 else {
                completion(.failure(ServiceError("Failed to bind OAuth callback listener")))
                return
            }
            readyHandler()
            let deadline = Date().addingTimeInterval(Self.oauthCallbackWindow)
            while Date() < deadline {
                guard Self.awaitConnection(socketDescriptor, timeout: min(deadline.timeIntervalSinceNow, 1)) else { continue }
                let clientSocket = accept(socketDescriptor, nil, nil)
                guard clientSocket >= 0 else { continue }
                guard let request = Self.receiveRequest(clientSocket),
                      let query = Self.callbackQuery(from: request),
                      Self.isAuthorizationResponse(query, expectedState: expectedState) else {
                    Self.respond(clientSocket, status: "404 Not Found", body: "")
                    close(clientSocket)
                    continue
                }
                let wasCancelled = (JarvisSessionParser.parseQueryString(query)["code"] ?? "").isEmpty
                Self.respond(clientSocket, status: "200 OK", body: wasCancelled ? Self.oauthCallbackCancelledPage : Self.oauthCallbackCompletePage)
                close(clientSocket)
                completion(.success(query))
                return
            }
            completion(.failure(ServiceError("Browser sign-in timed out")))
        }
    }

    /// Waits for the listening socket to become readable rather than blocking in `accept`, so the
    /// window is honored even when nothing ever connects.
    private static func awaitConnection(_ descriptor: Int32, timeout: TimeInterval) -> Bool {
        var descriptors = [pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)]
        let polled = poll(&descriptors, 1, Int32(max(1, timeout * 1000)))
        return polled > 0 && (descriptors[0].revents & Int16(POLLIN)) != 0
    }

    private static func receiveRequest(_ clientSocket: Int32) -> String? {
        var receiveTimeout = timeval(tv_sec: Int(oauthCallbackReceiveTimeout), tv_usec: 0)
        setsockopt(clientSocket, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 4096)
        let byteCount = recv(clientSocket, &buffer, buffer.count - 1, 0)
        guard byteCount > 0 else { return nil }
        return String(decoding: buffer.prefix(byteCount), as: UTF8.self)
    }

    private static func callbackQuery(from request: String) -> String? {
        guard let pathStart = request.range(of: "GET ")?.upperBound,
              let pathEnd = request[pathStart...].firstIndex(of: " ") else { return nil }
        let path = String(request[pathStart..<pathEnd])
        return path.split(separator: "?", maxSplits: 1).dropFirst().first.map(String.init)
    }

    /// Only the authorization response ends the leg, and only when it carries the `state` this
    /// login generated. Without that check anything sent to this port — including a request from
    /// an unrelated local process — could complete or fail the sign-in.
    private static func isAuthorizationResponse(_ query: String, expectedState: String) -> Bool {
        let parameters = JarvisSessionParser.parseQueryString(query)
        guard expectedState.isEmpty || parameters["state"] == expectedState else { return false }
        return !(parameters["code"] ?? "").isEmpty || !(parameters["error"] ?? "").isEmpty
    }

    private static func respond(_ clientSocket: Int32, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        _ = response.withCString { send(clientSocket, $0, strlen($0), 0) }
    }

    func findAvailablePort() -> Int {
        for port in [2259, 6460, 7119, 8870, 9096] {
            let probeSocket = socket(AF_INET, SOCK_STREAM, 0)
            if probeSocket >= 0 {
                var address = sockaddr_in()
                address.sin_family = sa_family_t(AF_INET)
                address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
                address.sin_port = in_port_t(port).bigEndian
                let hasListener = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(probeSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                    }
                }
                close(probeSocket)
                if hasListener { continue }
            }
            let testSocket = socket(AF_INET, SOCK_STREAM, 0)
            if testSocket < 0 { continue }
            var reuse = Int32(1)
            setsockopt(testSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
            address.sin_port = in_port_t(port).bigEndian
            let canBind = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(testSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
            close(testSocket)
            if canBind { return port }
        }
        return 0
    }

    func generatePKCEState() -> JarvisOAuthState {
        let verifier = generateRandomString(length: 64)
        return JarvisOAuthState(
            codeVerifier: verifier,
            codeChallenge: base64URLEncodedSHA256(verifier),
            state: generateRandomString(length: 32),
            nonce: generateRandomString(length: 32)
        )
    }

    func generateRandomString(length: Int) -> String {
        let characters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return String((0..<length).compactMap { _ in characters.randomElement() })
    }

    func base64URLEncodedSHA256(_ value: String) -> String {
        Data(SHA256.hash(data: Data(value.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func generateOpenNOWDeviceId() -> String {
        var hostnameBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let hostname = gethostname(&hostnameBuffer, hostnameBuffer.count) == 0
            ? String(decoding: hostnameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            : "unknown"
        let user = ProcessInfo.processInfo.environment["USER"] ?? "unknown"
        return SHA256.hash(data: Data("\(hostname):\(user):opennow-stable".utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
