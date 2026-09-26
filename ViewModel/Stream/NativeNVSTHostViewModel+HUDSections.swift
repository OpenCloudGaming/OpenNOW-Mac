//  The unified HUD's collapsible sections: the pad-focus list the dock draws, section ordering,
//  and the fold state persisted across sessions. Split from `+Controls` to stay under its budget.
//
//  AppKit is imported for the same reason as `+Controls`: `full-screen` reads `NativeStreamView`'s
//  `window`, which is an AppKit member on the stream surface these entries act on.
//
//  swiftlint:disable:next no_appkit_in_view_model
import AppKit
import Foundation

@MainActor
extension NativeNVSTHostViewModel {

    /// The HUD's focusable rows in draw order, following the reader's order and skipping hidden
    /// sections. Each leads with its fold header; the power button is a dock-wide action.
    var hudFocusEntries: [StreamHUDFocusEntry] {
        let content: [OPNStreamHUDSection: [StreamHUDFocusEntry]] = [
            .session: [],
            .audio: audioFocusEntries,
            .capture: captureFocusEntries,
            .display: displayFocusEntries,
            .input: inputFocusEntries,
            .controllers: controllersFocusEntries,
            .network: [],
            .stats: statsFocusEntries,
            .coop: remoteCoOpFocusEntries,
            .upscaling: upscalingFocusEntries,
            .stream: streamFocusEntries,
        ]
        let sections = visibleHUDSectionOrder.map { section in
            StreamHUDFocusEntry.Section(
                section: section,
                action: { [weak self] in self?.toggleHUDSection(section) },
                content: content[section] ?? []
            )
        }
        return [quitMenuFocusEntry] + StreamHUDFocusEntry.sectioned(sections, collapsed: collapsedHUDSections)
    }

    /// The header power button: opens the pause/end menu from any point in the HUD.
    private var quitMenuFocusEntry: StreamHUDFocusEntry {
        StreamHUDFocusEntry(id: "quit-menu", isDisabled: false, kind: .globalAction, action: { [weak self] in self?.showStreamControls() })
    }

    /// The replay window's entry exists only in Instant Replay mode; a manual-only session has no
    /// rolling window to save.
    var replayBufferFocusEntries: [StreamHUDFocusEntry] {
        guard isInstantReplayEnabled else { return [] }
        return [StreamHUDFocusEntry(id: "replay", isDisabled: !sidebarCapabilities.supports(.recording) || !isConnected || !isReplayBufferActive || replayBufferState.isSaving, group: "capture", columns: 4, action: saveNativeReplayClip)]
    }

    private var audioFocusEntries: [StreamHUDFocusEntry] {
        [
            StreamHUDFocusEntry(id: "microphone", isDisabled: !sidebarCapabilities.supports(.microphone) || !microphoneAvailable || microphoneUpdateTask != nil, group: "audio", columns: 4, action: toggleNativeMicrophone),
            StreamHUDFocusEntry(id: "localAudioMute", isDisabled: !isConnected, group: "audio", columns: 4, action: toggleNativeLocalAudioMute),
            // Two full-width rows of their own, in the order the panel draws them. Each confirm opens
            // a list rather than firing once, so both route through the pad-dropdown state.
            StreamHUDFocusEntry(id: Self.microphoneModeDropdownID, isDisabled: isMicrophoneModeRowDisabled, action: { [weak self] in
                self?.togglePadDropdown(Self.microphoneModeDropdownID)
            }),
            StreamHUDFocusEntry(id: Self.microphoneDeviceDropdownID, isDisabled: isMicrophoneDeviceRowDisabled, action: { [weak self] in
                self?.togglePadDropdown(Self.microphoneDeviceDropdownID)
            }),
        ]
    }

    /// Disabled for every reason the row cannot be used: no microphone in this session's mode, a seat
    /// that carries none, or a device change already in flight behind the same transport call.
    var isMicrophoneDeviceRowDisabled: Bool {
        !sidebarCapabilities.supports(.microphone)
            || !microphoneAvailable
            || microphoneUpdateTask != nil
            || microphoneUnavailableReason != nil
            || microphoneDeviceOptions.count <= 1
    }

