//
//  CatalogLaunchOverlayViews.swift
//  OpenNOW
//

import AppKit
import AVKit
import Combine
import CryptoKit
import ImageIO
import SwiftUI

struct VendorLaunchFlowOverlay: View {
    let viewModel: CatalogViewModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.82)
                .ignoresSafeArea()
            RadialGradient(
                colors: [OpenNOWDesign.accent.opacity(0.20), .clear],
                center: .top,
                startRadius: 20,
                endRadius: 620
            )
            .ignoresSafeArea()

            switch viewModel.launchFlowState {
            case .activeSessionPrompt:
                VendorActiveSessionCard(viewModel: viewModel)
            case .checkingSession, .stoppingSession, .startingStream:
                VendorLaunchProgressCard(viewModel: viewModel)
            case .idle:
                EmptyView()
            }
        }
    }
}

struct VendorActiveSessionCard: View {
    let viewModel: CatalogViewModel

    var body: some View {
        VendorLaunchPanel(title: "Active Session", subtitle: viewModel.activeLaunchSession?.title ?? "Current Stream") {
            VStack(alignment: .leading, spacing: 18) {
                VendorLaunchStepHeader(index: "2", title: "Session Already Running", message: viewModel.launchFlowMessage)
                if let active = viewModel.activeLaunchSession {
                    VStack(alignment: .leading, spacing: 10) {
                        VendorLaunchSessionRow(label: "Current session", value: active.title)
                        VendorLaunchSessionRow(label: "App ID", value: active.appId > 0 ? String(active.appId) : "Unknown")
                        VendorLaunchSessionRow(label: "Server", value: active.serverIp)
                    }
                    .padding(14)
                    .background(Color.white.opacity(0.055))
                    .overlay { Rectangle().stroke(Color.white.opacity(0.10), lineWidth: 1) }
                }
                if !viewModel.launchFlowError.isEmpty {
                    VendorLaunchInlineMessage(message: viewModel.launchFlowError, warning: true)
                }
                HStack(spacing: 12) {
                    Button("CANCEL") { viewModel.cancelVendorLaunch() }
                        .buttonStyle(VendorLaunchSecondaryButtonStyle())
                    Spacer()
                    if viewModel.canResumeActiveLaunchSession {
                        Button("RESUME SESSION") { viewModel.resumeActiveLaunchSession() }
                            .buttonStyle(VendorLaunchSecondaryButtonStyle())
                    }
                    Button("END AND LAUNCH") { viewModel.endActiveSessionAndLaunchSelectedGame() }
                        .buttonStyle(VendorLaunchPrimaryButtonStyle())
                }
            }
        }
    }
}

struct VendorLaunchProgressCard: View {
    let viewModel: CatalogViewModel

