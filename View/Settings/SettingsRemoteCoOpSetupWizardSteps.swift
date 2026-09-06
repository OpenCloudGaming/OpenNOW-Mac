//  The wizard's two conditional configuration steps: how guests are reached, and how their video
//  gets through a filtering network.
//
//  These two are the only steps that write settings rather than asking questions, so they are also
//  the only ones whose contents depend on which provider or route the host picked.
//

import SwiftUI

extension RemoteCoOpSetupWizard {
    // MARK: - Step 3 (conditional): reachability

    /// A host who needs a tunnel has two ways to get one: run a tunnel program, or configure Hosted
    /// Signaling instead. Only one is used per invite - see `startRemoteCoOpInvite` - so the choice is
    /// made here rather than leaving both cards to compete silently later.
    var reachabilityStep: some View {
        VStack(alignment: .leading, spacing: 14 * uiScale) {
            stepHeading("Getting guests in the door")
            VStack(alignment: .leading, spacing: 8 * uiScale) {
                if client == .nativeApp {
                    choiceCard(
                        title: "I Already Have a VPN or Tailscale Running",
                        detail: "Your guest reaches this Mac by tailnet or VPN address. Nothing to configure here.",
                        isSelected: reachabilityChoice == .vpnAlreadyRunning
                    ) { reachabilityChoice = .vpnAlreadyRunning }
                }
                choiceCard(
                    title: "Run a Tunnel",
                    detail: "cloudflared, ngrok, or Tailscale Funnel. You run it, paste the address it prints.",
                    isSelected: reachabilityChoice == .tunnel
                ) { reachabilityChoice = .tunnel }
                choiceCard(
                    title: "Hosted Signaling",
                    detail: "Nothing to run. Paste an Ably API key instead - free tier covers a normal session many times over.",
                    isSelected: reachabilityChoice == .hostedSignaling
                ) { reachabilityChoice = .hostedSignaling }
            }

            switch reachabilityChoice {
            case .tunnel: tunnelFields
            case .hostedSignaling: hostedSignalingFields
            case .vpnAlreadyRunning:
                Text("Transport will be set to Direct - a VPN or tailnet route already reaches this Mac, so STUN would only reveal your public address for nothing.")
                    .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.54))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var tunnelFields: some View {
        VStack(alignment: .leading, spacing: 10 * uiScale) {
            SettingsTextFieldRow(
                title: "Public Address",
                subtitle: "HTTPS address a tunnel exposes this Mac on.",
                text: viewModel.remoteCoOpPreferences.publicAddress,
                placeholder: "https://your-tunnel.example",
                uiScale: uiScale,
                action: viewModel.setRemoteCoOpPublicAddress
            )
            Text(RemoteCoOpSettingsPage.tunnelExampleCommands)
                .font(.system(size: 11 * uiScale, design: .monospaced))
                .foregroundStyle(.white.opacity(0.72))
                .textSelection(.enabled)
                .padding(10 * uiScale)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.05))
                .overlay { Rectangle().stroke(Color.white.opacity(0.12), lineWidth: 1) }
        }
        .padding(.top, 2 * uiScale)
    }

    var hostedSignalingFields: some View {
        VStack(alignment: .leading, spacing: 10 * uiScale) {
            SettingsSecureTextFieldRow(
                title: "Ably API Key",
                subtitle: viewModel.remoteCoOpAblyKey.isUsable ? "Stored in your keychain. Type a new key to replace it." : "Stored in your keychain, never in an invite.",
                text: $ablyKeyDraft,
                placeholder: viewModel.remoteCoOpAblyKey.isUsable ? "Stored" : "APP_ID.KEY_ID:SECRET",
                uiScale: uiScale,
                action: viewModel.setRemoteCoOpAblyKey
            )
            if !viewModel.remoteCoOpAblyKeyMessage.isEmpty {
                Text(viewModel.remoteCoOpAblyKeyMessage)
                    .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(viewModel.remoteCoOpAblyKey.isUsable ? OpenNOWDesign.accent : OpenNOWDesign.Semantic.destructive)
            }
            if viewModel.remoteCoOpAblyKey.isUsable {
                SettingsTextFieldRow(
                    title: "Static Guest Page (Optional)",
                    subtitle: "A copy of the guest page hosted somewhere reachable without this Mac being reachable at all.",
                    text: viewModel.remoteCoOpPreferences.hostedGuestPageURL,
                    placeholder: "https://your-account.github.io/opennow-remote-coop/",
                    uiScale: uiScale,
                    action: viewModel.setRemoteCoOpHostedGuestPageURL
                )
            }
        }
        .padding(.top, 2 * uiScale)
    }

    // MARK: - Step 4 (conditional): relay

    var relayStep: some View {
        VStack(alignment: .leading, spacing: 14 * uiScale) {
            stepHeading("Getting video through a filtering network")
            VStack(alignment: .leading, spacing: 8 * uiScale) {
                ForEach(Array(OPNRemoteCoOpRelayProvider.allCases.enumerated()), id: \.offset) { index, provider in
                    choiceCard(
                        title: provider.label,
                        detail: provider.summary,
                        isSelected: provider == relayCredentials.provider
                    ) { viewModel.setRemoteCoOpRelayProviderIndex(index) }
                }
            }
            switch relayCredentials.provider {
            case .none:
                Text("Pick a provider above to continue - the relay is what carries video when a guest's network refuses a direct connection.")
                    .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.54))
                    .fixedSize(horizontal: false, vertical: true)
            case .cloudflare:
                VStack(alignment: .leading, spacing: 8 * uiScale) {
                    Text(relayCredentials.canRelay ? "Cloudflare relay configured." : "Free tier: 1,000 GB a month. The guided setup handles the Cloudflare side in three steps.")
                        .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                        .fixedSize(horizontal: false, vertical: true)
                    SettingsActionButton(title: relayCredentials.canRelay ? "RUN SETUP AGAIN" : "GUIDED SETUP", uiScale: uiScale) {
                        openRelaySetup()
                    }
                }
            case .staticCredentials:
                staticRelayFields
            case .sharedSecret:
                sharedSecretRelayFields
            }
        }
    }

    var staticRelayFields: some View {
        VStack(alignment: .leading, spacing: 10 * uiScale) {
            SettingsTextFieldRow(
                title: "TURN URLs",
                subtitle: "One per line, or comma separated. Prefer a turns: URL on 443.",
                text: relayCredentials.staticRelay.urlText,
                placeholder: "turns:relay.example.com:443?transport=tcp",
                uiScale: uiScale,
                action: viewModel.setRemoteCoOpStaticRelayURLs
            )
            SettingsTextFieldRow(
                title: "Username",
                subtitle: "From your provider's dashboard.",
                text: relayCredentials.staticRelay.rawUsername,
                placeholder: "Relay username",
                uiScale: uiScale,
                action: viewModel.setRemoteCoOpStaticRelayUsername
            )
            SettingsSecureTextFieldRow(
                title: "Password",
                subtitle: relayCredentials.staticRelay.password.isEmpty ? "Stored in your keychain." : "Stored in your keychain. Type a new password to replace it.",
                text: $staticRelayPasswordDraft,
                placeholder: relayCredentials.staticRelay.password.isEmpty ? "Relay password" : "Stored",
                uiScale: uiScale,
                action: viewModel.setRemoteCoOpStaticRelayPassword
            )
            Text("ExpressTURN gives 1,000 GB a month with no card.")
                .font(.settingsFont(size: 11 * uiScale, weight: .medium))
                .foregroundStyle(.white.opacity(0.44))
        }
    }

    var sharedSecretRelayFields: some View {
        VStack(alignment: .leading, spacing: 10 * uiScale) {
            SettingsTextFieldRow(
                title: "TURN URLs",
                subtitle: "One per line, or comma separated.",
                text: relayCredentials.sharedSecretRelay.urlText,
                placeholder: "turns:turn.example.com:443?transport=tcp",
                uiScale: uiScale,
                action: viewModel.setRemoteCoOpSharedSecretRelayURLs
            )
            SettingsSecureTextFieldRow(
                title: "Shared Secret",
                subtitle: relayCredentials.sharedSecretRelay.secret.isEmpty ? "coturn's static-auth-secret. Stored in your keychain." : "Stored in your keychain. Type a new secret to replace it.",
                text: $sharedSecretDraft,
                placeholder: relayCredentials.sharedSecretRelay.secret.isEmpty ? "static-auth-secret" : "Stored",
                uiScale: uiScale,
                action: viewModel.setRemoteCoOpSharedSecretRelaySecret
            )
        }
    }
}
