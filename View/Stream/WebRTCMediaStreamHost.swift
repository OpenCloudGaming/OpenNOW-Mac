//  OpenNOW
//
//  Created by OpenCode on 6/16/26.
//

import Combine
import Foundation
import SwiftUI

typealias WebRTCMediaStreamCompletion = WebRTCMediaStreamEndCallback
typealias WebRTCMediaStreamProgressHandler = WebRTCMediaStreamProgressCallback

enum StreamLaunchLoadingStage {
    static func label(stepIndex: Int, queuePosition: Int? = nil) -> String {
        if let queuePosition, queuePosition > 0 { return "Waiting in queue" }
        switch stepIndex {
        case StreamLaunchStep.checkNetworkRoute.rawValue: return "Checking connection"
        case StreamLaunchStep.allocateCloudSession.rawValue: return "Finding a server"
        case StreamLaunchStep.receiveStreamOffer.rawValue: return "Preparing stream"
        case StreamLaunchStep.negotiateWebRTC.rawValue: return "Connecting"
        case StreamLaunchStep.connected.rawValue: return "Ready"
        default: return "Starting"
        }
    }
}

extension StreamLaunchConfiguration {
    var loadingArtworkURL: URL? {
        let urls = (metadata["loadingScreenshotUrls"] ?? "")
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !urls.isEmpty else { return nil }
        let seed = id.uuidString.utf8.reduce(UInt(0)) { ($0 &* 31) &+ UInt($1) }
        return URL(string: urls[Int(seed % UInt(urls.count))])
    }
}

struct StreamLaunchLoadingScreen<Accessory: View>: View {
    let title: String
    let stage: String
    let artworkURL: URL?
    let queuePosition: Int?
    let accessoryPresented: Bool
    let cancelAction: (() -> Void)?
    private let accessory: Accessory

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(title: String,
         stage: String,
         artworkURL: URL?,
         queuePosition: Int? = nil,
         accessoryPresented: Bool = false,
         cancelAction: (() -> Void)? = nil,
         @ViewBuilder accessory: () -> Accessory) {
        self.title = title.isEmpty ? "GeForce NOW" : title
        self.stage = stage
        self.artworkURL = artworkURL
        self.queuePosition = queuePosition
        self.accessoryPresented = accessoryPresented
        self.cancelAction = cancelAction
        self.accessory = accessory()
    }

    var body: some View {
        GeometryReader { proxy in
            let compact = min(proxy.size.width, proxy.size.height) < 620
            ZStack {
                if let artworkURL {
                    AsyncImage(url: artworkURL) { phase in
                        if case .success(let image) = phase {
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: proxy.size.width + 40, height: proxy.size.height + 40)
                                .blur(radius: 30)
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .clipped()
                        }
                    }
                    .transition(.opacity)
                }

                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.54), location: 0),
                        .init(color: .black.opacity(0.20), location: 0.42),
                        .init(color: .black.opacity(0.78), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                RadialGradient(
                    colors: [OpenNOWDesign.accent.opacity(0.18), .clear],
                    center: .center,
                    startRadius: 12,
                    endRadius: compact ? 260 : 480
                )
                .blendMode(.screen)

                VStack(spacing: compact ? 16 : 22) {
                    Spacer(minLength: 24)

                    if accessoryPresented {
                        accessory
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .frame(maxWidth: 920, maxHeight: compact ? 300 : 520)
                    } else {
                        StreamLaunchSignal(reduceMotion: reduceMotion)
                            .frame(width: compact ? 68 : 84, height: compact ? 68 : 84)
                    }

                    VStack(spacing: 8) {
                        Text(title)
                            .font(.nvidia(size: compact ? 24 : 32, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)

                        HStack(spacing: 8) {
                            Circle()
                                .fill(OpenNOWDesign.accent)
                                .frame(width: 6, height: 6)
                                .shadow(color: OpenNOWDesign.accent, radius: 6)
                            Text(stage.uppercased())
                                .font(.nvidia(size: 11, weight: .bold))
                                .tracking(1.5)
                                .foregroundStyle(.white.opacity(0.72))
                        }
                    }

                    if let queuePosition, queuePosition > 0 {
                        Text("Position \(queuePosition)")
                            .font(.nvidia(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, OpenNOWDesign.Spacing.contentVertical)
                            .frame(height: 32)
                            .background(Color.black.opacity(0.48))
                            .overlay { Rectangle().stroke(OpenNOWDesign.accent.opacity(0.38), lineWidth: 1) }
                    }

                    if let cancelAction {
                        Button("Cancel", action: cancelAction)
                            .font(.nvidia(size: 13, weight: .bold))
                            .buttonStyle(.plain)
                            .foregroundStyle(.white.opacity(0.88))
                            .padding(.horizontal, OpenNOWDesign.Spacing.medium)
                            .frame(height: 34)
                            .background(Color.white.opacity(0.08))
                            .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.regular, lineWidth: 1) }
                            .accessibilityLabel("Cancel stream launch")
                    }

                    Spacer(minLength: 24)

                    if !accessoryPresented {
                        VendorIndeterminateProgressBar()
                            .frame(width: compact ? 190 : 280, height: 3)
                            .padding(.bottom, compact ? 22 : 34)
                    }
                }
                .padding(.horizontal, compact ? 22 : 40)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .background(Color.black)
        }
    }
}

