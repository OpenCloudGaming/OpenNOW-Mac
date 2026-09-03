import Combine
import AppKit
import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LoginAccount.lastLoginAt, order: .reverse) private var accounts: [LoginAccount]
    @Query(sort: \LoginSession.issuedAt, order: .reverse) private var sessions: [LoginSession]
    @Query private var devices: [LoginDeviceRegistration]

    @StateObject private var viewModel = LoginViewModel()
    /// Owns the bootstrap, the startup animation's lifetime, the window title, and the file-open
    /// notification observer that used to be subscribed from inside `body`.
    @StateObject private var root = AppRootViewModel()
    @AppStorage(OpenNOWInterfacePreferences.uiScaleKey) private var uiScale = OpenNOWInterfacePreferences.defaultUIScale

    var body: some View {
        ZStack {
            LoginView(viewModel: viewModel, accounts: accounts) { title in
                root.setWindowTitle(title)
            }
            .accessibilityHidden(root.isShowingStartupLoading)

            // Above the catalog and the stream surface, below the startup splash: an update prompt
            // must never cover the launch animation, and must never be covered by a game.
            OpenNOWUpdateOverlay()
                .zIndex(90)

            if root.isShowingStartupLoading {
                OpenNOWStartupLoadingView(duration: root.startupAnimationDuration)
                    .transition(.opacity)
                    .zIndex(100)
            }
        }
            // Replaces the `withAnimation(.easeInOut(duration:))` that used to wrap the dismissal.
            // Same curve and duration, scoped to the container holding the overlay rather than to
            // the whole root, so an unrelated LoginView change in the same transaction is not
            // swept into it.
            .animation(.easeInOut(duration: OpenNOWStartupAnimation.fadeDuration), value: root.isShowingStartupLoading)
            // Keep the floor low enough for Split View tiles and forced frames:
            // when macOS sizes the window below the SwiftUI minimum, content
            // pins at that minimum and the trailing edge (header avatar, the
            // controller actions sidebar) gets clipped instead of adapting.
            .frame(minWidth: 640, minHeight: 480)
            .frame(idealWidth: 1200, idealHeight: 720)
            .ignoresSafeArea()
            .background(WindowTitleConfigurator(title: root.windowTitle))
            .background(OpenNOWInterfaceScaleDensityBooster(scale: uiScale))
            .environment(\.opnUIScale, uiScale)
            .onDisappear { root.unbind() }
            // Binding happens inside the bootstrap, not in an `onAppear`: SwiftUI starts a `.task`
            // before it calls `onAppear`, so the two would race.
            .task {
                await root.bootstrapIfNeeded(login: viewModel, syncModelState: syncViewModel)
            }
            .onChange(of: accounts.count) { _, _ in syncViewModel() }
            .onChange(of: sessions.count) { _, _ in syncViewModel() }
            .onChange(of: devices.count) { _, _ in syncViewModel() }
            .onOpenURL { url in root.handleOpenURL(url) }
    }

    /// Stays in the view: it reads the live `@Query` results, which only a view can observe.
    private func syncViewModel() {
        viewModel.update(modelContext: modelContext, accounts: accounts, sessions: sessions, devices: devices)
    }
}

private struct WindowTitleConfigurator: NSViewRepresentable {
    let title: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WindowConfigurationView {
        let view = WindowConfigurationView(frame: .zero)
        let coordinator = context.coordinator
        view.onWindowChanged = { window in coordinator.attach(window) }
        return view
    }

    func updateNSView(_ view: WindowConfigurationView, context: Context) {
        context.coordinator.update(title: title)
    }

    static func dismantleNSView(_ nsView: WindowConfigurationView, coordinator: Coordinator) {
        nsView.onWindowChanged = nil
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var configuredWindow: ObjectIdentifier?
        private var title = ""

        func attach(_ window: NSWindow?) {
            guard self.window !== window else { return }
            self.window = window
            configuredWindow = nil
            guard let window else { return }
            configure(window)
            update(title: title)
        }

        func update(title: String) {
            self.title = title
            guard let window else { return }
            configure(window)
            if window.title != title {
                window.title = title
            }
        }

        func detach() {
            window = nil
            configuredWindow = nil
        }

        private func configure(_ window: NSWindow) {
            let windowIdentifier = ObjectIdentifier(window)
            guard configuredWindow != windowIdentifier else { return }
            configuredWindow = windowIdentifier
            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = false
            window.isOpaque = true
            window.backgroundColor = .black
            if #available(macOS 11.0, *) {
                window.titlebarSeparatorStyle = .none
            }
            if let fitted = OpenNOWWindowFitting.fittedFrame(for: window) {
                window.setFrame(fitted, display: true)
            }
        }
    }

    final class WindowConfigurationView: NSView {
        var onWindowChanged: (@MainActor (NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChanged?(window)
        }
    }
}

enum OpenNOWWindowFitting {
    static let targetFillRatio: CGFloat = 0.85

    @MainActor
    static func fittedFrame(for window: NSWindow) -> CGRect? {
        let screen = window.screen ?? NSScreen.main
        guard let screen else { return nil }
        let visible = screen.visibleFrame
        let allowedWidth = visible.width * targetFillRatio
        let allowedHeight = visible.height * targetFillRatio
        let current = window.frame
        let widthScale = allowedWidth / current.width
        let heightScale = allowedHeight / current.height
        guard widthScale < 1 || heightScale < 1 else { return nil }
        let scale = min(widthScale, heightScale)
        guard scale < 1 else { return nil }
        // Never shrink below the window's minimum content size: SwiftUI keeps
        // laying the content out at its minWidth/minHeight, so a smaller frame
        // just clips the trailing edge instead of resizing the interface.
        let minFrame = window.frameRect(forContentRect: CGRect(origin: .zero, size: window.contentMinSize)).size
        let newSize = CGSize(
            width: max(floor(current.width * scale), minFrame.width),
            height: max(floor(current.height * scale), minFrame.height)
        )
        guard newSize.width < current.width || newSize.height < current.height else { return nil }
        let origin = CGPoint(
            x: visible.midX - newSize.width / 2,
            y: visible.midY - newSize.height / 2
        )
        return CGRect(origin: origin, size: newSize)
    }
}

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragAreaView {
        DragAreaView(frame: .zero)
    }

    func updateNSView(_ nsView: DragAreaView, context: Context) {}

    final class DragAreaView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [LoginAccount.self, LoginSession.self, LoginDeviceRegistration.self, CatalogImageCacheEntry.self], inMemory: true)
}
