//
//  MacForceNow
//

import AppKit
import Foundation

extension OPNGameService {
    // The service-urls document is global reference data, but it is looked up by both
    // the login provider picker and the catalog session setup, so a single launch
    // requested it twice (measured 1280ms + 1028ms). Memoized per idpId with in-flight
    // coalescing; the streaming base URL side effect is replayed on every hit.
    func fetchProviderInfo(idpId: String, completion: @escaping OPNProviderInfoCallback) {
        Self.referenceDataLock.lock()
        if let entry = Self.providerInfoCache[idpId], Date().timeIntervalSince(entry.timestamp) <= Self.referenceDataFreshSeconds {
            Self.referenceDataLock.unlock()
            let (info, endpoint) = entry.value
            providerStreamingBaseUrl = endpoint.streamingServiceUrl
            dispatchProviderInfo(completion, true, info, endpoint, "")
            return
        }
        if Self.pendingProviderInfoCallbacks[idpId] != nil {
            Self.pendingProviderInfoCallbacks[idpId]?.append(completion)
            Self.referenceDataLock.unlock()
            return
        }
        Self.pendingProviderInfoCallbacks[idpId] = [completion]
        Self.referenceDataLock.unlock()

        fetchProviderInfoUncached(idpId: idpId) { [weak self] success, info, endpoint, error in
            Self.referenceDataLock.lock()
            if success {
                Self.providerInfoCache[idpId] = ReferenceDataEntry(value: (info, endpoint), timestamp: Date())
            }
            let callbacks = Self.pendingProviderInfoCallbacks.removeValue(forKey: idpId) ?? []
            Self.referenceDataLock.unlock()
            guard let self else { return }
            for callback in callbacks {
                self.dispatchProviderInfo(callback, success, info, endpoint, error)
            }
        }
    }

    private func fetchProviderInfoUncached(idpId: String, completion: @escaping OPNProviderInfoCallback) {
        guard let url = URL(string: Self.providerServiceUrlsEndpoint) else {
            dispatchProviderInfo(completion, false, OPNGameProviderInfo(), OPNGameProviderEndpoint(), "Invalid provider info URL")
            return
        }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.gfnUserAgent, forHTTPHeaderField: "User-Agent")
        let networkStart = OPNNetworkLog.start(&request, operation: "provider.serviceUrls")
        let tracedRequest = request
        OPNSessionProxySessionProvider.shared.controlPlaneURLSession().dataTask(with: tracedRequest) { [weak self] data, response, error in
            OPNNetworkLog.finish(tracedRequest, operation: "provider.serviceUrls", startedAt: networkStart, data: data, response: response, error: error)
            guard let self else { return }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard error == nil, let data, statusCode == 200 else {
                var endpoint = OPNGameProviderEndpoint()
                endpoint.streamingServiceUrl = Self.defaultStreamingBaseUrl
                self.providerStreamingBaseUrl = endpoint.streamingServiceUrl
                self.dispatchProviderInfo(completion, false, OPNGameProviderInfo(), endpoint, error?.localizedDescription ?? "Provider info request failed")
                return
            }

            let json = (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary
            let info = self.parseGameProviderInfo(json)
            var endpoint = self.selectGameProviderEndpoint(info, idpId: idpId)
            if endpoint.streamingServiceUrl.isEmpty { endpoint.streamingServiceUrl = Self.defaultStreamingBaseUrl }
            self.providerStreamingBaseUrl = self.normalizeStreamingBaseUrl(endpoint.streamingServiceUrl)
            if self.providerStreamingBaseUrl.isEmpty { self.providerStreamingBaseUrl = Self.defaultStreamingBaseUrl }
            endpoint.streamingServiceUrl = self.providerStreamingBaseUrl
            self.dispatchProviderInfo(completion, true, info, endpoint, "")
        }.resume()
    }

