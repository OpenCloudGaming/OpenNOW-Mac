//  The HUD's pad-drivable dropdowns, and the microphone device the AUDIO panel selects.
//
//  swiftlint:disable:next no_appkit_in_view_model
import AppKit
import Foundation

@MainActor
extension NativeNVSTHostViewModel {
    static let microphoneDeviceDropdownID = "microphone-device"
    static let microphoneModeDropdownID = "microphone-mode"
    static let remoteCoOpQualityDropdownPrefix = "coop-quality-"

    // MARK: - Pad-driven dropdowns

    /// The rows of the dropdown `dropdownID` in draw order. Empty for an id this model does not own,
    /// which is how an unknown dropdown refuses to open instead of opening on nothing.
    func padDropdownItems(_ dropdownID: String) -> [OPNDropdownPadItem] {
        if dropdownID == Self.microphoneDeviceDropdownID { return microphoneDevicePadItems() }
        if dropdownID == Self.microphoneModeDropdownID { return microphoneModePadItems() }
        guard dropdownID.hasPrefix(Self.remoteCoOpQualityDropdownPrefix),
              let participantID = UUID(uuidString: String(dropdownID.dropFirst(Self.remoteCoOpQualityDropdownPrefix.count))) else { return [] }
        return remoteCoOpQualityPadItems(participantID: participantID)
    }

    /// What the menu `dropdownID` renders: whether it is open, which row the pad stands on, and the
    /// two things a trigger can do to it. Only one dropdown is open at a time.
    func padDropdown(dropdownID: String) -> OPNDropdownPadDriver<String> {
        OPNDropdownPadDriver(
            isPresented: openHUDDropdownID == dropdownID,
            highlightedValue: openHUDDropdownID == dropdownID ? hudDropdownHighlightedItemID : nil,
            toggle: { [weak self] in self?.togglePadDropdown(dropdownID) },
            close: { [weak self] in self?.closeHUDDropdown(ifOpen: dropdownID) }
        )
    }

    func togglePadDropdown(_ dropdownID: String) {
        if openHUDDropdownID == dropdownID {
            closeHUDDropdown(ifOpen: dropdownID)
            return
        }
        let items = padDropdownItems(dropdownID)
        guard !items.isEmpty else { return }
        openHUDDropdownID = dropdownID
        // Opens on the row in use, so the pad starts where the user already is.
        hudDropdownHighlightedItemID = items.first(where: { $0.isSelected })?.id ?? items.first?.id
    }

    /// Up/down inside an open panel, wrapping. Never touches `hudFocusID`: the pad is in the list and
    /// the trigger keeps its focus ring, so cancelling lands back on it.
    func moveHUDDropdownHighlight(step: Int) {
        guard let dropdownID = openHUDDropdownID else { return }
        let items = padDropdownItems(dropdownID)
        guard !items.isEmpty else { return }
        let currentIndex = items.firstIndex { $0.id == hudDropdownHighlightedItemID } ?? 0
        hudDropdownHighlightedItemID = items[(currentIndex + step + items.count) % items.count].id
    }

    /// Confirm inside an open panel. Closes before running the row, so the trigger owns focus while the
    /// action's own state changes land.
    func commitHUDDropdownHighlight() {
        guard let dropdownID = openHUDDropdownID,
              let item = padDropdownItems(dropdownID).first(where: { $0.id == hudDropdownHighlightedItemID }) else {
            closeHUDDropdown()
            return
        }
        closeHUDDropdown(ifOpen: dropdownID)
        item.action()
    }

    func closeHUDDropdown() {
        openHUDDropdownID = nil
        hudDropdownHighlightedItemID = nil
    }

    /// Closes only when the open panel is `dropdownID`, so a stale view cannot close another menu.
    func closeHUDDropdown(ifOpen dropdownID: String) {
        guard openHUDDropdownID == dropdownID else { return }
        closeHUDDropdown()
    }

    var isHUDDropdownOpen: Bool { openHUDDropdownID != nil }

    // MARK: - The microphone device dropdown

    /// One row per input device, the synthetic "Default Device" (empty UID) first, as Settings lists
    /// them. The default's label carries the fallback so the HUD never claims a device not in use.
    func microphoneDevicePadItems() -> [OPNDropdownPadItem] {
        microphoneDeviceOptions.map { option in
            let isFallbackRow = isMicrophoneDeviceFallbackActive && option.uniqueId.isEmpty
            return OPNDropdownPadItem(
                id: option.uniqueId,
                title: isFallbackRow ? "\(option.label) (fallback)" : option.label,
                isSelected: option.uniqueId == selectedMicrophoneDeviceUID,
                action: { [weak self] in self?.requestNativeMicrophoneDevice(option.uniqueId) }
            )
        }
    }

    /// The UID the panel marks, or empty for "Default Device". Empty while a change is in flight too,
    /// so the old row is not marked once the user has chosen a new one.
    var selectedMicrophoneDeviceUID: String {
        microphonePendingDeviceUID ?? microphoneDeviceUID
    }

