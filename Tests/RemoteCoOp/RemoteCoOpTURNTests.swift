//
//  RemoteCoOpTURNTests.swift
//  OpenNOWTests
//
//  Cloudflare TURN credential minting, the quota readout, and the rule that a relay is added to the
//  ICE list rather than substituted for it.
//

import Foundation
import Testing
@testable import OpenNOW

@Suite(.serialized)
struct RemoteCoOpTURNTests {
    private static let mintHost = "rtc.live.cloudflare.com"
    private static let analyticsHost = "api.cloudflare.com"

    private let turnKey = OPNRemoteCoOpTURNKey(keyID: "key-1", keyToken: "turn-token")

    private func account(accountID: String = "acct-1") -> OPNRemoteCoOpCloudflareAccount {
        OPNRemoteCoOpCloudflareAccount(accountID: accountID, apiToken: "api-token")
    }

    // MARK: - Credential parsing

    @Test func parsesAnObjectShapedIceServersReply() throws {
        let data = Data("""
        {"iceServers":{"urls":["stun:stun.cloudflare.com:3478","turn:turn.cloudflare.com:3478?transport=udp","turns:turn.cloudflare.com:443?transport=tcp"],"username":"u","credential":"c"}}
        """.utf8)
        let servers = OPNRemoteCoOpTURNCredentials.parse(data)
        #expect(servers.count == 1)
        #expect(servers[0].urls.count == 3)
        #expect(servers[0].username == "u")
        #expect(servers[0].credential == "c")
        // The TCP-on-443 URL is the whole point of the relay: it is the one a filtering firewall lets
        // through, so a parse that quietly dropped it would leave the blocked guest still blocked.
        #expect(servers[0].urls.contains("turns:turn.cloudflare.com:443?transport=tcp"))
    }

    @Test func parsesASingleStringURL() throws {
        let data = Data(#"{"iceServers":{"urls":"turns:turn.cloudflare.com:443?transport=tcp","username":"u","credential":"c"}}"#.utf8)
        let servers = OPNRemoteCoOpTURNCredentials.parse(data)
        #expect(servers.count == 1)
        #expect(servers[0].urls == ["turns:turn.cloudflare.com:443?transport=tcp"])
    }

    /// Confirmed live against Cloudflare's real endpoint with a real key: this is the shape it
    /// actually returns, not the single-object shape every other fixture in this file assumes. The
    /// old decoder silently dropped every real reply to this shape, which read as "Cloudflare would
    /// not mint credentials" on Test Relay even though Set Up Relay had just reported success -
    /// because Set Up Relay never calls this endpoint at all.
    @Test func parsesAnArrayShapedIceServersReply() throws {
        let data = Data("""
        {"iceServers":[{"urls":["stun:stun.cloudflare.com:3478","stun:stun.cloudflare.com:53"]},{"urls":["turn:turn.cloudflare.com:3478?transport=udp","turns:turn.cloudflare.com:5349?transport=tcp"],"username":"u","credential":"c"}]}
        """.utf8)
        let servers = OPNRemoteCoOpTURNCredentials.parse(data)
        #expect(servers.count == 2)
        #expect(servers[0].username == nil)
        #expect(servers[0].credential == nil)
        #expect(servers[1].username == "u")
        #expect(servers[1].credential == "c")
        #expect(servers.flatMap(\.urls).contains("turns:turn.cloudflare.com:5349?transport=tcp"))
    }

    @Test func dropsURLSchemesAGuestCannotUse() throws {
        let data = Data(#"{"iceServers":{"urls":["https://example.com","turn:turn.cloudflare.com:3478"],"username":"u","credential":"c"}}"#.utf8)
        let servers = OPNRemoteCoOpTURNCredentials.parse(data)
        #expect(servers[0].urls == ["turn:turn.cloudflare.com:3478"])
    }

    @Test func yieldsNoServersRatherThanThrowingOnGarbage() throws {
        #expect(OPNRemoteCoOpTURNCredentials.parse(Data("not json".utf8)).isEmpty)
        #expect(OPNRemoteCoOpTURNCredentials.parse(Data(#"{"iceServers":{"urls":[],"username":"u"}}"#.utf8)).isEmpty)
    }

    // MARK: - Minting

    @Test func mintingSendsTheTokenAsBearerAndAsksForTheConfiguredTTL() async throws {
        SessionManagerURLProtocol.install(host: Self.mintHost) { _ in
            SessionManagerURLProtocol.response(json: [
                "iceServers": ["urls": ["turns:turn.cloudflare.com:443?transport=tcp"], "username": "u", "credential": "c"],
            ])
        }
        defer { SessionManagerURLProtocol.uninstall(host: Self.mintHost) }

        let servers = try await OPNRemoteCoOpTURNCredentials.iceServers(for: turnKey, ttlSeconds: 3_600)
        #expect(servers.count == 1)

        let request = try #require(SessionManagerURLProtocol.recordedRequests(host: Self.mintHost).first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer turn-token")
        #expect(request.url?.path == "/v1/turn/keys/key-1/credentials/generate-ice-servers")
        let body = try #require(SessionManagerURLProtocol.recordedJSONBodies(host: Self.mintHost).first)
        #expect(body["ttl"] as? Int == 3_600)
    }

    @Test func mintingRefusesWithoutAKey() async throws {
        await #expect(throws: OPNRemoteCoOpTURNError.notConfigured) {
            try await OPNRemoteCoOpTURNCredentials.iceServers(for: OPNRemoteCoOpTURNKey(keyID: "", keyToken: ""))
        }
    }

    @Test func mintingSurfacesTheHTTPStatus() async throws {
        SessionManagerURLProtocol.install(host: Self.mintHost) { _ in (403, Data()) }
        defer { SessionManagerURLProtocol.uninstall(host: Self.mintHost) }
        await #expect(throws: OPNRemoteCoOpTURNError.rejected(status: 403)) {
            try await OPNRemoteCoOpTURNCredentials.iceServers(for: turnKey)
        }
    }

