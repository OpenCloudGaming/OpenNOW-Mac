import Testing
import Foundation
@testable import OpenNOW

@Test func launchAppIdRejectsZeroAndInvalidValues() {
    #expect(OPNLaunchAppId.resolve("0") == nil)
    #expect(OPNLaunchAppId.resolve(" 0 ") == nil)
    #expect(OPNLaunchAppId.resolve("") == nil)
    #expect(OPNLaunchAppId.resolve("GFN-PC") == nil)
    #expect(OPNLaunchAppId.resolve("123")?.stringValue == "123")
    #expect(OPNLaunchAppId.resolve("123")?.intValue == 123)
}

@Test func catalogLocaleUsesUSForEnglishRegionalVariants() {
    #expect(OPNLocale.gfnCatalogLocale(for: "en_CA") == "en_US")
    #expect(OPNLocale.gfnCatalogLocale(for: "en-GB") == "en_US")
    #expect(OPNLocale.gfnCatalogLocale(for: "fr_CA") == "fr_CA")
    #expect(OPNLocale.gfnCatalogLocale(for: "") == "en_US")
}

@Test func providerInfoParsesAndSelectsDigevoEndpoint() {
    let digevoIdpId = "IsvVBA3Aj8KZ7gwwuRUhB6-tOF2o2F1wncD-XjYv100"
    let providerInfo = OPNGameServiceSwiftAdapter.parseProviderInfo(from: [
        "gfnServiceInfo": [
            "defaultProvider": "NVIDIA",
            "loggedInProvider": "NVIDIA",
            "loginRequired": false,
            "loginPreferredProviders": ["NVIDIA"],
            "gfnServiceEndpoints": [
                [
                    "loginProviderDisplayName": "NVIDIA",
                    "streamingServiceUrl": "https://prod.cloudmatchbeta.nvidiagrid.net/",
                    "idpId": "PDiAhv2kJTFeQ7WOPqiQ2tRZ7lGhR2X11dXvM4TZSxg",
                    "redeemRedirectUrl": "https://www.nvidia.com/content/drivers/redirect.asp?page=gfn_pc_redeem_activation_code",
                    "loginProvider": "NVIDIA",
                    "loginProviderCode": "NVIDIA",
                    "loginProviderPriority": 1,
                ],
                [
                    "loginProviderDisplayName": "Digevo",
                    "streamingServiceUrl": "https://prod.DIG.geforcenow.nvidiagrid.net",
                    "idpId": digevoIdpId,
                    "redeemRedirectUrl": "",
                    "loginProvider": "Digevo",
                    "loginProviderCode": "DIG",
                    "loginProviderPriority": 10,
                ],
            ],
        ],
    ])
    let selected = OPNGameServiceSwiftAdapter.selectProviderEndpoint(from: providerInfo, idpId: digevoIdpId)

    #expect(providerInfo.endpoints.count == 2)
    #expect(selected.loginProviderDisplayName == "Digevo")
    #expect(selected.loginProvider == "Digevo")
    #expect(selected.loginProviderCode == "DIG")
    #expect(selected.idpId == digevoIdpId)
    #expect(selected.streamingServiceUrl == "https://prod.DIG.geforcenow.nvidiagrid.net/")
}

@Test func streamCoordinatorRejectsZeroApplicationIdBeforeNetworkWork() async {
    let coordinator = OpenNOWStreamSessionCoordinator()
    let configuration = StreamLaunchConfiguration(
        title: "Invalid Launch",
        applicationID: "0",
        accessToken: "token",
        accountLinked: true,
        selectedStore: "Steam"
    )

    do {
        _ = try await coordinator.startSession(configuration: configuration)
        Issue.record("Expected coordinator to reject appId 0 before session allocation")
    } catch let error as OpenNOWStreamSessionError {
        #expect(error.errorDescription == "This game does not include a launchable GeForce NOW app id.")
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}

@Test func streamCoordinatorFinishSessionReportsUDSEndOfSession() async throws {
    try await networkTestIsolationLock.withLock {
        let host = "*"
        SessionManagerURLProtocol.install(host: host) { request in
            if request.url?.host == "uds.geforcenow.com" {
                #expect(request.url?.path == "/v1/uds/session/reports")
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
                #expect(request.value(forHTTPHeaderField: "NV-Device-ID")?.isEmpty == false)
                return SessionManagerURLProtocol.response(json: ["reports": []])
            }
            #expect(request.url?.path == "/v2/session/session-report")
            #expect(request.httpMethod == "DELETE")
            return SessionManagerURLProtocol.response(json: [:])
        }
        defer { SessionManagerURLProtocol.uninstall(host: host) }

        let coordinator = OpenNOWStreamSessionCoordinator()
        let session = StreamSessionDescriptor(
            id: "session-report",
            applicationID: "123",
            serverAddress: "stop.example.test",
            title: "Report Game",
            metadata: ["accessToken": "token", "startedAtEpochSeconds": String(Date().timeIntervalSince1970 - 10)]
        )

        try await coordinator.finishSession(session, reason: .completed)

        let requests = SessionManagerURLProtocol.recordedRequests(host: host)
        let udsRequest = try #require(requests.first { $0.url?.host == "uds.geforcenow.com" })
        let body = try #require(SessionManagerURLProtocol.bodyData(from: udsRequest))
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["source"] as? String == "EndOfSession")
        #expect(json["sessionId"] as? String == "session-report")
        #expect((json["sessionDurationInSeconds"] as? Int ?? -1) >= 0)
    }
}

@Test func streamCoordinatorFinishSessionIgnoresUDSFailure() async throws {
    try await networkTestIsolationLock.withLock {
        let host = "*"
        SessionManagerURLProtocol.install(host: host) { request in
            if request.url?.host == "uds.geforcenow.com" {
                return SessionManagerURLProtocol.response(json: ["error": "auth"], status: 401)
            }
            return SessionManagerURLProtocol.response(json: [:])
        }
        defer { SessionManagerURLProtocol.uninstall(host: host) }

        let coordinator = OpenNOWStreamSessionCoordinator()
        let session = StreamSessionDescriptor(id: "session-report", applicationID: "123", serverAddress: "stop.example.test", title: "Report Game", metadata: ["accessToken": "token"])

        try await coordinator.finishSession(session, reason: .userRequested)
        #expect(SessionManagerURLProtocol.recordedRequests(host: host).contains { $0.url?.host == "uds.geforcenow.com" })
    }
}

@Test func streamCoordinatorFinishSessionSkipsUDSWithoutAccessToken() async throws {
    try await networkTestIsolationLock.withLock {
        let host = "*"
        SessionManagerURLProtocol.install(host: host) { _ in
            SessionManagerURLProtocol.response(json: [:])
        }
        defer { SessionManagerURLProtocol.uninstall(host: host) }

        let coordinator = OpenNOWStreamSessionCoordinator()
        let session = StreamSessionDescriptor(id: "session-report", applicationID: "123", serverAddress: "stop.example.test", title: "Report Game")

        try await coordinator.finishSession(session, reason: .completed)
        #expect(!SessionManagerURLProtocol.recordedRequests(host: host).contains { $0.url?.host == "uds.geforcenow.com" })
    }
}

