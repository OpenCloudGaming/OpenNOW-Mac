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

    /// WebRTC is the legacy path: it still streams, but every feature since the native transport
    /// landed (Remote Co-Op hosting, HDR, 4:4:4, 120 fps, rumble, the cursor protocol) is
    /// NVST-only. Home says so once, with the switch attached, rather than leaving a user to
    /// discover it one missing feature at a time.
    var usesLegacyWebRTCTransport: Bool {
        streamProfile.transportModeIndex == 0
    }

    var showsLegacyTransportNotice: Bool {
        usesLegacyWebRTCTransport && !OPNStreamPreferences.legacyTransportNoticeDismissed
    }

    func dismissLegacyTransportNotice() {
        OPNStreamPreferences.saveLegacyTransportNoticeDismissed(true)
        loadSettingsPreferences()
    }

    /// The notice's own button. Switches the transport and clears any earlier dismissal, so a user
    /// who later goes back to WebRTC is told again.
    func switchToNativeTransportFromNotice() {
        OPNStreamPreferences.saveLegacyTransportNoticeDismissed(false)
        setNVSTTransportEnabled(true)
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

    func setPresentationModeIndex(_ index: Int) {
        OPNStreamPreferences.savePresentationModeIndex(index)
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

    func setMouseSensitivityPercent(_ value: Double) {
        OPNStreamPreferences.saveMouseSensitivityPercent(Int(value.rounded()))
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


    /// Both secrets go to the keychain, never to preferences: the API token can create billable
    /// resources on the host's account, so neither may sit beside the display settings or reach
    /// launch metadata.
    func setRemoteCoOpCloudflareAPIToken(_ token: String) {
        var credentials = OPNRemoteCoOpTURNKeyStore.load()
        credentials.account = OPNRemoteCoOpCloudflareAccount(accountID: credentials.account.accountID, apiToken: token)
        OPNRemoteCoOpTURNKeyStore.save(credentials)
        remoteCoOpRelayCredentials = OPNRemoteCoOpTURNKeyStore.load()
        remoteCoOpTURNSetupMessage = ""
    }

    /// Proves the relay end to end rather than just checking the fields are filled in.
    ///
    /// Every way relay credentials go wrong - a wrong password, a URL with no TLS variant, a provider
    /// that has not activated the account - produces the same symptom: a session that works for
    /// everyone except the one guest who needed the relay, on a network the host cannot test from.
    func testRemoteCoOpRelay() {
        let credentials = OPNRemoteCoOpTURNKeyStore.load()
        guard credentials.canRelay else {
            remoteCoOpRelayTestPassed = false
            remoteCoOpRelayTestMessage = "Configure a relay first."
            return
        }
        remoteCoOpRelayTestInFlight = true
        remoteCoOpRelayTestPassed = false
        remoteCoOpRelayTestMessage = "Asking the relay for an allocation..."
        Task { @MainActor in
            defer { remoteCoOpRelayTestInFlight = false }
            let servers = await credentials.iceServers()
            guard !servers.isEmpty else {
                remoteCoOpRelayTestMessage = credentials.provider == .cloudflare
                    ? "Cloudflare would not mint credentials. Run setup again."
                    : "No usable relay URLs. Each needs a turns:, turn: or stun: prefix."
                return
            }
            let result = await OPNRemoteCoOpRelayProbe.run(iceServers: servers)
            remoteCoOpRelayTestPassed = result.succeeded
            remoteCoOpRelayTestMessage = result.summary
        }
    }

    /// Stores the pasted Ably key, or says why it was refused.
    ///
    /// Refused rather than half-accepted: a key without the `APP_ID.KEY_ID:SECRET` shape signs a JWT
    /// Ably rejects for a reason the host cannot act on, so the failure belongs here where it can be
    /// explained rather than at the moment a guest fails to connect.
    func setRemoteCoOpAblyKey(_ pasted: String) {
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            OPNRemoteCoOpAblyKeyStore.save(OPNRemoteCoOpAblyKey(name: "", secret: ""))
            remoteCoOpAblyKey = OPNRemoteCoOpAblyKeyStore.load()
            remoteCoOpAblyKeyMessage = "Hosted signaling turned off. Guests must reach this Mac directly or through a tunnel."
            return
        }
        guard let key = OPNRemoteCoOpAblyKey(pasted: trimmed) else {
            remoteCoOpAblyKeyMessage = "That does not look like an Ably key. They read APP_ID.KEY_ID:SECRET."
            return
        }
        OPNRemoteCoOpAblyKeyStore.save(key)
        remoteCoOpAblyKey = OPNRemoteCoOpAblyKeyStore.load()
        remoteCoOpAblyKeyMessage = "Saved. New invites will also work for guests that cannot reach this Mac."
    }

    func setRemoteCoOpHostedGuestPageURL(_ url: String) {
        OPNRemoteCoOpPreferencesStore.setHostedGuestPageURL(url)
        remoteCoOpPreferences = OPNRemoteCoOpPreferencesStore.load()
    }

    func setRemoteCoOpRelayProviderIndex(_ index: Int) {
        guard OPNRemoteCoOpRelayProvider.allCases.indices.contains(index) else { return }
        var credentials = OPNRemoteCoOpTURNKeyStore.load()
        credentials.provider = OPNRemoteCoOpRelayProvider.allCases[index]
        OPNRemoteCoOpTURNKeyStore.save(credentials)
        remoteCoOpRelayCredentials = OPNRemoteCoOpTURNKeyStore.load()
        remoteCoOpTURNSetupMessage = ""
        remoteCoOpRelayTestMessage = ""
        remoteCoOpRelayTestPassed = false
        refreshRemoteCoOpTURNUsage()
    }

    func setRemoteCoOpStaticRelayURLs(_ text: String) {
        updateStaticRelay { OPNRemoteCoOpStaticRelay(urlText: text, username: $0.username, password: $0.password) }
    }

    func setRemoteCoOpStaticRelayUsername(_ username: String) {
        updateStaticRelay { OPNRemoteCoOpStaticRelay(urls: $0.urls, username: username, password: $0.password) }
    }

    func setRemoteCoOpStaticRelayPassword(_ password: String) {
        updateStaticRelay { OPNRemoteCoOpStaticRelay(urls: $0.urls, username: $0.username, password: password) }
    }

    func setRemoteCoOpSharedSecretRelayURLs(_ text: String) {
        updateSharedSecretRelay { OPNRemoteCoOpSharedSecretRelay(urlText: text, secret: $0.secret, username: $0.username) }
    }

    func setRemoteCoOpSharedSecretRelaySecret(_ secret: String) {
        updateSharedSecretRelay { OPNRemoteCoOpSharedSecretRelay(urls: $0.urls, secret: secret, username: $0.username) }
    }

    private func updateStaticRelay(_ transform: (OPNRemoteCoOpStaticRelay) -> OPNRemoteCoOpStaticRelay) {
        var credentials = OPNRemoteCoOpTURNKeyStore.load()
        credentials.staticRelay = transform(credentials.staticRelay)
        OPNRemoteCoOpTURNKeyStore.save(credentials)
        remoteCoOpRelayCredentials = OPNRemoteCoOpTURNKeyStore.load()
    }

    private func updateSharedSecretRelay(_ transform: (OPNRemoteCoOpSharedSecretRelay) -> OPNRemoteCoOpSharedSecretRelay) {
        var credentials = OPNRemoteCoOpTURNKeyStore.load()
        credentials.sharedSecretRelay = transform(credentials.sharedSecretRelay)
        OPNRemoteCoOpTURNKeyStore.save(credentials)
        remoteCoOpRelayCredentials = OPNRemoteCoOpTURNKeyStore.load()
    }

    /// Manual entry, for when `POST /calls/turn_keys` refuses a token that carries Cloudflare Calls
    /// (Edit) - a documented-enough failure that automatic provisioning cannot be the only path. A key
    /// made in the dashboard works identically; only the making of it differs.
    func setRemoteCoOpTURNKeyID(_ keyID: String) {
        var credentials = OPNRemoteCoOpTURNKeyStore.load()
        credentials.turnKey = OPNRemoteCoOpTURNKey(keyID: keyID, keyToken: credentials.turnKey.keyToken)
        OPNRemoteCoOpTURNKeyStore.save(credentials)
        remoteCoOpRelayCredentials = OPNRemoteCoOpTURNKeyStore.load()
        remoteCoOpTURNSetupMessage = ""
    }

    func setRemoteCoOpTURNKeyToken(_ token: String) {
        var credentials = OPNRemoteCoOpTURNKeyStore.load()
        credentials.turnKey = OPNRemoteCoOpTURNKey(keyID: credentials.turnKey.keyID, keyToken: token)
        OPNRemoteCoOpTURNKeyStore.save(credentials)
        remoteCoOpRelayCredentials = OPNRemoteCoOpTURNKeyStore.load()
        remoteCoOpTURNSetupMessage = remoteCoOpRelayCredentials.canRelay
            ? "Relay ready."
            : "Add the TURN key ID as well."
    }

    func setRemoteCoOpTURNAccountID(_ accountID: String) {
        var credentials = OPNRemoteCoOpTURNKeyStore.load()
        credentials.account = OPNRemoteCoOpCloudflareAccount(accountID: accountID, apiToken: credentials.account.apiToken)
        OPNRemoteCoOpTURNKeyStore.save(credentials)
        remoteCoOpRelayCredentials = OPNRemoteCoOpTURNKeyStore.load()
    }

    /// Derives the account ID and the TURN key from the pasted API token, so the host visits the
    /// Cloudflare dashboard once instead of three times.
    func setUpRemoteCoOpRelay() {
        let credentials = OPNRemoteCoOpTURNKeyStore.load()
        guard credentials.account.hasToken else {
            remoteCoOpTURNSetupMessage = "Paste a Cloudflare API token first."
            return
        }
        remoteCoOpTURNSetupInFlight = true
        remoteCoOpTURNSetupMessage = "Contacting Cloudflare..."
        Task { @MainActor in
            defer { remoteCoOpTURNSetupInFlight = false }
            do {
                let provisioned = try await OPNRemoteCoOpTURNProvisioner.provision(
                    apiToken: credentials.account.apiToken,
                    accountID: credentials.account.accountID,
                    existingKey: credentials.turnKey
                )
                OPNRemoteCoOpTURNKeyStore.save(provisioned)
                remoteCoOpRelayCredentials = OPNRemoteCoOpTURNKeyStore.load()
                remoteCoOpTURNSetupMessage = credentials.turnKey.isUsable
                    ? "Relay ready. Kept the existing TURN key."
                    : "Relay ready. Created a TURN key on your account."
                refreshRemoteCoOpTURNUsage()
            } catch {
                remoteCoOpTURNSetupMessage = error.localizedDescription
            }
        }
    }

    func clearRemoteCoOpRelay() {
        OPNRemoteCoOpTURNKeyStore.save(OPNRemoteCoOpRelayCredentials(
            provider: OPNRemoteCoOpTURNKeyStore.load().provider,
            turnKey: OPNRemoteCoOpTURNKey(keyID: "", keyToken: ""),
            account: OPNRemoteCoOpCloudflareAccount(accountID: "", apiToken: "")
        ))
        remoteCoOpRelayCredentials = OPNRemoteCoOpTURNKeyStore.load()
        remoteCoOpTURNUsage = nil
        remoteCoOpTURNUsageMessage = ""
        remoteCoOpTURNSetupMessage = "Relay credentials removed from this Mac. The TURN key still exists on your Cloudflare account."
    }

    /// Reads month-to-date relay usage. On demand rather than polled: it is a billing figure, not a
    /// live meter, and the query needs the Account Analytics permission on top of Calls - so a failure
    /// here has to name it instead of showing zero.
    func refreshRemoteCoOpTURNUsage() {
        let credentials = OPNRemoteCoOpTURNKeyStore.load()
        guard credentials.canReportUsage else {
            remoteCoOpTURNUsage = nil
            remoteCoOpTURNUsageMessage = credentials.canRelay ? "Add your account ID to see usage." : ""
            return
        }
        remoteCoOpTURNUsageMessage = "Checking..."
        Task { @MainActor in
            do {
                let usage = try await OPNRemoteCoOpTURNUsageReporter.monthToDateEgress(
                    for: credentials.account,
                    keyID: credentials.turnKey.keyID
                )
                remoteCoOpTURNUsage = usage
                remoteCoOpTURNUsageMessage = ""
            } catch {
                remoteCoOpTURNUsage = nil
                remoteCoOpTURNUsageMessage = "Usage unavailable. \(error.localizedDescription) The token also needs the Account Analytics permission."
            }
        }
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
        let restartRunningTest = microphoneTestActive
        loadSettingsPreferences()
        // A running test is bound to the old device; retarget it instead of leaving it measuring
        // a microphone the host just stopped asking about.
        if restartRunningTest { startMicrophoneTest() }
    }

    // MARK: - Microphone test

    func toggleMicrophoneTest() {
        if microphoneTestActive { stopMicrophoneTest() } else { startMicrophoneTest() }
    }

    /// Opens the selected input device without a streaming session and reports its live level.
    /// macOS shows its microphone permission prompt here the first time, which is exactly when a
    /// host expects it - not mid-game. The test ends itself after half a minute so a probe that
    /// is forgotten on screen does not hold the microphone open.
    func startMicrophoneTest() {
        stopMicrophoneTest()
        let probe = OPNMicrophoneLevelProbe()
        probe.onLevel = { [weak self] level in
            Task { @MainActor [weak self] in
                guard let self, self.microphoneTestActive else { return }
                self.microphoneTestLevel = level
            }
        }
        do {
            let deviceId = streamProfile.microphoneDeviceId
            try probe.start(deviceUniqueId: deviceId.isEmpty ? nil : deviceId)
        } catch {
            microphoneLevelProbe = nil
            microphoneTestActive = false
            microphoneTestLevel = 0
            microphoneTestMessage = microphoneTestFailureMessage(for: error)
            return
        }
        microphoneLevelProbe = probe
        microphoneTestActive = true
        microphoneTestLevel = 0
        microphoneTestMessage = "Speak now - the meter shows what OpenNOW hears."
        microphoneTestAutoStop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.stopMicrophoneTest()
        }
    }

    func stopMicrophoneTest() {
        microphoneTestAutoStop?.cancel()
        microphoneTestAutoStop = nil
        microphoneLevelProbe?.stop()
        microphoneLevelProbe = nil
        microphoneTestActive = false
        microphoneTestLevel = 0
        microphoneTestMessage = nil
    }

    private func microphoneTestFailureMessage(for error: any Error) -> String {
        switch error {
        case OPNMicrophoneLevelProbe.ProbeFailure.noInputDevice:
            return "No input device was found. Plug in a microphone or choose a different device."
        case OPNMicrophoneLevelProbe.ProbeFailure.unitCreationFailed:
            return "macOS refused to create the audio input unit."
        case OPNMicrophoneLevelProbe.ProbeFailure.unitConfigurationFailed(let status):
            return "The microphone could not be configured (error \(status))."
        case OPNMicrophoneLevelProbe.ProbeFailure.unitStartFailed(let status):
            return "The microphone refused to start (error \(status)). If macOS privacy blocks it, allow OpenNOW in System Settings \u{2192} Privacy & Security \u{2192} Microphone."
        default:
            return "The microphone test failed: \(error.localizedDescription)"
        }
    }

    func restoreStreamingProfileDefaults() {
        OPNStreamPreferences.restoreStreamingProfileDefaults()
        actionMessage = "Streaming profile defaults restored."
        loadSettingsPreferences()
    }
}
