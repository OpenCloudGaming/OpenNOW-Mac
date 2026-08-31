//  CatalogViewModel+Settings.swift
//  OpenNOW
//

import Foundation

@MainActor
extension CatalogViewModel {
    var streamingQualityProfileAllowsCustomization: Bool {
        streamProfile.allowsStreamingCustomization
    }

    func canEditStreamingQualitySettings() -> Bool {
        streamingQualityProfileAllowsCustomization
    }

    func setAspectIndex(_ index: Int) {
        guard canEditStreamingQualitySettings() else { return }
        OPNStreamPreferences.saveAspectIndex(index)
        loadSettingsPreferences()
    }

    func setResolutionIndex(_ index: Int) {
        guard canEditStreamingQualitySettings() else { return }
        OPNStreamPreferences.saveResolutionIndex(index)
        loadSettingsPreferences()
    }

    func setFpsIndex(_ index: Int) {
        guard canEditStreamingQualitySettings() else { return }
        OPNStreamPreferences.saveFpsIndex(index)
        loadSettingsPreferences()
    }

    func setCodecIndex(_ index: Int) {
        guard canEditStreamingQualitySettings() else { return }
        OPNStreamPreferences.saveCodecIndex(index)
        loadSettingsPreferences()
    }

    func setBitrateIndex(_ index: Int) {
        guard canEditStreamingQualitySettings() else { return }
        OPNStreamPreferences.saveBitrateIndex(index)
        loadSettingsPreferences()
    }

    func setColorQualityIndex(_ index: Int) {
        guard canEditStreamingQualitySettings() else { return }
        OPNStreamPreferences.saveColorQualityIndex(index)
        loadSettingsPreferences()
    }

    func setNVSTTransportEnabled(_ enabled: Bool) {
        OPNStreamPreferences.saveNVSTTransportEnabled(enabled)
        actionMessage = enabled ? "Native/NVST stream transport selected." : "WebRTC stream transport selected."
        loadSettingsPreferences()
    }

    func setStreamingQualityProfileIndex(_ index: Int) {
        OPNStreamPreferences.saveStreamingQualityProfileIndex(index)
        loadSettingsPreferences()
    }

    func setCloudGsyncEnabled(_ enabled: Bool) {
        guard canEditStreamingQualitySettings() else { return }
        OPNStreamPreferences.saveCloudGsyncEnabled(enabled)
        loadSettingsPreferences()
    }

    func setFallbackToLogicalResolution(_ enabled: Bool) {
        guard canEditStreamingQualitySettings() else { return }
        OPNStreamPreferences.saveFallbackToLogicalResolution(enabled)
        loadSettingsPreferences()
    }

    func setHudStreamingModeIndex(_ index: Int) {
        guard canEditStreamingQualitySettings() else { return }
        OPNStreamPreferences.saveHudStreamingModeIndex(index)
        loadSettingsPreferences()
    }

    func setSDRColorSpaceIndex(_ index: Int) {
        guard canEditStreamingQualitySettings() else { return }
        OPNStreamPreferences.saveSDRColorSpaceIndex(index)
        loadSettingsPreferences()
    }

    func setHDRColorSpaceIndex(_ index: Int) {
        guard canEditStreamingQualitySettings() else { return }
        OPNStreamPreferences.saveHDRColorSpaceIndex(index)
        loadSettingsPreferences()
    }

    func setPrefilterModeIndex(_ index: Int) {
        OPNStreamPreferences.savePrefilterModeIndex(index)
        loadSettingsPreferences()
    }

    func setPrefilterSharpness(_ value: Double) {
        OPNStreamPreferences.savePrefilterSharpness(Int(value.rounded()))
        loadSettingsPreferences()
    }

    func setPrefilterDenoise(_ value: Double) {
        OPNStreamPreferences.savePrefilterDenoise(Int(value.rounded()))
        loadSettingsPreferences()
    }

    func setUpscalingModeIndex(_ index: Int) {
        OPNStreamPreferences.saveUpscalingModeIndex(index)
        loadSettingsPreferences()
    }