@Test func sessionManagerRejectsZeroBeforeTokenValidation() async {
    let result = await withCheckedContinuation { continuation in
        OPNSessionManager.shared.createSession(appId: "0", internalTitle: "Invalid Launch", settings: [:]) { success, _, error in
            continuation.resume(returning: (success, error))
        }
    }

    #expect(result.0 == false)
    #expect(result.1 == "This game does not include a launchable GeForce NOW app id.")
}

@Test func sessionManagerRejectsZeroClaimBeforeTokenValidation() async {
    let result = await withCheckedContinuation { continuation in
        OPNSessionManager.shared.claimSession(sessionId: "session", serverIp: "server", appId: "0", settings: [:], recoveryMode: false) { success, _, error in
            continuation.resume(returning: (success, error))
        }
    }

    #expect(result.0 == false)
    #expect(result.1 == "This game does not include a launchable GeForce NOW app id.")
}

@Test func gameLaunchBridgePrefersIdTokenForCloudMatchLaunch() async throws {
    try await networkTestIsolationLock.withLock {
    let host = "*"
    SessionManagerURLProtocol.install(host: host) { request in
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/v2/session")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "GFNJWT id-token")
        return SessionManagerURLProtocol.response(json: [
            "requestStatus": [
                "statusCode": 1,
                "statusDescription": "SUCCESS",
            ],
            "sessions": [],
        ])
    }
    defer { SessionManagerURLProtocol.uninstall(host: host) }

    let result: (Bool, String, OPNGameLaunchPlan?) = await withCheckedContinuation { continuation in
        Task { @MainActor in
            let game = OPNCatalogGameObject()
            game.launchAppId = "123"
            game.title = "Regression Game"
            game.isInLibrary = true
            OPNGameLaunchBridge.shared.prepareLaunchPlan(game: game, accessToken: "access-token", idToken: "id-token", userId: "user", idpId: "idp", variantIndex: -1) { success, message, plan in
                continuation.resume(returning: (success, message, plan))
            }
        }
    }

    let request = try #require(SessionManagerURLProtocol.recordedRequests(host: host).first)
    let plan = try #require(result.2)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "GFNJWT id-token")
    #expect(result.0 == true)
    #expect(result.1 == "Launching Regression Game...")
    if case let .ready(configuration) = plan {
        #expect(configuration.apiToken == "id-token")
        #expect(configuration.appId == "123")
        #expect(configuration.metadata["userId"] == "user")
        #expect(configuration.metadata["idpId"] == "idp")
    } else {
        Issue.record("Expected a ready launch plan")
    }
    }
}

@Test func gameLaunchBridgePromptsBeforeReusingMatchingActiveSession() async throws {
    try await networkTestIsolationLock.withLock {
    let host = "*"
    SessionManagerURLProtocol.install(host: host) { request in
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/v2/session")
        return SessionManagerURLProtocol.response(json: [
            "requestStatus": [
                "statusCode": 1,
                "statusDescription": "SUCCESS",
            ],
            "sessions": [[
                "sessionId": "active-session",
                "status": 2,
                "sessionRequestData": ["appId": 123],
                "sessionControlInfo": ["ip": "control.example.test"],
                "connectionInfo": [[
                    "usage": 14,
                    "ip": "signaling.example.test",
                    "port": 443,
                    "resourcePath": "/nvst/",
                ]],
            ]],
        ])
    }
    defer { SessionManagerURLProtocol.uninstall(host: host) }

    let result: (Bool, String, OPNGameLaunchPlan?) = await withCheckedContinuation { continuation in
        Task { @MainActor in
            let game = OPNCatalogGameObject()
            game.launchAppId = "123"
            game.title = "Regression Game"
            game.isInLibrary = true
            OPNGameLaunchBridge.shared.prepareLaunchPlan(game: game, accessToken: "access-token", idToken: "id-token", userId: "user", idpId: "idp", variantIndex: -1) { success, message, plan in
                continuation.resume(returning: (success, message, plan))
            }
        }
    }

    let plan = try #require(result.2)
    #expect(result.0 == true)
    #expect(result.1 == "A GeForce NOW session is already active for Regression Game.")
    if case let .activeSession(active, resume, replacement) = plan {
        #expect(active.id == "active-session")
        #expect(active.appId == 123)
        #expect(active.title == "Regression Game")
        #expect(resume.resumeSessionId == "active-session")
        #expect(resume.resumeServer == "control.example.test")
        #expect(replacement.resumeSessionId.isEmpty)
        #expect(replacement.appId == "123")
    } else {
        Issue.record("Expected an active session plan")
    }
    }
}

@Test @MainActor func gameLaunchBridgeBlocksPatchingGamesBeforeNetworkWork() async throws {
    let game = OPNCatalogGameObject()
    game.launchAppId = "123"
    game.title = "Patching Game"
    game.isPatching = true

    let result: (Bool, String, OPNGameLaunchPlan?) = await withCheckedContinuation { continuation in
        OPNGameLaunchBridge.shared.prepareLaunchPlan(game: game, accessToken: "access-token", idToken: "id-token", userId: "user", variantIndex: -1) { success, message, plan in
            continuation.resume(returning: (success, message, plan))
        }
    }

    #expect(result.0 == false)
    #expect(result.1 == "GeForce NOW is patching this game. Try again after patching finishes.")
    #expect(result.2 == nil)
}

@Test func catalogGameObjectPreservesPatchingStateRoundTrip() {
    var game = OPNGameInfo()
    game.id = "game-id"
    game.launchAppId = "123"
    game.isPatching = true
    game.variants = [OPNGameVariant(id: "123", appStore: "STEAM", serviceStatus: "APP_PATCHING_STATUS", isPatching: true)]

    let object = OPNCatalogGameObject(game: game)
    let roundTrip = object.swiftValue

    #expect(object.isPatching == true)
    #expect(object.variants.first?.isPatching == true)
    #expect(roundTrip.isPatching == true)
    #expect(roundTrip.variants.first?.isPatching == true)
}

