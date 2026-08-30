//
//  OpenNOW
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
        let request = PanelFetchRequest(
            operationName: operationName,
            hash: hash,
            panelNames: panelNames,
            cacheKind: cacheKind,
            missingMessage: missingMessage,
            accountIdentifier: accountIdentifier,
            locale: locale
        )

        // The launch prefetch and the catalog view model can ask for the same panels at
        // once (and the vpcId correction below asks again), so identical requests join
        // one fetch instead of each paying for a 660KB response. A late joiner is
        // replayed whatever the fetch has delivered so far.
        let groupKey = "\(cacheKind)|\(accountIdentifier)|\(locale)"
        Self.panelFetchLock.lock()
        if let existing = Self.pendingPanelFetches[groupKey] {
            Self.panelFetchLock.unlock()
            let replayPanels = existing.addCompletion(completion)
            if !replayPanels.isEmpty {
                dispatchPanel(completion, true, replayPanels, "")
            }
            Task { @MainActor in
                OpenNOWLog.info(.catalog, "Panel fetch joined in-flight request kind=\(cacheKind) replayed=\(replayPanels.count)")
            }
            return
        }
        let group = PanelFetchGroup(completion: completion)
        Self.pendingPanelFetches[groupKey] = group
        Self.panelFetchLock.unlock()

        // Cold launch: start the cache read and the query straight away with the
        // vpcId this or a previous launch already resolved, instead of serializing
        // behind cloudmatch serverInfo. The authoritative lookup still runs and
        // repeats the fetch only when it disagrees.
        let optimisticVpcId = optimisticServerVpcId(token: accessToken, providerStreamingBaseUrl: providerBaseUrl)
        if !optimisticVpcId.isEmpty {
            startPanelFetch(vpcId: optimisticVpcId, request: request, group: group, groupKey: groupKey)
        }

        getServerVpcId(token: accessToken, providerStreamingBaseUrl: providerBaseUrl) { [weak self] resolvedVpcId in
            guard let self else { return }
            if resolvedVpcId != optimisticVpcId, !optimisticVpcId.isEmpty {
                Task { @MainActor in
                    OpenNOWLog.info(.catalog, "Panel vpcId corrected kind=\(cacheKind) optimistic=\(optimisticVpcId) resolved=\(resolvedVpcId)")
                }
            }
            self.startPanelFetch(vpcId: resolvedVpcId, request: request, group: group, groupKey: groupKey)
        }
    }

    struct PanelFetchRequest: Sendable {
        let operationName: String
        let hash: String
        let panelNames: [String]
        let cacheKind: String
        let missingMessage: String
        let accountIdentifier: String
        let locale: String
    }

    /// One logical panel fetch, shared by every caller that asked for the same panels.
    /// It can run for more than one vpcId (optimistic then authoritative) and delivers
    /// several times per run (disk cache, parsed response, enriched response), so it
    /// tracks outstanding runs rather than completing once.
    final class PanelFetchGroup: @unchecked Sendable {
        let lock = NSLock()
        private var completions: [OPNPanelCallback]
        private var latestPanels: [OPNPanelResult] = []
        private var startedVpcIds: Set<String> = []
        private var outstandingRuns = 0
        private var didDeliverNetworkPanels = false

        init(completion: @escaping OPNPanelCallback) {
            completions = [completion]
        }

        /// Registers another caller and returns what has already been delivered.
        func addCompletion(_ completion: @escaping OPNPanelCallback) -> [OPNPanelResult] {
            lock.lock()
            defer { lock.unlock() }
            completions.append(completion)
            return latestPanels
        }

        func beginRun(vpcId: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard startedVpcIds.insert(vpcId).inserted else { return false }
            outstandingRuns += 1
            return true
        }

        /// Returns true when no run is left, so the caller can retire the group.
        func endRun() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            outstandingRuns = max(outstandingRuns - 1, 0)
            return outstandingRuns == 0
        }

        func markNetworkPanelsDelivered() {
            lock.lock()
            didDeliverNetworkPanels = true
            lock.unlock()
        }

        var allowsCachedDelivery: Bool {
            lock.lock()
            defer { lock.unlock() }
            return !didDeliverNetworkPanels
        }

        func recipients(delivering panels: [OPNPanelResult]) -> [OPNPanelCallback] {
            lock.lock()
            defer { lock.unlock() }
            latestPanels = panels
            return completions
        }

        var errorRecipients: [OPNPanelCallback] {
            lock.lock()
            defer { lock.unlock() }
            return completions
        }
    }

    private func retirePanelFetchGroup(_ groupKey: String, group: PanelFetchGroup) {
        guard group.endRun() else { return }
        Self.panelFetchLock.lock()
        if Self.pendingPanelFetches[groupKey] === group {
            Self.pendingPanelFetches.removeValue(forKey: groupKey)
        }
        Self.panelFetchLock.unlock()
    }

    private func dispatchPanelGroup(_ group: PanelFetchGroup, panels: [OPNPanelResult]) {
        for completion in group.recipients(delivering: panels) {
            dispatchPanel(completion, true, panels, "")
        }
    }

    private func dispatchPanelGroupFailure(_ group: PanelFetchGroup, error: String) {
        for completion in group.errorRecipients {
            dispatchPanel(completion, false, [], error)
        }
    }

    private func startPanelFetch(vpcId: String, request: PanelFetchRequest, group: PanelFetchGroup, groupKey: String) {
        guard group.beginRun(vpcId: vpcId) else { return }

        if !request.accountIdentifier.isEmpty {
            dataCache.loadPanelsAsync(
                kind: request.cacheKind,
                accountIdentifier: request.accountIdentifier,
                vpcId: vpcId,
                locale: request.locale,
                maxAgeSeconds: Self.panelCacheFreshSeconds
            ) { [weak self] cachedPanels in
                guard let self, let cachedPanels, !cachedPanels.isEmpty, group.allowsCachedDelivery else { return }
                let sectionCount = cachedPanels.flatMap(\.sections).count
                Task { @MainActor in
                    OpenNOWLog.info(.catalog, "Panels served from cache kind=\(request.cacheKind) vpcId=\(vpcId) sections=\(sectionCount)")
                }
                self.dispatchPanelGroup(group, panels: cachedPanels)
            }
        }

        let variables: NSDictionary = ["vpcId": vpcId, "locale": request.locale, "panelNames": request.panelNames]
        postGraphQL(operationName: request.operationName, queryHash: request.hash, variables: variables) { [weak self] data, error in
            guard let self else { return }
            if !error.isEmpty {
                self.dispatchPanelGroupFailure(group, error: error)
                self.retirePanelFetchGroup(groupKey, group: group)
                return
            }
            guard let rawPanels = data?["panels"] as? [NSDictionary] else {
                self.dispatchPanelGroupFailure(group, error: request.missingMessage)
                self.retirePanelFetchGroup(groupKey, group: group)
                return
            }
            let panels = self.parsePanelResults(rawPanels)
            // Deliver parsed panels immediately so the home rails paint fast,
            // then redeliver once metadata enrichment completes so promo/sku
            // badges (Free, -XX%) appear on panel games too.
            group.markNetworkPanelsDelivered()
            self.dispatchPanelGroup(group, panels: panels)
            // Cache the parsed set right away: enrichment takes seconds (dozens of
            // metadata queries), so waiting for it means a launch the user cuts
            // short leaves nothing on disk for the next one to paint from.
            if !request.accountIdentifier.isEmpty {
                self.dataCache.savePanelsAsync(
                    kind: request.cacheKind,
                    accountIdentifier: request.accountIdentifier,
                    vpcId: vpcId,
                    locale: request.locale,
                    panels: panels
                )
            }
            self.enrichPanelResults(panels, vpcId: vpcId) { [weak self] enrichedPanels in
                guard let self else { return }
                if !request.accountIdentifier.isEmpty {
                    self.dataCache.savePanelsAsync(
                        kind: request.cacheKind,
                        accountIdentifier: request.accountIdentifier,
                        vpcId: vpcId,
                        locale: request.locale,
                        panels: enrichedPanels
                    )
                }
                self.dispatchPanelGroup(group, panels: enrichedPanels)
                self.retirePanelFetchGroup(groupKey, group: group)
            }
        }
    }

    /// Reads cached panels without needing a valid session: the cache key is
    /// account/vpc/locale only, so an expired-token launch can still paint the home
    /// rails while the token refresh runs.
    func loadCachedPanels(cacheKind: String, accountIdentifier: String, completion: @escaping @Sendable ([OPNPanelResult]?) -> Void) {
        let vpcId = persistedServerVpcId(providerStreamingBaseUrl: providerStreamingBaseURL())
        guard !vpcId.isEmpty, !accountIdentifier.isEmpty else {
            completion(nil)
            return
        }
        dataCache.loadPanelsAsync(
            kind: cacheKind,
            accountIdentifier: accountIdentifier,
            vpcId: vpcId,
            locale: Self.currentGFNCatalogLocale(),
            maxAgeSeconds: Self.panelCacheFreshSeconds,
            completion: completion
        )
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
