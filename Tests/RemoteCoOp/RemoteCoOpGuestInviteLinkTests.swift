//
//  RemoteCoOpGuestInviteLinkTests.swift
//  OpenNOW
//
//  A native guest joining by invite link, which is the only route that works through a tunnel.
//

import Foundation
import Testing
@testable import OpenNOW

@Suite("Remote Co-Op guest invite link")
struct RemoteCoOpGuestInviteLinkTests {
    @Test("a tunnel link resolves to the tunnel's own WebSocket")
    func tunnelLinkDerivesSignalingURL() throws {
        // What `cloudflared` produces: one hostname serving the page and the upgrade, no `server`
        // parameter because both are the same origin.
        let link = try #require(OPNRemoteCoOpGuestInviteLink(link: "https://brave-tiger-42.trycloudflare.com/?invite=TOKEN123"))
        #expect(link.token == "TOKEN123")
        #expect(link.signalingURL.absoluteString == "wss://brave-tiger-42.trycloudflare.com/remote-coop")
    }

    @Test("an explicit server parameter wins over the link's own host")
    func explicitServerParameterWins() throws {
        // The page and the socket do not have to share an origin, so a link that names the socket
        // must be believed rather than second-guessed from the page's host.
        let link = try #require(OPNRemoteCoOpGuestInviteLink(link: "https://page.example/?invite=ABC&server=wss://socket.example:9443/remote-coop"))
        #expect(link.token == "ABC")
        #expect(link.signalingURL.absoluteString == "wss://socket.example:9443/remote-coop")
    }

    @Test("a LAN link keeps its port, because the listener is not on 443")
    func lanLinkPreservesPort() throws {
        let link = try #require(OPNRemoteCoOpGuestInviteLink(link: "https://192.168.1.24:32188/?invite=TOKEN"))
        #expect(link.signalingURL.absoluteString == "wss://192.168.1.24:32188/remote-coop")
    }

    @Test("a link with extra query parameters still resolves")
    func linkWithExtraParametersResolves() throws {
        let link = try #require(OPNRemoteCoOpGuestInviteLink(link: "https://host.example/?code=ABCD&invite=TOKEN&theme=dark"))
        #expect(link.token == "TOKEN")
        #expect(link.signalingURL.absoluteString == "wss://host.example/remote-coop")
    }

    @Test("surrounding whitespace from a paste is ignored")
    func linkTolerantOfPastedWhitespace() throws {
        let link = try #require(OPNRemoteCoOpGuestInviteLink(link: "  https://host.example/?invite=TOKEN\n"))
        #expect(link.token == "TOKEN")
    }

    @Test("input that is not a usable invite link is refused")
    func nonLinksAreRefused() {
        // No token: the WebSocket server never greets with the invite, so a link without one leaves
        // the guest with nothing to present and must not be accepted as a route.
        #expect(OPNRemoteCoOpGuestInviteLink(link: "https://host.example/") == nil)
        #expect(OPNRemoteCoOpGuestInviteLink(link: "https://host.example/?invite=") == nil)
        // Bare addresses belong to the raw TCP path, and must not be mistaken for links.
        #expect(OPNRemoteCoOpGuestInviteLink(link: "100.101.102.103") == nil)
        #expect(OPNRemoteCoOpGuestInviteLink(link: "my-mac:32189") == nil)
        #expect(OPNRemoteCoOpGuestInviteLink(link: "") == nil)
        // A scheme that cannot carry a WebSocket.
        #expect(OPNRemoteCoOpGuestInviteLink(link: "ftp://host.example/?invite=TOKEN") == nil)
    }

    /// The two routes have to stay distinguishable from one field: a link is tried first because it is
    /// the more specific shape, and a bare address must never parse as one.
    @Test("addresses and links do not collide")
    func addressesAndLinksAreDisjoint() {
        let addresses = ["100.101.102.103", "100.101.102.103:41000", "my-mac", "my-mac.tail1234.ts.net", "[fd7a:115c::1]:41000"]
        for address in addresses {
            #expect(OPNRemoteCoOpGuestInviteLink(link: address) == nil, "\(address) must not parse as a link")
            #expect(OPNRemoteCoOpNativeDiscoveredHost(address: address) != nil, "\(address) must parse as an address")
        }
        let links = ["https://host.example/?invite=TOKEN", "https://192.168.1.24:32188/?invite=T"]
        for link in links {
            #expect(OPNRemoteCoOpGuestInviteLink(link: link) != nil, "\(link) must parse as a link")
        }
    }

    /// The link a host actually hands out has to be accepted by the guest that receives it. Built
    /// through the same code path the invite uses so the two cannot drift apart.
    @Test("the link a host generates is one a native guest can join with")
    func hostGeneratedLinkRoundTrips() async throws {
        let signaling = OPNInProcessRemoteCoOpSignalingSession()
        let hostSession = OPNRemoteCoOpHostSession(preferences: OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 1))
        let coordinator = OPNRemoteCoOpHostCoordinator(hostSession: hostSession, signaling: signaling)
        let invite = try await coordinator.startInvite(
            title: "Test",
            joinBaseURL: URL(string: "https://brave-tiger-42.trycloudflare.com/"),
            signalingServerURL: "wss://brave-tiger-42.trycloudflare.com/remote-coop",
            lifetimeSeconds: 120
        )
        let joinURL = try #require(invite.joinURL)
        let link = try #require(OPNRemoteCoOpGuestInviteLink(link: joinURL.absoluteString))
        #expect(link.token == invite.token)
        #expect(link.signalingURL.host == "brave-tiger-42.trycloudflare.com")
        #expect(link.signalingURL.path == "/remote-coop")
    }
}