@Test func catalogBrowsePreservesVendorVariantMetadata() async {
        await networkTestIsolationLock.withLock {
        let host = "*"
        let token = "catalog-vendor-metadata-token-\(UUID().uuidString)"
        _ = OPNGameDataCache.shared.clearAllCaches()
        OPNGameServiceSwiftAdapter.setAccessToken(token)
        OPNGameServiceSwiftAdapter.setUserId("catalog-vendor-metadata-user")
        SessionManagerURLProtocol.install(host: host) { request in
            if request.url?.host == "prod.cloudmatchbeta.nvidiagrid.net" {
                return SessionManagerURLProtocol.response(json: ["requestStatus": ["serverId": "GFN-PC"]])
            }
            let body = SessionManagerURLProtocol.bodyData(from: request).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
            let query = body["query"] as? String ?? ""
            let variables = body["variables"] as? [String: Any] ?? [:]
            if query.contains("filterGroupDefinitions") {
                return SessionManagerURLProtocol.response(json: ["data": ["filterGroupDefinitions": [], "sortOrderDefinitions": [["id": "a_to_z", "label": "A-Z", "orderBy": "sortName:ASC"]]]])
            }
            if query.contains("campaigns") || query.contains("ratingDefinitions") {
                return SessionManagerURLProtocol.response(json: ["data": [:]])
            }
            if variables["appIds"] != nil {
                return SessionManagerURLProtocol.response(json: ["data": ["apps": ["items": [catalogGraphQLGame(id: "vendor-game", libraryStatus: "PLATFORM_SYNC", librarySelected: true, variantId: "123456")]]]])
            }
            return SessionManagerURLProtocol.response(json: ["data": ["apps": [
                "numberReturned": 1,
                "numberSupported": 1,
                "pageInfo": ["hasNextPage": false, "endCursor": "", "totalCount": 1],
                "items": [catalogGraphQLGame(id: "vendor-game", libraryStatus: "PLATFORM_SYNC", librarySelected: true, variantId: "123456")],
            ]]])
        }
        defer { SessionManagerURLProtocol.uninstall(host: host) }

        let result = await withCheckedContinuation { continuation in
            OPNGameServiceSwiftAdapter.browseCatalogObject(searchQuery: "", sortId: "", filterIds: [], fetchCount: 24, forceRefresh: true) { success, browseResult, error in
                continuation.resume(returning: (success, browseResult.games.first?.swiftValue, error))
            }
        }

        let game = result.1
        #expect(result.0 == true)
        #expect(result.2.isEmpty)
        #expect(game?.displaysOwnRatingDuringGameplay == true)
        #expect(game?.supportedControls == ["KEYBOARD_MOUSE"])
        #expect(game?.ratingCategoryKey == "TEEN")
        let variant = game?.variants.first
        #expect(variant?.shortName == "vendor-short")
        #expect(variant?.supportedControls == ["GAMEPAD"])
        #expect(variant?.libraryStatus == "PLATFORM_SYNC")
        #expect(variant?.libraryPlayStatus == "PLAYABLE")
        #expect(variant?.libraryInstalled == true)
        #expect(variant?.librarySubscription == "GFN_PREMIUM")
        #expect(variant?.subscriptionIds == ["sub-ultimate"])
        #expect(variant?.paymentModelTypes == ["IncludedWithSubscription"])
        #expect(variant?.minimumSizeInBytes == 42_000_000)
        #expect(variant?.cloudSaveSupported == true)
        #expect(variant?.installTimeInMinutes == 7)
        #expect(variant?.supportedLanguages == ["en_US"])
        #expect(variant?.gfnFeatureLabels.contains("Ray Tracing") == true)
    }
}

@Test func panelSectionPreservesSeeMoreCatalogParameters() async {
        await networkTestIsolationLock.withLock {
        let host = "*"
        let token = "panel-see-more-token-\(UUID().uuidString)"
        _ = OPNGameDataCache.shared.clearAllCaches()
        OPNGameServiceSwiftAdapter.setAccessToken(token)
        OPNGameServiceSwiftAdapter.setUserId("panel-see-more-user")
        SessionManagerURLProtocol.install(host: host) { request in
            if request.url?.host == "prod.cloudmatchbeta.nvidiagrid.net" {
                return SessionManagerURLProtocol.response(json: ["requestStatus": ["serverId": "GFN-PC"]])
            }
            let absoluteURL = request.url?.absoluteString ?? ""
            if absoluteURL.contains("requestType=panels/MainV2") {
                #expect(absoluteURL.contains("46ec15f267a056e7d5e46e629efa929529e5e7542a4850faece90b9f8fa5f810"))
            }
            let body = SessionManagerURLProtocol.bodyData(from: request).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
            let variables = body["variables"] as? [String: Any] ?? [:]
            if variables["appIds"] != nil {
                return SessionManagerURLProtocol.response(json: ["data": ["apps": ["items": []]]])
            }
            return SessionManagerURLProtocol.response(json: ["data": ["panels": [[
                "id": "main-panel",
                "name": "MAIN",
                "sections": [[
                    "id": "featured-section",
                    "title": "Featured",
                    "seeMoreInfo": ["filterIds": ["genre-action", "store-steam"], "sortOrderId": "release_date", "title": "Show all featured"],
                    "items": [["__typename": "GameItem", "app": catalogGraphQLGame(id: "panel-game")]],
                ]],
            ]]]])
        }
        defer { SessionManagerURLProtocol.uninstall(host: host) }

        let result = await withCheckedContinuation { continuation in
            OPNGameServiceSwiftAdapter.fetchMainPanelObjects { success, panels, error in
                let section = panels.first?.sections.first
                continuation.resume(returning: (success, section?.seeMoreFilterIds ?? [], section?.seeMoreSortId ?? "", section?.seeMoreTitle ?? "", error))
            }
        }

        #expect(result.0 == true)
        #expect(result.4.isEmpty)
        #expect(result.1 == ["genre-action", "store-steam"])
        #expect(result.2 == "release_date")
        #expect(result.3 == "Show all featured")
    }
}

@Test func vendorRemoveMutationsTreatNotFoundAsSuccess() async {
        await networkTestIsolationLock.withLock {
        let host = "*"
        OPNGameServiceSwiftAdapter.setAccessToken("remove-mutation-404-token-\(UUID().uuidString)")
        OPNGameServiceSwiftAdapter.setUserId("remove-mutation-404-user")
        SessionManagerURLProtocol.install(host: host) { request in
            #expect(request.url?.host == "games.geforce.com")
            #expect(request.httpMethod == "POST")
            return SessionManagerURLProtocol.response(json: ["errors": [["message": "not found"]]], status: 404)
        }
        defer { SessionManagerURLProtocol.uninstall(host: host) }

        let favoriteResult: (Bool, String) = await withCheckedContinuation { continuation in
            OPNGameServiceSwiftAdapter.removeFavoriteApp("favorite-game-id") { success, error in
                continuation.resume(returning: (success, error))
            }
        }
        let ownedResult: (Bool, String) = await withCheckedContinuation { continuation in
            OPNGameServiceSwiftAdapter.removeOwnedVariant("123456") { success, error in
                continuation.resume(returning: (success, error))
            }
        }

        #expect(favoriteResult.0 == true)
        #expect(favoriteResult.1.isEmpty)
        #expect(ownedResult.0 == true)
        #expect(ownedResult.1.isEmpty)
        let queries = SessionManagerURLProtocol.recordedJSONBodies(host: host).compactMap { $0["query"] as? String }
        #expect(queries.contains { $0.contains("RemoveFavoriteApp") })
        #expect(queries.contains { $0.contains("RemoveOwnedVariant") })
    }
}

