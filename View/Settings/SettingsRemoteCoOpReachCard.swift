//
//  SettingsRemoteCoOpReachCard.swift
//  OpenNOW
//
//  "How Guests Reach You": the glossary, the per-situation readiness table, and the route an invite
//  will actually take.
//
//  Split from `SettingsRemoteCoOpViews.swift`. This is the card that answers "do I need any of
//  this", which is a different question from the cards that configure it.
//

import SwiftUI

extension RemoteCoOpSettingsPage {
    /// What a host actually has to decide, before any of the fields below mean anything.
    ///
    /// The page had six cards and no answer to "do I need any of this". Most hosts need none of it -
    /// a guest on the same Wi-Fi or on a tailnet just works - and the two optional pieces solve
    /// different problems that are easy to confuse, because both look like "connection settings".
    var reachCard: some View {
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
    func relayStatusText(hasRelay: Bool, isReachable: Bool) -> String {
        guard hasRelay else { return "NEEDS RELAY" }
        if relayTestOutcome == false { return "RELAY FAILED" }
        guard isReachable else { return "NEEDS TUNNEL OR SIGNALING" }
        return relayTestOutcome == true ? "TESTED" : "READY"
    }

    func relayRequirementText(hasRelay: Bool) -> String {
        guard hasRelay else { return "Needs a relay as well as a tunnel or Hosted Signaling. These networks filter the traffic video travels on." }
        switch relayTestOutcome {
        case false: return "Relay credentials are configured but the last test failed, so these guests will still not connect. See the Relay card."
        case true: return "Tested: the relay allocated, so a guest whose network blocks direct connections still connects."
        case nil: return "Relay credentials are configured. Press Test Relay below to confirm they work before relying on them."
        }
    }

    func reachGlossary(term: String, meaning: String) -> some View {
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
    var activeReachRouteSummary: String {
        if viewModel.remoteCoOpPreferences.effectivePublicAddress != nil { return "Tunnel" }
        if viewModel.remoteCoOpAblyKey.isUsable { return "Hosted Signaling (fallback - no tunnel set)" }
        return "Local network only"
    }

    struct ReachRoute {
        let situation: String
        let requirement: String
        let ready: Bool
        let status: String
    }

    var reachRoutes: [ReachRoute] {
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
    func anywhereRequirementText(hasTunnel: Bool, hasHostedSignaling: Bool) -> String {
        if hasTunnel { return "Invites point at your tunnel, so a guest needs nothing installed." }
        if hasHostedSignaling { return "Invites route through Hosted Signaling, so a guest needs nothing installed - but that only gets them in the door. If their network blocks a direct connection, video still needs a relay. See the row below." }
        return "Needs a tunnel or Hosted Signaling. Without either, an invite link only resolves on your own network."
    }
}
