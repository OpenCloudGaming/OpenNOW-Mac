//
//  OPNStreamPreferences+Settings.swift
//  OpenNOW
//
//  Fetching regions and running the network preflight, plus the per-setting writers behind
//  them. Split out of OPNStreamPreferences.swift.
//

import AppKit
import CoreAudio
import CoreMedia
import Foundation
import VideoToolbox

extension OPNStreamPreferences {
    public static func fetchRegions(token: String, providerStreamingBaseUrl: String, completion: @escaping @MainActor @Sendable ([OPNStreamRegionOption]) -> Void) {
        let baseUrl = providerStreamingBaseUrl.isEmpty ? defaultStreamingBaseUrl : providerStreamingBaseUrl
        var request = serverInfoRequest(baseUrl: baseUrl, token: token)
        request.timeoutInterval = 4
        let networkStart = OPNNetworkLog.start(&request, operation: "stream.fetchRegions")
        let tracedRequest = request
        URLSession.shared.dataTask(with: tracedRequest) { data, response, error in
            OPNNetworkLog.finish(tracedRequest, operation: "stream.fetchRegions", startedAt: networkStart, data: data, response: response, error: error)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard error == nil, let data, status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                Task { @MainActor in completion(loadCachedRegions()) }
                return
            }
            let serverInfo = CloudMatchServerInfoParser.parse(json)
            saveDetectedLocalRegionName(serverInfo.detectedLocalZone?.name ?? "")
            let regions = serverInfo.zones.values
                .sorted { $0.name < $1.name }
                .compactMap { zone -> OPNStreamRegionOption? in
                    let url = cloudMatchRegionBaseUrl(address: zone.address)
                    guard !url.isEmpty else { return nil }
                    return OPNStreamRegionOption(name: zone.name, url: url)
                }
            if regions.isEmpty {
                Task { @MainActor in completion(loadCachedRegions()) }
                return
            }
            measureRegions(regions, token: token, completion: completion)
        }.resume()
    }

    public static func fetchServerType(token: String, streamingBaseUrl: String) async throws -> Int? {
        let baseUrl = streamingBaseUrl.isEmpty ? defaultStreamingBaseUrl : streamingBaseUrl
        var request = serverInfoRequest(baseUrl: baseUrl, token: token, headers: .streamSession(transportMode: "nvst"))
        request.timeoutInterval = 4
        let (data, response) = try await OPNURLSessionHTTPTransport.send(request, operation: "stream.fetchServerType", invalidHTTPResponseError: URLError(.badServerResponse))
        guard response.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let parsed = Int(CloudMatchServerInfoParser.parse(json).serverType.trimmingCharacters(in: .whitespacesAndNewlines)),
              parsed > 0 else { return nil }
        return parsed
    }

    public static func runNetworkPreflight(token: String, providerStreamingBaseUrl: String, requestedMaxBitrateMbps: Int, completion: @escaping @MainActor @Sendable (OPNStreamNetworkPreflightResult) -> Void) {
        var initial = OPNStreamNetworkPreflightResult()
        initial.streamingBaseUrl = loadSelectedStreamingBaseUrl()
        initial.networkType = currentNetworkType()
        initial.recommendedMaxBitrateMbps = max(1, requestedMaxBitrateMbps)
        let initialResult = initial

        let selectedRegionUrl = loadSelectedRegionUrl()
        let cachedRegions = loadCachedRegions()
        let cachedChoice = selectedRegionUrl.isEmpty ? cachedRegions.first { !$0.url.isEmpty && $0.latencyMs >= 0 } : cachedRegionChoice(regions: cachedRegions, selectedRegionUrl: selectedRegionUrl)
        if let cachedChoice, !cachedChoice.url.isEmpty {
            var cached = initial
            if !selectedRegionUrl.isEmpty { cached.streamingBaseUrl = normalizedBaseUrl(cachedChoice.url) }
            cached.latencyMs = cachedChoice.latencyMs
            cached.usedAutomaticRegion = selectedRegionUrl.isEmpty
            cached.recommendedMaxBitrateMbps = recommendedBitrate(requestedMaxBitrateMbps: requestedMaxBitrateMbps, latencyMs: cached.latencyMs, packetLossPercent: cached.packetLossPercent, jitterMs: cached.jitterMs)
            fetchRegions(token: token, providerStreamingBaseUrl: providerStreamingBaseUrl) { _ in }
            finishNetworkPreflight(cached, token: token, providerStreamingBaseUrl: providerStreamingBaseUrl, requestedMaxBitrateMbps: requestedMaxBitrateMbps, completion: completion)
            return
        }
        fetchRegions(token: token, providerStreamingBaseUrl: providerStreamingBaseUrl) { regions in
            var result = initialResult
            if let chosen = cachedRegionChoice(regions: regions, selectedRegionUrl: selectedRegionUrl), !chosen.url.isEmpty {
                if !selectedRegionUrl.isEmpty { result.streamingBaseUrl = normalizedBaseUrl(chosen.url) }
                result.latencyMs = chosen.latencyMs
                result.usedAutomaticRegion = selectedRegionUrl.isEmpty
            }
            result.recommendedMaxBitrateMbps = recommendedBitrate(requestedMaxBitrateMbps: requestedMaxBitrateMbps, latencyMs: result.latencyMs, packetLossPercent: result.packetLossPercent, jitterMs: result.jitterMs)
            finishNetworkPreflight(result, token: token, providerStreamingBaseUrl: providerStreamingBaseUrl, requestedMaxBitrateMbps: requestedMaxBitrateMbps, completion: completion)
        }
    }

    public static func saveAspectIndex(_ aspectIndex: Int) {
        let clamped = clamp(aspectIndex, 0, aspectOptions.count - 1)
        storage.set(clamped, forKey: k.aspectIndex)
        let resolutions = resolutionOptions(forAspect: clamped)
        let currentResolution = clampedStoredInt(k.resolutionIndex, defaultResolutionIndex(forAspect: clamped), resolutions.count)
        storage.set(currentResolution, forKey: k.resolutionIndex)
    }

    public static func saveResolutionIndex(_ value: Int) { storage.set(clamp(value, 0, resolutionOptions(forAspect: loadProfile().aspectIndex).count - 1), forKey: k.resolutionIndex) }
    public static func saveFpsIndex(_ value: Int) { storage.set(clamp(value, 0, fpsOptions.count - 1), forKey: k.fpsIndex) }
    public static func saveCodecIndex(_ value: Int) { storage.set(clamp(value, 0, codecOptions.count - 1), forKey: k.codecIndex) }
    public static func saveBitrateIndex(_ value: Int) { storage.set(clamp(value, 0, bitrateOptions.count - 1), forKey: k.bitrateIndex) }
    public static func saveColorQualityIndex(_ value: Int) { storage.set(clamp(value, 0, colorQualityOptions.count - 1), forKey: k.colorQualityIndex) }
    public static func saveTransportModeIndex(_ value: Int) { storage.set(clamp(value, 0, transportModeOptions.count - 1), forKey: k.transportModeIndex) }
    public static func saveNVSTTransportEnabled(_ value: Bool) { saveTransportModeIndex(value ? 1 : 0) }
    public static func saveStreamingQualityProfileIndex(_ value: Int) {
        let index = clamp(value, 0, streamingQualityProfileOptions.count - 1)
        storage.set(index, forKey: k.streamingQualityProfileIndex)
        if let preset = streamingQualityPreset(for: index) {
            saveStreamingQualityPreset(preset)
        }
        storage.synchronize()
    }
    public static func saveCloudGsyncEnabled(_ value: Bool) { storage.set(value, forKey: k.cloudGsyncEnabled) }
    public static func saveFallbackToLogicalResolution(_ value: Bool) { storage.set(value, forKey: k.fallbackToLogicalResolution) }
    public static func saveHudStreamingModeIndex(_ value: Int) { storage.set(clamp(value, 0, hudStreamingModeOptions.count - 1), forKey: k.hudStreamingModeIndex) }
    public static func saveSDRColorSpaceIndex(_ value: Int) { storage.set(clamp(value, 0, colorSpaceOptions.count - 1), forKey: k.sdrColorSpaceIndex) }
    public static func saveHDRColorSpaceIndex(_ value: Int) { storage.set(clamp(value, 0, colorSpaceOptions.count - 1), forKey: k.hdrColorSpaceIndex) }
    public static func savePrefilterModeIndex(_ value: Int) { saveCanonicalInt(k.prefilterModeIndex, clamp(value, 0, prefilterModeOptions.count - 1)) }
    public static func savePrefilterSharpness(_ value: Int) { saveCanonicalInt(k.prefilterSharpness, clamp(value, 0, 10)) }
    public static func savePrefilterDenoise(_ value: Int) { saveCanonicalInt(k.prefilterDenoise, clamp(value, 0, 10)) }
    public static func saveUpscalingModeIndex(_ value: Int) { storage.set(normalizedUpscalingModeIndex(value), forKey: k.upscalingModeIndex) }
    public static func saveUpscalingTargetIndex(_ value: Int) { storage.set(clamp(value, 0, upscalingTargetOptions.count - 1), forKey: k.upscalingTargetIndex) }
    public static func saveUpscalingSharpness(_ value: Int) { storage.set(clamp(value, 0, 15), forKey: k.upscalingSharpness) }
    public static func saveUpscalingDenoise(_ value: Int) { storage.set(clamp(value, 0, 20), forKey: k.upscalingDenoise) }
    public static func saveUpscalingSettings(mode: Int, sharpness: Int, denoise: Int, forGame appId: String = "") {
        let modeIndex = normalizedUpscalingModeIndex(forMode: mode)
        let sharpness = clamp(sharpness, 0, 15)
        let denoise = clamp(denoise, 0, 20)
        if !appId.isEmpty, var profile = loadProfile(forGame: appId) {
            applyUpscalingSettings(to: &profile, modeIndex: modeIndex, sharpness: sharpness, denoise: denoise)
            saveProfile(forGame: appId, profile: profile)
            return
        }
        storage.set(modeIndex, forKey: k.upscalingModeIndex)
        storage.set(sharpness, forKey: k.upscalingSharpness)
        storage.set(denoise, forKey: k.upscalingDenoise)
    }
    public static func savePillarboxFillModeIndex(_ value: Int) { storage.set(normalizedPillarboxFillModeIndex(value), forKey: k.pillarboxFillModeIndex) }
    public static func savePillarboxFillColor(_ value: String) { storage.set(normalizedPillarboxFillColor(value), forKey: k.pillarboxFillColor) }
    public static func savePillarboxFillDim(_ value: Int) { storage.set(clamp(value, 0, 100), forKey: k.pillarboxFillDim) }
    public static func saveRecordingVideoBitrateMbps(_ value: Int) { storage.set(clamp(value, 0, 200), forKey: k.recordingVideoBitrateMbps) }
    public static func saveRecordingAudioBitrateKbps(_ value: Int) { storage.set(clamp(value, 64, 320), forKey: k.recordingAudioBitrateKbps) }
    public static func saveRecordingEnhancedVideoEnabled(_ value: Bool) { storage.set(value, forKey: k.recordingEnhancedVideoEnabled) }
    public static func saveL4SEnabled(_ value: Bool) { storage.set(value, forKey: k.l4sEnabled) }
    public static func saveHDREnabled(_ value: Bool) { storage.set(value, forKey: k.hdrEnabled) }
    public static func savePowerSaverEnabled(_ value: Bool) { storage.set(value, forKey: k.powerSaverEnabled) }
    public static func saveSuppressInputWhenInactive(_ value: Bool) { storage.set(value, forKey: k.suppressInputWhenInactive) }
    public static func saveDirectMouseInputEnabled(_ value: Bool) { storage.set(value, forKey: k.directMouseInput) }
    public static func saveAntiAFKMouseMovementEnabled(_ value: Bool) { storage.set(value, forKey: k.antiAFKMouseMovementEnabled) }
    public static func savePreventDisplaySleepWhileStreaming(_ value: Bool) { storage.set(value, forKey: k.preventDisplaySleepWhileStreaming) }
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
        storage.removeObject(forKey: "OpenNOW.Stream.LowLatencyModeEnabled")
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

    static func profile(from dictionary: [String: Any]?) -> OPNStreamPreferenceProfile {
        var profile = OPNStreamPreferenceProfile()
        applyVideoSettings(&profile, dictionary)
        applyColorSettings(&profile, dictionary)
        applyUpscalingSettings(&profile, dictionary)
        applyCaptureSettings(&profile, dictionary)
        applyAudioSettings(&profile, dictionary)
        if let preset = streamingQualityPreset(for: profile.streamingQualityProfileIndex) {
            applyStreamingQualityPreset(preset, to: &profile)
        }
        return profile
    }

    /// Aspect, resolution, frame rate, codec, bitrate and the quality profile they roll up into.
    static func applyVideoSettings(_ profile: inout OPNStreamPreferenceProfile, _ dictionary: [String: Any]?) {
        profile.aspectIndex = clampedInt(dictionary, k.aspectIndex, 1, aspectOptions.count)
        profile.aspect = aspectOptions[profile.aspectIndex]
        let resolutions = resolutionOptions(forAspect: profile.aspectIndex)
        profile.resolutionIndex = clampedInt(dictionary, k.resolutionIndex, defaultResolutionIndex(forAspect: profile.aspectIndex), resolutions.count)
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
        profile.transportModeIndex = clampedInt(dictionary, k.transportModeIndex, 0, transportModeOptions.count)
        profile.transportMode = transportModeOptions[profile.transportModeIndex]
        profile.streamingQualityProfileIndex = clampedInt(dictionary, k.streamingQualityProfileIndex, 0, streamingQualityProfileOptions.count)
        profile.streamingQualityProfileOption = streamingQualityProfileOptions[profile.streamingQualityProfileIndex]
        profile.streamingQualityProfile = profile.streamingQualityProfileOption.value
        profile.enableCloudGsync = bool(value(dictionary, k.cloudGsyncEnabled), false)
        profile.fallbackToLogicalResolution = bool(value(dictionary, k.fallbackToLogicalResolution), false)
        profile.hudStreamingModeIndex = clampedInt(dictionary, k.hudStreamingModeIndex, 0, hudStreamingModeOptions.count)
        profile.hudStreamingModeOption = hudStreamingModeOptions[profile.hudStreamingModeIndex]
        profile.hudStreamingMode = profile.hudStreamingModeOption.value
    }

    /// Colour spaces and the server-side prefilter.
    static func applyColorSettings(_ profile: inout OPNStreamPreferenceProfile, _ dictionary: [String: Any]?) {
        profile.sdrColorSpaceIndex = clampedInt(dictionary, k.sdrColorSpaceIndex, 2, colorSpaceOptions.count)
        profile.sdrColorSpaceOption = colorSpaceOptions[profile.sdrColorSpaceIndex]
        profile.sdrColorSpace = profile.sdrColorSpaceOption.value
        profile.hdrColorSpaceIndex = clampedInt(dictionary, k.hdrColorSpaceIndex, 0, colorSpaceOptions.count)
        profile.hdrColorSpaceOption = colorSpaceOptions[profile.hdrColorSpaceIndex]
        profile.hdrColorSpace = profile.hdrColorSpaceOption.value
        profile.prefilterModeIndex = clampedInt(dictionary, k.prefilterModeIndex, 0, prefilterModeOptions.count)
        profile.prefilterModeOption = prefilterModeOptions[profile.prefilterModeIndex]
        profile.prefilterMode = profile.prefilterModeOption.value
        profile.prefilterSharpness = clampedInt(dictionary, k.prefilterSharpness, 0, 11)
        profile.prefilterDenoise = clampedInt(dictionary, k.prefilterDenoise, 0, 11)
    }

    /// Client-side upscaling and how the pillarbox bars are filled.
    static func applyUpscalingSettings(_ profile: inout OPNStreamPreferenceProfile, _ dictionary: [String: Any]?) {
        profile.upscalingModeIndex = storedUpscalingModeIndex(dictionary)
        profile.upscalingModeOption = upscalingModeOptions[profile.upscalingModeIndex]
        profile.upscalingMode = profile.upscalingModeOption.value
        profile.upscalingTargetIndex = storedUpscalingTargetIndex(dictionary)
        profile.upscalingTargetOption = upscalingTargetOptions[profile.upscalingTargetIndex]
        profile.upscalingTargetHeight = profile.upscalingTargetOption.height
        profile.upscalingSharpness = clampedInt(dictionary, k.upscalingSharpness, 10, 16)
        profile.upscalingDenoise = clampedInt(dictionary, k.upscalingDenoise, 0, 21)
        profile.pillarboxFillModeIndex = storedPillarboxFillModeIndex(dictionary)
        profile.pillarboxFillMode = OPNPillarboxFillMode.from(profile.pillarboxFillModeIndex)
        profile.pillarboxFillColor = normalizedPillarboxFillColor(string(value(dictionary, k.pillarboxFillColor), defaultPillarboxFillColor))
        profile.pillarboxFillDim = clampedInt(dictionary, k.pillarboxFillDim, 55, 101)
    }

    /// Recording output plus the per-session behaviour toggles.
    static func applyCaptureSettings(_ profile: inout OPNStreamPreferenceProfile, _ dictionary: [String: Any]?) {
        profile.recordingVideoBitrateMbps = clampedInt(dictionary, k.recordingVideoBitrateMbps, 0, 201)
        profile.recordingAudioBitrateKbps = Int(clampedDouble(dictionary, k.recordingAudioBitrateKbps, 160, 64, 320).rounded())
        profile.recordingEnhancedVideoEnabled = bool(value(dictionary, k.recordingEnhancedVideoEnabled), true)
        profile.enableL4S = bool(value(dictionary, k.l4sEnabled), false)
        profile.enableHdr = bool(value(dictionary, k.hdrEnabled), false)
        profile.enablePowerSaver = bool(value(dictionary, k.powerSaverEnabled), false)
        profile.suppressInputWhenInactive = bool(value(dictionary, k.suppressInputWhenInactive), true)
        profile.directMouseInput = bool(value(dictionary, k.directMouseInput), true)
        profile.antiAFKMouseMovementEnabled = bool(value(dictionary, k.antiAFKMouseMovementEnabled), false)
        profile.preventDisplaySleepWhileStreaming = bool(value(dictionary, k.preventDisplaySleepWhileStreaming), true)
    }

    /// Volumes, microphone routing and the selected region.
    static func applyAudioSettings(_ profile: inout OPNStreamPreferenceProfile, _ dictionary: [String: Any]?) {
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
    }

    static func dictionary(from profile: OPNStreamPreferenceProfile, enabled: Bool) -> [String: Any] {
        var dictionary: [String: Any] = [
            k.gameProfileEnabled: enabled,
            k.aspectIndex: profile.aspectIndex,
            k.resolutionIndex: profile.resolutionIndex,
            k.fpsIndex: profile.fpsIndex,
            k.codecIndex: profile.codecIndex,
            k.bitrateIndex: profile.bitrateIndex,
            k.colorQualityIndex: profile.colorQualityIndex,
            k.transportModeIndex: profile.transportModeIndex,
            k.streamingQualityProfileIndex: profile.streamingQualityProfileIndex,
            k.cloudGsyncEnabled: profile.enableCloudGsync,
            k.fallbackToLogicalResolution: profile.fallbackToLogicalResolution,
            k.hudStreamingModeIndex: profile.hudStreamingModeIndex,
            k.sdrColorSpaceIndex: profile.sdrColorSpaceIndex,
            k.hdrColorSpaceIndex: profile.hdrColorSpaceIndex,
            k.prefilterModeIndex: profile.prefilterModeIndex,
            k.prefilterSharpness: profile.prefilterSharpness,
            k.prefilterDenoise: profile.prefilterDenoise,
            k.upscalingModeIndex: profile.upscalingModeIndex,
            k.upscalingTargetIndex: profile.upscalingTargetIndex,
            k.upscalingSharpness: profile.upscalingSharpness,
            k.upscalingDenoise: profile.upscalingDenoise,
            k.pillarboxFillModeIndex: profile.pillarboxFillModeIndex,
            k.pillarboxFillColor: profile.pillarboxFillColor,
            k.pillarboxFillDim: profile.pillarboxFillDim,
            k.recordingVideoBitrateMbps: profile.recordingVideoBitrateMbps,
            k.recordingAudioBitrateKbps: profile.recordingAudioBitrateKbps,
            k.recordingEnhancedVideoEnabled: profile.recordingEnhancedVideoEnabled,
            k.l4sEnabled: profile.enableL4S,
            k.hdrEnabled: profile.enableHdr,
            k.powerSaverEnabled: profile.enablePowerSaver,
            k.suppressInputWhenInactive: profile.suppressInputWhenInactive,
            k.directMouseInput: profile.directMouseInput,
            k.antiAFKMouseMovementEnabled: profile.antiAFKMouseMovementEnabled,
            k.preventDisplaySleepWhileStreaming: profile.preventDisplaySleepWhileStreaming,
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

    static func firstSupportedCodecIndex(_ capabilities: OPNStreamDeviceCapabilities) -> Int {
        if let h264Index = codecOptions.firstIndex(where: { $0.value == "H264" && codecSupported($0, capabilities: capabilities) }) { return h264Index }
        return codecOptions.firstIndex(where: { codecSupported($0, capabilities: capabilities) }) ?? 0
    }

    static func nearestSupportedFpsIndex(_ requestedFps: Int, _ capabilities: OPNStreamDeviceCapabilities) -> Int {
        var fallbackIndex = 0
        var fallbackFps = fpsOptions.first ?? 60
        for (index, fps) in fpsOptions.enumerated() where fpsSupported(fps, capabilities: capabilities) && fps <= requestedFps && fps >= fallbackFps {
            fallbackIndex = index
            fallbackFps = fps
        }
        return fallbackIndex
    }

    static func streamingQualityPreset(for index: Int) -> StreamingQualityPreset? {
        switch index {
        case 1:
            return StreamingQualityPreset(aspectIndex: 1, resolutionIndex: 3, fpsIndex: 1, codecIndex: 0, bitrateIndex: 2, colorQualityIndex: 0, cloudGsyncEnabled: false, fallbackToLogicalResolution: false, hudStreamingModeIndex: 0, sdrColorSpaceIndex: 2, hdrColorSpaceIndex: 0, l4sEnabled: false, hdrEnabled: false, powerSaverEnabled: false)
        case 2:
            return StreamingQualityPreset(aspectIndex: 1, resolutionIndex: 3, fpsIndex: 2, codecIndex: 0, bitrateIndex: 2, colorQualityIndex: 0, cloudGsyncEnabled: false, fallbackToLogicalResolution: false, hudStreamingModeIndex: 0, sdrColorSpaceIndex: 2, hdrColorSpaceIndex: 0, l4sEnabled: true, hdrEnabled: false, powerSaverEnabled: false)
        case 3:
            return StreamingQualityPreset(aspectIndex: 1, resolutionIndex: 0, fpsIndex: 0, codecIndex: 0, bitrateIndex: 0, colorQualityIndex: 0, cloudGsyncEnabled: false, fallbackToLogicalResolution: false, hudStreamingModeIndex: 0, sdrColorSpaceIndex: 2, hdrColorSpaceIndex: 0, l4sEnabled: false, hdrEnabled: false, powerSaverEnabled: true)
        case 4:
            return StreamingQualityPreset(aspectIndex: 1, resolutionIndex: 5, fpsIndex: 1, codecIndex: 3, bitrateIndex: 3, colorQualityIndex: 2, cloudGsyncEnabled: false, fallbackToLogicalResolution: false, hudStreamingModeIndex: 0, sdrColorSpaceIndex: 2, hdrColorSpaceIndex: 2, l4sEnabled: false, hdrEnabled: true, powerSaverEnabled: false)
        default:
            return nil
        }
    }

    static func applyStreamingQualityPreset(_ preset: StreamingQualityPreset, to profile: inout OPNStreamPreferenceProfile) {
        profile.aspectIndex = clamp(preset.aspectIndex, 0, aspectOptions.count - 1)
        profile.aspect = aspectOptions[profile.aspectIndex]
        let resolutions = resolutionOptions(forAspect: profile.aspectIndex)
        profile.resolutionIndex = clamp(preset.resolutionIndex, 0, resolutions.count - 1)
        profile.resolution = resolutions[profile.resolutionIndex]
        profile.fpsIndex = clamp(preset.fpsIndex, 0, fpsOptions.count - 1)
        profile.fps = fpsOptions[profile.fpsIndex]
        profile.codecIndex = clamp(preset.codecIndex, 0, codecOptions.count - 1)
        profile.codec = codecOptions[profile.codecIndex]
        profile.bitrateIndex = clamp(preset.bitrateIndex, 0, bitrateOptions.count - 1)
        profile.bitrate = bitrateOptions[profile.bitrateIndex]
        profile.maxBitrateMbps = profile.bitrate.mbps
        profile.colorQualityIndex = clamp(preset.colorQualityIndex, 0, colorQualityOptions.count - 1)
        profile.colorQuality = colorQualityOptions[profile.colorQualityIndex]
        profile.enableCloudGsync = preset.cloudGsyncEnabled
        profile.fallbackToLogicalResolution = preset.fallbackToLogicalResolution
        profile.hudStreamingModeIndex = clamp(preset.hudStreamingModeIndex, 0, hudStreamingModeOptions.count - 1)
        profile.hudStreamingModeOption = hudStreamingModeOptions[profile.hudStreamingModeIndex]
        profile.hudStreamingMode = profile.hudStreamingModeOption.value
        profile.sdrColorSpaceIndex = clamp(preset.sdrColorSpaceIndex, 0, colorSpaceOptions.count - 1)
        profile.sdrColorSpaceOption = colorSpaceOptions[profile.sdrColorSpaceIndex]
        profile.sdrColorSpace = profile.sdrColorSpaceOption.value
        profile.hdrColorSpaceIndex = clamp(preset.hdrColorSpaceIndex, 0, colorSpaceOptions.count - 1)
        profile.hdrColorSpaceOption = colorSpaceOptions[profile.hdrColorSpaceIndex]
        profile.hdrColorSpace = profile.hdrColorSpaceOption.value
        profile.enableL4S = preset.l4sEnabled
        profile.enableHdr = preset.hdrEnabled
        profile.enablePowerSaver = preset.powerSaverEnabled
    }

    static func saveStreamingQualityPreset(_ preset: StreamingQualityPreset) {
        let aspectIndex = clamp(preset.aspectIndex, 0, aspectOptions.count - 1)
        let resolutionIndex = clamp(preset.resolutionIndex, 0, resolutionOptions(forAspect: aspectIndex).count - 1)
        storage.set(aspectIndex, forKey: k.aspectIndex)
        storage.set(resolutionIndex, forKey: k.resolutionIndex)
        storage.set(clamp(preset.fpsIndex, 0, fpsOptions.count - 1), forKey: k.fpsIndex)
        storage.set(clamp(preset.codecIndex, 0, codecOptions.count - 1), forKey: k.codecIndex)
        storage.set(clamp(preset.bitrateIndex, 0, bitrateOptions.count - 1), forKey: k.bitrateIndex)
        storage.set(clamp(preset.colorQualityIndex, 0, colorQualityOptions.count - 1), forKey: k.colorQualityIndex)
        storage.set(preset.cloudGsyncEnabled, forKey: k.cloudGsyncEnabled)
        storage.set(preset.fallbackToLogicalResolution, forKey: k.fallbackToLogicalResolution)
        storage.set(clamp(preset.hudStreamingModeIndex, 0, hudStreamingModeOptions.count - 1), forKey: k.hudStreamingModeIndex)
        storage.set(clamp(preset.sdrColorSpaceIndex, 0, colorSpaceOptions.count - 1), forKey: k.sdrColorSpaceIndex)
        storage.set(clamp(preset.hdrColorSpaceIndex, 0, colorSpaceOptions.count - 1), forKey: k.hdrColorSpaceIndex)
        storage.set(preset.l4sEnabled, forKey: k.l4sEnabled)
        storage.set(preset.hdrEnabled, forKey: k.hdrEnabled)
        storage.set(preset.powerSaverEnabled, forKey: k.powerSaverEnabled)
    }

    static func storedUpscalingTargetIndex(_ dictionary: [String: Any]?) -> Int {
        clamp(int(value(dictionary, k.upscalingTargetIndex), defaultUpscalingTargetIndex), 0, upscalingTargetOptions.count - 1)
    }

    static func storedUpscalingModeIndex(_ dictionary: [String: Any]?) -> Int {
        normalizedUpscalingModeIndex(int(value(dictionary, k.upscalingModeIndex), 0))
    }

    /// `index` here is the stored array index, not a mode value. Index 2 (Spatial) is new — it was
    /// never reachable before this file added a third option, so there is no old stored data to
    /// protect there. Indices 3/4 predate even the Off/MetalFX pair and still coalesce to MetalFX.
    static func normalizedUpscalingModeIndex(_ index: Int) -> Int {
        switch index {
        case 0: return 0
        case 1: return 1
        case 2: return 2
        case 3, 4: return 1
        default: return 0
        }
    }

    /// `mode` here is the raw enhancement mode value (0/2/3), not an array index.
    static func normalizedUpscalingModeIndex(forMode mode: Int) -> Int {
        switch mode {
        case 0: return 0
        case 2: return 2
        case 1, 3, 4: return 1
        default: return 0
        }
    }

    static func applyUpscalingSettings(to profile: inout OPNStreamPreferenceProfile, modeIndex: Int, sharpness: Int, denoise: Int) {
        let modeIndex = clamp(modeIndex, 0, upscalingModeOptions.count - 1)
        profile.upscalingModeIndex = modeIndex
        profile.upscalingModeOption = upscalingModeOptions[modeIndex]
        profile.upscalingMode = profile.upscalingModeOption.value
        profile.upscalingSharpness = clamp(sharpness, 0, 15)
        profile.upscalingDenoise = clamp(denoise, 0, 20)
    }

    static func storedPillarboxFillModeIndex(_ dictionary: [String: Any]?) -> Int {
        normalizedPillarboxFillModeIndex(int(value(dictionary, k.pillarboxFillModeIndex), 0))
    }

    static func normalizedPillarboxFillModeIndex(_ index: Int) -> Int {
        OPNPillarboxFillMode.from(index).rawValue
    }

    static func normalizedPillarboxFillColor(_ value: String) -> String {
        let digits = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit) else { return defaultPillarboxFillColor }
        return "#" + digits.uppercased()
    }

    static func storedPreferenceValue(_ key: String) -> Any? {
        let prefilterKey = key == k.prefilterModeIndex || key == k.prefilterSharpness || key == k.prefilterDenoise
        return storage.storedValue(forKey: key, preferCanonicalDomain: prefilterKey)
    }

    static func saveCanonicalInt(_ key: String, _ value: Int) {
        storage.setCanonicalInt(value, forKey: key)
    }
}
