//  The value coercion and payload shaping the CloudMatch session calls share, plus the claim
//  poll's retry context. Split out of OPNSessionManager.swift.
//

@preconcurrency import Foundation

final class OPNPollClaimSessionContext: @unchecked Sendable {
    let manager: OPNSessionManager
    let sessionId: String
    let base: String
    let token: String
    let deviceId: String
    let clientId: String
    let headers: CloudMatchClientHeaders
    let initialProfile: [String: Any]
    /// NVST cannot connect until the seat publishes its RTSPS control endpoint, so on that
    /// transport "ready" is not enough to stop polling.
    let requiresNvstControlEndpoint: Bool
    private let completion: (Bool, [String: Any], String) -> Void
    private let maxRetries = 60

    init(manager: OPNSessionManager, sessionId: String, base: String, token: String, deviceId: String, clientId: String, headers: CloudMatchClientHeaders, initialProfile: [String: Any], requiresNvstControlEndpoint: Bool, completion: @escaping (Bool, [String: Any], String) -> Void) {
        self.manager = manager
        self.sessionId = sessionId
        self.base = base
        self.token = token
        self.deviceId = deviceId
        self.clientId = clientId
        self.headers = headers
        self.initialProfile = initialProfile
        self.requiresNvstControlEndpoint = requiresNvstControlEndpoint
        self.completion = completion
    }

    func poll(attempt: Int) {
        guard attempt < maxRetries else {
            complete(false, [:], "Timeout polling for session ready")
            return
        }
        guard var request = CloudMatchRequestFactory.pollSessionRequest(baseURLString: base, sessionId: sessionId, accessToken: token, deviceId: deviceId, headers: headers) else {
            complete(false, [:], "Invalid poll claim URL")
            return
        }
        let networkStart = OPNNetworkLog.start(&request, operation: "cloudmatch.pollClaimSession")
        let tracedRequest = request
        OPNSessionProxySessionProvider.shared.controlPlaneURLSession(for: .session).dataTask(with: tracedRequest) { [self] data, response, error in
            OPNNetworkLog.finish(tracedRequest, operation: "cloudmatch.pollClaimSession", startedAt: networkStart, data: data, response: response, error: error)
            manager.pollClaimSessionRequestFinished(context: self, attempt: attempt, data: data, error: error)
        }.resume()
    }

    func retry(after delay: TimeInterval, attempt: Int) {
        Task { @MainActor [self] in
            try? await Task.sleep(for: .seconds(delay))
            poll(attempt: attempt)
        }
    }

    func complete(_ success: Bool, _ session: [String: Any], _ error: String) {
        completion(success, session, error)
    }
}

// MARK: - Payload shaping

// Instance members rather than file-scope functions: they are only meaningful to the
// session manager, and several of their names (`string`, `array`, `dictionary`) already
// exist elsewhere in the module.
extension OPNSessionManager {
    func settingsByApplyingCloudVariables(_ settings: [String: Any], capabilities: OPNStreamDeviceCapabilities) -> [String: Any] {
    let resolved = WebRTCMediaStreamSettingsResolver.resolve(
        profile: webRTCMediaProfile(from: settings),
        capabilities: webRTCMediaCapabilities(from: capabilities),
        cloudVariables: webRTCMediaCloudVariables(from: OPNStreamPreferences.loadCachedCloudVariables())
    )
    var result = settings
    result.merge(resolved.dictionary(gameLanguage: string(settings["gameLanguage"]), accountLinked: bool(settings["accountLinked"], fallback: true), selectedStore: string(settings["selectedStore"]))) { _, new in new }
    return result
    }

