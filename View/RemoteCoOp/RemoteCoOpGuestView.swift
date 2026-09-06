//  The native Remote Co-Op guest window: discover hosts on this network, join one, watch the
//  stream. Video renders through the same Metal view the main stream surface uses.
//

import SwiftUI
@preconcurrency import WebRTC

struct RemoteCoOpGuestView: View {
    @StateObject private var viewModel = RemoteCoOpGuestViewModel()
    @Environment(\.opnUIScale) private var uiScale
    /// The controls sit over the game, so they retreat when the mouse does. Shown again on any
    /// movement, which is the same bargain the main stream surface makes.
    @State private var controlsVisible = true
    @State private var controlsHideTask: Task<Void, Never>?
    @State private var waitingElapsed = 0
    private static let controlsIdleSeconds: UInt64 = 3

    var body: some View {
        ZStack {
            OpenNOWDesign.Surface.deep.ignoresSafeArea()
            // Gated on the phase as well as the track. A track can arrive before approval - a host
            // bug did exactly that - and rendering it put the game on screen underneath the
            // "waiting for approval" overlay, which is the one thing that overlay promises is not
            // happening. The host is not the only thing that should have to be right about this.
            if let track = viewModel.videoTrack, viewModel.phase.allowsVideoPlayback {
                RemoteCoOpGuestVideoSurface(track: track)
                    .ignoresSafeArea()
            }
            overlayContent
        }
        .onContinuousHover { phase in
            guard case .active = phase else { return }
            revealControls()
        }
        .onAppear {
            viewModel.start()
            revealControls()
            enableFullScreenOnHostingWindow()
        }
        .onDisappear {
            controlsHideTask?.cancel()
            viewModel.stop()
        }
        .task(id: viewModel.waitingSince) {
            // Ticks only while an approval is outstanding, so the wait has a number on it instead of
            // an indefinite spinner.
            guard let start = viewModel.waitingSince else {
                waitingElapsed = 0
                return
            }
            while !Task.isCancelled {
                waitingElapsed = max(0, Int(Date().timeIntervalSince(start)))
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// A singleton SwiftUI `Window` scene - what this window is - does not reliably pick up
    /// `.fullScreenPrimary` the way a `WindowGroup` window does; the main catalog window works
    /// without this because it is a `WindowGroup`.
    ///
    /// Known rough edge: entering fullscreen works, but the button that should exit it can end up
    /// unresponsive - confirmed live, not dimming. Mutating styleMask/collectionBehavior after the
    /// scene creates the window updates what Accessibility reports without fully updating the
    /// window-server state underneath, which is a SwiftUI `Window`-scene limitation this cannot fully
    /// paper over. Kept anyway, by request: entry working is worth more than nothing. If the button
    /// does not respond, `⌃⌘F` or `Esc` are the way out.
    private func enableFullScreenOnHostingWindow() {
        if let window = NSApp.keyWindow {
            configureForFullScreen(window)
        } else {
            DispatchQueue.main.async {
                NSApp.keyWindow.map(configureForFullScreen)
            }
        }
    }

    private func configureForFullScreen(_ window: NSWindow) {
        window.collectionBehavior.insert(.fullScreenPrimary)
        if !window.styleMask.contains(.resizable) {
            window.styleMask.insert(.resizable)
        }
        if !window.styleMask.contains(.miniaturizable) {
            window.styleMask.insert(.miniaturizable)
        }
    }

    private func revealControls() {
        controlsHideTask?.cancel()
        if !controlsVisible { controlsVisible = true }
        controlsHideTask = Task {
            try? await Task.sleep(for: .seconds(Self.controlsIdleSeconds))
            guard !Task.isCancelled else { return }
            controlsVisible = false
        }
    }

    @ViewBuilder
    private var overlayContent: some View {
        switch viewModel.phase {
        case .browsing:
            hostBrowser
        case .connecting, .waitingForApproval:
            statusPanel(systemImage: "person.wave.2")
        case .connected:
            if viewModel.videoTrack == nil {
                statusPanel(systemImage: "antenna.radiowaves.left.and.right")
            } else {
                VStack(alignment: .leading, spacing: OpenNOWDesign.Spacing.xxSmall(scale: uiScale)) {
                    // No status pill once the video is up. "Watching <title>" restated what the guest
                    // is already looking at, and the controls next to it are the only part of this
                    // row that does anything.
                    HStack(spacing: OpenNOWDesign.Spacing.xSmall(scale: uiScale)) {
                        leaveButton
                        statsToggle
                        qualityMenu
                        Spacer()
                    }
                    .opacity(controlsVisible ? 1 : 0)
                    .animation(.easeInOut(duration: 0.2), value: controlsVisible)
                    if viewModel.hasController == false {
                        controllerMissingNotice
                    }
                    if viewModel.statsVisible, let stats = viewModel.stats {
                        Text([viewModel.connectedHostName, stats.overlayText].compactMap { $0 }.joined(separator: "  ·  "))
                            .catalogFont(size: 11 * uiScale, weight: .medium)
                            .monospacedDigit()
                            .foregroundStyle(OpenNOWDesign.Text.primary)
                            .padding(.horizontal, OpenNOWDesign.Spacing.small(scale: uiScale))
                            .padding(.vertical, OpenNOWDesign.Spacing.xxSmall(scale: uiScale))
                            .background(OpenNOWDesign.Surface.scrim)
                            .clipShape(Capsule())
                    }
                    Spacer()
                }
                .padding(OpenNOWDesign.Spacing.medium(scale: uiScale))
            }
        case .failed(let reason):
            failurePanel(reason: reason)
        }
    }

    private var hostBrowser: some View {
        VStack(spacing: OpenNOWDesign.Spacing.large(scale: uiScale)) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 40 * uiScale))
                .foregroundStyle(OpenNOWDesign.Text.secondary)
            Text("Join Remote Co-Op")
                .catalogFont(size: 22 * uiScale, weight: .semibold)
                .foregroundStyle(OpenNOWDesign.Text.primary)
            Text(viewModel.statusText)
                .catalogFont(size: 13 * uiScale)
                .foregroundStyle(OpenNOWDesign.Text.secondary)
            if viewModel.hosts.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, OpenNOWDesign.Spacing.xSmall(scale: uiScale))
            } else {
                VStack(spacing: OpenNOWDesign.Spacing.xSmall(scale: uiScale)) {
                    ForEach(viewModel.hosts) { host in
                        Button {
                            viewModel.join(host)
                        } label: {
                            HStack {
                                Image(systemName: "desktopcomputer")
                                Text(host.name)
                                    .catalogFont(size: 14 * uiScale, weight: .medium)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(OpenNOWDesign.Text.tertiary)
                            }
                            .padding(.horizontal, OpenNOWDesign.Spacing.medium(scale: uiScale))
                            .padding(.vertical, OpenNOWDesign.Spacing.small(scale: uiScale))
                            .frame(maxWidth: 360 * uiScale)
                            .background(OpenNOWDesign.Surface.panelRaised)
                            .overlay { Rectangle().stroke(.white.opacity(0.12), lineWidth: 1) }
                        }
                        .buttonStyle(.opnPressable(scale: 0.98))
                        .foregroundStyle(OpenNOWDesign.Text.primary)
                    }
                }
            }
            manualAddressField
            recentAddressList
        }
    }

    /// Somewhere to click instead of retyping. The field remembers one address; a guest who alternates
    /// between two hosts was retyping the other one every time.
    @ViewBuilder
    private var recentAddressList: some View {
        if !viewModel.recentAddresses.isEmpty {
            VStack(spacing: OpenNOWDesign.Spacing.xxSmall(scale: uiScale)) {
                Text("Recent")
                    .catalogFont(size: 11 * uiScale, weight: .medium)
                    .foregroundStyle(OpenNOWDesign.Text.tertiary)
                ForEach(viewModel.recentAddresses, id: \.self) { address in
                    HStack(spacing: OpenNOWDesign.Spacing.xxSmall(scale: uiScale)) {
                        Button { viewModel.joinRecentAddress(address) } label: {
                            HStack(spacing: OpenNOWDesign.Spacing.xxSmall(scale: uiScale)) {
                                Image(systemName: "clock.arrow.circlepath")
                                Text(address)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .catalogFont(size: 12 * uiScale, weight: .medium)
                            .foregroundStyle(OpenNOWDesign.Text.secondary)
                            .padding(.horizontal, OpenNOWDesign.Spacing.small(scale: uiScale))
                            .frame(width: 260 * uiScale, height: 26 * uiScale, alignment: .leading)
                            .background(OpenNOWDesign.Surface.panelRaised)
                            .overlay { Rectangle().stroke(.white.opacity(0.10), lineWidth: 1) }
                        }
                        .buttonStyle(.opnPressable(scale: 0.98))
                        Button { viewModel.forgetRecentAddress(address) } label: {
                            Image(systemName: "xmark")
                                .catalogFont(size: 10 * uiScale, weight: .bold)
                                .foregroundStyle(OpenNOWDesign.Text.tertiary)
                                .frame(width: 20 * uiScale, height: 26 * uiScale)
                        }
                        .buttonStyle(.opnPressable(scale: 0.9))
                        .accessibilityLabel("Forget \(address)")
                    }
                }
            }
        }
    }

    /// The way in for hosts the browser above can never list. Discovery is multicast, so a host
    /// reachable over Tailscale or any other tunnel is invisible to it while being perfectly
    /// connectable - this is where that address goes.
    private var manualAddressField: some View {
        VStack(spacing: OpenNOWDesign.Spacing.xxSmall(scale: uiScale)) {
            Text("Or connect by address or invite link")
                .catalogFont(size: 12 * uiScale, weight: .medium)
                .foregroundStyle(OpenNOWDesign.Text.tertiary)
            HStack(spacing: OpenNOWDesign.Spacing.xSmall(scale: uiScale)) {
                TextField("100.101.102.103 or https://…", text: $viewModel.manualAddress)
                    .textFieldStyle(.plain)
                    .catalogFont(size: 13 * uiScale)
                    .foregroundStyle(OpenNOWDesign.Text.primary)
                    .padding(.horizontal, OpenNOWDesign.Spacing.small(scale: uiScale))
                    .frame(width: 260 * uiScale, height: 28 * uiScale)
                    .background(OpenNOWDesign.Surface.panelRaised)
                    .overlay { Rectangle().stroke(.white.opacity(0.16), lineWidth: 1) }
                    .onSubmit { viewModel.joinManualAddress() }
                Button("Join") { viewModel.joinManualAddress() }
                    .buttonStyle(OpenNOWCompactButtonStyle(role: .primary, uiScale: uiScale))
                    .disabled(viewModel.manualAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("A Tailscale address or MagicDNS name works here, as does the invite link the host copied — use the link if they are behind a tunnel. Bonjour only reaches your local network.")
                .catalogFont(size: 11 * uiScale)
                .foregroundStyle(OpenNOWDesign.Text.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340 * uiScale)
        }
        .padding(.top, OpenNOWDesign.Spacing.medium(scale: uiScale))
    }

    private func statusPanel(systemImage: String) -> some View {
        VStack(spacing: OpenNOWDesign.Spacing.medium(scale: uiScale)) {
            Image(systemName: systemImage)
                .font(.system(size: 32 * uiScale))
                .foregroundStyle(OpenNOWDesign.Text.secondary)
            Text(viewModel.statusText)
                .catalogFont(size: 15 * uiScale, weight: .medium)
                .foregroundStyle(OpenNOWDesign.Text.primary)
            if viewModel.phase == .waitingForApproval, waitingElapsed > 0 {
                Text(waitingElapsed < 60 ? "\(waitingElapsed)s" : "\(waitingElapsed / 60)m \(waitingElapsed % 60)s")
                    .catalogFont(size: 12 * uiScale, weight: .medium)
                    .monospacedDigit()
                    .foregroundStyle(OpenNOWDesign.Text.tertiary)
            }
            ProgressView()
                .controlSize(.small)
            Button("Cancel") { viewModel.leave() }
                .buttonStyle(OpenNOWCompactButtonStyle(role: .destructive, uiScale: uiScale))
        }
        .padding(OpenNOWDesign.Spacing.xLarge(scale: uiScale))
        .background(OpenNOWDesign.Surface.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14 * uiScale, style: .continuous))
    }

    /// The only way out of a live session that is not closing the window. Every other phase has an
    /// exit; this is the one a guest actually spends their time in.
    private var leaveButton: some View {
        Button { viewModel.leave() } label: {
            HStack(spacing: 4 * uiScale) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                Text("Leave")
            }
            .catalogFont(size: 11 * uiScale, weight: .medium)
            .foregroundStyle(OpenNOWDesign.Text.primary)
            .padding(.horizontal, OpenNOWDesign.Spacing.small(scale: uiScale))
            .padding(.vertical, OpenNOWDesign.Spacing.xxSmall(scale: uiScale))
            .background(OpenNOWDesign.Surface.scrim)
            .clipShape(Capsule())
        }
        .buttonStyle(.opnPressable(scale: 0.95))
        .accessibilityLabel("Leave this session")
        .help("Leave this session")
    }

    /// Reveals the receive measurements. The guest is the only side that can see its own jitter
    /// buffer and route time, so this is where "is it actually fast" gets answered.
    private var statsToggle: some View {
        Button {
            viewModel.statsVisible.toggle()
        } label: {
            Image(systemName: viewModel.statsVisible ? "speedometer" : "gauge.with.dots.needle.33percent")
                .font(.system(size: 12 * uiScale))
                .foregroundStyle(viewModel.statsVisible ? OpenNOWDesign.Text.primary : OpenNOWDesign.Text.tertiary)
                .padding(OpenNOWDesign.Spacing.xxSmall(scale: uiScale))
                .background(OpenNOWDesign.Surface.scrim)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Show connection latency")
    }

    /// Lets the guest lower their own stream.
    ///
    /// Only downward: the picture is encoded and uploaded by the host, so raising it spends someone
    /// else's bandwidth and encoder. Anything above what the host allowed is not offered rather than
    /// offered and silently clamped, so the menu never shows a choice that does nothing. The host can
    /// still put the guest back up at any time, which is why "Host Default" stays available.
    @ViewBuilder
    private var qualityMenu: some View {
        if viewModel.phase == .connected {
            Menu {
                Button("Host Default") { viewModel.requestQualityPreset(nil) }
                Divider()
                ForEach(viewModel.selectableQualityPresets, id: \.self) { preset in
                    Button(preset.label) { viewModel.requestQualityPreset(preset) }
                }
            } label: {
                HStack(spacing: OpenNOWDesign.Spacing.xxSmall(scale: uiScale)) {
                    Image(systemName: "slider.horizontal.3")
                    Text(viewModel.participant?.guestRequestedQualityPreset?.label ?? "Quality")
                }
                .catalogFont(size: 11 * uiScale, weight: .medium)
                .foregroundStyle(OpenNOWDesign.Text.primary)
                .padding(.horizontal, OpenNOWDesign.Spacing.small(scale: uiScale))
                .padding(.vertical, OpenNOWDesign.Spacing.xxSmall(scale: uiScale))
                .background(OpenNOWDesign.Surface.scrim)
                .clipShape(Capsule())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Lower your own stream quality. The host sets the maximum.")
        }
    }

    /// Says so when there is no controller.
    ///
    /// The browser guest has to prompt for a button press because the Gamepad API hides controllers
    /// until one is pressed - a fingerprinting mitigation, not a real gate. Nothing needs unlocking
    /// here: GameController reports a pad immediately. What was missing is the other half of that
    /// prompt, which is telling someone with no pad connected why the game is ignoring them. Guests
    /// cannot use a keyboard: the wire packet carries pad state, and the seat has no second keyboard
    /// to route keystrokes to.
    private var controllerMissingNotice: some View {
        HStack(spacing: OpenNOWDesign.Spacing.xSmall(scale: uiScale)) {
            Image(systemName: "gamecontroller")
            Text("No controller detected — connect one to play. Guests cannot use a keyboard or mouse.")
                .catalogFont(size: 11 * uiScale, weight: .medium)
        }
        .foregroundStyle(OpenNOWDesign.Text.primary)
        .padding(.horizontal, OpenNOWDesign.Spacing.small(scale: uiScale))
        .padding(.vertical, OpenNOWDesign.Spacing.xxSmall(scale: uiScale))
        .background(OpenNOWDesign.Semantic.destructive.opacity(0.75))
        .clipShape(Capsule())
    }

    private func failurePanel(reason: String) -> some View {
        VStack(spacing: OpenNOWDesign.Spacing.medium(scale: uiScale)) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32 * uiScale))
                .foregroundStyle(OpenNOWDesign.Semantic.destructive)
            Text("Couldn't join")
                .catalogFont(size: 17 * uiScale, weight: .semibold)
                .foregroundStyle(OpenNOWDesign.Text.primary)
            Text(reason)
                .catalogFont(size: 13 * uiScale)
                .foregroundStyle(OpenNOWDesign.Text.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380 * uiScale)
            Button("Back") { viewModel.leave() }
                .buttonStyle(OpenNOWCompactButtonStyle(role: .primary, uiScale: uiScale))
        }
        .padding(OpenNOWDesign.Spacing.xLarge(scale: uiScale))
        .background(OpenNOWDesign.Surface.panel)
        .overlay { Rectangle().stroke(.white.opacity(0.14), lineWidth: 1) }
    }
}

