import Foundation
import Testing
@testable import OpenNOW

private final class CatalogRetryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0

    var count: Int { lock.withLock { attempts } }

    func next() -> Int {
        lock.withLock {
            attempts += 1
            return attempts
        }
    }
}

@MainActor
@Suite struct CatalogServiceIsolationTests {
    @Test func loadingAnotherCatalogKeepsEveryRequestOwnedByTheInitiatingAccount() async throws {
        try await networkTestIsolationLock.withLock { @MainActor @Sendable in
            let counter = CatalogRetryCounter()
            SessionManagerURLProtocol.install(host: "*", paths: ["/graphql", "/v2/serverInfo"]) { request in
                Self.catalogResponse(request, counter: counter)
            }
            defer { SessionManagerURLProtocol.uninstall(host: "*") }
            let first = makeCatalog(email: "catalog-a@example.test", userID: "user-a-\(UUID().uuidString)")
            let second = makeCatalog(email: "catalog-b@example.test", userID: "user-b-\(UUID().uuidString)")
            defer {
                first.session.purgeTokens()
                second.session.purgeTokens()
            }
            let firstService = try #require(first.gameService as? OPNGameService)
            let secondService = try #require(second.gameService as? OPNGameService)
            let firstBridge = try #require(first.launchBridge as? OPNGameLaunchBridge)
            #expect((firstBridge.gameService as? OPNGameService) === firstService)
            #expect(firstService !== secondService)
            #expect(firstService !== OPNGameService.shared)
            firstService.graphqlURL = "https://catalog-a.example.test/graphql"
            firstService.persistedGraphqlURL = firstService.graphqlURL
            firstService.providerStreamingBaseUrl = "https://provider-a.nvidiagrid.net/"
            secondService.providerStreamingBaseUrl = "https://provider-b.nvidiagrid.net/"
            first.configureCatalogService()
            let favoritesSucceeded = await withCheckedContinuation { continuation in
                firstService.fetchFavoriteGameObjects { success, _, _ in continuation.resume(returning: success) }
                second.configureCatalogService()
                first.selectGame(Self.game())
                first.toggleFavoriteSelectedGame()
                first.confirmSelectedVariantOwned()
            }
            #expect(favoritesSucceeded)
            try await waitUntil { first.errorMessage == "Ownership rejected for isolation test" && !first.isLoadingFavorites && counter.count == 3 }
            let requests = SessionManagerURLProtocol.recordedRequests(host: "*")
            let graphql = requests.filter { $0.url?.path == "/graphql" }
            #expect(graphql.count >= 4)
            #expect(graphql.allSatisfy { $0.url?.host == "catalog-a.example.test" })
            #expect(graphql.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "GFNJWT \(first.session.idToken)" })
            let queries = SessionManagerURLProtocol.recordedJSONBodies(host: "*").compactMap { $0["query"] as? String }
            #expect(queries.contains { $0.contains("AddFavoriteApp") })
            #expect(queries.contains { $0.contains("AddOwnedVariant") })
            #expect(requests.filter { $0.url?.path == "/v2/serverInfo" }.contains { $0.url?.host == "provider-a.nvidiagrid.net" })
            #expect(requests.filter { $0.url?.path == "/v2/serverInfo" }.contains { $0.url?.host == "provider-b.nvidiagrid.net" })
            #expect(firstService.providerStreamingBaseURL() == "https://provider-a.nvidiagrid.net/")
            #expect(secondService.providerStreamingBaseURL() == "https://provider-b.nvidiagrid.net/")
        }
    }

    @Test func coalescedProviderCompletionsConfigureEveryRequestingService() async throws {
        try await networkTestIsolationLock.withLock { @MainActor @Sendable in
            let providerID = "coalesced-\(UUID().uuidString)"
            SessionManagerURLProtocol.install(host: "pcs.geforcenow.com") { _ in
                Self.providerResponse(firstID: providerID, secondID: "unused")
            }
            defer { SessionManagerURLProtocol.uninstall(host: "pcs.geforcenow.com") }
            let first = OPNGameService()
            let second = OPNGameService()
            var outcomes: [Bool] = []
            first.fetchProviderInfo(idpId: providerID) { success, _, _, _ in outcomes.append(success) }
            second.fetchProviderInfo(idpId: providerID) { success, _, _, _ in outcomes.append(success) }
            try await waitUntil { outcomes.count == 2 }
            #expect(outcomes == [true, true])
            #expect(first.providerStreamingBaseURL() == "https://provider-a.nvidiagrid.net/")
            #expect(second.providerStreamingBaseURL() == first.providerStreamingBaseURL())
            #expect(SessionManagerURLProtocol.recordedRequests(host: "pcs.geforcenow.com").count == 1)
        }
    }

    @Test func aLateProviderCompletionCannotReplaceANewerProviderContext() async throws {
        try await networkTestIsolationLock.withLock { @MainActor @Sendable in
            let firstID = "provider-a-\(UUID().uuidString)"
            let secondID = "provider-b-\(UUID().uuidString)"
            SessionManagerURLProtocol.install(host: "pcs.geforcenow.com") { _ in
                Self.providerResponse(firstID: firstID, secondID: secondID)
            }
            defer { SessionManagerURLProtocol.uninstall(host: "pcs.geforcenow.com") }
            let changed = OPNGameService()
            let unchanged = OPNGameService()
            var outcomes: [Bool] = []
            changed.fetchProviderInfo(idpId: firstID) { success, _, _, _ in outcomes.append(success) }
            changed.fetchProviderInfo(idpId: secondID) { success, _, _, _ in outcomes.append(success) }
            unchanged.fetchProviderInfo(idpId: firstID) { success, _, _, _ in outcomes.append(success) }
            try await waitUntil { outcomes.count == 3 }
            #expect(outcomes.filter { !$0 }.count == 1)
            #expect(changed.providerStreamingBaseURL() == "https://provider-b.nvidiagrid.net/")
            #expect(unchanged.providerStreamingBaseURL() == "https://provider-a.nvidiagrid.net/")
            let cached = OPNGameService()
            cached.fetchProviderInfo(idpId: firstID) { success, _, _, _ in outcomes.append(success) }
            try await waitUntil { outcomes.count == 4 }
            #expect(outcomes.last == true)
            #expect(cached.providerStreamingBaseURL() == "https://provider-a.nvidiagrid.net/")
            #expect(SessionManagerURLProtocol.recordedRequests(host: "pcs.geforcenow.com").count == 2)
        }
    }