@Test func catalogBrowseContinuesAfterFortyItemFirstPage() async {
        await networkTestIsolationLock.withLock {
        let host = "*"
        let token = "catalog-pagination-token-\(UUID().uuidString)"
        _ = OPNGameDataCache.shared.clearAllCaches()
        OPNGameServiceSwiftAdapter.setAccessToken(token)
        OPNGameServiceSwiftAdapter.setUserId("catalog-pagination-user")
        SessionManagerURLProtocol.install(host: host) { request in
            if request.url?.host == "prod.cloudmatchbeta.nvidiagrid.net" {
                return SessionManagerURLProtocol.response(json: ["requestStatus": ["serverId": "GFN-PC"]])
            }
            let body = SessionManagerURLProtocol.bodyData(from: request).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
            let query = body["query"] as? String ?? ""
            let variables = body["variables"] as? [String: Any] ?? [:]
            if variables["appIds"] != nil {
                return SessionManagerURLProtocol.response(json: ["data": ["apps": ["items": []]]])
            }
            if query.contains("filterGroupDefinitions") {
                return SessionManagerURLProtocol.response(json: ["data": ["filterGroupDefinitions": [], "sortOrderDefinitions": [["id": "a_to_z", "label": "A-Z", "orderBy": "sortName:ASC"]]]])
            }
            let cursor = variables["cursor"] as? String ?? ""
            let start = cursor == "cursor-40" ? 40 : 0
            let count = cursor == "cursor-40" ? 5 : 40
            let hasNextPage = cursor.isEmpty
            let endCursor = hasNextPage ? "cursor-40" : "cursor-45"
            return SessionManagerURLProtocol.response(json: ["data": ["apps": [
                "numberReturned": count,
                "numberSupported": 45,
                "pageInfo": ["hasNextPage": hasNextPage, "endCursor": endCursor, "totalCount": 45],
                "items": (start..<(start + count)).map { catalogGraphQLGame(id: "catalog-game-\($0)") },
            ]]])
        }
        defer { SessionManagerURLProtocol.uninstall(host: host) }

        let result = await withCheckedContinuation { continuation in
            OPNGameServiceSwiftAdapter.browseCatalogObject(searchQuery: "", sortId: "", filterIds: [], fetchCount: 200, forceRefresh: true) { success, browseResult, error in
                continuation.resume(returning: (success, browseResult.games.count, browseResult.numberReturned, browseResult.totalCount, error))
            }
        }

        #expect(result.0 == true)
        #expect(result.4.isEmpty)
        #expect(result.1 == 45)
        #expect(result.2 == 45)
        #expect(result.3 == 45)
        let catalogBodies = SessionManagerURLProtocol.recordedJSONBodies(host: host).filter { body in
            ((body["query"] as? String) ?? "").contains("GetFilterBrowseResults")
        }
        #expect(catalogBodies.compactMap { ($0["variables"] as? [String: Any])?["cursor"] as? String } == ["", "cursor-40"])
        #expect(catalogBodies.compactMap { ($0["variables"] as? [String: Any])?["sortString"] as? String } == ["sortName:ASC", "sortName:ASC"])
    }
}

@Test func libraryFetchUsesVendorOwnedFilterAndPaginatesAllResults() async {
        await networkTestIsolationLock.withLock {
        let host = "*"
        let token = "library-pagination-token-\(UUID().uuidString)"
        _ = OPNGameDataCache.shared.clearAllCaches()
        OPNGameServiceSwiftAdapter.setAccessToken(token)
        OPNGameServiceSwiftAdapter.setUserId("library-pagination-user")
        SessionManagerURLProtocol.install(host: host) { request in
            if request.url?.host == "prod.cloudmatchbeta.nvidiagrid.net" {
                return SessionManagerURLProtocol.response(json: ["requestStatus": ["serverId": "GFN-PC"]])
            }
            let body = SessionManagerURLProtocol.bodyData(from: request).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
            let query = body["query"] as? String ?? ""
            let variables = body["variables"] as? [String: Any] ?? [:]
            if variables["appIds"] != nil {
                return SessionManagerURLProtocol.response(json: ["data": ["apps": ["items": []]]])
            }
            if query.contains("campaigns") {
                return SessionManagerURLProtocol.response(json: ["data": ["campaigns": ["items": []]]])
            }
            let cursor = variables["cursor"] as? String ?? ""
            let start = cursor == "library-cursor-2" ? 2 : 0
            let count = cursor == "library-cursor-2" ? 1 : 2
            let hasNextPage = cursor.isEmpty
            let endCursor = hasNextPage ? "library-cursor-2" : "library-cursor-3"
            return SessionManagerURLProtocol.response(json: ["data": ["apps": [
                "numberReturned": count,
                "numberSupported": 5_758,
                "pageInfo": ["hasNextPage": hasNextPage, "endCursor": endCursor, "totalCount": 3],
                "items": (start..<(start + count)).map { catalogGraphQLGame(id: "library-game-\($0)", libraryStatus: $0.isMultiple(of: 2) ? "PLATFORM_SYNC" : "MANUAL", librarySelected: false) },
            ]]])
        }
        defer { SessionManagerURLProtocol.uninstall(host: host) }

        let result = await withCheckedContinuation { continuation in
            OPNGameServiceSwiftAdapter.fetchLibraryGameObjects { success, games, error in
                continuation.resume(returning: (
                    success,
                    games.count,
                    games.map { $0.isInLibrary },
                    games.map { $0.variants.first?.inLibrary == true },
                    games.map { $0.variants.first?.librarySelected == false },
                    error
                ))
            }
        }

        #expect(result.0 == true)
        #expect(result.5.isEmpty)
        #expect(result.1 == 3)
        #expect(result.2.allSatisfy { $0 })
        #expect(result.3.allSatisfy { $0 })
        #expect(result.4.allSatisfy { $0 })
        let catalogBodies = SessionManagerURLProtocol.recordedJSONBodies(host: host).filter { body in
            ((body["query"] as? String) ?? "").contains("GetFilterBrowseResults")
        }
        #expect(catalogBodies.compactMap { ($0["variables"] as? [String: Any])?["cursor"] as? String } == ["", "library-cursor-2"])
        let filters = catalogBodies.first?["variables"].flatMap { ($0 as? [String: Any])?["filters"] as? [String: Any] }
        let variants = filters?["variants"] as? [String: Any]
        let gfn = variants?["gfn"] as? [String: Any]
        let library = gfn?["library"] as? [String: Any]
        let status = library?["status"] as? [String: Any]
        #expect(status?["notEquals"] as? String == "NOT_OWNED")
    }
}