private struct StreamLaunchSignal: View {
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation) { timeline in
            let cycle = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
            let rotation = reduceMotion ? 0 : cycle * 360
            ZStack {
                Circle()
                    .fill(OpenNOWDesign.accent.opacity(0.12))
                    .blur(radius: 14)
                Circle()
                    .stroke(.white.opacity(0.15), lineWidth: 1)
                Circle()
                    .trim(from: 0.06, to: 0.70)
                    .stroke(OpenNOWDesign.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(rotation))
                Circle()
                    .trim(from: 0.12, to: 0.42)
                    .stroke(.white.opacity(0.64), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                    .padding(9)
                    .rotationEffect(.degrees(-rotation * 0.72))
                Circle()
                    .fill(OpenNOWDesign.accent)
                    .frame(width: 8, height: 8)
                    .shadow(color: OpenNOWDesign.accent, radius: 8)
            }
        }
    }
}

struct WebRTCMediaStreamView: View {
    let configuration: StreamLaunchConfiguration
    let onProgress: WebRTCMediaStreamProgressHandler?
    let onRequiredSessionAd: (@Sendable (StreamSessionAdPresentation) async throws -> Int)?
    let onEnd: WebRTCMediaStreamCompletion
    private let coordinator: OpenNOWStreamSessionCoordinator

    init(configuration: StreamLaunchConfiguration,
         onProgress: WebRTCMediaStreamProgressHandler?,
         onRequiredSessionAd: (@Sendable (StreamSessionAdPresentation) async throws -> Int)? = nil,
         onEnd: @escaping WebRTCMediaStreamCompletion) {
        self.configuration = configuration
        self.onProgress = onProgress
        self.onRequiredSessionAd = onRequiredSessionAd
        self.onEnd = onEnd
        coordinator = OpenNOWStreamSessionCoordinator(
            adPresenter: InlineStreamSessionAdPresenter(handler: onRequiredSessionAd),
            progressHandler: { progress in
                Task { @MainActor in onProgress?(progress) }
            }
        )
    }

    var body: some View {
        switch Self.selectedTransport(applicationID: configuration.applicationID) {
        case .webRTC:
            WebRTCMediaStreamSurface(
                configuration: configuration,
                sessionProvider: coordinator,
                signaling: coordinator,
                onAntiAFKStateChange: { enabled in OPNStreamPreferences.saveAntiAFKMouseMovementEnabled(enabled) },
                onVideoEnhancementChange: { mode, sharpness, denoise in
                    OPNStreamPreferences.saveUpscalingSettings(mode: mode, sharpness: sharpness, denoise: denoise, forGame: configuration.applicationID)
                },
                preventDisplaySleep: Self.preventDisplaySleepWhileStreaming(applicationID: configuration.applicationID),
                onProgress: { progress in
                    onProgress?(progress)
                },
                onEnd: { success, message, report in
                    onEnd(success, message, report)
                }
            )
        case .nativeNVST:
            NativeNVSTMediaStreamSurface(
                configuration: configuration,
                sessionProvider: coordinator,
                preventDisplaySleep: Self.preventDisplaySleepWhileStreaming(applicationID: configuration.applicationID),
                onProgress: { progress in
                    onProgress?(progress)
                },
                onEnd: { success, message, report in
                    onEnd(success, message, report)
                }
            )
        }
    }

    private static func selectedTransport(applicationID: String) -> OPNSelectedStreamTransport {
        OPNStreamTransportSelector.selectedTransport(forGame: applicationID)
    }

    private static func preventDisplaySleepWhileStreaming(applicationID: String) -> Bool {
        let profile = OPNStreamPreferences.launchProfile(forGame: applicationID, capabilities: OPNStreamPreferences.loadDeviceCapabilities())
        return profile.preventDisplaySleepWhileStreaming
    }
}

private struct NativeNVSTMediaStreamSurface: View {
    let configuration: StreamLaunchConfiguration
    /// Owns the session and everything the HUD does to it. A `@StateObject` on this view, which is
    /// the lifetime the fifty-two `@State` properties it replaced already had - the session must
    /// not outlive this view, and must not be rebuilt while it is on screen.
    @StateObject private var model: NativeNVSTHostViewModel
    @AppStorage(OpenNOWInterfacePreferences.uiScaleKey) private var uiScale = OpenNOWInterfacePreferences.defaultUIScale

    init(
        configuration: StreamLaunchConfiguration,
        sessionProvider: any NativeNVSTSessionProvider,
        preventDisplaySleep: Bool,
        onProgress: WebRTCMediaStreamProgressHandler?,
        onEnd: @escaping WebRTCMediaStreamCompletion
    ) {
        self.configuration = configuration
        _model = StateObject(wrappedValue: NativeNVSTHostViewModel(
            configuration: configuration,
            sessionProvider: sessionProvider,
            preventDisplaySleep: preventDisplaySleep,
            onProgress: onProgress,
            onEnd: onEnd
        ))
    }