    // MARK: - Usage

    @Test func sumsEveryGroupInTheAnalyticsReply() throws {
        let data = Data("""
        {"data":{"viewer":{"accounts":[{"callsTurnUsageAdaptiveGroups":[{"sum":{"egressBytes":1000}},{"sum":{"egressBytes":2500}}]}]}}}
        """.utf8)
        #expect(OPNRemoteCoOpTURNUsageReporter.totalEgressBytes(data) == 3_500)
    }

    /// GraphQL reports a missing permission in a 200 body, so the parse has to survive one.
    @Test func readsZeroFromAnErrorCarryingReply() throws {
        let data = Data(#"{"data":null,"errors":[{"message":"Account Analytics permission required"}]}"#.utf8)
        #expect(OPNRemoteCoOpTURNUsageReporter.totalEgressBytes(data) == 0)
        #expect(OPNRemoteCoOpTURNUsageReporter.totalEgressBytes(Data("nonsense".utf8)) == 0)
    }

    @Test func usageQueryScopesToTheAccountAndTheCalendarMonth() async throws {
        SessionManagerURLProtocol.install(host: Self.analyticsHost) { _ in
            SessionManagerURLProtocol.response(json: [
                "data": ["viewer": ["accounts": [["callsTurnUsageAdaptiveGroups": [["sum": ["egressBytes": 250_000_000_000]]]]]]],
            ])
        }
        defer { SessionManagerURLProtocol.uninstall(host: Self.analyticsHost) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 17)))

        let usage = try await OPNRemoteCoOpTURNUsageReporter.monthToDateEgress(for: account(), keyID: "key-1", now: now, calendar: calendar)
        #expect(usage.egressBytes == 250_000_000_000)

