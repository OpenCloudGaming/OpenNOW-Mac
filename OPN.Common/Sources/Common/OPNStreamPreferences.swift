import AppKit
import CoreAudio
import CoreMedia
import Foundation
import OpenNOWTelemetry
import VideoToolbox

public struct OPNStreamAspectOption: Equatable, Sendable {
    public var label: String
    public var widthRatio: Int
    public var heightRatio: Int

    public init(label: String, widthRatio: Int, heightRatio: Int) {
        self.label = label
        self.widthRatio = widthRatio
        self.heightRatio = heightRatio
    }
}

public struct OPNStreamResolutionOption: Equatable, Sendable {
    public var width: Int
    public var height: Int

    public var value: String { "\(width)x\(height)" }
    public var label: String { "\(width) x \(height)" }

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct OPNStreamRegionOption: Equatable, Sendable {
    public var name: String
    public var url: String
    public var latencyMs: Int = -1
    public var automatic = false

    public var label: String {
        if automatic { return "Automatic" }
        if latencyMs >= 0 { return "\(name) (\(latencyMs) ms)" }
        return name
    }

    public init(name: String, url: String, latencyMs: Int = -1, automatic: Bool = false) {
        self.name = name
        self.url = url
        self.latencyMs = latencyMs
        self.automatic = automatic
    }
}

public struct OPNStreamCodecOption: Equatable, Sendable {
    public var label: String
    public var value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public struct OPNStreamBitrateOption: Equatable, Sendable {
    public var label: String
    public var mbps: Int

    public init(label: String, mbps: Int) {
        self.label = label
        self.mbps = mbps
    }
}

public struct OPNStreamColorQualityOption: Equatable, Sendable {
    public var label: String
    public var value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public struct OPNStreamPrefilterModeOption: Equatable, Sendable {
    public var label: String
    public var value: Int

    public init(label: String, value: Int) {
        self.label = label
        self.value = value
    }
}

public struct OPNStreamUpscalingModeOption: Equatable, Sendable {
    public var label: String
    public var value: Int

    public init(label: String, value: Int) {
        self.label = label
        self.value = value
    }
}

public struct OPNStreamUpscalingTargetOption: Equatable, Sendable {
    public var label: String
    public var height: Int

    public init(label: String, height: Int) {
        self.label = label
        self.height = height
    }
}

public struct OPNStreamMicrophoneModeOption: Equatable, Sendable {
    public var label: String
    public var value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public struct OPNStreamMicrophoneDeviceOption: Equatable, Sendable {
    public var label: String
    public var uniqueId: String
    public var automatic = false

    public init(label: String, uniqueId: String, automatic: Bool = false) {
        self.label = label
        self.uniqueId = uniqueId
        self.automatic = automatic
    }
}

public struct OPNStreamNetworkPreflightResult: Equatable, Sendable {
    public var streamingBaseUrl = ""
    public var networkTestSessionId = ""
    public var networkType = "Unknown"
    public var latencyMs = -1
    public var measuredBandwidthMbps = 0.0
    public var packetLossPercent = -1.0
    public var jitterMs = -1
    public var recommendedMaxBitrateMbps = 0
    public var serverReportedWarning = false
    public var continueRecommended = true
    public var usedAutomaticRegion = false
    public var warningMessage = ""

    public init() {}
}

public struct OPNStreamCloudVariables: Equatable, Sendable {
    public var fetched = false
    public var allowH265 = true
    public var allowAV1 = true
    public var allowHDR = true
    public var allowL4S = true
    public var allowReflex = true
    public var allowPrefilter = true
    public var maxBitrateMbps = 0
    public var maxSupportedPrefilterMode = 2
    public var supportedPrefilterModes: [Int] = []
    public var refreshIntervalSeconds = 3600
    public var gpuName = ""

    public init() {}
}

public struct OPNStreamDeviceCapabilities: Equatable, Sendable {
    public var h264HardwareDecodeSupported = true
    public var h265HardwareDecodeSupported = false
    public var av1HardwareDecodeSupported = false
    public var hdrDisplaySupported = false
    public var maxDisplayWidth = 0
    public var maxDisplayHeight = 0
    public var maxDisplayRefreshRate = 0
    public var displayDpi = 100

    public init() {}
}

public struct OPNStreamPreferenceProfile: Equatable, Sendable {
    public var aspectIndex = 1
    public var resolutionIndex = 2
    public var fpsIndex = 1
    public var codecIndex = 0
    public var bitrateIndex = 2
    public var colorQualityIndex = 0
    public var fps = 60
    public var maxBitrateMbps = 50
    public var prefilterModeIndex = 0
    public var prefilterMode = 0
    public var prefilterSharpness = 0
    public var prefilterDenoise = 0
    public var prefilterModel = 0
    public var upscalingModeIndex = 0
    public var upscalingMode = 0
    public var upscalingTargetIndex = 1
    public var upscalingTargetHeight = 2160
    public var upscalingSharpness = 4
    public var upscalingDenoise = 0
    public var recordingVideoBitrateMbps = 0
    public var recordingAudioBitrateKbps = 160
    public var recordingEnhancedVideoEnabled = true
    public var enableL4S = false
    public var enableHdr = false
    public var lowLatencyMode = false
    public var enablePowerSaver = false
    public var suppressInputWhenInactive = true
    public var directMouseInput = true
    public var gameVolume = 1.0
    public var microphoneVolume = 1.0
    public var microphoneMode = "disabled"
    public var microphoneDeviceId = ""
    public var microphonePushToTalkKeyCode = 9
    public var microphonePushToTalkModifierMask = 0
    public var microphonePushToTalkKeyLabel = "V"
    public var microphonePushToTalkComboLabel = "V"
    public var selectedRegionUrl = ""
    public var aspect = OPNStreamPreferences.aspectOptions[1]
    public var resolution = OPNStreamResolutionOption(width: 1920, height: 1200)
    public var codec = OPNStreamPreferences.codecOptions[0]
    public var bitrate = OPNStreamPreferences.bitrateOptions[2]
    public var colorQuality = OPNStreamPreferences.colorQualityOptions[0]
    public var prefilterModeOption = OPNStreamPreferences.prefilterModeOptions[0]
    public var upscalingModeOption = OPNStreamPreferences.upscalingModeOptions[0]
    public var upscalingTargetOption = OPNStreamPreferences.upscalingTargetOptions[1]

    public var aspectRatio: Double {
        aspect.heightRatio > 0 ? Double(aspect.widthRatio) / Double(aspect.heightRatio) : 16.0 / 9.0
    }

    public init() {}
}

public enum OPNStreamPreferences {
    private static let storage = OPNAppPreferenceStorage.standard

