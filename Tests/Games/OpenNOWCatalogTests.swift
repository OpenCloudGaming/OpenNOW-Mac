//  Catalog browsing, panels and the library: what the vendor's GraphQL answers turn into.
//  Split out of OpenNOWGameServicesTests.swift.
//

import Testing
import Foundation
@testable import OpenNOW

@Test func catalogGameObjectPreservesPatchingStateRoundTrip() {
    var game = OPNGameInfo()
    game.id = "game-id"
    game.launchAppId = "123"
    game.isFavorited = true
    game.isPatching = true
    game.variants = [OPNGameVariant(id: "123", appStore: "STEAM", serviceStatus: "APP_PATCHING_STATUS", isPatching: true)]

    let object = OPNCatalogGameObject(game: game)
    let roundTrip = object.swiftValue

    #expect(object.isPatching == true)
    #expect(object.isFavorited == true)
    #expect(object.variants.first?.isPatching == true)
    #expect(roundTrip.isPatching == true)
    #expect(roundTrip.isFavorited == true)
    #expect(roundTrip.variants.first?.isPatching == true)
}

/// A catalog browse that returns one fully populated vendor game, with the app-metadata pass answering for it too.
let vendorVariantMetadataResponder: SessionManagerURLProtocol.Handler = { request in
        if request.url?.host == "prod.cloudmatchbeta.nvidiagrid.net" {
            return SessionManagerURLProtocol.response(json: ["requestStatus": ["serverId": "GFN-PC"]])
        }
        let absoluteURL = request.url?.absoluteString ?? ""
        let body = SessionManagerURLProtocol.bodyData(from: request).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        let query = body["query"] as? String ?? ""
        let variables = body["variables"] as? [String: Any] ?? [:]
        if query.contains("filterGroupDefinitions") {
            return SessionManagerURLProtocol.response(json: ["data": ["filterGroupDefinitions": [], "sortOrderDefinitions": [["id": "a_to_z", "label": "A-Z", "orderBy": "sortName:ASC"]]]])
        }
        if query.contains("campaigns") || query.contains("ratingDefinitions") {
            return SessionManagerURLProtocol.response(json: ["data": [:]])
        }
        if variables["appIds"] != nil || absoluteURL.contains("requestType=appMetaData") {
            return SessionManagerURLProtocol.response(json: ["data": ["apps": ["items": [catalogGraphQLGame(id: "vendor-game", libraryStatus: "PLATFORM_SYNC", librarySelected: true, variantId: "123456", favorited: true)]]]])
        }
        return SessionManagerURLProtocol.response(json: ["data": ["apps": [
            "numberReturned": 1,
            "numberSupported": 1,
            "pageInfo": ["hasNextPage": false, "endCursor": "", "totalCount": 1],
            "items": [catalogGraphQLGame(id: "vendor-game", libraryStatus: "PLATFORM_SYNC", librarySelected: true, variantId: "123456")],
        ]]])
}