@Test func libraryFetchKeepsOwnedDirectGFNVariantWithoutStore() async {
        await networkTestIsolationLock.withLock {
        let host = "*"
        let token = "library-direct-gfn-token-\(UUID().uuidString)"
        _ = OPNGameDataCache.shared.clearAllCaches()
        OPNGameServiceSwiftAdapter.setAccessToken(token)
        OPNGameServiceSwiftAdapter.setUserId("library-direct-gfn-user")
        SessionManagerURLProtocol.install(host: host) { request in
            if request.url?.host == "prod.cloudmatchbeta.nvidiagrid.net" {
                return SessionManagerURLProtocol.response(json: ["requestStatus": ["serverId": "GFN-PC"]])
            }
            let body = SessionManagerURLProtocol.bodyData(from: request).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
            let query = body["query"] as? String ?? ""
            let variables = body["variables"] as? [String: Any] ?? [:]
            if variables["appIds"] != nil {
                return SessionManagerURLProtocol.response(json: ["data": ["apps": ["items": []]]])
            }
            if query.contains("campaigns") {
                return SessionManagerURLProtocol.response(json: ["data": ["campaigns": ["items": []]]])
            }
            return SessionManagerURLProtocol.response(json: ["data": ["apps": [
                "numberReturned": 1,
                "numberSupported": 5_758,
                "pageInfo": ["hasNextPage": false, "endCursor": "", "totalCount": 1],
                "items": [catalogGraphQLGame(id: "genshin-impact", title: "Genshin Impact", libraryStatus: "MANUAL", librarySelected: false, appStore: "UNKNOWN", variantId: "145491")],
            ]]])
        }
        defer { SessionManagerURLProtocol.uninstall(host: host) }

        let result = await withCheckedContinuation { continuation in
            OPNGameServiceSwiftAdapter.fetchLibraryGameObjects { success, games, error in
                let game = games.first
                continuation.resume(returning: (
                    success,
                    games.count,
                    game?.title ?? "",
                    game?.isInLibrary == true,
                    game?.launchAppId ?? "",
                    game?.variants.first?.appStore ?? "missing",
                    game?.variants.first?.inLibrary == true,
                    game?.availableStores ?? [],
                    error
                ))
            }
        }

        #expect(result.0 == true)
        #expect(result.8.isEmpty)
        #expect(result.1 == 1)
        #expect(result.2 == "Genshin Impact")
        #expect(result.3 == true)
        #expect(result.4 == "145491")
        #expect(result.5.isEmpty)
        #expect(result.6 == true)
        #expect(result.7.isEmpty)
    }
}

@Test func sessionManagerCreateUsesReleaseCloudMatchShape() async throws {
    try await networkTestIsolationLock.withLock {
    let host = "create-release-shape.example.test"
    SessionManagerURLProtocol.install(host: host) { request in
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v2/session")
        return SessionManagerURLProtocol.response(json: sessionResponse(statusCode: 1, sessionStatus: 2, controlHost: host))
    }
    defer { SessionManagerURLProtocol.uninstall(host: host) }

    let manager = OPNSessionManager()
    manager.setAccessToken("token")
    manager.setStreamingBaseUrl("https://\(host)")
    var settings = minimalSettings()
    settings["networkTestSessionId"] = "stale-session-id"
    settings["enablePersistingInGameSettings"] = true
    settings["partnerCustomData"] = "partner-data"
    settings["userAge"] = 21
    settings["streamingQualityProfile"] = 4
    settings["enableCloudGsync"] = true
    settings["fallbackToLogicalResolution"] = true
    settings["mouseMovementFlags"] = 3
    settings["hudStreamingMode"] = 2
    settings["sdrColorSpace"] = 1
    settings["hdrColorSpace"] = 2
    settings["resolution"] = "7680x4320"

    let result = await withCheckedContinuation { continuation in
        manager.createSession(appId: "123", internalTitle: "Test Game", settings: settings) { success, _, error in
            continuation.resume(returning: (success, error))
        }
    }

    let request = try #require(SessionManagerURLProtocol.recordedRequests(host: host).first)
    let payload = try #require(SessionManagerURLProtocol.recordedJSONBodies(host: host).first)
    let requestData = try #require(payload["sessionRequestData"] as? [String: Any])
    let metadata = try #require(requestData["metaData"] as? [[String: String]])
    let transport = try #require(requestData["transport"] as? [String: Any])
    let metadataKeys = Set(metadata.compactMap { $0["key"] })

    #expect(result.0 == true)
    #expect(result.1.isEmpty)
    #expect(request.url?.query?.contains("keyboardLayout=us") == true)
    #expect(request.value(forHTTPHeaderField: "nv-client-streamer") == "WEBRTC")
    #expect(request.value(forHTTPHeaderField: "nv-client-version") == "2.0.85.135")
    #expect(request.value(forHTTPHeaderField: "nv-client-type") == "BROWSER")
    #expect(request.value(forHTTPHeaderField: "Origin") == "https://play.geforcenow.com")
    #expect(request.value(forHTTPHeaderField: "Referer") == nil)
    #expect(request.value(forHTTPHeaderField: "nv-device-make") == nil)
    #expect(requestData["internalTitle"] as? String == "Test Game")
    #expect(requestData["clientPlatformName"] as? String == "browser")
    #expect(requestData["clientDisplayHdrCapabilities"] is [String: Any])
    #expect(requestData["networkTestSessionId"] as? String == "stale-session-id")
    #expect(requestData["accountLinked"] as? Bool == true)
    #expect(requestData["enablePersistingInGameSettings"] as? Bool == true)
    #expect(requestData["partnerCustomData"] as? String == "")
    #expect(requestData["userAge"] as? Int == 26)
    #expect(requestData["secureRTSPSupported"] as? Bool == false)
    #expect(transport["policy"] as? Int == 2)
    #expect(transport["relayProtocol"] as? Int == 0)
    let monitorSettings = try #require(requestData["clientRequestMonitorSettings"] as? [[String: Any]])
    let monitor = try #require(monitorSettings.first)
    #expect(monitor["monitorId"] as? Int == 0)
    #expect(monitor["positionX"] as? Int == 0)
    #expect(monitor["positionY"] as? Int == 0)
    #expect(monitor["widthInPixels"] as? Int == 7680)
    #expect(monitor["heightInPixels"] as? Int == 4320)
    let physicalResolution = try #require(parsePhysicalResolutionMetadata(metadata))
    #expect(physicalResolution["horizontalPixels"] as? Int == 7680)
    #expect(physicalResolution["verticalPixels"] as? Int == 4320)
    let streamingFeatures = try #require(requestData["requestedStreamingFeatures"] as? [String: Any])
    #expect(streamingFeatures["reflex"] as? Bool == true)
    #expect(streamingFeatures["cloudGsync"] as? Bool == true)
    #expect(streamingFeatures["profile"] as? Int == 4)
    #expect(streamingFeatures["fallbackToLogicalResolution"] as? Bool == true)
    #expect(streamingFeatures["mouseMovementFlags"] as? Int == 3)
    #expect(streamingFeatures["hudStreamingMode"] as? Int == 2)
    #expect(streamingFeatures["sdrColorSpace"] as? Int == 1)
    #expect(streamingFeatures["hdrColorSpace"] as? Int == 2)
    #expect(streamingFeatures["prefilterSharpness"] as? Int == 0)
    #expect(metadataKeys.contains("store") == true)
    #expect(metadataKeys.contains("networkLatencyMs") == true)
    #expect(metadata.contains { $0["key"] == "wssignaling" && $0["value"] == "1" })
    #expect(metadata.contains { $0["key"] == "GSStreamerType" && $0["value"] == "WebRTC" })
    }
}

