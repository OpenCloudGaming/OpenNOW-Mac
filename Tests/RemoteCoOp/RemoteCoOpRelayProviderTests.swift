//
//  RemoteCoOpRelayProviderTests.swift
//  OpenNOWTests
//
//  The relay providers that need no API: pasted credentials, and coturn's shared-secret scheme.
//

import CryptoKit
import Foundation
import Testing
@testable import OpenNOW

@Suite struct RemoteCoOpRelayProviderTests {

    // MARK: - Static credentials

    @Test func staticCredentialsBecomeOneICEServer() throws {
        let relay = OPNRemoteCoOpStaticRelay(
            urlText: "turns:relay.example.com:443?transport=tcp\nturn:relay.example.com:3478",
            username: "user",
            password: "pass"
        )
        #expect(relay.isUsable)
        let servers = relay.iceServers
        #expect(servers.count == 1)
        #expect(servers[0].urls.count == 2)
        #expect(servers[0].username == "user")
        #expect(servers[0].credential == "pass")
    }

    /// Hosts paste these out of dashboards and JavaScript snippets, so the separators and the leftover
    /// quotes and commas of a copied array literal all have to survive.
    @Test func pastedURLListsAreParsedHoweverTheyArrive() throws {
        let cases = [
            "turns:a.example:443, turn:b.example:3478",
            "turns:a.example:443\nturn:b.example:3478",
            "\"turns:a.example:443\", \"turn:b.example:3478\"",
            "  turns:a.example:443   turn:b.example:3478  ",
        ]
        for text in cases {
            let relay = OPNRemoteCoOpStaticRelay(urlText: text, username: "u", password: "p")
            #expect(relay.urls == ["turns:a.example:443", "turn:b.example:3478"], "failed for \(text)")
        }
    }

