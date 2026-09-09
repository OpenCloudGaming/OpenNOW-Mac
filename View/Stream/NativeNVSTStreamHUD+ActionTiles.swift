import Combine
import Foundation
import SwiftUI

extension NativeNVSTMediaStreamSurface {
    /// Fixed rows of at most 4 buttons each, rather than the grid's adaptive wrap — the wrap could
    /// pack 5 across on a wide sidebar (as seen with all 7 buttons: 5 then a stray 2), which reads
    /// as an uneven long row instead of a deliberate grid.
    /// Fixed 4 columns, not an adaptive wrap - the adaptive grid could pack 5 across on a wide
    /// sidebar (5 then a stray 2 for these 7 buttons), which reads as an uneven long row instead of
    /// a deliberate grid.
    static let nativeHUDControlsColumns = Array(repeating: GridItem(.fixed(42), spacing: 8), count: 4)

    /// One icon tile of the CONTROLS / INPUT grids. Declared as data so the grid and the caption
    /// under it read the same title — a pad user has no hover tooltip to learn what an icon does.
    struct NativeHUDTile: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let systemName: String
        let isActive: Bool
        let isDisabled: Bool
        let action: () -> Void
    }

    var nativeHUDControlTiles: [NativeHUDTile] {
        [
            NativeHUDTile(id: "microphone",
                          title: model.microphoneEnabled ? "Mute microphone" : "Unmute microphone",
                          subtitle: nativeMicrophoneStatusText,
                          systemName: model.microphoneEnabled ? "mic.slash.fill" : "mic.fill",
                          isActive: model.microphoneEnabled && model.microphoneAvailable,
                          isDisabled: !model.sidebarCapabilities.supports(.microphone) || !model.microphoneAvailable || model.microphoneUpdateTask != nil,
                          action: model.toggleNativeMicrophone),
            NativeHUDTile(id: "localAudioMute",
                          title: model.nativeLocalAudioMuted ? "Unmute Local Audio" : "Mute Local Audio",
                          subtitle: model.nativeLocalAudioMuted ? "Muted on this Mac" : "Playing on this Mac",
                          systemName: model.nativeLocalAudioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                          isActive: model.nativeLocalAudioMuted,
                          isDisabled: !model.isConnected,
                          action: model.toggleNativeLocalAudioMute),
            NativeHUDTile(id: "recording",
                          title: model.recordingCanStop ? "Stop Recording" : "Record",
                          subtitle: model.recordingStatusText,
                          systemName: model.recordingCanStop ? "stop.circle" : "record.circle",
                          isActive: model.recordingCanStop,
                          isDisabled: !model.sidebarCapabilities.supports(.recording) || !model.isConnected || model.recordingIsBusy,
                          action: model.toggleNativeRecording),
            NativeHUDTile(id: "floating-stats",
                          title: model.nativeStatsVisible ? "Hide Floating Stats" : "Show Floating Stats",
                          subtitle: "Detailed overlay",
                          systemName: "chart.line.uptrend.xyaxis",
                          isActive: model.nativeStatsVisible,
                          isDisabled: !model.sidebarCapabilities.supports(.floatingStats),
                          action: model.toggleNativeStatsHUD),
        ]
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
            NativeHUDTile(id: "controller-mapping",
                          title: "Controller Mapping",
                          subtitle: "Steam Controller grip binds",
                          systemName: "gamecontroller",
                          isActive: false,
                          isDisabled: false,
                          action: { model.showingControllerMapping = true }),
            NativeHUDTile(id: "quit",
                          title: "Quit Menu",
                          subtitle: "End session",
                          systemName: "power",
                          isActive: false,
                          isDisabled: false,
                          action: { model.showStreamControls() }),
        ]
    }

    /// `Title · subtitle` of the focused tile in `tiles`, or nil when focus is elsewhere.
    func nativeHUDCaption(for tiles: [NativeHUDTile], extra: [(id: String, caption: String)] = []) -> String? {
        guard let focus = model.hudFocusID else { return nil }
        if let tile = tiles.first(where: { $0.id == focus }) {
            return tile.subtitle.isEmpty ? tile.title : "\(tile.title) · \(tile.subtitle)"
        }
        return extra.first(where: { $0.id == focus })?.caption
    }

    func nativeHUDTileGrid(_ tiles: [NativeHUDTile]) -> some View {
        LazyVGrid(columns: Self.nativeHUDControlsColumns, alignment: .leading, spacing: 8) {
            ForEach(tiles) { tile in
                StreamHUDActionRow(
                    title: tile.title,
                    subtitle: tile.subtitle,
                    systemName: tile.systemName,
                    isActive: tile.isActive,
                    isDisabled: tile.isDisabled,
                    isFocused: model.hudFocusID == tile.id,
                    action: tile.action
                )
            }
        }
    }

    var nativeHUDControlsPanel: some View {
        let tiles = nativeHUDControlTiles
        return StreamHUDSection(label: "CONTROLS", spacing: 8, caption: nativeHUDCaption(for: tiles)) {
            nativeHUDTileGrid(tiles)
        }
    }

    var nativeHUDInputPanel: some View {
        let tiles = nativeHUDInputTiles
        return StreamHUDSection(label: "INPUT", spacing: 8, caption: nativeHUDCaption(for: tiles, extra: [("mouse-sensitivity", "Mouse Sensitivity · A steps +25%")])) {
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
