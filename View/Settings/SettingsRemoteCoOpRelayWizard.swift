//
//  SettingsRemoteCoOpRelayWizard.swift
//  OpenNOW
//
//  Guided setup for the Cloudflare relay.
//
//  The relay is the one part of Remote Co-Op whose setup happens somewhere else. Three things have to
//  be true on Cloudflare's side before a single field here does anything, and each of them fails in a
//  way that looks like one of the others: an unsubscribed account and a token missing a permission
//  both come back as "Authorization Failure", so a host with a perfectly good token spends their time
//  auditing checkboxes.
//
//  A wizard suits that because the work is genuinely sequential and mostly external. The settings card
//  stays the place to inspect and change what was configured - this is only the path in.
//

import SwiftUI

struct RemoteCoOpRelayWizard: View {
    /// Resolved once rather than force-unwrapped at each use: a literal that fails to parse should
    /// cost the row that links to it, not the whole Settings tab.
    private static let cloudflareRealtimeURL = URL(string: "https://dash.cloudflare.com/?to=/:account/realtime")
    private static let cloudflareAPITokensURL = URL(string: "https://dash.cloudflare.com/profile/api-tokens")

    let viewModel: CatalogViewModel
    let uiScale: CGFloat
    let dismiss: () -> Void

    @State private var stepIndex = 0
    @State private var apiTokenDraft = ""
    @State private var keyIDDraft = ""
    @State private var keyTokenDraft = ""
    @State private var showingManualKey = false

    private enum Step: Int, CaseIterable {
        case subscribe
        case token
        case finish

        var title: String {
            switch self {
            case .subscribe: "Subscribe to Realtime"
            case .token: "Create an API token"
            case .finish: "Connect it"
            }
        }
    }

    private var step: Step { Step(rawValue: stepIndex) ?? .subscribe }
    private var credentials: OPNRemoteCoOpRelayCredentials { viewModel.remoteCoOpRelayCredentials }

