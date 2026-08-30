import AppKit
import CoreAudio
import CoreMedia
import Foundation
import VideoToolbox

public enum OPNStreamPreferences {
    static let storage = OPNAppPreferenceStorage.standard

    public static let defaultStreamingBaseUrl = CloudMatch.productionBaseURLString + "/"
    public static let defaultPillarboxFillColor = "#000000"
    public static let aspectOptions = [
        OPNStreamAspectOption(label: "16:9", widthRatio: 16, heightRatio: 9),
        OPNStreamAspectOption(label: "16:10", widthRatio: 16, heightRatio: 10),
        OPNStreamAspectOption(label: "21:9", widthRatio: 21, heightRatio: 9),
        OPNStreamAspectOption(label: "32:9", widthRatio: 32, heightRatio: 9)
    ]
    public static let fpsOptions = [30, 60, 120, 240]
    public static let codecOptions = [
        OPNStreamCodecOption(label: "H264", value: "H264"),
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
    public static let transportModeOptions = [
        OPNStreamTransportModeOption(label: "WebRTC", value: "webrtc"),
        OPNStreamTransportModeOption(label: "Native/NVST", value: "nvst")
    ]
    public static let streamingQualityProfileOptions = [
        OPNStreamQualityProfileOption(label: "Custom", value: 0),
        OPNStreamQualityProfileOption(label: "Balanced", value: 1),
        OPNStreamQualityProfileOption(label: "Competitive", value: 2),
        OPNStreamQualityProfileOption(label: "Data Saver", value: 3),
        OPNStreamQualityProfileOption(label: "Cinematic", value: 4)
    ]
    public static let hudStreamingModeOptions = [
        OPNStreamHudModeOption(label: "Off", value: 0),
        OPNStreamHudModeOption(label: "QP Map", value: 1),
        OPNStreamHudModeOption(label: "Separate Stream", value: 2)
    ]
    public static let colorSpaceOptions = [
        OPNStreamColorSpaceOption(label: "Default", value: 0),
        OPNStreamColorSpaceOption(label: "BT.709", value: 1),
        OPNStreamColorSpaceOption(label: "BT.2020", value: 2)
    ]
    public static let prefilterModeOptions = [
        OPNStreamPrefilterModeOption(label: "Off", value: 0),
        OPNStreamPrefilterModeOption(label: "Auto", value: 1),
        OPNStreamPrefilterModeOption(label: "Custom", value: 2)
    ]
    // Appended, not inserted: MetalFX must stay at index 1 so an existing stored index doesn't
    // silently repoint at a different tier after this file starts shipping a third option.
    public static let upscalingModeOptions = [
        OPNStreamUpscalingModeOption(label: "Off", value: 0),
        OPNStreamUpscalingModeOption(label: "MetalFX", value: 3),
        OPNStreamUpscalingModeOption(label: "Spatial", value: 2)
    ]
    public static let upscalingTargetOptions = [
        OPNStreamUpscalingTargetOption(label: "2K", height: 1440),
        OPNStreamUpscalingTargetOption(label: "4K", height: 2160),
        OPNStreamUpscalingTargetOption(label: "5K", height: 2880)
    ]
    public static let microphoneModeOptions = [
        OPNStreamMicrophoneModeOption(label: "Disabled", value: "disabled"),
        OPNStreamMicrophoneModeOption(label: "Push-to-Talk", value: "push-to-talk"),
        OPNStreamMicrophoneModeOption(label: "Open Mic", value: "voice-activity")
    ]

    static let nvClientId = GFNClientMetadata.clientId
    static let nvCloudVariablesClientVersion = GFNClientMetadata.appVersion
    static let defaultUpscalingTargetIndex = 1
    static let maxConcurrentRegionMeasurements = 4
    static let k = Keys.self
    struct StreamingQualityPreset {
        let aspectIndex: Int
        let resolutionIndex: Int
        let fpsIndex: Int
        let codecIndex: Int
        let bitrateIndex: Int
        let colorQualityIndex: Int
        let cloudGsyncEnabled: Bool
        let fallbackToLogicalResolution: Bool
        let hudStreamingModeIndex: Int
        let sdrColorSpaceIndex: Int
        let hdrColorSpaceIndex: Int
        let l4sEnabled: Bool
        let hdrEnabled: Bool
        let powerSaverEnabled: Bool
    }
    static let streamingProfileKeys = [
        Keys.aspectIndex,
        Keys.resolutionIndex,
        Keys.fpsIndex,
        Keys.codecIndex,
        Keys.bitrateIndex,
        Keys.colorQualityIndex,
        Keys.transportModeIndex,
        Keys.streamingQualityProfileIndex,
        Keys.hudStreamingModeIndex,
        Keys.sdrColorSpaceIndex,
        Keys.hdrColorSpaceIndex,
        Keys.prefilterModeIndex,
        Keys.prefilterSharpness,
        Keys.prefilterDenoise,
        Keys.upscalingModeIndex,
        Keys.upscalingTargetIndex,
        Keys.upscalingSharpness,
        Keys.upscalingDenoise,
        Keys.pillarboxFillModeIndex,
        Keys.pillarboxFillColor,
        Keys.pillarboxFillDim,
        Keys.recordingVideoBitrateMbps,
        Keys.recordingAudioBitrateKbps,
        Keys.recordingEnhancedVideoEnabled,
        Keys.cloudGsyncEnabled,
        Keys.fallbackToLogicalResolution,
        Keys.l4sEnabled,
        Keys.hdrEnabled,
        Keys.powerSaverEnabled,
        Keys.suppressInputWhenInactive,
        Keys.directMouseInput,
        Keys.antiAFKMouseMovementEnabled,
        Keys.preventDisplaySleepWhileStreaming,
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
        case 2: return [(2560, 1080), (3440, 1440), (3840, 1600), (5120, 2160)].map(OPNStreamResolutionOption.init)
        case 3: return [(3840, 1080), (5120, 1440)].map(OPNStreamResolutionOption.init)
        default: return resolutionOptions(forAspect: 1)
        }
    }

