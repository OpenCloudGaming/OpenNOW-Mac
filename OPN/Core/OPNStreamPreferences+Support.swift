//
//  OPNStreamPreferences+Support.swift
//  OpenNOW
//
//  Storage plumbing behind the preference store: game-profile dictionaries, region
//  measurement, JSON coercion and the defaults keys. Split out of OPNStreamPreferences.swift.
//

import AppKit
import CoreAudio
import CoreMedia
import Foundation
import VideoToolbox

extension OPNStreamPreferences {
    static func gameProfileDictionary(for appId: String) -> [String: Any]? {
        guard !appId.isEmpty, let profiles = storage.dictionary(forKey: k.gameProfiles) else { return nil }
        return profiles[appId] as? [String: Any]
    }

    static func mutableGameProfilesDictionary() -> [String: [String: Any]] {
        let profiles = storage.dictionary(forKey: k.gameProfiles) ?? [:]
        var result: [String: [String: Any]] = [:]
        for (key, value) in profiles {
            if let dictionary = value as? [String: Any] { result[key] = dictionary }
        }
        return result
    }

    static func normalizedHTTPSBaseUrlOrEmpty(_ url: String) -> String {
        guard !url.isEmpty, let components = URLComponents(string: url), components.scheme?.lowercased() == "https", components.host?.isEmpty == false else { return "" }
        return url.hasSuffix("/") ? url : url + "/"
    }

    static func normalizedBaseUrl(_ url: String) -> String {
        let normalized = normalizedHTTPSBaseUrlOrEmpty(url)
        return normalized.isEmpty ? defaultStreamingBaseUrl : normalized
    }

    static func cloudMatchRegionBaseUrl(address: String) -> String {
        let raw = address.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !raw.isEmpty else { return "" }
        let withScheme = raw.hasPrefix("https://") || raw.hasPrefix("http://") ? raw : "https://\(raw)"
        return normalizedHTTPSBaseUrlOrEmpty(withScheme)
    }

    static func normalizedCachedRegions(_ regions: [OPNStreamRegionOption]) -> [OPNStreamRegionOption] {
        var regionByUrl: [String: OPNStreamRegionOption] = [:]
        var urls: [String] = []
        for region in regions {
            guard !region.automatic, !region.name.isEmpty else { continue }
            let normalizedURL = normalizedHTTPSBaseUrlOrEmpty(region.url)
            guard !normalizedURL.isEmpty else { continue }
            let normalizedRegion = OPNStreamRegionOption(name: region.name, url: normalizedURL, latencyMs: region.latencyMs)
            if let existing = regionByUrl[normalizedURL] {
                if cachedRegion(normalizedRegion, isPreferredTo: existing) { regionByUrl[normalizedURL] = normalizedRegion }
            } else {
                regionByUrl[normalizedURL] = normalizedRegion
                urls.append(normalizedURL)
            }
        }
        return urls.compactMap { regionByUrl[$0] }
    }

    static func cachedRegion(_ candidate: OPNStreamRegionOption, isPreferredTo current: OPNStreamRegionOption) -> Bool {
        let candidateHasLatency = candidate.latencyMs >= 0
        let currentHasLatency = current.latencyMs >= 0
        if candidateHasLatency != currentHasLatency { return candidateHasLatency }
        if candidateHasLatency, currentHasLatency, candidate.latencyMs != current.latencyMs { return candidate.latencyMs < current.latencyMs }
        return candidate.name < current.name
    }

    static func browserUserAgent() -> String {
        GFNClientMetadata.browserMacUserAgent
    }