@Test func sessionManagerCreateUsesNVSTCloudMatchShape() async throws {
    try await networkTestIsolationLock.withLock {
    let host = "create-nvst-shape.example.test"
    SessionManagerURLProtocol.install(host: host) { request in
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v2/session")
        return SessionManagerURLProtocol.response(json: sessionResponse(statusCode: 1, sessionStatus: 2, controlHost: host))
    }
    defer { SessionManagerURLProtocol.uninstall(host: host) }

    let manager = OPNSessionManager()
    manager.setAccessToken("token")
    manager.setStreamingBaseUrl("https://\(host)")
    var settings = minimalSettings()
    settings["transportMode"] = "nvst"

    let result = await withCheckedContinuation { continuation in
        manager.createSession(appId: "123", internalTitle: "Test Game", settings: settings) { success, _, error in
            continuation.resume(returning: (success, error))
        }
    }

    let request = try #require(SessionManagerURLProtocol.recordedRequests(host: host).first)
    let payload = try #require(SessionManagerURLProtocol.recordedJSONBodies(host: host).first)
    let requestData = try #require(payload["sessionRequestData"] as? [String: Any])
    let metadata = try #require(requestData["metaData"] as? [[String: String]])
    let transport = try #require(requestData["transport"] as? [String: Any])

    #expect(result.0 == true)
    #expect(result.1.isEmpty)
    #expect(request.value(forHTTPHeaderField: "nv-client-streamer") == "NVIDIA-CLASSIC")
    #expect(request.value(forHTTPHeaderField: "nv-client-version") == "2.0.80.173")
    #expect(request.value(forHTTPHeaderField: "nv-client-type") == "NATIVE")
    #expect(requestData["clientPlatformName"] as? String == "windows")
    #expect(requestData["secureRTSPSupported"] as? Bool == true)
    #expect(transport["policy"] as? Int == 2)
    #expect(transport["relayProtocol"] as? Int == 0)
    #expect(metadata.contains { $0["key"] == "wssignaling" && $0["value"] == "0" })
    #expect(!metadata.contains { $0["key"] == "GSStreamerType" })
    }
}

@Test func sessionManagerUsesBundleConnectionWhenVideoConnectionIsAbsent() async throws {
    try await networkTestIsolationLock.withLock {
    let host = "bundle-media.example.test"
    SessionManagerURLProtocol.install(host: host) { request in
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/v2/session/resume-session")
        return SessionManagerURLProtocol.response(json: [
            "requestStatus": ["statusCode": 1, "statusDescription": "SUCCESS"],
            "session": [
                "sessionId": "resume-session",
                "status": 2,
                "sessionRequestData": ["appId": 123],
                "sessionControlInfo": ["ip": host],
                "connectionInfo": [
                    ["usage": 14, "ip": "signaling.example.test", "port": 443, "resourcePath": "/nvst/"],
                    ["usage": 17, "ip": "bundle.example.test", "port": 47998, "resourcePath": ""],
                ],
            ],
        ])
    }
    defer { SessionManagerURLProtocol.uninstall(host: host) }

    let manager = OPNSessionManager()
    manager.setAccessToken("token")
    manager.setStreamingBaseUrl("https://\(host)")

    let result = await withCheckedContinuation { continuation in
        manager.pollSession(sessionId: "resume-session", serverIp: host) { success, info, error in
            let media = info["mediaConnectionInfo"] as? [String: Any] ?? [:]
            continuation.resume(returning: (success, media["ip"] as? String ?? "", media["port"] as? Int ?? 0, error))
        }
    }

    #expect(result.0 == true)
    #expect(result.3.isEmpty)
    #expect(result.1 == "bundle.example.test")
    #expect(result.2 == 47998)
    }
}

@Test func sessionManagerPausedResumeSendsExplicitPutBeforePolling() async {
    await networkTestIsolationLock.withLock {
    let host = "resume-success.example.test"
    let lock = NSLock()
    nonisolated(unsafe) var getCount = 0
    SessionManagerURLProtocol.install(host: host) { request in
        let path = request.url?.path ?? ""
        if request.httpMethod == "GET", path == "/v2/session/resume-session" {
            lock.lock()
            getCount += 1
            let count = getCount
            lock.unlock()
            return SessionManagerURLProtocol.response(json: sessionResponse(statusCode: 1, sessionStatus: count == 1 ? 6 : 2, controlHost: host))
        }
        if request.httpMethod == "PUT", path == "/v2/session/resume-session" {
            return SessionManagerURLProtocol.response(json: sessionResponse(statusCode: 1, sessionStatus: 6, controlHost: host))
        }
        return SessionManagerURLProtocol.response(json: sessionResponse(statusCode: 1, sessionStatus: 2, controlHost: host))
    }
    defer { SessionManagerURLProtocol.uninstall(host: host) }

    OPNSessionManager.shared.setAccessToken("token")
    OPNSessionManager.shared.setStreamingBaseUrl("https://\(host)")
    var settings = minimalSettings()
    settings["resolution"] = "7680x4320"

    let result = await withCheckedContinuation { continuation in
        OPNSessionManager.shared.claimSession(sessionId: "resume-session", serverIp: host, appId: "123", settings: settings, recoveryMode: false) { success, _, error in
            continuation.resume(returning: (success, error))
        }
    }

    let requests = SessionManagerURLProtocol.recordedRequests(host: host)
    let claimRequest = requests.first { $0.httpMethod == "PUT" }
    let claimPayload = SessionManagerURLProtocol.recordedJSONBodies(host: host).first { $0["action"] != nil }
    let claimRequestData = claimPayload?["sessionRequestData"] as? [String: Any]
    let claimMetadata = claimRequestData?["metaData"] as? [[String: String]] ?? []
    let claimTransport = claimRequestData?["transport"] as? [String: Any]
    #expect(result.0 == true)
    #expect(requests.map(\.httpMethod) == ["GET", "PUT", "GET"])
    #expect(claimRequest?.value(forHTTPHeaderField: "nv-client-streamer") == "WEBRTC")
    #expect(claimRequest?.value(forHTTPHeaderField: "nv-client-version") == "2.0.85.135")
    #expect(claimRequest?.value(forHTTPHeaderField: "nv-client-type") == "BROWSER")
    #expect(claimPayload?["action"] as? Int == 2)
    #expect(claimPayload?["data"] as? String == "RESUME")
    #expect(claimRequestData?["appId"] as? Int == 123)
    #expect(claimRequestData?["clientPlatformName"] as? String == "browser")
    #expect(claimRequestData?["clientIdentification"] as? String == "GFN-PC")
    #expect(claimRequestData?["accountLinked"] as? Bool == true)
    #expect(claimRequestData?["secureRTSPSupported"] as? Bool == false)
    #expect(claimTransport?["policy"] as? Int == 2)
    #expect(claimTransport?["relayProtocol"] as? Int == 0)
    let claimMonitorSettings = claimRequestData?["clientRequestMonitorSettings"] as? [[String: Any]] ?? []
    #expect(claimMonitorSettings.first?["widthInPixels"] as? Int == 7680)
    #expect(claimMonitorSettings.first?["heightInPixels"] as? Int == 4320)
    let claimPhysicalResolution = parsePhysicalResolutionMetadata(claimMetadata)
    #expect(claimPhysicalResolution?["horizontalPixels"] as? Int == 7680)
    #expect(claimPhysicalResolution?["verticalPixels"] as? Int == 4320)
    #expect(claimMetadata.contains { $0["key"] == "wssignaling" && $0["value"] == "1" })
    #expect(claimMetadata.contains { $0["key"] == "GSStreamerType" && $0["value"] == "WebRTC" })
    }
}