    func parseGameProviderInfo(_ json: NSDictionary?) -> OPNGameProviderInfo {
        let raw = providerInfoDictionary(json)
        var info = OPNGameProviderInfo()
        guard let raw else { return info }
        info.defaultProvider = safeString(raw["defaultProvider"]) ?? ""
        info.loggedInProvider = safeString(raw["loggedInProvider"]) ?? ""
        info.loginRequired = safeBool(raw["loginRequired"])
        info.loginPreferredProviders = safeStringArray(raw["loginPreferredProviders"])
        let endpoints = raw["gfnServiceEndpoints"] as? [NSDictionary] ?? []
        for entry in endpoints {
            var endpoint = OPNGameProviderEndpoint()
            endpoint.loginProvider = safeString(entry["loginProvider"]) ?? ""
            endpoint.loginProviderCode = safeString(entry["loginProviderCode"]) ?? ""
            endpoint.loginProviderDisplayName = safeString(entry["loginProviderDisplayName"]) ?? ""
            endpoint.streamingServiceUrl = normalizeStreamingBaseUrl(safeString(entry["streamingServiceUrl"]) ?? "")
            endpoint.idpId = safeString(entry["idpId"]) ?? ""
            endpoint.redeemRedirectUrl = safeString(entry["redeemRedirectUrl"]) ?? ""
            endpoint.priority = safeInt(entry["loginProviderPriority"])
            if !endpoint.streamingServiceUrl.isEmpty { info.endpoints.append(endpoint) }
        }
        info.endpoints.sort { $0.priority < $1.priority }
        return info
    }

    func providerInfoDictionary(_ json: NSDictionary?) -> NSDictionary? {
        guard let json else { return nil }
        if let info = json["gfnServiceInfo"] as? NSDictionary { return info }
        if let data = json["data"] as? NSDictionary {
            if let info = data["gfnServiceInfo"] as? NSDictionary { return info }
            if let serviceUrls = data["serviceUrls"] as? NSDictionary, let info = serviceUrls["gfnServiceInfo"] as? NSDictionary { return info }
        }
        return json
    }

    func selectGameProviderEndpoint(_ info: OPNGameProviderInfo, idpId: String) -> OPNGameProviderEndpoint {
        if !idpId.isEmpty, let endpoint = info.endpoints.first(where: { $0.idpId == idpId }) { return endpoint }
        if !info.loggedInProvider.isEmpty, let endpoint = info.endpoints.first(where: { $0.loginProvider == info.loggedInProvider || $0.loginProviderCode == info.loggedInProvider }) { return endpoint }
        if !info.defaultProvider.isEmpty, let endpoint = info.endpoints.first(where: { $0.loginProvider == info.defaultProvider || $0.loginProviderCode == info.defaultProvider }) { return endpoint }
        if let endpoint = info.endpoints.first(where: { !$0.streamingServiceUrl.isEmpty }) { return endpoint }
        var fallback = OPNGameProviderEndpoint()
        fallback.loginProvider = info.defaultProvider
        fallback.streamingServiceUrl = Self.defaultStreamingBaseUrl
        return fallback
    }

    // The resolved vpcId only changes when the account moves region, so it is
    // persisted across launches: the panel disk cache is keyed by vpcId, so
    // without a stored value a cold launch cannot even read cached home rails
    // until the cloudmatch serverInfo round trip completes.
    static let persistedServerVpcIdKeyPrefix = "MacForceNow.Catalog.ServerVpcId."

    func persistedServerVpcIdKey(providerStreamingBaseUrl: String) -> String {
        Self.persistedServerVpcIdKeyPrefix + normalizeStreamingBaseUrl(providerStreamingBaseUrl)
    }

    func persistedServerVpcId(providerStreamingBaseUrl: String) -> String {
        OPNAppPreferenceStorage.standard.string(forKey: persistedServerVpcIdKey(providerStreamingBaseUrl: providerStreamingBaseUrl)) ?? ""
    }

    /// A vpcId usable immediately, without waiting on the network: the fresh
    /// in-memory entry when this process already resolved one, otherwise the
    /// value persisted by a previous launch. Empty when nothing is known yet.
    func optimisticServerVpcId(token: String, providerStreamingBaseUrl: String) -> String {
        let normalized = normalizeStreamingBaseUrl(providerStreamingBaseUrl)
        let cacheKey = "\(normalized)|\(token.hashValue)"
        Self.vpcLock.lock()
        let entry = Self.vpcCache[cacheKey]
        Self.vpcLock.unlock()
        if let entry, Date().timeIntervalSince(entry.timestamp) <= Self.serverVpcCacheFreshSeconds {
            return entry.vpcId
        }
        return persistedServerVpcId(providerStreamingBaseUrl: normalized)
    }