    var body: some View {
        VendorLaunchPanel(title: "Launching", subtitle: viewModel.launchFlowTitle) {
            VStack(alignment: .leading, spacing: 14) {
                Text(progressTitle)
                    .font(.nvidia(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                VendorIndeterminateProgressBar()
                    .frame(height: 4)
                if !viewModel.launchFlowError.isEmpty {
                    VendorLaunchInlineMessage(message: viewModel.launchFlowError, warning: true)
                }
            }
        }
    }

    private var progressTitle: String {
        switch viewModel.launchFlowState {
        case .checkingSession: return "Checking Session"
        case .stoppingSession: return "Ending Session"
        case .startingStream: return "Starting Stream"
        default: return "Preparing Launch"
        }
    }
}

struct VendorStreamLaunchLoadingOverlay: View {
    let viewModel: CatalogViewModel

    var body: some View {
        let progress = viewModel.activeStreamProgress
        let configuration = viewModel.activeStreamConfiguration
        StreamLaunchLoadingScreen(
            title: progress?.title.isEmpty == false ? progress?.title ?? "GeForce NOW" : "GeForce NOW",
            stage: viewModel.activeStreamAdPlayback == nil ? StreamLaunchLoadingStage.label(stepIndex: progress?.currentStepIndex ?? -1, queuePosition: progress?.queuePosition) : "Sponsored break",
            artworkURL: configuration?.loadingArtworkURL,
            queuePosition: progress?.queuePosition,
            accessoryPresented: viewModel.activeStreamAdPlayback != nil,
            cancelAction: viewModel.cancelActiveStreamLaunch
        ) {
            if let ad = viewModel.activeStreamAdPlayback {
                VendorEmbeddedSessionAdPlayer(
                    ad: ad,
                    onFinished: { watchedTimeInMs in viewModel.finishRequiredStreamAdPlayback(watchedTimeInMs: watchedTimeInMs) },
                    onFailed: { message in viewModel.failRequiredStreamAdPlayback(message) }
                )
            }
        }
    }
}

struct VendorEmbeddedSessionAdPlayer: View {
    private static let volumePreferenceKey = "OpenNOW.Stream.RequiredSessionAdVolume"

    let ad: CatalogStreamAdPlayback
    let onFinished: (Int) -> Void
    let onFailed: (String) -> Void
    @State private var player: AVPlayer?
    @State private var item: AVPlayerItem?
    @State private var statusObservation: NSKeyValueObservation?
    @State private var endObserver: NSObjectProtocol?
    @State private var startedAt = Date()
    @State private var remainingSeconds = 0
    @AppStorage(Self.volumePreferenceKey) private var volume = 1.0
    @State private var didFinish = false
    private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                if let player {
                    VendorSessionAdPlayerView(player: player)
                } else {
                    Color.black
                    ProgressView()
                        .controlSize(.large)
                }

                Text("AD · \(countdownText)")
                    .nvidiaFont(size: 12, weight: .bold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, OpenNOWDesign.Spacing.controlRow)
                    .padding(.vertical, 7)
                    .background(Color.black.opacity(0.72))
                    .padding(OpenNOWDesign.Spacing.contentVertical)
            }
            .background(.black)

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ad.title)
                        .nvidiaFont(size: 13, weight: .bold)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("Sponsored message required before your free-tier session continues")
                        .nvidiaFont(size: 11, weight: .medium)
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                HStack(spacing: 9) {
                    Image(systemName: volume <= 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.nvidiaSans(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.72))
                    Slider(value: $volume, in: 0...1)
                        .frame(width: 140)
                        .onChange(of: volume) { _, nextVolume in
                            player?.volume = Float(nextVolume)
                        }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.black.opacity(0.86))
        }
        .clipShape(Rectangle())
        .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.regular, lineWidth: 1) }
        .shadow(color: .black.opacity(0.54), radius: 26, y: 18)
        .onAppear(perform: startPlayback)
        .onDisappear(perform: stopPlayback)
        .onReceive(timer) { _ in updateCountdown() }
    }

    private var countdownText: String {
        let minutes = max(0, remainingSeconds) / 60
        let seconds = max(0, remainingSeconds) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func startPlayback() {
        guard player == nil else { return }
        guard let url = URL(string: ad.mediaUrl) else {
            fail("Required ad media URL is invalid.")
            return
        }
        startedAt = Date()
        remainingSeconds = max(1, Int(ceil(Double(ad.durationMs) / 1000.0)))
        let nextItem = AVPlayerItem(url: url)
        let nextPlayer = AVPlayer(playerItem: nextItem)
        nextPlayer.volume = Float(volume)
        item = nextItem
        player = nextPlayer
        statusObservation = nextItem.observe(\.status, options: [.new]) { observedItem, _ in
            Task { @MainActor in
                if observedItem.status == .failed {
                    fail(observedItem.error?.localizedDescription ?? "Required ad failed to load.")
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nextItem, queue: .main) { _ in
            Task { @MainActor in finish() }
        }
        nextPlayer.play()
    }

    private func stopPlayback() {
        statusObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        player?.pause()
        player = nil
        item = nil
    }

    private func updateCountdown() {
        guard let player else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        let knownDuration = Double(ad.durationMs) / 1000.0
        let itemDuration = player.currentItem?.duration.seconds ?? 0
        let duration = knownDuration > 0 ? knownDuration : (itemDuration.isFinite ? itemDuration : 0)
        remainingSeconds = duration > 0 ? max(0, Int(ceil(duration - elapsed))) : 0
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        let watchedTimeInMs = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
        stopPlayback()
        onFinished(watchedTimeInMs)
    }

    private func fail(_ message: String) {
        guard !didFinish else { return }
        didFinish = true
        stopPlayback()
        onFailed(message)
    }
}

struct VendorSessionAdPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView(frame: .zero)
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

struct VendorLaunchPanel<Content: View>: View {
    let title: String
    let subtitle: String
    private let content: Content

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                VendorResourceImage(name: "nv-gfn-logo_v3", fileExtension: "png")
                    .scaledToFit()
                    .frame(width: 108, height: 32, alignment: .leading)
                Spacer()
                Button { } label: {
                    Text("LAUNCH STATUS")
                        .nvidiaFont(size: 10, weight: .bold)
                        .foregroundStyle(OpenNOWDesign.accent)
                        .tracking(1.4)
                }
                .buttonStyle(.plain)
                .disabled(true)
            }
            .padding(.horizontal, 22)
            .frame(height: 58)
            .background(OpenNOWDesign.Surface.chrome)

            VStack(alignment: .leading, spacing: 8) {
                Text(title.uppercased())
                    .nvidiaFont(size: 13, weight: .bold)
                    .foregroundStyle(OpenNOWDesign.accent)
                    .tracking(1.2)
                Text(subtitle.isEmpty ? "GeForce NOW" : subtitle)
                    .nvidiaFont(size: 28, weight: .bold)
                    .foregroundStyle(.white)
                    .lineLimit(2)
            }
            .padding(.horizontal, 26)
            .padding(.top, 24)
            .padding(.bottom, 18)

            content
                .padding(.horizontal, 26)
                .padding(.bottom, 26)
        }
        .frame(minWidth: 360, idealWidth: 640, maxWidth: 640)
        .background(OpenNOWDesign.Surface.app)
        .overlay { Rectangle().stroke(Color.white.opacity(0.14), lineWidth: 1) }
        .shadow(color: .black.opacity(0.55), radius: 28, y: 18)
    }
}