    /// The caption the HUD shows for the focused device row.
    var microphoneDeviceCaption: String {
        "Microphone Device \u{00b7} \(microphoneDeviceSelectionLabel)"
    }

    /// The trigger's label: the device in use, named as the picker names it. A missing saved device
    /// resolves to no row, so this reads "Default Device" and the suffix says it is a fallback.
    var microphoneDeviceSelectionLabel: String {
        let label = microphoneDeviceOptions.first { $0.uniqueId == selectedMicrophoneDeviceUID }?.label ?? "Default Device"
        return isMicrophoneDeviceFallbackActive ? "\(label) (fallback)" : label
    }

    /// The live meter as a percentage, for the HUD's readout beside the bar.
    var microphoneLevelPercent: Int {
        Int((min(max(microphoneLevel, 0), 1) * 100).rounded())
    }

    // MARK: - The microphone mode dropdown

    /// One row per mode Settings offers, in Settings' order and with Settings' own labels. The mode is
    /// the gating policy — off, held to talk, or always capturing — and it persists for later sessions.
    func microphoneModePadItems() -> [OPNDropdownPadItem] {
        OPNStreamPreferences.microphoneModeOptions.map { option in
            OPNDropdownPadItem(
                id: option.value,
                title: option.label,
                isSelected: option.value == microphoneMode,
                action: { [weak self] in self?.requestNativeMicrophoneMode(option.value) }
            )
        }
    }

    /// The caption the HUD shows for the focused mode row.
    var microphoneModeCaption: String {
        "Microphone Mode \u{00b7} \(microphoneModeSelectionLabel)"
    }

    var microphoneModeSelectionLabel: String {
        OPNStreamPreferences.microphoneModeOptions.first { $0.value == microphoneMode }?.label ?? "Disabled"
    }

    /// Why the microphone cannot be used in this session, or nil when it can. A section that was never
    /// requested is the one case the seat cannot be blamed for, so it is named first.
    var microphoneUnavailableReason: String? {
        guard isMicrophoneSectionNegotiated else {
            return "The microphone was off when this session started, so it can only be enabled for the next one."
        }
        return microphoneTransportAvailability.failureMessage
    }

    /// Whether the mode can be changed: the seat has to carry a microphone, and no change may be in
    /// flight. Deliberately not gated on `microphoneAvailable` — switching the mode back on is the
    /// whole point of the row when the mode is off.
    var isMicrophoneModeRowDisabled: Bool {
        !sidebarCapabilities.supports(.microphone)
            || microphoneUpdateTask != nil
            || microphoneUnavailableReason != nil
    }

    // MARK: - Microphone commands

    /// Applies a mode choice to the running session and saves it for the next one. Choosing "Disabled"
    /// is always allowed, since it only stops capture.
    func requestNativeMicrophoneMode(_ mode: String) {
        guard isConnected, !isEnding, !didEnd else { return }
        if mode != "disabled", let reason = microphoneUnavailableReason {
            showNativeTransientStreamMessage(reason)
            return
        }
        applyMicrophoneMode(mode)
    }

    /// Writes the mode everywhere it is read and applies it to the live session: the preference
    /// Settings shares, the capture gate, and the push-to-talk chord.
    func applyMicrophoneMode(_ mode: String) {
        // Silences the session first: the mute path refuses to run once the mode has cleared the
        // microphone's availability, and a mode change must never leave capture open.
        if mode != "voice-activity" { requestNativeMicrophoneEnabled(false, source: "mode") }
        microphoneMode = mode
        OPNStreamPreferences.saveMicrophoneMode(mode)
        microphoneAvailable = isMicrophoneSectionNegotiated && mode != "disabled"
        if let nativeView { configurePushToTalkMonitor(for: nativeView, mode: mode) }
        if mode == "voice-activity" { requestNativeMicrophoneEnabled(true, source: "mode") }
        publishMicrophoneConfiguration()
        OPNStreamTelemetry.capture("nvst.ui.microphone.mode", level: .info, message: "Native NVST microphone mode changed.", attributes: ["applicationID": configuration.applicationID, "mode": mode])
    }

    /// Applies a device choice: refused with the reason when the seat cannot carry a microphone, and
    /// otherwise queued behind the mute toggle's pending-state machinery.
    func requestNativeMicrophoneDevice(_ uid: String) {
        guard let path, isConnected, !isEnding, !didEnd else { return }
        if let reason = microphoneUnavailableReason {
            showNativeTransientStreamMessage(reason)
            return
        }
        microphonePendingDeviceUID = uid
        pendingMicrophoneDeviceUIDs.append(uid)
        guard microphoneUpdateTask == nil else { return }
        microphoneUpdateTask = Task { @MainActor in
            await applyPendingMicrophoneDeviceChanges(path: path)
        }
    }