    public static func defaultResolutionIndex(forAspect aspectIndex: Int) -> Int {
        switch aspectIndex {
        case 0: return 2
        case 1: return 3
        default: return 0
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

    public static func loadDeviceCapabilities(screen: NSScreen? = nil) -> OPNStreamDeviceCapabilities {
        var capabilities = OPNStreamDeviceCapabilities()
        capabilities.h264HardwareDecodeSupported = VTIsHardwareDecodeSupported(kCMVideoCodecType_H264)
        capabilities.h265HardwareDecodeSupported = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        if #available(macOS 14.0, *) {
            capabilities.av1HardwareDecodeSupported = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
        }

        guard let snapshot = mainThreadScreenSnapshot(screen: screen) else { return capabilities }
        let scale = snapshot.backingScaleFactor > 0 ? snapshot.backingScaleFactor : 1.0
        capabilities.displayDpi = max(100, Int((100.0 * scale).rounded()))
        if let screenNumber = snapshot.screenNumber {
            let displayId = CGDirectDisplayID(screenNumber)
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
            capabilities.maxDisplayWidth = Int((snapshot.frameSize.width * scale).rounded())
            capabilities.maxDisplayHeight = Int((snapshot.frameSize.height * scale).rounded())
        }
        capabilities.maxDisplayRefreshRate = max(capabilities.maxDisplayRefreshRate, snapshot.maximumFramesPerSecond)
        capabilities.hdrDisplaySupported = snapshot.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0
        return capabilities
    }

    private static func mainThreadScreenSnapshot(screen: NSScreen?) -> OPNStreamScreenSnapshot? {
        nonisolated(unsafe) let requestedScreen = screen
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                OPNStreamScreenSnapshot(screen: requestedScreen ?? NSScreen.main)
            }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                OPNStreamScreenSnapshot(screen: requestedScreen ?? NSScreen.main)
            }
        }
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

    public static func presentationCapability(codec: String, capabilities: OPNStreamDeviceCapabilities) -> OPNStreamPresentationCapability {
        switch codec.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "H265", "HEVC":
            return OPNStreamPresentationCapability(
                supportsTenBit: capabilities.h265HardwareDecodeSupported,
                supportsHDR: capabilities.h265HardwareDecodeSupported && capabilities.hdrDisplaySupported
            )
        case "AV1":
            return OPNStreamPresentationCapability(
                supportsTenBit: capabilities.av1HardwareDecodeSupported,
                supportsHDR: false
            )
        case "AUTO":
            return OPNStreamPresentationCapability(
                supportsTenBit: capabilities.h265HardwareDecodeSupported || capabilities.av1HardwareDecodeSupported,
                supportsHDR: capabilities.h265HardwareDecodeSupported && capabilities.hdrDisplaySupported
            )
        default:
            return OPNStreamPresentationCapability(supportsTenBit: false, supportsHDR: false)
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
        // HDR is intentionally not clamped here: enableHdr is a stored preference, and the
        // stream-time gates (codec resolution, session settings) already no-op it on displays
        // without HDR support. Clamping at load silently discards the user's setting.
        return result
    }

    public static func loadProfile() -> OPNStreamPreferenceProfile {
        profile(from: nil)
    }

    public static func loadProfile(forGame appId: String) -> OPNStreamPreferenceProfile? {
        guard let dictionary = gameProfileDictionary(for: appId), bool(dictionary[k.gameProfileEnabled], false) else { return nil }
        return profile(from: dictionary)
    }

    public static func launchProfile(forGame appId: String, capabilities: OPNStreamDeviceCapabilities) -> OPNStreamPreferenceProfile {
        var profile = loadProfile()
        if let gameProfile = loadProfile(forGame: appId) {
            profile.upscalingModeIndex = gameProfile.upscalingModeIndex
            profile.upscalingMode = gameProfile.upscalingMode
            profile.upscalingModeOption = gameProfile.upscalingModeOption
            profile.upscalingTargetIndex = gameProfile.upscalingTargetIndex
            profile.upscalingTargetHeight = gameProfile.upscalingTargetHeight
            profile.upscalingTargetOption = gameProfile.upscalingTargetOption
            profile.upscalingSharpness = gameProfile.upscalingSharpness
            profile.upscalingDenoise = gameProfile.upscalingDenoise
            profile.pillarboxFillModeIndex = gameProfile.pillarboxFillModeIndex
            profile.pillarboxFillMode = gameProfile.pillarboxFillMode
            profile.pillarboxFillColor = gameProfile.pillarboxFillColor
            profile.pillarboxFillDim = gameProfile.pillarboxFillDim
        }
        return effectiveProfile(profile, capabilities: capabilities)
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

    /// Throughput estimates from the network test are intentionally not clamped here: the probe
    /// under-reports fast lines, and the streamer's congestion control already adapts bitrate
    /// downward on real congestion. Only measured impairment (loss, jitter, latency) caps the rate.
    public static func recommendedBitrate(requestedMaxBitrateMbps: Int, latencyMs: Int, packetLossPercent: Double, jitterMs: Int) -> Int {
        var recommended = max(1, requestedMaxBitrateMbps)
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
}
