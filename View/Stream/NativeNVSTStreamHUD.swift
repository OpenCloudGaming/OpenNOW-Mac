//  The native NVST surface's own HUD: stats, network health, the unified dock and its panels.
//  Split out of WebRTCMediaStreamHost.swift.
//

import Combine
import Foundation
import SwiftUI

extension NativeNVSTMediaStreamSurface {
    var nativeNetworkRecoveryOverlay: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea(.container, edges: [.horizontal, .bottom])
            VStack(spacing: 14) {
                ProgressView().controlSize(.large).tint(WebRTCMediaStreamTheme.accent)
                Text("CONNECTION INTERRUPTED")
                    .font(.streamNvidia(size: 16, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(WebRTCMediaStreamTheme.accent)
                Text("Waiting for a usable network path. OpenNOW will resume the same GeForce NOW session automatically.")
                    .font(.streamNvidia(size: 12, weight: .medium))
                    .foregroundStyle(WebRTCMediaStreamTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                Button("End Stream", action: model.endFromStreamControls)
                    .buttonStyle(.bordered)
            }
            .padding(30)
            .background(WebRTCMediaStreamTheme.panel.opacity(0.96))
            .overlay(Rectangle().stroke(WebRTCMediaStreamTheme.accent.opacity(0.4), lineWidth: 1))
        }
    }

    var nativeTransientStreamMessageOverlay: some View {
        Text(model.transientStreamMessage)
            .font(.streamNvidia(size: 12, weight: .bold))
            .foregroundStyle(WebRTCMediaStreamTheme.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.86))
            .overlay(Rectangle().stroke(WebRTCMediaStreamTheme.accent.opacity(0.55), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 24)
            .allowsHitTesting(false)
    }

    var nativeMicrophoneStatusText: String {
        guard model.microphoneAvailable else { return "Disabled" }
        if model.microphoneMode == "push-to-talk" { return model.microphoneEnabled ? "PTT Active" : "PTT Ready" }
        if model.microphoneMode == "voice-activity", model.microphoneEnabled { return "Voice Activity" }
        return model.microphoneEnabled ? "On" : "Muted"
    }

    func nativeSessionLimitText(at date: Date) -> String {
        guard let sessionLimit = model.sessionLimit else { return "Unlimited" }
        let remainingSeconds = sessionLimit.remainingSeconds(at: date)
        return String(format: "%d:%02d", remainingSeconds / 60, remainingSeconds % 60)
    }

    func nativeSessionLimitIsHealthy(at date: Date) -> Bool {
        guard let sessionLimit = model.sessionLimit else { return true }
        return sessionLimit.remainingSeconds(at: date) > 300
    }

    var nativeNetworkHealthText: String {
        guard model.latestNativeStats?.available == true else { return "Waiting" }
        if (model.latestNativeStats?.packetLoss ?? 0) > 0 || (model.latestNativeStats?.jitterMilliseconds ?? 0) >= 35 || (model.latestNativeStats?.latencyMilliseconds ?? 0) >= 120 { return "Poor" }
        if (model.latestNativeStats?.jitterMilliseconds ?? 0) >= 20 || (model.latestNativeStats?.latencyMilliseconds ?? 0) >= 90 { return "Fair" }
        return "Good"
    }

    var nativeNetworkHealthIsGood: Bool {
        nativeNetworkHealthText == "Good"
    }

    var nativeLatencyText: String {
        guard model.latestNativeStats?.available == true, let latency = model.latestNativeStats?.latencyMilliseconds, latency >= 0 else { return "--" }
        return "\(Int(latency.rounded())) ms"
    }

    var nativePacketLossText: String {
        guard model.latestNativeStats?.available == true, let packetLoss = model.latestNativeStats?.packetLoss else { return "--" }
        return String(packetLoss)
    }

    var nativeNetworkWarningText: String {
        guard model.latestNativeStats?.available == true else { return "Waiting for native NVST network telemetry." }
        if (model.latestNativeStats?.packetLoss ?? 0) > 0 { return "Packet loss is active; image quality or input response may degrade." }
        if (model.latestNativeStats?.latencyMilliseconds ?? 0) >= 120 { return "Latency is high; input may feel delayed." }
        if (model.latestNativeStats?.jitterMilliseconds ?? 0) >= 35 { return "Network jitter is unstable; gameplay may stutter." }
        // Bitrate alone says nothing on NVST: the seat skips unchanged frames, so menus and pauses
        // read as a few hundred kilobits with the link perfectly healthy. The model raises this
        // only when low bitrate and a falling frame rate have persisted together.
        if let stats = model.latestNativeStats, let decodeWarning = NativeNVSTDecodeBudget.warning(for: stats) { return decodeWarning }
        if model.nativeBitrateStarved { return "Inbound bitrate is low and frames are arriving late; the link may be starved." }
        if model.latestNativeStats?.decoderIsHardware == false { return "Video is decoding in software; this colour format has no hardware decoder here." }
        return ""
    }

    var nativeUnifiedHUD: some View {
        StreamUnifiedSidebar(title: configuration.title.isEmpty ? "GeForce NOW" : configuration.title, closeAction: { model.setUnifiedHUDVisible(false) }) {
            VStack(alignment: .leading, spacing: 14) {
                nativeHUDStatusPanel
                nativeHUDControlsPanel
                nativeHUDInputPanel
                nativeHUDControllersPanel
                nativeHUDNetworkPanel
                if model.sidebarCapabilities.visibleFeatures.contains(.remoteCoOp), model.remoteCoOpPreferences.isEnabled {
                    nativeHUDRemoteCoOpPanel
                }
                nativeHUDVideoPanel
            }
        }
    }

    var nativeHUDStatusPanel: some View {
        StreamHUDWrappingRow(minimumItemWidth: 84) {
            StreamHUDMetricCard(title: "Mic", value: nativeMicrophoneStatusText, positive: model.microphoneEnabled && model.microphoneAvailable)
            StreamHUDMetricCard(title: "Rec", value: model.recordingStatusText, positive: model.recordingCanStop)
            StreamHUDMetricCard(title: "AFK", value: model.antiAFKMouseMovementEnabled ? "On" : "Off", positive: model.antiAFKMouseMovementEnabled)
            if model.sessionLimit != nil {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    StreamHUDMetricCard(title: "Session", value: nativeSessionLimitText(at: context.date), positive: nativeSessionLimitIsHealthy(at: context.date))
                }
            }
            if model.remoteCoOpPreferences.isEnabled {
                StreamHUDMetricCard(title: "Co-Op", value: model.remoteCoOpSummaryText, positive: model.remoteCoOpSnapshot.connectedParticipantCount > 0)
            }
        }
    }

