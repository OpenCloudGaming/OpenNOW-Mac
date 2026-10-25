import Foundation
import Testing
@testable import OpenNOW

@MainActor
@Suite struct StreamPreflightProviderRoutingTests {
    enum RegionSelection: CaseIterable, Sendable {
        case automaticUncached, automaticCachedElsewhere, explicit

        var selectedURL: String {
            switch self {
            case .automaticUncached, .automaticCachedElsewhere: ""
            case .explicit: "https://preflight-chosen.nvidiagrid.net/"
            }
        }

        var cachedRegions: [OPNStreamRegionOption] {
            switch self {
            case .automaticUncached: []
            case .automaticCachedElsewhere:
                [OPNStreamRegionOption(name: "Another provider's cached region", url: "https://preflight-stale.nvidiagrid.net/", latencyMs: 10)]
            case .explicit:
                [OPNStreamRegionOption(name: "Chosen region", url: selectedURL, latencyMs: 10)]
            }
        }
    }

    enum NetworkOutcome: CaseIterable, Sendable {
        case completed, provisioned, unavailable, malformed

        var isSessionAvailable: Bool { self == .completed || self == .provisioned }
    }

    @Test(arguments: RegionSelection.allCases, NetworkOutcome.allCases)
    func preflightKeepsEachOwnersRouteThroughFinalAllocation(_ region: RegionSelection, _ outcome: NetworkOutcome) async throws {
        try await networkTestIsolationLock.withLock { @MainActor @Sendable in
            SessionManagerURLProtocol.install(host: "*", paths: ["/v2/serverInfo", "/v2/nettestsession", "/v2/session"]) { request in
                Self.response(to: request, outcome: outcome)
            }
            defer { SessionManagerURLProtocol.uninstall(host: "*") }
            let storage = OPNAppPreferenceStorage.standard
            let activeSessionKey = OPNSessionManager.persistedActiveSessionIdKey
            let savedActiveSessionID = withExclusivePreferenceDomain { storage.string(forKey: activeSessionKey) }
            defer {
                withExclusivePreferenceDomain {
                    if let savedActiveSessionID { storage.set(savedActiveSessionID, forKey: activeSessionKey) }
                    if savedActiveSessionID == nil { storage.removeObject(forKey: activeSessionKey) }
                    storage.synchronize()
                }
            }

            for owner in ["a", "b"] {
                let providerURL = "https://preflight-provider-\(owner).nvidiagrid.net/"
                let configuration = StreamLaunchConfiguration(
                    title: "Owner \(owner)", applicationID: "123", accessToken: "owner-\(owner)-token",
                    accountLinked: true, selectedStore: "Steam",
                    metadata: [OPNLaunchEntitlements.providerMetadataKey: providerURL]
                )
                let providerSnapshot = try #require(configuration.metadata[OPNLaunchEntitlements.providerMetadataKey])
                let expectedURL = region.selectedURL.isEmpty ? providerURL : region.selectedURL
                let expectedHost = try #require(URL(string: expectedURL)?.host)
                let requestOffset = SessionManagerURLProtocol.recordedRequests(host: "*").count
                let preflight = await runPreflight(configuration: configuration, providerURL: providerSnapshot, region: region)
                #expect(preflight.streamingBaseUrl == expectedURL)
                #expect(preflight.networkTestSessionId == (outcome.isSessionAvailable ? "nettest-\(expectedHost)" : ""))
                #expect(preflight.serverReportedWarning == (outcome == .provisioned))
                if outcome == .completed { #expect(preflight.latencyMs == 12) }

                var settings = minimalSettings()
                settings["networkTestSessionId"] = preflight.networkTestSessionId
                let launch = PreparedStreamLaunch(settings: settings, streamingBaseUrl: preflight.streamingBaseUrl)
                let coordinator = OPNStreamSessionCoordinator(sessionManager: OPNSessionManager(), deviceId: "owner-\(owner)-device")
                let allocated = try await coordinator.allocateSession(configuration: configuration, launch: launch)
                #expect(allocated.isReady)
                try await waitForRegionRequest(after: requestOffset)
                let requests = Array(SessionManagerURLProtocol.recordedRequests(host: "*").dropFirst(requestOffset))
                let networkRequests = requests.filter { $0.url?.path == "/v2/nettestsession" }
                let allocationRequests = requests.filter { $0.url?.path == "/v2/session" }
                #expect(networkRequests.count == 1)
                #expect(allocationRequests.count == 1)
                #expect((networkRequests + allocationRequests).allSatisfy { $0.url?.host == expectedHost && $0.httpMethod == "POST" })
                #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "GFNJWT \(configuration.accessToken)" })
                #expect(requests.filter { $0.url?.path == "/v2/serverInfo" }.allSatisfy { $0.url?.absoluteString == providerURL + "v2/serverInfo" })
                let allocationPayloads = SessionManagerURLProtocol.recordedJSONBodies(host: "*").compactMap { $0["sessionRequestData"] as? [String: Any] }
                let payload = try #require(allocationPayloads.last)
                #expect(payload["deviceHashId"] as? String == "owner-\(owner)-device")
                #expect((payload["networkTestSessionId"] as? String ?? "") == preflight.networkTestSessionId)
                #expect(configuration.metadata[OPNLaunchEntitlements.providerMetadataKey] == providerSnapshot)
            }
            #expect(SessionManagerURLProtocol.strayRequestSummaries().isEmpty)
        }
    }

    private func runPreflight(configuration: StreamLaunchConfiguration, providerURL: String, region: RegionSelection) async -> OPNStreamNetworkPreflightResult {
        await withCheckedContinuation { continuation in
            withPreservedPreferences(["OpenNOW.Stream.RegionUrl", "OpenNOW.Stream.CachedRegions"]) {
                OPNStreamPreferences.saveSelectedRegionUrl(region.selectedURL)
                OPNStreamPreferences.saveCachedRegions(region.cachedRegions)
                OPNStreamPreferences.runNetworkPreflight(token: configuration.accessToken, providerStreamingBaseUrl: providerURL, requestedMaxBitrateMbps: 50) {
                    continuation.resume(returning: $0)
                }
            }
        }
    }

    private func waitForRegionRequest(after offset: Int) async throws {
        for _ in 0..<300 {
            let requests = SessionManagerURLProtocol.recordedRequests(host: "*").dropFirst(offset)
            if requests.contains(where: { $0.url?.path == "/v2/serverInfo" }) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The provider region refresh did not reach the scripted transport")
    }

    nonisolated private static func response(to request: URLRequest, outcome: NetworkOutcome) -> (Int, Data) {
        guard request.url?.path != "/v2/serverInfo" else {
            return SessionManagerURLProtocol.response(json: [:], status: 404)
        }
        guard request.url?.path != "/v2/session" else {
            return SessionManagerURLProtocol.response(json: sessionResponse(statusCode: 1, sessionStatus: 2))
        }
        guard outcome != .unavailable else { return SessionManagerURLProtocol.response(json: [:], status: 404) }
        guard outcome != .malformed else { return SessionManagerURLProtocol.response(json: [:]) }
        let host = request.url?.host ?? "missing-host"
        var response: [String: Any] = ["netTestSession": [
            "sessionId": "nettest-\(host)",
            "connectionInfo": [["ip": "measurement-endpoint.example.test", "port": 443, "appLevelProtocol": 5]],
        ]]
        if outcome == .completed {
            response["testResult"] = ["status": "COMPLETED", "latencyMs": 12, "maxPacketSize": 1400]
        }
        return SessionManagerURLProtocol.response(json: response)
    }
}