/// The guest's video: the stream surface's own Metal view, driven owner-less (enhancement
/// overrides off, plain rendering) straight from the received track.
private struct RemoteCoOpGuestVideoSurface: NSViewRepresentable {
    let track: RTCVideoTrack

    /// Holds whichever track the view is currently rendering. `var`, because SwiftUI reuses the
    /// NSView across a track change and the renderer has to be moved: bound once in `makeNSView`,
    /// the second track never rendered and `dismantleNSView` released the wrong one.
    final class Coordinator {
        var track: RTCVideoTrack
        init(track: RTCVideoTrack) { self.track = track }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(track: track)
    }

    func makeNSView(context: Context) -> OPNMetalVideoView {
        // 120 rather than 60: this becomes the layer's `preferredFramesPerSecond`, so a 60 here would
        // cap presentation at 60 even when the host is sending a 120 fps preset - the received frames
        // would be decoded and then dropped at the last step. The guest has no way to know which
        // preset the host chose, and the value is a ceiling the system clamps to the actual display
        // refresh, so asking for the higher one costs nothing on a 60 Hz panel.
        let view = OPNMetalVideoView(frame: .zero, targetFps: 120, owner: nil)
        track.add(view)
        return view
    }

    func updateNSView(_ nsView: OPNMetalVideoView, context: Context) {
        guard context.coordinator.track !== track else { return }
        context.coordinator.track.remove(nsView)
        context.coordinator.track = track
        track.add(nsView)
    }

    // The track retains its renderers, so a view that is going away must be removed explicitly or
    // libwebrtc keeps decoding into it.
    static func dismantleNSView(_ nsView: OPNMetalVideoView, coordinator: Coordinator) {
        coordinator.track.remove(nsView)
    }
}