@Test func catalogBrowsePreservesVendorVariantMetadata() async {
        await networkTestIsolationLock.withLock {
        let host = "*"
        let token = "catalog-vendor-metadata-token-\(UUID().uuidString)"
        _ = OPNGameDataCache.shared.clearAllCaches()
        OPNGameService.shared.setAccessToken(token)
        OPNGameService.shared.setUserId("catalog-vendor-metadata-user")
        SessionManagerURLProtocol.install(host: host, paths: ["/graphql", "/v2/serverInfo"], handler: vendorVariantMetadataResponder)
        defer { SessionManagerURLProtocol.uninstall(host: host) }

        let result = await withCheckedContinuation { continuation in
            OPNGameService.shared.browseCatalogObject(searchQuery: "", sortId: "", filterIds: [], fetchCount: 24, forceRefresh: true) { success, browseResult, error in
                continuation.resume(returning: (success, browseResult.games.first?.swiftValue, error))
            }
        }

        let game = result.1
        #expect(result.0 == true)
        #expect(result.2.isEmpty)
        #expect(game?.displaysOwnRatingDuringGameplay == true)
        #expect(game?.isFavorited == true)
        #expect(game?.skuPlayabilityText == "Included with membership")
        #expect(game?.skuUnplayableDialogHeader == "Upgrade required")
        #expect(game?.skuUnplayableDialogBody == "Upgrade to play")
        #expect(game?.skuUnplayableDialogBodyEcommerceRestricted == "Upgrade in your account")
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

/// One home panel whose section carries a `seeMoreInfo` block, and asserts the panel query's own hash on the way through.
let seeMoreParametersResponder: SessionManagerURLProtocol.Handler = { request in
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
                "items": [
                    ["__typename": "GameItem", "app": catalogGraphQLGame(id: "panel-game")],
                    ["__typename": "FilterItem", "id": "filter-action", "title": "Action Games", "image": "https://assets.example.invalid/filter.jpg", "filterIds": ["genre-action"], "sortOrderId": "release_date"],
                    ["__typename": "MarketingItem", "id": "marketing-tile", "title": "Membership Deal", "subTitle": "Limited", "body": "Play more", "images": ["HERO_IMAGE": ["https://assets.example.invalid/marketing.jpg"]], "action": ["uri": "https://play.geforcenow.com/deal", "label": "Learn More"]],
                ],
            ]],
        ]]]])
}

@Test func panelSectionPreservesSeeMoreCatalogParameters() async {
        await networkTestIsolationLock.withLock {
        let host = "*"
        let token = "panel-see-more-token-\(UUID().uuidString)"
        _ = OPNGameDataCache.shared.clearAllCaches()
        OPNGameService.shared.setAccessToken(token)
        OPNGameService.shared.setUserId("panel-see-more-user")
        SessionManagerURLProtocol.install(host: host, paths: ["/graphql", "/v2/serverInfo"], handler: seeMoreParametersResponder)
        defer { SessionManagerURLProtocol.uninstall(host: host) }

        // Panels are delivered twice (parsed, then metadata-enriched). Await the
        // second delivery so the enrichment's follow-up requests have finished
        // before this test uninstalls its URL handler — otherwise they bleed
        // into the next test's stricter handler and fail its expectations.
        let result = await withCheckedContinuation { continuation in
            nonisolated(unsafe) var deliveryCount = 0
            OPNGameService.shared.fetchMainPanelObjects { success, panels, error in
                dispatchPrecondition(condition: .onQueue(.main))
                deliveryCount += 1
                guard deliveryCount == 2 else { return }
                let section = panels.first?.sections.first
                let tiles = section?.tiles ?? []
                continuation.resume(returning: (success, section?.seeMoreFilterIds ?? [], section?.seeMoreSortId ?? "", section?.seeMoreTitle ?? "", tiles.map(\.kind), tiles.first?.filterIds ?? [], tiles.last?.actionUrl ?? "", error))
            }
        }

        #expect(result.0 == true)
        #expect(result.7.isEmpty)
        #expect(result.1 == ["genre-action", "store-steam"])
        #expect(result.2 == "release_date")
        #expect(result.3 == "Show all featured")
        #expect(result.4 == ["filter", "marketing"])
        #expect(result.5 == ["genre-action"])
        #expect(result.6 == "https://play.geforcenow.com/deal")
    }
}

