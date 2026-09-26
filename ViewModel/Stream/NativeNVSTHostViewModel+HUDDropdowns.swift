//  The HUD's pad-drivable dropdowns, and the microphone device the AUDIO panel selects.
//
//  A dropdown is a focus entry like any other control, except its confirm opens a list rather than
//  firing once: the pad then walks that list, confirms a row, or cancels back to the trigger. That
//  open list is HUD state this model owns — the gamepad handler is what moves through it — so the row
//  definitions live here as well as the open/highlight state. The view renders what this says is open
//  and highlighted, and both the pointer and the pad therefore select from one list.
//
//  swiftlint:disable:next no_appkit_in_view_model
import AppKit
import Foundation

@MainActor
extension NativeNVSTHostViewModel {
    static let microphoneDeviceDropdownID = "microphone-device"
    static let remoteCoOpQualityDropdownPrefix = "coop-quality-"

    // MARK: - Pad-driven dropdowns

    /// The rows of the pad-drivable dropdown `id`, in draw order. Empty for an id this model does not
    /// own, which is how an unknown dropdown refuses to open instead of opening on nothing.
    func padDropdownItems(_ id: String) -> [OPNDropdownPadItem] {
        if id == Self.microphoneDeviceDropdownID { return microphoneDevicePadItems() }
        if id.hasPrefix(Self.remoteCoOpQualityDropdownPrefix),
           let participantID = UUID(uuidString: String(id.dropFirst(Self.remoteCoOpQualityDropdownPrefix.count))) {
            return remoteCoOpQualityPadItems(participantID: participantID)
        }
        return []
    }

    /// What the menu with this id renders: whether it is open, which row the pad stands on, and the
    /// two things a trigger can do to it. Only one dropdown is ever open, because the pad stands on
    /// one focus entry.
    func padDropdown(id: String) -> OPNDropdownPadDriver {
        OPNDropdownPadDriver(
            isPresented: openHUDDropdownID == id,
            highlightedItemID: openHUDDropdownID == id ? hudDropdownHighlightedItemID : nil,
            toggle: { [weak self] in self?.togglePadDropdown(id) },
            close: { [weak self] in self?.closeHUDDropdown(ifOpen: id) }
        )
    }

    func togglePadDropdown(_ id: String) {
        if openHUDDropdownID == id {
            closeHUDDropdown(ifOpen: id)
            return
        }
        let items = padDropdownItems(id)
        guard !items.isEmpty else { return }
        openHUDDropdownID = id
        // Open on the row in use, which is the one the checkmark marks, so the pad starts where the
        // user already is instead of at the top of a long list.
        hudDropdownHighlightedItemID = items.first(where: { $0.isSelected })?.id ?? items.first?.id
    }