    private var captureFocusEntries: [StreamHUDFocusEntry] {
        [
            StreamHUDFocusEntry(id: "recording", isDisabled: !sidebarCapabilities.supports(.recording) || !isConnected || recordingIsBusy, group: "capture", columns: 4, action: toggleNativeRecording),
        ]
        + replayBufferFocusEntries
        + [
            StreamHUDFocusEntry(id: "screenshot", isDisabled: !sidebarCapabilities.supports(.screenshot) || !isConnected || screenshotTask != nil, group: "capture", columns: 4, action: takeNativeScreenshot),
        ]
    }

    private var displayFocusEntries: [StreamHUDFocusEntry] {
        [
            StreamHUDFocusEntry(id: "floating-stats", isDisabled: !sidebarCapabilities.supports(.floatingStats), group: "display", columns: 4, action: toggleNativeStatsHUD),
            StreamHUDFocusEntry(id: "full-screen", isDisabled: isFullScreenTileDisabled, group: "display", columns: 4, action: toggleNativeFullScreen),
            StreamHUDFocusEntry(id: "picture-in-picture", isDisabled: !sidebarCapabilities.supports(.pictureInPicture), group: "display", columns: 4, action: togglePictureInPicture),
        ]
    }

    private var controllersFocusEntries: [StreamHUDFocusEntry] {
        [
            StreamHUDFocusEntry(id: "controller-mapping", isDisabled: false, group: "controllers", columns: 4, action: { [weak self] in self?.showingControllerMapping = true }),
            StreamHUDFocusEntry(id: "controller-order", isDisabled: false, group: "controllers", columns: 4, action: { [weak self] in self?.showingControllerOrder = true }),
            StreamHUDFocusEntry(id: "rumble-intensity", isDisabled: false, action: cycleRumbleIntensity),
        ]
    }

    private var inputFocusEntries: [StreamHUDFocusEntry] {
        [
            StreamHUDFocusEntry(id: "pointer", isDisabled: !isConnected, group: "input", columns: 4, action: toggleNativePointerLock),
            StreamHUDFocusEntry(id: "cursor-policy", isDisabled: !isConnected, group: "input", columns: 4, action: cycleCursorPolicy),
            StreamHUDFocusEntry(id: "anti-afk", isDisabled: !sidebarCapabilities.supports(.antiAFK) || !isConnected, group: "input", columns: 4, action: toggleNativeAntiAFKMouseMovement),
            StreamHUDFocusEntry(id: "mouse-sensitivity", isDisabled: !isConnected, action: cycleNativeMouseSensitivity),
        ]
    }

    private var remoteCoOpFocusEntries: [StreamHUDFocusEntry] {
        [
            StreamHUDFocusEntry(id: "coop-invite", isDisabled: !sidebarCapabilities.supports(.remoteCoOp) || (remoteCoOpSnapshot.invite == nil && !canStartRemoteCoOpInvite), group: "coop", columns: 4, action: { [weak self] in
                guard let self else { return }
                if remoteCoOpSnapshot.invite == nil { startRemoteCoOpInvite() } else { stopRemoteCoOpInvite() }
            }),
            StreamHUDFocusEntry(id: "coop-copy", isDisabled: remoteCoOpSnapshot.invite == nil, group: "coop", columns: 4, action: { [weak self] in self?.copyRemoteCoOpInvite() }),
        ]
        + remoteCoOpParticipantFocusEntries
    }

    private var statsFocusEntries: [StreamHUDFocusEntry] {
        [
            StreamHUDFocusEntry(id: "stats-detail", isDisabled: false, action: cycleNativeStatsDetail),
            StreamHUDFocusEntry(id: "stats-position", isDisabled: false, action: cycleNativeStatsPosition),
        ]
    }

    private var upscalingFocusEntries: [StreamHUDFocusEntry] {
        [
            StreamHUDFocusEntry(id: "upscaling-tier", isDisabled: !sidebarCapabilities.supports(.videoEnhancement), action: cycleNativeUpscalingTier),
            StreamHUDFocusEntry(id: "upscaling-target", isDisabled: !isConnected || upscalingModeIndex == 0 || !sidebarCapabilities.supports(.videoEnhancement), action: cycleNativeUpscalingTarget),
            StreamHUDFocusEntry(id: "clarity", isDisabled: !isConnected || upscalingModeIndex == 0 || !sidebarCapabilities.supports(.videoEnhancement), action: cycleNativeClarity),
            StreamHUDFocusEntry(id: "noise-reduction", isDisabled: !isConnected || upscalingModeIndex == 0 || !sidebarCapabilities.supports(.videoEnhancement), action: cycleNativeNoiseReduction),
        ]
    }