@Test func libraryPatchStatusFetchUsesVendorOwnedFilterAndClearsEndedPatch() async {
    await networkTestIsolationLock.withLock {
        let host = "*"
        OPNGameService.shared.setAccessToken("library-patch-token-\(UUID().uuidString)")
        OPNGameService.shared.setUserId("library-patch-user")
        SessionManagerURLProtocol.install(host: host, paths: ["/graphql", "/v2/serverInfo"]) { request in
            if request.url?.host == "prod.cloudmatchbeta.nvidiagrid.net" {
                return SessionManagerURLProtocol.response(json: ["requestStatus": ["serverId": "GFN-PC"]])
            }
            let body = SessionManagerURLProtocol.bodyData(from: request).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
            let query = body["query"] as? String ?? ""
            let variables = body["variables"] as? [String: Any] ?? [:]
            #expect(query.contains("GetAppsPatchInfoWithLibraryFilter"))
            #expect((variables["filters"] as? [String: Any]) != nil)
            #expect(variables["fetchCount"] as? Int == 749)
            return SessionManagerURLProtocol.response(json: ["data": ["apps": [
                "numberReturned": 1,
                "pageInfo": ["hasNextPage": false, "endCursor": "", "totalCount": 1],
                "items": [[
                    "id": "ended-patch-game",
                    "variants": [["id": "123456", "gfn": ["status": "AVAILABLE", "library": ["status": "MANUAL"]]]],
                ]],
            ]]])
        }
        defer { SessionManagerURLProtocol.uninstall(host: host) }

        let result = await withCheckedContinuation { continuation in
            OPNGameService.shared.fetchLibraryPatchStatuses { success, statuses, error in
                continuation.resume(returning: (success, statuses["ended-patch-game"], error))
            }
        }

        #expect(result.0 == true)
        #expect(result.2.isEmpty)
        #expect(result.1?.isPatching == false)
        #expect(result.1?.variantPatchingById["123456"] == false)
    }
}

@Test func cmsMetadataLookupUsesVendorVariantIdsQuery() async {
    await networkTestIsolationLock.withLock {
        let host = "*"
        OPNGameService.shared.setAccessToken("cms-metadata-token-\(UUID().uuidString)")
        OPNGameService.shared.setUserId("cms-metadata-user")
        SessionManagerURLProtocol.install(host: host, paths: ["/graphql", "/v2/serverInfo"]) { request in
            if request.url?.host == "prod.cloudmatchbeta.nvidiagrid.net" {
                return SessionManagerURLProtocol.response(json: ["requestStatus": ["serverId": "GFN-PC"]])
            }
            let body = SessionManagerURLProtocol.bodyData(from: request).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
            let query = body["query"] as? String ?? ""
            guard query.contains("GetAppDataQueryForCmsId") else {
                return SessionManagerURLProtocol.response(json: ["data": [:]])
            }
                let variables = body["variables"] as? [String: Any] ?? [:]
                if query.contains("GetRatingDefinitions") {
                    return SessionManagerURLProtocol.response(json: ["data": ["ratingDefinitions": []]])
                }
                #expect(query.contains("GetAppDataQueryForCmsId"))
            #expect(variables["cmsIds"] as? [Int] == [145491])
            return SessionManagerURLProtocol.response(json: ["data": ["apps": ["items": [catalogGraphQLGame(id: "genshin-impact", title: "Genshin Impact", variantId: "145491", favorited: true)]]]])
        }
        defer { SessionManagerURLProtocol.uninstall(host: host) }

        let result = await withCheckedContinuation { continuation in
            OPNGameService.shared.fetchGameObjectByCMSId("145491") { success, game, error in
                continuation.resume(returning: (success, game?.title ?? "", game?.variants.first?.id ?? "", game?.isFavorited ?? false, error))
            }
        }

        #expect(result.0 == true)
        #expect(result.1 == "Genshin Impact")
        #expect(result.2 == "145491")
        #expect(result.3 == true)
        #expect(result.4.isEmpty)
    }
}

@Test func subscriptionDefinitionsFetchParsesVendorFields() async {
    await networkTestIsolationLock.withLock {
        let host = "*"
        OPNGameService.shared.setAccessToken("subscription-definitions-token-\(UUID().uuidString)")
        OPNGameService.shared.setUserId("subscription-definitions-user")
        SessionManagerURLProtocol.install(host: host, paths: ["/graphql"]) { request in
            let body = SessionManagerURLProtocol.bodyData(from: request).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
            let query = body["query"] as? String ?? ""
            let variables = body["variables"] as? [String: Any] ?? [:]
            #expect(query.contains("subscriptionDefinitions"))
            #expect(variables["locale"] as? String == OPNLocale.currentGFNCatalogLocale())
            return SessionManagerURLProtocol.response(json: ["data": ["subscriptionDefinitions": [[
                "subscription": "ubisoft_plus",
                "label": "Ubisoft+",
                "logoURL": "https://assets.example.invalid/ubisoft-plus.svg",
                "primaryStore": "UBISOFT_CONNECT",
            ]]]])
        }
        defer { SessionManagerURLProtocol.uninstall(host: host) }

        let result = await withCheckedContinuation { continuation in
            OPNGameService.shared.fetchSubscriptionDefinitions { success, definitions, error in
                let definition = definitions.first
                continuation.resume(returning: (
                    success,
                    definition?.subscription ?? "",
                    definition?.label ?? "",
                    definition?.logoURL ?? "",
                    definition?.primaryStore ?? "",
                    error
                ))
            }
        }

        #expect(result.0 == true)
        #expect(result.5.isEmpty)
        #expect(result.1 == "ubisoft_plus")
        #expect(result.2 == "Ubisoft+")
        #expect(result.3 == "https://assets.example.invalid/ubisoft-plus.svg")
        #expect(result.4 == "UBISOFT_CONNECT")
    }
}