    func setUpscalingSharpness(_ value: Double) {
        OPNStreamPreferences.saveUpscalingSharpness(Int(value.rounded()))
        loadSettingsPreferences()
    }

    func setUpscalingDenoise(_ value: Double) {
        OPNStreamPreferences.saveUpscalingDenoise(Int(value.rounded()))
        loadSettingsPreferences()
    }

    func setPillarboxFillModeIndex(_ index: Int) {
        OPNStreamPreferences.savePillarboxFillModeIndex(index)
        loadSettingsPreferences()
    }

    func setPillarboxFillColor(_ hex: String) {
        OPNStreamPreferences.savePillarboxFillColor(hex)
        loadSettingsPreferences()
    }

    func setPillarboxFillDim(_ value: Double) {
        OPNStreamPreferences.savePillarboxFillDim(Int(value.rounded()))
        loadSettingsPreferences()
    }

    func setL4SEnabled(_ enabled: Bool) {
        guard canEditStreamingQualitySettings() else { return }
        OPNStreamPreferences.saveL4SEnabled(enabled)
        loadSettingsPreferences()
    }

    func setHDREnabled(_ enabled: Bool) {
        guard canEditStreamingQualitySettings() else { return }
        OPNStreamPreferences.saveHDREnabled(enabled)
        loadSettingsPreferences()
    }

    func setPowerSaverEnabled(_ enabled: Bool) {
        guard canEditStreamingQualitySettings() else { return }
        OPNStreamPreferences.savePowerSaverEnabled(enabled)
        loadSettingsPreferences()
    }

    func setSuppressInputWhenInactive(_ enabled: Bool) {
        OPNStreamPreferences.saveSuppressInputWhenInactive(enabled)
        loadSettingsPreferences()
    }

    func setDirectMouseInputEnabled(_ enabled: Bool) {
        OPNStreamPreferences.saveDirectMouseInputEnabled(enabled)
        loadSettingsPreferences()
    }

    func setAntiAFKMouseMovementEnabled(_ enabled: Bool) {
        OPNStreamPreferences.saveAntiAFKMouseMovementEnabled(enabled)
        actionMessage = enabled ? "Anti-AFK mouse movement enabled." : "Anti-AFK mouse movement disabled."
        loadSettingsPreferences()
    }

    func setRemoteCoOpEnabled(_ enabled: Bool) {
        OPNRemoteCoOpPreferencesStore.setEnabled(enabled)
        remoteCoOpPreferences = OPNRemoteCoOpPreferencesStore.load()
        actionMessage = enabled ? "Remote Co-Op enabled. Reserved guest slots apply to newly launched streams." : "Remote Co-Op disabled."
        loadSettingsPreferences()
    }

    func setRemoteCoOpAlphaOptedIn(_ optedIn: Bool) {
        OPNRemoteCoOpPreferencesStore.setAlphaOptedIn(optedIn)
        remoteCoOpPreferences = OPNRemoteCoOpPreferencesStore.load()
        // Opting out hides the Remote Co-Op tab. Leaving it selected would strand Settings on a
        // page the tab bar no longer draws, with no tab highlighted and no way back except the
        // keyboard.
        if !optedIn, selectedSettingsGroup == .remoteCoOp {
            selectedSettingsGroup = .experimental
        }
        actionMessage = optedIn ? "Remote Co-Op alpha access enabled. Configure Remote Co-Op from Gameplay settings." : "Remote Co-Op alpha access disabled. Remote Co-Op settings are hidden."
        loadSettingsPreferences()
    }

    func setRemoteCoOpReservedGuestSlots(_ index: Int) {
        OPNRemoteCoOpPreferencesStore.setReservedGuestSlots(index)
        remoteCoOpPreferences = OPNRemoteCoOpPreferencesStore.load()
        actionMessage = index > 0 ? "Remote Co-Op will reserve \(index) guest controller slot(s) on newly launched streams." : "Remote Co-Op guest controller slots disabled."
        loadSettingsPreferences()
    }

