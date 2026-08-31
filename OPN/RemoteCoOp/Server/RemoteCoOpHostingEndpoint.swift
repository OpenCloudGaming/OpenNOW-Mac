//
//  RemoteCoOpHostingEndpoint.swift
//  OpenNOW
//
//  Decides where a Remote Co-Op session's signaling lives, and hands back a session plus the two
//  addresses that go into the invite.
//
//  Both stream surfaces - native NVST and WebRTC - need exactly this and nothing else from the
//  choice between hosting locally and using a deployed broker, so the branch lives here rather than
//  twice in two view models.
//

import Foundation

public struct OPNRemoteCoOpHostingSession: @unchecked Sendable {
    public let signaling: any OPNRemoteCoOpSignalingSession
    public let joinBaseURL: URL?
    public let signalingServerURL: String
    /// Nil when a tunnel is advertising the session: the guest validates the tunnel's certificate,
    /// not this Mac's, so there is no fingerprint for them to compare.
    public let certificateFingerprint: String?
    /// The embedded server, retained so the caller can stop it with the session.
    public let embeddedServer: OPNRemoteCoOpEmbeddedServer?

    public var isLocallyHosted: Bool { embeddedServer != nil }
}

public enum OPNRemoteCoOpHostingEndpointError: LocalizedError {
    case guestPageMissing

    public var errorDescription: String? {
        switch self {
        case .guestPageMissing:
            return "The Remote Co-Op guest page is missing from the app bundle."
        }
    }
}

public enum OPNRemoteCoOpHostingEndpoint {
    /// The port the embedded server binds. Fixed rather than ephemeral so a guest's accepted
    /// certificate exception, which is per origin and therefore per port, survives a restart.
    public static let defaultLocalPort: UInt16 = 32188

    /// Starts the local server and returns the addresses that go into the invite.
    ///
    /// There is one hosting path now. A separately deployed Node broker used to be the alternative,
    /// chosen because a rendezvous both sides dial *out* to works from behind any NAT - but it also
    /// meant a server to operate, a shared signing secret to keep in sync, and a deployment nobody
    /// on this project maintained. A tunnel gives the same outbound reachability with nothing to
    /// run, so the broker and everything supporting it is gone. See `publicAddress`.
    public static func make(preferences: OPNRemoteCoOpPreferences,
                            networkConfiguration: OPNRemoteCoOpNetworkConfiguration,
                            logger: (@Sendable (String) -> Void)? = nil) async throws -> OPNRemoteCoOpHostingSession {
        guard let documentRoot = OPNRemoteCoOpEmbeddedServer.bundledDocumentRoot() else {
            throw OPNRemoteCoOpHostingEndpointError.guestPageMissing
        }
        // The certificate is always minted for the address the listener is reachable at on this
        // machine, never for a tunnel hostname: a tunnel terminates TLS itself and connects to this
        // server as an upstream, so the browser only ever validates the tunnel's own certificate.
        let host = OPNRemoteCoOpLocalAddress.advertisedHost()
        let identity = try OPNRemoteCoOpTLSIdentity.identity(for: host)
        let tunnel = preferences.effectivePublicAddress
        let server = OPNRemoteCoOpEmbeddedServer(
            documentRoot: documentRoot,
            networkConfiguration: networkConfiguration,
            // Guests arrive with the tunnel's `Origin`, not this machine's, so the allowlist has to
            // know about it or every upgrade through the tunnel is rejected.
            additionalAllowedOrigins: tunnel.map { [originString(for: $0)] } ?? [],
            logger: logger
        )
        let endpoint = try await server.start(port: defaultLocalPort, advertisedHost: host, identity: identity)
        guard let tunnel else {
            return OPNRemoteCoOpHostingSession(
                signaling: OPNEmbeddedRemoteCoOpSignalingSession(server: server),
                joinBaseURL: URL(string: endpoint.guestJoinBaseURL),
                signalingServerURL: endpoint.signalingServerURL,
                certificateFingerprint: endpoint.certificateFingerprint,
                embeddedServer: server
            )
        }
        logger?("Remote Co-Op advertising tunnel address \(tunnel.absoluteString)")
        return OPNRemoteCoOpHostingSession(
            signaling: OPNEmbeddedRemoteCoOpSignalingSession(server: server),
            joinBaseURL: tunnel,
            signalingServerURL: signalingURL(forTunnel: tunnel),
            // The guest validates the tunnel's certificate, so this Mac's fingerprint is not
            // something they will ever be shown.
            certificateFingerprint: nil,
            embeddedServer: server
        )
    }

    /// `wss://<tunnel host>/remote-coop`, preserving a non-default port if the tunnel names one.
    static func signalingURL(forTunnel tunnel: URL) -> String {
        var components = URLComponents(url: tunnel, resolvingAgainstBaseURL: false)
        components?.scheme = "wss"
        components?.path = "/remote-coop"
        components?.query = nil
        components?.fragment = nil
        return components?.url?.absoluteString ?? "wss://\(tunnel.host ?? "")/remote-coop"
    }

    /// The `Origin` a browser sends for a page served from `url`: scheme, host, and the port only
    /// when it is not the scheme's default.
    static func originString(for url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? "https"
        let host = url.host ?? ""
        guard let port = url.port, !(scheme == "https" && port == 443), !(scheme == "http" && port == 80) else {
            return "\(scheme)://\(host)"
        }
        return "\(scheme)://\(host):\(port)"
    }
}
