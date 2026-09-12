import Combine
import Foundation
import SwiftUI

typealias WebRTCMediaStreamCompletion = WebRTCMediaStreamEndCallback
typealias WebRTCMediaStreamProgressHandler = WebRTCMediaStreamProgressCallback

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
                    stepIndex: model.loadingStepIndex,
                    artworkURL: configuration.loadingArtworkURL
                ) { EmptyView() }
            }
        }
        .background(Color.black)
        .onAppear {
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