    var body: some View {
        VStack(alignment: .leading, spacing: 18 * uiScale) {
            header
            progress
            Divider().overlay(Color.white.opacity(0.12))
            ScrollView { stepBody.padding(.trailing, 4 * uiScale) }
                .frame(maxHeight: 360 * uiScale)
            Divider().overlay(Color.white.opacity(0.12))
            footer
        }
        .padding(24 * uiScale)
        .frame(width: 560 * uiScale, alignment: .leading)
        .background(Color(red: 24 / 255, green: 24 / 255, blue: 24 / 255))
        .overlay { Rectangle().stroke(Color.white.opacity(0.16), lineWidth: 1) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6 * uiScale) {
            Text("Set Up Relay")
                .font(.settingsNvidia(size: 19 * uiScale, weight: .bold))
                .foregroundStyle(.white)
            Text("A relay lets guests play from networks that block direct connections - schools, libraries, cafes. It is free for 1,000 GB a month, and only guests who actually need it use any of that.")
                .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var progress: some View {
        HStack(spacing: 8 * uiScale) {
            ForEach(Step.allCases, id: \.rawValue) { entry in
                HStack(spacing: 6 * uiScale) {
                    Text("\(entry.rawValue + 1)")
                        .font(.settingsNvidia(size: 11 * uiScale, weight: .bold))
                        .foregroundStyle(entry.rawValue <= stepIndex ? .black : .white.opacity(0.5))
                        .frame(width: 18 * uiScale, height: 18 * uiScale)
                        .background(entry.rawValue <= stepIndex ? OpenNOWDesign.accent : Color.white.opacity(0.1))
                    Text(entry.title)
                        .font(.settingsNvidia(size: 11 * uiScale, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(entry.rawValue == stepIndex ? .white : .white.opacity(0.42))
                }
                if entry != .finish {
                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                        .frame(height: 1)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private var stepBody: some View {
        switch step {
        case .subscribe: subscribeStep
        case .token: tokenStep
        case .finish: finishStep
        }
    }

    private var subscribeStep: some View {
        VStack(alignment: .leading, spacing: 12 * uiScale) {
            bullet("Open Cloudflare and subscribe to Realtime. The checkout total is $0.00 - 1,000 GB a month is included.")
            bullet("It does ask for a card. Usage past the allowance is billed at $0.05/GB automatically, with no warning at the threshold, which is why the card here shows what you have used.")
            // Leading with this because it is the failure that reads as something else entirely:
            // Cloudflare answers an unsubscribed account with the same wording as a bad token.
            callout("Skipping this is the usual reason setup fails later. Cloudflare reports an unsubscribed account as an authorization failure, which looks exactly like a token problem.")
            if let url = Self.cloudflareRealtimeURL {
                Link("Open Cloudflare Realtime", destination: url)
                    .font(.settingsNvidia(size: 12 * uiScale, weight: .bold))
            }
            Text("Prefer not to put a card down? Tailscale covers the same blocked-network case for free, with no Cloudflare account at all - each guest just installs it and joins your tailnet. Close this and see the README.")
                .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tokenStep: some View {
        VStack(alignment: .leading, spacing: 12 * uiScale) {
            bullet("On the API tokens page, choose Create Custom Token.")
            bullet("Add three account permissions:")
            VStack(alignment: .leading, spacing: 5 * uiScale) {
                permissionRow("Cloudflare Calls", "Edit", "Creates the key and mints credentials. Required.")
                permissionRow("Account Settings", "Read", "Lets setup find your account ID.")
                permissionRow("Account Analytics", "Read", "Reads how much of the free tier you have used.")
            }
            .padding(.leading, 14 * uiScale)
            bullet("Set Account Resources to Include, and pick your account.")
            callout("Newer accounts list Cloudflare Calls as Cloudflare Realtime. Same permission, renamed.")
            if let url = Self.cloudflareAPITokensURL {
                Link("Open the API token page", destination: url)
                    .font(.settingsNvidia(size: 12 * uiScale, weight: .bold))
            }
        }
    }

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 12 * uiScale) {
            Text("Paste the token Cloudflare showed you. OpenNOW finds your account and creates the TURN key itself. The token is stored in your keychain and never travels with an invite.")
                .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)
            wizardField(title: "Cloudflare API Token", text: $apiTokenDraft, secure: true, placeholder: "Paste the token")

            if !viewModel.remoteCoOpTURNSetupMessage.isEmpty {
                Text(viewModel.remoteCoOpTURNSetupMessage)
                    .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(credentials.canRelay ? OpenNOWDesign.accent : .white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The escape hatch, folded away: creating a key over the API is refused often enough that
            // the wizard cannot be a dead end, but leading with it would suggest the normal path fails.
            Button(showingManualKey ? "Hide manual entry" : "Cloudflare refused to create a key?") {
                showingManualKey.toggle()
            }
            .buttonStyle(.plain)
            .font(.settingsNvidia(size: 12 * uiScale, weight: .bold))
            .foregroundStyle(OpenNOWDesign.accent)

            if showingManualKey {
                VStack(alignment: .leading, spacing: 10 * uiScale) {
                    Text("Make one at Realtime > TURN in the dashboard and paste both halves. It works identically; only the making of it differs. Cloudflare shows the token once, at creation.")
                        .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                    wizardField(title: "TURN Key ID", text: $keyIDDraft, secure: false, placeholder: "Key ID")
                    wizardField(title: "TURN Key Token", text: $keyTokenDraft, secure: true, placeholder: "Bearer token")
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10 * uiScale) {
            if credentials.canRelay {
                Text("Relay ready")
                    .font(.settingsNvidia(size: 12 * uiScale, weight: .bold))
                    .foregroundStyle(OpenNOWDesign.accent)
            }
            Spacer(minLength: 0)
            if stepIndex > 0 {
                SettingsDialogButton(title: "BACK", tone: .secondary, uiScale: uiScale) { stepIndex -= 1 }
            }
            SettingsDialogButton(title: step == .finish ? "DONE" : "CANCEL", tone: .secondary, uiScale: uiScale, action: dismiss)
            SettingsDialogButton(title: primaryTitle, tone: .primary, uiScale: uiScale, action: primaryAction)
        }
    }

    private var primaryTitle: String {
        switch step {
        case .subscribe, .token: "NEXT"
        case .finish: viewModel.remoteCoOpTURNSetupInFlight ? "WORKING..." : "SET UP RELAY"
        }
    }

    private func primaryAction() {
        guard step == .finish else {
            stepIndex += 1
            return
        }
        // Whatever the host filled in, in the order that needs the fewest round trips: a pasted key is
        // usable immediately, where a token still has to be exchanged with Cloudflare.
        if !keyIDDraft.isEmpty { viewModel.setRemoteCoOpTURNKeyID(keyIDDraft) }
        if !keyTokenDraft.isEmpty { viewModel.setRemoteCoOpTURNKeyToken(keyTokenDraft) }
        if !apiTokenDraft.isEmpty {
            viewModel.setRemoteCoOpCloudflareAPIToken(apiTokenDraft)
            viewModel.setUpRemoteCoOpRelay()
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7 * uiScale) {
            Text("\u{2022}")
                .font(.settingsNvidia(size: 12 * uiScale, weight: .bold))
                .foregroundStyle(.white.opacity(0.4))
            Text(text)
                .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func permissionRow(_ name: String, _ level: String, _ why: String) -> some View {
        HStack(alignment: .top, spacing: 8 * uiScale) {
            Text(name)
                .font(.settingsNvidia(size: 12 * uiScale, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 132 * uiScale, alignment: .leading)
            Text(level)
                .font(.settingsNvidia(size: 11 * uiScale, weight: .bold))
                .foregroundStyle(.black)
                .padding(.horizontal, 6 * uiScale)
                .background(OpenNOWDesign.accent)
            Text(why)
                .font(.settingsNvidia(size: 11 * uiScale, weight: .medium))
                .foregroundStyle(.white.opacity(0.52))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func callout(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10 * uiScale) {
            Rectangle().fill(OpenNOWDesign.accent).frame(width: 3 * uiScale)
            Text(text)
                .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func wizardField(title: String, text: Binding<String>, secure: Bool, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4 * uiScale) {
            Text(title)
                .font(.settingsNvidia(size: 12 * uiScale, weight: .bold))
                .foregroundStyle(.white.opacity(0.82))
            Group {
                if secure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .textFieldStyle(.plain)
            .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 9 * uiScale)
            .frame(height: 30 * uiScale)
            .background(Color.white.opacity(0.06))
            .overlay { Rectangle().stroke(Color.white.opacity(0.14), lineWidth: 1) }
        }
    }
}
