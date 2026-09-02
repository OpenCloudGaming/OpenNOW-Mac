//
//  RemoteCoOpAblyCredentialsTests.swift
//  OpenNOWTests
//
//  The signaling credential: an Ably JWT minted locally, and the invite fields that carry it.
//
//  Ably rejects a malformed JWT with an error the host cannot act on, so the structure is asserted
//  field by field rather than "it produced a string".
//

import CryptoKit
import Foundation
import Testing
@testable import OpenNOW

@Suite struct RemoteCoOpAblyCredentialsTests {
    private let key = OPNRemoteCoOpAblyKey(name: "appid.keyid", secret: "s3cr3t")
    private let issued = Date(timeIntervalSince1970: 1_700_000_000)

    private func segments(_ jwt: String) throws -> (header: [String: Any], claims: [String: Any], signingInput: String, signature: String) {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        #expect(parts.count == 3)
        let header = try #require(decodeSegment(parts[0]))
        let claims = try #require(decodeSegment(parts[1]))
        return (header, claims, "\(parts[0]).\(parts[1])", parts[2])
    }

    private func decodeSegment(_ segment: String) -> [String: Any]? {
        var base64 = segment.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - Key parsing

    @Test func parsesThePastedDashboardForm() throws {
        let parsed = try #require(OPNRemoteCoOpAblyKey(pasted: "  appid.keyid:secretvalue \n"))
        #expect(parsed.name == "appid.keyid")
        #expect(parsed.secret == "secretvalue")
        #expect(parsed.isUsable)
    }

    /// A secret containing a colon must survive: only the first colon separates name from secret.
    @Test func onlyTheFirstColonSeparates() throws {
        let parsed = try #require(OPNRemoteCoOpAblyKey(pasted: "appid.keyid:aa:bb:cc"))
        #expect(parsed.secret == "aa:bb:cc")
    }

    /// Refused rather than half-accepted: a name without a dot is not an Ably key, and signing with it
    /// yields a JWT Ably rejects for a reason the host cannot act on.
    @Test func refusesAnythingThatIsNotAnAblyKey() throws {
        #expect(OPNRemoteCoOpAblyKey(pasted: "noseparator") == nil)
        #expect(OPNRemoteCoOpAblyKey(pasted: "nodot:secret") == nil)
        #expect(OPNRemoteCoOpAblyKey(pasted: "appid.keyid:") == nil)
        #expect(OPNRemoteCoOpAblyKey(pasted: ".keyid:secret") == nil)
        #expect(OPNRemoteCoOpAblyKey(pasted: "") == nil)
    }

    // MARK: - JWT structure

    @Test func theHeaderNamesTheKeyAndTheAlgorithm() throws {
        let jwt = try #require(OPNRemoteCoOpAblyJWT.mintGuestToken(key: key, channel: "room", issuedAt: issued, expiresAt: issued.addingTimeInterval(3_600)))
        let parsed = try segments(jwt)
        #expect(parsed.header["alg"] as? String == "HS256")
        #expect(parsed.header["typ"] as? String == "JWT")
        // Ably identifies which key signed this by `kid`; without it the JWT cannot be verified at all.
        #expect(parsed.header["kid"] as? String == "appid.keyid")
    }

    /// The capability is a JSON *string*, not an object. Ably parses the claim's contents itself, so
    /// an object here is silently the wrong shape.
    ///
    /// This is also the security boundary of the whole hosted transport, so it is asserted exactly:
    /// a guest must NOT hold `publish` on the host channel. It used to be one channel with
    /// channel-wide publish, which let any invite holder publish as the host - spoofing an offer to
    /// hijack another guest's WebRTC session, or replacing their ICE servers to route that guest's
    /// media through an attacker. Ably enforces this server-side; a client-side check cannot.
    @Test func aGuestTokenMayReadTheHostChannelButNeverPublishToIt() throws {
        let jwt = try #require(OPNRemoteCoOpAblyJWT.mintGuestToken(key: key, channel: "room-a", issuedAt: issued, expiresAt: issued.addingTimeInterval(3_600)))
        let claims = try segments(jwt).claims
        let capability = try #require(claims["x-ably-capability"] as? String, "capability must be a string, not an object")

        let decoded = try #require(try JSONSerialization.jsonObject(with: Data(capability.utf8)) as? [String: [String]])
        #expect(decoded.keys.sorted() == ["room-a:guest", "room-a:host"], "the token reaches a channel other than its own")
        #expect(decoded["room-a:host"] == ["subscribe"], "a guest that can publish on the host channel can impersonate the host")
        #expect(decoded["room-a:guest"]?.sorted() == ["presence", "publish"])
    }

    /// The host's capability is the mirror image, and it is what makes the guest's restriction
    /// meaningful: the host must be the only party that can publish where guests listen.
    @Test func aHostTokenPublishesOnlyOnTheHostChannel() throws {
        let jwt = try #require(OPNRemoteCoOpAblyJWT.mintHostToken(key: key, channel: "room-a", issuedAt: issued, expiresAt: issued.addingTimeInterval(3_600)))
        let capability = try #require(try segments(jwt).claims["x-ably-capability"] as? String)
        let decoded = try #require(try JSONSerialization.jsonObject(with: Data(capability.utf8)) as? [String: [String]])
        #expect(decoded["room-a:host"] == ["publish"])
        #expect(decoded["room-a:guest"]?.sorted() == ["presence", "subscribe"])
    }

    /// Both sides derive the two channel names, and the browser guest hardcodes the same suffixes.
    /// A drift here does not fail loudly - signaling just goes nowhere - so the shape is pinned.
    @Test func theTwoChannelNamesAreDerivedFromTheInviteChannel() throws {
        let base = OPNRemoteCoOpAblyJWT.channelName(inviteID: UUID(uuidString: "4A9A239E-241C-470E-BC62-0507FABC50A1")!)
        #expect(base == "opennow-remote-coop:4a9a239e-241c-470e-bc62-0507fabc50a1")
        #expect(OPNRemoteCoOpAblyJWT.hostChannelName(base: base) == "\(base):host")
        #expect(OPNRemoteCoOpAblyJWT.guestChannelName(base: base) == "\(base):guest")
    }

    /// Without this claim the token is anonymous, and Ably raises a clientId-mismatch error the
    /// moment a client that declares one - which the browser guest does - tries to connect with it.
    /// Caught only by reading Ably's own docs, not by anything that runs; pinned here so it cannot
    /// regress silently a second time.
    @Test func grantsAWildcardClientIDSoAGuestMayDeclareItsParticipantID() throws {
        let jwt = try #require(OPNRemoteCoOpAblyJWT.mintGuestToken(key: key, channel: "room", issuedAt: issued, expiresAt: issued.addingTimeInterval(60)))
        let claims = try segments(jwt).claims
        #expect(claims["x-ably-clientId"] as? String == "*")
    }

    @Test func theTokenExpiresWithTheInvite() throws {
        let expiry = issued.addingTimeInterval(3_600)
        let jwt = try #require(OPNRemoteCoOpAblyJWT.mintGuestToken(key: key, channel: "room", issuedAt: issued, expiresAt: expiry))
        let claims = try segments(jwt).claims
        #expect(claims["iat"] as? Int == Int(issued.timeIntervalSince1970))
        #expect(claims["exp"] as? Int == Int(expiry.timeIntervalSince1970))
    }

    /// Signed over `header.claims` with the key secret. Verified here rather than trusted, because a
    /// wrong signing input produces a well-formed JWT that only Ably will reject.
    @Test func theSignatureIsHMACSHA256OverTheSigningInput() throws {
        let jwt = try #require(OPNRemoteCoOpAblyJWT.mintGuestToken(key: key, channel: "room", issuedAt: issued, expiresAt: issued.addingTimeInterval(60)))
        let parsed = try segments(jwt)
        let expected = HMAC<SHA256>.authenticationCode(
            for: Data(parsed.signingInput.utf8),
            using: SymmetricKey(data: Data("s3cr3t".utf8))
        )
        let expectedSegment = Data(expected).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #expect(parsed.signature == expectedSegment)
    }

    /// JWT base64url is unpadded and URL-safe. A `+`, `/` or `=` anywhere means a decoder somewhere
    /// rejects the token, and the invite carrying it is a URL.
    @Test func everySegmentIsUnpaddedBase64URL() throws {
        // Bytes chosen to force `+` and `/` under standard base64.
        let awkward = OPNRemoteCoOpAblyKey(name: "app.key", secret: "\u{00FF}\u{00FE}?>~")
        let jwt = try #require(OPNRemoteCoOpAblyJWT.mintGuestToken(key: awkward, channel: "room?>", issuedAt: issued, expiresAt: issued.addingTimeInterval(60)))
        #expect(!jwt.contains("="))
        #expect(!jwt.contains("+"))
        #expect(!jwt.contains("/"))
    }

    @Test func refusesToMintWithoutSomethingToSignOrSomewhereToPoint() throws {
        let valid = issued.addingTimeInterval(60)
        #expect(OPNRemoteCoOpAblyJWT.mintGuestToken(key: OPNRemoteCoOpAblyKey(name: "", secret: "s"), channel: "c", issuedAt: issued, expiresAt: valid) == nil)
        #expect(OPNRemoteCoOpAblyJWT.mintGuestToken(key: OPNRemoteCoOpAblyKey(name: "a.b", secret: ""), channel: "c", issuedAt: issued, expiresAt: valid) == nil)
        #expect(OPNRemoteCoOpAblyJWT.mintGuestToken(key: key, channel: "", issuedAt: issued, expiresAt: valid) == nil)
        // Already expired: a credential that cannot be used is a failure to report, not to hand out.
        #expect(OPNRemoteCoOpAblyJWT.mintGuestToken(key: key, channel: "c", issuedAt: issued, expiresAt: issued) == nil)
    }

    /// A new invite is a new channel, so a credential that outlived its invite has nothing left to
    /// address even before its own expiry.
    @Test func theChannelIsDerivedFromTheInvite() throws {
        let a = OPNRemoteCoOpAblyJWT.channelName(inviteID: UUID())
        let b = OPNRemoteCoOpAblyJWT.channelName(inviteID: UUID())
        #expect(a != b)
        #expect(a.hasPrefix("opennow-remote-coop:"), "an unnamespaced channel could be granted beyond Remote Co-Op")
    }

    // MARK: - Invite payload

    private func payload(kind: OPNRemoteCoOpSignalingKind, channel: String?, token: String?) -> OPNRemoteCoOpInviteTokenPayload {
        OPNRemoteCoOpInviteTokenPayload(
            inviteID: UUID(),
            code: "ABC123",
            applicationID: "app",
            title: "Game",
            createdAt: issued,
            expiresAt: issued.addingTimeInterval(3_600),
            preferences: OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 1),
            signalingKind: kind,
            signalingChannel: channel,
            signalingToken: token
        )
    }

