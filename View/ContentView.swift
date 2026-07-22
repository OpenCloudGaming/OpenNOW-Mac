//
//  ContentView.swift
//  MacForceNow
//
//  Created by Jayian on 6/14/26.
//

import Combine
import AppKit
import SwiftData
import SwiftUI

struct ContentView: View {
    private static let defaultWindowTitle = "MacForce Now"

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LoginAccount.lastLoginAt, order: .reverse) private var accounts: [LoginAccount]
    @Query(sort: \LoginSession.issuedAt, order: .reverse) private var sessions: [LoginSession]
    @Query private var devices: [LoginDeviceRegistration]

    @StateObject private var viewModel = LoginViewModel()
    @State private var windowTitle = Self.defaultWindowTitle
    @State private var didBootstrap = false
    @State private var isShowingStartupLoading = true

    var body: some View {
        ZStack {
            LoginView(viewModel: viewModel, accounts: accounts) { title in
                windowTitle = title ?? Self.defaultWindowTitle
            }

            if isShowingStartupLoading {
                MacForceNowStartupLoadingView()
                    .transition(.opacity)
                    .zIndex(100)
            }
        }
            .frame(minWidth: 980, minHeight: 600)
            .frame(idealWidth: 1200, idealHeight: 720)
            .ignoresSafeArea()
            .background(WindowTitleConfigurator(title: windowTitle))
            .task {
                await bootstrapAppStartIfNeeded()
            }
            .onChange(of: accounts.count) { _, _ in syncViewModel() }
            .onChange(of: sessions.count) { _, _ in syncViewModel() }
            .onChange(of: devices.count) { _, _ in syncViewModel() }
            .onOpenURL { url in handleOpenURL(url) }
            .onReceive(NotificationCenter.default.publisher(for: .openNOWDidOpenFile)) { notification in
                guard let url = notification.object as? URL else { return }
                viewModel.handleOpenedFile(url)
            }
    }

    private func bootstrapAppStartIfNeeded() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        syncViewModel()
        viewModel.bootstrap()
        drainOpenedFiles()
        await dismissStartupLoading()
    }

    private func dismissStartupLoading() async {
        try? await Task.sleep(nanoseconds: MacForceNowStartupAnimation.dismissalDelayNanoseconds)
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: MacForceNowStartupAnimation.fadeDuration)) {
            isShowingStartupLoading = false
        }
    }

    private func drainOpenedFiles() {
        for url in MacForceNowFileOpenCoordinator.shared.drainPendingFileURLs() {
            viewModel.handleOpenedFile(url)
        }
    }

    private func syncViewModel() {
        viewModel.update(modelContext: modelContext, accounts: accounts, sessions: sessions, devices: devices)
    }

    private func handleOpenURL(_ url: URL) {
        viewModel.handleOAuthCallback(url)
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
            if let fitted = MacForceNowWindowFitting.fittedFrame(for: window) {
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

enum MacForceNowWindowFitting {
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
        let newSize = CGSize(width: floor(current.width * scale), height: floor(current.height * scale))
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