    /// Up/down inside an open panel, wrapping. Never touches `hudFocusID`: the pad is in the list, and
    /// the trigger keeps its focus ring so cancelling lands back on it.
    func moveHUDDropdownHighlight(step: Int) {
        guard let id = openHUDDropdownID else { return }
        let items = padDropdownItems(id)
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == hudDropdownHighlightedItemID } ?? 0
        hudDropdownHighlightedItemID = items[(current + step + items.count) % items.count].id
    }

    /// Confirm inside an open panel. Closes before running the row so focus is back on the trigger
    /// while the action's own state changes land, several of which the HUD re-reads as it re-renders.
    func commitHUDDropdownHighlight() {
        guard let id = openHUDDropdownID,
              let item = padDropdownItems(id).first(where: { $0.id == hudDropdownHighlightedItemID }) else {
            closeHUDDropdown()
            return
        }
        closeHUDDropdown(ifOpen: id)
        item.action()
    }

    func closeHUDDropdown() {
        openHUDDropdownID = nil
        hudDropdownHighlightedItemID = nil
    }

    /// Closes only when the open panel is `id`, so a stale view cannot close another menu.
    func closeHUDDropdown(ifOpen id: String) {
        guard openHUDDropdownID == id else { return }
        closeHUDDropdown()
    }

    var isHUDDropdownOpen: Bool { openHUDDropdownID != nil }

    // MARK: - The microphone device dropdown

    /// One row per input device, first row synthetic and always "Default Device" (empty UID), exactly
    /// as the Settings picker lists them. The label carries the fallback when the saved device is
    /// gone, so the HUD never claims a device that is not in use.
    func microphoneDevicePadItems() -> [OPNDropdownPadItem] {
        microphoneDeviceOptions.map { option in
            let isFallback = microphoneDeviceFallbackActive && option.uniqueId.isEmpty
            return OPNDropdownPadItem(
                id: option.uniqueId,
                title: isFallback ? "\(option.label) (fallback)" : option.label,
                isSelected: option.uniqueId == selectedMicrophoneDeviceID,
                action: { [weak self] in self?.requestNativeMicrophoneDevice(option.uniqueId) }
            )
        }
    }

    /// The saved UID, or empty for "Default Device". Empty while a change is in flight too, because
    /// the panel should not mark the old row once the user has chosen a new one.
    var selectedMicrophoneDeviceID: String {
        microphonePendingDeviceID ?? microphoneDeviceID
    }

    /// The caption the HUD shows for the focused device row: the row's title and whether capture is
    /// on the chosen device, the default, or a fallback.
    var microphoneDeviceCaption: String {
        "Microphone Device \u{00b7} \(microphoneDeviceSelectionLabel)"
    }

    /// The trigger's label: the device in use, named as the picker names it, with the fallback called
    /// out so the UI never claims a device that is not capturing.
    var microphoneDeviceSelectionLabel: String {
        // When the saved device is gone the lookup finds no row, so this reads "Default Device" — and
        // the fallback suffix is what keeps that from claiming the user's choice is in use.
        let label = microphoneDeviceOptions.first { $0.uniqueId == selectedMicrophoneDeviceID }?.label ?? "Default Device"
        return microphoneDeviceFallbackActive ? "\(label) (fallback)" : label
    }

    /// The live meter as a percentage, for the HUD's readout beside the bar.
    var microphoneLevelPercent: Int {
        Int((min(max(microphoneLevel, 0), 1) * 100).rounded())
    }

    /// Whether the device row can be used at all: a seat that negotiated no microphone channel, a
    /// legacy RTSP-mic seat, or Settings' microphone mode being off. Nil when it can.
    var microphoneDeviceUnavailableReason: String? {
        guard microphoneAvailable else {
            return microphoneMode == "disabled" ? "Microphone is disabled in Settings." : nil
        }
        return microphoneTransportAvailability.failureMessage
    }

    /// The pad-drivable dropdown is open, or a device change is already in flight — the microphone
    /// tile's own busy rule, since both go through the same transport call.
    var isMicrophoneDeviceChangeBusy: Bool { microphoneUpdateTask != nil }

    // MARK: - Microphone commands

    /// Applies a device choice to the running session: captures from it, then saves it so Settings and
    /// the next session agree. Serialised behind the same pending-state machinery as the mute toggle,
    /// so a device change and a mute cannot interleave on the same transport.
    func requestNativeMicrophoneDevice(_ uid: String) {
        guard let path, isConnected, !isEnding, !didEnd else { return }
        guard availabilityAllowsMicrophoneChange(uid) else { return }
        microphonePendingDeviceID = uid
        pendingMicrophoneDeviceChanges.append(uid)
        guard microphoneUpdateTask == nil else { return }
        microphoneUpdateTask = Task { @MainActor in
            defer { microphoneUpdateTask = nil }
            while !Task.isCancelled, !didEnd, !pendingMicrophoneDeviceChanges.isEmpty {
                let target = pendingMicrophoneDeviceChanges.removeFirst()
                do {
                    try await path.setMicrophoneDevice(target)
                    guard !Task.isCancelled, !didEnd else { return }
                    applyMicrophoneDevice(target)
                    showNativeTransientStreamMessage(microphoneDeviceStatusMessage(for: target))
                    OPNStreamTelemetry.capture("nvst.ui.microphone.device", level: .info, message: "Native NVST microphone device changed.", attributes: ["applicationID": configuration.applicationID, "deviceId": target.isEmpty ? "default" : target])
                } catch {
                    guard !Task.isCancelled, !didEnd else { return }
                    // Roll back to what is actually in use, so the row does not mark a device the
                    // transport refused.
                    pendingMicrophoneDeviceChanges.removeAll()
                    microphonePendingDeviceID = nil
                    let message = Self.message(for: error)
                    showNativeTransientStreamMessage(message)
                    OPNStreamTelemetry.capture("nvst.ui.microphone.device.failed", level: .error, message: message, attributes: ["applicationID": configuration.applicationID])
                }
            }
            microphonePendingDeviceID = nil
        }
    }

    private func availabilityAllowsMicrophoneChange(_ uid: String) -> Bool {
        guard let reason = microphoneDeviceUnavailableReason else { return true }
        showNativeTransientStreamMessage(reason)
        return false
    }

    /// Writes the choice to the preference the Settings picker also reads — the same key, so this is
    /// a reload for Settings rather than a migration — and mirrors it on the HUD's selected row.
    private func applyMicrophoneDevice(_ uid: String) {
        microphoneDeviceID = uid
        OPNStreamPreferences.saveMicrophoneDeviceId(uid)
        microphoneDeviceFallbackActive = false
    }

    private func microphoneDeviceStatusMessage(for uid: String) -> String {
        guard let option = microphoneDeviceOptions.first(where: { $0.uniqueId == uid }) else { return "Microphone Device Changed" }
        return "Microphone: \(option.label)"
    }

    /// Re-reads the device list so a microphone plugged in mid-stream is selectable without closing
    /// and reopening the HUD.
    func reloadMicrophoneDeviceOptions() {
        microphoneDeviceOptions = OPNStreamPreferences.loadMicrophoneDeviceOptions()
    }

    /// Re-reads the list and re-resolves the fallback, which is what the HUD does on every open.
    func refreshMicrophoneDeviceOptions() {
        reloadMicrophoneDeviceOptions()
        resolveMicrophoneDeviceFallback()
    }

    /// Whether the saved device is still one of the rows that are present. The saved UID is never
    /// rewritten here: a fallback is a resolution result, and the device is expected back.
    func resolveMicrophoneDeviceFallback() {
        let saved = microphoneDeviceID.isEmpty ? OPNStreamPreferences.loadProfile().microphoneDeviceId : microphoneDeviceID
        microphoneDeviceFallbackActive = !saved.isEmpty
            && !microphoneDeviceOptions.contains(where: { $0.uniqueId == saved })
    }

    /// The capture device went away and the session fell back to the system default. Named by the
    /// transport, which is the only layer that knows capture is still running somewhere else; this
    /// only says so and refreshes the list, and deliberately does not touch the saved UID.
    func handleMicrophoneDeviceFallback(_ message: String) {
        reloadMicrophoneDeviceOptions()
        microphoneDeviceFallbackActive = true
        showNativeTransientStreamMessage(message)
    }

    /// One row per quality choice for a guest, the same rows the pointer path built inline before this
    /// moved here. "Session default" stays a distinct choice from the preset that matches it today: a
    /// guest left on it follows later changes to the session setting.
    private func remoteCoOpQualityPadItems(participantID: UUID) -> [OPNDropdownPadItem] {
        let selected = remoteCoOpSnapshot.participants.first { $0.id == participantID }?.qualityPreset
        var items = [OPNDropdownPadItem(id: "session-default", title: "Session Default", isSelected: selected == nil, action: { [weak self] in
            self?.setRemoteCoOpParticipantQualityPreset(nil, for: participantID)
        })]
        items += OPNRemoteCoOpQualityPreset.allCases.map { preset in
            OPNDropdownPadItem(id: preset.label, title: preset.label, isSelected: selected == preset, action: { [weak self] in
                self?.setRemoteCoOpParticipantQualityPreset(preset, for: participantID)
            })
        }
        return items
    }

    /// Asks the transport whether this seat carries a microphone at all. Only answerable once the
    /// bundle is up, which is why it is asked when the HUD opens rather than at launch.
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
