import Foundation

func webRTCMediaCapabilities(from capabilities: OPNStreamDeviceCapabilities) -> WebRTCMediaDeviceCapabilities {
    WebRTCMediaDeviceCapabilities(
        h264HardwareDecodeSupported: capabilities.h264HardwareDecodeSupported,
        h265HardwareDecodeSupported: capabilities.h265HardwareDecodeSupported,
        av1HardwareDecodeSupported: capabilities.av1HardwareDecodeSupported,
        hdrDisplaySupported: capabilities.hdrDisplaySupported,
        maxDisplayWidth: capabilities.maxDisplayWidth,
        maxDisplayHeight: capabilities.maxDisplayHeight,
        maxDisplayRefreshRate: capabilities.maxDisplayRefreshRate,
        displayDpi: capabilities.displayDpi,
        connectedGamepadCount: NativeWebRTCGamepadMonitor.connectedGamepadCount()
    )
}

func webRTCMediaCloudVariables(from variables: OPNStreamCloudVariables) -> WebRTCMediaCloudVariables {
    WebRTCMediaCloudVariables(
        fetched: variables.fetched,
        allowH265: variables.allowH265,
        allowAV1: variables.allowAV1,
        allowHDR: variables.allowHDR,
        allowL4S: variables.allowL4S,
        allowReflex: variables.allowReflex,
        allowPrefilter: variables.allowPrefilter,
        supportedPrefilterModes: variables.supportedPrefilterModes,
        maxBitrateMbps: variables.maxBitrateMbps
    )
}

func webRTCMediaProfile(from profile: OPNStreamPreferenceProfile) -> WebRTCMediaStreamProfile {
    WebRTCMediaStreamProfile(
        resolution: WebRTCMediaResolution(width: profile.resolution.width, height: profile.resolution.height),
        fps: profile.fps,
        codec: profile.codec.value,
        colorQuality: profile.colorQuality.value,
        maxBitrateMbps: profile.maxBitrateMbps,
        prefilterMode: profile.prefilterMode,
        prefilterSharpness: profile.prefilterSharpness,
        prefilterDenoise: profile.prefilterDenoise,
        prefilterModel: profile.prefilterModel,
        enableL4S: profile.enableL4S,
        enableHdr: profile.enableHdr,
        transportMode: profile.transportMode.value,
        streamingQualityProfile: profile.streamingQualityProfile,
        enableCloudGsync: profile.enableCloudGsync,
        fallbackToLogicalResolution: profile.fallbackToLogicalResolution,
        hudStreamingMode: profile.hudStreamingMode,
        sdrColorSpace: profile.sdrColorSpace,
        hdrColorSpace: profile.hdrColorSpace,
        enablePowerSaver: profile.enablePowerSaver,
        microphoneMode: profile.microphoneMode,
        microphoneDeviceId: profile.microphoneDeviceId,
        microphonePushToTalkKeyCode: profile.microphonePushToTalkKeyCode,
        microphonePushToTalkModifierMask: profile.microphonePushToTalkModifierMask,
        gameVolume: profile.gameVolume,
        microphoneVolume: profile.microphoneVolume,
        upscalingMode: profile.upscalingMode,
        upscalingSharpness: profile.upscalingSharpness,
        upscalingDenoise: profile.upscalingDenoise,
        upscalingTargetHeight: profile.upscalingTargetHeight,
        suppressInputWhenInactive: profile.suppressInputWhenInactive,
        directMouseInput: profile.directMouseInput,
        antiAFKMouseMovementEnabled: profile.antiAFKMouseMovementEnabled,
        preventDisplaySleepWhileStreaming: profile.preventDisplaySleepWhileStreaming,
        recordingVideoBitrateMbps: profile.recordingVideoBitrateMbps,
        recordingAudioBitrateKbps: profile.recordingAudioBitrateKbps,
        recordingEnhancedVideoEnabled: profile.recordingEnhancedVideoEnabled
    )
}