@Test func sessionManagerNVSTPausedResumeSendsNVSTClaimShape() async {
    await networkTestIsolationLock.withLock {
    let host = "resume-nvst-success.example.test"
    SessionManagerURLProtocol.install(host: host) { _ in
        SessionManagerURLProtocol.response(json: sessionResponse(statusCode: 1, sessionStatus: 2, controlHost: host))
    }
    defer { SessionManagerURLProtocol.uninstall(host: host) }

    OPNSessionManager.shared.setAccessToken("token")
    OPNSessionManager.shared.setStreamingBaseUrl("https://\(host)")
    var settings = minimalSettings()
    settings["transportMode"] = "nvst"

    let result = await withCheckedContinuation { continuation in
        OPNSessionManager.shared.claimSession(sessionId: "resume-session", serverIp: host, appId: "123", settings: settings, recoveryMode: false) { success, _, error in
            continuation.resume(returning: (success, error))
        }
    }

    let claimPayload = SessionManagerURLProtocol.recordedJSONBodies(host: host).first { $0["action"] != nil }
    let claimRequest = SessionManagerURLProtocol.recordedRequests(host: host).first { $0.httpMethod == "PUT" }
    let claimRequestData = claimPayload?["sessionRequestData"] as? [String: Any]
    let claimMetadata = claimRequestData?["metaData"] as? [[String: String]] ?? []
    let claimTransport = claimRequestData?["transport"] as? [String: Any]
    #expect(result.0 == true)
    #expect(claimRequest?.value(forHTTPHeaderField: "nv-client-streamer") == "NVIDIA-CLASSIC")
    #expect(claimRequest?.value(forHTTPHeaderField: "nv-client-version") == "2.0.80.173")
    #expect(claimRequest?.value(forHTTPHeaderField: "nv-client-type") == "NATIVE")
    #expect(claimRequestData?["clientPlatformName"] as? String == "windows")
    #expect(claimRequestData?["secureRTSPSupported"] as? Bool == true)
    #expect(claimTransport?["policy"] as? Int == 2)
    #expect(claimTransport?["relayProtocol"] as? Int == 0)
    #expect(claimMetadata.contains { $0["key"] == "wssignaling" && $0["value"] == "0" })
    #expect(!claimMetadata.contains { $0["key"] == "GSStreamerType" })
    }
}

@Test func sessionManagerSessionNotPausedFailsWithoutPollingFallback() async {
    await networkTestIsolationLock.withLock {
    let host = "resume-not-paused.example.test"
    SessionManagerURLProtocol.install(host: host) { request in
        let path = request.url?.path ?? ""
        if request.httpMethod == "GET", path == "/v2/session/resume-session" {
            return SessionManagerURLProtocol.response(json: sessionResponse(statusCode: 1, sessionStatus: 2, controlHost: host))
        }
        return SessionManagerURLProtocol.response(json: [
            "requestStatus": [
                "statusCode": 34,
                "statusDescription": "SESSION_NOT_PAUSED",
            ],
        ])
    }
    defer { SessionManagerURLProtocol.uninstall(host: host) }

    OPNSessionManager.shared.setAccessToken("token")
    OPNSessionManager.shared.setStreamingBaseUrl("https://\(host)")

    let result = await withCheckedContinuation { continuation in
        OPNSessionManager.shared.claimSession(sessionId: "resume-session", serverIp: host, appId: "123", settings: minimalSettings(), recoveryMode: false) { success, _, error in
            continuation.resume(returning: (success, error))
        }
    }

    let requests = SessionManagerURLProtocol.recordedRequests(host: host)
    #expect(result.0 == false)
    #expect(result.1 == "Session is not paused and cannot be resumed.")
    #expect(requests.map(\.httpMethod) == ["GET", "PUT"])
    }
}

@Test func sessionManagerStaleInternalClaimErrorFailsWithoutPollingFallback() async {
    await networkTestIsolationLock.withLock {
    let host = "resume-stale-internal.example.test"
    UserDefaults.standard.set("resume-session", forKey: "OpenNOW.Stream.ActiveSessionId")
    SessionManagerURLProtocol.install(host: host) { request in
        let path = request.url?.path ?? ""
        if request.httpMethod == "GET", path == "/v2/session/resume-session" {
            return SessionManagerURLProtocol.response(json: sessionResponse(statusCode: 1, sessionStatus: 2, controlHost: host))
        }
        return SessionManagerURLProtocol.response(json: staleSessionResponse(), status: 400)
    }
    defer {
        UserDefaults.standard.removeObject(forKey: "OpenNOW.Stream.ActiveSessionId")
        SessionManagerURLProtocol.uninstall(host: host)
    }

    OPNSessionManager.shared.setAccessToken("token")
    OPNSessionManager.shared.setStreamingBaseUrl("https://\(host)")

    let result = await withCheckedContinuation { continuation in
        OPNSessionManager.shared.claimSession(sessionId: "resume-session", serverIp: host, appId: "123", settings: minimalSettings(), recoveryMode: false) { success, _, error in
            continuation.resume(returning: (success, error))
        }
    }

    let requests = SessionManagerURLProtocol.recordedRequests(host: host)
    #expect(result.0 == false)
    #expect(result.1 == "This GeForce NOW session is no longer resumable. End it and launch again.")
    #expect(UserDefaults.standard.string(forKey: "OpenNOW.Stream.ActiveSessionId") == nil)
    #expect(requests.map(\.httpMethod) == ["GET", "PUT"])
    }
}