    public static let defaultStreamingBaseUrl = "https://prod.cloudmatchbeta.nvidiagrid.net/"
    public static let aspectOptions = [
        OPNStreamAspectOption(label: "16:9", widthRatio: 16, heightRatio: 9),
        OPNStreamAspectOption(label: "16:10", widthRatio: 16, heightRatio: 10),
        OPNStreamAspectOption(label: "21:9", widthRatio: 21, heightRatio: 9),
        OPNStreamAspectOption(label: "32:9", widthRatio: 32, heightRatio: 9)
    ]
    public static let fpsOptions = [30, 60, 120, 240]
    public static let codecOptions = [
        OPNStreamCodecOption(label: "H264  Low Latency", value: "H264"),
        OPNStreamCodecOption(label: "H265  Quality", value: "H265"),
        OPNStreamCodecOption(label: "AV1  CPU", value: "AV1"),
        OPNStreamCodecOption(label: "Auto", value: "auto")
    ]
    public static let bitrateOptions = [
        OPNStreamBitrateOption(label: "15 Mbps", mbps: 15),
        OPNStreamBitrateOption(label: "25 Mbps", mbps: 25),
        OPNStreamBitrateOption(label: "50 Mbps", mbps: 50),
        OPNStreamBitrateOption(label: "75 Mbps", mbps: 75),
        OPNStreamBitrateOption(label: "100 Mbps", mbps: 100)
    ]
    public static let colorQualityOptions = [
        OPNStreamColorQualityOption(label: "8-bit 4:2:0", value: "8bit_420"),
        OPNStreamColorQualityOption(label: "8-bit 4:4:4", value: "8bit_444"),
        OPNStreamColorQualityOption(label: "10-bit 4:2:0", value: "10bit_420"),
        OPNStreamColorQualityOption(label: "10-bit 4:4:4", value: "10bit_444")
    ]
    public static let prefilterModeOptions = [
        OPNStreamPrefilterModeOption(label: "Off", value: 0),
        OPNStreamPrefilterModeOption(label: "Auto", value: 1),
        OPNStreamPrefilterModeOption(label: "Custom", value: 2)
    ]
    public static let upscalingModeOptions = [
        OPNStreamUpscalingModeOption(label: "Off", value: 0),
        OPNStreamUpscalingModeOption(label: "Auto", value: 1),
        OPNStreamUpscalingModeOption(label: "Spatial", value: 2),
        OPNStreamUpscalingModeOption(label: "MetalFX", value: 3),
        OPNStreamUpscalingModeOption(label: "Temporal", value: 4)
    ]
    public static let upscalingTargetOptions = [
        OPNStreamUpscalingTargetOption(label: "2K", height: 1440),
        OPNStreamUpscalingTargetOption(label: "4K", height: 2160)
    ]
    public static let microphoneModeOptions = [
        OPNStreamMicrophoneModeOption(label: "Disabled", value: "disabled"),
        OPNStreamMicrophoneModeOption(label: "Push-to-Talk", value: "push-to-talk"),
        OPNStreamMicrophoneModeOption(label: "Open Mic", value: "voice-activity")
    ]

    private static let nvClientId = "ec7e38d4-03af-4b58-b131-cfb0495903ab"
    private static let nvClientVersion = "2.0.85.135"
    private static let defaultUpscalingTargetIndex = 1
    private static let maxConcurrentRegionMeasurements = 4
    private static let k = Keys.self
    private static let streamingProfileKeys = [
        Keys.aspectIndex,
        Keys.resolutionIndex,
        Keys.fpsIndex,
        Keys.codecIndex,
        Keys.bitrateIndex,
        Keys.colorQualityIndex,
        Keys.prefilterModeIndex,
        Keys.prefilterSharpness,
        Keys.prefilterDenoise,
        Keys.upscalingModeIndex,
        Keys.upscalingTargetIndex,
        Keys.upscalingSharpness,
        Keys.upscalingDenoise,
        Keys.recordingVideoBitrateMbps,
        Keys.recordingAudioBitrateKbps,
        Keys.recordingEnhancedVideoEnabled,
        Keys.l4sEnabled,
        Keys.hdrEnabled,
        Keys.lowLatencyModeEnabled,
        Keys.powerSaverEnabled,
        Keys.suppressInputWhenInactive,
        Keys.directMouseInput,
        Keys.gameVolume,
        Keys.microphoneVolume,
        Keys.microphoneShortcutEnabled,
        Keys.microphoneMode,
        Keys.microphoneDeviceId,
        Keys.microphonePushToTalkKeyCode,
        Keys.microphonePushToTalkModifierMask
    ]

    public static func resolutionOptions(forAspect aspectIndex: Int) -> [OPNStreamResolutionOption] {
        switch aspectIndex {
        case 0: return [(1280, 720), (1600, 900), (1920, 1080), (2560, 1440), (3840, 2160)].map(OPNStreamResolutionOption.init)
        case 1: return [(1280, 800), (1440, 900), (1680, 1050), (1920, 1200), (2560, 1600), (2880, 1800)].map(OPNStreamResolutionOption.init)
        case 2: return [(2560, 1080), (3440, 1440), (3840, 1600)].map(OPNStreamResolutionOption.init)
        case 3: return [(3840, 1080), (5120, 1440)].map(OPNStreamResolutionOption.init)
        default: return resolutionOptions(forAspect: 1)
        }
    }

    public static func loadMicrophoneDeviceOptions() -> [OPNStreamMicrophoneDeviceOption] {
        var devices = [OPNStreamMicrophoneDeviceOption(label: "Default Device", uniqueId: "", automatic: true)]
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr, dataSize > 0 else { return devices }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var audioDevices = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &audioDevices) == noErr else { return devices }

        for audioDevice in audioDevices {
            var streamAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var streamDataSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(audioDevice, &streamAddress, 0, nil, &streamDataSize) == noErr, streamDataSize > 0 else { continue }
            guard let name = audioObjectString(audioDevice, selector: kAudioObjectPropertyName) else { continue }
            let uid = audioObjectString(audioDevice, selector: kAudioDevicePropertyDeviceUID) ?? String(audioDevice)
            if !devices.contains(where: { $0.uniqueId == uid }) {
                devices.append(OPNStreamMicrophoneDeviceOption(label: name.isEmpty ? "Microphone" : name, uniqueId: uid))
            }
        }
        return devices
    }

    public static func loadDeviceCapabilities() -> OPNStreamDeviceCapabilities {
        var capabilities = OPNStreamDeviceCapabilities()
        capabilities.h264HardwareDecodeSupported = VTIsHardwareDecodeSupported(kCMVideoCodecType_H264)
        capabilities.h265HardwareDecodeSupported = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        if #available(macOS 14.0, *) {
            capabilities.av1HardwareDecodeSupported = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
        }

        guard let screen = NSScreen.main else { return capabilities }
        let scale = screen.backingScaleFactor > 0 ? screen.backingScaleFactor : 1.0
        capabilities.displayDpi = max(100, Int((100.0 * scale).rounded()))
        if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            let displayId = CGDirectDisplayID(screenNumber.uint32Value)
            let width = CGDisplayPixelsWide(displayId)
            let height = CGDisplayPixelsHigh(displayId)
            if width > 0, height > 0 {
                capabilities.maxDisplayWidth = width
                capabilities.maxDisplayHeight = height
            }
            if let mode = CGDisplayCopyDisplayMode(displayId) {
                let refreshRate = mode.refreshRate
                if refreshRate.isFinite, refreshRate > 0 { capabilities.maxDisplayRefreshRate = Int(refreshRate.rounded()) }
            }
        }
        if capabilities.maxDisplayWidth == 0 || capabilities.maxDisplayHeight == 0 {
            capabilities.maxDisplayWidth = Int((screen.frame.width * scale).rounded())
            capabilities.maxDisplayHeight = Int((screen.frame.height * scale).rounded())
        }
        capabilities.maxDisplayRefreshRate = max(capabilities.maxDisplayRefreshRate, screen.maximumFramesPerSecond)
        capabilities.hdrDisplaySupported = screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0
        return capabilities
    }

    public static func codecSupported(_ codec: OPNStreamCodecOption, capabilities: OPNStreamDeviceCapabilities) -> Bool {
        switch (codec.value.isEmpty ? "H264" : codec.value).uppercased() {
        case "AUTO", "H264": return true
        case "H265", "HEVC": return capabilities.h265HardwareDecodeSupported
        case "AV1": return capabilities.av1HardwareDecodeSupported
        default: return false
        }
    }

    public static func fpsSupported(_ fps: Int, capabilities: OPNStreamDeviceCapabilities) -> Bool {
        if fps <= 60 { return true }
        if capabilities.maxDisplayRefreshRate <= 0 { return true }
        return fps <= max(60, capabilities.maxDisplayRefreshRate)
    }

    public static func colorQualitySupported(_ colorQuality: OPNStreamColorQualityOption, codec: OPNStreamCodecOption, capabilities: OPNStreamDeviceCapabilities) -> Bool {
        guard codecSupported(codec, capabilities: capabilities) else { return false }
        if !colorQuality.value.uppercased().hasPrefix("10BIT") { return true }
        switch (codec.value.isEmpty ? "H264" : codec.value).uppercased() {
        case "H265", "HEVC": return capabilities.h265HardwareDecodeSupported
        case "AV1": return capabilities.av1HardwareDecodeSupported
        case "AUTO": return capabilities.h265HardwareDecodeSupported || capabilities.av1HardwareDecodeSupported
        default: return false
        }
    }

