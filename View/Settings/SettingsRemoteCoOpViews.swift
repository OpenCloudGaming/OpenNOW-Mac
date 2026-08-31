//
//  SettingsRemoteCoOpViews.swift
//  OpenNOW
//
//  The Remote Co-Op settings tab.
//
//  This was a single card at the bottom of Gameplay. It outgrew that: alongside the session
//  options it now carries the broker address, the guest join address and the invite signing
//  secret, and those three decide whether a guest can connect at all. Buried under the streaming
//  options they read as trivia; on their own page they read as setup.
//
//  The tab only appears once the alpha is opted into in Experimental - see
//  `CatalogSettingsGroup.visibleCases(remoteCoOpOptedIn:)`.
//

import SwiftUI

struct RemoteCoOpSettingsPage: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat
    /// Write-only: the stored secret is never read back into the field. It is a signing key, and a
    /// keychain item that renders itself into a view every time Settings opens is one screenshot
    /// away from being someone else's.
    @State private var inviteSecretDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16 * uiScale) {
            SettingsCard(title: "Session", uiScale: uiScale) {
                SettingsToggleRow(
                    title: "Enable Remote Co-Op",
                    subtitle: "Allows the stream HUD to generate an invite for a remote player. Changes apply to newly launched streams.",
                    isOn: viewModel.remoteCoOpPreferences.isEnabled,
                    uiScale: uiScale,
                    action: viewModel.setRemoteCoOpEnabled
                )
                SettingsDivider(uiScale: uiScale)
                SettingsOptionRow(
                    title: "Reserved Controllers",
                    subtitle: "Advertises remote gamepad slots to GeForce NOW before launch. Player 2 requires at least one reserved slot.",
                    options: ["None", "1 Guest", "2 Guests", "3 Guests"],
                    selectedIndex: viewModel.remoteCoOpPreferences.reservedGuestSlots,
                    uiScale: uiScale,
                    action: viewModel.setRemoteCoOpReservedGuestSlots
                )
                SettingsDivider(uiScale: uiScale)
                SettingsToggleRow(
                    title: "Require Host Approval",
                    subtitle: "Guests can join the room, but input remains disabled until the host approves them.",
                    isOn: viewModel.remoteCoOpPreferences.requireHostApproval,
                    uiScale: uiScale,
                    action: viewModel.setRemoteCoOpRequireHostApproval
                )
                SettingsDivider(uiScale: uiScale)
                SettingsToggleRow(
                    title: "Hide Guest Invite Details",
                    subtitle: "Share opaque invites that do not reveal the game title or app ID to guests.",
                    isOn: viewModel.remoteCoOpPreferences.hideGuestInviteDetails,
                    uiScale: uiScale,
                    action: viewModel.setRemoteCoOpHideGuestInviteDetails
                )
            }

            SettingsCard(title: "Guest Stream", uiScale: uiScale) {
                SettingsOptionRow(
                    title: "Transport",
                    subtitle: viewModel.remoteCoOpPreferences.transportMode.description,
                    options: OPNRemoteCoOpTransportMode.allCases.map(\.label),
                    selectedIndex: selectedTransportModeIndex,
                    uiScale: uiScale,
                    action: viewModel.setRemoteCoOpTransportModeIndex
                )
                SettingsDivider(uiScale: uiScale)
                SettingsOptionRow(
                    title: "Guest Quality",
                    subtitle: "Caps the outbound Remote Co-Op stream sent to guests.",
                    options: OPNRemoteCoOpQualityPreset.allCases.map(\.label),
                    selectedIndex: selectedQualityPresetIndex,
                    uiScale: uiScale,
                    action: viewModel.setRemoteCoOpQualityPresetIndex
                )
                SettingsDivider(uiScale: uiScale)
                SettingsOptionRow(
                    title: "Latency Mode",
                    subtitle: viewModel.remoteCoOpPreferences.latencyMode.description,
                    options: OPNRemoteCoOpLatencyMode.allCases.map(\.label),
                    selectedIndex: selectedLatencyModeIndex,
                    uiScale: uiScale,
                    action: viewModel.setRemoteCoOpLatencyModeIndex
                )
            }

            SettingsCard(title: "Hosting", uiScale: uiScale) {
                SettingsOptionRow(
                    title: "Signaling Host",
                    subtitle: viewModel.remoteCoOpPreferences.hostingMode.description,
                    options: OPNRemoteCoOpHostingMode.allCases.map(\.label),
                    selectedIndex: selectedHostingModeIndex,
                    uiScale: uiScale,
                    action: viewModel.setRemoteCoOpHostingModeIndex
                )
                SettingsDivider(uiScale: uiScale)
                SettingsInfoRow(label: "Status", value: hostingSummary, uiScale: uiScale)
            }

            if viewModel.remoteCoOpPreferences.hostingMode == .externalBroker {
                brokerCard
            }
        }
    }

    /// Only shown for a deployed broker. Hosting locally derives every one of these - the addresses
    /// come from the bound listener, and the signing secret does not exist because the app both
    /// signs and verifies its own invites.
    private var brokerCard: some View {
        SettingsCard(title: "Broker", uiScale: uiScale) {
            Group {
                SettingsTextFieldRow(
                    title: "Signaling Server",
                    subtitle: "WebSocket URL of the Remote Co-Op broker. Must match the address the broker printed at startup.",
                    text: viewModel.remoteCoOpPreferences.signalingServerURL,
                    placeholder: OPNRemoteCoOpPreferences.defaultSignalingServerURL,
                    uiScale: uiScale,
                    action: viewModel.setRemoteCoOpSignalingServerURL
                )
                SettingsDivider(uiScale: uiScale)
                SettingsTextFieldRow(
                    title: "Guest Join URL",
                    subtitle: "Base address of the browser join page invites link to. Must be HTTPS: browsers only allow WebRTC from a secure origin.",
                    text: viewModel.remoteCoOpPreferences.guestJoinBaseURL,
                    placeholder: OPNRemoteCoOpPreferences.defaultGuestJoinBaseURL,
                    uiScale: uiScale,
                    action: viewModel.setRemoteCoOpGuestJoinBaseURL
                )
                SettingsDivider(uiScale: uiScale)
                SettingsSecureTextFieldRow(
                    title: "Invite Signing Secret",
                    subtitle: inviteSecretSubtitle,
                    text: $inviteSecretDraft,
                    placeholder: "OPENNOW_REMOTE_COOP_INVITE_SECRET",
                    uiScale: uiScale,
                    action: viewModel.setRemoteCoOpInviteSecret
                )
            }
        }
    }

    /// The broker verifies every invite signature and rejects the host's own registration when it
    /// does not match, so an unset or mismatched secret is not a degraded mode - it is a session
    /// nobody can join. No local check can see a *mismatch*, only an absence.
    private var inviteSecretSubtitle: String {
        viewModel.remoteCoOpInviteSecretConfigured
            ? "Stored in the keychain. Must match the broker's OPENNOW_REMOTE_COOP_INVITE_SECRET."
            : "Not set - guests cannot join. Paste the broker's OPENNOW_REMOTE_COOP_INVITE_SECRET."
    }

    /// What the host needs to know before creating an invite, in one line. Both failure modes here
    /// are silent otherwise: a plaintext guest URL cannot build a peer connection at all, and a
    /// missing signing secret means the broker rejects the host's own registration.
    private var hostingSummary: String {
        switch viewModel.remoteCoOpPreferences.hostingMode {
        case .local:
            return "OpenNOW serves the invite on \(OPNRemoteCoOpLocalAddress.advertisedHost()):\(OPNRemoteCoOpHostingEndpoint.defaultLocalPort). Guests accept a certificate warning once."
        case .externalBroker:
            guard let url = URL(string: viewModel.remoteCoOpPreferences.guestJoinBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let scheme = url.scheme?.lowercased() else { return "Guest join URL is not a valid address" }
            guard scheme == "https" else { return "Guest join URL must be HTTPS for WebRTC to work" }
            return viewModel.remoteCoOpInviteSecretConfigured ? "Configured" : "Signing secret missing - guests cannot join"
        }
    }

    private var selectedHostingModeIndex: Int {
        OPNRemoteCoOpHostingMode.allCases.firstIndex(of: viewModel.remoteCoOpPreferences.hostingMode) ?? 0
    }

    private var selectedTransportModeIndex: Int {
        OPNRemoteCoOpTransportMode.allCases.firstIndex(of: viewModel.remoteCoOpPreferences.transportMode) ?? 0
    }

    private var selectedQualityPresetIndex: Int {
        OPNRemoteCoOpQualityPreset.allCases.firstIndex(of: viewModel.remoteCoOpPreferences.qualityPreset) ?? 0
    }

    private var selectedLatencyModeIndex: Int {
        OPNRemoteCoOpLatencyMode.allCases.firstIndex(of: viewModel.remoteCoOpPreferences.latencyMode) ?? 0
    }
}
