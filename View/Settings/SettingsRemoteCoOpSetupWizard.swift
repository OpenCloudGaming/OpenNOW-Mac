//  Asks a host where their guests will be, and configures what that implies.
//
//  The settings page presents a transport mode, a tunnel, Hosted Signaling and a relay and expects the
//  host to know which they need. This asks the two questions they can actually answer, works backwards
//  to what is required, and then lets them configure exactly that - inline, one step at a time, rather
//  than sending them back to a page of cards to find the right one themselves.
//
//  One step per screen rather than one long scroll: a host answering "restricted network" used to see
//  every question, the full advice paragraph and every relay field at once. Paginating means each
//  screen only ever shows what that step needs.
//

import SwiftUI

struct RemoteCoOpSetupWizard: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat
    let openRelaySetup: () -> Void
    let dismiss: () -> Void

    private enum Step: Equatable {
        case location
        case client
        case reachability
        case relay
        case summary
    }

    enum ReachabilityChoice {
        case tunnel
        case hostedSignaling
        /// Declared by the host, not detected: a VPN this app cannot see (anything but Tailscale) is
        /// otherwise indistinguishable from no route at all. Only offered for a native guest - a
        /// browser meets a self-signed certificate over a bare tailnet or VPN address, which is the
        /// same reason a tunnel's own advice never recommends this to a browser guest either.
        case vpnAlreadyRunning
    }

    @State private var location: OPNRemoteCoOpGuestLocation?
    @State var client: OPNRemoteCoOpGuestClient?
    @State private var stepIndex = 0
    @State private var applied = false
    @State var reachabilityChoice: ReachabilityChoice = .tunnel
    @State var ablyKeyDraft = ""
    @State var staticRelayPasswordDraft = ""
    @State var sharedSecretDraft = ""

    private var tailscaleDetected: Bool { OPNRemoteCoOpLocalAddress.tailscaleIPv4() != nil }
    var hasTunnel: Bool { viewModel.remoteCoOpPreferences.effectivePublicAddress != nil }
    var hasHostedSignaling: Bool { viewModel.remoteCoOpAblyKey.isUsable }
    var hasRelay: Bool { relayCredentials.canRelay }
    var relayCredentials: OPNRemoteCoOpRelayCredentials { viewModel.remoteCoOpRelayCredentials }

    private var advice: OPNRemoteCoOpSetupAdvice? {
        guard let location else { return nil }
        return OPNRemoteCoOpSetupAdvisor.advise(
            location: location,
            client: client ?? .unsure,
            tailscaleDetected: tailscaleDetected
        )
    }

    /// Only the steps the current answers actually call for - a host on their own network never sees
    /// a reachability or relay step at all.
    private var steps: [Step] {
        var steps: [Step] = [.location, .client]
        guard let advice, client != nil else { return steps }
        if advice.needsTunnel { steps.append(.reachability) }
        if advice.needsRelay { steps.append(.relay) }
        steps.append(.summary)
        return steps
    }

    private var currentStep: Step {
        steps[min(stepIndex, steps.count - 1)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16 * uiScale) {
            VStack(alignment: .leading, spacing: 6 * uiScale) {
                HStack(spacing: 8 * uiScale) {
                    Text("Remote Co-Op Setup")
                        .font(.settingsNvidia(size: 19 * uiScale, weight: .bold))
                        .foregroundStyle(.white)
                    Spacer(minLength: 0)
                    Text("STEP \(stepIndex + 1) OF \(steps.count)")
                        .font(.settingsNvidia(size: 11 * uiScale, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(.white.opacity(0.4))
                }
                Text("Nothing here is permanent - every setting it touches stays editable afterwards from the cards below.")
                    .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().overlay(Color.white.opacity(0.12))

            Group {
                switch currentStep {
                case .location: locationStep
                case .client: clientStep
                case .reachability: reachabilityStep
                case .relay: relayStep
                case .summary: summaryStep
                }
            }
            .frame(maxWidth: .infinity, minHeight: 260 * uiScale, alignment: .topLeading)

            Divider().overlay(Color.white.opacity(0.12))

            HStack(spacing: 10 * uiScale) {
                if tailscaleDetected {
                    Text("Tailscale detected on this Mac")
                        .font(.settingsNvidia(size: 11 * uiScale, weight: .bold))
                        .foregroundStyle(OpenNOWDesign.accent)
                }
                Spacer(minLength: 0)
                SettingsDialogButton(title: "CLOSE", tone: .secondary, uiScale: uiScale, action: dismiss)
                if stepIndex > 0 {
                    SettingsDialogButton(title: "BACK", tone: .secondary, uiScale: uiScale) { stepIndex -= 1 }
                }
                // Always exactly one trailing button, in the same rightmost slot, on every step -
                // NEXT, then APPLY, then DONE. Dropping it entirely once applied is what let BACK
                // slide into the primary button's position and read as the highlighted action.
                switch (currentStep, applied) {
                case (.summary, true):
                    SettingsDialogButton(title: "DONE", tone: .primary, uiScale: uiScale, action: dismiss)
                case (.summary, false):
                    if let advice {
                        SettingsDialogButton(title: "APPLY", tone: .primary, uiScale: uiScale) { apply(advice) }
                    }
                default:
                    SettingsDialogButton(title: "NEXT", tone: .primary, uiScale: uiScale) {
                        stepIndex = min(stepIndex + 1, steps.count - 1)
                    }
                    .disabled(!canAdvance)
                }
            }
        }
        .padding(24 * uiScale)
        .frame(width: 580 * uiScale, alignment: .leading)
        .background(Color(red: 24 / 255, green: 24 / 255, blue: 24 / 255))
        .overlay { Rectangle().stroke(Color.white.opacity(0.16), lineWidth: 1) }
        .onAppear {
            reachabilityChoice = hasTunnel ? .tunnel : (hasHostedSignaling ? .hostedSignaling : .tunnel)
        }
        .onChange(of: currentStep) { _, _ in
            // Advancing into a step can only make it *shorter* than what was already answered - going
            // back to change location or client must not leave the index pointing past a step that no
            // longer exists.
            stepIndex = min(stepIndex, steps.count - 1)
        }
    }

    private var canAdvance: Bool {
        switch currentStep {
        case .location: return location != nil
        case .client: return client != nil
        case .reachability, .relay: return true
        case .summary: return false
        }
    }

    // MARK: - Step 1: location

    private var locationStep: some View {
        question(
            number: 1,
            title: "Where will your guests be?",
            options: OPNRemoteCoOpGuestLocation.allCases.map { ($0.label, $0.detail, $0 == location) },
            select: { location = OPNRemoteCoOpGuestLocation.allCases[$0]; applied = false }
        )
    }

    // MARK: - Step 2: client

    var clientStep: some View {
        question(
            number: 2,
            title: "What will they play in?",
            options: OPNRemoteCoOpGuestClient.allCases.map { ($0.label, $0.detail, $0 == client) },
            select: { client = OPNRemoteCoOpGuestClient.allCases[$0]; applied = false }
        )
    }

    // MARK: - Final step: summary

    private var summaryStep: some View {
        guard let advice else { return AnyView(EmptyView()) }
        // Three ways to satisfy reachability, and `hasTunnel` alone only sees one of them: a declared
        // VPN/tailnet route and a configured Hosted Signaling key are real too, just not visible in
        // the Public Address field this checks by default. This is the same reachability-precedence
        // fact the main Settings page's reach summary already tracks - the wizard has to agree with it.
        let reachabilityIsSatisfied = hasTunnel
            || reachabilityChoice == .vpnAlreadyRunning
            || (reachabilityChoice == .hostedSignaling && hasHostedSignaling)
        let outstanding = OPNRemoteCoOpSetupAdvisor.outstandingSteps(
            for: advice,
            hasTunnel: reachabilityIsSatisfied,
            hasRelay: hasRelay
        )
        return AnyView(
            VStack(alignment: .leading, spacing: 10 * uiScale) {
                HStack(spacing: 7 * uiScale) {
                    Text("\u{2713}")
                        .font(.settingsNvidia(size: 11 * uiScale, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 18 * uiScale, height: 18 * uiScale)
                        .background(OpenNOWDesign.accent)
                    Text(advice.headline)
                        .font(.settingsNvidia(size: 15 * uiScale, weight: .bold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 5 * uiScale) {
                    ForEach(Array(advice.reasons.enumerated()), id: \.offset) { _, reason in
                        HStack(alignment: .top, spacing: 7 * uiScale) {
                            Text("\u{2022}")
                                .foregroundStyle(.white.opacity(0.35))
                            Text(reason)
                                .foregroundStyle(.white.opacity(0.68))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                    }
                }

                if applied {
                    Text("Transport set to \(advice.transportMode.label).")
                        .font(.settingsNvidia(size: 12 * uiScale, weight: .bold))
                        .foregroundStyle(OpenNOWDesign.accent)
                } else if outstanding.isEmpty {
                    Text(advice.needsNothing
                         ? "Nothing else to do - press Apply to set the transport mode."
                         : "Everything this needs is already configured - press Apply to set the transport mode.")
                        .font(.settingsNvidia(size: 12 * uiScale, weight: .bold))
                        .foregroundStyle(OpenNOWDesign.accent)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 7 * uiScale) {
                        Text("Still to finish")
                            .font(.settingsNvidia(size: 12 * uiScale, weight: .bold))
                            .foregroundStyle(.white.opacity(0.82))
                        ForEach(Array(outstanding.enumerated()), id: \.offset) { _, todo in
                            Text("\u{2022} " + todo)
                                .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                                .foregroundStyle(.white.opacity(0.62))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(11 * uiScale)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.04))
                    .overlay { Rectangle().stroke(Color.white.opacity(0.09), lineWidth: 1) }
                }
            }
            .padding(.top, 4 * uiScale)
        )
    }

    private func apply(_ advice: OPNRemoteCoOpSetupAdvice) {
        // Only the transport mode is applied automatically here - everything a step could configure,
        // it already did directly, live, the moment the host typed it.
        //
        // A declared VPN/tailnet route overrides what the advisor recommended: it picked `.automatic`
        // assuming a tunnel, but a route that already exists needs no STUN, and offering it would only
        // reveal this Mac's public address for nothing - the same reasoning `.sameNetwork` already
        // gets for free.
        let effectiveTransportMode = (advice.needsTunnel && reachabilityChoice == .vpnAlreadyRunning)
            ? .directOnly
            : advice.transportMode
        if let index = OPNRemoteCoOpTransportMode.allCases.firstIndex(of: effectiveTransportMode) {
            viewModel.setRemoteCoOpTransportModeIndex(index)
        }
        if !viewModel.remoteCoOpPreferences.isEnabled {
            viewModel.setRemoteCoOpEnabled(true)
        }
        applied = true
    }

    // MARK: - Shared step chrome

    func stepHeading(_ title: String) -> some View {
        Text(title)
            .font(.settingsNvidia(size: 15 * uiScale, weight: .bold))
            .foregroundStyle(.white)
    }

    func choiceCard(title: String, detail: String, isSelected: Bool, select: @escaping () -> Void) -> some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 4 * uiScale) {
                Text(title)
                    .font(.settingsNvidia(size: 13 * uiScale, weight: .bold))
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.78))
                Text(detail)
                    .font(.settingsNvidia(size: 11 * uiScale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10 * uiScale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.white.opacity(0.07) : Color.white.opacity(0.025))
            .overlay { Rectangle().stroke(isSelected ? OpenNOWDesign.accent.opacity(0.5) : Color.white.opacity(0.08), lineWidth: 1) }
        }
        .buttonStyle(.plain)
    }

    private func question(number: Int,
                          title: String,
                          options: [(String, String, Bool)],
                          select: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8 * uiScale) {
            HStack(spacing: 7 * uiScale) {
                Text("\(number)")
                    .font(.settingsNvidia(size: 11 * uiScale, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 18 * uiScale, height: 18 * uiScale)
                    .background(OpenNOWDesign.accent)
                Text(title)
                    .font(.settingsNvidia(size: 15 * uiScale, weight: .bold))
                    .foregroundStyle(.white)
            }
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                Button { select(index) } label: {
                    HStack(alignment: .top, spacing: 10 * uiScale) {
                        Rectangle()
                            .fill(option.2 ? OpenNOWDesign.accent : Color.white.opacity(0.14))
                            .frame(width: 3 * uiScale)
                        VStack(alignment: .leading, spacing: 2 * uiScale) {
                            Text(option.0)
                                .font(.settingsNvidia(size: 13 * uiScale, weight: .bold))
                                .foregroundStyle(option.2 ? .white : .white.opacity(0.78))
                            Text(option.1)
                                .font(.settingsNvidia(size: 11 * uiScale, weight: .medium))
                                .foregroundStyle(.white.opacity(0.5))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(9 * uiScale)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(option.2 ? Color.white.opacity(0.07) : Color.white.opacity(0.025))
                    .overlay { Rectangle().stroke(option.2 ? OpenNOWDesign.accent.opacity(0.5) : Color.white.opacity(0.08), lineWidth: 1) }
                }
                .buttonStyle(.plain)
            }
        }
    }
}
