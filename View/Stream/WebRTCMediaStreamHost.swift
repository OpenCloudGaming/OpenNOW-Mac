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

    @Environment(\.accessibilityReduceMotion) var reduceMotion

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

struct NativeNVSTMediaStreamSurface: View {
    let configuration: StreamLaunchConfiguration
    /// Owns the session and everything the HUD does to it. A `@StateObject` on this view, which is
    /// the lifetime the fifty-two `@State` properties it replaced already had - the session must
    /// not outlive this view, and must not be rebuilt while it is on screen.
    @StateObject var model: NativeNVSTHostViewModel
    @AppStorage(OpenNOWInterfacePreferences.uiScaleKey) var uiScale = OpenNOWInterfacePreferences.defaultUIScale

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

    @ViewBuilder var nativeWindowOverlay: some View {
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