func webRTCMediaProfile(from settings: [String: Any]) -> WebRTCMediaStreamProfile {
    let resolutionParts = bridgeString(settings["resolution"], fallback: "1920x1080").split(separator: "x").compactMap { Int($0) }
    return WebRTCMediaStreamProfile(
        resolution: WebRTCMediaResolution(width: resolutionParts.first ?? 1920, height: resolutionParts.count > 1 ? resolutionParts[1] : 1080),
        fps: bridgeInt(settings["fps"], fallback: 60),
        codec: bridgeString(settings["codec"], fallback: "H264"),
        colorQuality: bridgeString(settings["colorQuality"], fallback: "8bit_420"),
        maxBitrateMbps: bridgeInt(settings["maxBitrateMbps"], fallback: 50),
        prefilterMode: bridgeInt(settings["prefilterMode"]),
        prefilterSharpness: bridgeInt(settings["prefilterSharpness"]),
        prefilterDenoise: bridgeInt(settings["prefilterDenoise"]),
        prefilterModel: bridgeInt(settings["prefilterModel"]),
        enableL4S: bridgeBool(settings["enableL4S"]),
        enableHdr: bridgeBool(settings["enableHdr"]),
        transportMode: bridgeString(settings["transportMode"], fallback: "webrtc"),
        streamingQualityProfile: bridgeInt(settings["streamingQualityProfile"]),
        enableCloudGsync: bridgeBool(settings["enableCloudGsync"]),
        fallbackToLogicalResolution: bridgeBool(settings["fallbackToLogicalResolution"]),
        hudStreamingMode: bridgeInt(settings["hudStreamingMode"]),
        sdrColorSpace: bridgeInt(settings["sdrColorSpace"], fallback: 2),
        hdrColorSpace: bridgeInt(settings["hdrColorSpace"]),
        enablePowerSaver: false,
        microphoneMode: bridgeString(settings["microphoneMode"], fallback: "disabled"),
        microphoneDeviceId: bridgeString(settings["microphoneDeviceId"]),
        microphonePushToTalkKeyCode: bridgeInt(settings["microphonePushToTalkKeyCode"], fallback: 9),
        microphonePushToTalkModifierMask: bridgeInt(settings["microphonePushToTalkModifierMask"]),
        gameVolume: bridgeDouble(settings["gameVolume"], fallback: 1),
        microphoneVolume: bridgeDouble(settings["microphoneVolume"], fallback: 1),
        upscalingMode: bridgeInt(settings["upscalingMode"]),
        upscalingSharpness: bridgeInt(settings["upscalingSharpness"], fallback: 10),
        upscalingDenoise: bridgeInt(settings["upscalingDenoise"]),
        upscalingTargetHeight: bridgeInt(settings["upscalingTargetHeight"], fallback: 2160),
        suppressInputWhenInactive: bridgeBool(settings["suppressInputWhenInactive"], fallback: true),
        directMouseInput: bridgeBool(settings["directMouseInput"], fallback: true),
        antiAFKMouseMovementEnabled: bridgeBool(settings["antiAFKMouseMovementEnabled"]),
        preventDisplaySleepWhileStreaming: bridgeBool(settings["preventDisplaySleepWhileStreaming"], fallback: true),
        recordingVideoBitrateMbps: bridgeInt(settings["recordingVideoBitrateMbps"]),
        recordingAudioBitrateKbps: bridgeInt(settings["recordingAudioBitrateKbps"], fallback: 160),
        recordingEnhancedVideoEnabled: bridgeBool(settings["recordingEnhancedVideoEnabled"], fallback: true)
    )
}

private func bridgeString(_ value: Any?, fallback: String = "") -> String {
    if let value = value as? String { return value.isEmpty ? fallback : value }
    if let value = value as? NSString { let string = value as String; return string.isEmpty ? fallback : string }
    if let value = value as? NSNumber { return value.stringValue }
    return fallback
}

private func bridgeInt(_ value: Any?, fallback: Int = 0) -> Int {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? String { return Int(value) ?? fallback }
    return fallback
}

private func bridgeDouble(_ value: Any?, fallback: Double = 0) -> Double {
    if let value = value as? Double { return value }
    if let value = value as? NSNumber { return value.doubleValue }
    if let value = value as? String { return Double(value) ?? fallback }
    return fallback
}

private func bridgeBool(_ value: Any?, fallback: Bool = false) -> Bool {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    if let value = value as? String { return value == "1" || value.caseInsensitiveCompare("true") == .orderedSame || value.caseInsensitiveCompare("yes") == .orderedSame }
    return fallback
}