@Test func sessionManagerStaleInternalCreateErrorReturnsHTTPMessage() async {
    await networkTestIsolationLock.withLock {
    let host = "create-stale-internal.example.test"
    SessionManagerURLProtocol.install(host: host) { request in
        #expect(request.httpMethod == "POST")
        return SessionManagerURLProtocol.response(json: staleSessionResponse(), status: 400)
    }
    defer { SessionManagerURLProtocol.uninstall(host: host) }

    let manager = OPNSessionManager()
    manager.setAccessToken("token")
    manager.setStreamingBaseUrl("https://\(host)")
    let result = await withCheckedContinuation { continuation in
        manager.createSession(appId: "123", internalTitle: "Test Game", settings: minimalSettings()) { success, _, error in
            continuation.resume(returning: (success, error))
        }
    }

    #expect(result.0 == false)
    #expect(result.1.contains("HTTP 400:"))
    #expect(result.1.contains("INTERNAL_ERROR_STATUS 8A8C0000"))
    }
}

@Test func sessionManagerDoesNotSelectZeroAppIdSessionLimitEntry() {
    let selected = OPNSessionManager.shared.selectSessionLimitReuseEntry([[
        "sessionId": "stale-session",
        "appId": 0,
        "status": 2,
        "serverIp": "control.example.test",
    ]], requestedAppId: 123)

    #expect(selected == nil)
}

private func minimalSettings() -> [String: Any] {
    [
        "resolution": "1920x1080",
        "fps": 60,
        "codec": "h264",
        "colorQuality": "standard",
        "maxBitrateMbps": 50,
        "selectedStore": "Steam",
        "accountLinked": true,
        "gameLanguage": "en_US",
        "keyboardLayout": "us",
    ]
}

private func parsePhysicalResolutionMetadata(_ metadata: [[String: String]]) -> [String: Any]? {
    guard let value = metadata.first(where: { $0["key"] == "clientPhysicalResolution" })?["value"],
          let data = value.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return object
}

private func sessionResponse(statusCode: Int, sessionStatus: Int, controlHost: String = "control.example.test") -> [String: Any] {
    [
        "requestStatus": [
            "statusCode": statusCode,
            "statusDescription": statusCode == 1 ? "SUCCESS" : "ERROR",
        ],
        "session": [
            "sessionId": "resume-session",
            "status": sessionStatus,
            "gpuType": "L40",
            "sessionRequestData": ["appId": 123],
            "sessionControlInfo": ["ip": controlHost],
            "connectionInfo": [[
                "usage": 14,
                "ip": "signaling.example.test",
                "port": 443,
                "resourcePath": "/nvst/",
            ]],
            "monitorSettings": [[
                "widthInPixels": 1920,
                "heightInPixels": 1080,
                "framesPerSecond": 60,
                "dpi": 96,
            ]],
        ],
    ]
}

private func staleSessionResponse() -> [String: Any] {
    [
        "requestStatus": [
            "statusCode": 4,
            "statusDescription": "INTERNAL_ERROR_STATUS 8A8C0000",
        ],
        "session": [
            "sessionId": "resume-session",
            "status": 4,
            "sessionRequestData": ["appId": 0],
        ],
    ]
}

private func catalogGraphQLGame(id: String, title: String? = nil, libraryStatus: String = "NOT_OWNED", librarySelected: Bool = false, appStore: String = "STEAM", variantId: String? = nil) -> [String: Any] {
    [
        "id": id,
        "title": title ?? "Catalog Game \(id)",
        "shortName": "vendor-title",
        "developerName": "Vendor Developer",
        "publisherName": "Vendor Publisher",
        "maxLocalPlayers": 4,
        "maxOnlinePlayers": 8,
        "supportedControls": ["KEYBOARD_MOUSE"],
        "displaysOwnRatingDuringGameplay": true,
        "genres": ["ACTION"],
        "contentRatings": [["categoryKey": "TEEN", "contentDescriptorKeys": ["VIOLENCE"], "interactiveElementKeys": ["USERS_INTERACT"], "type": "ESRB"]],
        "images": ["TV_BANNER": ["https://assets.example.invalid/\(id).jpg"]],
        "variants": [[
            "id": variantId ?? "1\(abs(id.hashValue % 1_000_000))",
            "shortName": "vendor-short",
            "appStore": appStore,
            "storeUrl": "https://store.example.invalid/\(id)",
            "developerName": "Variant Developer",
            "publisherName": "Variant Publisher",
            "streetDate": "2026-07-17",
            "supportedControls": ["GAMEPAD"],
            "subscriptions": ["sub-ultimate"],
            "paymentModels": [["__typename": "IncludedWithSubscription"]],
            "minimumSizeInBytes": 42_000_000,
            "cloudSaveSupported": true,
            "gfn": [
                "status": "AVAILABLE",
                "installTimeInMinutes": 7,
                "supportedLanguages": [["language": "en_US"]],
                "features": [["__typename": "GfnSubscriptionFeatureValue", "key": "RAY_TRACING", "value": "SUPPORTED"]],
                "library": ["status": libraryStatus, "selected": librarySelected, "playStatus": "PLAYABLE", "installed": true, "subscription": "GFN_PREMIUM"],
            ],
        ]],
        "gfn": ["playabilityState": "PLAYABLE", "minimumMembershipTierLabel": "Free", "playType": "FULL_GAME"],
        "itemMetadata": ["campaignIds": []],
    ]
}

private final class SessionManagerURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var requestsByHost: [String: [URLRequest]] = [:]
    nonisolated(unsafe) private static var bodiesByHost: [String: [Data]] = [:]
    nonisolated(unsafe) private static var installed = false

    static func install(host: String, handler: @escaping Handler) {
        lock.withLock {
            handlers[host] = handler
            requestsByHost[host] = []
            bodiesByHost[host] = []
            if !installed {
                URLProtocol.registerClass(Self.self)
                installed = true
            }
        }
    }

    static func uninstall(host: String) {
        lock.withLock {
            handlers[host] = nil
            requestsByHost[host] = nil
            bodiesByHost[host] = nil
            if handlers.isEmpty, installed {
                URLProtocol.unregisterClass(Self.self)
                installed = false
            }
        }
    }

    static func recordedRequests(host: String) -> [URLRequest] {
        lock.withLock { requestsByHost[host] ?? [] }
    }

    static func recordedJSONBodies(host: String) -> [[String: Any]] {
        lock.withLock { bodiesByHost[host] ?? [] }
            .compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    static func response(json: [String: Any], status: Int = 200) -> (Int, Data) {
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        return (status, data)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return lock.withLock { handlers[host] != nil || handlers["*"] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let host = request.url?.host, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body = Self.bodyData(from: request)
        let handler = Self.lock.withLock { () -> Handler? in
            let key = Self.handlers[host] == nil && Self.handlers["*"] != nil ? "*" : host
            Self.requestsByHost[key, default: []].append(request)
            if let body { Self.bodiesByHost[key, default: []].append(body) }
            return Self.handlers[key]
        }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = handler(request)
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count < 0 { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }
}