    /// One row per physical controller with a battery gauge; absent when nothing is connected.
    @ViewBuilder
    var nativeHUDControllersPanel: some View {
        if !model.controllerBatteries.isEmpty {
            StreamHUDSection(label: "CONTROLLERS", spacing: 6,
                             caption: model.hudFocusID == "rumble-intensity" ? "Rumble Intensity · A steps +25%, 0 is off" : nil) {
                ForEach(model.controllerBatteries) { battery in
                    StreamHUDControllerRow(label: battery.label, name: battery.name, level: battery.level, charging: battery.charging)
                }
                // The same ceiling as Settings → Steam Controller → Rumble Intensity, reachable
                // mid-game: a title whose special moves ignore its own vibration slider is
                // discovered while playing it.
                StreamHUDSliderRow(
                    label: "Rumble Intensity %",
                    value: model.rumbleIntensityPercent,
                    range: ControllerRumblePreference.range,
                    step: ControllerRumblePreference.step,
                    isDisabled: false,
                    isFocused: model.hudFocusID == "rumble-intensity",
                    action: { model.updateRumbleIntensity(percent: $0) }
                )
                .padding(.top, 4)
            }
        }
    }

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
                          subtitle: model.pointerLocked ? "Pointer locked" : "Click stream also captures",
                          systemName: model.pointerLocked ? "cursorarrow.slash" : "cursorarrow.click",
                          isActive: model.pointerLocked,
                          isDisabled: !model.isConnected || model.nativeView?.directMouseInputEnabled != true,
                          action: model.toggleNativePointerLock),
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

    var nativeHUDNetworkPanel: some View {
        StreamHUDSection(label: "NETWORK", spacing: 8) {
            StreamHUDWrappingRow(minimumItemWidth: 84) {
                StreamHUDMetricCard(title: "Health", value: nativeNetworkHealthText, positive: nativeNetworkHealthIsGood)
                StreamHUDMetricCard(title: "Latency", value: nativeLatencyText, positive: (model.latestNativeStats?.latencyMilliseconds ?? 0) < 90)
                StreamHUDMetricCard(title: "Loss", value: nativePacketLossText, positive: (model.latestNativeStats?.packetLoss ?? 0) == 0)
            }
            if !nativeNetworkWarningText.isEmpty {
                Text(nativeNetworkWarningText)
                    .font(.streamNvidia(size: 11, weight: .medium))
                    .foregroundStyle(WebRTCMediaStreamTheme.warning)
                    .lineLimit(2)
            }
        }
    }

    var nativeHUDRemoteCoOpPanel: some View {
        StreamHUDSection(label: "CO-OP", spacing: 8, showsBetaTag: true) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.remoteCoOpTitle)
                            .font(.streamNvidia(size: 14, weight: .bold))
                            .foregroundStyle(WebRTCMediaStreamTheme.textPrimary)
                        Text(model.remoteCoOpSubtitle)
                            .font(.streamNvidia(size: 11, weight: .medium))
                            .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(model.remoteCoOpSnapshot.preferences.transportMode.label.uppercased())
                        .font(.streamNvidia(size: 9, weight: .bold))
                        .tracking(0.7)
                        .foregroundStyle(model.remoteCoOpSnapshot.preferences.transportMode == .directOnly ? WebRTCMediaStreamTheme.warning : WebRTCMediaStreamTheme.accent)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(Color.white.opacity(0.07))
                        .overlay { Rectangle().stroke(WebRTCMediaStreamTheme.divider, lineWidth: 1) }
                }
                HStack(spacing: 8) {
                    StreamHUDActionRow(
                        title: model.remoteCoOpSnapshot.invite == nil ? "Create Invite" : "End Invite",
                        subtitle: model.remoteCoOpInviteActionSubtitle,
                        systemName: model.remoteCoOpSnapshot.invite == nil ? "person.badge.plus" : "person.crop.circle.badge.xmark",
                        isActive: model.remoteCoOpSnapshot.invite != nil,
                        isDisabled: !model.sidebarCapabilities.supports(.remoteCoOp) || (model.remoteCoOpSnapshot.invite == nil && !model.canStartRemoteCoOpInvite),
                        isFocused: model.hudFocusID == "coop-invite",
                        action: { model.remoteCoOpSnapshot.invite == nil ? model.startRemoteCoOpInvite() : model.stopRemoteCoOpInvite() }
                    )
                    if model.remoteCoOpSnapshot.invite != nil {
                        StreamHUDActionRow(
                            title: "Copy Invite",
                            // Not the code: it printed the six characters a guest cannot join with,
                            // directly under the button that copies the token they can.
                            subtitle: model.remoteCoOpClipboardLabel,
                            systemName: "doc.on.doc",
                            isActive: false,
                            isDisabled: false,
                            isFocused: model.hudFocusID == "coop-copy",
                            action: { model.copyRemoteCoOpInvite() }
                        )
                    }
                    Spacer(minLength: 0)
                }
                nativeHUDDetailRow(label: "Slots", value: "\(model.remoteCoOpSnapshot.preferences.effectiveReservedGuestSlots)")
                nativeHUDDetailRow(label: "Quality", value: model.remoteCoOpSnapshot.preferences.qualityPreset.label)
                nativeHUDDetailRow(label: "Latency", value: model.remoteCoOpSnapshot.preferences.latencyMode.label)
                nativeHUDDetailRow(label: "Details", value: model.remoteCoOpSnapshot.preferences.hideGuestInviteDetails ? "Hidden" : "Visible")
                // What a guest in another OpenNOW types into "connect by address". Only needed off
                // the LAN - a guest on this network finds the host through Bonjour - so it is shown
                // rather than copied into the invite, which is a browser link.
                if let address = model.remoteCoOpNativeGuestAddress {
                    // Copyable: it is the one value in this panel a guest has to be given by hand, and
                    // reading it off a screen mid-game is how it gets mistyped.
                    Button { model.copyRemoteCoOpGuestAddress() } label: {
                        HStack(spacing: 6) {
                            nativeHUDDetailRow(label: "App Guests", value: address)
                            Image(systemName: "doc.on.doc")
                                .font(.streamNvidia(size: 9, weight: .bold))
                                .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Copy the address app guests connect to")
                }
                if let remaining = model.remoteCoOpInviteRemainingText {
                    nativeHUDDetailRow(label: "Expires", value: remaining)
                }
                if !model.remoteCoOpMessage.isEmpty {
                    Text(model.remoteCoOpMessage)
                        .font(.streamNvidia(size: 11, weight: .medium))
                        .foregroundStyle(WebRTCMediaStreamTheme.textSecondary)
                        .lineLimit(1)
                }
                if !model.remoteCoOpSnapshot.participants.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.remoteCoOpSnapshot.participants) { participant in
                            VStack(alignment: .leading, spacing: 3) {
                                nativeHUDRemoteCoOpParticipantRow(participant)
                                nativeHUDRemoteCoOpDeliveryRow(participant)
                            }
                        }
                    }
                }
            }
        }
    }

    func nativeHUDRemoteCoOpParticipantRow(_ participant: OPNRemoteCoOpParticipant) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(participant.connectionState == .connected ? WebRTCMediaStreamTheme.accent : WebRTCMediaStreamTheme.warning)
                .frame(width: 7, height: 7)
            Text(participant.displayName)
                .font(.streamNvidia(size: 11, weight: .bold))
                .foregroundStyle(WebRTCMediaStreamTheme.textPrimary)
            Spacer(minLength: 8)
            Text(participant.playerIndex.map { "P\($0 + 1)" } ?? participant.connectionState.label)
                .font(.streamNvidia(size: 10, weight: .bold))
                .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
            if participant.connectionState == .connected {
                nativeHUDRemoteCoOpQualityMenu(participant)
            }
            if participant.connectionState == .waitingForApproval {
                StreamHUDParticipantIconButton(
                    systemName: "checkmark",
                    label: "Approve guest",
                    color: WebRTCMediaStreamTheme.accent,
                    isFocused: model.hudFocusID == "coop-approve-\(participant.id.uuidString)"
                ) {
                    model.approveRemoteCoOpParticipant(participant.id)
                }
            }
            StreamHUDParticipantIconButton(
                systemName: "xmark",
                label: "Remove guest",
                color: WebRTCMediaStreamTheme.danger,
                isFocused: model.hudFocusID == "coop-remove-\(participant.id.uuidString)"
            ) {
                model.removeRemoteCoOpParticipant(participant.id)
            }
        }
    }

    /// What the guest is actually receiving, under their row.
    ///
    /// A preset is a ceiling, not a promise: the relay never upscales, the box preserves aspect ratio,
    /// and Low Latency mode lets libwebrtc trade resolution away to hold frame rate. All three are
    /// correct and all three look identical from a menu that says "4K", so the delivered size and the
    /// reason it is not larger are shown rather than left to be guessed at.
    @ViewBuilder
    func nativeHUDRemoteCoOpDeliveryRow(_ participant: OPNRemoteCoOpParticipant) -> some View {
        if participant.connectionState == .connected, let stats = model.remoteCoOpDeliveryStats[participant.id] {
            HStack(spacing: 6) {
                Image(systemName: stats.isAtBest ? "checkmark.circle" : "arrow.down.circle")
                    .font(.streamNvidia(size: 9, weight: .bold))
                    .foregroundStyle(stats.isAtBest ? WebRTCMediaStreamTheme.textTertiary : WebRTCMediaStreamTheme.warning)
                Text(stats.summary)
                    .font(.streamNvidia(size: 10, weight: .medium))
                    .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 15)
        }
    }

    /// Per-guest quality. Guests are not interchangeable - one may be on Ethernet next door and
    /// another on a hotel connection - and the encode is already per guest, so moving one up or down
    /// costs the others nothing. "Session default" is a distinct choice from the preset that happens
    /// to match it today: a guest left on it follows later changes to the session setting.
    func nativeHUDRemoteCoOpQualityMenu(_ participant: OPNRemoteCoOpParticipant) -> some View {
        Menu {
            Button {
                model.setRemoteCoOpParticipantQualityPreset(nil, for: participant.id)
            } label: {
                Label("Session Default (\(model.remoteCoOpSnapshot.preferences.qualityPreset.label))", systemImage: participant.qualityPreset == nil ? "checkmark" : "")
            }
            Divider()
            ForEach(OPNRemoteCoOpQualityPreset.allCases, id: \.self) { preset in
                Button {
                    model.setRemoteCoOpParticipantQualityPreset(preset, for: participant.id)
                } label: {
                    Label(preset.label, systemImage: participant.qualityPreset == preset ? "checkmark" : "")
                }
            }
        } label: {
            Text(participant.qualityPreset?.label ?? "Auto")
                .font(.streamNvidia(size: 10, weight: .bold))
                .foregroundStyle(participant.qualityPreset == nil ? WebRTCMediaStreamTheme.textTertiary : WebRTCMediaStreamTheme.accent)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Stream quality for this guest")
    }

    /// Split into two boxes, matching how every other HUD group (MIC/REC/AFK, NETWORK) already
    /// separates itself: one for controls you change, one for the stream's own read-only facts.
    /// Previously this was one flat "VIDEO" box mixing both, with a static "Target" info row that
    /// duplicated (and could visibly contradict) the "Target Resolution" control above it.
    var nativeHUDVideoPanel: some View {
        Group {
            nativeHUDUpscalingPanel
            nativeHUDStreamInfoPanel
        }
    }

    var nativeHUDUpscalingPanel: some View {
        StreamHUDSection(label: "UPSCALING") {
            VStack(alignment: .leading, spacing: 10) {
                // Display order is independent of the stored option array's order, which stays
                // fixed for backward compatibility.
                StreamHUDSegmentedRow(
                    label: "Upscaling",
                    options: NativeNVSTHostViewModel.upscalingTierDisplayOrder.map { ($0.value, $0.label) },
                    selection: OPNStreamPreferences.upscalingModeOptions[model.upscalingModeIndex].value,
                    isDisabled: !model.sidebarCapabilities.supports(.videoEnhancement),
                    isFocused: model.hudFocusID == "upscaling-tier",
                    onSelect: { model.updateNativeUpscalingTier(value: $0) }
                )
                StreamHUDDropdown(
                    label: "Target Resolution",
                    options: Array(OPNStreamPreferences.upscalingTargetOptions.enumerated().map { ($0.offset, $0.element.label) }),
                    selection: model.upscalingTargetIndex,
                    isDisabled: !model.isConnected || model.upscalingModeIndex == 0 || !model.sidebarCapabilities.supports(.videoEnhancement),
                    onSelect: { model.updateNativeUpscalingTarget(targetIndex: $0) },
                    isFocused: model.hudFocusID == "upscaling-target"
                )
                nativeHUDSliderRow("Clarity", value: model.upscalingSharpness, range: 0...15, isFocused: model.hudFocusID == "clarity") { model.updateNativeUpscalingClarity(sharpness: $0) }
                nativeHUDSliderRow("Noise Reduction", value: model.upscalingDenoise, range: 0...20, isFocused: model.hudFocusID == "noise-reduction") { model.updateNativeUpscalingClarity(denoise: $0) }
            }
        }
    }

    var nativeHUDStreamInfoPanel: some View {
        StreamHUDSection(label: "STREAM") {
            VStack(alignment: .leading, spacing: 10) {
                StreamHUDDropdown(
                    label: "Pillarbox Fill",
                    options: OPNPillarboxFillMode.pickerCases.map { ($0.rawValue, $0.label) },
                    selection: model.pillarboxFillModeIndex,
                    isDisabled: !model.isConnected,
                    onSelect: { model.updateNativePillarboxFill(modeIndex: $0) },
                    isFocused: model.hudFocusID == "pillarbox-fill"
                )
                nativeHUDDetailRow(label: "Active", value: model.upscalingModeIndex == 0 ? "Native" : OPNStreamPreferences.upscalingModeOptions[model.upscalingModeIndex].label)
                nativeHUDDetailRow(label: "Resolution", value: model.nativeStreamResolutionText)
                nativeHUDDetailRow(label: "Frame Rate", value: model.nativeStreamFrameRateText)
                nativeHUDDetailRow(label: "Codec", value: model.nativeStreamCodecText)
            }
        }
    }

    func nativeHUDSliderRow(_ label: String, value: Int, range: ClosedRange<Int>, isFocused: Bool = false, action: @escaping (Int) -> Void) -> some View {
        StreamHUDSliderRow(
            label: label,
            value: value,
            range: range,
            isDisabled: !model.isConnected || model.upscalingModeIndex == 0 || !model.sidebarCapabilities.supports(.videoEnhancement),
            isFocused: isFocused,
            action: action
        )
    }

    func nativeHUDDetailRow(label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.streamNvidia(size: 11, weight: .medium))
                .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
            Spacer(minLength: 8)
            Text(value)
                .font(.streamNvidia(size: 11, weight: .bold))
                .foregroundStyle(WebRTCMediaStreamTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    var nativeStreamControlsOverlay: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.54))
                .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("STREAM PAUSED")
                        .font(.streamNvidia(size: 10, weight: .bold))
                        .tracking(1.1)
                        .foregroundStyle(WebRTCMediaStreamTheme.accent)
                    Text(configuration.title.isEmpty ? "GeForce NOW" : configuration.title)
                        .font(.streamNvidia(size: 20, weight: .bold))
                        .foregroundStyle(WebRTCMediaStreamTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 22)
                .padding(.top, 16)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(WebRTCMediaStreamTheme.appBar)
                Rectangle()
                    .fill(WebRTCMediaStreamTheme.divider)
                    .frame(height: 1)
                VStack(alignment: .leading, spacing: 16) {
                    Text("Dismiss this overlay to resume input, pause the session, or quit the stream. Remote input is paused while this menu is open.")
                        .font(.streamNvidia(size: 12, weight: .medium))
                        .foregroundStyle(WebRTCMediaStreamTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        StreamQuitMenuButton(
                            title: "Resume",
                            isPrimary: true,
                            isFocused: model.streamControlsFocusIndex == 0,
                            isDisabled: model.isEnding,
                            action: model.dismissStreamControls
                        )
                        .keyboardShortcut(.cancelAction)
                        StreamQuitMenuButton(
                            title: "Pause Stream",
                            isPrimary: false,
                            isFocused: model.streamControlsFocusIndex == 1,
                            isDisabled: model.isEnding,
                            action: model.pauseFromStreamControls
                        )
                        StreamQuitMenuButton(
                            title: model.isEnding ? "Quitting..." : (model.pendingApplicationQuitCompletion == nil ? "End Stream" : "Quit OpenNOW"),
                            isPrimary: false,
                            isFocused: model.streamControlsFocusIndex == 2,
                            isDisabled: model.isEnding,
                            action: model.endFromStreamControls
                        )
                    }
                    Text("\(WebRTCMediaStreamCommand.shortcutGuide)   Esc Resume")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.36))
                }
                .padding(18)
            }
            .frame(width: 440)
            .background(WebRTCMediaStreamTheme.panel.opacity(0.985))
            .overlay {
                Rectangle()
                    .stroke(WebRTCMediaStreamTheme.accent.opacity(0.28), lineWidth: 1)
            }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(WebRTCMediaStreamTheme.accent)
                    .frame(height: 2)
            }
            .shadow(color: .black.opacity(0.58), radius: 28, x: 0, y: 20)
        }
    }
}