@Test func vendorRemoveMutationsTreatNotFoundAsSuccess() async {
        await networkTestIsolationLock.withLock {
        let host = "*"
        OPNGameService.shared.setAccessToken("remove-mutation-404-token-\(UUID().uuidString)")
        OPNGameService.shared.setUserId("remove-mutation-404-user")
        SessionManagerURLProtocol.install(host: host, paths: ["/graphql"]) { request in
            #expect(request.url?.host == "games.geforce.com")
            #expect(request.httpMethod == "POST")
            return SessionManagerURLProtocol.response(json: ["errors": [["message": "not found"]]], status: 404)
        }
        defer { SessionManagerURLProtocol.uninstall(host: host) }

        let favoriteResult: (Bool, String) = await withCheckedContinuation { continuation in
            OPNGameService.shared.removeFavoriteApp("favorite-game-id") { success, error in
                continuation.resume(returning: (success, error))
            }
        }
        let ownedResult: (Bool, String) = await withCheckedContinuation { continuation in
            OPNGameService.shared.removeOwnedVariant("123456") { success, error in
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

@Test func catalogBrowseAppliesCollectionFiltersWhenDefinitionsAreEmpty() async {
        await networkTestIsolationLock.withLock {
        let host = "*"
        let token = "catalog-collections-token-\(UUID().uuidString)"
        _ = OPNGameDataCache.shared.clearAllCaches()
        OPNGameService.shared.setAccessToken(token)
        OPNGameService.shared.setUserId("catalog-collections-user")
        SessionManagerURLProtocol.install(host: host, paths: ["/graphql", "/v2/serverInfo"]) { request in
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
            return SessionManagerURLProtocol.response(json: ["data": ["apps": [
                "numberReturned": 1,
                "numberSupported": 1,
                "pageInfo": ["hasNextPage": false, "endCursor": "", "totalCount": 1],
                "items": [catalogGraphQLGame(id: "favorite-catalog-game")],
            ]]])
        }
        defer { SessionManagerURLProtocol.uninstall(host: host) }

        let result = await withCheckedContinuation { continuation in
            OPNGameService.shared.browseCatalogObject(searchQuery: "", sortId: "", filterIds: ["my_favorites"], fetchCount: 200, forceRefresh: true) { success, browseResult, error in
                continuation.resume(returning: (
                    success,
                    browseResult.selectedFilterIds,
                    browseResult.filterGroups.map { group in (group.id, group.options.map(\.id)) },
                    error
                ))
            }
        }

        #expect(result.0 == true)
        #expect(result.3.isEmpty)
        #expect(result.1 == ["my_favorites"])
        #expect(result.2.contains { $0.0 == "collections" && $0.1.sorted() == ["my_favorites", "my_library"] })
        let catalogBodies = SessionManagerURLProtocol.recordedJSONBodies(host: host).filter { body in
            ((body["query"] as? String) ?? "").contains("GetFilterBrowseResults")
        }
        let filters = catalogBodies.first?["variables"].flatMap { ($0 as? [String: Any])?["filters"] as? [String: Any] }
        let library = filters?["library"] as? [String: Any]
        let favorited = library?["favorited"] as? [String: Any]
        #expect(favorited?["equals"] as? Bool == true)
    }
}

/// A catalog whose first page returns the full 40 items and a cursor, so the client has to ask for the second.
let fortyItemPageResponder: SessionManagerURLProtocol.Handler = { request in
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

@Test func catalogBrowseContinuesAfterFortyItemFirstPage() async {
        await networkTestIsolationLock.withLock {
        let host = "*"
        let token = "catalog-pagination-token-\(UUID().uuidString)"
        _ = OPNGameDataCache.shared.clearAllCaches()
        OPNGameService.shared.setAccessToken(token)
        OPNGameService.shared.setUserId("catalog-pagination-user")
        SessionManagerURLProtocol.install(host: host, paths: ["/graphql", "/v2/serverInfo"], handler: fortyItemPageResponder)
        defer { SessionManagerURLProtocol.uninstall(host: host) }

        // Browse fetches a single page; the caller drives further pages via endCursor.
        let firstPage = await withCheckedContinuation { continuation in
            OPNGameService.shared.browseCatalogObject(searchQuery: "", sortId: "", filterIds: [], fetchCount: 200, forceRefresh: true) { success, browseResult, error in
                continuation.resume(returning: (success, browseResult.games.count, browseResult.numberReturned, browseResult.totalCount, browseResult.hasNextPage, browseResult.endCursor, error))
            }
        }

        #expect(firstPage.0 == true)
        #expect(firstPage.6.isEmpty)
        #expect(firstPage.1 == 40)
        #expect(firstPage.2 == 40)
        #expect(firstPage.3 == 45)
        #expect(firstPage.4 == true)
        #expect(firstPage.5 == "cursor-40")

        let nextPage = await withCheckedContinuation { continuation in
            OPNGameService.shared.browseCatalogObject(searchQuery: "", sortId: "", filterIds: [], fetchCount: 200, forceRefresh: true, cursor: firstPage.5) { success, browseResult, error in
                continuation.resume(returning: (success, browseResult.games.count, browseResult.numberReturned, browseResult.totalCount, browseResult.hasNextPage, error))
            }
        }

        #expect(nextPage.0 == true)
        #expect(nextPage.5.isEmpty)
        #expect(nextPage.1 == 5)
        #expect(nextPage.2 == 5)
        #expect(nextPage.3 == 45)
        #expect(nextPage.4 == false)
        let catalogBodies = SessionManagerURLProtocol.recordedJSONBodies(host: host).filter { body in
            ((body["query"] as? String) ?? "").contains("GetFilterBrowseResults")
        }
        #expect(catalogBodies.compactMap { ($0["variables"] as? [String: Any])?["cursor"] as? String } == ["", "cursor-40"])
        #expect(catalogBodies.compactMap { ($0["variables"] as? [String: Any])?["sortString"] as? String } == ["sortName:ASC", "sortName:ASC"])
    }
}

/// A library query paginated across two pages, so the owned filter and the cursor both have to survive the second request.
let libraryPaginationResponder: SessionManagerURLProtocol.Handler = { request in
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

@Test func libraryFetchUsesVendorOwnedFilterAndPaginatesAllResults() async {
        await networkTestIsolationLock.withLock {
        let host = "*"
        let token = "library-pagination-token-\(UUID().uuidString)"
        _ = OPNGameDataCache.shared.clearAllCaches()
        OPNGameService.shared.setAccessToken(token)
        OPNGameService.shared.setUserId("library-pagination-user")
        SessionManagerURLProtocol.install(host: host, paths: ["/graphql", "/v2/serverInfo"], handler: libraryPaginationResponder)
        defer { SessionManagerURLProtocol.uninstall(host: host) }

        let result = await withCheckedContinuation { continuation in
            OPNGameService.shared.fetchLibraryGameObjects { success, games, error in
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
        OPNGameService.shared.setAccessToken(token)
        OPNGameService.shared.setUserId("library-direct-gfn-user")
        SessionManagerURLProtocol.install(host: host, paths: ["/graphql", "/v2/serverInfo"]) { request in
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
            OPNGameService.shared.fetchLibraryGameObjects { success, games, error in
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
