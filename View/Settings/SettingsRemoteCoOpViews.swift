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
    @State private var turnAPITokenDraft = ""
    @State private var turnKeyTokenDraft = ""
    @State private var showingRelayWizard = false
    @State private var showingSetupWizard = false
    @State private var staticRelayPasswordDraft = ""
    @State private var sharedSecretDraft = ""
    @State private var ablyKeyDraft = ""
    // Seeded once from what is already configured - see the `onAppear` below - then left to the host.
    // Defaulting all three closed is what actually shrinks the page for the common case; a host who
    // set one of them up before should still find it open.
    @State private var hostedSignalingExpanded = false
    @State private var tunnelExpanded = false
    @State private var relayExpanded = false
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

    /// What a host actually has to decide, before any of the fields below mean anything.
    ///
    /// The page had six cards and no answer to "do I need any of this". Most hosts need none of it -
    /// a guest on the same Wi-Fi or on a tailnet just works - and the two optional pieces solve
    /// different problems that are easy to confuse, because both look like "connection settings".
    private var reachCard: some View {
        SettingsCard(title: "How Guests Reach You", uiScale: uiScale) {
            Group {
                HStack(spacing: 10 * uiScale) {
                    SettingsActionButton(title: "HELP ME SET THIS UP", uiScale: uiScale) {
                        showingSetupWizard = true
                    }
                    Text("Answers two questions about where your guests will be and configures what that implies. Start here if you are not sure which of the below you need.")
                        .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                        .foregroundStyle(.white.opacity(0.54))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                SettingsDivider(uiScale: uiScale)

                // A tunnel and Hosted Signaling can both be configured at once - one as the everyday
                // path, one as a fallback for a network the other cannot cross - and only one of them
                // actually addresses a new invite. Without this line that choice was invisible: turning
                // both on looked like "more coverage" when it was really "one of these is doing
                // nothing right now."
                SettingsInfoRow(label: "Invites Currently Use", value: activeReachRouteSummary, uiScale: uiScale)

                SettingsDivider(uiScale: uiScale)

                VStack(alignment: .leading, spacing: 8 * uiScale) {
                    Text("Two separate things have to work. A guest has to reach this Mac to join at all, and video has to flow to them once they have. Where your guest is decides whether you need to set anything up.")
                    HStack(alignment: .top, spacing: 8 * uiScale) {
                        reachGlossary(term: "Tunnel", meaning: "Gives this Mac a public web address, so a guest anywhere can open the invite link. Without one, invites only work on your own network or over a VPN.")
                        reachGlossary(term: "Relay", meaning: "Carries the video when a guest's network blocks a direct connection, as school, library and cafe networks do. Without one, those guests never connect.")
                    }
                    reachGlossary(term: "Hosted Signaling", meaning: "Covers the case a tunnel cannot: this Mac itself unreachable, on carrier-grade NAT or a cafe network. Both sides connect outward to a channel instead - but only to let a guest join. It does not carry video; a guest whose network blocks a direct connection still needs a relay. Optional, and only used by a guest whose invite needs it.")
                }
                .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

                SettingsDivider(uiScale: uiScale)

                ForEach(Array(reachRoutes.enumerated()), id: \.offset) { index, route in
                    if index > 0 { SettingsDivider(uiScale: uiScale) }
                    HStack(alignment: .top, spacing: 12 * uiScale) {
                        VStack(alignment: .leading, spacing: 4 * uiScale) {
                            Text(route.situation)
                                .font(.settingsNvidia(size: 14 * uiScale, weight: .bold))
                                .foregroundStyle(.white)
                            Text(route.requirement)
                                .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                                .foregroundStyle(.white.opacity(0.58))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8 * uiScale)
                        Text(route.status)
                            .font(.settingsNvidia(size: 11 * uiScale, weight: .bold))
                            .tracking(0.6)
                            .foregroundStyle(route.ready ? OpenNOWDesign.accent : .white.opacity(0.45))
                            .fixedSize()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Configured is not the same as working, and only the relay can tell the difference: it is the
    /// one piece with a real test behind it. Reporting READY over a failed test would overclaim in
    /// exactly the case this row exists to warn about.
    private func relayStatusText(hasRelay: Bool, isReachable: Bool) -> String {
        guard hasRelay else { return "NEEDS RELAY" }
        if relayTestOutcome == false { return "RELAY FAILED" }
        guard isReachable else { return "NEEDS TUNNEL OR SIGNALING" }
        return relayTestOutcome == true ? "TESTED" : "READY"
    }

    private func relayRequirementText(hasRelay: Bool) -> String {
        guard hasRelay else { return "Needs a relay as well as a tunnel or Hosted Signaling. These networks filter the traffic video travels on." }
        switch relayTestOutcome {
        case false: return "Relay credentials are configured but the last test failed, so these guests will still not connect. See the Relay card."
        case true: return "Tested: the relay allocated, so a guest whose network blocks direct connections still connects."
        case nil: return "Relay credentials are configured. Press Test Relay below to confirm they work before relying on them."
        }
    }

    private func reachGlossary(term: String, meaning: String) -> some View {
        VStack(alignment: .leading, spacing: 3 * uiScale) {
            Text(term.uppercased())
                .font(.settingsNvidia(size: 11 * uiScale, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(OpenNOWDesign.accent)
            Text(meaning)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Mirrors the precedence `startRemoteCoOpInvite` actually applies: a tunnel wins whenever one is
    /// configured, and Hosted Signaling is only reached for as a fallback when there is none. Restated
    /// here rather than read off a shared source of truth because the decision is a single `?:` at the
    /// call site, not a value either side can hand this view - but if that precedence ever changes,
    /// this line has to change with it or it starts lying.
    private var activeReachRouteSummary: String {
        if viewModel.remoteCoOpPreferences.effectivePublicAddress != nil { return "Tunnel" }
        if viewModel.remoteCoOpAblyKey.isUsable { return "Hosted Signaling (fallback - no tunnel set)" }
        return "Local network only"
    }

    private struct ReachRoute {
        let situation: String
        let requirement: String
        let ready: Bool
        let status: String
    }

    private var reachRoutes: [ReachRoute] {
        let hasTunnel = viewModel.remoteCoOpPreferences.effectivePublicAddress != nil
        let hasHostedSignaling = viewModel.remoteCoOpAblyKey.isUsable
        // Either gets an invite link to resolve at all. They are not the same guarantee: a tunnel
        // also carries media directly when nothing else blocks it, while Hosted Signaling only ever
        // gets a guest in the door - see the relay row below for what still has to be true after that.
        let isReachable = hasTunnel || hasHostedSignaling
        let hasRelay = relayCredentials.canRelay
        return [
            ReachRoute(
                situation: "On your network",
                requirement: "Nothing to set up. The guest picks this Mac from their list, or opens the invite link.",
                ready: true,
                status: "READY"
            ),
            ReachRoute(
                situation: "Over Tailscale or a VPN",
                requirement: "The only option that covers both halves at once: the guest reaches this Mac by tailnet address, and Tailscale's own relay carries the traffic when a direct connection fails. Nothing to set up here - the guest installs Tailscale instead.",
                ready: true,
                status: "READY"
            ),
            ReachRoute(
                situation: "Anywhere, in a browser",
                requirement: anywhereRequirementText(hasTunnel: hasTunnel, hasHostedSignaling: hasHostedSignaling),
                ready: isReachable,
                status: isReachable ? "READY" : "NEEDS TUNNEL OR SIGNALING"
            ),
            ReachRoute(
                situation: "On a school, library or cafe network",
                requirement: relayRequirementText(hasRelay: hasRelay),
                ready: hasRelay && isReachable && relayTestOutcome != false,
                status: relayStatusText(hasRelay: hasRelay, isReachable: isReachable)
            ),
        ]
    }

    /// A tunnel and Hosted Signaling both get an invite to resolve, but a host who has only set up
    /// Hosted Signaling needs to know that reaching a guest is not the same as their video working -
    /// the exact gap that reads as "READY" and then fails at the relay step otherwise.
    private func anywhereRequirementText(hasTunnel: Bool, hasHostedSignaling: Bool) -> String {
        if hasTunnel { return "Invites point at your tunnel, so a guest needs nothing installed." }
        if hasHostedSignaling { return "Invites route through Hosted Signaling, so a guest needs nothing installed - but that only gets them in the door. If their network blocks a direct connection, video still needs a relay. See the row below." }
        return "Needs a tunnel or Hosted Signaling. Without either, an invite link only resolves on your own network."
    }

    /// Relay credentials for guests whose network refuses a direct connection.
    ///
    /// Separate from the tunnel card because the two solve different halves: a tunnel makes
    /// *signaling* reachable, a relay makes *media* reachable, and a guest behind a filtering
    /// firewall needs both.
    ///
    /// Only the API token is asked for. Cloudflare needs three values, but two of them are derivable
    /// from the first, and making a host copy a key ID and a separate TURN token out of a dashboard is
    /// where a setup like this gets abandoned.
    private var relayCard: some View {
        SettingsCollapsibleCard(title: "Relay (Optional)", statusSummary: relaySummary, isConfigured: relayCredentials.canRelay, uiScale: uiScale, isExpanded: $relayExpanded) {
            Group {
                Text("Carries a guest's video when their network blocks a direct connection, as school, library and cafe networks do. Runs on Cloudflare, free for 1,000 GB a month, and only the guests who need it use any of that - everyone else still connects directly.")
                    .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                SettingsDivider(uiScale: uiScale)
                SettingsInfoRow(label: "Status", value: relaySummary, uiScale: uiScale)
                SettingsDivider(uiScale: uiScale)
                SettingsOptionRow(
                    title: "Provider",
                    subtitle: relayCredentials.provider.summary,
                    options: OPNRemoteCoOpRelayProvider.allCases.map(\.label),
                    selectedIndex: OPNRemoteCoOpRelayProvider.allCases.firstIndex(of: relayCredentials.provider) ?? 0,
                    uiScale: uiScale,
                    action: viewModel.setRemoteCoOpRelayProviderIndex
                )
                Text(OPNRemoteCoOpRelayProvider.pickerFootnote)
                    .font(.settingsNvidia(size: 11 * uiScale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.44))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if relayCredentials.provider == .staticCredentials { staticRelayRows }
                if relayCredentials.provider == .sharedSecret { sharedSecretRelayRows }
                if relayCredentials.provider == .cloudflare { cloudflareRelayRows }
                if relayCredentials.provider != .none { relayTestRow }
            }
        }
    }

    /// Any provider that hands out a username and a password, which is most of them.
    private var staticRelayRows: some View {
        Group {
            SettingsDivider(uiScale: uiScale)
            SettingsTextFieldRow(
                title: "TURN URLs",
                subtitle: relayURLHint(relayCredentials.staticRelay.urls.count),
                text: relayCredentials.staticRelay.urlText,
                placeholder: "turns:relay.example.com:443?transport=tcp",
                uiScale: uiScale,
                action: viewModel.setRemoteCoOpStaticRelayURLs
            )
            SettingsDivider(uiScale: uiScale)
            SettingsTextFieldRow(
                title: "Username",
                subtitle: "From your provider's dashboard.",
                text: relayCredentials.staticRelay.rawUsername,
                placeholder: "Relay username",
                uiScale: uiScale,
                action: viewModel.setRemoteCoOpStaticRelayUsername
            )
            SettingsDivider(uiScale: uiScale)
            SettingsSecureTextFieldRow(
                title: "Password",
                subtitle: relayCredentials.staticRelay.password.isEmpty ? "Stored in your keychain." : "Stored in your keychain. Type a new password to replace it.",
                text: $staticRelayPasswordDraft,
                placeholder: relayCredentials.staticRelay.password.isEmpty ? "Relay password" : "Stored",
                uiScale: uiScale,
                action: viewModel.setRemoteCoOpStaticRelayPassword
            )
            SettingsDivider(uiScale: uiScale)
            Text("ExpressTURN gives 1,000 GB a month with no card - the same allowance as Cloudflare, for far less setup. Metered gives 20 GB, Turnix 10 GB, Xirsys 0.5 GB. Twilio has no free tier. A password here does not expire, so treat it as a real secret: anyone holding it can spend your allowance.\n\nExpressTURN's free tier serves plain TURN on 80 and 443 but reserves turns: for paid plans, so expect Test Relay to report TCP rather than TLS. That still gets through a network blocking UDP; only a firewall inspecting the protocol itself would refuse it.")
                .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// coturn under `--use-auth-secret`, and anything else speaking the TURN REST API.
    private var sharedSecretRelayRows: some View {
        Group {
            SettingsDivider(uiScale: uiScale)
            SettingsTextFieldRow(
                title: "TURN URLs",
                subtitle: relayURLHint(relayCredentials.sharedSecretRelay.urls.count),
                text: relayCredentials.sharedSecretRelay.urlText,
                placeholder: "turns:turn.example.com:443?transport=tcp",
                uiScale: uiScale,
                action: viewModel.setRemoteCoOpSharedSecretRelayURLs
            )
            SettingsDivider(uiScale: uiScale)
            SettingsSecureTextFieldRow(
                title: "Shared Secret",
                subtitle: relayCredentials.sharedSecretRelay.secret.isEmpty ? "coturn's static-auth-secret. Stored in your keychain." : "Stored in your keychain. Type a new secret to replace it.",
                text: $sharedSecretDraft,
                placeholder: relayCredentials.sharedSecretRelay.secret.isEmpty ? "static-auth-secret" : "Stored",
                uiScale: uiScale,
                action: viewModel.setRemoteCoOpSharedSecretRelaySecret
            )
            SettingsDivider(uiScale: uiScale)
            Text("The best option if you run your own server: credentials are derived here and expire after six hours, so nothing long-lived ever reaches a guest and there is no API to call. Run coturn with --use-auth-secret and --static-auth-secret set to the same value.")
                .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var cloudflareRelayRows: some View {
        Group {
            SettingsDivider(uiScale: uiScale)
            HStack(spacing: 10 * uiScale) {
                SettingsActionButton(title: relayCredentials.canRelay ? "RUN SETUP AGAIN" : "GUIDED SETUP", uiScale: uiScale) {
                    showingRelayWizard = true
                }
                    Text("Walks through the Cloudflare side in three steps. The fields below are the same settings, if you would rather fill them in yourself.")
                        .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                        .foregroundStyle(.white.opacity(0.54))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                SettingsDivider(uiScale: uiScale)
                SettingsSecureTextFieldRow(
                    title: "Cloudflare API Token",
                    subtitle: relayCredentials.account.hasToken ? "Stored in your keychain. Type a new token to replace it." : "Stored in your keychain, never in an invite.",
                    text: $turnAPITokenDraft,
                    placeholder: relayCredentials.account.hasToken ? "Stored" : "Paste your Cloudflare API token",
                    uiScale: uiScale,
                    action: viewModel.setRemoteCoOpCloudflareAPIToken
                )
                SettingsDivider(uiScale: uiScale)
                HStack(spacing: 10 * uiScale) {
                    SettingsActionButton(title: viewModel.remoteCoOpTURNSetupInFlight ? "WORKING..." : "SET UP RELAY", uiScale: uiScale) {
                        viewModel.setUpRemoteCoOpRelay()
                    }
                    .disabled(viewModel.remoteCoOpTURNSetupInFlight || !relayCredentials.account.hasToken)
                    if relayCredentials.canRelay {
                        SettingsActionButton(title: "REMOVE", tone: .secondary, uiScale: uiScale) {
                            viewModel.clearRemoteCoOpRelay()
                        }
                    }
                    Text(relaySetupHint)
                        .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                        .foregroundStyle(.white.opacity(0.54))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                SettingsDivider(uiScale: uiScale)
                Text("Or paste a key you made yourself")
                    .font(.settingsNvidia(size: 13 * uiScale, weight: .bold))
                    .foregroundStyle(.white.opacity(0.82))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("If setup is refused, the account is usually not subscribed to Realtime yet. Failing that, Realtime > TURN in the dashboard makes a key in a click and it works exactly the same. Copy both halves it shows you \u{2014} the token is shown once.")
                    .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                SettingsDivider(uiScale: uiScale)
                SettingsTextFieldRow(
                    title: "TURN Key ID",
                    subtitle: "The key's ID, safe to store in the clear.",
                    text: relayCredentials.turnKey.keyID,
                    placeholder: "Created by setup, or paste one",
                    uiScale: uiScale,
                    action: viewModel.setRemoteCoOpTURNKeyID
                )
                SettingsDivider(uiScale: uiScale)
                SettingsSecureTextFieldRow(
                    title: "TURN Key Token",
                    subtitle: relayCredentials.turnKey.keyToken.isEmpty ? "Stored in your keychain, never in an invite." : "Stored in your keychain. Type a new token to replace it.",
                    text: $turnKeyTokenDraft,
                    placeholder: relayCredentials.turnKey.keyToken.isEmpty ? "The key's bearer token" : "Stored",
                    uiScale: uiScale,
                    action: viewModel.setRemoteCoOpTURNKeyToken
                )
                SettingsDivider(uiScale: uiScale)
                SettingsTextFieldRow(
                    title: "Account ID",
                    subtitle: "Detected during setup. Fill it in only if your token lacks Account Settings, or sees several accounts - it is the hex string in your dashboard URL, dash.cloudflare.com/<account id>.",
                    text: relayCredentials.account.accountID,
                    placeholder: "Detected automatically",
                    uiScale: uiScale,
                    action: viewModel.setRemoteCoOpTURNAccountID
                )
                SettingsDivider(uiScale: uiScale)
                SettingsInfoRow(label: "Free Tier Used", value: relayUsageValue, uiScale: uiScale)
                SettingsDivider(uiScale: uiScale)
                VStack(alignment: .leading, spacing: 6 * uiScale) {
                    Text(relayUsageSubtitle)
                    Text("Only guests whose network refuses a direct connection use the relay, and only their stream travels through it. Cloudflare includes 1,000 GB a month \u{2014} roughly 200 hours at 720p60, or 140 at 1080p60 \u{2014} then bills $0.05/GB automatically, with no warning at the threshold.")
                }
                .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
    }

    private var relayCredentials: OPNRemoteCoOpRelayCredentials { viewModel.remoteCoOpRelayCredentials }

    /// Last row of the card: it verifies everything above it, so it reads as a conclusion rather than
    /// as another setting.
    private var relayTestRow: some View {
        Group {
            SettingsDivider(uiScale: uiScale)
            VStack(alignment: .leading, spacing: 8 * uiScale) {
                HStack(spacing: 10 * uiScale) {
                    SettingsActionButton(title: viewModel.remoteCoOpRelayTestInFlight ? "TESTING..." : "TEST RELAY", uiScale: uiScale) {
                        viewModel.testRemoteCoOpRelay()
                    }
                    .disabled(viewModel.remoteCoOpRelayTestInFlight)
                    if let outcome = relayTestOutcome {
                        relayTestTag(outcome)
                    }
                    Spacer(minLength: 0)
                }
                Text(relayTestHint)
                    .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(relayTestHintColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// `nil` while nothing has been run, so an untested relay does not show a red tag it has not
    /// earned - only an actual failed run does.
    private var relayTestOutcome: Bool? {
        guard !viewModel.remoteCoOpRelayTestInFlight, !viewModel.remoteCoOpRelayTestMessage.isEmpty else { return nil }
        return viewModel.remoteCoOpRelayTestPassed
    }

    private func relayTestTag(_ passed: Bool) -> some View {
        Text(passed ? "SUCCESS" : "FAILED")
            .font(.settingsNvidia(size: 11 * uiScale, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(.black)
            .padding(.horizontal, 9 * uiScale)
            .frame(height: 22 * uiScale)
            .background(passed ? OpenNOWDesign.accent : OpenNOWDesign.Semantic.destructive)
    }

    private var relayTestHintColor: Color {
        guard let outcome = relayTestOutcome else { return .white.opacity(0.54) }
        return outcome ? OpenNOWDesign.accent : OpenNOWDesign.Semantic.destructive
    }

    private var relayTestHint: String {
        if !viewModel.remoteCoOpRelayTestMessage.isEmpty { return viewModel.remoteCoOpRelayTestMessage }
        return "Asks the relay for a real allocation. The only way to find out it does not work without waiting for a guest who cannot connect."
    }

    /// Reports what was recognised, because anything without a turn:, turns: or stun: scheme is
    /// dropped when the entry is built - silently, otherwise, and a host would have no way to tell a
    /// rejected URL from a working one until a guest failed to connect.
    private func relayURLHint(_ recognised: Int) -> String {
        let base = "One per line, or comma separated. Prefer a turns: URL on 443 - that is the one a filtering firewall lets through."
        switch recognised {
        case 0: return base + " None recognised yet. A bare host:port works too - the scheme is filled in from the port."
        case 1: return base + " 1 URL recognised."
        default: return base + " \(recognised) URLs recognised."
        }
    }

    private var relaySetupHint: String {
        if !viewModel.remoteCoOpTURNSetupMessage.isEmpty { return viewModel.remoteCoOpTURNSetupMessage }
        if relayCredentials.canRelay { return "Guests who cannot connect directly will use the relay." }
        return "Creates a TURN key named \"OpenNOW Remote Co-Op\" on your account. If Cloudflare refuses, paste a key below instead."
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
    private var relayUsageValue: String {
        viewModel.remoteCoOpTURNUsage?.summary ?? "Unknown"
    }

    private var relayUsageSubtitle: String {
        if !viewModel.remoteCoOpTURNUsageMessage.isEmpty { return viewModel.remoteCoOpTURNUsageMessage }
        guard let usage = viewModel.remoteCoOpTURNUsage else { return "Reads when this tab opens." }
        let hours = usage.remainingHours(atPreset: viewModel.remoteCoOpPreferences.qualityPreset)
        return String(format: "About %.0f more hours at %@, if every guest were relayed. Shared with Cloudflare's SFU, and counted from the first of the month rather than your billing date.", hours, viewModel.remoteCoOpPreferences.qualityPreset.label)
    }

    private var relaySummary: String {
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