    public static func effectiveProfile(_ profile: OPNStreamPreferenceProfile, capabilities: OPNStreamDeviceCapabilities) -> OPNStreamPreferenceProfile {
        var result = profile
        if result.codecIndex < 0 || result.codecIndex >= codecOptions.count || !codecSupported(result.codec, capabilities: capabilities) {
            result.codecIndex = firstSupportedCodecIndex(capabilities)
            result.codec = codecOptions[result.codecIndex]
        }
        if !fpsSupported(result.fps, capabilities: capabilities) {
            result.fpsIndex = nearestSupportedFpsIndex(result.fps, capabilities)
            result.fps = fpsOptions[result.fpsIndex]
        }
        if result.colorQualityIndex < 0 || result.colorQualityIndex >= colorQualityOptions.count || !colorQualitySupported(result.colorQuality, codec: result.codec, capabilities: capabilities) {
            result.colorQualityIndex = 0
            result.colorQuality = colorQualityOptions[0]
        }
        return result
    }

    public static func resolveCodec(profile: OPNStreamPreferenceProfile, resolution: OPNStreamResolutionOption, capabilities: OPNStreamDeviceCapabilities, libWebRTCAvailable: Bool) -> String {
        let requested = (profile.codec.value.isEmpty ? "H264" : profile.codec.value).uppercased()
        if requested != "AUTO" { return codecSupported(profile.codec, capabilities: capabilities) ? requested : "H264" }
        if !libWebRTCAvailable { return "H264" }
        let pixels = max(1, resolution.width) * max(1, resolution.height)
        let prefersTenBit = profile.colorQuality.value.hasPrefix("10bit")
        let prefersHighResolution = pixels >= 2560 * 1440
        let prefersVeryHighResolution = pixels >= 3840 * 2160
        let highFps = profile.fps >= 144
        if !highFps, prefersVeryHighResolution, capabilities.av1HardwareDecodeSupported { return "AV1" }
        if !highFps, (prefersTenBit || prefersHighResolution || profile.maxBitrateMbps >= 75), capabilities.h265HardwareDecodeSupported { return "H265" }
        return "H264"
    }

    public static func loadProfile() -> OPNStreamPreferenceProfile {
        profile(from: nil)
    }

    public static func loadProfile(forGame appId: String) -> OPNStreamPreferenceProfile? {
        guard let dictionary = gameProfileDictionary(for: appId), bool(dictionary[k.gameProfileEnabled], false) else { return nil }
        return profile(from: dictionary)
    }

    public static func saveProfile(forGame appId: String, profile: OPNStreamPreferenceProfile) {
        guard !appId.isEmpty else { return }
        var profiles = mutableGameProfilesDictionary()
        profiles[appId] = dictionary(from: profile, enabled: true)
        storage.set(profiles, forKey: k.gameProfiles)
        storage.synchronize()
    }

    public static func deleteProfile(forGame appId: String) {
        guard !appId.isEmpty else { return }
        var profiles = mutableGameProfilesDictionary()
        profiles.removeValue(forKey: appId)
        storage.set(profiles, forKey: k.gameProfiles)
        storage.synchronize()
    }

    public static func profileExists(forGame appId: String) -> Bool {
        gameProfileDictionary(for: appId) != nil
    }

    public static func profileEnabled(forGame appId: String) -> Bool {
        guard let dictionary = gameProfileDictionary(for: appId) else { return false }
        return bool(dictionary[k.gameProfileEnabled], false)
    }

    public static func setProfileEnabled(forGame appId: String, enabled: Bool) {
        guard !appId.isEmpty, var profile = gameProfileDictionary(for: appId) else { return }
        profile[k.gameProfileEnabled] = enabled
        var profiles = mutableGameProfilesDictionary()
        profiles[appId] = profile
        storage.set(profiles, forKey: k.gameProfiles)
        storage.synchronize()
    }

    public static func recommendedBitrate(requestedMaxBitrateMbps: Int, latencyMs: Int, measuredBandwidthMbps: Double, packetLossPercent: Double, jitterMs: Int) -> Int {
        let requested = max(1, requestedMaxBitrateMbps)
        var recommended = requested
        if measuredBandwidthMbps > 1.0, measuredBandwidthMbps.isFinite {
            recommended = min(recommended, max(5, Int((measuredBandwidthMbps * 0.85).rounded(.down))))
        }
        if packetLossPercent >= 5.0 { recommended = min(recommended, 15) }
        else if packetLossPercent >= 2.0 { recommended = min(recommended, 25) }
        else if packetLossPercent >= 1.0 { recommended = min(recommended, 50) }
        if jitterMs >= 50 { recommended = min(recommended, 25) }
        else if jitterMs >= 30 { recommended = min(recommended, 50) }
        if latencyMs < 0 { return recommended }
        if latencyMs >= 120 { return min(recommended, 25) }
        if latencyMs >= 85 { return min(recommended, 50) }
        if latencyMs >= 60 { return min(recommended, 75) }
        return recommended
    }

    public static func loadSelectedRegionUrl() -> String {
        storage.string(forKey: k.selectedRegionUrl) ?? ""
    }

    public static func loadSelectedStreamingBaseUrl() -> String {
        let selected = loadSelectedRegionUrl()
        if !selected.isEmpty { return normalizedBaseUrl(selected) }
        let best = loadCachedRegions().first { !$0.url.isEmpty && $0.latencyMs >= 0 }
        return best.map { normalizedBaseUrl($0.url) } ?? defaultStreamingBaseUrl
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
        return items.compactMap { item in
            guard let name = item["name"] as? String, let url = item["url"] as? String, !name.isEmpty, !url.isEmpty else { return nil }
            let normalizedURL = normalizedHTTPSBaseUrlOrEmpty(url)
            guard !normalizedURL.isEmpty else { return nil }
            return OPNStreamRegionOption(name: name, url: normalizedURL, latencyMs: int(item["latencyMs"], -1))
        }
    }

    public static func saveCachedRegions(_ regions: [OPNStreamRegionOption]) {
        let items: [[String: Any]] = regions.compactMap { region in
            guard !region.automatic, !region.name.isEmpty, !region.url.isEmpty else { return nil }
            let normalizedURL = normalizedHTTPSBaseUrlOrEmpty(region.url)
            guard !normalizedURL.isEmpty else { return nil }
            var item: [String: Any] = ["name": region.name, "url": normalizedURL]
            if region.latencyMs >= 0 { item["latencyMs"] = region.latencyMs }
            return item
        }
        storage.set(items, forKey: k.cachedRegions)
        storage.synchronize()
    }