    func monitorSettings(_ settings: [String: Any], capabilities: OPNStreamDeviceCapabilities, hdrEnabled: Bool) -> [String: Any] {
    let resolution = requestedResolution(settings)
    let width = resolution.width
    let height = resolution.height
    return [
        "monitorId": 0,
        "positionX": 0,
        "positionY": 0,
        "widthInPixels": width,
        "heightInPixels": height,
        "framesPerSecond": int(settings["fps"], fallback: 60),
        "maxBitrateKbps": min(max(int(settings["maxBitrateMbps"], fallback: 50), 1), 1_000) * 1_000,
        "sdrHdrMode": hdrEnabled ? 1 : 0,
        "displayData": hdrEnabled && capabilities.hdrDisplaySupported ? ["desiredContentMaxLuminance": 1000, "desiredContentMinLuminance": 0, "desiredContentMaxFrameAverageLuminance": 400] : [:],
        "hdr10PlusGamingData": NSNull(),
        "dpi": max(0, capabilities.displayDpi),
    ]
    }

    func clientPhysicalResolutionMetadata(settings: [String: Any], capabilities: OPNStreamDeviceCapabilities) -> String {
    let resolution = requestedResolution(settings)
    let width = max(max(0, capabilities.maxDisplayWidth), resolution.width)
    let height = max(max(0, capabilities.maxDisplayHeight), resolution.height)
    return "{\"horizontalPixels\":\(width),\"verticalPixels\":\(height)}"
    }

    func requestedResolution(_ settings: [String: Any]) -> (width: Int, height: Int) {
    let parts = string(settings["resolution"]).split(separator: "x").compactMap { Int($0) }
    return (max(640, parts.first ?? 1920), max(360, parts.count > 1 ? parts[1] : 1080))
    }

    func requestedStreamingFeatures(_ settings: [String: Any], hdrEnabled: Bool) -> [String: Any] {
    let colorQuality = string(settings["colorQuality"])
    let bitDepth = colorQuality == "10bit_420" || colorQuality == "10bit_444" ? 1 : 0
    let chromaFormat = colorQuality == "8bit_444" || colorQuality == "10bit_444" ? 1 : 0
    let requestedMaxBitrateKbps = min(max(int(settings["maxBitrateMbps"], fallback: 50), 1), 1_000) * 1_000
    return [
        "maxBitrateKbps": requestedMaxBitrateKbps,
        "reflex": bool(settings["enableReflex"], fallback: true),
        "bitDepth": bitDepth,
        "cloudGsync": bool(settings["enableCloudGsync"]),
        "enabledL4S": bool(settings["enableL4S"]),
        "mouseMovementFlags": int(settings["mouseMovementFlags"]),
        "trueHdr": hdrEnabled,
        "supportedHidDevices": int(settings["supportedHidDevices"]),
        "profile": min(max(int(settings["streamingQualityProfile"]), 0), 4),
        "fallbackToLogicalResolution": bool(settings["fallbackToLogicalResolution"]),
        "hidDevices": NSNull(),
        "chromaFormat": chromaFormat,
        "prefilterMode": min(max(int(settings["prefilterMode"]), 0), 2),
        "prefilterSharpness": min(max(int(settings["prefilterSharpness"]), 0), 10),
        "prefilterNoiseReduction": min(max(int(settings["prefilterDenoise"]), 0), 10),
        "prefilterModel": max(int(settings["prefilterModel"]), 0),
        "hudStreamingMode": min(max(int(settings["hudStreamingMode"]), 0), 2),
        "sdrColorSpace": min(max(int(settings["sdrColorSpace"], fallback: 2), 0), 2),
        "hdrColorSpace": min(max(int(settings["hdrColorSpace"]), 0), 2),
    ]
    }

    func streamTransportMode(_ settings: [String: Any]) -> String {
    let value = string(settings["transportMode"])
    return value.caseInsensitiveCompare("nvst") == .orderedSame ? "nvst" : "webrtc"
    }

    func sessionClientPlatformName(_ transportMode: String) -> String {
    transportMode == "nvst" ? "windows" : "browser"
    }

    func sessionTransportPolicy(_ settings: [String: Any]) -> [String: Any]? {
    guard settings["transportPolicy"] != nil || settings["relayProtocol"] != nil || settings["relayLocation"] != nil else { return nil }
    var transport: [String: Any] = [
        "policy": min(max(int(settings["transportPolicy"], fallback: 2), 0), 2),
        "relayProtocol": min(max(int(settings["relayProtocol"]), 0), 2),
    ]
    if settings["relayLocation"] != nil {
        transport["relayLocation"] = min(max(int(settings["relayLocation"]), 0), 2)
    }
    return transport
    }