    /// Drains the queued changes one at a time, so rapid switching cannot interleave on the transport.
    private func applyPendingMicrophoneDeviceChanges(path: NativeNVSTStreamingPath) async {
        defer { microphoneUpdateTask = nil }
        while !Task.isCancelled, !didEnd, !pendingMicrophoneDeviceUIDs.isEmpty {
            let targetUID = pendingMicrophoneDeviceUIDs.removeFirst()
            do {
                try await path.setMicrophoneDevice(targetUID)
                guard !Task.isCancelled, !didEnd else { return }
                applyMicrophoneDevice(targetUID)
                showNativeTransientStreamMessage(microphoneDeviceStatusMessage(for: targetUID))
                OPNStreamTelemetry.capture("nvst.ui.microphone.device", level: .info, message: "Native NVST microphone device changed.", attributes: ["applicationID": configuration.applicationID, "deviceId": targetUID.isEmpty ? "default" : targetUID])
            } catch {
                guard !Task.isCancelled, !didEnd else { return }
                // Rolls back to what is actually in use, so no row marks a device the transport refused.
                pendingMicrophoneDeviceUIDs.removeAll()
                microphonePendingDeviceUID = nil
                let message = Self.message(for: error)
                showNativeTransientStreamMessage(message)
                OPNStreamTelemetry.capture("nvst.ui.microphone.device.failed", level: .error, message: message, attributes: ["applicationID": configuration.applicationID])
            }
        }
        microphonePendingDeviceUID = nil
    }

    /// Writes the choice to the preference the Settings picker reads — the same key, so this is a
    /// reload for Settings rather than a migration.
    private func applyMicrophoneDevice(_ uid: String) {
        microphoneDeviceUID = uid
        OPNStreamPreferences.saveMicrophoneDeviceId(uid)
        isMicrophoneDeviceFallbackActive = false
        publishMicrophoneConfiguration()
    }

    /// Hands the transport the configuration a later bring-up resolves from, so a reconnect cannot undo
    /// an Off or a device change. Only a new bundle reads it; the live session keeps running.
    private func publishMicrophoneConfiguration() {
        guard let path else { return }
        let configuration = microphoneConfigurationForCurrentMode
        Task { @MainActor in
            do {
                try await path.setMicrophoneConfiguration(configuration)
            } catch {
                OPNStreamTelemetry.capture("nvst.ui.microphone.configuration.failed", level: .warning, message: Self.message(for: error), attributes: ["applicationID": self.configuration.applicationID])
            }
        }
    }

    private func microphoneDeviceStatusMessage(for uid: String) -> String {
        guard let option = microphoneDeviceOptions.first(where: { $0.uniqueId == uid }) else { return "Microphone Device Changed" }
        return "Microphone: \(option.label)"
    }

    /// Re-reads the device list, so a microphone plugged in mid-stream becomes a row.
    func reloadMicrophoneDeviceOptions() {
        microphoneDeviceOptions = OPNStreamPreferences.loadMicrophoneDeviceOptions()
    }

    /// Re-reads the list and re-resolves the fallback, which is what the HUD does on every open.
    func refreshMicrophoneDeviceOptions() {
        reloadMicrophoneDeviceOptions()
        resolveMicrophoneDeviceFallback()
    }

    /// Whether the saved device is still one of the rows present. The saved UID is never rewritten
    /// here: a fallback is a resolution result, and the device is expected back.
    func resolveMicrophoneDeviceFallback() {
        let savedUID = microphoneDeviceUID.isEmpty ? OPNStreamPreferences.loadProfile().microphoneDeviceId : microphoneDeviceUID
        isMicrophoneDeviceFallbackActive = !savedUID.isEmpty
            && !microphoneDeviceOptions.contains { $0.uniqueId == savedUID }
    }

    /// The capture device is gone and the session fell back to the system default. The transport names
    /// the fallback; this reports it and refreshes the list without touching the saved UID.
    func handleMicrophoneDeviceFallback(_ message: String) {
        reloadMicrophoneDeviceOptions()
        isMicrophoneDeviceFallbackActive = true
        showNativeTransientStreamMessage(message)
    }

    /// One row per quality choice for a guest. "Session default" stays distinct from the preset that
    /// matches it today, so a guest left on it follows later changes to the session setting.
    private func remoteCoOpQualityPadItems(participantID: UUID) -> [OPNDropdownPadItem] {
        let selectedPreset = remoteCoOpSnapshot.participants.first { $0.id == participantID }?.qualityPreset
        var items = [OPNDropdownPadItem(id: "session-default", title: "Session Default", isSelected: selectedPreset == nil, action: { [weak self] in
            self?.setRemoteCoOpParticipantQualityPreset(nil, for: participantID)
        })]
        items += OPNRemoteCoOpQualityPreset.allCases.map { preset in
            OPNDropdownPadItem(id: preset.label, title: preset.label, isSelected: selectedPreset == preset, action: { [weak self] in
                self?.setRemoteCoOpParticipantQualityPreset(preset, for: participantID)
            })
        }
        return items
    }

    /// Asks the transport whether this seat carries a microphone at all, which is only answerable once
    /// the bundle is up — hence asking when the HUD opens rather than at launch.
    func refreshMicrophoneTransportAvailability() {
        guard let path else {
            microphoneTransportAvailability = .pending
            return
        }
        Task { @MainActor in
            microphoneTransportAvailability = await path.microphoneAvailability()
        }
    }
}