struct VendorLaunchStepHeader: View {
    let index: String
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(index)
                .nvidiaFont(size: 12, weight: .bold)
                .foregroundStyle(.black)
                .frame(width: 26, height: 26)
                .background(OpenNOWDesign.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .nvidiaFont(size: 16, weight: .bold)
                    .foregroundStyle(.white)
                Text(message)
                    .nvidiaFont(size: 12, weight: .medium)
                    .foregroundStyle(.white.opacity(0.70))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct VendorLaunchSessionRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label.uppercased())
                .nvidiaFont(size: 10, weight: .bold)
                .foregroundStyle(.white.opacity(0.48))
                .frame(width: 130, alignment: .leading)
            Text(value.isEmpty ? "-" : value)
                .nvidiaFont(size: 13, weight: .medium)
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(1)
        }
    }
}

struct VendorLaunchInlineMessage: View {
    let message: String
    let warning: Bool

    var body: some View {
        let presentation = CatalogErrorPresentation(rawMessage: message)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.title)
                    .nvidiaFont(size: 12, weight: .bold)
                if let hint = presentation.hint {
                    Text(hint)
                        .nvidiaFont(size: 11, weight: .medium)
                        .foregroundStyle(.white.opacity(0.62))
                }
            }
        }
        .foregroundStyle(warning ? Color.yellow.opacity(0.86) : .white.opacity(0.72))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.045))
        .overlay { Rectangle().stroke(Color.white.opacity(0.08), lineWidth: 1) }
    }
}

struct VendorLaunchPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .nvidiaFont(size: 12, weight: .bold)
            .foregroundStyle(.black)
            .tracking(0.8)
            .padding(.horizontal, 18)
            .frame(height: 38)
            .background(OpenNOWDesign.accent.opacity(configuration.isPressed ? 0.78 : 1.0))
    }
}

struct VendorLaunchSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .nvidiaFont(size: 12, weight: .bold)
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.68 : 0.86))
            .tracking(0.8)
            .padding(.horizontal, 16)
            .frame(height: 38)
            .background(Color.white.opacity(configuration.isPressed ? 0.10 : 0.055))
            .overlay { Rectangle().stroke(Color.white.opacity(0.14), lineWidth: 1) }
    }
}
