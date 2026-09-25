import Combine
import Foundation
import SwiftUI

struct StreamHostView: View {
    let configuration: StreamLaunchConfiguration
    let onProgress: StreamProgressHandler?
    let onEnd: StreamCompletionHandler
    private let coordinator: OPNStreamSessionCoordinator

    init(configuration: StreamLaunchConfiguration,
         onProgress: StreamProgressHandler?,
         onRequiredSessionAd: (@Sendable (StreamSessionAdPresentation) async throws -> Int)? = nil,
         onEnd: @escaping StreamCompletionHandler) {
        self.configuration = configuration
        self.onProgress = onProgress
        self.onEnd = onEnd
        coordinator = OPNStreamSessionCoordinator(
            adPresenter: InlineStreamSessionAdPresenter(handler: onRequiredSessionAd),
            progressHandler: { progress in
                Task { @MainActor in onProgress?(progress) }
            }
        )
    }

    var body: some View {
        NativeNVSTMediaStreamSurface(
            configuration: configuration,
            sessionProvider: coordinator,
            preventDisplaySleep: Self.preventDisplaySleepWhileStreaming(applicationID: configuration.applicationID),
            onProgress: onProgress,
            onEnd: onEnd
        )
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
    @AppStorage(OPNInterfacePreferences.uiScaleKey) var uiScale = OPNInterfacePreferences.defaultUIScale
    /// Internal, not private: the section stack that reads and clears these lives in the HUD files.
    @State var hudSectionDropTarget: OPNStreamHUDSection?
    @State var isDropTargetingSectionsEnd = false

    init(
        configuration: StreamLaunchConfiguration,
        sessionProvider: any NativeNVSTSessionProvider,
        preventDisplaySleep: Bool,
        onProgress: StreamProgressHandler?,
        onEnd: @escaping StreamCompletionHandler
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
            ControllerMappingView()
        }
        .sheet(isPresented: $model.showingControllerOrder) {
            ControllerOrderView()
        }
    }

    @ViewBuilder var nativeWindowOverlay: some View {
        ZStack(alignment: .topLeading) {
            if model.nativeStatsVisible && !model.streamControlsVisible { nativeStatsHUD.allowsHitTesting(false) }
            // Presentation is decided here rather than nested inside one `if` so the tap-catcher
            // and the dock carry separate transitions: a conditional ancestor animates as one
            // block, and the invisible catcher would slide in with the drawer.
            if model.unifiedHUDVisible {
                Color.black.opacity(0.001)
                    .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
                    .onTapGesture {}
                    .opnTransition(.opacity)
                nativeUnifiedHUD
                    .opnTransition(.move(edge: .leading).combined(with: .opacity))
            }
            if model.onScreenKeyboardVisible { StreamOnScreenKeyboardOverlay(controller: model.onScreenKeyboard) }
            if model.streamControlsVisible { nativeStreamControlsOverlay }
            if model.isShortcutsHelpVisible { nativeShortcutsHelpOverlay }
            if model.isHUDCustomizeVisible { nativeHUDCustomizeOverlay }
            if !model.networkPathAvailable && !model.streamControlsVisible { nativeNetworkRecoveryOverlay }
            if !model.transientStreamMessage.isEmpty { nativeTransientStreamMessageOverlay.allowsHitTesting(false) }
        }
        .opnMotion(OPNDesign.Motion.panel, value: model.nativeStatsVisible)
        .opnMotion(OPNDesign.Motion.panel, value: model.unifiedHUDVisible)
        .opnMotion(OPNDesign.Motion.panel, value: model.streamControlsVisible)
        .opnMotion(OPNDesign.Motion.panel, value: model.isShortcutsHelpVisible)
        .opnMotion(OPNDesign.Motion.panel, value: model.isHUDCustomizeVisible)
        .opnInterfaceScale(uiScale)
    }

}

private struct NativeNVSTStreamHostView: NSViewRepresentable {
    let onResolve: @MainActor (NativeStreamView) -> Void

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
        let streamView = NativeStreamView(frame: .zero)
        var onResolve: (@MainActor (NativeStreamView) -> Void)?
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
            throw OPNStreamSessionError.sessionAllocationFailed("Required ad playback is not available.")
        }
        return try await handler(ad)
    }
}
