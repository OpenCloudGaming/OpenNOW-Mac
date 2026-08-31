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
    /// Present only when hosting locally. The host can read it out so a guest can confirm the
    /// certificate they accepted is the one being presented.
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

    public static func make(preferences: OPNRemoteCoOpPreferences,
                            networkConfiguration: OPNRemoteCoOpNetworkConfiguration,
                            logger: (@Sendable (String) -> Void)? = nil) async throws -> OPNRemoteCoOpHostingSession {
        switch preferences.hostingMode {
        case .externalBroker:
            return externalSession(preferences: preferences)
        case .local:
            return try await localSession(networkConfiguration: networkConfiguration, logger: logger)
        }
    }

    private static func externalSession(preferences: OPNRemoteCoOpPreferences) -> OPNRemoteCoOpHostingSession {
        let trimmed = preferences.signalingServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let signaling: any OPNRemoteCoOpSignalingSession
        if let serverURL = URL(string: trimmed), serverURL.scheme?.hasPrefix("ws") == true {
            signaling = OPNRemoteCoOpWebSocketSignalingSession(serverURL: serverURL)
        } else {
            // Nothing usable configured. An in-process session keeps the host side working and
            // simply never receives a guest, rather than failing the invite outright.
            signaling = OPNInProcessRemoteCoOpSignalingSession()
        }
        return OPNRemoteCoOpHostingSession(
            signaling: signaling,
            joinBaseURL: URL(string: preferences.guestJoinBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
            signalingServerURL: trimmed,
            certificateFingerprint: nil,
            embeddedServer: nil
        )
    }

    private static func localSession(networkConfiguration: OPNRemoteCoOpNetworkConfiguration,
                                     logger: (@Sendable (String) -> Void)?) async throws -> OPNRemoteCoOpHostingSession {
        guard let documentRoot = OPNRemoteCoOpEmbeddedServer.bundledDocumentRoot() else {
            throw OPNRemoteCoOpHostingEndpointError.guestPageMissing
        }
        // The advertised address goes into both the invite link and the certificate, and a browser
        // checks the name even while overriding trust - so they must be the same string.
        let host = OPNRemoteCoOpLocalAddress.advertisedHost()
        let identity = try OPNRemoteCoOpTLSIdentity.identity(for: host)
        let server = OPNRemoteCoOpEmbeddedServer(documentRoot: documentRoot, networkConfiguration: networkConfiguration, logger: logger)
        let endpoint = try await server.start(port: defaultLocalPort, advertisedHost: host, identity: identity)
        return OPNRemoteCoOpHostingSession(
            signaling: OPNEmbeddedRemoteCoOpSignalingSession(server: server),
            joinBaseURL: URL(string: endpoint.guestJoinBaseURL),
            signalingServerURL: endpoint.signalingServerURL,
            certificateFingerprint: endpoint.certificateFingerprint,
            embeddedServer: server
        )
    }
}
