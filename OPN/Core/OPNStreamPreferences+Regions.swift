//  Region selection and the cloud-variable / network-preflight payloads that inform it.
//  Split out of OPNStreamPreferences.swift.
//

import AppKit
import CoreAudio

extension OPNStreamPreferences {
    public static func loadSelectedRegionUrl() -> String {
        storage.string(forKey: k.selectedRegionUrl) ?? ""
    }

    public static func loadSelectedStreamingBaseUrl() -> String {
        let selected = loadSelectedRegionUrl()
        if !selected.isEmpty { return normalizedBaseUrl(selected) }
        return defaultStreamingBaseUrl
    }

    public static func loadSelectedRegionUrl(forGame appId: String) -> String {
        guard let dictionary = gameProfileDictionary(for: appId), bool(dictionary[k.gameProfileEnabled], false) else { return loadSelectedRegionUrl() }
        return normalizedHTTPSBaseUrlOrEmpty(string(dictionary[k.selectedRegionUrl], ""))
    }

    public static func loadSelectedStreamingBaseUrl(forGame appId: String) -> String {
        if let dictionary = gameProfileDictionary(for: appId), bool(dictionary[k.gameProfileEnabled], false) {
            let selected = string(dictionary[k.selectedRegionUrl], "")
            if !selected.isEmpty { return normalizedBaseUrl(selected) }
        }
        return loadSelectedStreamingBaseUrl()
    }

    public static func saveSelectedRegionUrl(_ url: String) {
        let normalized = normalizedHTTPSBaseUrlOrEmpty(url)
        if normalized.isEmpty { storage.removeObject(forKey: k.selectedRegionUrl) }
        else { storage.set(normalized, forKey: k.selectedRegionUrl) }
        storage.synchronize()
    }

    public static func loadCachedRegions() -> [OPNStreamRegionOption] {
        guard let items = storage.array(forKey: k.cachedRegions) as? [[String: Any]] else { return [] }
        let regions: [OPNStreamRegionOption] = items.compactMap { item -> OPNStreamRegionOption? in
            guard let name = item["name"] as? String, let url = item["url"] as? String, !name.isEmpty, !url.isEmpty else { return nil }
            let normalizedURL = normalizedHTTPSBaseUrlOrEmpty(url)
            guard !normalizedURL.isEmpty else { return nil }
            return OPNStreamRegionOption(name: name, url: normalizedURL, latencyMs: int(item["latencyMs"], -1))
        }
        return normalizedCachedRegions(regions)
    }