    private var streamFocusEntries: [StreamHUDFocusEntry] {
        [
            StreamHUDFocusEntry(id: "pillarbox-fill", isDisabled: !isConnected, action: cycleNativePillarboxFill),
            StreamHUDFocusEntry(id: "vsync", isDisabled: !isConnected, action: cycleNativeVsyncMode),
        ]
    }

    /// The dock's draw order: present this session, not hidden by the reader, in their order.
    var visibleHUDSectionOrder: [OPNStreamHUDSection] {
        hudSectionOrder.filter { isHUDSectionPresent($0) && !hiddenHUDSections.contains($0) }
    }

    /// Whether this session draws the section at all: the pad-only and Remote Co-Op panels are
    /// absent from a session with no controller or no Co-Op enabled.
    func isHUDSectionPresent(_ section: OPNStreamHUDSection) -> Bool {
        switch section {
        case .controllers: return !controllerBatteries.isEmpty
        case .coop: return remoteCoOpPreferences.isEnabled
        default: return true
        }
    }

    func isHUDSectionHidden(_ section: OPNStreamHUDSection) -> Bool {
        hiddenHUDSections.contains(section)
    }

    func isHUDSectionCollapsed(_ section: OPNStreamHUDSection) -> Bool {
        collapsedHUDSections.contains(section)
    }

    func isHUDSectionHeaderFocused(_ section: OPNStreamHUDSection) -> Bool {
        hudFocusID == section.focusID
    }

    var hasCustomHUDLayout: Bool {
        hudSectionOrder != OPNStreamHUDSection.allCases || !hiddenHUDSections.isEmpty || !isHUDClockVisible
    }

    func toggleHUDSectionHidden(_ section: OPNStreamHUDSection) {
        let isHiding = !hiddenHUDSections.contains(section)
        hiddenHUDSections = hiddenHUDSections.symmetricDifference([section])
        OPNStreamHUDSettings.hiddenSections = hiddenHUDSections
        // Hiding the section the pad stands in must not leave focus on a row that is gone.
        if isHiding, let focused = hudFocusID, !hudFocusEntries.contains(where: { $0.id == focused }) {
            hudFocusID = hudFocusEntries.first(where: { !$0.isDisabled && $0.kind == .control })?.id
        }
        OPNStreamTelemetry.capture("nvst.ui.hud.section.visibility", level: .info, message: "Native NVST HUD section visibility changed.", attributes: ["applicationID": configuration.applicationID, "section": section.rawValue, "hidden": String(isHiding)])
    }

    /// Drops `dragged` just before `target`, which is what dropping on a section's top edge reads as.
    /// A nil target is the trailing drop zone: move to the end.
    func moveHUDSection(_ dragged: OPNStreamHUDSection, to target: OPNStreamHUDSection?) {
        guard let target else {
            moveHUDSectionToEnd(dragged)
            return
        }
        guard dragged != target,
              let from = hudSectionOrder.firstIndex(of: dragged),
              let to = hudSectionOrder.firstIndex(of: target) else { return }
        var order = hudSectionOrder
        order.remove(at: from)
        order.insert(dragged, at: from < to ? to - 1 : to)
        storeHUDSectionOrder(order)
    }

    func moveHUDSectionToEnd(_ dragged: OPNStreamHUDSection) {
        guard let from = hudSectionOrder.firstIndex(of: dragged), from != hudSectionOrder.count - 1 else { return }
        var order = hudSectionOrder
        order.remove(at: from)
        order.append(dragged)
        storeHUDSectionOrder(order)
    }

    func resetHUDLayout() {
        storeHUDSectionOrder(OPNStreamHUDSection.allCases, isReset: true)
        hiddenHUDSections = []
        OPNStreamHUDSettings.hiddenSections = []
        setHUDClockVisible(true)
        OPNStreamTelemetry.capture("nvst.ui.hud.layout.reset", level: .info, message: "Native NVST HUD layout reset to default.", attributes: ["applicationID": configuration.applicationID])
    }

