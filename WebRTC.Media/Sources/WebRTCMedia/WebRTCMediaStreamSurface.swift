import SwiftUI

public typealias WebRTCMediaStreamProgressCallback = @MainActor @Sendable (_ progress: StreamProgress) -> Void
public typealias WebRTCMediaStreamEndCallback = @MainActor @Sendable (_ success: Bool, _ message: String, _ report: StreamReport?) -> Void

@MainActor
public struct WebRTCMediaStreamSurface: View {
    private let configuration: StreamLaunchConfiguration
    private let sessionProvider: any StreamSessionProvider
    private let signaling: (any StreamSignalingChannel)?
    private let onProgress: WebRTCMediaStreamProgressCallback?
    private let onEnd: WebRTCMediaStreamEndCallback

    @State private var path: WebRTCStreamingPath?
    @State private var transport: NativeWebRTCTransport?
    @State private var hasStarted = false
    @State private var isStreamReady = false
    @State private var statusMessage = "Starting WebRTC media path..."
    @State private var pointerLocked = false
    @State private var statsVisible = false
    @State private var sidebarVisible = true
    @State private var latestStats: OPNStreamStatsSnapshot?
    @State private var statsTask: Task<Void, Never>?
    @State private var nativeView: NativeWebRTCStreamView?

    public init(configuration: StreamLaunchConfiguration,
                sessionProvider: any StreamSessionProvider,
                signaling: (any StreamSignalingChannel)? = nil,
                onProgress: WebRTCMediaStreamProgressCallback? = nil,
                onEnd: @escaping WebRTCMediaStreamEndCallback) {
        self.configuration = configuration
        self.sessionProvider = sessionProvider
        self.signaling = signaling
        self.onProgress = onProgress
        self.onEnd = onEnd
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            NativeWebRTCStreamSurface { view in
                nativeView = view
                view.onPointerLockChanged = { locked in pointerLocked = locked }
                view.onCommand = { command in
                    handle(command)
                }
                Task { await startIfNeeded(nativeView: view) }
            }
            if !isStreamReady { launchOverlay }
            if statsVisible { statsHUD }
            if sidebarVisible { sidebar }
            if pointerLocked { pointerLockBadge }
        }
        .background(Color.black)
        .ignoresSafeArea()
        .onDisappear { stopStream() }
    }

    private var launchOverlay: some View {
        LinearGradient(
            colors: [Color(red: 0.015, green: 0.02, blue: 0.018), Color(red: 0.05, green: 0.08, blue: 0.055)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            VStack(spacing: 18) {
                Text(configuration.title.isEmpty ? "GeForce NOW" : configuration.title)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(statusMessage)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(red: 0.67, green: 1.0, blue: 0.36).opacity(0.84))
                ProgressView()
                    .controlSize(.large)
                    .tint(Color(red: 0.56, green: 1.0, blue: 0.25))
            }
            .padding(36)
            .background(.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
        }
    }

    private var statsHUD: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("STREAM STATS")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(red: 0.61, green: 1.0, blue: 0.22))
            statsRow("Latency", formatted(latestStats?.latencyMs, suffix: " ms"))
            statsRow("Jitter", formatted(latestStats?.jitterMs, suffix: " ms"))
            statsRow("Bitrate", formatted(latestStats?.inboundBitrateMbps, suffix: " Mbps"))
            statsRow("Loss", formatted(latestStats?.packetLossPercent, suffix: "%"))
            statsRow("FPS", formatted(latestStats?.renderFps, suffix: ""))
            statsRow("Codec", latestStats?.codec.isEmpty == false ? latestStats?.codec ?? "-" : "-")
            statsRow("Resolution", latestStats?.resolution.isEmpty == false ? latestStats?.resolution ?? "-" : "-")
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .padding(14)
        .frame(width: 228, alignment: .leading)
        .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color(red: 0.61, green: 1.0, blue: 0.22).opacity(0.28), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 24, x: 0, y: 12)
        .padding(.top, 22)
        .padding(.trailing, sidebarVisible ? 102 : 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    private var sidebar: some View {
        VStack(spacing: 10) {
            Text("GFN")
                .font(.system(size: 11, weight: .black, design: .rounded))
                .foregroundStyle(Color(red: 0.61, green: 1.0, blue: 0.22))
                .padding(.bottom, 6)
            sidebarButton(systemName: pointerLocked ? "cursorarrow.rays" : "cursorarrow", title: pointerLocked ? "Unlock" : "Lock") {
                nativeView?.setPointerLocked(!pointerLocked)
            }
            sidebarButton(systemName: "waveform.path.ecg", title: "Stats") {
                statsVisible.toggle()
            }
            sidebarButton(systemName: "gamecontroller.fill", title: "Pad") {
                WebRTCMediaTelemetry.capture("webrtc.ui.gamepad.status", level: .info, message: "Gamepad status requested.", attributes: ["connected": String(NativeWebRTCGamepadMonitor.connectedGamepadCount())])
            }
            sidebarButton(systemName: "xmark", title: "Close") {
                sidebarVisible = false
            }
        }
        .padding(10)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
        .padding(.top, 22)
        .padding(.trailing, 18)
    }

    private var pointerLockBadge: some View {
        Text("POINTER LOCKED  ESC TO RELEASE")
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.black)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color(red: 0.61, green: 1.0, blue: 0.22), in: Capsule())
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private func sidebarButton(systemName: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemName)
                    .font(.system(size: 17, weight: .semibold))
                Text(title)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.white.opacity(0.92))
            .frame(width: 58, height: 54)
            .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func statsRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.white.opacity(0.58))
            Spacer()
            Text(value).foregroundStyle(.white.opacity(0.94))
        }
    }

    private func formatted(_ value: Double?, suffix: String) -> String {
        guard let value, value >= 0 else { return "-" }
        return String(format: "%.1f%@", value, suffix)
    }

    private func startIfNeeded(nativeView: NativeWebRTCStreamView) async {
        guard !hasStarted else { return }
        hasStarted = true
        let transport = NativeWebRTCTransport(nativeView: nativeView)
        let path = WebRTCStreamingPath(sessionProvider: sessionProvider, transport: transport, signaling: signaling)
        nativeView.onInputEvent = { event in Task { try? await path.send(event) } }
        self.transport = transport
        self.path = path
        startStatsPolling(transport: transport)
        do {
            _ = try await path.start(configuration: configuration) { progress in
                await MainActor.run {
                    statusMessage = progress.message
                    isStreamReady = progress.isReady
                    onProgress?(progress)
                }
            }
        } catch {
            let message = Self.message(for: error)
            statusMessage = message
            onEnd(false, message, StreamReport(title: configuration.title, success: false, reason: .failed, message: message, durationSeconds: 0, metadata: ["applicationID": configuration.applicationID]))
        }
    }

    private func startStatsPolling(transport: NativeWebRTCTransport) {
        statsTask?.cancel()
        statsTask = Task {
            for await snapshot in transport.statsSnapshots(intervalSeconds: 1) {
                latestStats = snapshot
            }
        }
    }

    private func handle(_ command: WebRTCMediaStreamCommand) {
        switch command {
        case .toggleStatsHUD:
            statsVisible.toggle()
            WebRTCMediaTelemetry.capture("webrtc.ui.stats.toggle", level: .info, message: statsVisible ? "Stats HUD shown." : "Stats HUD hidden.", attributes: ["visible": String(statsVisible)])
        case .toggleSidebar:
            sidebarVisible.toggle()
            WebRTCMediaTelemetry.capture("webrtc.ui.sidebar.toggle", level: .info, message: sidebarVisible ? "Sidebar shown." : "Sidebar hidden.", attributes: ["visible": String(sidebarVisible)])
        }
    }

    private func stopStream() {
        statsTask?.cancel()
        statsTask = nil
        nativeView?.setPointerLocked(false)
        if let path { Task { try? await path.stop(reason: .userRequested, message: "Stream view closed.") } }
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription, !description.isEmpty { return description }
        return error.localizedDescription
    }
}

private struct NativeWebRTCStreamSurface: NSViewRepresentable {
    let onResolve: @MainActor (NativeWebRTCStreamView) -> Void

    func makeNSView(context: Context) -> NativeWebRTCStreamView {
        let view = NativeWebRTCStreamView(frame: .zero)
        onResolve(view)
        return view
    }

    func updateNSView(_ nsView: NativeWebRTCStreamView, context: Context) {}
}