    @Test func aHostedInviteCarriesItsChannelAndCredential() throws {
        let hosted = payload(kind: .hosted, channel: "room", token: "jwt")
        #expect(hosted.signalingKind == .hosted)
        #expect(hosted.signalingChannel == "room")
        #expect(hosted.signalingToken == "jwt")
    }

    /// An embedded invite carrying a channel would be a lie the guest could act on, so the fields are
    /// dropped rather than trusted to be unset by the caller.
    @Test func anEmbeddedInviteCarriesNeither() throws {
        let embedded = payload(kind: .embedded, channel: "room", token: "jwt")
        #expect(embedded.signalingChannel == nil)
        #expect(embedded.signalingToken == nil)
    }

    /// Version 1 invites predate these fields entirely and must keep working, meaning the embedded
    /// server — which is what they always meant.
    @Test func aVersionOneInviteDecodesAsEmbedded() throws {
        let legacy = """
        {"version":1,"inviteID":"\(UUID().uuidString)","code":"ABC123",
         "createdAtEpochSeconds":1700000000,"expiresAtEpochSeconds":1700003600}
        """
        let decoded = try JSONDecoder().decode(OPNRemoteCoOpInviteTokenPayload.self, from: Data(legacy.utf8))
        #expect(decoded.signalingKind == .embedded)
        #expect(decoded.signalingChannel == nil)
        #expect(decoded.signalingToken == nil)
    }