    func setRemoteCoOpTransportModeIndex(_ index: Int) {
        let modes = OPNRemoteCoOpTransportMode.allCases
        guard modes.indices.contains(index) else { return }
        OPNRemoteCoOpPreferencesStore.setTransportMode(modes[index])
        remoteCoOpPreferences = OPNRemoteCoOpPreferencesStore.load()
        loadSettingsPreferences()
    }

    func setRemoteCoOpQualityPresetIndex(_ index: Int) {
        let presets = OPNRemoteCoOpQualityPreset.allCases
        guard presets.indices.contains(index) else { return }
        OPNRemoteCoOpPreferencesStore.setQualityPreset(presets[index])
        remoteCoOpPreferences = OPNRemoteCoOpPreferencesStore.load()
        loadSettingsPreferences()
    }

    func setRemoteCoOpLatencyModeIndex(_ index: Int) {
        let modes = OPNRemoteCoOpLatencyMode.allCases
        guard modes.indices.contains(index) else { return }
        OPNRemoteCoOpPreferencesStore.setLatencyMode(modes[index])
        remoteCoOpPreferences = OPNRemoteCoOpPreferencesStore.load()
        loadSettingsPreferences()
    }

    func setRemoteCoOpRequireHostApproval(_ required: Bool) {
        OPNRemoteCoOpPreferencesStore.setRequireHostApproval(required)
        remoteCoOpPreferences = OPNRemoteCoOpPreferencesStore.load()
        loadSettingsPreferences()
    }


    func setRemoteCoOpPublicAddress(_ address: String) {
        OPNRemoteCoOpPreferencesStore.setPublicAddress(address)
        remoteCoOpPreferences = OPNRemoteCoOpPreferencesStore.load()
    }




    func setRemoteCoOpHideGuestInviteDetails(_ hidden: Bool) {
        OPNRemoteCoOpPreferencesStore.setHideGuestInviteDetails(hidden)
        remoteCoOpPreferences = OPNRemoteCoOpPreferencesStore.load()
        actionMessage = hidden ? "Remote Co-Op guest invites will hide game details." : "Remote Co-Op guest invites will show game details."
        loadSettingsPreferences()
    }

    func setPreventDisplaySleepWhileStreaming(_ enabled: Bool) {
        OPNStreamPreferences.savePreventDisplaySleepWhileStreaming(enabled)
        actionMessage = enabled ? "Display sleep prevention enabled for active streams." : "Display sleep prevention disabled for active streams."
        loadSettingsPreferences()
    }

    func setRecordingVideoBitrateMbps(_ value: Double) {
        OPNStreamPreferences.saveRecordingVideoBitrateMbps(Int(value.rounded()))
        loadSettingsPreferences()
    }

    func setRecordingAudioBitrateKbps(_ value: Double) {
        OPNStreamPreferences.saveRecordingAudioBitrateKbps(Int(value.rounded()))
        loadSettingsPreferences()
    }

    func setRecordingEnhancedVideoEnabled(_ enabled: Bool) {
        OPNStreamPreferences.saveRecordingEnhancedVideoEnabled(enabled)
        loadSettingsPreferences()
    }

    func setGameVolume(_ value: Double) {
        OPNStreamPreferences.saveGameVolume(value)
        loadSettingsPreferences()
    }

    func setMicrophoneVolume(_ value: Double) {
        OPNStreamPreferences.saveMicrophoneVolume(value)
        loadSettingsPreferences()
    }

    func setMicrophoneMode(_ mode: String) {
        OPNStreamPreferences.saveMicrophoneMode(mode)
        loadSettingsPreferences()
    }

    func setMicrophoneDeviceId(_ deviceId: String) {
        OPNStreamPreferences.saveMicrophoneDeviceId(deviceId)
        loadSettingsPreferences()
    }

    func restoreStreamingProfileDefaults() {
        OPNStreamPreferences.restoreStreamingProfileDefaults()
        actionMessage = "Streaming profile defaults restored."
        loadSettingsPreferences()
    }
}
