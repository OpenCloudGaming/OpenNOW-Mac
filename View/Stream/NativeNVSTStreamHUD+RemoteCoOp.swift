import Combine
import Foundation
import SwiftUI

extension NativeNVSTMediaStreamSurface {
    var nativeHUDRemoteCoOpPanel: some View {
        StreamHUDSection(label: "CO-OP", spacing: 8, showsBetaTag: true) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.remoteCoOpTitle)
                            .font(.streamFont(size: 14, weight: .bold))
                            .foregroundStyle(WebRTCMediaStreamTheme.textPrimary)
                        Text(model.remoteCoOpSubtitle)
                            .font(.streamFont(size: 11, weight: .medium))
                            .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(model.remoteCoOpSnapshot.preferences.transportMode.label.uppercased())
                        .font(.streamFont(size: 9, weight: .bold))
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
                                .font(.streamFont(size: 9, weight: .bold))
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
                        .font(.streamFont(size: 11, weight: .medium))
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
                .font(.streamFont(size: 11, weight: .bold))
                .foregroundStyle(WebRTCMediaStreamTheme.textPrimary)
            Spacer(minLength: 8)
            Text(participant.playerIndex.map { "P\($0 + 1)" } ?? participant.connectionState.label)
                .font(.streamFont(size: 10, weight: .bold))
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
                    .font(.streamFont(size: 9, weight: .bold))
                    .foregroundStyle(stats.isAtBest ? WebRTCMediaStreamTheme.textTertiary : WebRTCMediaStreamTheme.warning)
                Text(stats.summary)
                    .font(.streamFont(size: 10, weight: .medium))
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
                .font(.streamFont(size: 10, weight: .bold))
                .foregroundStyle(participant.qualityPreset == nil ? WebRTCMediaStreamTheme.textTertiary : WebRTCMediaStreamTheme.accent)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Stream quality for this guest")
    }
}