    func setHUDClockVisible(_ visible: Bool) {
        guard isHUDClockVisible != visible else { return }
        isHUDClockVisible = visible
        OPNStreamHUDSettings.isClockVisible = visible
        OPNStreamTelemetry.capture("nvst.ui.hud.clock", level: .info, message: visible ? "Native NVST HUD clock shown." : "Native NVST HUD clock hidden.", attributes: ["applicationID": configuration.applicationID])
    }

    func toggleHUDClock() {
        setHUDClockVisible(!isHUDClockVisible)
    }

    /// Opens and closes the layout editor. Remote input pauses while it is up, and closes the
    /// shortcut list so only one modal is ever on screen.
    func setHUDCustomizeVisible(_ visible: Bool) {
        guard isConnected, !isEnding, !didEnd, !streamControlsVisible else { return }
        if visible { setShortcutsHelpVisible(false) }
        isHUDCustomizeVisible = visible
        nativeView?.remoteInputEnabled = visible ? false : (!unifiedHUDVisible && networkPathAvailable)
        OPNStreamTelemetry.capture("nvst.ui.hud.customize", level: .info, message: visible ? "Native NVST HUD layout editor shown." : "Native NVST HUD layout editor hidden.", attributes: ["applicationID": configuration.applicationID])
    }

    private func storeHUDSectionOrder(_ order: [OPNStreamHUDSection], isReset: Bool = false) {
        guard order != hudSectionOrder else { return }
        hudSectionOrder = order
        OPNStreamHUDSettings.sectionOrder = order
        guard !isReset else { return }
        OPNStreamTelemetry.capture("nvst.ui.hud.section.reorder", level: .info, message: "Native NVST HUD section reordered.", attributes: ["applicationID": configuration.applicationID, "order": order.map(\.rawValue).joined(separator: ",")])
    }

    /// Folds a section away or brings it back, and remembers the choice. `symmetricDifference`
    /// toggles membership without a branch, so there is one assignment to persist and to report.
    func toggleHUDSection(_ section: OPNStreamHUDSection) {
        let isCollapsing = !collapsedHUDSections.contains(section)
        collapsedHUDSections = collapsedHUDSections.symmetricDifference([section])
        OPNStreamHUDSettings.collapsedSections = collapsedHUDSections
        // A pointer click can fold a section out from under the pad's focus. Anchor focus on the
        // header so the next activate reopens it instead of firing whatever entry is now first.
        if let focused = hudFocusID, !hudFocusEntries.contains(where: { $0.id == focused }) {
            hudFocusID = section.focusID
        }
        OPNStreamTelemetry.capture("nvst.ui.hud.section", level: .info, message: "Native NVST HUD section toggled.", attributes: ["applicationID": configuration.applicationID, "section": section.rawValue, "collapsed": String(isCollapsing)])
    }

    /// One focus entry per guest, so approving and removing are reachable from a controller. The
    /// rows match the HUD so pad navigation follows what is on screen.
    var remoteCoOpParticipantFocusEntries: [StreamHUDFocusEntry] {
        guard sidebarCapabilities.supports(.remoteCoOp) else { return [] }
        return remoteCoOpSnapshot.participants.flatMap { participant -> [StreamHUDFocusEntry] in
            var entries: [StreamHUDFocusEntry] = []
            // The quality dropdown, then approve and remove, in the order the participant's row draws
            // them, all one grid so up/down keeps the column the way the rest of the HUD does.
            let group = "coop-participant-\(participant.id.uuidString)"
            let qualityID = Self.remoteCoOpQualityDropdownPrefix + participant.id.uuidString
            let showsApprove = participant.connectionState == .waitingForApproval
            let columns = showsApprove ? 3 : 2
            entries.append(StreamHUDFocusEntry(id: qualityID, isDisabled: false, group: group, columns: columns, action: { [weak self] in
                self?.togglePadDropdown(qualityID)
            }))
            if showsApprove {
                entries.append(StreamHUDFocusEntry(id: "coop-approve-\(participant.id.uuidString)", isDisabled: false, group: group, columns: columns, action: { [weak self] in
                    self?.approveRemoteCoOpParticipant(participant.id)
                }))
            }
            entries.append(StreamHUDFocusEntry(id: "coop-remove-\(participant.id.uuidString)", isDisabled: false, group: group, columns: columns, action: { [weak self] in
                self?.removeRemoteCoOpParticipant(participant.id)
            }))
            return entries
        }
    }
}
