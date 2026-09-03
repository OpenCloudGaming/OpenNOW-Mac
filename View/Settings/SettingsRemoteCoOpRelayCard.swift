//  The Relay card and the provider-specific rows behind it.
//
//  Split from `SettingsRemoteCoOpViews.swift` on the seam the card boundaries already draw: four
//  providers, each with its own credential shape, is the largest single concern on that page and the
//  one a reader is least likely to want while reading the rest of it.
//

import SwiftUI

extension RemoteCoOpSettingsPage {
    /// Relay credentials for guests whose network refuses a direct connection.
    ///
    /// Separate from the tunnel card because the two solve different halves: a tunnel makes
    /// *signaling* reachable, a relay makes *media* reachable, and a guest behind a filtering
    /// firewall needs both.
    ///
    /// Only the API token is asked for. Cloudflare needs three values, but two of them are derivable
    /// from the first, and making a host copy a key ID and a separate TURN token out of a dashboard is
    /// where a setup like this gets abandoned.
    var relayCard: some View {
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
    var staticRelayRows: some View {
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
    var sharedSecretRelayRows: some View {
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

    var cloudflareRelayRows: some View {
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

    var relayCredentials: OPNRemoteCoOpRelayCredentials { viewModel.remoteCoOpRelayCredentials }

    /// Last row of the card: it verifies everything above it, so it reads as a conclusion rather than
    /// as another setting.
    var relayTestRow: some View {
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
    var relayTestOutcome: Bool? {
        guard !viewModel.remoteCoOpRelayTestInFlight, !viewModel.remoteCoOpRelayTestMessage.isEmpty else { return nil }
        return viewModel.remoteCoOpRelayTestPassed
    }

    func relayTestTag(_ passed: Bool) -> some View {
        Text(passed ? "SUCCESS" : "FAILED")
            .font(.settingsNvidia(size: 11 * uiScale, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(.black)
            .padding(.horizontal, 9 * uiScale)
            .frame(height: 22 * uiScale)
            .background(passed ? OpenNOWDesign.accent : OpenNOWDesign.Semantic.destructive)
    }

    var relayTestHintColor: Color {
        guard let outcome = relayTestOutcome else { return .white.opacity(0.54) }
        return outcome ? OpenNOWDesign.accent : OpenNOWDesign.Semantic.destructive
    }

    var relayTestHint: String {
        if !viewModel.remoteCoOpRelayTestMessage.isEmpty { return viewModel.remoteCoOpRelayTestMessage }
        return "Asks the relay for a real allocation. The only way to find out it does not work without waiting for a guest who cannot connect."
    }

    /// Reports what was recognised, because anything without a turn:, turns: or stun: scheme is
    /// dropped when the entry is built - silently, otherwise, and a host would have no way to tell a
    /// rejected URL from a working one until a guest failed to connect.
    func relayURLHint(_ recognised: Int) -> String {
        let base = "One per line, or comma separated. Prefer a turns: URL on 443 - that is the one a filtering firewall lets through."
        switch recognised {
        case 0: return base + " None recognised yet. A bare host:port works too - the scheme is filled in from the port."
        case 1: return base + " 1 URL recognised."
        default: return base + " \(recognised) URLs recognised."
        }
    }

    var relaySetupHint: String {
        if !viewModel.remoteCoOpTURNSetupMessage.isEmpty { return viewModel.remoteCoOpTURNSetupMessage }
        if relayCredentials.canRelay { return "Guests who cannot connect directly will use the relay." }
        return "Creates a TURN key named \"OpenNOW Remote Co-Op\" on your account. If Cloudflare refuses, paste a key below instead."
    }
}
