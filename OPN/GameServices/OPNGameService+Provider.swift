//
//  MacForceNow
//

import AppKit
import Foundation

extension OPNGameService {
    func fetchProviderInfo(idpId: String, completion: @escaping OPNProviderInfoCallback) {
        guard let url = URL(string: Self.providerServiceUrlsEndpoint) else {
            dispatchProviderInfo(completion, false, OPNGameProviderInfo(), OPNGameProviderEndpoint(), "Invalid provider info URL")
            return
        }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.gfnUserAgent, forHTTPHeaderField: "User-Agent")
        let networkStart = OPNNetworkLog.start(&request, operation: "provider.serviceUrls")
        let tracedRequest = request
        URLSession.shared.dataTask(with: tracedRequest) { [weak self] data, response, error in
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

    func getServerVpcId(token: String, providerStreamingBaseUrl: String, completion: @escaping @Sendable (String) -> Void) {
        let normalized = normalizeStreamingBaseUrl(providerStreamingBaseUrl)
        let cacheKey = "\(normalized)|\(token.hashValue)"
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

        let finish: @Sendable (String) -> Void = { vpcId in
            let resolved = vpcId.isEmpty ? "GFN-PC" : vpcId
            Self.vpcLock.lock()
            Self.vpcCache[cacheKey] = VpcCacheEntry(vpcId: resolved, timestamp: Date())
            let callbacks = Self.pendingVpcCallbacks.removeValue(forKey: cacheKey) ?? []
            Self.vpcLock.unlock()
            for callback in callbacks { callback(resolved) }
        }

        guard let url = URL(string: normalized + String(CloudMatch.Endpoint.serverInfo.path.dropFirst())) else {
            finish("GFN-PC")
            return
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("GFNJWT \(token)", forHTTPHeaderField: "Authorization")
        Self.applyClientHeaders(to: &request, includeBrowserHeaders: false)
        request.setValue(GFNClientMetadata.nativeWindowsUserAgent, forHTTPHeaderField: "User-Agent")
        let networkStart = OPNNetworkLog.start(&request, operation: "cloudmatch.serverInfo")
        let tracedRequest = request
        URLSession.shared.dataTask(with: tracedRequest) { data, response, error in
            OPNNetworkLog.finish(tracedRequest, operation: "cloudmatch.serverInfo", startedAt: networkStart, data: data, response: response, error: error)
            guard error == nil, let data, (response as? HTTPURLResponse)?.statusCode == 200 else {
                finish("GFN-PC")
                return
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let serverInfo = json.map(CloudMatchServerInfoParser.parse)
            let requestStatus = json?["requestStatus"] as? [String: Any]
            let serverId = requestStatus?["serverId"] as? String
            finish(serverInfo?.vpcId.isEmpty == false ? serverInfo?.vpcId ?? "GFN-PC" : serverId ?? "GFN-PC")
        }.resume()
    }
}
