//
//  MacForceNow
//

import AppKit
import Foundation

extension OPNGameService {
    func fetchMarqueePanels(completion: @escaping OPNPanelCallback) {
        fetchPanels(operationName: "panels/Marquee", hash: Self.marqueeHash, panelNames: ["MARQUEE"], cacheKind: "marquee", missingMessage: "No panels in marquee response", completion: completion)
    }

    func fetchMainPanels(completion: @escaping OPNPanelCallback) {
        fetchPanels(operationName: "panels/MainV2", hash: Self.panelsHash, panelNames: ["MAIN"], cacheKind: "main", missingMessage: "No panels in response", completion: completion)
    }

    func fetchPanels(operationName: String, hash: String, panelNames: [String], cacheKind: String, missingMessage: String, completion: @escaping OPNPanelCallback) {
        let accountIdentifier = userId
        let providerBaseUrl = providerStreamingBaseURL()
        let locale = Self.currentGFNCatalogLocale()
        getServerVpcId(token: accessToken, providerStreamingBaseUrl: providerBaseUrl) { [weak self] resolvedVpcId in
            guard let self else { return }

            if !accountIdentifier.isEmpty {
                self.dataCache.loadPanelsAsync(
                    kind: cacheKind,
                    accountIdentifier: accountIdentifier,
                    vpcId: resolvedVpcId,
                    locale: locale,
                    maxAgeSeconds: Self.panelCacheFreshSeconds
                ) { [weak self] cachedPanels in
                    guard let self, let cachedPanels, !cachedPanels.isEmpty else { return }
                    self.dispatchPanel(completion, true, cachedPanels, "")
                }
            }

            let variables: NSDictionary = ["vpcId": resolvedVpcId, "locale": locale, "panelNames": panelNames]
            self.postGraphQL(operationName: operationName, queryHash: hash, variables: variables) { data, error in
                if !error.isEmpty {
                    self.dispatchPanel(completion, false, [], error)
                    return
                }
                guard let rawPanels = data?["panels"] as? [NSDictionary] else {
                    self.dispatchPanel(completion, false, [], missingMessage)
                    return
                }
                let panels = self.parsePanelResults(rawPanels)
                // Deliver parsed panels immediately so the home rails paint fast,
                // then redeliver once metadata enrichment completes so promo/sku
                // badges (Free, -XX%) appear on panel games too.
                self.dispatchPanel(completion, true, panels, "")
                self.enrichPanelResults(panels, vpcId: resolvedVpcId) { [weak self] enrichedPanels in
                    guard let self else { return }
                    if !accountIdentifier.isEmpty {
                        self.dataCache.savePanelsAsync(
                            kind: cacheKind,
                            accountIdentifier: accountIdentifier,
                            vpcId: resolvedVpcId,
                            locale: locale,
                            panels: enrichedPanels
                        )
                    }
                    self.dispatchPanel(completion, true, enrichedPanels, "")
                }
            }
        }
    }

    func enrichPanelResults(_ panels: [OPNPanelResult], vpcId: String, completion: @escaping @Sendable ([OPNPanelResult]) -> Void) {
        let games = panels.flatMap(\.sections).flatMap(\.games)
        guard !games.isEmpty else {
            completion(panels)
            return
        }
        enrichGames(games, vpcId: vpcId) { enrichedGames in
            var enrichedById: [String: OPNGameInfo] = [:]
            for game in enrichedGames {
                let key = game.uuid.isEmpty ? game.id : game.uuid
                if !key.isEmpty { enrichedById[key] = game }
            }
            let enrichedPanels = panels.map { panel in
                var outputPanel = panel
                outputPanel.sections = panel.sections.map { section in
                    var outputSection = section
                    outputSection.games = section.games.map { game in
                        enrichedById[game.uuid.isEmpty ? game.id : game.uuid] ?? game
                    }
                    return outputSection
                }
                return outputPanel
            }
            completion(enrichedPanels)
        }
    }

    func parsePanelResults(_ rawPanels: [NSDictionary]) -> [OPNPanelResult] {
        rawPanels.compactMap { panel in
            var result = OPNPanelResult()
            result.id = safeString(panel["id"]) ?? ""
            result.title = safeString(panel["name"]) ?? ""
            if result.id.isEmpty { result.id = result.title }
            result.typename = safeString(panel["__typename"]) ?? ""
            let sections = panel["sections"] as? [NSDictionary] ?? []
            result.sections = sections.compactMap { section in
                var panelSection = OPNPanelSection()
                panelSection.id = safeString(section["id"]) ?? ""
                panelSection.title = safeString(section["title"]) ?? ""
                panelSection.typename = safeString(section["__typename"]) ?? ""
                if let seeMoreInfo = section["seeMoreInfo"] as? NSDictionary {
                    panelSection.seeMoreFilterIds = safeStringArray(seeMoreInfo["filterIds"])
                    panelSection.seeMoreSortId = safeString(seeMoreInfo["sortOrderId"]) ?? ""
                    panelSection.seeMoreTitle = safeString(seeMoreInfo["title"]) ?? ""
                }
                let items = section["items"] as? [NSDictionary] ?? []
                panelSection.games = items.compactMap { item in
                    guard safeString(item["__typename"]) == "GameItem", let app = item["app"] as? NSDictionary else { return nil }
                    let game = parseGameItem(app)
                    return !game.id.isEmpty && !game.title.isEmpty && !game.variants.isEmpty ? game : nil
                }
                panelSection.tiles = items.compactMap(parsePanelTile)
                return panelSection.games.isEmpty && panelSection.tiles.isEmpty ? nil : panelSection
            }
            return result.sections.isEmpty ? nil : result
        }
    }

    func parsePanelTile(_ item: NSDictionary) -> OPNPanelTile? {
        let typename = safeString(item["__typename"]) ?? ""
        if typename == "FilterItem" {
            var tile = OPNPanelTile()
            tile.id = safeString(item["id"]) ?? ""
            tile.kind = "filter"
            tile.title = safeString(item["title"]) ?? ""
            tile.imageUrl = safeString(item["image"]) ?? ""
            tile.filterIds = safeStringArray(item["filterIds"])
            tile.sortId = safeString(item["sortOrderId"]) ?? ""
            return tile.id.isEmpty && tile.title.isEmpty ? nil : tile
        }
        if typename == "MarketingItem" {
            var tile = OPNPanelTile()
            tile.id = safeString(item["id"]) ?? ""
            tile.kind = "marketing"
            tile.title = safeString(item["title"]) ?? ""
            tile.subtitle = safeString(item["subTitle"]) ?? ""
            tile.body = safeString(item["body"]) ?? ""
            if let images = item["images"] as? NSDictionary {
                tile.imageUrl = firstLandscapeImageString(images).map { Self.optimizeImageURL($0, width: 900) } ?? ""
            }
            if let action = item["action"] as? NSDictionary {
                tile.actionUrl = safeString(action["uri"]) ?? safeString(action["url"]) ?? ""
                tile.actionLabel = safeString(action["label"]) ?? ""
            }
            return tile.id.isEmpty && tile.title.isEmpty ? nil : tile
        }
        return nil
    }
}
