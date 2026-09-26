import Combine
import Foundation
import SwiftUI

extension NativeNVSTMediaStreamSurface {
    /// One icon tile of a HUD grid. Declared as data so the grid and the caption under it read the
    /// same title — a pad user has no hover tooltip to learn what an icon does.
    struct NativeHUDTile: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let systemName: String
        let isActive: Bool
        let isDisabled: Bool
        let action: () -> Void
    }

    var nativeHUDAudioTiles: [NativeHUDTile] {
        [
            // The glyph shows the current state, not the action: a green tile with a slashed mic read
            // as "muted" while the microphone was live. Green now means audio is flowing.
            NativeHUDTile(id: "microphone",
                          title: model.microphoneEnabled ? "Mute microphone" : "Unmute microphone",
                          subtitle: nativeMicrophoneStatusText,
                          systemName: model.microphoneEnabled ? "mic.fill" : "mic.slash.fill",
                          isActive: model.microphoneEnabled && model.microphoneAvailable,
                          isDisabled: !model.sidebarCapabilities.supports(.microphone) || !model.microphoneAvailable || model.microphoneUpdateTask != nil,
                          action: model.toggleNativeMicrophone),
            NativeHUDTile(id: "localAudioMute",
                          title: model.nativeLocalAudioMuted ? "Unmute Local Audio" : "Mute Local Audio",
                          subtitle: model.nativeLocalAudioMuted ? "Muted on this Mac" : "Playing on this Mac",
                          systemName: model.nativeLocalAudioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                          isActive: !model.nativeLocalAudioMuted,
                          isDisabled: !model.isConnected,
                          action: model.toggleNativeLocalAudioMute),
        ]
    }

    var nativeHUDCaptureTiles: [NativeHUDTile] {
        [
            NativeHUDTile(id: "recording",
                          title: model.recordingCanStop ? "Stop Recording" : "Record",
                          subtitle: model.recordingStatusText,
                          systemName: model.recordingCanStop ? "stop.circle" : "record.circle",
                          isActive: model.recordingCanStop,
                          isDisabled: !model.sidebarCapabilities.supports(.recording) || !model.isConnected || model.recordingIsBusy,
                          action: model.toggleNativeRecording),
        ]
        + replayControlTiles
        + [
            NativeHUDTile(id: "screenshot",
                          title: "Screenshot",
                          subtitle: "Save current frame",
                          systemName: "camera.fill",
                          isActive: false,
                          isDisabled: !model.sidebarCapabilities.supports(.screenshot) || !model.isConnected || model.screenshotTask != nil,
                          action: model.takeNativeScreenshot),
        ]
    }

    var nativeHUDDisplayTiles: [NativeHUDTile] {
        [
            NativeHUDTile(id: "floating-stats",
                          title: model.nativeStatsVisible ? "Hide Floating Stats" : "Show Floating Stats",
                          subtitle: "\(model.statsDetail.title) overlay",
                          systemName: "chart.line.uptrend.xyaxis",
                          isActive: model.nativeStatsVisible,
                          isDisabled: !model.sidebarCapabilities.supports(.floatingStats),
                          action: model.toggleNativeStatsHUD),
            NativeHUDTile(id: "full-screen",
                          title: model.streamWindowIsFullScreen ? "Leave Full Screen" : "Enter Full Screen",
                          subtitle: model.streamWindowIsFullScreen ? "Full screen" : "Windowed",
                          systemName: model.streamWindowIsFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                          isActive: model.streamWindowIsFullScreen,
                          isDisabled: model.isFullScreenTileDisabled,
                          action: model.toggleNativeFullScreen),
            // `pip` is the canonical macOS PiP glyph - the shape Apple uses in Safari, QuickTime and
            // TV. One symbol for both states, with the state carried by `isActive`, matching
            // `floating-stats` beside it. SF Symbols 2 / macOS 11+, below the 15.6 deployment
            // target; a missing symbol renders a blank tile rather than failing to compile, so the
            // availability is asserted in `StreamSidebarFeaturesTests`.
            NativeHUDTile(id: "picture-in-picture",
                          title: model.isPictureInPicture ? "Leave Picture in Picture" : "Picture in Picture",
                          subtitle: model.isPictureInPicture ? "Floating" : "Small floating window",
                          systemName: "pip",
                          isActive: model.isPictureInPicture,
                          isDisabled: !model.sidebarCapabilities.supports(.pictureInPicture),
                          action: model.togglePictureInPicture),
        ]
    }

    var nativeHUDControllerTiles: [NativeHUDTile] {
        [
            NativeHUDTile(id: "controller-mapping",
                          title: "Controller Mapping",
                          subtitle: hasPerGameControllerMappingOverride
                              ? "Custom for this game"
                              : "Per-controller custom bindings",
                          systemName: "gamecontroller",
                          isActive: hasPerGameControllerMappingOverride,
                          isDisabled: false,
                          action: { model.showingControllerMapping = true }),
            NativeHUDTile(id: "controller-order",
                          title: "Reorder Controllers",
                          subtitle: "Choose Player 1–4",
                          systemName: "arrow.up.arrow.down",
                          isActive: false,
                          isDisabled: false,
                          action: { model.showingControllerOrder = true }),
        ]
    }

    /// True while the running game overrides at least one controller type, so the HUD shows the
    /// mapping in effect rather than every tile reading inactive.
    private var hasPerGameControllerMappingOverride: Bool {
        let mappingStore = ControllerMappingStore.shared
        guard mappingStore.isCurrentGameKnown else { return false }
        return ControllerFamily.allCases.contains { mappingStore.activeOverride(for: $0) != nil }
    }

    var nativeHUDInputTiles: [NativeHUDTile] {
        [
            NativeHUDTile(id: "pointer",
                          title: model.pointerLocked ? "Release Mouse" : "Capture Mouse",
                          subtitle: model.mouseModeSubtitle,
                          systemName: model.pointerLocked ? "cursorarrow.slash" : "cursorarrow.click",
                          isActive: model.pointerLocked,
                          isDisabled: !model.isConnected,
                          action: model.toggleNativePointerLock),
            NativeHUDTile(id: "cursor-policy",
                          title: "Cursor",
                          subtitle: model.cursorPolicySubtitle,
                          systemName: model.cursorPolicySymbolName,
                          isActive: model.cursorPolicy != .auto,
                          isDisabled: !model.isConnected,
                          action: model.cycleCursorPolicy),
            NativeHUDTile(id: "anti-afk",
                          title: model.antiAFKMouseMovementEnabled ? "Disable Anti-AFK" : "Enable Anti-AFK",
                          subtitle: model.antiAFKMouseMovementEnabled ? "Active" : "Idle",
                          systemName: "cursorarrow.motionlines",
                          isActive: model.antiAFKMouseMovementEnabled,
                          isDisabled: !model.sidebarCapabilities.supports(.antiAFK) || !model.isConnected,
                          action: model.toggleNativeAntiAFKMouseMovement),
        ]
    }

    /// The replay tile is drawn only in Instant Replay mode, the way Steam's manual mode offers no
    /// "save the last N" action at all.
    private var replayControlTiles: [NativeHUDTile] {
        guard model.isInstantReplayEnabled else { return [] }
        return [NativeHUDTile(id: "replay",
                              title: "Save Replay",
                              subtitle: model.replayBufferStatusText,
                              systemName: "film.stack",
                              isActive: model.isReplayBufferActive,
                              isDisabled: !model.sidebarCapabilities.supports(.recording) || !model.isConnected || !model.isReplayBufferActive || model.replayBufferState.isSaving,
                              action: model.saveNativeReplayClip)]
    }

    /// `Title · subtitle` of the focused tile in `tiles`, or nil when focus is elsewhere.
    func nativeHUDCaption(for tiles: [NativeHUDTile], extra: [(id: String, caption: String)] = []) -> String? {
        guard let focus = model.hudFocusID else { return nil }
        if let tile = tiles.first(where: { $0.id == focus }) {
            return tile.subtitle.isEmpty ? tile.title : "\(tile.title) · \(tile.subtitle)"
        }
        return extra.first(where: { $0.id == focus })?.caption
    }

    /// One row per panel, with the columns equal to the panel's tile count (capped at four), so the
    /// row fills the panel width and a short panel leaves no dead space on the right.
    func nativeHUDTileGrid(_ tiles: [NativeHUDTile]) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: min(max(tiles.count, 1), 4))
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(tiles) { tile in
                StreamHUDActionRow(
                    title: tile.title,
                    subtitle: tile.subtitle,
                    systemName: tile.systemName,
                    isActive: tile.isActive,
                    isDisabled: tile.isDisabled,
                    isFocused: model.hudFocusID == tile.id,
                    isWidthFlexible: true,
                    action: tile.action
                )
            }
        }
    }

    var nativeHUDAudioPanel: some View {
        let tiles = nativeHUDAudioTiles
        return StreamHUDSection(
            label: OPNStreamHUDSection.audio.title,
            spacing: 8,
            caption: nativeHUDCaption(for: tiles, extra: [
                (NativeNVSTHostViewModel.microphoneModeDropdownID, model.microphoneModeCaption),
                (NativeNVSTHostViewModel.microphoneDeviceDropdownID, model.microphoneDeviceCaption),
            ]),
            isCollapsed: model.isHUDSectionCollapsed(.audio),
            isFocused: model.isHUDSectionHeaderFocused(.audio),
            reorderPayload: OPNStreamHUDSection.audio.rawValue,
            onToggle: { model.toggleHUDSection(.audio) }
        ) {
            nativeHUDTileGrid(tiles)
            // Below the tiles: full-width rows of their own, because they change settings rather than
            // toggling a state, and the pad reads each as the row it draws as.
            microphoneUnavailableNotice
            nativeHUDMicrophoneModeRow
            nativeHUDMicrophoneDeviceRow
            nativeHUDMicrophoneLevelRow
        }
    }

    /// Off, held-to-talk, or always capturing. Which modes are live depends on whether this session
    /// asked for a microphone section, and the notice above the row says so when they are not.
    var nativeHUDMicrophoneModeRow: some View {
        microphoneDropdownRow(
            label: "Microphone Mode",
            dropdownID: NativeNVSTHostViewModel.microphoneModeDropdownID,
            selection: model.microphoneMode,
            isDisabled: model.isMicrophoneModeRowDisabled
        )
    }

    /// One row of the AUDIO panel: the HUD's own dropdown, whose rows carry their own actions.
    func microphoneDropdownRow(label: String, dropdownID: String, selection: String, isDisabled: Bool) -> some View {
        StreamHUDDropdown(
            label: label,
            rows: model.padDropdownItems(dropdownID),
            selection: selection,
            isDisabled: isDisabled,
            isFocused: model.hudFocusID == dropdownID,
            // Capped so a long list scrolls rather than running the height of the HUD.
            visibleItemCount: 6,
            padDriver: model.padDropdown(dropdownID: dropdownID)
        )
    }

    /// The microphone the stream captures from: where the picker's saved choice reaches capture, and
    /// where it can be changed without leaving the session.
    var nativeHUDMicrophoneDeviceRow: some View {
        microphoneDropdownRow(
            label: "Microphone Device",
            dropdownID: NativeNVSTHostViewModel.microphoneDeviceDropdownID,
            selection: model.selectedMicrophoneDeviceUID,
            isDisabled: model.isMicrophoneDeviceRowDisabled
        )
    }

    /// Why the microphone rows are unusable, in the microphone tile's own words. Drawn above the rows
    /// rather than instead of them, so the rows the pad stands on stay where they were.
    @ViewBuilder
    var microphoneUnavailableNotice: some View {
        if let reason = model.microphoneUnavailableReason {
            Text(reason)
                .font(.streamFont(size: 10, weight: .medium))
                .foregroundStyle(StreamHUDTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The live meter, beside the picker. Scaled exactly as the Settings mic test scales its own, so
    /// the pre-flight and the session read the same for the same input.
    var nativeHUDMicrophoneLevelRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text("Microphone Level")
                    .font(.streamFont(size: 11, weight: .medium))
                    .foregroundStyle(StreamHUDTheme.textTertiary)
                Spacer(minLength: 8)
                Text("\(model.microphoneLevelPercent)%")
                    .font(.streamFont(size: 11, weight: .bold))
                    .foregroundStyle(StreamHUDTheme.textPrimary)
                    .frame(minWidth: 32, alignment: .trailing)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.075))
                    Rectangle()
                        .fill(StreamHUDTheme.accent)
                        .frame(width: proxy.size.width * CGFloat(min(max(model.microphoneLevel, 0), 1)))
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Microphone level")
        .accessibilityValue("\(model.microphoneLevelPercent) percent")
    }

    var nativeHUDCapturePanel: some View {
        let tiles = nativeHUDCaptureTiles
        return StreamHUDSection(
            label: OPNStreamHUDSection.capture.title,
            spacing: 8,
            caption: nativeHUDCaption(for: tiles),
            isCollapsed: model.isHUDSectionCollapsed(.capture),
            isFocused: model.isHUDSectionHeaderFocused(.capture),
            reorderPayload: OPNStreamHUDSection.capture.rawValue,
            onToggle: { model.toggleHUDSection(.capture) }
        ) {
            nativeHUDTileGrid(tiles)
        }
    }

    var nativeHUDDisplayPanel: some View {
        let tiles = nativeHUDDisplayTiles
        return StreamHUDSection(
            label: OPNStreamHUDSection.display.title,
            spacing: 8,
            caption: nativeHUDCaption(for: tiles),
            isCollapsed: model.isHUDSectionCollapsed(.display),
            isFocused: model.isHUDSectionHeaderFocused(.display),
            reorderPayload: OPNStreamHUDSection.display.rawValue,
            onToggle: { model.toggleHUDSection(.display) }
        ) {
            nativeHUDTileGrid(tiles)
        }
    }

    var nativeHUDInputPanel: some View {
        let tiles = nativeHUDInputTiles
        return StreamHUDSection(
            label: OPNStreamHUDSection.input.title,
            spacing: 8,
            caption: nativeHUDCaption(for: tiles, extra: [("mouse-sensitivity", "Mouse Sensitivity · A steps +25%")]),
            isCollapsed: model.isHUDSectionCollapsed(.input),
            isFocused: model.isHUDSectionHeaderFocused(.input),
            reorderPayload: OPNStreamHUDSection.input.rawValue,
            onToggle: { model.toggleHUDSection(.input) }
        ) {
            nativeHUDTileGrid(tiles)
            StreamHUDSliderRow(
                label: "Mouse Sensitivity %",
                value: model.mouseSensitivityPercent,
                range: OPNStreamPreferences.mouseSensitivityRange,
                step: OPNStreamPreferences.mouseSensitivityStep,
                isDisabled: !model.isConnected,
                isFocused: model.hudFocusID == "mouse-sensitivity",
                action: { model.updateNativeMouseSensitivity(percent: $0) }
            )
        }
    }
}