        let body = try #require(SessionManagerURLProtocol.recordedJSONBodies(host: Self.analyticsHost).first)
        let variables = try #require(body["variables"] as? [String: Any])
        #expect(variables["accountId"] as? String == "acct-1")
        #expect(variables["keyId"] as? String == "key-1")
        #expect(variables["dateFrom"] as? String == "2026-09-01")
        #expect(variables["dateTo"] as? String == "2026-09-17")
    }

    /// Minting works with only a TURN key; the usage query additionally needs the account tag, so it
    /// has to refuse rather than query with an empty filter and report someone else's zero.
    @Test func usageRefusesWithoutAnAccountID() async throws {
        await #expect(throws: OPNRemoteCoOpTURNError.notConfigured) {
            try await OPNRemoteCoOpTURNUsageReporter.monthToDateEgress(for: account(accountID: ""), keyID: "key-1")
        }
        let credentials = OPNRemoteCoOpRelayCredentials(turnKey: turnKey, account: account(accountID: ""))
        #expect(credentials.canRelay)
        #expect(!credentials.canReportUsage)
    }

    /// The two credentials are not interchangeable: minting uses the TURN key's own bearer token and
    /// analytics uses the account's API token. Sending the wrong one at either endpoint fails in a way
    /// that reads like a permission problem, so the split is worth pinning down.
    @Test func mintingAndAnalyticsUseDifferentTokens() async throws {
        SessionManagerURLProtocol.install(host: Self.mintHost) { _ in
            SessionManagerURLProtocol.response(json: [
                "iceServers": ["urls": ["turns:turn.cloudflare.com:443?transport=tcp"], "username": "u", "credential": "c"],
            ])
        }
        SessionManagerURLProtocol.install(host: Self.analyticsHost) { _ in
            SessionManagerURLProtocol.response(json: [
                "data": ["viewer": ["accounts": [["callsTurnUsageAdaptiveGroups": []]]]],
            ])
        }
        defer {
            SessionManagerURLProtocol.uninstall(host: Self.mintHost)
            SessionManagerURLProtocol.uninstall(host: Self.analyticsHost)
        }

        _ = try await OPNRemoteCoOpTURNCredentials.iceServers(for: turnKey)
        _ = try await OPNRemoteCoOpTURNUsageReporter.monthToDateEgress(for: account(), keyID: "key-1")

        let mint = try #require(SessionManagerURLProtocol.recordedRequests(host: Self.mintHost).first)
        let analytics = try #require(SessionManagerURLProtocol.recordedRequests(host: Self.analyticsHost).first)
        #expect(mint.value(forHTTPHeaderField: "Authorization") == "Bearer turn-token")
        #expect(analytics.value(forHTTPHeaderField: "Authorization") == "Bearer api-token")
    }

    /// GraphQL answers a missing permission with HTTP 200 and an `errors` array. Reading only the
    /// status would report that as zero bytes used, which is worse than saying nothing.
    @Test func usageSurfacesAPermissionErrorRatherThanReportingZero() async throws {
        SessionManagerURLProtocol.install(host: Self.analyticsHost) { _ in
            SessionManagerURLProtocol.response(json: [
                "data": NSNull(),
                "errors": [["message": "not entitled to Account Analytics"]],
            ])
        }
        defer { SessionManagerURLProtocol.uninstall(host: Self.analyticsHost) }
        await #expect(throws: OPNRemoteCoOpTURNError.cloudflare("Cloudflare refused the usage query: not entitled to Account Analytics")) {
            try await OPNRemoteCoOpTURNUsageReporter.monthToDateEgress(for: account(), keyID: "key-1")
        }
    }

    // MARK: - Provisioning

    private func installProvisioningStub(accounts: [[String: Any]], createStatus: Int = 200) {
        // Serialised up front: a `[[String: Any]]` is not `Sendable` and cannot cross into the handler.
        let accountsBody = (try? JSONSerialization.data(withJSONObject: ["success": true, "result": accounts])) ?? Data()
        SessionManagerURLProtocol.install(host: Self.analyticsHost) { request in
            if request.url?.path == "/client/v4/accounts" {
                return (200, accountsBody)
            }
            guard createStatus == 200 else {
                return SessionManagerURLProtocol.response(json: ["errors": [["message": "Cloudflare Calls permission required"]]], status: createStatus)
            }
            return SessionManagerURLProtocol.response(json: ["result": ["uid": "made-key", "key": "made-token"]])
        }
    }

    @Test func provisioningDerivesTheAccountAndCreatesAKey() async throws {
        installProvisioningStub(accounts: [["id": "acct-9", "name": "Personal"]])
        defer { SessionManagerURLProtocol.uninstall(host: Self.analyticsHost) }

        let credentials = try await OPNRemoteCoOpTURNProvisioner.provision(apiToken: "api-token")
        #expect(credentials.account.accountID == "acct-9")
        #expect(credentials.turnKey.keyID == "made-key")
        #expect(credentials.turnKey.keyToken == "made-token")
        #expect(credentials.canReportUsage)

        let create = try #require(SessionManagerURLProtocol.recordedRequests(host: Self.analyticsHost)
            .first { $0.url?.path.hasSuffix("/calls/turn_keys") == true })
        #expect(create.httpMethod == "POST")
        #expect(create.url?.path == "/client/v4/accounts/acct-9/calls/turn_keys")
    }

    /// Cloudflare returns a TURN key's bearer token once, at creation, and listing keys cannot recover
    /// it. Re-running setup therefore has to keep the stored key, or every run would strand another
    /// unusable key on the user's account.
    @Test func provisioningKeepsAnExistingKeyRatherThanCreatingAnother() async throws {
        installProvisioningStub(accounts: [["id": "acct-9", "name": "Personal"]])
        defer { SessionManagerURLProtocol.uninstall(host: Self.analyticsHost) }

        let credentials = try await OPNRemoteCoOpTURNProvisioner.provision(apiToken: "api-token", existingKey: turnKey)
        #expect(credentials.turnKey == turnKey)
        #expect(credentials.account.accountID == "acct-9")
        #expect(!SessionManagerURLProtocol.recordedRequests(host: Self.analyticsHost)
            .contains { $0.url?.path.hasSuffix("/calls/turn_keys") == true })
    }

    /// A pasted account ID short-circuits detection, which matters because listing accounts needs
    /// Account Settings (Read) - a permission the relay itself does not.
    @Test func provisioningTrustsAPastedAccountID() async throws {
        installProvisioningStub(accounts: [])
        defer { SessionManagerURLProtocol.uninstall(host: Self.analyticsHost) }

        let credentials = try await OPNRemoteCoOpTURNProvisioner.provision(apiToken: "api-token", accountID: "acct-manual")
        #expect(credentials.account.accountID == "acct-manual")
        #expect(!SessionManagerURLProtocol.recordedRequests(host: Self.analyticsHost)
            .contains { $0.url?.path == "/client/v4/accounts" })
    }

    @Test func provisioningNamesTheAccountsWhenTheTokenSeesSeveral() async throws {
        installProvisioningStub(accounts: [["id": "a", "name": "Work"], ["id": "b", "name": "Home"]])
        defer { SessionManagerURLProtocol.uninstall(host: Self.analyticsHost) }

        await #expect(throws: OPNRemoteCoOpTURNError.ambiguousAccount(["Work", "Home"])) {
            try await OPNRemoteCoOpTURNProvisioner.provision(apiToken: "api-token")
        }
    }

    /// A token without Account Settings (Read) gets HTTP 200 and an empty list from the user-scoped
    /// `/accounts`, and a scoped-token 403 means the same thing. Both have to name that permission and
    /// the dashboard URL rather than read as a bad token.
    @Test func provisioningTreatsAScopedTokenAsAMissingAccountID() async throws {
        SessionManagerURLProtocol.install(host: Self.analyticsHost) { _ in
            SessionManagerURLProtocol.response(json: ["errors": [["message": "Authentication error"]]], status: 403)
        }
        defer { SessionManagerURLProtocol.uninstall(host: Self.analyticsHost) }
        await #expect(throws: OPNRemoteCoOpTURNError.noAccounts) {
            try await OPNRemoteCoOpTURNProvisioner.provision(apiToken: "api-token")
        }
        let message = try #require(OPNRemoteCoOpTURNError.noAccounts.errorDescription)
        #expect(message.contains("Account Settings"))
        #expect(message.contains("dash.cloudflare.com"))
    }

    /// A 401 is the one case pasting an account ID cannot fix, so it keeps Cloudflare's own wording.
    @Test func provisioningReportsAnInvalidToken() async throws {
        SessionManagerURLProtocol.install(host: Self.analyticsHost) { _ in
            SessionManagerURLProtocol.response(json: ["errors": [["message": "Invalid API Token"]]], status: 401)
        }
        defer { SessionManagerURLProtocol.uninstall(host: Self.analyticsHost) }
        let error = await #expect(throws: OPNRemoteCoOpTURNError.self) {
            try await OPNRemoteCoOpTURNProvisioner.provision(apiToken: "api-token")
        }
        let message = try #require(error?.errorDescription)
        #expect(message.contains("listing accounts"))
        #expect(message.contains("Invalid API Token"))
    }

    @Test func provisioningReportsNoVisibleAccount() async throws {
        installProvisioningStub(accounts: [])
        defer { SessionManagerURLProtocol.uninstall(host: Self.analyticsHost) }

        await #expect(throws: OPNRemoteCoOpTURNError.noAccounts) {
            try await OPNRemoteCoOpTURNProvisioner.provision(apiToken: "api-token")
        }
    }

    /// Cloudflare's own message names the permission that is missing, which a status code does not.
    @Test func provisioningSurfacesCloudflaresMessage() async throws {
        installProvisioningStub(accounts: [["id": "acct-9", "name": "Personal"]], createStatus: 403)
        defer { SessionManagerURLProtocol.uninstall(host: Self.analyticsHost) }

        let error = await #expect(throws: OPNRemoteCoOpTURNError.self) {
            try await OPNRemoteCoOpTURNProvisioner.provision(apiToken: "api-token")
        }
        let message = try #require(error?.errorDescription)
        // Which of the three Cloudflare calls failed, not just that one did: "authorization failure"
        // on its own does not say whether the token, the permission or the account is at fault.
        #expect(message.contains("create a TURN key"))
        #expect(message.contains("Cloudflare Calls permission required"))
    }

    @Test func provisioningRefusesWithoutAToken() async throws {
        await #expect(throws: OPNRemoteCoOpTURNError.notConfigured) {
            try await OPNRemoteCoOpTURNProvisioner.provision(apiToken: "   ")
        }
    }

    /// A hand-pasted key has to work exactly like a provisioned one, because Cloudflare can refuse to
    /// create a key over the API for a token that carries Cloudflare Calls (Edit) - so provisioning
    /// cannot be the only way to end up with a usable relay.
    @Test func aHandEnteredKeyMintsTheSameWayAProvisionedOneDoes() async throws {
        SessionManagerURLProtocol.install(host: Self.mintHost) { _ in
            SessionManagerURLProtocol.response(json: [
                "iceServers": ["urls": ["turns:turn.cloudflare.com:443?transport=tcp"], "username": "u", "credential": "c"],
            ])
        }
        defer { SessionManagerURLProtocol.uninstall(host: Self.mintHost) }

        let pasted = OPNRemoteCoOpTURNKey(keyID: "  dashboard-key  ", keyToken: "  dashboard-token\n")
        #expect(pasted.keyID == "dashboard-key")
        #expect(pasted.isUsable)

        let servers = try await OPNRemoteCoOpTURNCredentials.iceServers(for: pasted)
        #expect(servers.count == 1)
        let request = try #require(SessionManagerURLProtocol.recordedRequests(host: Self.mintHost).first)
        #expect(request.url?.path == "/v1/turn/keys/dashboard-key/credentials/generate-ice-servers")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer dashboard-token")
    }

    /// A relay needs only the TURN key; the account half is for the usage readout. Requiring both
    /// would block the fallback path, since a host who pasted a dashboard key may never have had a
    /// working API token at all.
    @Test func aTURNKeyAloneIsEnoughToRelay() throws {
        let credentials = OPNRemoteCoOpRelayCredentials(
            turnKey: turnKey,
            account: OPNRemoteCoOpCloudflareAccount(accountID: "", apiToken: "")
        )
        #expect(credentials.canRelay)
        #expect(!credentials.canReportUsage)
    }

    // MARK: - Quota arithmetic

    @Test func quotaMathTracksTheFreeAllowance() throws {
        let usage = OPNRemoteCoOpTURNUsage(egressBytes: 250_000_000_000)
        #expect(abs(usage.usedGigabytes - 250) < 0.001)
        #expect(abs(usage.remainingGigabytes - 750) < 0.001)
        #expect(abs(usage.fractionUsed - 0.25) < 0.001)
        #expect(usage.summary.contains("250.0 of 1000 GB"))
    }

    /// Past the allowance the readout has to stay at "none left" rather than going negative, which
    /// would render as a negative hours-remaining estimate.
    @Test func quotaClampsOnceTheAllowanceIsSpent() throws {
        let usage = OPNRemoteCoOpTURNUsage(egressBytes: 1_400_000_000_000)
        #expect(usage.remainingGigabytes == 0)
        #expect(usage.fractionUsed == 1)
        #expect(usage.remainingHours(atPreset: .p1080f60) == 0)
    }

    @Test func remainingHoursFallWithABiggerPreset() throws {
        let usage = OPNRemoteCoOpTURNUsage(egressBytes: 0)
        let light = usage.remainingHours(atPreset: .p720f30)
        let heavy = usage.remainingHours(atPreset: .p2160f60)
        #expect(light > heavy)
        // 1,000 GB at the lightest preset should be a plausible number of hours, not a rounding
        // artefact: a wrong unit conversion here shows up as minutes or as months.
        #expect(light > 10 && light < 10_000)
    }

    // MARK: - Endpoint composition

    /// A relay is appended, never substituted. ICE prefers the lower-priority-cost candidate, so
    /// leaving STUN and the host candidates in place keeps a guest who *can* connect directly on the
    /// direct path, and only the guest who cannot pays the relay hop.
    @Test func relayAugmentationAppendsRatherThanReplaces() async throws {
        SessionManagerURLProtocol.install(host: Self.mintHost) { _ in
            SessionManagerURLProtocol.response(json: [
                "iceServers": ["urls": ["turns:turn.cloudflare.com:443?transport=tcp"], "username": "u", "credential": "c"],
            ])
        }
        defer { SessionManagerURLProtocol.uninstall(host: Self.mintHost) }

        let base = OPNRemoteCoOpNetworkConfiguration(transportMode: .automatic)
        let augmented = await OPNRemoteCoOpHostingEndpoint.relayAugmented(base, credentials: OPNRemoteCoOpRelayCredentials(turnKey: turnKey, account: account()))
        #expect(augmented.iceServers.count == base.iceServers.count + 1)
        #expect(augmented.iceServers.prefix(base.iceServers.count).map(\.urls) == base.iceServers.map(\.urls))
        #expect(augmented.iceServers.last?.credential == "c")
    }

    @Test func relayAugmentationLeavesTheConfigurationAloneWithoutAKey() async throws {
        let base = OPNRemoteCoOpNetworkConfiguration(transportMode: .automatic)
        let augmented = await OPNRemoteCoOpHostingEndpoint.relayAugmented(base, credentials: OPNRemoteCoOpRelayCredentials(turnKey: OPNRemoteCoOpTURNKey(keyID: "", keyToken: ""), account: account()))
        #expect(augmented.iceServers.map(\.urls) == base.iceServers.map(\.urls))
    }

    /// A relay that cannot be minted must not fail the invite: direct-only is a working session for
    /// most guests, where a thrown error is no session for anyone.
    @Test func relayAugmentationFallsBackToDirectWhenCloudflareRefuses() async throws {
        SessionManagerURLProtocol.install(host: Self.mintHost) { _ in (401, Data()) }
        defer { SessionManagerURLProtocol.uninstall(host: Self.mintHost) }

        let base = OPNRemoteCoOpNetworkConfiguration(transportMode: .automatic)
        let augmented = await OPNRemoteCoOpHostingEndpoint.relayAugmented(base, credentials: OPNRemoteCoOpRelayCredentials(turnKey: turnKey, account: account()))
        #expect(augmented.iceServers.map(\.urls) == base.iceServers.map(\.urls))
    }
}