    var body: some View {
        ZStack {
            // Deferred by one main-actor turn on purpose. `resolveIfReady` is driven from
            // `updateNSView`, so this callback lands *inside* the SwiftUI update cycle - and every
            // one of these writes is `@Published` now, which makes publishing here undefined
            // behavior ("Publishing changes from within view updates is not allowed"). As `@State`
            // on a struct SwiftUI merely scheduled another pass; on an `ObservableObject` it does
            // not. `resolveIfReady` latches on `didResolve` and `startIfNeeded` has its own guards,
            // so arriving a turn later is safe.
            NativeNVSTStreamHostView { view in
                Task { @MainActor in
                    model.nativeView = view
                    model.configureNativeView(view)
                    model.startIfNeeded()
                }
            }
            .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
            nativeWindowOverlay
            if !model.isConnected {
                StreamLaunchLoadingScreen(
                    title: configuration.title,
                    stage: StreamLaunchLoadingStage.label(stepIndex: model.loadingStepIndex),
                    artworkURL: configuration.loadingArtworkURL
                ) { EmptyView() }
            }
        }
        .background(Color.black)
        .onAppear {
            WebRTCMediaTelemetry.configure(sink: OpenNOWWebRTCMediaTelemetrySink())
            model.startIfNeeded()
        }
        .task { await model.pollControllerBatteries() }
        .onDisappear { model.stopStream() }
        .sheet(isPresented: $model.showingControllerMapping) {
            SteamControllerMappingView()
        }
    }

    @ViewBuilder private var nativeWindowOverlay: some View {
        ZStack(alignment: .topLeading) {
            if model.nativeStatsVisible && !model.streamControlsVisible { nativeStatsHUD.allowsHitTesting(false) }
            if model.unifiedHUDVisible {
                ZStack {
                    Color.black.opacity(0.001)
                        .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
                        .onTapGesture {}
                    nativeUnifiedHUD
                }
            }
            if model.onScreenKeyboardVisible { StreamOnScreenKeyboardOverlay(controller: model.onScreenKeyboard) }
            if model.streamControlsVisible { nativeStreamControlsOverlay }
            if !model.networkPathAvailable && !model.streamControlsVisible { nativeNetworkRecoveryOverlay }
            if !model.transientStreamMessage.isEmpty { nativeTransientStreamMessageOverlay.allowsHitTesting(false) }
        }
        .opnInterfaceScale(uiScale)
    }