    /// The signer covers the whole payload, so the channel and credential cannot be edited in a link.
    @Test func theSignalingFieldsAreCoveredBySignature() throws {
        let signer = OPNRemoteCoOpInviteTokenSigner()
        let hosted = payload(kind: .hosted, channel: "room", token: "jwt")
        let token = try signer.token(for: hosted)
        let verified = try signer.verify(token, now: issued.addingTimeInterval(60))
        #expect(verified.signalingChannel == "room")
        #expect(verified.signalingToken == "jwt")

        // Tamper with the channel and the signature must fail.
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        var base64 = parts[0].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        let raw = try #require(Data(base64Encoded: base64))
        let tampered = String(data: raw, encoding: .utf8)!.replacingOccurrences(of: "\"room\"", with: "\"evil\"")
        let reencoded = Data(tampered.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #expect(throws: (any Error).self) {
            _ = try signer.verify("\(reencoded).\(parts[1])", now: issued.addingTimeInterval(60))
        }
    }

    // MARK: - Invite creation

    private func hostSession() -> OPNRemoteCoOpHostSession {
        OPNRemoteCoOpHostSession(preferences: OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 1))
    }

    /// Reads the payload back through the session's own signer, which is the only thing that can
    /// verify it, and asserts the hosted fields survived the round trip into the token a guest holds.
    @Test func theHostedChannelAndCredentialReachTheGuestsToken() async throws {
        let signer = OPNRemoteCoOpInviteTokenSigner()
        let session = OPNRemoteCoOpHostSession(
            preferences: OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 1),
            inviteSigner: signer
        )
        let key = self.key
        let invite = try await session.startInvite(lifetimeSeconds: 600) { inviteID, expiresAt in
            let channel = OPNRemoteCoOpAblyJWT.channelName(inviteID: inviteID)
            guard let token = OPNRemoteCoOpAblyJWT.mintGuestToken(key: key, channel: channel, expiresAt: expiresAt) else { return nil }
            return OPNRemoteCoOpInviteSignaling(channel: channel, token: token)
        }

        let payload = try signer.verify(invite.token, now: Date())
        #expect(payload.signalingKind == .hosted)
        #expect(payload.signalingToken?.split(separator: ".").count == 3, "the invite carries something that is not a JWT")
        // The channel is named after this invite, so an older invite's credential addresses nothing.
        #expect(payload.signalingChannel == OPNRemoteCoOpAblyJWT.channelName(inviteID: invite.id))
    }

    /// The native listener greets any socket that connects, before it has presented anything, so the
    /// invite it hands over must not carry the hosted-signaling credential.
    ///
    /// That credential grants publish on this invite's guest channel and subscribe on its host
    /// channel - reach well beyond the LAN or tailnet the listener is exposed on, and a native guest
    /// is already connected directly and needs none of it. The greeting still has to *verify*, since
    /// the guest echoes it straight back as its join.
    @Test func theNativeGreetingCarriesNoHostedCredential() async throws {
        let signer = OPNRemoteCoOpInviteTokenSigner()
        let session = OPNRemoteCoOpHostSession(
            preferences: OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 1),
            inviteSigner: signer
        )
        let key = self.key
        let invite = try await session.startInvite(joinBaseURL: URL(string: "https://pages.example/guest/"), lifetimeSeconds: 600) { inviteID, expiresAt in
            let channel = OPNRemoteCoOpAblyJWT.channelName(inviteID: inviteID)
            guard let token = OPNRemoteCoOpAblyJWT.mintGuestToken(key: key, channel: channel, expiresAt: expiresAt) else { return nil }
            return OPNRemoteCoOpInviteSignaling(channel: channel, token: token)
        }
        // Positive control: the real invite does carry it, so this test is comparing two things that
        // differ rather than asserting a credential that was never minted.
        #expect(try signer.verify(invite.token, now: Date()).signalingToken != nil)

        let greeting = try #require(await session.greetingInvite())
        let payload = try signer.verify(greeting.token, now: Date())
        #expect(payload.signalingToken == nil, "the greeting hands the Ably credential to anyone who opens a socket")
        #expect(payload.signalingChannel == nil)
        #expect(payload.signalingKind == .embedded)
        // The join URL embeds the token in its query, so it goes too.
        #expect(greeting.joinURL == nil)
        // Still the same invite, and still verifiable - the guest echoes this straight back.
        #expect(payload.inviteID == invite.id)
        #expect(payload.code == invite.code)
        #expect(greeting.token != invite.token)
    }

    /// No key configured is the common case and must stay embedded — the transport that needs no
    /// account and no third party.
    @Test func noKeyLeavesTheInviteEmbedded() async throws {
        let signer = OPNRemoteCoOpInviteTokenSigner()
        let session = OPNRemoteCoOpHostSession(
            preferences: OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 1),
            inviteSigner: signer
        )
        let invite = try await session.startInvite(lifetimeSeconds: 600) { _, _ in nil }
        let payload = try signer.verify(invite.token, now: Date())
        #expect(payload.signalingKind == .embedded)
        #expect(payload.signalingToken == nil)
    }

    /// The host subscribes to the channel before the invite naming it goes out, so both must be
    /// derived from the same ID. Reading it off the invite afterwards was the bug: the coordinator is
    /// built first, so the invite is always nil at that point and hosted signaling silently never
    /// activated.
    @Test func theInviteIDIsTheHostsToChooseSoBothSidesAgree() async throws {
        let session = hostSession()
        let chosen = UUID()
        let invite = try await session.startInvite(inviteID: chosen, lifetimeSeconds: 600)
        #expect(invite.id == chosen)
    }

    // MARK: - Effective hosted guest page URL

    @Test func requiresHTTPSForTheHostedGuestPage() throws {
        var preferences = OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 1)
        preferences.hostedGuestPageURL = "http://plain.example/guest"
        #expect(preferences.effectiveHostedGuestPageURL == nil, "a plaintext guest page would leave the guest unable to open RTCPeerConnection")

        preferences.hostedGuestPageURL = "https://user.github.io/opennow-remote-coop/"
        #expect(preferences.effectiveHostedGuestPageURL?.absoluteString == "https://user.github.io/opennow-remote-coop/")
    }

    @Test func emptyHostedGuestPageURLMeansServeItLocally() throws {
        let preferences = OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 1)
        #expect(preferences.hostedGuestPageURL.isEmpty)
        #expect(preferences.effectiveHostedGuestPageURL == nil)
    }

    /// A hosted invite pointed at a static page carries no `server` query item: there is no
    /// `wss://` URL for it, since the guest signals over the channel named in the invite payload
    /// instead. A stray empty `server=` in the link would be worse than nothing - the guest page
    /// would try to connect to it.
    @Test func aStaticGuestPageJoinLinkCarriesNoServerParameter() async throws {
        let session = OPNRemoteCoOpHostSession(preferences: OPNRemoteCoOpPreferences(isEnabled: true, reservedGuestSlots: 1))
        let invite = try await session.startInvite(
            joinBaseURL: URL(string: "https://user.github.io/opennow-remote-coop/"),
            signalingServerURL: "",
            lifetimeSeconds: 600
        ) { inviteID, expiresAt in
            let channel = OPNRemoteCoOpAblyJWT.channelName(inviteID: inviteID)
            guard let token = OPNRemoteCoOpAblyJWT.mintGuestToken(key: self.key, channel: channel, expiresAt: expiresAt) else { return nil }
            return OPNRemoteCoOpInviteSignaling(channel: channel, token: token)
        }
        let joinURL = try #require(invite.joinURL)
        let components = try #require(URLComponents(url: joinURL, resolvingAgainstBaseURL: false))
        #expect(components.host == "user.github.io")
        #expect(components.queryItems?.contains { $0.name == "invite" } == true)
        #expect(components.queryItems?.contains { $0.name == "server" } != true,
                "a static page link should not carry a signaling server address")
    }
}