    /// A host pasting straight from a provider's dashboard gets `host:port`, not a URL. Supplying the
    /// scheme is the difference between that working and silently relaying nothing.
    @Test func aBareHostGetsASchemeInferredFromItsPort() throws {
        let relay = OPNRemoteCoOpStaticRelay(
            urlText: "relay1.expressturn.com:3480, relay1.expressturn.com:443",
            username: "u",
            password: "p"
        )
        #expect(relay.urls == [
            "turn:relay1.expressturn.com:3480",
            "turns:relay1.expressturn.com:443",
            "turn:relay1.expressturn.com:443?transport=tcp",
        ])
    }

    /// Port 443 does not settle whether a server speaks TLS: ExpressTURN's free tier serves plain
    /// TURN there and reserves turns: for paid plans, so guessing either way is wrong for somebody.
    /// Both are offered and ICE keeps whichever allocates.
    @Test func anAmbiguousTLSPortOffersBothSchemes() throws {
        #expect(OPNRemoteCoOpRelayURLs.normalise("free.expressturn.com:443")
                == ["turns:free.expressturn.com:443", "turn:free.expressturn.com:443?transport=tcp"])
        #expect(OPNRemoteCoOpRelayURLs.normalise("a.example:5349")
                == ["turns:a.example:5349", "turn:a.example:5349?transport=tcp"])
    }

    @Test func unambiguousPortsGetASingleScheme() throws {
        // 80 is never TLS, and TCP is the entire reason to relay over it.
        #expect(OPNRemoteCoOpRelayURLs.normalise("a.example:80") == ["turn:a.example:80?transport=tcp"])
        #expect(OPNRemoteCoOpRelayURLs.normalise("a.example:3478") == ["turn:a.example:3478"])
        #expect(OPNRemoteCoOpRelayURLs.normalise("a.example:3480") == ["turn:a.example:3480"])
        #expect(OPNRemoteCoOpRelayURLs.normalise("a.example") == ["turn:a.example"])
    }

    @Test func anExplicitSchemeIsNeverOverridden() throws {
        // Someone who typed turn: on 443 meant it; a provider can serve plaintext TURN there.
        #expect(OPNRemoteCoOpRelayURLs.normalise("turn:turn.example.com:443") == ["turn:turn.example.com:443"])
        #expect(OPNRemoteCoOpRelayURLs.normalise("turns:turn.example.com:3478") == ["turns:turn.example.com:3478"])
    }

    /// Expanding one entry into two must not produce duplicates when a host also typed one of them
    /// explicitly - a repeated URL is a wasted allocation attempt on every invite.
    @Test func expansionDoesNotDuplicateAnExplicitEntry() throws {
        let relay = OPNRemoteCoOpStaticRelay(
            urlText: "turns:a.example:443\na.example:443",
            username: "u",
            password: "p"
        )
        #expect(relay.urls == ["turns:a.example:443", "turn:a.example:443?transport=tcp"])
    }

    /// Inference must not fire on a half-typed hostname, or the recognised-URL count reads as a
    /// working relay while the host is still typing.
    @Test func inferenceRequiresSomethingHostShaped() throws {
        #expect(OPNRemoteCoOpRelayURLs.normalise("t").isEmpty)
        #expect(OPNRemoteCoOpRelayURLs.normalise("relay").isEmpty)
        #expect(OPNRemoteCoOpRelayURLs.normalise("https://dashboard.example.com").isEmpty)
        #expect(OPNRemoteCoOpRelayURLs.normalise("").isEmpty)
    }

    /// A pasted dashboard line can include an https: URL. Dropping it beats letting it reach the peer
    /// connection, where one unusable entry can invalidate the whole ICE server at negotiation time.
    @Test func nonRelaySchemesAreDropped() throws {
        let relay = OPNRemoteCoOpStaticRelay(urlText: "https://dashboard.example, turns:a.example:443", username: "u", password: "p")
        #expect(relay.urls == ["turns:a.example:443"])
    }

    /// The settings rows commit on every keystroke and write the stored value back into the field, so
    /// anything normalised on the way in erases what the host is halfway through typing. This walks a
    /// real URL one character at a time: every prefix has to survive, including the ones that are not
    /// yet a valid URL.
    @Test func aHalfTypedURLIsNotErased() throws {
        let target = "turns:relay1.expressturn.com:443"
        for length in 1...target.count {
            let typed = String(target.prefix(length))
            let relay = OPNRemoteCoOpStaticRelay(urlText: typed, username: "u", password: "p")
            #expect(relay.urlText == typed, "lost input at \(length) characters")
        }
        let complete = OPNRemoteCoOpStaticRelay(urlText: target, username: "u", password: "p")
        #expect(complete.urls == [target])
        #expect(complete.isUsable)
    }

    /// Same for the shared secret, whose URL field has the same shape.
    @Test func aHalfTypedSecretURLIsNotErased() throws {
        let target = "turns:turn.example.com:443?transport=tcp"
        for length in 1...target.count {
            let typed = String(target.prefix(length))
            #expect(OPNRemoteCoOpSharedSecretRelay(urlText: typed, secret: "k").urlText == typed)
        }
    }

    /// Whitespace a host is mid-way through typing has to survive too - trimming on the way in makes
    /// a trailing space impossible to type.
    @Test func credentialsAreStoredVerbatimAndTrimmedOnlyWhenRead() throws {
        let relay = OPNRemoteCoOpStaticRelay(urlText: "turns:a.example:443", username: "  user ", password: " pass ")
        #expect(relay.rawUsername == "  user ")
        #expect(relay.username == "user")
        #expect(relay.password == "pass")
        #expect(relay.iceServers.first?.username == "user")
    }

    @Test func staticRelayNeedsAllThreeParts() throws {
        #expect(!OPNRemoteCoOpStaticRelay(urlText: "", username: "u", password: "p").isUsable)
        #expect(!OPNRemoteCoOpStaticRelay(urlText: "turns:a.example:443", username: "", password: "p").isUsable)
        #expect(!OPNRemoteCoOpStaticRelay(urlText: "turns:a.example:443", username: "u", password: "").isUsable)
        #expect(OPNRemoteCoOpStaticRelay(urlText: "turns:a.example:443", username: "u", password: "p").isUsable)
    }

    // MARK: - Shared secret

    /// coturn validates `username = <expiry>:<name>` against `base64(HMAC-SHA1(secret, username))`
    /// without being told anything in advance, so this has to match its arithmetic exactly - a wrong
    /// digest or a wrong username shape is rejected with no diagnostic beyond a failed connection.
    @Test func sharedSecretMatchesCoturnsScheme() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let relay = OPNRemoteCoOpSharedSecretRelay(urlText: "turns:turn.example:443", secret: "s3cr3t", username: "opennow")
        let servers = relay.iceServers(now: now, ttlSeconds: 3_600)
        let server = try #require(servers.first)

        let expectedUser = "1700003600:opennow"
        #expect(server.username == expectedUser)

        let mac = HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(expectedUser.utf8),
            using: SymmetricKey(data: Data("s3cr3t".utf8))
        )
        #expect(server.credential == Data(mac).base64EncodedString())
    }

    @Test func sharedSecretUsernameCarriesTheExpiry() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let relay = OPNRemoteCoOpSharedSecretRelay(urlText: "turns:turn.example:443", secret: "k")
        let server = try #require(relay.iceServers(now: now, ttlSeconds: 7_200).first)
        let expiry = try #require(server.username?.split(separator: ":").first.flatMap { Int($0) })
        #expect(expiry == 1_007_200)
    }

    /// A credential that has already expired is worse than none: it fails at connection time rather
    /// than at setup, so a too-small TTL is floored rather than honoured.
    @Test func aUselesslyShortTTLIsFloored() throws {
        let now = Date(timeIntervalSince1970: 500_000)
        let relay = OPNRemoteCoOpSharedSecretRelay(urlText: "turns:turn.example:443", secret: "k")
        let server = try #require(relay.iceServers(now: now, ttlSeconds: 0).first)
        let expiry = try #require(server.username?.split(separator: ":").first.flatMap { Int($0) })
        #expect(expiry >= 500_060)
    }

    @Test func sharedSecretDefaultsItsUsername() throws {
        #expect(OPNRemoteCoOpSharedSecretRelay(urls: [], secret: "k", username: "   ").username == "opennow")
        #expect(OPNRemoteCoOpSharedSecretRelay(urls: [], secret: "k", username: "player").username == "player")
    }

    @Test func sharedSecretNeedsBothPartsAndProducesNothingOtherwise() throws {
        #expect(!OPNRemoteCoOpSharedSecretRelay(urlText: "turns:a:443", secret: "").isUsable)
        #expect(OPNRemoteCoOpSharedSecretRelay(urlText: "turns:a:443", secret: "").iceServers().isEmpty)
        #expect(!OPNRemoteCoOpSharedSecretRelay(urlText: "", secret: "k").isUsable)
    }

    // MARK: - Dispatch

    private func credentials(_ provider: OPNRemoteCoOpRelayProvider) -> OPNRemoteCoOpRelayCredentials {
        OPNRemoteCoOpRelayCredentials(
            provider: provider,
            turnKey: OPNRemoteCoOpTURNKey(keyID: "k", keyToken: "t"),
            account: OPNRemoteCoOpCloudflareAccount(accountID: "a", apiToken: "t"),
            staticRelay: OPNRemoteCoOpStaticRelay(urlText: "turns:a.example:443", username: "u", password: "p"),
            sharedSecretRelay: OPNRemoteCoOpSharedSecretRelay(urlText: "turns:b.example:443", secret: "s")
        )
    }

    @Test func eachProviderReportsWhetherItCanRelay() throws {
        #expect(!credentials(.none).canRelay)
        #expect(credentials(.cloudflare).canRelay)
        #expect(credentials(.staticCredentials).canRelay)
        #expect(credentials(.sharedSecret).canRelay)
    }

    /// Only Cloudflare has an API to ask. Reporting usage for the others would either invent a number
    /// or read someone else's.
    @Test func onlyCloudflareReportsUsage() throws {
        #expect(credentials(.cloudflare).canReportUsage)
        #expect(!credentials(.staticCredentials).canReportUsage)
        #expect(!credentials(.sharedSecret).canReportUsage)
        #expect(!credentials(.none).canReportUsage)
    }

    /// The two local providers resolve without a network call at all, which is most of their appeal:
    /// no API token, and nothing to fail at invite time.
    @Test func localProvidersResolveWithoutANetworkCall() async throws {
        let staticServers = await credentials(.staticCredentials).iceServers()
        #expect(staticServers.first?.credential == "p")

        let secretServers = await credentials(.sharedSecret).iceServers()
        #expect(secretServers.first?.urls == ["turns:b.example:443"])
        #expect(secretServers.first?.username?.contains(":") == true)

        #expect(await credentials(.none).iceServers().isEmpty)
    }

    /// Labels name a provider a host will recognise, not the credential scheme underneath - the
    /// mechanism names told nobody which option to pick. The generic schemes are not tied to the
    /// provider they are named after, so the summaries have to name the others.
    @Test func providerLabelsNameAProviderAndSummariesNameTheRest() throws {
        #expect(OPNRemoteCoOpRelayProvider.staticCredentials.label == "ExpressTURN")
        #expect(OPNRemoteCoOpRelayProvider.sharedSecret.label == "coturn")
        #expect(OPNRemoteCoOpRelayProvider.staticCredentials.summary.contains("Metered"))
        #expect(OPNRemoteCoOpRelayProvider.staticCredentials.summary.contains("Xirsys"))
        #expect(OPNRemoteCoOpRelayProvider.pickerFootnote.contains("Metered"))
        for provider in OPNRemoteCoOpRelayProvider.allCases {
            #expect(!provider.label.isEmpty)
            #expect(!provider.summary.isEmpty)
        }
    }

    /// Renaming a label must not resettle a host's stored choice, which is keyed on the raw value.
    @Test func storedProviderIdentifiersAreStable() throws {
        #expect(OPNRemoteCoOpRelayProvider.cloudflare.rawValue == "cloudflare")
        #expect(OPNRemoteCoOpRelayProvider.staticCredentials.rawValue == "staticCredentials")
        #expect(OPNRemoteCoOpRelayProvider.sharedSecret.rawValue == "sharedSecret")
        #expect(OPNRemoteCoOpRelayProvider.none.rawValue == "none")
    }

    // MARK: - Probe reporting

    /// The probe reports "no allocation" rather than an error, because that is the common outcome for
    /// wrong credentials: the server simply never answers with a relay candidate.
    @Test func aProbeThatAllocatesNothingReadsAsAFailure() throws {
        let result = OPNRemoteCoOpRelayProbeResult(relayCandidates: 0, workingURLs: [], attemptedURLs: ["turn:a.example:3478"], firstCandidateElapsed: 0, elapsed: 1.2, failure: nil)
        #expect(!result.succeeded)
        #expect(result.summary.contains("No relay candidate"))
        #expect(result.summary.contains("username and password"))
    }

    /// A relay that allocates only over turn: is a half-working relay: it serves everyone except the
    /// guest on a filtering network, who is the reason the relay exists. That has to be called out
    /// rather than reported as a pass.
    @Test func aProbeWithoutATLSCandidateWarnsRatherThanPasses() throws {
        let result = OPNRemoteCoOpRelayProbeResult(
            relayCandidates: 2,
            workingURLs: ["turn:relay.example:3478"],
            attemptedURLs: ["turn:relay.example:3478"],
            firstCandidateElapsed: 0.2,
            elapsed: 0.4,
            failure: nil
        )
        #expect(result.succeeded)
        #expect(!result.hasTLSCandidate)
        #expect(result.reach == .udpOnly)
        #expect(result.summary.contains("UDP only"))
    }

    @Test func aProbeWithATLSCandidateSaysSo() throws {
        let result = OPNRemoteCoOpRelayProbeResult(
            relayCandidates: 3,
            workingURLs: ["turn:relay.example:3478", "turns:relay.example:443"],
            attemptedURLs: ["turn:relay.example:3478", "turns:relay.example:443"],
            firstCandidateElapsed: 0.3,
            elapsed: 0.5,
            failure: nil
        )
        #expect(result.hasTLSCandidate)
        #expect(result.summary.contains("turns:"))
        #expect(result.summary.contains("3 candidates"))
        #expect(result.reach == .tls)
    }

    @Test func aProbeFailureIsReportedVerbatim() throws {
        let result = OPNRemoteCoOpRelayProbeResult(relayCandidates: 0, workingURLs: [], attemptedURLs: [], firstCandidateElapsed: 0, elapsed: 0, failure: "No relay is configured.")
        #expect(result.summary == "No relay is configured.")
        #expect(!result.succeeded)
    }

    @Test func aSingleCandidateIsNotPluralised() throws {
        let result = OPNRemoteCoOpRelayProbeResult(relayCandidates: 1, workingURLs: ["turns:a:443"], attemptedURLs: ["turns:a:443"], firstCandidateElapsed: 0.1, elapsed: 0.1, failure: nil)
        #expect(result.summary.contains("1 candidate,"))
    }

    /// A relay reachable only over UDP is the one that fails the guest this feature exists for, and a
    /// TCP one is not: those are different outcomes and must not share a warning.
    @Test func reachIsGradedByHowTheRelayIsReachedNotJustThatItIs() throws {
        func reach(_ urls: [String]) -> OPNRemoteCoOpRelayProbeResult.Reach {
            OPNRemoteCoOpRelayProbeResult(relayCandidates: 1, workingURLs: urls, attemptedURLs: urls, firstCandidateElapsed: 0.1, elapsed: 0.2, failure: nil).reach
        }
        #expect(reach(["turns:a.example:443?transport=tcp"]) == .tls)
        #expect(reach(["turn:a.example:443?transport=tcp"]) == .tcp)
        #expect(reach(["turn:a.example:3478"]) == .udpOnly)
        // TLS wins when several allocated: it is the one that survives the strictest network.
        #expect(reach(["turn:a.example:3478", "turns:a.example:443"]) == .tls)
    }

    /// A TCP relay is a working answer for a UDP-blocking network, so it must not be reported with
    /// the same warning as a UDP-only one.
    @Test func aTCPRelayIsNotWarnedAboutLikeAUDPOnlyOne() throws {
        let tcp = OPNRemoteCoOpRelayProbeResult(relayCandidates: 1, workingURLs: ["turn:a.example:443?transport=tcp"], attemptedURLs: ["turn:a.example:443?transport=tcp"], firstCandidateElapsed: 0.1, elapsed: 0.2, failure: nil)
        #expect(tcp.summary.contains("survives a network that blocks UDP"))
        #expect(!tcp.summary.contains("UDP only"))
    }

    /// Gathering stays open until every URL has been tried, so a dead entry can hold it for the whole
    /// timeout. Reporting that as the relay's latency describes the dead URL, not the working one.
    @Test func latencyReportedIsTimeToFirstCandidateNotEndOfGathering() throws {
        let result = OPNRemoteCoOpRelayProbeResult(
            relayCandidates: 1,
            workingURLs: ["turn:a.example:3478"],
            attemptedURLs: ["turn:a.example:3478"],
            firstCandidateElapsed: 0.31,
            elapsed: 10.1,
            failure: nil
        )
        #expect(result.summary.contains("310 ms"))
        #expect(!result.summary.contains("10100"))
    }

    /// "UDP only" has two opposite causes: no TCP URL was ever offered, or one was offered and
    /// refused. Naming the URLs that failed is the difference between "add a URL" and "that URL does
    /// not work", and the host cannot tell which from a count.
    @Test func aPartialAllocationNamesTheURLsThatFailed() throws {
        let result = OPNRemoteCoOpRelayProbeResult(
            relayCandidates: 1,
            workingURLs: ["turn:free.expressturn.com:3478"],
            attemptedURLs: ["turn:free.expressturn.com:3478", "turns:free.expressturn.com:443", "turn:free.expressturn.com:80?transport=tcp"],
            firstCandidateElapsed: 0.9,
            elapsed: 3.4,
            failure: nil
        )
        #expect(result.failedURLs.count == 2)
        #expect(result.summary.contains("1 of 3 URLs"))
        #expect(result.summary.contains("Did not allocate:"))
        #expect(result.summary.contains("turns:free.expressturn.com:443"))
    }

    /// When everything offered did allocate, "UDP only" means no TCP URL exists to try, so the advice
    /// is to add one rather than to look at what failed.
    @Test func udpOnlyWithNothingFailedAsksForATCPURL() throws {
        let result = OPNRemoteCoOpRelayProbeResult(
            relayCandidates: 1,
            workingURLs: ["turn:a.example:3478"],
            attemptedURLs: ["turn:a.example:3478"],
            firstCandidateElapsed: 0.2,
            elapsed: 0.3,
            failure: nil
        )
        #expect(result.failedURLs.isEmpty)
        #expect(result.summary.contains("Add a URL on port 443 or 80"))
        #expect(!result.summary.contains("Did not allocate"))
    }

    /// A total failure is nearly always credentials rather than URLs, so it says so rather than
    /// listing three URLs as if one of them were the problem.
    @Test func aTotalFailurePointsAtCredentialsFirst() throws {
        let result = OPNRemoteCoOpRelayProbeResult(
            relayCandidates: 0,
            workingURLs: [],
            attemptedURLs: ["turn:a.example:3478", "turns:a.example:443"],
            firstCandidateElapsed: 0,
            elapsed: 5,
            failure: nil
        )
        #expect(result.summary.contains("No relay candidate from 2 URLs"))
        #expect(result.summary.contains("username and password"))
    }

    /// Nothing configured must not reach the network at all - a probe with no servers is a
    /// misconfiguration to report, not a request to make.
    @Test func anEmptyServerListShortCircuits() async throws {
        let result = await OPNRemoteCoOpRelayProbe.run(iceServers: [], timeout: 1)
        #expect(!result.succeeded)
        #expect(result.failure == "No relay is configured.")
        #expect(result.elapsed == 0)
    }

    @Test func switchingProviderSwitchesWhichCredentialsAreUsed() async throws {
        let viaStatic = await credentials(.staticCredentials).iceServers()
        let viaSecret = await credentials(.sharedSecret).iceServers()
        #expect(viaStatic.first?.urls != viaSecret.first?.urls)
    }
}