    @Test func launchPrefetchResolvesItsOwnProviderBeforeSendingAccountRequests() async throws {
        try await networkTestIsolationLock.withLock { @MainActor @Sendable in
            let providerID = "prefetch-\(UUID().uuidString)"
            SessionManagerURLProtocol.install(host: "*", paths: ["/v1/serviceUrls", "/v2/serverInfo", "/graphql"]) { request in
                if request.url?.path == "/v1/serviceUrls" {
                    return Self.providerResponse(firstID: "unused", secondID: providerID)
                }
                if request.url?.path == "/v2/serverInfo" {
                    return SessionManagerURLProtocol.response(json: ["requestStatus": ["serverId": "GFN-PC"]])
                }
                return SessionManagerURLProtocol.response(json: ["data": [
                    "panels": [],
                    "apps": ["items": [], "pageInfo": ["hasNextPage": false]],
                    "filterGroupDefinitions": [],
                    "sortOrderDefinitions": [["id": "a_to_z", "orderBy": "sortName:ASC", "label": "A-Z"]],
                ]])
            }
            defer { SessionManagerURLProtocol.uninstall(host: "*") }
            let prefetch = CatalogLaunchPrefetch()
            prefetch.gameService.graphqlURL = "https://prefetch.example.test/graphql"
            prefetch.gameService.persistedGraphqlURL = prefetch.gameService.graphqlURL
            let userID = "prefetch-user-\(UUID().uuidString)"
            var events: Set<String> = []
            prefetch.start(accountIdentifier: userID, accessToken: "prefetch-access", idToken: "prefetch-id", idpId: providerID)
            _ = prefetch.attach(accountIdentifier: userID) { event in
                switch event {
                case .panels(let kind, _), .panelsFailed(let kind, _): events.insert(kind.rawValue)
                case .games(let kind, _), .gamesFailed(let kind, _): events.insert(kind.rawValue)
                }
            }
            try await waitUntil { events.count == 4 }
            prefetch.recordLaunchResultsAdopted(accountIdentifier: userID)
            let requests = SessionManagerURLProtocol.recordedRequests(host: "*")
            let streamingRequests = requests.filter { $0.url?.path == "/v2/serverInfo" }
            #expect(!streamingRequests.isEmpty)
            #expect(streamingRequests.allSatisfy { $0.url?.host == "provider-b.nvidiagrid.net" })
            #expect(streamingRequests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "GFNJWT prefetch-id" })
            #expect(prefetch.gameService !== OPNGameService.shared)
        }
    }

    private func makeCatalog(email: String, userID: String) -> CatalogViewModel {
        let account = makeLoginAccountForTesting(email: email, userId: userID)
        let session = makeLoginSessionForTesting(accountEmail: email, userId: userID)
        return CatalogViewModel(account: account, session: session, onRefreshAuth: { false })
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(predicate(), "The scripted catalog response did not arrive")
    }

    nonisolated private static func catalogResponse(_ request: URLRequest, counter: CatalogRetryCounter) -> (Int, Data) {
        if request.url?.path == "/v2/serverInfo" {
            return SessionManagerURLProtocol.response(json: ["requestStatus": ["serverId": "GFN-PC"]])
        }
        let query = SessionManagerURLProtocol.bodyData(from: request).flatMap {
            (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
        }?["query"] as? String ?? ""
        if query.contains("AddOwnedVariant") {
            return SessionManagerURLProtocol.response(json: ["errors": [["message": "Ownership rejected for isolation test"]]])
        }
        if query.contains("AddFavoriteApp") {
            return SessionManagerURLProtocol.response(json: ["data": ["addFavoriteApp": ["app": ["id": "game-a"]]]])
        }
        if counter.next() == 1 {
            return SessionManagerURLProtocol.response(json: ["errors": [["message": "PersistedQueryNotFound", "extensions": ["code": "PERSISTED_QUERY_NOT_FOUND"]]]], status: 400)
        }
        return SessionManagerURLProtocol.response(json: ["data": ["panels": []]])
    }

    nonisolated private static func providerResponse(firstID: String, secondID: String) -> (Int, Data) {
        SessionManagerURLProtocol.response(json: ["gfnServiceInfo": ["gfnServiceEndpoints": [
            ["idpId": firstID, "loginProvider": "Provider A", "streamingServiceUrl": "https://provider-a.nvidiagrid.net/"],
            ["idpId": secondID, "loginProvider": "Provider B", "streamingServiceUrl": "https://provider-b.nvidiagrid.net/"],
        ]]])
    }

    private static func game() -> OPNCatalogGameObject {
        var game = OPNGameInfo()
        game.id = "game-a"
        game.title = "Account A Game"
        game.variants = [OPNGameVariant(id: "123", appStore: "STEAM")]
        return OPNCatalogGameObject(game: game)
    }
}
