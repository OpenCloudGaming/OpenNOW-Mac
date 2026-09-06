import AppKit
import Foundation

extension OPNGameService {
    func fetchSubscriptionInfo(userId: String, completion: @escaping OPNSubscriptionCallback) {
        let token = accessToken
        guard !token.isEmpty else {
            dispatchSubscription(completion, false, OPNSubscriptionInfo(), "No access token")
            return
        }
        guard !userId.isEmpty else {
            dispatchSubscription(completion, false, OPNSubscriptionInfo(), "No user ID")
            return
        }

        resolveCatalogVpcId(token: token, providerStreamingBaseUrl: providerStreamingBaseURL()) { [weak self] resolvedVpcId in
            guard let self else { return }
            var components = URLComponents(string: "https://mes.geforcenow.com/v4/subscriptions")
            components?.queryItems = [
                URLQueryItem(name: "serviceName", value: "gfn_pc"),
                URLQueryItem(name: "languageCode", value: Self.currentGFNLocale()),
                URLQueryItem(name: "vpcId", value: resolvedVpcId == "GFN-PC" ? Self.defaultSubscriptionVpcId : resolvedVpcId),
                URLQueryItem(name: "userId", value: userId),
            ]
            guard let url = components?.url else {
                self.dispatchSubscription(completion, false, OPNSubscriptionInfo(), "Invalid subscription URL")
                return
            }
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.httpMethod = "GET"
            request.setValue("GFNJWT \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            Self.applyClientHeaders(to: &request, includeBrowserHeaders: false)
            let networkStart = OPNNetworkLog.start(&request, operation: "mes.subscriptions")
            let tracedRequest = request
            OPNSessionProxySessionProvider.shared.controlPlaneURLSession().dataTask(with: tracedRequest) { data, response, error in
                OPNNetworkLog.finish(tracedRequest, operation: "mes.subscriptions", startedAt: networkStart, data: data, response: response, error: error)
                Self.workQueue.async {
                    if let error {
                        self.dispatchSubscription(completion, false, OPNSubscriptionInfo(), error.localizedDescription)
                        return
                    }
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                    let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? NSDictionary
                    guard statusCode == 200, let json else {
                        self.dispatchSubscription(completion, false, OPNSubscriptionInfo(), "Subscription API failed (\(statusCode))")
                        return
                    }
                    self.dispatchSubscription(completion, true, self.parseSubscriptionInfo(json), "")
                }
            }.resume()
        }
    }

    func resolveStoreURL(game: OPNGameInfo, variantIndex: Int, completion: @escaping OPNStoreURLCallback) {
        if let localStoreURL = storeURLForKnownGame(game, variantIndex: variantIndex), !localStoreURL.isEmpty {
            dispatchStoreURL(completion, true, localStoreURL, "")
            return
        }
        let appId = game.uuid.isEmpty ? game.id : game.uuid
        guard !appId.isEmpty else {
            dispatchStoreURL(completion, false, "", "No app ID available for store URL lookup")
            return
        }
        guard !accessToken.isEmpty else {
            dispatchStoreURL(completion, false, "", "No access token")
            return
        }
        let selectedVariant = game.variants.indices.contains(variantIndex) ? game.variants[variantIndex] : nil
        resolveCatalogVpcId(token: accessToken, providerStreamingBaseUrl: providerStreamingBaseURL()) { [weak self] resolvedVpcId in
            guard let self else { return }
            self.fetchAppMetadata(appIds: [appId], vpcId: resolvedVpcId.isEmpty ? "GFN-PC" : resolvedVpcId) { data, error in
                if !error.isEmpty {
                    self.dispatchStoreURL(completion, false, "", error)
                    return
                }
                guard let items = (data?["apps"] as? NSDictionary)?["items"] as? [NSDictionary] else {
                    self.dispatchStoreURL(completion, false, "", "No app metadata in store URL response")
                    return
                }
                let metadataApp = items.first { self.safeString($0["id"]) == appId } ?? items.first
                guard let metadataApp else {
                    self.dispatchStoreURL(completion, false, "", "No matching app metadata for store URL lookup")
                    return
                }
                let metadataGame = self.parseGameItem(metadataApp)
                let storeURL = self.storeURLForMetadataGame(metadataGame, variantId: selectedVariant?.id ?? "", store: selectedVariant?.appStore ?? "")
                if storeURL.isEmpty {
                    self.dispatchStoreURL(completion, false, "", "No store URL found for selected variant")
                    return
                }
                self.dispatchStoreURL(completion, true, storeURL, "")
            }
        }
    }

    func fetchUserAccount(completion: @escaping OPNUserAccountCallback) {
        let query = """
        query GetUserAccount {
          userAccount {
            subscriptions { id }
            storesData { store accountLinkingData { userDisplayName expiresIn userIdentifier accountSyncingData { totalNumberOfSyncedGfnGames syncState syncDate } } }
          }
        }
        """
        postGraphQlJson(query: query, variables: [:] as NSDictionary) { [weak self] data, error in
            guard let self else { return }
            if !error.isEmpty {
                self.dispatchUserAccount(completion, false, OPNUserAccountInfo(), error)
                return
            }
            self.dispatchUserAccount(completion, true, self.parseUserAccountInfo(data), "")
        }
    }

    func fetchStoreDefinitions(completion: @escaping OPNStoreDefinitionsCallback) {
        let query = """
        query GetStoreDefinitions($locale: String!) {
          appStoreDefinitions(language: $locale) {
            store label sortOrder smallImageUrl largeImageUrl
            features {
              __typename
              ... on AccountLinkingSso { displayProposition supported }
              ... on AccountGamesSyncing { displayProposition supported }
              ... on AccountSubscriptions { displayProposition }
            }
            accountLinkingMetadata { supportedVariantIds isSupported isRequired label }
          }
        }
        """
        postGraphQlJson(query: query, variables: ["locale": Self.currentGFNCatalogLocale()] as NSDictionary) { [weak self] data, error in
            guard let self else { return }
            if !error.isEmpty {
                self.dispatchStoreDefinitions(completion, false, [], error)
                return
            }
            self.dispatchStoreDefinitions(completion, true, self.parseStoreDefinitions(data), "")
        }
    }

    func fetchSubscriptionDefinitions(completion: @escaping OPNSubscriptionDefinitionsCallback) {
        let query = """
        query GetSubscriptionDefinitions($locale: String!) {
          subscriptionDefinitions(language: $locale) { subscription label logoURL primaryStore }
        }
        """
        postGraphQlJson(query: query, variables: ["locale": Self.currentGFNCatalogLocale()] as NSDictionary) { [weak self] data, error in
            guard let self else { return }
            if !error.isEmpty {
                self.dispatchSubscriptionDefinitions(completion, false, [], error)
                return
            }
            self.dispatchSubscriptionDefinitions(completion, true, self.parseSubscriptionDefinitions(data), "")
        }
    }

    func parseUserAccountInfo(_ data: NSDictionary?) -> OPNUserAccountInfo {
        var info = OPNUserAccountInfo()
        guard let userAccount = data?["userAccount"] as? NSDictionary else { return info }
        info.subscriptions = (userAccount["subscriptions"] as? [NSDictionary] ?? []).compactMap { safeString($0["id"]) }.filter { !$0.isEmpty }
        for storeData in userAccount["storesData"] as? [NSDictionary] ?? [] {
            var storeInfo = OPNStoreAccountInfo()
            storeInfo.store = safeString(storeData["store"]) ?? ""
            if let linkingData = storeData["accountLinkingData"] as? NSDictionary {
                storeInfo.hasAccountLinkingData = true
                storeInfo.userDisplayName = safeString(linkingData["userDisplayName"]) ?? ""
                storeInfo.expiresIn = safeString(linkingData["expiresIn"]) ?? ""
                storeInfo.userIdentifier = safeString(linkingData["userIdentifier"]) ?? ""
                if let syncingData = linkingData["accountSyncingData"] as? NSDictionary {
                    storeInfo.hasAccountSyncingData = true
                    storeInfo.syncing.totalNumberOfSyncedGfnGames = safeInt(syncingData["totalNumberOfSyncedGfnGames"])
                    storeInfo.syncing.syncState = safeString(syncingData["syncState"]) ?? ""
                    storeInfo.syncing.syncDate = safeString(syncingData["syncDate"]) ?? ""
                }
            }
            if !storeInfo.store.isEmpty { info.stores.append(storeInfo) }
        }
        return info
    }

    func parseStoreDefinitions(_ data: NSDictionary?) -> [OPNStoreDefinition] {
        var definitions: [OPNStoreDefinition] = []
        for storeData in data?["appStoreDefinitions"] as? [NSDictionary] ?? [] {
            var definition = OPNStoreDefinition()
            definition.store = safeString(storeData["store"]) ?? ""
            definition.label = safeString(storeData["label"]) ?? ""
            definition.smallImageUrl = safeString(storeData["smallImageUrl"]) ?? ""
            definition.largeImageUrl = safeString(storeData["largeImageUrl"]) ?? ""
            definition.sortOrder = safeInt(storeData["sortOrder"])
            for featureData in storeData["features"] as? [NSDictionary] ?? [] {
                let feature = OPNStoreFeatureInfo(type: safeString(featureData["__typename"]) ?? "", displayProposition: safeString(featureData["displayProposition"]) ?? "", supported: safeBool(featureData["supported"]))
                if !feature.type.isEmpty { definition.features.append(feature) }
            }
            if let metadata = storeData["accountLinkingMetadata"] as? NSDictionary {
                definition.accountLinkingMetadata.supportedVariantIds = safeStringArray(metadata["supportedVariantIds"])
                definition.accountLinkingMetadata.isSupported = safeBool(metadata["isSupported"])
                definition.accountLinkingMetadata.isRequired = safeBool(metadata["isRequired"])
                definition.accountLinkingMetadata.label = safeString(metadata["label"]) ?? ""
            }
            if !definition.store.isEmpty { definitions.append(definition) }
        }
        return definitions.sorted { $0.sortOrder == $1.sortOrder ? $0.store < $1.store : $0.sortOrder < $1.sortOrder }
    }

    func parseSubscriptionDefinitions(_ data: NSDictionary?) -> [OPNSubscriptionDefinition] {
        (data?["subscriptionDefinitions"] as? [NSDictionary] ?? []).compactMap { item in
            var definition = OPNSubscriptionDefinition()
            definition.subscription = safeString(item["subscription"]) ?? ""
            definition.label = safeString(item["label"]) ?? ""
            definition.logoURL = safeString(item["logoURL"]) ?? ""
            definition.primaryStore = safeString(item["primaryStore"]) ?? ""
            return definition.subscription.isEmpty ? nil : definition
        }
    }

    func parseSubscriptionInfo(_ json: NSDictionary) -> OPNSubscriptionInfo {
        var info = OPNSubscriptionInfo()
        info.membershipTier = safeString(json["membershipTier"]).flatMap { $0.isEmpty ? nil : $0 } ?? "Free"
        info.subscriptionType = safeString(json["type"]) ?? ""
        info.subscriptionSubType = safeString(json["subType"]) ?? ""
        info.allottedHours = safeMinutesAsHours(json["allottedTimeInMinutes"])
        info.purchasedHours = safeMinutesAsHours(json["purchasedTimeInMinutes"])
        info.rolledOverHours = safeMinutesAsHours(json["rolledOverTimeInMinutes"])
        let fallbackTotal = info.allottedHours + info.purchasedHours + info.rolledOverHours
        info.totalHours = safeMinutesAsHours(json["totalTimeInMinutes"])
        if info.totalHours <= 0 { info.totalHours = fallbackTotal }
        info.remainingHours = safeMinutesAsHours(json["remainingTimeInMinutes"])
        info.usedHours = max(0, info.totalHours - info.remainingHours)
        info.isUnlimited = info.subscriptionSubType == "UNLIMITED"
        if let state = json["currentSubscriptionState"] as? NSDictionary {
            info.isGamePlayAllowed = state["isGamePlayAllowed"] as? Bool ?? true
        }
        info.entitledAudioChannelCount = entitledAudioChannelCount(features: json["features"])
        return info
    }

    /// The `SUPPORTED_AUDIO_FORMATS` feature as a channel count, using the official client's own
    /// mapping (`STEREO` 2, `UP_TO_5_1_SURROUND_PCM` 6, `UP_TO_7_1_SURROUND_PCM` 8). 0 when the
    /// feature is absent, so callers can tell "not entitled" from "not reported".
    func entitledAudioChannelCount(features: Any?) -> Int {
        guard let features = features as? [Any] else { return 0 }
        for case let feature as NSDictionary in features {
            guard (safeString(feature["key"]) ?? "").uppercased() == "SUPPORTED_AUDIO_FORMATS" else { continue }
            let value = (safeString(feature["textValue"]) ?? safeString(feature["value"]) ?? "").uppercased()
            if value.contains("7_1") { return 8 }
            if value.contains("5_1") { return 6 }
            return 2
        }
        return 0
    }

    func safeMinutesAsHours(_ value: Any?) -> Double {
        if let number = value as? NSNumber { return number.doubleValue / 60 }
        if let string = value as? String { return (Double(string) ?? 0) / 60 }
        return 0
    }

    func storeURLForKnownGame(_ game: OPNGameInfo, variantIndex: Int) -> String? {
        if game.variants.indices.contains(variantIndex), !game.variants[variantIndex].storeUrl.isEmpty { return game.variants[variantIndex].storeUrl }
        return game.variants.first { !$0.storeUrl.isEmpty }?.storeUrl
    }
}
