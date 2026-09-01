//
//  SettingsRemoteCoOpViews.swift
//  OpenNOW
//
//  The Remote Co-Op settings tab.
//
//  This was a single card at the bottom of Gameplay. It outgrew that: alongside the session
//  options it now carries how guests reach the host - tunnel, hosted signaling, relay - and those
//  decide whether a guest can connect at all. Buried under the streaming options they read as
//  trivia; on their own page they read as setup.
//
//  The tab only appears once the alpha is opted into in Experimental - see
//  `CatalogSettingsGroup.visibleCases(remoteCoOpOptedIn:)`.
//

import SwiftUI

struct RemoteCoOpSettingsPage: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat
    @State var turnAPITokenDraft = ""
    @State var turnKeyTokenDraft = ""
    @State var showingRelayWizard = false
    @State var showingSetupWizard = false
    @State var staticRelayPasswordDraft = ""
    @State var sharedSecretDraft = ""
    @State private var ablyKeyDraft = ""
    // Seeded once from what is already configured - see the `onAppear` below - then left to the host.
    // Defaulting all three closed is what actually shrinks the page for the common case; a host who
    // set one of them up before should still find it open.
    @State private var hostedSignalingExpanded = false
    @State private var tunnelExpanded = false
    @State var relayExpanded = false
    @State private var didSeedOptionalCardExpansion = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16 * uiScale) {
            if !OPNRemoteCoOpPreferencesStore.isNativeTransportSelected {
                SettingsCard(title: "Transport Required", uiScale: uiScale) {
                    VStack(alignment: .leading, spacing: 6 * uiScale) {
                        Text("Remote Co-Op needs the Native/NVST transport")
                            .font(.settingsNvidia(size: 15 * uiScale, weight: .bold))
                            .foregroundStyle(OpenNOWDesign.Semantic.destructive)
                        Text("Your streams are set to WebRTC, where hosting is not supported: that path decodes inside libwebrtc and gives no way to share frames without decoding and encoding them a second time, which guests experienced as a sluggish picture. Everything below is still editable, but no invite can be created until you switch Settings > Streaming > Transport to Native/NVST and relaunch.")
                            .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                            .foregroundStyle(.white.opacity(0.62))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

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
                SettingsInfoRow(label: "Served By", value: "This Mac", uiScale: uiScale)
                SettingsDivider(uiScale: uiScale)
                SettingsInfoRow(label: "Address", value: hostingSummary, uiScale: uiScale)
            }

            reachCard
            hostedSignalingCard
            tunnelCard
            relayCard
        }
        .onAppear {
            viewModel.refreshRemoteCoOpTURNUsage()
            guard !didSeedOptionalCardExpansion else { return }
            didSeedOptionalCardExpansion = true
            hostedSignalingExpanded = viewModel.remoteCoOpAblyKey.isUsable
            tunnelExpanded = viewModel.remoteCoOpPreferences.effectivePublicAddress != nil
            relayExpanded = viewModel.remoteCoOpRelayCredentials.canRelay
        }
        .sheet(isPresented: $showingRelayWizard) {
            RemoteCoOpRelayWizard(viewModel: viewModel, uiScale: uiScale) { showingRelayWizard = false }
        }
        .sheet(isPresented: $showingSetupWizard) {
            RemoteCoOpSetupWizard(
                viewModel: viewModel,
                uiScale: uiScale,
                // Handing off between two sheets: the interview decides a relay is needed, and the
                // relay wizard is where that actually gets done.
                openRelaySetup: {
                    showingSetupWizard = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { showingRelayWizard = true }
                },
                dismiss: { showingSetupWizard = false }
            )
        }
    }

    /// Signaling through a hosted channel, for the case a tunnel cannot help: the *host* being
    /// unreachable.
    ///
    /// A tunnel and a relay both assume the host can be reached or the guest can be relayed to. When
    /// the host itself is behind CGNAT or on a cafe network there is nothing to tunnel to, and the
    /// only way out is for both sides to dial outward to somewhere public.
    private var hostedSignalingCard: some View {
        SettingsCollapsibleCard(title: "Hosted Signaling (Optional)", statusSummary: hostedSignalingSummary, isConfigured: viewModel.remoteCoOpAblyKey.isUsable, uiScale: uiScale, isExpanded: $hostedSignalingExpanded) {
            Group {
                Text("Lets guests join when this Mac cannot be reached at all - behind carrier-grade NAT, or on a cafe or hotel network where no tunnel can help. Both sides connect outward to a channel instead. Guests who can already reach you keep connecting directly; this costs nothing when it is not needed.")
                    .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                SettingsDivider(uiScale: uiScale)
                SettingsInfoRow(label: "Status", value: hostedSignalingSummary, uiScale: uiScale)
                SettingsDivider(uiScale: uiScale)
                SettingsSecureTextFieldRow(
                    title: "Ably API Key",
                    subtitle: viewModel.remoteCoOpAblyKey.isUsable ? "Stored in your keychain. Type a new key to replace it." : "Stored in your keychain, never in an invite. Only a short-lived token scoped to one invite reaches guests.",
                    text: $ablyKeyDraft,
                    placeholder: viewModel.remoteCoOpAblyKey.isUsable ? "Stored" : "APP_ID.KEY_ID:SECRET",
                    uiScale: uiScale,
                    action: viewModel.setRemoteCoOpAblyKey
                )
                SettingsDivider(uiScale: uiScale)
                VStack(alignment: .leading, spacing: 6 * uiScale) {
                    if !viewModel.remoteCoOpAblyKeyMessage.isEmpty {
                        Text(viewModel.remoteCoOpAblyKeyMessage)
                            .foregroundStyle(viewModel.remoteCoOpAblyKey.isUsable ? OpenNOWDesign.accent : OpenNOWDesign.Semantic.destructive)
                    }
                    Text("Ably's free tier covers 6 million messages a month, then $2.50 per million. A whole session is a few hundred messages, so this is unlikely to cost anything.")
                    Link("Open the Ably dashboard", destination: Self.ablyDashboardURL)
                        .font(.settingsNvidia(size: 12 * uiScale, weight: .bold))
                }
                .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                if viewModel.remoteCoOpAblyKey.isUsable {
                    SettingsDivider(uiScale: uiScale)
                    SettingsTextFieldRow(
                        title: "Static Guest Page (Optional)",
                        subtitle: "A copy of the guest page hosted somewhere reachable without this Mac being reachable at all - GitHub Pages is free. Leave empty to keep serving it from this Mac, which still works for any guest who can reach you.",
                        text: viewModel.remoteCoOpPreferences.hostedGuestPageURL,
                        placeholder: "https://your-account.github.io/opennow-remote-coop/",
                        uiScale: uiScale,
                        action: viewModel.setRemoteCoOpHostedGuestPageURL
                    )
                }
            }
        }
    }

    private static let ablyDashboardURL = URL(string: "https://ably.com/accounts")!

    private var hostedSignalingSummary: String {
        guard viewModel.remoteCoOpAblyKey.isUsable else { return "Off - guests must reach this Mac" }
        guard relayCredentials.canRelay else {
            return "Ready (\(viewModel.remoteCoOpAblyKey.displayName)) - guests off your network also need the Relay card below"
        }
        return "Ready (\(viewModel.remoteCoOpAblyKey.displayName))"
    }

    /// Optional public address for a tunnel.
    ///
    /// A guest on another network cannot reach this Mac directly unless a port is forwarded, and
    /// behind CGNAT or MAP-E there is no port to forward at all. A tunnel solves that the same way a
    /// deployed broker does - by making the connection outbound - and additionally gets a
    /// certificate browsers already trust, which is the one thing local hosting cannot do for
    /// itself. Nothing is bundled: the user runs their own tunnel and pastes the address.
    private var tunnelCard: some View {
        SettingsCollapsibleCard(title: "Tunnel (Optional)", statusSummary: tunnelSummary, isConfigured: viewModel.remoteCoOpPreferences.effectivePublicAddress != nil, uiScale: uiScale, isExpanded: $tunnelExpanded) {
            Group {
                Text("Gives this Mac a public web address so a guest anywhere can open an invite link with nothing installed. Without one, invites resolve only on your own network or over a VPN. You run the tunnel yourself - cloudflared, ngrok, or Tailscale Funnel if you already use Tailscale - and paste the address it prints.")
                    .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                SettingsDivider(uiScale: uiScale)
                SettingsInfoRow(label: "Status", value: tunnelSummary, uiScale: uiScale)
                SettingsDivider(uiScale: uiScale)
                SettingsTextFieldRow(
                    title: "Public Address",
                    subtitle: "HTTPS address a tunnel exposes this Mac on. Leave empty for same-network guests.",
                    text: viewModel.remoteCoOpPreferences.publicAddress,
                    placeholder: "https://your-tunnel.example",
                    uiScale: uiScale,
                    action: viewModel.setRemoteCoOpPublicAddress
                )
                SettingsDivider(uiScale: uiScale)
                SettingsInfoRow(label: "Forward To", value: tunnelTargetURL, uiScale: uiScale)
                SettingsDivider(uiScale: uiScale)
                VStack(alignment: .leading, spacing: 6 * uiScale) {
                    Text("Point a tunnel at the address above, then paste the public HTTPS URL it prints.")
                        .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(Self.tunnelExampleCommands)
                        .font(.system(size: 11 * uiScale, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.72))
                        .textSelection(.enabled)
                        .padding(10 * uiScale)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.05))
                        .overlay { Rectangle().stroke(Color.white.opacity(0.12), lineWidth: 1) }
                    Text("Both flags matter: the tunnel reaches this Mac over HTTPS with a self-signed certificate, so it has to be told not to verify it. Your guest only ever sees the tunnel's own certificate.")
                        .font(.settingsNvidia(size: 11 * uiScale, weight: .medium))
                        .foregroundStyle(.white.opacity(0.44))
                        .fixedSize(horizontal: false, vertical: true)
                    if let setupGuideURL = Self.setupGuideURL {
                        Link("Remote Co-Op setup guide", destination: setupGuideURL)
                            .font(.settingsNvidia(size: 12 * uiScale, weight: .bold))
                            .foregroundStyle(OpenNOWDesign.accent)
                    }
                }
                .padding(.vertical, 4 * uiScale)
            }
        }
    }

    static let setupGuideURL = URL(string: "https://github.com/OpenCloudGaming/OpenNOW-Mac/blob/main/RemoteCoOp/README.md")

    /// Two options rather than one, because they differ in ways that matter to a guest: a Cloudflare
    /// quick tunnel needs no account, while ngrok's free tier shows a click-through warning page
    /// before the join page loads.
    static let tunnelExampleCommands = """
    # Cloudflare (no account needed)
    cloudflared tunnel --url https://127.0.0.1:32188 --no-tls-verify

    # ngrok (needs a free account)
    ngrok http https://127.0.0.1:32188 --host-header=rewrite
    """

    private var tunnelTargetURL: String {
        "https://127.0.0.1:\(OPNRemoteCoOpHostingEndpoint.defaultLocalPort)"
    }

    /// Says which of the two failure modes the field is in, because both are silent otherwise: a
    /// plaintext address leaves the guest unable to build a peer connection, and a malformed one is
    /// simply ignored.
    /// Reads as an estimate, not a bill: the allowance is shared with Cloudflare's SFU and the query
    /// is calendar month-to-date, which need not match their billing cycle.
    var relayUsageValue: String {
        viewModel.remoteCoOpTURNUsage?.summary ?? "Unknown"
    }

    var relayUsageSubtitle: String {
        if !viewModel.remoteCoOpTURNUsageMessage.isEmpty { return viewModel.remoteCoOpTURNUsageMessage }
        guard let usage = viewModel.remoteCoOpTURNUsage else { return "Reads when this tab opens." }
        let hours = usage.remainingHours(atPreset: viewModel.remoteCoOpPreferences.qualityPreset)
        return String(format: "About %.0f more hours at %@, if every guest were relayed. Shared with Cloudflare's SFU, and counted from the first of the month rather than your billing date.", hours, viewModel.remoteCoOpPreferences.qualityPreset.label)
    }

    var relaySummary: String {
        guard relayCredentials.canRelay else {
            return relayCredentials.account.hasToken ? "Token saved - run Set Up Relay" : "Direct only"
        }
        return relayCredentials.canReportUsage ? "Cloudflare relay ready" : "Relay ready - no usage readout"
    }

    private var tunnelSummary: String {
        let raw = viewModel.remoteCoOpPreferences.publicAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "Not set - guests must be on your network" }
        guard viewModel.remoteCoOpPreferences.effectivePublicAddress != nil else {
            return raw.lowercased().hasPrefix("http://")
                ? "Must be HTTPS - browsers block WebRTC on plaintext"
                : "Not a valid HTTPS address"
        }
        return "Guests will be sent to this address"
    }

    /// Where guests are told to connect. Both states are worth naming: a tunnel address changes the
    /// answer completely, and without one the session is reachable on this network only.
    private var hostingSummary: String {
        if let tunnel = viewModel.remoteCoOpPreferences.effectivePublicAddress {
            return tunnel.host ?? tunnel.absoluteString
        }
        return "\(OPNRemoteCoOpLocalAddress.advertisedHost()):\(OPNRemoteCoOpHostingEndpoint.defaultLocalPort) (this network only)"
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