    private var nativeNetworkRecoveryOverlay: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea(.container, edges: [.horizontal, .bottom])
            VStack(spacing: 14) {
                ProgressView().controlSize(.large).tint(WebRTCMediaStreamTheme.accent)
                Text("CONNECTION INTERRUPTED")
                    .font(.streamNvidia(size: 16, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(WebRTCMediaStreamTheme.accent)
                Text("Waiting for a usable network path. OpenNOW will resume the same GeForce NOW session automatically.")
                    .font(.streamNvidia(size: 12, weight: .medium))
                    .foregroundStyle(WebRTCMediaStreamTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                Button("End Stream", action: model.endFromStreamControls)
                    .buttonStyle(.bordered)
            }
            .padding(30)
            .background(WebRTCMediaStreamTheme.panel.opacity(0.96))
            .overlay(Rectangle().stroke(WebRTCMediaStreamTheme.accent.opacity(0.4), lineWidth: 1))
        }
    }

    private var nativeTransientStreamMessageOverlay: some View {
        Text(model.transientStreamMessage)
            .font(.streamNvidia(size: 12, weight: .bold))
            .foregroundStyle(WebRTCMediaStreamTheme.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.86))
            .overlay(Rectangle().stroke(WebRTCMediaStreamTheme.accent.opacity(0.55), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 24)
            .allowsHitTesting(false)
    }

    private var nativeStatsHUD: some View {
        let profile = OPNStreamPreferences.launchProfile(forGame: configuration.applicationID, capabilities: OPNStreamPreferences.loadDeviceCapabilities())
        let streamFramesPerSecond = model.latestNativeStats?.streamFramesPerSecond ?? Double(profile.fps)
        let resolution = nonEmptyNativeStat(model.latestNativeStats?.resolution, fallback: "\(profile.resolution.width)x\(profile.resolution.height)")
        let codec = nonEmptyNativeStat(model.latestNativeStats?.codec, fallback: "--")
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                nativeStatsCompactBox(value: nativeLiveStatsWholeNumber(model.latestNativeStats?.gameFramesPerSecond), label: "GAME FPS", color: nativeGameFPSColor(target: streamFramesPerSecond))
                nativeStatsVerticalDivider
                nativeStatsCompactBox(value: nativeStatsWholeNumber(streamFramesPerSecond), label: "STREAM FPS", color: WebRTCMediaStreamTheme.textPrimary)
                nativeStatsVerticalDivider
                nativeStatsCompactBox(value: nativeLiveStatsWholeNumber(model.latestNativeStats?.latencyMilliseconds), label: "MS", color: nativeLatencyColor)
            }
            .frame(height: 48)

            nativeStatsHorizontalDivider

            VStack(alignment: .leading, spacing: 5) {
                nativeStatsStandardRow(label: "Frame Loss", value: nativeStatsCount(model.latestNativeStats?.frameLoss), detail: nativeStatsTotal(model.latestNativeStats?.totalFrameLoss), color: nativeFrameLossColor)
                // Percent over the last interval, matching what the WebRTC HUD shows; the running
                // count stays alongside it as the detail.
                nativeStatsStandardRow(label: "Packet Loss", value: nativeStatsPercentage(model.latestNativeStats?.packetLossPercent), detail: nativeStatsTotal(model.latestNativeStats?.totalPacketLoss), color: nativePacketLossColor)
                nativeStatsStandardRow(label: "Bandwidth Used", value: nativeStatsMegabits(model.latestNativeStats?.bitrateMegabitsPerSecond), detail: "Mbps", color: WebRTCMediaStreamTheme.textPrimary)
                nativeStatsStandardRow(label: "Jitter", value: nativeStatsMilliseconds(model.latestNativeStats?.jitterMilliseconds), detail: "ms", color: WebRTCMediaStreamTheme.textPrimary)
                // Client-side decode cost. It used to occupy the MS box, where it read as network
                // latency and was not one.
                nativeStatsStandardRow(label: "Decode", value: nativeStatsMilliseconds(model.latestNativeStats?.decodeMilliseconds), detail: "ms", color: WebRTCMediaStreamTheme.textPrimary)
                nativeStatsStandardRow(label: "Transport", value: "Native NVST", detail: nil, color: OpenNOWDesign.accent)
                nativeStatsStandardRow(label: "Resolution", value: resolution, detail: nil, color: WebRTCMediaStreamTheme.textPrimary)
                nativeStatsStandardRow(label: "Codec", value: codec, detail: nil, color: WebRTCMediaStreamTheme.textPrimary)
                nativeStatsStandardRow(label: "Server Location", value: nonEmptyNativeStat(model.latestNativeStats?.serverLocation, fallback: "--"), detail: nil, color: WebRTCMediaStreamTheme.textPrimary)
            }
        }
        .padding(10)
        .frame(width: 264, alignment: .topLeading)
        .background(Color.black.opacity(0.90))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(WebRTCMediaStreamTheme.accent)
                .frame(height: 2)
        }
        .overlay(Rectangle().stroke(.white.opacity(0.16), lineWidth: 1))
        .shadow(color: .black.opacity(0.52), radius: 16, x: 0, y: 8)
        .padding([.top, .trailing], OpenNOWDesign.Spacing.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .allowsHitTesting(false)
    }

    private func nativeStatsCompactBox(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.streamNvidia(size: 22, weight: .bold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
            Text(label)
                .font(.streamNvidia(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(WebRTCMediaStreamTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.055))
    }

    private var nativeStatsVerticalDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.18))
            .frame(width: 1)
            .padding(.vertical, 4)
    }

    private var nativeStatsHorizontalDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.18))
            .frame(height: 1)
    }

    private func nativeStatsStandardRow(label: String, value: String, detail: String?, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.streamNvidia(size: 10, weight: .medium))
                .foregroundStyle(WebRTCMediaStreamTheme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(value)
                .font(.streamNvidia(size: 10, weight: .bold))
                .foregroundStyle(color)
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(.streamNvidia(size: 10, weight: .medium))
                    .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    private func nativeGameFPSColor(target: Double) -> Color {
        guard let latestNativeStats = model.latestNativeStats, latestNativeStats.available, latestNativeStats.gameFramesPerSecond >= 0 else { return WebRTCMediaStreamTheme.textTertiary }
        return latestNativeStats.gameFramesPerSecond >= max(1, target * 0.9) ? WebRTCMediaStreamTheme.accent : WebRTCMediaStreamTheme.warning
    }

    private var nativeLatencyColor: Color {
        guard let latestNativeStats = model.latestNativeStats, latestNativeStats.available, latestNativeStats.latencyMilliseconds >= 0 else { return WebRTCMediaStreamTheme.textTertiary }
        if latestNativeStats.latencyMilliseconds >= 120 { return WebRTCMediaStreamTheme.danger }
        if latestNativeStats.latencyMilliseconds >= 90 { return WebRTCMediaStreamTheme.warning }
        return WebRTCMediaStreamTheme.accent
    }

    private var nativeFrameLossColor: Color {
        guard let latestNativeStats = model.latestNativeStats, latestNativeStats.available else { return WebRTCMediaStreamTheme.textTertiary }
        return latestNativeStats.frameLoss == 0 ? WebRTCMediaStreamTheme.accent : WebRTCMediaStreamTheme.warning
    }

    private var nativePacketLossColor: Color {
        guard let latestNativeStats = model.latestNativeStats, latestNativeStats.available else { return WebRTCMediaStreamTheme.textTertiary }
        return latestNativeStats.packetLossPercent <= 0 ? WebRTCMediaStreamTheme.accent : WebRTCMediaStreamTheme.warning
    }

    private func nativeStatsWholeNumber(_ value: Double?) -> String {
        guard let value, value >= 0 else { return "--" }
        return String(format: "%.0f", value)
    }

    private func nativeLiveStatsWholeNumber(_ value: Double?) -> String {
        guard model.latestNativeStats?.available == true else { return "--" }
        return nativeStatsWholeNumber(value)
    }

    private func nativeStatsCount(_ value: UInt64?) -> String {
        guard model.latestNativeStats?.available == true, let value else { return "--" }
        return String(value)
    }

    private func nativeStatsTotal(_ value: UInt64?) -> String {
        guard model.latestNativeStats?.available == true, let value else { return "(-- Total)" }
        return "(\(value) Total)"
    }

    private func nativeStatsPercentage(_ value: Double?) -> String {
        guard model.latestNativeStats?.available == true, let value, value >= 0 else { return "--" }
        return String(format: "%.1f%%", value)
    }

    /// Sub-millisecond values are the normal case for decode, so one decimal rather than none.
    private func nativeStatsMilliseconds(_ value: Double?) -> String {
        guard model.latestNativeStats?.available == true, let value, value >= 0 else { return "--" }
        return String(format: "%.1f", value)
    }

    private func nativeStatsMegabits(_ value: Double?) -> String {
        guard model.latestNativeStats?.available == true, let value, value >= 0 else { return "--" }
        return String(format: "%.1f", value)
    }

    private func nonEmptyNativeStat(_ value: String?, fallback: String) -> String {
        guard let value, !value.isEmpty else { return fallback }
        return value
    }

    private var nativeMicrophoneStatusText: String {
        guard model.microphoneAvailable else { return "Disabled" }
        if model.microphoneMode == "push-to-talk" { return model.microphoneEnabled ? "PTT Active" : "PTT Ready" }
        if model.microphoneMode == "voice-activity", model.microphoneEnabled { return "Voice Activity" }
        return model.microphoneEnabled ? "On" : "Muted"
    }

    private func nativeSessionLimitText(at date: Date) -> String {
        guard let sessionLimit = model.sessionLimit else { return "Unlimited" }
        let remainingSeconds = sessionLimit.remainingSeconds(at: date)
        return String(format: "%d:%02d", remainingSeconds / 60, remainingSeconds % 60)
    }

    private func nativeSessionLimitIsHealthy(at date: Date) -> Bool {
        guard let sessionLimit = model.sessionLimit else { return true }
        return sessionLimit.remainingSeconds(at: date) > 300
    }

    private var nativeNetworkHealthText: String {
        guard model.latestNativeStats?.available == true else { return "Waiting" }
        if (model.latestNativeStats?.packetLoss ?? 0) > 0 || (model.latestNativeStats?.jitterMilliseconds ?? 0) >= 35 || (model.latestNativeStats?.latencyMilliseconds ?? 0) >= 120 { return "Poor" }
        if (model.latestNativeStats?.jitterMilliseconds ?? 0) >= 20 || (model.latestNativeStats?.latencyMilliseconds ?? 0) >= 90 { return "Fair" }
        return "Good"
    }

    private var nativeNetworkHealthIsGood: Bool {
        nativeNetworkHealthText == "Good"
    }

    private var nativeLatencyText: String {
        guard model.latestNativeStats?.available == true, let latency = model.latestNativeStats?.latencyMilliseconds, latency >= 0 else { return "--" }
        return "\(Int(latency.rounded())) ms"
    }

    private var nativePacketLossText: String {
        guard model.latestNativeStats?.available == true, let packetLoss = model.latestNativeStats?.packetLoss else { return "--" }
        return String(packetLoss)
    }

    private var nativeNetworkWarningText: String {
        guard model.latestNativeStats?.available == true else { return "Waiting for native NVST network telemetry." }
        if (model.latestNativeStats?.packetLoss ?? 0) > 0 { return "Packet loss is active; image quality or input response may degrade." }
        if (model.latestNativeStats?.latencyMilliseconds ?? 0) >= 120 { return "Latency is high; input may feel delayed." }
        if (model.latestNativeStats?.jitterMilliseconds ?? 0) >= 35 { return "Network jitter is unstable; gameplay may stutter." }
        if let bitrate = model.latestNativeStats?.bitrateMegabitsPerSecond, bitrate >= 0, bitrate < 5 { return "Inbound bitrate is low for cloud gaming quality." }
        return ""
    }

    private var nativeUnifiedHUD: some View {
        StreamUnifiedSidebar(title: configuration.title.isEmpty ? "GeForce NOW" : configuration.title, closeAction: { model.setUnifiedHUDVisible(false) }) {
            VStack(alignment: .leading, spacing: 14) {
                nativeHUDStatusPanel
                nativeHUDControlsPanel
                nativeHUDNetworkPanel
                if model.sidebarCapabilities.visibleFeatures.contains(.remoteCoOp), model.remoteCoOpPreferences.isAlphaOptedIn {
                    nativeHUDRemoteCoOpPanel
                }
                nativeHUDVideoPanel
            }
        }
    }

    private var nativeHUDStatusPanel: some View {
        StreamHUDWrappingRow(minimumItemWidth: 84) {
            StreamHUDMetricCard(title: "Mic", value: nativeMicrophoneStatusText, positive: model.microphoneEnabled && model.microphoneAvailable)
            StreamHUDMetricCard(title: "Rec", value: "Unavailable", positive: false)
            StreamHUDMetricCard(title: "AFK", value: model.antiAFKMouseMovementEnabled ? "On" : "Off", positive: model.antiAFKMouseMovementEnabled)
            if model.sessionLimit != nil {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    StreamHUDMetricCard(title: "Session", value: nativeSessionLimitText(at: context.date), positive: nativeSessionLimitIsHealthy(at: context.date))
                }
            }
            if model.remoteCoOpPreferences.isAlphaOptedIn {
                StreamHUDMetricCard(title: "Co-Op", value: "Unavailable", positive: false)
            }
            ForEach(model.controllerBatteries.sorted { $0.label < $1.label }) { battery in
                StreamHUDBatteryCard(label: battery.label, level: battery.level, charging: battery.charging)
            }
        }
    }

    /// Fixed rows of at most 4 buttons each, rather than the grid's adaptive wrap — the wrap could
    /// pack 5 across on a wide sidebar (as seen with all 7 buttons: 5 then a stray 2), which reads
    /// as an uneven long row instead of a deliberate grid.
    /// Fixed 4 columns, not an adaptive wrap - the adaptive grid could pack 5 across on a wide
    /// sidebar (5 then a stray 2 for these 7 buttons), which reads as an uneven long row instead of
    /// a deliberate grid.
    private static let nativeHUDControlsColumns = Array(repeating: GridItem(.fixed(42), spacing: 8), count: 4)

    private var nativeHUDControlsPanel: some View {
        StreamHUDSection(label: "CONTROLS", spacing: 8) {
            LazyVGrid(columns: Self.nativeHUDControlsColumns, alignment: .leading, spacing: 8) {
                StreamHUDActionRow(
                    title: model.microphoneEnabled ? "Mute microphone" : "Unmute microphone",
                    subtitle: nativeMicrophoneStatusText,
                    systemName: model.microphoneEnabled ? "mic.slash.fill" : "mic.fill",
                    isActive: model.microphoneEnabled && model.microphoneAvailable,
                    isDisabled: !model.sidebarCapabilities.supports(.microphone) || !model.microphoneAvailable || model.microphoneUpdateTask != nil,
                    isFocused: model.hudFocusID == "microphone",
                    action: model.toggleNativeMicrophone
                )
                StreamHUDActionRow(
                    title: "Record",
                    subtitle: "Unavailable with native NVST",
                    systemName: "record.circle",
                    isActive: false,
                    isDisabled: !model.sidebarCapabilities.supports(.recording),
                    action: {}
                )
                StreamHUDActionRow(
                    title: model.pointerLocked ? "Release Mouse" : "Capture Mouse",
                    subtitle: model.pointerLocked ? "Pointer locked" : "Click stream also captures",
                    systemName: model.pointerLocked ? "cursorarrow.slash" : "cursorarrow.click",
                    isActive: model.pointerLocked,
                    isDisabled: !model.isConnected || model.nativeView?.directMouseInputEnabled != true,
                    isFocused: model.hudFocusID == "pointer",
                    action: model.toggleNativePointerLock
                )
                StreamHUDActionRow(
                    title: model.antiAFKMouseMovementEnabled ? "Disable Anti-AFK" : "Enable Anti-AFK",
                    subtitle: model.antiAFKMouseMovementEnabled ? "Active" : "Idle",
                    systemName: "cursorarrow.motionlines",
                    isActive: model.antiAFKMouseMovementEnabled,
                    isDisabled: !model.sidebarCapabilities.supports(.antiAFK) || !model.isConnected,
                    isFocused: model.hudFocusID == "anti-afk",
                    action: model.toggleNativeAntiAFKMouseMovement
                )
                StreamHUDActionRow(
                    title: model.nativeStatsVisible ? "Hide Floating Stats" : "Show Floating Stats",
                    subtitle: "Detailed overlay",
                    systemName: "chart.line.uptrend.xyaxis",
                    isActive: model.nativeStatsVisible,
                    isDisabled: !model.sidebarCapabilities.supports(.floatingStats),
                    isFocused: model.hudFocusID == "floating-stats",
                    action: model.toggleNativeStatsHUD
                )
                StreamHUDActionRow(
                    title: "Controller Mapping",
                    subtitle: "Steam Controller grip binds",
                    systemName: "gamecontroller",
                    isActive: false,
                    isDisabled: false,
                    isFocused: model.hudFocusID == "controller-mapping",
                    action: { model.showingControllerMapping = true }
                )
                StreamHUDActionRow(
                    title: "Quit Menu",
                    subtitle: "End session",
                    systemName: "power",
                    isActive: false,
                    isDisabled: false,
                    isFocused: model.hudFocusID == "quit",
                    action: { model.showStreamControls() }
                )
            }
        }
    }

    private var nativeHUDNetworkPanel: some View {
        StreamHUDSection(label: "NETWORK", spacing: 8) {
            StreamHUDWrappingRow(minimumItemWidth: 84) {
                StreamHUDMetricCard(title: "Health", value: nativeNetworkHealthText, positive: nativeNetworkHealthIsGood)
                StreamHUDMetricCard(title: "Latency", value: nativeLatencyText, positive: (model.latestNativeStats?.latencyMilliseconds ?? 0) < 90)
                StreamHUDMetricCard(title: "Loss", value: nativePacketLossText, positive: (model.latestNativeStats?.packetLoss ?? 0) == 0)
            }
            if !nativeNetworkWarningText.isEmpty {
                Text(nativeNetworkWarningText)
                    .font(.streamNvidia(size: 11, weight: .medium))
                    .foregroundStyle(WebRTCMediaStreamTheme.warning)
                    .lineLimit(2)
            }
        }
    }

    private var nativeHUDRemoteCoOpPanel: some View {
        StreamHUDSection(label: "CO-OP", spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Remote Co-Op")
                            .font(.streamNvidia(size: 14, weight: .bold))
                            .foregroundStyle(WebRTCMediaStreamTheme.textPrimary)
                        Text("Video and audio relay require WebRTC transport.")
                            .font(.streamNvidia(size: 11, weight: .medium))
                            .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Text("NVST")
                        .font(.streamNvidia(size: 9, weight: .bold))
                        .tracking(0.7)
                        .foregroundStyle(WebRTCMediaStreamTheme.warning)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(Color.white.opacity(0.07))
                        .overlay { Rectangle().stroke(WebRTCMediaStreamTheme.divider, lineWidth: 1) }
                }
                StreamHUDActionRow(
                    title: "Create Invite",
                    subtitle: "Unavailable with native NVST",
                    systemName: "person.badge.plus",
                    isActive: false,
                    isDisabled: !model.sidebarCapabilities.supports(.remoteCoOp),
                    action: {}
                )
                nativeHUDDetailRow(label: "Slots", value: "\(model.remoteCoOpPreferences.effectiveReservedGuestSlots)")
                nativeHUDDetailRow(label: "Quality", value: model.remoteCoOpPreferences.qualityPreset.label)
                nativeHUDDetailRow(label: "Latency", value: model.remoteCoOpPreferences.latencyMode.label)
            }
        }
    }

    /// Split into two boxes, matching how every other HUD group (MIC/REC/AFK, NETWORK) already
    /// separates itself: one for controls you change, one for the stream's own read-only facts.
    /// Previously this was one flat "VIDEO" box mixing both, with a static "Target" info row that
    /// duplicated (and could visibly contradict) the "Target Resolution" control above it.
    private var nativeHUDVideoPanel: some View {
        Group {
            nativeHUDUpscalingPanel
            nativeHUDStreamInfoPanel
        }
    }

    private var nativeHUDUpscalingPanel: some View {
        StreamHUDSection(label: "UPSCALING") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Upscaling", selection: Binding(
                    get: { OPNStreamPreferences.upscalingModeOptions[model.upscalingModeIndex].value },
                    set: { model.updateNativeUpscalingTier(value: $0) }
                )) {
                    // Display order is independent of the stored option array's order, which
                    // stays fixed for backward compatibility.
                    ForEach(NativeNVSTHostViewModel.upscalingTierDisplayOrder, id: \.value) { tier in
                        Text(tier.label).tag(tier.value)
                    }
                }
                .font(.streamNvidia(size: 12, weight: .medium))
                .pickerStyle(.segmented)
                .tint(WebRTCMediaStreamTheme.accent)
                .disabled(!model.sidebarCapabilities.supports(.videoEnhancement))
                .hudFocusRing(model.hudFocusID == "upscaling-tier")
                StreamHUDDropdown(
                    label: "Target Resolution",
                    options: Array(OPNStreamPreferences.upscalingTargetOptions.enumerated().map { ($0.offset, $0.element.label) }),
                    selection: model.upscalingTargetIndex,
                    isDisabled: !model.isConnected || model.upscalingModeIndex == 0 || !model.sidebarCapabilities.supports(.videoEnhancement),
                    onSelect: { model.updateNativeUpscalingTarget(targetIndex: $0) },
                    isFocused: model.hudFocusID == "upscaling-target"
                )
                nativeHUDSliderRow("Clarity", value: model.upscalingSharpness, range: 0...15, isFocused: model.hudFocusID == "clarity") { model.updateNativeUpscalingClarity(sharpness: $0) }
                nativeHUDSliderRow("Noise Reduction", value: model.upscalingDenoise, range: 0...20, isFocused: model.hudFocusID == "noise-reduction") { model.updateNativeUpscalingClarity(denoise: $0) }
            }
        }
    }

    private var nativeHUDStreamInfoPanel: some View {
        StreamHUDSection(label: "STREAM") {
            VStack(alignment: .leading, spacing: 10) {
                StreamHUDDropdown(
                    label: "Pillarbox Fill",
                    options: OPNPillarboxFillMode.pickerCases.map { ($0.rawValue, $0.label) },
                    selection: model.pillarboxFillModeIndex,
                    isDisabled: !model.isConnected,
                    onSelect: { model.updateNativePillarboxFill(modeIndex: $0) },
                    isFocused: model.hudFocusID == "pillarbox-fill"
                )
                nativeHUDDetailRow(label: "Active", value: model.upscalingModeIndex == 0 ? "Native" : OPNStreamPreferences.upscalingModeOptions[model.upscalingModeIndex].label)
                nativeHUDDetailRow(label: "Resolution", value: model.nativeStreamResolutionText)
                nativeHUDDetailRow(label: "Frame Rate", value: model.nativeStreamFrameRateText)
                nativeHUDDetailRow(label: "Codec", value: model.nativeStreamCodecText)
            }
        }
    }

    private func nativeHUDSliderRow(_ label: String, value: Int, range: ClosedRange<Int>, isFocused: Bool = false, action: @escaping (Int) -> Void) -> some View {
        StreamHUDSliderRow(
            label: label,
            value: value,
            range: range,
            isDisabled: !model.isConnected || model.upscalingModeIndex == 0 || !model.sidebarCapabilities.supports(.videoEnhancement),
            isFocused: isFocused,
            action: action
        )
    }

    private func nativeHUDDetailRow(label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.streamNvidia(size: 11, weight: .medium))
                .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
            Spacer(minLength: 8)
            Text(value)
                .font(.streamNvidia(size: 11, weight: .bold))
                .foregroundStyle(WebRTCMediaStreamTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var nativeStreamControlsOverlay: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.54))
                .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("STREAM PAUSED")
                        .font(.streamNvidia(size: 10, weight: .bold))
                        .tracking(1.1)
                        .foregroundStyle(WebRTCMediaStreamTheme.accent)
                    Text(configuration.title.isEmpty ? "GeForce NOW" : configuration.title)
                        .font(.streamNvidia(size: 20, weight: .bold))
                        .foregroundStyle(WebRTCMediaStreamTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 22)
                .padding(.top, 16)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(WebRTCMediaStreamTheme.appBar)
                Rectangle()
                    .fill(WebRTCMediaStreamTheme.divider)
                    .frame(height: 1)
                VStack(alignment: .leading, spacing: 16) {
                    Text("Dismiss this overlay to resume input, pause the session, or quit the stream. Remote input is paused while this menu is open.")
                        .font(.streamNvidia(size: 12, weight: .medium))
                        .foregroundStyle(WebRTCMediaStreamTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        StreamQuitMenuButton(
                            title: "Resume",
                            isPrimary: true,
                            isFocused: model.streamControlsFocusIndex == 0,
                            isDisabled: model.isEnding,
                            action: model.dismissStreamControls
                        )
                        .keyboardShortcut(.cancelAction)
                        StreamQuitMenuButton(
                            title: "Pause Stream",
                            isPrimary: false,
                            isFocused: model.streamControlsFocusIndex == 1,
                            isDisabled: model.isEnding,
                            action: model.pauseFromStreamControls
                        )
                        StreamQuitMenuButton(
                            title: model.isEnding ? "Quitting..." : (model.pendingApplicationQuitCompletion == nil ? "End Stream" : "Quit OpenNOW"),
                            isPrimary: false,
                            isFocused: model.streamControlsFocusIndex == 2,
                            isDisabled: model.isEnding,
                            action: model.endFromStreamControls
                        )
                    }
                    Text("\(WebRTCMediaStreamCommand.shortcutGuide)   Esc Resume")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.36))
                }
                .padding(18)
            }
            .frame(width: 440)
            .background(WebRTCMediaStreamTheme.panel.opacity(0.985))
            .overlay {
                Rectangle()
                    .stroke(WebRTCMediaStreamTheme.accent.opacity(0.28), lineWidth: 1)
            }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(WebRTCMediaStreamTheme.accent)
                    .frame(height: 2)
            }
            .shadow(color: .black.opacity(0.58), radius: 28, x: 0, y: 20)
        }
    }

}