    static func serverInfoRequest(baseUrl: String, token: String, headers: CloudMatchClientHeaders? = nil) -> URLRequest {
        let requestHeaders = headers ?? CloudMatchClientHeaders.browserWebRTC(clientId: nvClientId, userAgent: browserUserAgent())
        var request = CloudMatchRequestFactory.serverInfoRequest(baseURLString: normalizedBaseUrl(baseUrl), accessToken: token, deviceId: OPNDeviceIdentity.stableCloudmatchDeviceId(), headers: requestHeaders, timeoutInterval: 4) ?? URLRequest(url: URL(string: defaultStreamingBaseUrl + String(CloudMatch.Endpoint.serverInfo.path.dropFirst()))!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    static func finishNetworkPreflight(_ seed: OPNStreamNetworkPreflightResult, token: String, providerStreamingBaseUrl: String, requestedMaxBitrateMbps: Int, completion: @escaping @MainActor @Sendable (OPNStreamNetworkPreflightResult) -> Void) {
        Task {
            var result = seed
            do {
                let baseURLString = networkTestBaseURL(seed: seed, providerStreamingBaseUrl: providerStreamingBaseUrl)
                let service = NetworkTestService(configuration: NetworkTestConfiguration(baseURLString: baseURLString, timeoutInterval: 8), transport: NetworkTestURLSessionTransport())
                let networkTest = try await service.startSession(accessToken: token)
                result = mergeNetworkTest(networkTest, into: result, requestedMaxBitrateMbps: requestedMaxBitrateMbps)
                OPNTelemetryRecorder.record(OPNTelemetryEvent(name: .networkTest, parameters: ["status": networkTest.rawStatus.isEmpty ? "completed" : networkTest.rawStatus, "continued": "true"]))
            } catch {
                OPNTelemetryRecorder.record(OPNTelemetryEvent(name: .networkTestException, parameters: ["error": error.localizedDescription, "continued": "true"]))
            }
            await MainActor.run { completion(result) }
        }
    }

    static func networkTestBaseURL(seed: OPNStreamNetworkPreflightResult, providerStreamingBaseUrl: String) -> String {
        let candidate = seed.streamingBaseUrl.isEmpty ? providerStreamingBaseUrl : seed.streamingBaseUrl
        let normalized = normalizedBaseUrl(candidate.isEmpty ? defaultStreamingBaseUrl : candidate)
        return normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized
    }

    static func mergeNetworkTest(_ networkTest: NetworkTestResult, into seed: OPNStreamNetworkPreflightResult, requestedMaxBitrateMbps: Int) -> OPNStreamNetworkPreflightResult {
        var result = seed
        if !networkTest.sessionId.isEmpty { result.networkTestSessionId = networkTest.sessionId }
        if networkTest.isCompleted {
            if networkTest.downlinkBandwidth > 0 { result.measuredBandwidthMbps = measuredBandwidthMbps(fromDownlinkBandwidth: networkTest.downlinkBandwidth) }
            if networkTest.latencyMilliseconds >= 0 { result.latencyMs = networkTest.latencyMilliseconds }
            if networkTest.jitterMilliseconds >= 0 { result.jitterMs = networkTest.jitterMilliseconds }
            if networkTest.maxPacketSize >= 512, networkTest.maxPacketSize <= Int(UInt16.max) { result.maxPacketSize = networkTest.maxPacketSize }
            if networkTest.packetLossPercent >= 0, networkTest.packetLossPercent.isFinite { result.packetLossPercent = networkTest.packetLossPercent }
        } else {
            result.serverReportedWarning = true
            result.warningMessage = networkTest.hasTestResult
                ? "Network test returned status \(networkTest.rawStatus). Launch will continue."
                : "Network test was provisioned; no completed measurement was returned. Launch will continue."
        }
        result.recommendedMaxBitrateMbps = recommendedBitrate(requestedMaxBitrateMbps: requestedMaxBitrateMbps, latencyMs: result.latencyMs, packetLossPercent: result.packetLossPercent, jitterMs: result.jitterMs)
        return result
    }

    static func measuredBandwidthMbps(fromDownlinkBandwidth downlinkBandwidth: Int) -> Double {
        Double(downlinkBandwidth) / 1_000_000.0
    }

    static func measureRegions(_ regions: [OPNStreamRegionOption], token: String, completion: @escaping @MainActor @Sendable ([OPNStreamRegionOption]) -> Void) {
        if regions.isEmpty {
            Task { @MainActor in completion([]) }
            return
        }
        let state = RegionMeasurementState(regions)
        let orderedIndices = prioritizedRegionMeasurementIndices(regions)
        Task.detached(priority: .utility) {
            let indexBox = RegionIndexBox(indices: orderedIndices)
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<min(maxConcurrentRegionMeasurements, orderedIndices.count) {
                    group.addTask {
                        while let index = indexBox.next() {
                            await measureRegionAsync(state: state, index: index, token: token, attempt: 0, bestLatencyMs: -1)
                        }
                    }
                }
            }
            await MainActor.run {
                let sorted = state.values.sorted {
                    if $0.latencyMs >= 0, $1.latencyMs >= 0, $0.latencyMs != $1.latencyMs { return $0.latencyMs < $1.latencyMs }
                    if $0.latencyMs >= 0, $1.latencyMs < 0 { return true }
                    if $0.latencyMs < 0, $1.latencyMs >= 0 { return false }
                    return $0.name < $1.name
                }
                saveCachedRegions(sorted)
                completion(sorted)
            }
        }
    }

    static func prioritizedRegionMeasurementIndices(_ regions: [OPNStreamRegionOption]) -> [Int] {
        let selectedRegionUrl = loadSelectedRegionUrl()
        let normalizedSelectedUrl = selectedRegionUrl.isEmpty ? "" : normalizedBaseUrl(selectedRegionUrl)
        let cachedLatencyByUrl = Dictionary(uniqueKeysWithValues: loadCachedRegions().map { (normalizedBaseUrl($0.url), $0.latencyMs) })
        return regions.indices.sorted { lhs, rhs in
            let left = regions[lhs]
            let right = regions[rhs]
            let leftSelected = !normalizedSelectedUrl.isEmpty && normalizedBaseUrl(left.url) == normalizedSelectedUrl
            let rightSelected = !normalizedSelectedUrl.isEmpty && normalizedBaseUrl(right.url) == normalizedSelectedUrl
            if leftSelected != rightSelected { return leftSelected }
            let leftLatency = cachedLatencyByUrl[normalizedBaseUrl(left.url)] ?? Int.max
            let rightLatency = cachedLatencyByUrl[normalizedBaseUrl(right.url)] ?? Int.max
            let leftHasLatency = leftLatency >= 0 && leftLatency < Int.max
            let rightHasLatency = rightLatency >= 0 && rightLatency < Int.max
            if leftHasLatency != rightHasLatency { return leftHasLatency }
            if leftLatency != rightLatency { return leftLatency < rightLatency }
            return left.name < right.name
        }
    }

    static func measureRegion(state: RegionMeasurementState, index: Int, token: String, attempt: Int, bestLatencyMs: Int, completion: @escaping @Sendable () -> Void) {
        let start = Date()
        let region = state.region(at: index)
        var request = serverInfoRequest(baseUrl: region.url, token: token)
        request.timeoutInterval = 4
        let networkStart = OPNNetworkLog.start(&request, operation: "stream.measureRegion")
        let tracedRequest = request
        URLSession.shared.dataTask(with: tracedRequest) { data, response, error in
            OPNNetworkLog.finish(tracedRequest, operation: "stream.measureRegion", startedAt: networkStart, data: data, response: response, error: error)
            var updatedBest = bestLatencyMs
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if error == nil, status >= 200, status < 500 {
                let measured = Int(Date().timeIntervalSince(start) * 1000.0)
                updatedBest = updatedBest < 0 ? measured : min(updatedBest, measured)
                state.setLatency(updatedBest, at: index)
            }
            if updatedBest >= 0, attempt + 1 < 2 {
                measureRegion(state: state, index: index, token: token, attempt: attempt + 1, bestLatencyMs: updatedBest, completion: completion)
                return
            }
            completion()
        }.resume()
    }

    static func measureRegionAsync(state: RegionMeasurementState, index: Int, token: String, attempt: Int, bestLatencyMs: Int) async {
        let start = Date()
        let region = state.region(at: index)
        var request = serverInfoRequest(baseUrl: region.url, token: token)
        request.timeoutInterval = 4
        let networkStart = OPNNetworkLog.start(&request, operation: "stream.measureRegion")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            OPNNetworkLog.finish(request, operation: "stream.measureRegion", startedAt: networkStart, data: data, response: response, error: nil)
            var updatedBest = bestLatencyMs
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status >= 200, status < 500 {
                let measured = Int(Date().timeIntervalSince(start) * 1000.0)
                updatedBest = updatedBest < 0 ? measured : min(updatedBest, measured)
                state.setLatency(updatedBest, at: index)
            }
            if updatedBest >= 0, attempt + 1 < 2 {
                await measureRegionAsync(state: state, index: index, token: token, attempt: attempt + 1, bestLatencyMs: updatedBest)
            }
        } catch {
            OPNNetworkLog.finish(request, operation: "stream.measureRegion", startedAt: networkStart, data: nil, response: nil, error: error)
        }
    }

