import Foundation

import Foundation

public struct NVSTSignalingConfiguration: Equatable, Sendable {
    public var signalingServer: String
    public var sessionID: String
    public var signalingURL: String
    public var origin: String
    public var userAgent: String

    public init(signalingServer: String,
                sessionID: String,
                signalingURL: String = "",
                origin: String = "https://play.geforcenow.com",
                userAgent: String = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/131.0.0.0 Safari/537.36") {
        self.signalingServer = signalingServer
        self.sessionID = sessionID
        self.signalingURL = signalingURL
        self.origin = origin
        self.userAgent = userAgent
    }

    public var webSocketSubprotocol: String {
        "x-nv-sessionid.\(sessionID)"
    }

    public func signInURL(peerName: String) -> URL? {
        let baseURLString: String
        if !signalingURL.isEmpty {
            baseURLString = signalingURL
        } else if signalingServer.contains(":") {
            baseURLString = "wss://\(signalingServer)/nvst/"
        } else {
            baseURLString = "wss://\(signalingServer):443/nvst/"
        }

        var components = URLComponents(string: baseURLString) ?? URLComponents()
        components.scheme = "wss"
        if components.host == nil {
            components.host = signalingServer
        }
        var path = components.path.isEmpty ? "/nvst/" : components.path
        if !path.hasSuffix("/") {
            path += "/"
        }
        components.path = path + "sign_in"
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "peer_id", value: peerName))
        items.append(URLQueryItem(name: "version", value: "2"))
        items.append(URLQueryItem(name: "peer_role", value: "1"))
        items.append(URLQueryItem(name: "pairing_id", value: sessionID))
        components.queryItems = items
        return components.url
    }
}