    func clientDisplayHdrCapabilities(_ capabilities: OPNStreamDeviceCapabilities) -> [String: Any] {
    [
        "hdrSupported": capabilities.hdrDisplaySupported,
        "bitDepth": capabilities.hdrDisplaySupported ? 10 : 8,
        "maxDisplayWidth": max(0, capabilities.maxDisplayWidth),
        "maxDisplayHeight": max(0, capabilities.maxDisplayHeight),
        "maxDisplayRefreshRate": max(0, capabilities.maxDisplayRefreshRate),
        "supportedHdrModes": capabilities.hdrDisplaySupported ? ["HDR"] : [],
    ]
    }

    func networkTestSessionIdValue(_ settings: [String: Any]) -> Any {
    let value = string(settings["networkTestSessionId"])
    return value.isEmpty ? NSNull() : value
    }

    func networkTypeValue(_ settings: [String: Any]) -> String {
    let value = string(settings["networkType"])
    return value.isEmpty ? "Unknown" : value
    }

    func networkLatencyValue(_ settings: [String: Any]) -> String {
    let latency = int(settings["networkLatencyMs"], fallback: -1)
    return latency >= 0 ? String(latency) : "Unknown"
    }

    func adActionCode(_ action: String) -> Int {
    switch action {
    case "start": 1
    case "pause": 2
    case "resume": 3
    case "finish": 4
    case "cancel": 5
    default: 0
    }
    }

    func extractHost(from value: String) -> String? {
    guard !value.isEmpty else { return nil }
    if let host = URL(string: value)?.host, !host.isEmpty { return host }
    for prefix in ["rtsps://", "rtsp://", "wss://", "https://"] where value.hasPrefix(prefix) {
        let remainder = String(value.dropFirst(prefix.count))
        let end = remainder.firstIndex(where: { $0 == ":" || $0 == "/" }) ?? remainder.endIndex
        let host = String(remainder[..<end])
        return host.isEmpty || host.hasPrefix(".") ? nil : host
    }
    return nil
    }

    func usableEndpointHost(_ host: String) -> String {
    let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
    let hostname = trimmed.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
    guard !trimmed.isEmpty, !hostname.isEmpty, !hostname.hasPrefix("."), !hostname.hasSuffix("."), !trimmed.contains("/") else { return "" }
    guard hostname.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty }) else { return "" }
    return trimmed
    }

    func isValidSessionId(_ sessionId: String) -> Bool {
    !sessionId.isEmpty && sessionId.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7f }
    }

    func escapedLogString(_ value: String) -> String {
    value.isEmpty ? "(empty)" : value
    }

    func dictionary(_ value: Any?) -> [String: Any] {
    value as? [String: Any] ?? [:]
    }

    func array(_ value: Any?) -> [Any] {
    value as? [Any] ?? []
    }

    func stringArray(_ value: Any?) -> [String] {
    if let value = value as? String { return value.isEmpty ? [] : [value] }
    if let value = value as? [String] { return value }
    if let value = value as? NSArray { return value.compactMap { string($0) }.filter { !$0.isEmpty } }
    return []
    }

    func string(_ value: Any?) -> String {
    if let value = value as? String { return value }
    if let value = value as? NSString { return value as String }
    if let value = value as? NSNumber { return value.stringValue }
    return ""
    }

    func int(_ value: Any?, fallback: Int = 0) -> Int {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? String { return Int(value) ?? fallback }
    return fallback
    }

    func double(_ value: Any?, fallback: Double = 0.0) -> Double {
    if let value = value as? Double { return value }
    if let value = value as? NSNumber { return value.doubleValue }
    if let value = value as? String { return Double(value) ?? fallback }
    return fallback
    }

    func bool(_ value: Any?, fallback: Bool = false) -> Bool {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    if let value = value as? String { return (value as NSString).boolValue }
    return fallback
    }

}