    static func currentNetworkType() -> String {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return "Unknown" }
        defer { freeifaddrs(interfaces) }
        var hasWifi = false
        var hasWired = false
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let item = pointer?.pointee {
            defer { pointer = item.ifa_next }
            guard let namePointer = item.ifa_name else { continue }
            let flags = Int32(item.ifa_flags)
            if flags & IFF_UP == 0 || flags & IFF_RUNNING == 0 || flags & IFF_LOOPBACK != 0 { continue }
            let name = String(cString: namePointer)
            if name.hasPrefix("awdl") || name.hasPrefix("llw") || name.hasPrefix("utun") { continue }
            if name == "en0" || name == "en1" { hasWifi = true }
            else if name.hasPrefix("en") || name.hasPrefix("bridge") { hasWired = true }
        }
        if hasWired { return "Ethernet" }
        if hasWifi { return "WiFi" }
        return "Unknown"
    }

    static func cachedRegionChoice(regions: [OPNStreamRegionOption], selectedRegionUrl: String) -> OPNStreamRegionOption? {
        if !selectedRegionUrl.isEmpty {
            let normalizedSelected = normalizedBaseUrl(selectedRegionUrl)
            if let selected = regions.first(where: { !$0.url.isEmpty && normalizedBaseUrl($0.url) == normalizedSelected }) { return selected }
        }
        return regions.first { !$0.url.isEmpty && $0.latencyMs >= 0 }
    }

    static func jsonValue(from text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    static func firstRecursiveJSONValue(_ json: Any?, keys: [String]) -> Any? {
        if let dictionary = json as? [String: Any] {
            for key in keys where dictionary[key] != nil && !(dictionary[key] is NSNull) { return dictionary[key] }
            for value in dictionary.values {
                if let nested = firstRecursiveJSONValue(value, keys: keys) { return nested }
            }
        } else if let array = json as? [Any] {
            for value in array {
                if let nested = firstRecursiveJSONValue(value, keys: keys) { return nested }
            }
        }
        return nil
    }

    static func number(_ value: Any?) -> NSNumber? {
        if let number = value as? NSNumber { return number }
        if let string = value as? String, let double = Double(string), double.isFinite { return NSNumber(value: double) }
        return nil
    }

    static func jsonString(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func firstRecursiveNumber(_ json: Any?, keys: [String]) -> NSNumber? { number(firstRecursiveJSONValue(json, keys: keys)) }
    static func firstRecursiveString(_ json: Any?, keys: [String]) -> String? { jsonString(firstRecursiveJSONValue(json, keys: keys)).flatMap { $0.isEmpty ? nil : $0 } }
    static func firstRecursiveBool(_ json: Any?, keys: [String], fallback: Bool) -> Bool { jsonBool(firstRecursiveJSONValue(json, keys: keys), fallback) }

    static func jsonBool(_ value: Any?, _ fallback: Bool) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        guard let string = value as? String else { return fallback }
        switch string.lowercased() {
        case "true", "yes", "1", "enabled": return true
        case "false", "no", "0", "disabled": return false
        default: return fallback
        }
    }

    static func successfulNetworkTestResult(from json: Any?) -> [String: Any]? {
        guard let dictionary = json as? [String: Any] else { return nil }
        if let testResult = (dictionary["testResult"] ?? dictionary["test_result"]) as? [String: Any],
           let status = jsonString(testResult["status"]),
           ["COMPLETED", "SUCCESS"].contains(status.uppercased()) {
            return testResult
        }
        for key in ["data", "response", "networkTest"] {
            if let result = successfulNetworkTestResult(from: dictionary[key]) { return result }
        }
        return nil
    }

    static func cloudVariableValue(_ json: Any?, names: [String]) -> Any? {
        if let dictionary = json as? [String: Any] {
            let variableName = jsonString(dictionary["key"] ?? dictionary["name"] ?? dictionary["variableName"] ?? dictionary["id"])
            if let variableName, names.contains(where: { variableName.caseInsensitiveCompare($0) == .orderedSame }) {
                for key in ["value", "defaultValue", "currentValue", "setValue", "textValue"] where dictionary[key] != nil && !(dictionary[key] is NSNull) { return dictionary[key] }
            }
            for name in names where dictionary[name] != nil && !(dictionary[name] is NSNull) { return dictionary[name] }
            for value in dictionary.values {
                if let nested = cloudVariableValue(value, names: names) { return nested }
            }
        } else if let array = json as? [Any] {
            for value in array {
                if let nested = cloudVariableValue(value, names: names) { return nested }
            }
        }
        return nil
    }

    static func cloudVariableBool(_ json: Any?, names: [String], fallback: Bool) -> Bool { jsonBool(cloudVariableValue(json, names: names), fallback) }
    static func cloudVariableNumber(_ json: Any?, names: [String]) -> NSNumber? { number(cloudVariableValue(json, names: names)) }
    static func cloudVariableString(_ json: Any?, names: [String]) -> String? { jsonString(cloudVariableValue(json, names: names)).flatMap { $0.isEmpty ? nil : $0 } }

    static func cloudVariablePrefilterModes(_ json: Any?, names: [String]) -> [Int] {
        var modes: [Int] = []
        appendPrefilterModes(&modes, value: cloudVariableValue(json, names: names))
        return modes.sorted()
    }

    static func appendPrefilterModes(_ modes: inout [Int], value: Any?) {
        guard let value, !(value is NSNull) else { return }
        if let array = value as? [Any] {
            for entry in array { appendPrefilterModes(&modes, value: entry) }
            return
        }
        if let dictionary = value as? [String: Any] {
            let entitled = number(dictionary["isEntitled"] ?? dictionary["enabled"] ?? dictionary["supported"])
            if let entitled, !entitled.boolValue { return }
            appendUniquePrefilterMode(&modes, prefilterMode(from: dictionary["value"] ?? dictionary["mode"] ?? dictionary["id"] ?? dictionary["name"] ?? dictionary["entitlementValue"]))
            return
        }
        if let string = jsonString(value), string.hasPrefix("[") || string.hasPrefix("{"), let nested = jsonValue(from: string) {
            appendPrefilterModes(&modes, value: nested)
            return
        }
        if let string = jsonString(value), string.contains(",") {
            for part in string.components(separatedBy: ",") { appendUniquePrefilterMode(&modes, prefilterMode(from: part.trimmingCharacters(in: .whitespacesAndNewlines))) }
            return
        }
        appendUniquePrefilterMode(&modes, prefilterMode(from: value))
    }

    static func appendUniquePrefilterMode(_ modes: inout [Int], _ mode: Int) {
        guard mode >= 0, mode <= 2, !modes.contains(mode) else { return }
        modes.append(mode)
    }

    static func prefilterMode(from value: Any?) -> Int {
        if let number = number(value) {
            let mode = number.intValue
            return mode >= 0 && mode <= 2 ? mode : -1
        }
        guard let string = jsonString(value)?.lowercased() else { return -1 }
        if string == "off" || string == "disabled" { return 0 }
        if string == "auto" || string == "automatic" { return 1 }
        if string == "custom" { return 2 }
        return -1
    }

    static func bitrateMbps(from json: Any?, mbpsKeys: [String], kbpsKeys: [String]) -> Int {
        if let mbps = firstRecursiveNumber(json, keys: mbpsKeys), mbps.doubleValue > 0 { return max(1, Int(mbps.doubleValue.rounded(.down))) }
        if let kbps = firstRecursiveNumber(json, keys: kbpsKeys), kbps.doubleValue > 0 { return max(1, Int((kbps.doubleValue / 1000.0).rounded(.down))) }
        return 0
    }

    static func percent(from json: Any?, keys: [String]) -> Double {
        guard let value = firstRecursiveNumber(json, keys: keys) else { return -1 }
        var percent = value.doubleValue
        if percent >= 0, percent <= 1 { percent *= 100 }
        return percent >= 0 && percent.isFinite ? percent : -1
    }

    static func networkTestSessionId(from json: Any?) -> String? {
        guard let dictionary = json as? [String: Any] else { return nil }
        for key in ["networkTestSessionId", "networkSessionId", "sessionId", "id"] {
            if let value = jsonString(dictionary[key]), !value.isEmpty { return value }
        }
        for key in ["session", "networkTestSession", "data", "requestStatus"] {
            if let value = networkTestSessionId(from: dictionary[key]), !value.isEmpty { return value }
        }
        return nil
    }

    static func audioObjectString(_ objectId: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(objectId, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func clampedInt(_ dictionary: [String: Any]?, _ key: String, _ defaultValue: Int, _ upperBoundExclusive: Int) -> Int {
        let raw = dictionary?[key] ?? storedPreferenceValue(key)
        let stored = int(raw, defaultValue)
        return upperBoundExclusive <= 0 ? 0 : clamp(stored, 0, upperBoundExclusive - 1)
    }

    static func clampedDouble(_ dictionary: [String: Any]?, _ key: String, _ defaultValue: Double, _ minValue: Double, _ maxValue: Double) -> Double {
        let raw = dictionary?[key] ?? storedPreferenceValue(key)
        let stored = double(raw, defaultValue)
        return min(max(stored.isFinite ? stored : defaultValue, minValue), maxValue)
    }

    static func clampedStoredInt(_ key: String, _ defaultValue: Int, _ upperBoundExclusive: Int) -> Int { clampedInt(nil, key, defaultValue, upperBoundExclusive) }
    static func value(_ dictionary: [String: Any]?, _ key: String) -> Any? { dictionary?[key] ?? storedPreferenceValue(key) }
    static func int(_ value: Any?, _ defaultValue: Int) -> Int { (value as? NSNumber)?.intValue ?? value as? Int ?? defaultValue }
    static func double(_ value: Any?, _ defaultValue: Double) -> Double { (value as? NSNumber)?.doubleValue ?? value as? Double ?? defaultValue }
    static func bool(_ value: Any?, _ defaultValue: Bool) -> Bool { (value as? NSNumber)?.boolValue ?? value as? Bool ?? defaultValue }
    static func string(_ value: Any?, _ defaultValue: String) -> String { (value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? defaultValue }
    static func clamp(_ value: Int, _ lower: Int, _ upper: Int) -> Int { max(lower, min(value, upper)) }

    static func pushToTalkModifierBit(forKeyCode keyCode: Int) -> Int {
        switch keyCode {
        case 55: return 0x08
        case 56, 60: return 0x01
        case 57: return 0x10
        case 58, 61: return 0x04
        case 59, 62: return 0x02
        default: return 0
        }
    }

    static func sanitizedPushToTalkModifierMask(_ modifierMask: Int) -> Int { modifierMask & 0x1f }
    static func normalizedPushToTalkModifierMask(keyCode: Int, modifierMask: Int) -> Int { sanitizedPushToTalkModifierMask(modifierMask) | pushToTalkModifierBit(forKeyCode: keyCode) }

    static let keyLabels: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "Backspace", 53: "Escape", 55: "Left Command", 56: "Left Shift", 57: "Caps Lock", 58: "Left Option", 59: "Left Control", 60: "Right Shift", 61: "Right Option", 62: "Right Control", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1"
    ]

    enum Keys {
        static let aspectIndex = "OpenNOW.Stream.AspectIndex"
        static let resolutionIndex = "OpenNOW.Stream.ResolutionIndex"
        static let fpsIndex = "OpenNOW.Stream.FpsIndex"
        static let codecIndex = "OpenNOW.Stream.CodecIndex"
        static let bitrateIndex = "OpenNOW.Stream.BitrateIndex"
        static let colorQualityIndex = "OpenNOW.Stream.ColorQualityIndex"
        static let transportModeIndex = "OpenNOW.Stream.TransportModeIndex"
        static let streamingQualityProfileIndex = "OpenNOW.Stream.StreamingQualityProfileIndex"
        static let cloudGsyncEnabled = "OpenNOW.Stream.CloudGsyncEnabled"
        static let fallbackToLogicalResolution = "OpenNOW.Stream.FallbackToLogicalResolution"
        static let hudStreamingModeIndex = "OpenNOW.Stream.HudStreamingModeIndex"
        static let sdrColorSpaceIndex = "OpenNOW.Stream.SDRColorSpaceIndex"
        static let hdrColorSpaceIndex = "OpenNOW.Stream.HDRColorSpaceIndex"
        static let prefilterModeIndex = "OpenNOW.Stream.PrefilterModeIndex"
        static let prefilterSharpness = "OpenNOW.Stream.PrefilterSharpness"
        static let prefilterDenoise = "OpenNOW.Stream.PrefilterDenoise"
        static let upscalingModeIndex = "OpenNOW.Stream.UpscalingModeIndex"
        static let upscalingTargetIndex = "OpenNOW.Stream.UpscalingTargetIndex"
        static let upscalingSharpness = "OpenNOW.Stream.UpscalingSharpness"
        static let upscalingDenoise = "OpenNOW.Stream.UpscalingDenoise"
        static let pillarboxFillModeIndex = "OpenNOW.Stream.PillarboxFillModeIndex"
        static let pillarboxFillColor = "OpenNOW.Stream.PillarboxFillColor"
        static let pillarboxFillDim = "OpenNOW.Stream.PillarboxFillDim"
        static let recordingVideoBitrateMbps = "OpenNOW.Stream.RecordingVideoBitrateMbps"
        static let recordingAudioBitrateKbps = "OpenNOW.Stream.RecordingAudioBitrateKbps"
        static let recordingEnhancedVideoEnabled = "OpenNOW.Stream.RecordingEnhancedVideoEnabled"
        static let l4sEnabled = "OpenNOW.Stream.L4SEnabled"
        static let powerSaverEnabled = "OpenNOW.Stream.PowerSaverEnabled"
        static let suppressInputWhenInactive = "OpenNOW.Stream.SuppressInputWhenInactive"
        static let directMouseInput = "OpenNOW.Stream.DirectMouseInput"
        static let antiAFKMouseMovementEnabled = "OpenNOW.Stream.AntiAFKMouseMovementEnabled"
        static let preventDisplaySleepWhileStreaming = "OpenNOW.Stream.PreventDisplaySleepWhileStreaming"
        static let gameVolume = "OpenNOW.Stream.GameVolume"
        static let microphoneVolume = "OpenNOW.Stream.MicrophoneVolume"
        static let microphoneShortcutEnabled = "OpenNOW.Stream.MicrophoneShortcutEnabled"
        static let microphoneMode = "OpenNOW.Stream.MicrophoneMode"
        static let microphoneDeviceId = "OpenNOW.Stream.MicrophoneDeviceId"
        static let microphonePushToTalkKeyCode = "OpenNOW.Stream.MicrophonePushToTalkKeyCode"
        static let microphonePushToTalkModifierMask = "OpenNOW.Stream.MicrophonePushToTalkModifierMask"
        static let selectedRegionUrl = "OpenNOW.Stream.RegionUrl"
        static let cachedRegions = "OpenNOW.Stream.CachedRegions"
        static let detectedLocalRegionName = "OpenNOW.Stream.DetectedLocalRegionName"
        static let cachedCloudVariablesJSON = "OpenNOW.Stream.CloudVariablesJSON"
        static let cachedCloudVariablesTimestamp = "OpenNOW.Stream.CloudVariablesTimestamp"
        static let hdrEnabled = "OpenNOW.Stream.HDREnabled"
        static let gameProfiles = "OpenNOW.Stream.GameProfiles"
        static let gameProfileEnabled = "enabled"
    }
}