    public static func networkPreflightResult(from jsonText: String, seed: OPNStreamNetworkPreflightResult, requestedMaxBitrateMbps: Int) -> OPNStreamNetworkPreflightResult {
        guard let json = jsonValue(from: jsonText) else {
            var result = seed
            result.recommendedMaxBitrateMbps = recommendedBitrate(requestedMaxBitrateMbps: requestedMaxBitrateMbps, latencyMs: seed.latencyMs, measuredBandwidthMbps: seed.measuredBandwidthMbps, packetLossPercent: seed.packetLossPercent, jitterMs: seed.jitterMs)
            return result
        }
        var result = seed
        if let sessionId = networkTestSessionId(from: json), !sessionId.isEmpty { result.networkTestSessionId = sessionId }
        if let latency = firstRecursiveNumber(json, keys: ["latencyMs", "clientMeasuredLatencyMs", "rttMs", "roundTripTimeMs", "pingMs"]), latency.intValue >= 0 { result.latencyMs = latency.intValue }
        let bandwidthMbps = bitrateMbps(from: json, mbpsKeys: ["bandwidthMbps", "availableBandwidthMbps", "downloadBandwidthMbps", "measuredBandwidthMbps"], kbpsKeys: ["bandwidthKbps", "availableBandwidthKbps", "downloadBandwidthKbps", "measuredBandwidthKbps"])
        if bandwidthMbps > 0 { result.measuredBandwidthMbps = Double(bandwidthMbps) }
        let packetLoss = percent(from: json, keys: ["packetLossPercent", "packetLossPercentage", "packetLoss"])
        if packetLoss >= 0 { result.packetLossPercent = packetLoss }
        if let jitter = firstRecursiveNumber(json, keys: ["jitterMs", "jitter", "networkJitterMs"]), jitter.intValue >= 0 { result.jitterMs = jitter.intValue }
        result.serverReportedWarning = firstRecursiveBool(json, keys: ["warning", "hasWarning", "shouldWarn", "networkWarning"], fallback: result.serverReportedWarning)
        result.continueRecommended = firstRecursiveBool(json, keys: ["continueRecommended", "shouldContinue", "continueAllowed"], fallback: result.continueRecommended)
        if firstRecursiveBool(json, keys: ["blockLaunch", "stopLaunch", "failLaunch"], fallback: false) { result.continueRecommended = false }
        if let warning = firstRecursiveString(json, keys: ["warningMessage", "warningDescription", "message", "statusDescription"]) { result.warningMessage = warning }
        let serverRecommended = bitrateMbps(from: json, mbpsKeys: ["recommendedMaxBitrateMbps", "recommendedBitrateMbps", "maxRecommendedBitrateMbps"], kbpsKeys: ["recommendedMaxBitrateKbps", "recommendedBitrateKbps", "maxRecommendedBitrateKbps"])
        let measuredRecommended = recommendedBitrate(requestedMaxBitrateMbps: requestedMaxBitrateMbps, latencyMs: result.latencyMs, measuredBandwidthMbps: result.measuredBandwidthMbps, packetLossPercent: result.packetLossPercent, jitterMs: result.jitterMs)
        result.recommendedMaxBitrateMbps = serverRecommended > 0 ? min(measuredRecommended, serverRecommended) : measuredRecommended
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

    public static func fetchCloudVariables(token: String, completion: @escaping @Sendable (OPNStreamCloudVariables) -> Void) {
        let cached = loadCachedCloudVariables()
        let cachedAt = storage.double(forKey: k.cachedCloudVariablesTimestamp)
        if cached.fetched, cachedAt > 0, Date().timeIntervalSince1970 - cachedAt < Double(cached.refreshIntervalSeconds) {
            DispatchQueue.main.async { completion(cached) }
            return
        }
        guard var request = cloudVariablesRequest(token: token, locale: currentCloudVariablesLocale()) else {
            DispatchQueue.main.async { completion(cached) }
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
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    static func cloudVariablesRequest(token: String, locale: String) -> URLRequest? {
        _ = token
        var components = URLComponents(string: "https://gx-target-experiments-frontend-api.gx.nvidia.com/cloudvariables/v3")
        components?.queryItems = cloudVariablesQueryItems(locale: locale)
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        request.httpMethod = "GET"
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(browserUserAgent(), forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func cloudVariablesQueryItems(locale: String) -> [URLQueryItem] {
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
            URLQueryItem(name: "userId", value: "undefined"),
            URLQueryItem(name: "idpId", value: "undefined"),
            URLQueryItem(name: "clientId", value: "78589530426925203"),
            URLQueryItem(name: "clientVer", value: nvClientVersion),
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

    private static func currentCloudVariablesLocale() -> String {
        let identifier = Locale.current.identifier.replacingOccurrences(of: "-", with: "_")
        return identifier.isEmpty ? "en_US" : identifier
    }

    public static func fetchRegions(token: String, providerStreamingBaseUrl: String, completion: @escaping @Sendable ([OPNStreamRegionOption]) -> Void) {
        let baseUrl = providerStreamingBaseUrl.isEmpty ? defaultStreamingBaseUrl : providerStreamingBaseUrl
        var request = serverInfoRequest(baseUrl: baseUrl, token: token)
        request.timeoutInterval = 4
        let networkStart = OPNNetworkLog.start(&request, operation: "stream.fetchRegions")
        let tracedRequest = request
        URLSession.shared.dataTask(with: tracedRequest) { data, response, error in
            OPNNetworkLog.finish(tracedRequest, operation: "stream.fetchRegions", startedAt: networkStart, data: data, response: response, error: error)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard error == nil, let data, status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let metadata = json["metaData"] as? [[String: Any]] else {
                DispatchQueue.main.async { completion(loadCachedRegions()) }
                return
            }
            let regions = metadata.compactMap { entry -> OPNStreamRegionOption? in
                guard let key = entry["key"] as? String, let value = entry["value"] as? String, !key.isEmpty, !value.isEmpty else { return nil }
                if key == "gfn-regions" || key.hasPrefix("gfn-") || !value.hasPrefix("https://") { return nil }
                return OPNStreamRegionOption(name: key, url: normalizedBaseUrl(value))
            }
            if regions.isEmpty {
                DispatchQueue.main.async { completion(loadCachedRegions()) }
                return
            }
            measureRegions(regions, token: token, completion: completion)
        }.resume()
    }

    public static func runNetworkPreflight(token: String, providerStreamingBaseUrl: String, requestedMaxBitrateMbps: Int, completion: @escaping @Sendable (OPNStreamNetworkPreflightResult) -> Void) {
        var initial = OPNStreamNetworkPreflightResult()
        initial.streamingBaseUrl = loadSelectedStreamingBaseUrl()
        initial.networkType = currentNetworkType()
        initial.recommendedMaxBitrateMbps = max(1, requestedMaxBitrateMbps)
        let initialResult = initial

        let selectedRegionUrl = loadSelectedRegionUrl()
        let cachedRegions = loadCachedRegions()
        let cachedChoice = cachedRegionChoice(regions: cachedRegions, selectedRegionUrl: selectedRegionUrl)
        if let cachedChoice, !cachedChoice.url.isEmpty {
            var cached = initial
            cached.streamingBaseUrl = normalizedBaseUrl(cachedChoice.url)
            cached.latencyMs = cachedChoice.latencyMs
            cached.usedAutomaticRegion = selectedRegionUrl.isEmpty
            cached.recommendedMaxBitrateMbps = recommendedBitrate(requestedMaxBitrateMbps: requestedMaxBitrateMbps, latencyMs: cached.latencyMs, measuredBandwidthMbps: cached.measuredBandwidthMbps, packetLossPercent: cached.packetLossPercent, jitterMs: cached.jitterMs)
            DispatchQueue.main.async { completion(cached) }
            fetchRegions(token: token, providerStreamingBaseUrl: providerStreamingBaseUrl) { _ in }
            return
        }
        fetchRegions(token: token, providerStreamingBaseUrl: providerStreamingBaseUrl) { regions in
            var result = initialResult
            if let chosen = cachedRegionChoice(regions: regions, selectedRegionUrl: selectedRegionUrl), !chosen.url.isEmpty {
                result.streamingBaseUrl = normalizedBaseUrl(chosen.url)
                result.latencyMs = chosen.latencyMs
                result.usedAutomaticRegion = selectedRegionUrl.isEmpty
            }
            result.recommendedMaxBitrateMbps = recommendedBitrate(requestedMaxBitrateMbps: requestedMaxBitrateMbps, latencyMs: result.latencyMs, measuredBandwidthMbps: result.measuredBandwidthMbps, packetLossPercent: result.packetLossPercent, jitterMs: result.jitterMs)
            completion(result)
        }
    }

    public static func saveAspectIndex(_ aspectIndex: Int) {
        let clamped = clamp(aspectIndex, 0, aspectOptions.count - 1)
        storage.set(clamped, forKey: k.aspectIndex)
        let resolutions = resolutionOptions(forAspect: clamped)
        let currentResolution = clampedStoredInt(k.resolutionIndex, clamped == 1 ? 2 : 0, resolutions.count)
        storage.set(currentResolution, forKey: k.resolutionIndex)
    }

    public static func saveResolutionIndex(_ value: Int) { storage.set(clamp(value, 0, resolutionOptions(forAspect: loadProfile().aspectIndex).count - 1), forKey: k.resolutionIndex) }
    public static func saveFpsIndex(_ value: Int) { storage.set(clamp(value, 0, fpsOptions.count - 1), forKey: k.fpsIndex) }
    public static func saveCodecIndex(_ value: Int) { storage.set(clamp(value, 0, codecOptions.count - 1), forKey: k.codecIndex) }
    public static func saveBitrateIndex(_ value: Int) { storage.set(clamp(value, 0, bitrateOptions.count - 1), forKey: k.bitrateIndex) }
    public static func saveColorQualityIndex(_ value: Int) { storage.set(clamp(value, 0, colorQualityOptions.count - 1), forKey: k.colorQualityIndex) }
    public static func savePrefilterModeIndex(_ value: Int) { saveCanonicalInt(k.prefilterModeIndex, clamp(value, 0, prefilterModeOptions.count - 1)) }
    public static func savePrefilterSharpness(_ value: Int) { saveCanonicalInt(k.prefilterSharpness, clamp(value, 0, 10)) }
    public static func savePrefilterDenoise(_ value: Int) { saveCanonicalInt(k.prefilterDenoise, clamp(value, 0, 10)) }
    public static func saveUpscalingModeIndex(_ value: Int) { storage.set(clamp(value, 0, upscalingModeOptions.count - 1), forKey: k.upscalingModeIndex) }
    public static func saveUpscalingTargetIndex(_: Int) { storage.set(defaultUpscalingTargetIndex, forKey: k.upscalingTargetIndex) }
    public static func saveUpscalingSharpness(_ value: Int) { storage.set(clamp(value, 0, 40), forKey: k.upscalingSharpness) }
    public static func saveUpscalingDenoise(_ value: Int) { storage.set(clamp(value, 0, 20), forKey: k.upscalingDenoise) }
    public static func saveRecordingVideoBitrateMbps(_ value: Int) { storage.set(clamp(value, 0, 200), forKey: k.recordingVideoBitrateMbps) }
    public static func saveRecordingAudioBitrateKbps(_ value: Int) { storage.set(clamp(value, 64, 320), forKey: k.recordingAudioBitrateKbps) }
    public static func saveRecordingEnhancedVideoEnabled(_ value: Bool) { storage.set(value, forKey: k.recordingEnhancedVideoEnabled) }
    public static func saveL4SEnabled(_ value: Bool) { storage.set(value, forKey: k.l4sEnabled) }
    public static func saveHDREnabled(_ value: Bool) { storage.set(value, forKey: k.hdrEnabled) }
    public static func saveLowLatencyModeEnabled(_ value: Bool) { storage.set(value, forKey: k.lowLatencyModeEnabled) }
    public static func savePowerSaverEnabled(_ value: Bool) { storage.set(value, forKey: k.powerSaverEnabled) }
    public static func saveSuppressInputWhenInactive(_ value: Bool) { storage.set(value, forKey: k.suppressInputWhenInactive) }
    public static func saveDirectMouseInputEnabled(_ value: Bool) { storage.set(value, forKey: k.directMouseInput) }
    public static func saveGameVolume(_ value: Double) { storage.set(min(max(value, 0.0), 1.0), forKey: k.gameVolume) }
    public static func saveMicrophoneVolume(_ value: Double) { storage.set(min(max(value, 0.0), 1.0), forKey: k.microphoneVolume) }
    public static func loadMicrophoneShortcutEnabled() -> Bool { bool(storage.object(forKey: k.microphoneShortcutEnabled), true) }
    public static func saveMicrophoneShortcutEnabled(_ value: Bool) { storage.set(value, forKey: k.microphoneShortcutEnabled) }
    public static func saveMicrophoneMode(_ mode: String) { storage.set(microphoneModeOptions.contains { $0.value == mode } ? mode : microphoneModeOptions[0].value, forKey: k.microphoneMode) }
    public static func saveMicrophoneDeviceId(_ deviceId: String) { deviceId.isEmpty ? storage.removeObject(forKey: k.microphoneDeviceId) : storage.set(deviceId, forKey: k.microphoneDeviceId) }
    public static func saveMicrophonePushToTalkKeyCode(_ value: Int) { storage.set(clamp(value, 0, 127), forKey: k.microphonePushToTalkKeyCode) }
    public static func saveMicrophonePushToTalkModifierMask(_ value: Int) { storage.set(sanitizedPushToTalkModifierMask(value), forKey: k.microphonePushToTalkModifierMask) }

    public static func restoreStreamingProfileDefaults() {
        for key in streamingProfileKeys {
            storage.removeObject(forKey: key)
        }
        storage.synchronize()
    }

    public static func microphonePushToTalkKeyLabel(_ keyCode: Int) -> String {
        keyLabels[keyCode] ?? "Key \(keyCode)"
    }

    public static func microphonePushToTalkComboLabel(keyCode: Int, modifierMask: Int) -> String {
        let keyBit = pushToTalkModifierBit(forKeyCode: keyCode)
        let visible = sanitizedPushToTalkModifierMask(modifierMask) & ~keyBit
        var parts: [String] = []
        if visible & 0x02 != 0 { parts.append("Control") }
        if visible & 0x04 != 0 { parts.append("Option") }
        if visible & 0x01 != 0 { parts.append("Shift") }
        if visible & 0x08 != 0 { parts.append("Command") }
        if visible & 0x10 != 0 { parts.append("Caps Lock") }
        parts.append(microphonePushToTalkKeyLabel(keyCode))
        return parts.joined(separator: " + ")
    }

    private static func profile(from dictionary: [String: Any]?) -> OPNStreamPreferenceProfile {
        var profile = OPNStreamPreferenceProfile()
        profile.aspectIndex = clampedInt(dictionary, k.aspectIndex, 1, aspectOptions.count)
        profile.aspect = aspectOptions[profile.aspectIndex]
        let resolutions = resolutionOptions(forAspect: profile.aspectIndex)
        profile.resolutionIndex = clampedInt(dictionary, k.resolutionIndex, profile.aspectIndex == 1 ? 2 : 0, resolutions.count)
        profile.resolution = resolutions[profile.resolutionIndex]
        profile.fpsIndex = clampedInt(dictionary, k.fpsIndex, 1, fpsOptions.count)
        profile.fps = fpsOptions[profile.fpsIndex]
        profile.codecIndex = clampedInt(dictionary, k.codecIndex, 0, codecOptions.count)
        profile.codec = codecOptions[profile.codecIndex]
        profile.bitrateIndex = clampedInt(dictionary, k.bitrateIndex, 2, bitrateOptions.count)
        profile.bitrate = bitrateOptions[profile.bitrateIndex]
        profile.maxBitrateMbps = profile.bitrate.mbps
        profile.colorQualityIndex = clampedInt(dictionary, k.colorQualityIndex, 0, colorQualityOptions.count)
        profile.colorQuality = colorQualityOptions[profile.colorQualityIndex]
        profile.prefilterModeIndex = clampedInt(dictionary, k.prefilterModeIndex, 0, prefilterModeOptions.count)
        profile.prefilterModeOption = prefilterModeOptions[profile.prefilterModeIndex]
        profile.prefilterMode = profile.prefilterModeOption.value
        profile.prefilterSharpness = clampedInt(dictionary, k.prefilterSharpness, 0, 11)
        profile.prefilterDenoise = clampedInt(dictionary, k.prefilterDenoise, 0, 11)
        profile.upscalingModeIndex = clampedInt(dictionary, k.upscalingModeIndex, 0, upscalingModeOptions.count)
        profile.upscalingModeOption = upscalingModeOptions[profile.upscalingModeIndex]
        profile.upscalingMode = profile.upscalingModeOption.value
        applyDefaultUpscalingTarget(&profile)
        profile.upscalingSharpness = clampedInt(dictionary, k.upscalingSharpness, 4, 41)
        profile.upscalingDenoise = clampedInt(dictionary, k.upscalingDenoise, 0, 21)
        profile.recordingVideoBitrateMbps = clampedInt(dictionary, k.recordingVideoBitrateMbps, 0, 201)
        profile.recordingAudioBitrateKbps = Int(clampedDouble(dictionary, k.recordingAudioBitrateKbps, 160, 64, 320).rounded())
        profile.recordingEnhancedVideoEnabled = bool(value(dictionary, k.recordingEnhancedVideoEnabled), true)
        profile.enableL4S = bool(value(dictionary, k.l4sEnabled), false)
        profile.enableHdr = bool(value(dictionary, k.hdrEnabled), false)
        profile.lowLatencyMode = bool(value(dictionary, k.lowLatencyModeEnabled), false)
        profile.enablePowerSaver = bool(value(dictionary, k.powerSaverEnabled), false)
        profile.suppressInputWhenInactive = bool(value(dictionary, k.suppressInputWhenInactive), true)
        profile.directMouseInput = bool(value(dictionary, k.directMouseInput), true)
        profile.gameVolume = clampedDouble(dictionary, k.gameVolume, 1, 0, 1)
        profile.microphoneVolume = clampedDouble(dictionary, k.microphoneVolume, 1, 0, 1)
        profile.microphoneMode = string(value(dictionary, k.microphoneMode), "disabled")
        if !microphoneModeOptions.contains(where: { $0.value == profile.microphoneMode }) { profile.microphoneMode = "disabled" }
        profile.microphoneDeviceId = string(value(dictionary, k.microphoneDeviceId), "")
        profile.microphonePushToTalkKeyCode = clampedInt(dictionary, k.microphonePushToTalkKeyCode, 9, 128)
        profile.microphonePushToTalkModifierMask = normalizedPushToTalkModifierMask(keyCode: profile.microphonePushToTalkKeyCode, modifierMask: clampedInt(dictionary, k.microphonePushToTalkModifierMask, 0, 32))
        profile.microphonePushToTalkKeyLabel = microphonePushToTalkKeyLabel(profile.microphonePushToTalkKeyCode)
        profile.microphonePushToTalkComboLabel = microphonePushToTalkComboLabel(keyCode: profile.microphonePushToTalkKeyCode, modifierMask: profile.microphonePushToTalkModifierMask)
        profile.selectedRegionUrl = string(value(dictionary, k.selectedRegionUrl), "")
        return profile
    }

    private static func dictionary(from profile: OPNStreamPreferenceProfile, enabled: Bool) -> [String: Any] {
        var dictionary: [String: Any] = [
            k.gameProfileEnabled: enabled,
            k.aspectIndex: profile.aspectIndex,
            k.resolutionIndex: profile.resolutionIndex,
            k.fpsIndex: profile.fpsIndex,
            k.codecIndex: profile.codecIndex,
            k.bitrateIndex: profile.bitrateIndex,
            k.colorQualityIndex: profile.colorQualityIndex,
            k.prefilterModeIndex: profile.prefilterModeIndex,
            k.prefilterSharpness: profile.prefilterSharpness,
            k.prefilterDenoise: profile.prefilterDenoise,
            k.upscalingModeIndex: profile.upscalingModeIndex,
            k.upscalingTargetIndex: profile.upscalingTargetIndex,
            k.upscalingSharpness: profile.upscalingSharpness,
            k.upscalingDenoise: profile.upscalingDenoise,
            k.recordingVideoBitrateMbps: profile.recordingVideoBitrateMbps,
            k.recordingAudioBitrateKbps: profile.recordingAudioBitrateKbps,
            k.recordingEnhancedVideoEnabled: profile.recordingEnhancedVideoEnabled,
            k.l4sEnabled: profile.enableL4S,
            k.hdrEnabled: profile.enableHdr,
            k.lowLatencyModeEnabled: profile.lowLatencyMode,
            k.powerSaverEnabled: profile.enablePowerSaver,
            k.suppressInputWhenInactive: profile.suppressInputWhenInactive,
            k.directMouseInput: profile.directMouseInput,
            k.gameVolume: profile.gameVolume,
            k.microphoneVolume: profile.microphoneVolume,
            k.microphoneMode: profile.microphoneMode,
            k.microphonePushToTalkKeyCode: profile.microphonePushToTalkKeyCode,
            k.microphonePushToTalkModifierMask: profile.microphonePushToTalkModifierMask
        ]
        if !profile.microphoneDeviceId.isEmpty { dictionary[k.microphoneDeviceId] = profile.microphoneDeviceId }
        let normalizedRegionUrl = normalizedHTTPSBaseUrlOrEmpty(profile.selectedRegionUrl)
        if !normalizedRegionUrl.isEmpty { dictionary[k.selectedRegionUrl] = normalizedRegionUrl }
        return dictionary
    }

    private static func firstSupportedCodecIndex(_ capabilities: OPNStreamDeviceCapabilities) -> Int {
        if let h264Index = codecOptions.firstIndex(where: { $0.value == "H264" && codecSupported($0, capabilities: capabilities) }) { return h264Index }
        return codecOptions.firstIndex(where: { codecSupported($0, capabilities: capabilities) }) ?? 0
    }

    private static func nearestSupportedFpsIndex(_ requestedFps: Int, _ capabilities: OPNStreamDeviceCapabilities) -> Int {
        var fallbackIndex = 0
        var fallbackFps = fpsOptions.first ?? 60
        for (index, fps) in fpsOptions.enumerated() where fpsSupported(fps, capabilities: capabilities) && fps <= requestedFps && fps >= fallbackFps {
            fallbackIndex = index
            fallbackFps = fps
        }
        return fallbackIndex
    }

    private static func applyDefaultUpscalingTarget(_ profile: inout OPNStreamPreferenceProfile) {
        let index = clamp(defaultUpscalingTargetIndex, 0, upscalingTargetOptions.count - 1)
        profile.upscalingTargetIndex = index
        profile.upscalingTargetOption = upscalingTargetOptions[index]
        profile.upscalingTargetHeight = profile.upscalingTargetOption.height
    }

    private static func storedPreferenceValue(_ key: String) -> Any? {
        let prefilterKey = key == k.prefilterModeIndex || key == k.prefilterSharpness || key == k.prefilterDenoise
        return storage.storedValue(forKey: key, preferCanonicalDomain: prefilterKey)
    }

    private static func saveCanonicalInt(_ key: String, _ value: Int) {
        storage.setCanonicalInt(value, forKey: key)
    }

    private static func gameProfileDictionary(for appId: String) -> [String: Any]? {
        guard !appId.isEmpty, let profiles = storage.dictionary(forKey: k.gameProfiles) else { return nil }
        return profiles[appId] as? [String: Any]
    }

    private static func mutableGameProfilesDictionary() -> [String: [String: Any]] {
        let profiles = storage.dictionary(forKey: k.gameProfiles) ?? [:]
        var result: [String: [String: Any]] = [:]
        for (key, value) in profiles {
            if let dictionary = value as? [String: Any] { result[key] = dictionary }
        }
        return result
    }

    private static func normalizedHTTPSBaseUrlOrEmpty(_ url: String) -> String {
        guard !url.isEmpty, let components = URLComponents(string: url), components.scheme?.lowercased() == "https", components.host?.isEmpty == false else { return "" }
        return url.hasSuffix("/") ? url : url + "/"
    }

    private static func normalizedBaseUrl(_ url: String) -> String {
        let normalized = normalizedHTTPSBaseUrlOrEmpty(url)
        return normalized.isEmpty ? defaultStreamingBaseUrl : normalized
    }

    private static func applyCloudmatchHeaders(to request: inout URLRequest, token: String) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(nvClientId, forHTTPHeaderField: "nv-client-id")
        request.setValue("BROWSER", forHTTPHeaderField: "nv-client-type")
        request.setValue(nvClientVersion, forHTTPHeaderField: "nv-client-version")
        request.setValue("WEBRTC", forHTTPHeaderField: "nv-client-streamer")
        request.setValue("WINDOWS", forHTTPHeaderField: "nv-device-os")
        request.setValue("DESKTOP", forHTTPHeaderField: "nv-device-type")
        if !token.isEmpty { request.setValue("GFNJWT \(token)", forHTTPHeaderField: "Authorization") }
    }

    private static func browserUserAgent() -> String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36"
    }

    private static func serverInfoRequest(baseUrl: String, token: String) -> URLRequest {
        let base = normalizedBaseUrl(baseUrl)
        var request = URLRequest(url: URL(string: base + "v2/serverInfo")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        applyCloudmatchHeaders(to: &request, token: token)
        request.setValue(OPNDeviceIdentity.stableCloudmatchDeviceId(), forHTTPHeaderField: "x-device-id")
        return request
    }

    private static func measureRegions(_ regions: [OPNStreamRegionOption], token: String, completion: @escaping @Sendable ([OPNStreamRegionOption]) -> Void) {
        if regions.isEmpty {
            DispatchQueue.main.async { completion([]) }
            return
        }
        let state = RegionMeasurementState(regions)
        let orderedIndices = prioritizedRegionMeasurementIndices(regions)
        let group = DispatchGroup()
        let queue = OperationQueue()
        queue.name = "com.opennow.stream.region-measurements"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = maxConcurrentRegionMeasurements
        for index in orderedIndices {
            group.enter()
            queue.addOperation {
                let semaphore = DispatchSemaphore(value: 0)
                measureRegion(state: state, index: index, token: token, attempt: 0, bestLatencyMs: -1) {
                    semaphore.signal()
                }
                semaphore.wait()
                group.leave()
            }
        }
        group.notify(queue: .main) {
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

    private static func prioritizedRegionMeasurementIndices(_ regions: [OPNStreamRegionOption]) -> [Int] {
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

    private static func measureRegion(state: RegionMeasurementState, index: Int, token: String, attempt: Int, bestLatencyMs: Int, completion: @escaping @Sendable () -> Void) {
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

    private static func currentNetworkType() -> String {
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

    private static func cachedRegionChoice(regions: [OPNStreamRegionOption], selectedRegionUrl: String) -> OPNStreamRegionOption? {
        if !selectedRegionUrl.isEmpty {
            let normalizedSelected = normalizedBaseUrl(selectedRegionUrl)
            if let selected = regions.first(where: { !$0.url.isEmpty && normalizedBaseUrl($0.url) == normalizedSelected }) { return selected }
        }
        return regions.first { !$0.url.isEmpty && $0.latencyMs >= 0 }
    }

    private static func jsonValue(from text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func firstRecursiveJSONValue(_ json: Any?, keys: [String]) -> Any? {
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

    private static func number(_ value: Any?) -> NSNumber? {
        if let number = value as? NSNumber { return number }
        if let string = value as? String, let double = Double(string), double.isFinite { return NSNumber(value: double) }
        return nil
    }

    private static func jsonString(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func firstRecursiveNumber(_ json: Any?, keys: [String]) -> NSNumber? { number(firstRecursiveJSONValue(json, keys: keys)) }
    private static func firstRecursiveString(_ json: Any?, keys: [String]) -> String? { jsonString(firstRecursiveJSONValue(json, keys: keys)).flatMap { $0.isEmpty ? nil : $0 } }
    private static func firstRecursiveBool(_ json: Any?, keys: [String], fallback: Bool) -> Bool { jsonBool(firstRecursiveJSONValue(json, keys: keys), fallback) }

    private static func jsonBool(_ value: Any?, _ fallback: Bool) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        guard let string = value as? String else { return fallback }
        switch string.lowercased() {
        case "true", "yes", "1", "enabled": return true
        case "false", "no", "0", "disabled": return false
        default: return fallback
        }
    }

    private static func cloudVariableValue(_ json: Any?, names: [String]) -> Any? {
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

    private static func cloudVariableBool(_ json: Any?, names: [String], fallback: Bool) -> Bool { jsonBool(cloudVariableValue(json, names: names), fallback) }
    private static func cloudVariableNumber(_ json: Any?, names: [String]) -> NSNumber? { number(cloudVariableValue(json, names: names)) }
    private static func cloudVariableString(_ json: Any?, names: [String]) -> String? { jsonString(cloudVariableValue(json, names: names)).flatMap { $0.isEmpty ? nil : $0 } }

    private static func cloudVariablePrefilterModes(_ json: Any?, names: [String]) -> [Int] {
        var modes: [Int] = []
        appendPrefilterModes(&modes, value: cloudVariableValue(json, names: names))
        return modes.sorted()
    }

    private static func appendPrefilterModes(_ modes: inout [Int], value: Any?) {
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

    private static func appendUniquePrefilterMode(_ modes: inout [Int], _ mode: Int) {
        guard mode >= 0, mode <= 2, !modes.contains(mode) else { return }
        modes.append(mode)
    }

    private static func prefilterMode(from value: Any?) -> Int {
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

    private static func bitrateMbps(from json: Any?, mbpsKeys: [String], kbpsKeys: [String]) -> Int {
        if let mbps = firstRecursiveNumber(json, keys: mbpsKeys), mbps.doubleValue > 0 { return max(1, Int(mbps.doubleValue.rounded(.down))) }
        if let kbps = firstRecursiveNumber(json, keys: kbpsKeys), kbps.doubleValue > 0 { return max(1, Int((kbps.doubleValue / 1000.0).rounded(.down))) }
        return 0
    }

    private static func percent(from json: Any?, keys: [String]) -> Double {
        guard let value = firstRecursiveNumber(json, keys: keys) else { return -1 }
        var percent = value.doubleValue
        if percent >= 0, percent <= 1 { percent *= 100 }
        return percent >= 0 && percent.isFinite ? percent : -1
    }

    private static func networkTestSessionId(from json: Any?) -> String? {
        guard let dictionary = json as? [String: Any] else { return nil }
        for key in ["networkTestSessionId", "networkSessionId", "sessionId", "id"] {
            if let value = jsonString(dictionary[key]), !value.isEmpty { return value }
        }
        for key in ["session", "networkTestSession", "data", "requestStatus"] {
            if let value = networkTestSessionId(from: dictionary[key]), !value.isEmpty { return value }
        }
        return nil
    }

    private static func audioObjectString(_ objectId: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(objectId, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func clampedInt(_ dictionary: [String: Any]?, _ key: String, _ defaultValue: Int, _ upperBoundExclusive: Int) -> Int {
        let raw = dictionary?[key] ?? storedPreferenceValue(key)
        let stored = int(raw, defaultValue)
        return upperBoundExclusive <= 0 ? 0 : clamp(stored, 0, upperBoundExclusive - 1)
    }

    private static func clampedDouble(_ dictionary: [String: Any]?, _ key: String, _ defaultValue: Double, _ minValue: Double, _ maxValue: Double) -> Double {
        let raw = dictionary?[key] ?? storedPreferenceValue(key)
        let stored = double(raw, defaultValue)
        return min(max(stored.isFinite ? stored : defaultValue, minValue), maxValue)
    }

    private static func clampedStoredInt(_ key: String, _ defaultValue: Int, _ upperBoundExclusive: Int) -> Int { clampedInt(nil, key, defaultValue, upperBoundExclusive) }
    private static func value(_ dictionary: [String: Any]?, _ key: String) -> Any? { dictionary?[key] ?? storedPreferenceValue(key) }
    private static func int(_ value: Any?, _ defaultValue: Int) -> Int { (value as? NSNumber)?.intValue ?? value as? Int ?? defaultValue }
    private static func double(_ value: Any?, _ defaultValue: Double) -> Double { (value as? NSNumber)?.doubleValue ?? value as? Double ?? defaultValue }
    private static func bool(_ value: Any?, _ defaultValue: Bool) -> Bool { (value as? NSNumber)?.boolValue ?? value as? Bool ?? defaultValue }
    private static func string(_ value: Any?, _ defaultValue: String) -> String { (value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? defaultValue }
    private static func clamp(_ value: Int, _ lower: Int, _ upper: Int) -> Int { max(lower, min(value, upper)) }

    private static func pushToTalkModifierBit(forKeyCode keyCode: Int) -> Int {
        switch keyCode {
        case 55: return 0x08
        case 56, 60: return 0x01
        case 57: return 0x10
        case 58, 61: return 0x04
        case 59, 62: return 0x02
        default: return 0
        }
    }

    private static func sanitizedPushToTalkModifierMask(_ modifierMask: Int) -> Int { modifierMask & 0x1f }
    private static func normalizedPushToTalkModifierMask(keyCode: Int, modifierMask: Int) -> Int { sanitizedPushToTalkModifierMask(modifierMask) | pushToTalkModifierBit(forKeyCode: keyCode) }

    private static let keyLabels: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "Backspace", 53: "Escape", 55: "Left Command", 56: "Left Shift", 57: "Caps Lock", 58: "Left Option", 59: "Left Control", 60: "Right Shift", 61: "Right Option", 62: "Right Control", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1"
    ]

    private enum Keys {
        static let aspectIndex = "OpenNOW.Stream.AspectIndex"
        static let resolutionIndex = "OpenNOW.Stream.ResolutionIndex"
        static let fpsIndex = "OpenNOW.Stream.FpsIndex"
        static let codecIndex = "OpenNOW.Stream.CodecIndex"
        static let bitrateIndex = "OpenNOW.Stream.BitrateIndex"
        static let colorQualityIndex = "OpenNOW.Stream.ColorQualityIndex"
        static let prefilterModeIndex = "OpenNOW.Stream.PrefilterModeIndex"
        static let prefilterSharpness = "OpenNOW.Stream.PrefilterSharpness"
        static let prefilterDenoise = "OpenNOW.Stream.PrefilterDenoise"
        static let upscalingModeIndex = "OpenNOW.Stream.UpscalingModeIndex"
        static let upscalingTargetIndex = "OpenNOW.Stream.UpscalingTargetIndex"
        static let upscalingSharpness = "OpenNOW.Stream.UpscalingSharpness"
        static let upscalingDenoise = "OpenNOW.Stream.UpscalingDenoise"
        static let recordingVideoBitrateMbps = "OpenNOW.Stream.RecordingVideoBitrateMbps"
        static let recordingAudioBitrateKbps = "OpenNOW.Stream.RecordingAudioBitrateKbps"
        static let recordingEnhancedVideoEnabled = "OpenNOW.Stream.RecordingEnhancedVideoEnabled"
        static let l4sEnabled = "OpenNOW.Stream.L4SEnabled"
        static let lowLatencyModeEnabled = "OpenNOW.Stream.LowLatencyModeEnabled"
        static let powerSaverEnabled = "OpenNOW.Stream.PowerSaverEnabled"
        static let suppressInputWhenInactive = "OpenNOW.Stream.SuppressInputWhenInactive"
        static let directMouseInput = "OpenNOW.Stream.DirectMouseInput"
        static let gameVolume = "OpenNOW.Stream.GameVolume"
        static let microphoneVolume = "OpenNOW.Stream.MicrophoneVolume"
        static let microphoneShortcutEnabled = "OpenNOW.Stream.MicrophoneShortcutEnabled"
        static let microphoneMode = "OpenNOW.Stream.MicrophoneMode"
        static let microphoneDeviceId = "OpenNOW.Stream.MicrophoneDeviceId"
        static let microphonePushToTalkKeyCode = "OpenNOW.Stream.MicrophonePushToTalkKeyCode"
        static let microphonePushToTalkModifierMask = "OpenNOW.Stream.MicrophonePushToTalkModifierMask"
        static let selectedRegionUrl = "OpenNOW.Stream.RegionUrl"
        static let cachedRegions = "OpenNOW.Stream.CachedRegions"
        static let cachedCloudVariablesJSON = "OpenNOW.Stream.CloudVariablesJSON"
        static let cachedCloudVariablesTimestamp = "OpenNOW.Stream.CloudVariablesTimestamp"
        static let hdrEnabled = "OpenNOW.Stream.HDREnabled"
        static let gameProfiles = "OpenNOW.Stream.GameProfiles"
        static let gameProfileEnabled = "enabled"
    }
}

@objc(OPNStreamViewPreferenceSnapshot)
public final class OPNStreamViewPreferenceSnapshot: NSObject {
    @objc public let directMouseInput: Bool
    @objc public let microphoneShortcutEnabled: Bool
    @objc public let gameVolume: Double
    @objc public let microphoneVolume: Double
    @objc public let maxBitrateMbps: Int
    @objc public let lowLatencyMode: Bool
    @objc public let upscalingModeIndex: Int
    @objc public let upscalingMode: Int
    @objc public let upscalingTargetHeight: Int
    @objc public let upscalingSharpness: Int
    @objc public let upscalingDenoise: Int
    @objc public let streamWidth: Int
    @objc public let streamHeight: Int
    @objc public let recordingEnhancedVideoEnabled: Bool

    init(profile: OPNStreamPreferenceProfile) {
        directMouseInput = profile.directMouseInput
        microphoneShortcutEnabled = OPNStreamPreferences.loadMicrophoneShortcutEnabled()
        gameVolume = profile.gameVolume
        microphoneVolume = profile.microphoneVolume
        maxBitrateMbps = profile.maxBitrateMbps
        lowLatencyMode = profile.lowLatencyMode
        upscalingModeIndex = profile.upscalingModeIndex
        upscalingMode = profile.upscalingMode
        upscalingTargetHeight = profile.upscalingTargetHeight
        upscalingSharpness = profile.upscalingSharpness
        upscalingDenoise = profile.upscalingDenoise
        streamWidth = profile.resolution.width
        streamHeight = profile.resolution.height
        recordingEnhancedVideoEnabled = profile.recordingEnhancedVideoEnabled
        super.init()
    }
}

@objc(OPNStreamViewPreferences)
public final class OPNStreamViewPreferences: NSObject {
    @objc public static func loadViewPreferenceSnapshot() -> OPNStreamViewPreferenceSnapshot {
        OPNStreamViewPreferenceSnapshot(profile: OPNStreamPreferences.loadProfile())
    }

    @objc public static func upscalingModeLabels() -> [String] {
        OPNStreamPreferences.upscalingModeOptions.map(\.label)
    }

    @objc(upscalingModeValueAtIndex:)
    public static func upscalingModeValue(at index: Int) -> Int {
        let clamped = min(max(index, 0), OPNStreamPreferences.upscalingModeOptions.count - 1)
        return OPNStreamPreferences.upscalingModeOptions[clamped].value
    }

    @objc public static func saveMicrophoneShortcutEnabled(_ enabled: Bool) {
        OPNStreamPreferences.saveMicrophoneShortcutEnabled(enabled)
    }

    @objc public static func saveGameVolume(_ value: Double) {
        OPNStreamPreferences.saveGameVolume(value)
    }

    @objc public static func saveMicrophoneVolume(_ value: Double) {
        OPNStreamPreferences.saveMicrophoneVolume(value)
    }

    @objc public static func saveUpscalingModeIndex(_ index: Int) {
        OPNStreamPreferences.saveUpscalingModeIndex(index)
    }

    @objc public static func saveUpscalingSharpness(_ sharpness: Int) {
        OPNStreamPreferences.saveUpscalingSharpness(sharpness)
    }

    @objc public static func saveUpscalingDenoise(_ denoise: Int) {
        OPNStreamPreferences.saveUpscalingDenoise(denoise)
    }
}

private extension OPNStreamResolutionOption {
    init(_ tuple: (Int, Int)) {
        self.init(width: tuple.0, height: tuple.1)
    }
}

private final class RegionMeasurementState: @unchecked Sendable {
    private let lock = NSLock()
    private var regions: [OPNStreamRegionOption]

    init(_ regions: [OPNStreamRegionOption]) {
        self.regions = regions
    }

    var values: [OPNStreamRegionOption] {
        lock.lock()
        defer { lock.unlock() }
        return regions
    }

    func region(at index: Int) -> OPNStreamRegionOption {
        lock.lock()
        defer { lock.unlock() }
        return regions[index]
    }

    func setLatency(_ latencyMs: Int, at index: Int) {
        lock.lock()
        defer { lock.unlock() }
        regions[index].latencyMs = latencyMs
    }
}
