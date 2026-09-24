//  The native Co-Op guest window: listen for the host's forwarded source video on a UDP port and
//  render it through the same Metal surface the stream uses. No WebRTC anywhere on this path — the
//  received access units are decoded and the resulting frames go straight to the view.
//

import SwiftUI

struct RemoteCoOpNativeGuestView: View {
    @StateObject private var viewModel = RemoteCoOpNativeGuestViewModel()
    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        ZStack {
            OPNDesign.Surface.deep.ignoresSafeArea()
            RemoteCoOpNativeGuestSurface(receiver: viewModel.receiver)
                .ignoresSafeArea()
            overlay
        }
        .onDisappear { viewModel.stopListening() }
    }

    private var overlay: some View {
        VStack(alignment: .leading, spacing: OPNDesign.Spacing.small(scale: uiScale)) {
            HStack(spacing: OPNDesign.Spacing.xSmall(scale: uiScale)) {
                TextField("Port", text: $viewModel.portText)
                    .textFieldStyle(.plain)
                    .catalogFont(size: 13 * uiScale)
                    .monospacedDigit()
                    .foregroundStyle(OPNDesign.Text.primary)
                    .padding(.horizontal, OPNDesign.Spacing.small(scale: uiScale))
                    .frame(width: 96 * uiScale, height: 28 * uiScale)
                    .background(OPNDesign.Surface.panelRaised)
                    .overlay { Rectangle().stroke(.white.opacity(0.16), lineWidth: 1) }
                    .disabled(viewModel.phase == .listening)
                    .onSubmit { viewModel.startListening() }
                if viewModel.phase == .listening {
                    Button("Stop") { viewModel.stopListening() }
                        .buttonStyle(OPNCompactButtonStyle(role: .destructive, uiScale: uiScale))
                } else {
                    Button("Listen") { viewModel.startListening() }
                        .buttonStyle(OPNCompactButtonStyle(role: .primary, uiScale: uiScale))
                }
                Spacer()
            }
            if let stats = viewModel.stats {
                statsLine(stats)
            }
            Text(viewModel.statusText)
                .catalogFont(size: 11 * uiScale, weight: .medium)
                .foregroundStyle(OPNDesign.Text.secondary)
                .padding(.horizontal, OPNDesign.Spacing.small(scale: uiScale))
                .padding(.vertical, OPNDesign.Spacing.xxSmall(scale: uiScale))
                .background(OPNDesign.Surface.scrim)
            Spacer()
        }
        .padding(OPNDesign.Spacing.medium(scale: uiScale))
    }

    private func statsLine(_ stats: RemoteCoOpNativeGuestReceiver.Stats) -> some View {
        Text("\(stats.codecName)  \(stats.resolutionText)  "
             + String(format: "%.0f fps", stats.framesPerSecond)
             + String(format: "  %.1f Mbps", stats.megabitsPerSecond)
             + "  decoded \(stats.decoded)  missed \(stats.failures)")
            .catalogFont(size: 11 * uiScale, weight: .medium)
            .monospacedDigit()
            .foregroundStyle(OPNDesign.Text.primary)
            .padding(.horizontal, OPNDesign.Spacing.small(scale: uiScale))
            .padding(.vertical, OPNDesign.Spacing.xxSmall(scale: uiScale))
            .background(OPNDesign.Surface.scrim)
    }
}

/// The guest's video surface: the stream's own Metal view, fed decoded `OPNVideoFrame`s directly.
private struct RemoteCoOpNativeGuestSurface: NSViewRepresentable {
    let receiver: RemoteCoOpNativeGuestReceiver

    /// Retains the view so the receiver's frame callback can render off the main thread. Rendering is
    /// thread-safe, so no actor hop is needed at stream cadence.
    final class Renderer: @unchecked Sendable {
        private let view: OPNMetalVideoView

        init(view: OPNMetalVideoView) {
            self.view = view
        }

        func render(_ frame: OPNVideoFrame) {
            view.renderFrame(frame)
        }
    }

    func makeNSView(context: Context) -> OPNMetalVideoView {
        // 120 rather than 60: this is the layer's `preferredFramesPerSecond`, a ceiling the system
        // clamps to the display, so asking high costs nothing on a 60 Hz panel.
        let view = OPNMetalVideoView(frame: .zero, targetFps: 120)
        let renderer = Renderer(view: view)
        receiver.onFrame = { [renderer] frame in renderer.render(frame) }
        return view
    }

    func updateNSView(_ nsView: OPNMetalVideoView, context: Context) {}

    static func dismantleNSView(_ nsView: OPNMetalVideoView, coordinator: ()) {
        // The receiver is owned by the view model; clearing here would need a reference to it, and
        // the renderer retains the view, so the pair is released together when the window closes.
    }
}