    public static func saveDetectedLocalRegionName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { storage.removeObject(forKey: k.detectedLocalRegionName) }
        else { storage.set(trimmed, forKey: k.detectedLocalRegionName) }
        storage.synchronize()
    }

    public static func loadDetectedLocalRegionName() -> String {
        storage.string(forKey: k.detectedLocalRegionName) ?? ""
    }

    /// The human region name for the endpoint a session was allocated on ("Japan"). CloudMatch
    /// hands out seat-zone hostnames ("np-tyo-01") that are DNS aliases of the region hostnames the
    /// region list carries ("ap-japan"), so a host match only works when the session stayed on the
    /// listed endpoint. Otherwise the region the app itself asked for is the answer: the selected
    /// region, or — on Automatic — the local region `serverInfo` detected.
    public static func regionName(forStreamingBaseUrl baseUrl: String) -> String {
        let regions = loadCachedRegions()
        if let host = URLComponents(string: normalizedBaseUrl(baseUrl))?.host,
           let matched = regions.first(where: { URLComponents(string: $0.url)?.host?.caseInsensitiveCompare(host) == .orderedSame }) {
            return matched.name
        }
        let selected = loadSelectedRegionUrl()
        if !selected.isEmpty, let chosen = cachedRegionChoice(regions: regions, selectedRegionUrl: selected) {
            return chosen.name
        }
        return loadDetectedLocalRegionName()
    }

    public static func saveCachedRegions(_ regions: [OPNStreamRegionOption]) {
        let items: [[String: Any]] = normalizedCachedRegions(regions).map { region in
            var item: [String: Any] = ["name": region.name, "url": region.url]
            if region.latencyMs >= 0 { item["latencyMs"] = region.latencyMs }
            return item
        }
        storage.set(items, forKey: k.cachedRegions)
        storage.synchronize()
    }

    public static func networkPreflightResult(from jsonText: String, seed: OPNStreamNetworkPreflightResult, requestedMaxBitrateMbps: Int) -> OPNStreamNetworkPreflightResult {
        guard let json = jsonValue(from: jsonText) else {
            var result = seed
            result.recommendedMaxBitrateMbps = recommendedBitrate(requestedMaxBitrateMbps: requestedMaxBitrateMbps, latencyMs: seed.latencyMs, packetLossPercent: seed.packetLossPercent, jitterMs: seed.jitterMs)
            return result
        }
        var result = seed
        if let sessionId = networkTestSessionId(from: json), !sessionId.isEmpty { result.networkTestSessionId = sessionId }
        if let testResult = successfulNetworkTestResult(from: json) {
            if let latency = firstRecursiveNumber(testResult, keys: ["latencyMs", "clientMeasuredLatencyMs", "rttMs", "roundTripTimeMs", "pingMs"]), latency.intValue >= 0 { result.latencyMs = latency.intValue }
            let bandwidthMbps = bitrateMbps(from: testResult, mbpsKeys: ["bandwidthMbps", "availableBandwidthMbps", "downloadBandwidthMbps", "measuredBandwidthMbps"], kbpsKeys: ["bandwidthKbps", "availableBandwidthKbps", "downloadBandwidthKbps", "measuredBandwidthKbps"])
            if bandwidthMbps > 0 { result.measuredBandwidthMbps = Double(bandwidthMbps) }
            let packetLoss = percent(from: testResult, keys: ["packetLossPercent", "packetLossPercentage", "packetLoss"])
            if packetLoss >= 0 { result.packetLossPercent = packetLoss }
            if let jitter = firstRecursiveNumber(testResult, keys: ["jitterMs", "jitter", "networkJitterMs"]), jitter.intValue >= 0 { result.jitterMs = jitter.intValue }
            if let maxPacketSize = firstRecursiveNumber(testResult, keys: ["maxPacketSize", "max_packet_size"]), maxPacketSize.intValue >= 512, maxPacketSize.intValue <= Int(UInt16.max) { result.maxPacketSize = maxPacketSize.intValue }
        }
        result.serverReportedWarning = firstRecursiveBool(json, keys: ["warning", "hasWarning", "shouldWarn", "networkWarning"], fallback: result.serverReportedWarning)
        result.continueRecommended = firstRecursiveBool(json, keys: ["continueRecommended", "shouldContinue", "continueAllowed"], fallback: result.continueRecommended)
        if firstRecursiveBool(json, keys: ["blockLaunch", "stopLaunch", "failLaunch"], fallback: false) { result.continueRecommended = false }
        if let warning = firstRecursiveString(json, keys: ["warningMessage", "warningDescription", "message", "statusDescription"]) { result.warningMessage = warning }
        result.recommendedMaxBitrateMbps = recommendedBitrate(requestedMaxBitrateMbps: requestedMaxBitrateMbps, latencyMs: result.latencyMs, packetLossPercent: result.packetLossPercent, jitterMs: result.jitterMs)
        return result
    }

    public static func cloudVariables(from jsonText: String) -> OPNStreamCloudVariables {
        var variables = OPNStreamCloudVariables()
        guard let json = jsonValue(from: jsonText) else { return variables }
        variables.fetched = true
        variables.allowH265 = cloudVariableBool(json, names: ["allowH265", "enableH265", "h265Enabled", "allowHevc", "enableHevc", "hevcEnabled"], fallback: variables.allowH265)
        variables.allowAV1 = cloudVariableBool(json, names: ["allowAV1", "enableAV1", "av1Enabled"], fallback: variables.allowAV1)
        variables.allowHDR = cloudVariableBool(json, names: ["allowHDR", "enableHDR", "hdrEnabled", "trueHdrEnabled", "enableTrueHdr"], fallback: variables.allowHDR)
        variables.allowL4S = cloudVariableBool(json, names: ["allowL4S", "enableL4S", "l4sEnabled"], fallback: variables.allowL4S)
        variables.allowReflex = cloudVariableBool(json, names: ["allowReflex", "enableReflex", "reflexEnabled"], fallback: variables.allowReflex)
        variables.allowPrefilter = cloudVariableBool(json, names: ["allowPrefilter", "enablePrefilter", "prefilterEnabled", "allowDLPrefiltering", "enableDLPrefiltering"], fallback: variables.allowPrefilter)
        variables.supportedPrefilterModes = cloudVariablePrefilterModes(json, names: ["SUPPORTED_DL_PREFILTERING", "supportedDLPrefiltering", "supportedPrefilterModes", "prefilterModes"])
        if let maxMbps = cloudVariableNumber(json, names: ["maxBitrateMbps", "maximumBitrateMbps", "streamMaxBitrateMbps"]), maxMbps.doubleValue > 0 { variables.maxBitrateMbps = max(1, Int(maxMbps.doubleValue.rounded(.down))) }
        else if let maxKbps = cloudVariableNumber(json, names: ["maxBitrateKbps", "maximumBitrateKbps", "streamMaxBitrateKbps"]), maxKbps.doubleValue > 0 { variables.maxBitrateMbps = max(1, Int((maxKbps.doubleValue / 1000.0).rounded(.down))) }
        if let refresh = cloudVariableNumber(json, names: ["refreshIntervalSeconds", "ttlSeconds", "cacheTtlSeconds"]), refresh.intValue > 0 { variables.refreshIntervalSeconds = max(60, min(refresh.intValue, 86_400)) }
        if let gpu = cloudVariableString(json, names: ["gpuName", "gpuType", "defaultGpuName", "preferredGpuName"]) { variables.gpuName = gpu }
        return variables
    }

    public static func loadCachedCloudVariables() -> OPNStreamCloudVariables {
        guard let json = storage.string(forKey: k.cachedCloudVariablesJSON), !json.isEmpty else { return OPNStreamCloudVariables() }
        var variables = cloudVariables(from: json)
        variables.fetched = variables.fetched && variables.refreshIntervalSeconds > 0
        return variables
    }

    public static func saveCachedCloudVariables(_ variables: OPNStreamCloudVariables, rawJSON: String) {
        guard variables.fetched, !rawJSON.isEmpty else { return }
        storage.set(rawJSON, forKey: k.cachedCloudVariablesJSON)
        storage.set(Date().timeIntervalSince1970, forKey: k.cachedCloudVariablesTimestamp)
        storage.synchronize()
    }

    public static func fetchCloudVariables(token: String, userId: String = "", idpId: String = "", completion: @escaping @MainActor @Sendable (OPNStreamCloudVariables) -> Void) {
        let cached = loadCachedCloudVariables()
        let cachedAt = storage.double(forKey: k.cachedCloudVariablesTimestamp)
        if cached.fetched, cachedAt > 0, Date().timeIntervalSince1970 - cachedAt < Double(cached.refreshIntervalSeconds) {
            Task { @MainActor in completion(cached) }
            return
        }
        guard var request = cloudVariablesRequest(token: token, locale: currentCloudVariablesLocale(), userId: userId, idpId: idpId) else {
            Task { @MainActor in completion(cached) }
            return
        }
        let networkStart = OPNNetworkLog.start(&request, operation: "stream.cloudVariables")
        let tracedRequest = request
        URLSession.shared.dataTask(with: tracedRequest) { data, response, error in
            OPNNetworkLog.finish(tracedRequest, operation: "stream.cloudVariables", startedAt: networkStart, data: data, response: response, error: error)
            var result = cached
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if error == nil, let data, (200..<300).contains(status), let json = String(data: data, encoding: .utf8) {
                OPNProtocolDebug.logJSONData(label: "cloudvariables/v3 response", data: data)
                let parsed = cloudVariables(from: json)
                if parsed.fetched {
                    result = parsed
                    saveCachedCloudVariables(result, rawJSON: json)
                }
            }
            Task { @MainActor in completion(result) }
        }.resume()
    }

    static func cloudVariablesRequest(token: String, locale: String, userId: String = "", idpId: String = "") -> URLRequest? {
        _ = token
        let configuration = GDNConfiguration(cloudVariablesURLString: "https://gx-target-experiments-frontend-api.gx.nvidia.com/cloudvariables/v3", userAgent: browserUserAgent())
        guard var request = GDNRequestFactory.cloudVariablesRequest(queryItems: cloudVariablesQueryItems(locale: locale, userId: userId, idpId: idpId), configuration: configuration, timeoutInterval: 4) else { return nil }
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    static func cloudVariablesQueryItems(locale: String, userId: String = "", idpId: String = "") -> [URLQueryItem] {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let language = locale.split(separator: "_").first.map(String.init) ?? "en"
        let clientParams = "{\"osName\":\"MACOS\",\"variant\":\"release\",\"userDefaultUILanguage\":\"\(language)\"}"
        return [
            URLQueryItem(name: "cvName", value: [
                "clientIMESupportedKBLayouts",
                "enableGpuNameMappingV2",
                "isBroadcastEnabled",
                "punctualUIConfig",
                "cvConfigOverrides",
                "enableBrowserPushNotification",
                "deeplinkSupportV2",
                "linuxNativeDownload",
                "clipboardPasteFeatureConfig",
                "steamosNativeDownload",
                "defaultKeyboardLayout",
                "enableBrowserIGSS",
                "isBrowserClientIMESupported",
                "OscConfig",
                "webRtcNetworkTestV2",
            ].joined(separator: ",")),
            URLQueryItem(name: "deviceId", value: OPNDeviceIdentity.stableCloudmatchDeviceId()),
            URLQueryItem(name: "userId", value: vendorIdentity(userId)),
            URLQueryItem(name: "idpId", value: vendorIdentity(idpId)),
            URLQueryItem(name: "clientId", value: "78589530426925203"),
            URLQueryItem(name: "clientVer", value: nvCloudVariablesClientVersion),
            URLQueryItem(name: "clientVariant", value: "Release"),
            URLQueryItem(name: "deviceOS", value: "MacOS"),
            URLQueryItem(name: "deviceType", value: "Desktop"),
            URLQueryItem(name: "deviceMake", value: "APPLE"),
            URLQueryItem(name: "deviceModel", value: "undefined"),
            URLQueryItem(name: "deviceOSVersion", value: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"),
            URLQueryItem(name: "clientType", value: "Browser"),
            URLQueryItem(name: "browserType", value: "Chrome"),
            URLQueryItem(name: "clientParams", value: clientParams),
        ]
    }

    static func vendorIdentity(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "undefined" : trimmed
    }

    static func currentCloudVariablesLocale() -> String {
        let identifier = Locale.current.identifier.replacingOccurrences(of: "-", with: "_")
        return identifier.isEmpty ? "en_US" : identifier
    }
}
