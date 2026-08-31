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
                SettingsInfoRow(label: "Served By", value: "This Mac", uiScale: uiScale)
                SettingsDivider(uiScale: uiScale)
                SettingsInfoRow(label: "Address", value: hostingSummary, uiScale: uiScale)
            }

            tunnelCard
        }
    }

    /// Optional public address for a tunnel.
    ///
    /// A guest on another network cannot reach this Mac directly unless a port is forwarded, and
    /// behind CGNAT or MAP-E there is no port to forward at all. A tunnel solves that the same way a
    /// deployed broker does - by making the connection outbound - and additionally gets a
    /// certificate browsers already trust, which is the one thing local hosting cannot do for
    /// itself. Nothing is bundled: the user runs their own tunnel and pastes the address.
    private var tunnelCard: some View {
        SettingsCard(title: "Tunnel (Optional)", uiScale: uiScale) {
            Group {
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
                    Link("Remote Co-Op setup guide", destination: Self.setupGuideURL)
                        .font(.settingsNvidia(size: 12 * uiScale, weight: .bold))
                        .foregroundStyle(OpenNOWDesign.accent)
                }
                .padding(.vertical, 4 * uiScale)
            }
        }
    }

    static let setupGuideURL = URL(string: "https://github.com/OpenCloudGaming/OpenNOW-Mac/blob/main/RemoteCoOp/README.md")!

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