private struct NativeNVSTStreamHostView: NSViewRepresentable {
    let onResolve: @MainActor (NativeWebRTCStreamView) -> Void

    func makeNSView(context: Context) -> NativeNVSTSurfaceContainerView {
        let view = NativeNVSTSurfaceContainerView(frame: .zero)
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: NativeNVSTSurfaceContainerView, context: Context) {
        nsView.onResolve = onResolve
        nsView.resolveIfReady()
    }

    static func dismantleNSView(_ nsView: NativeNVSTSurfaceContainerView, coordinator: ()) {
        nsView.streamView.remoteInputEnabled = false
        nsView.streamView.setPointerLocked(false)
        nsView.streamView.onInputEvent = nil
        nsView.streamView.onAbsoluteMouseMove = nil
        nsView.streamView.onGamepadTopologyChanged = nil
        nsView.streamView.onPointerLockChanged = nil
        nsView.streamView.onCommand = nil
        nsView.streamView.shouldHandleCommand = nil
        nsView.onResolve = nil
    }

    final class NativeNVSTSurfaceContainerView: NSView {
        let streamView = NativeWebRTCStreamView(frame: .zero)
        var onResolve: (@MainActor (NativeWebRTCStreamView) -> Void)?
        private var didResolve = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            addSubview(streamView)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resolveIfReady()
        }

        override func layout() {
            super.layout()
            streamView.frame = bounds
            resolveIfReady()
        }

        func resolveIfReady() {
            streamView.frame = bounds
            guard !didResolve, window != nil, bounds.width >= 1, bounds.height >= 1, let onResolve else { return }
            didResolve = true
            onResolve(streamView)
        }
    }

    final class NativeNVSTOverlayHostingView: NSHostingView<AnyView> {
        var capturesInput = false

        override func hitTest(_ point: NSPoint) -> NSView? {
            capturesInput ? super.hitTest(point) : nil
        }
    }
}

private struct InlineStreamSessionAdPresenter: StreamSessionAdPresenter {
    let handler: (@Sendable (StreamSessionAdPresentation) async throws -> Int)?

    func playRequiredSessionAd(_ ad: StreamSessionAdPresentation) async throws -> Int {
        guard let handler else {
            throw OpenNOWStreamSessionError.sessionAllocationFailed("Required ad playback is not available.")
        }
        return try await handler(ad)
    }
}