    /// The vpcId to use for catalog reads (library, favorites, account, patch
    /// status, browse). Answers immediately from the known value and refreshes it
    /// in the background, so only a first-ever launch waits on the network. The
    /// authoritative lookup still persists the correct value for the next launch,
    /// and `fetchPanels` refetches the home rails itself when it disagrees.
    func resolveCatalogVpcId(token: String, providerStreamingBaseUrl: String, completion: @escaping @Sendable (String) -> Void) {
        let optimistic = optimisticServerVpcId(token: token, providerStreamingBaseUrl: providerStreamingBaseUrl)
        guard !optimistic.isEmpty else {
            getServerVpcId(token: token, providerStreamingBaseUrl: providerStreamingBaseUrl, completion: completion)
            return
        }
        completion(optimistic)
        getServerVpcId(token: token, providerStreamingBaseUrl: providerStreamingBaseUrl) { resolved in
            guard resolved != optimistic else { return }
            Task { @MainActor in
                MacForceNowLog.warning(.catalog, "Catalog vpcId changed optimistic=\(optimistic) resolved=\(resolved)")
            }
        }
    }

    func getServerVpcId(token: String, providerStreamingBaseUrl: String, completion: @escaping @Sendable (String) -> Void) {
        let normalized = normalizeStreamingBaseUrl(providerStreamingBaseUrl)
        let cacheKey = "\(normalized)|\(token.hashValue)"
        let persistKey = persistedServerVpcIdKey(providerStreamingBaseUrl: normalized)
        Self.vpcLock.lock()
        if let entry = Self.vpcCache[cacheKey], Date().timeIntervalSince(entry.timestamp) <= Self.serverVpcCacheFreshSeconds {
            Self.vpcLock.unlock()
            completion(entry.vpcId)
            return
        }
        if Self.pendingVpcCallbacks[cacheKey] != nil {
            Self.pendingVpcCallbacks[cacheKey]?.append(completion)
            Self.vpcLock.unlock()
            return
        }
        Self.pendingVpcCallbacks[cacheKey] = [completion]
        Self.vpcLock.unlock()

        // `persist` is false for the fallback path so a failed request never
        // overwrites a good stored vpcId with the generic "GFN-PC" default.
        let finish: @Sendable (String, Bool) -> Void = { vpcId, persist in
            let resolved = vpcId.isEmpty ? "GFN-PC" : vpcId
            if persist {
                OPNAppPreferenceStorage.standard.set(resolved, forKey: persistKey)
            }
            Self.vpcLock.lock()
            Self.vpcCache[cacheKey] = VpcCacheEntry(vpcId: resolved, timestamp: Date())
            let callbacks = Self.pendingVpcCallbacks.removeValue(forKey: cacheKey) ?? []
            Self.vpcLock.unlock()
            for callback in callbacks { callback(resolved) }
        }

        guard let url = URL(string: normalized + String(CloudMatch.Endpoint.serverInfo.path.dropFirst())) else {
            finish("GFN-PC", false)
            return
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("GFNJWT \(token)", forHTTPHeaderField: "Authorization")
        Self.applyClientHeaders(to: &request, includeBrowserHeaders: false)
        request.setValue(GFNClientMetadata.nativeWindowsUserAgent, forHTTPHeaderField: "User-Agent")
        let networkStart = OPNNetworkLog.start(&request, operation: "cloudmatch.serverInfo")
        let tracedRequest = request
        OPNSessionProxySessionProvider.shared.controlPlaneURLSession().dataTask(with: tracedRequest) { data, response, error in
            OPNNetworkLog.finish(tracedRequest, operation: "cloudmatch.serverInfo", startedAt: networkStart, data: data, response: response, error: error)
            guard error == nil, let data, (response as? HTTPURLResponse)?.statusCode == 200 else {
                finish("GFN-PC", false)
                return
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let serverInfo = json.map(CloudMatchServerInfoParser.parse)
            let requestStatus = json?["requestStatus"] as? [String: Any]
            let serverId = requestStatus?["serverId"] as? String
            finish(serverInfo?.vpcId.isEmpty == false ? serverInfo?.vpcId ?? "GFN-PC" : serverId ?? "GFN-PC", true)
        }.resume()
    }
}
