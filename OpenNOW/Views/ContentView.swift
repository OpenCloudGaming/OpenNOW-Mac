//
//  ContentView.swift
//  OpenNOW
//
//  Created by Jayian on 6/14/26.
//

import Combine
import AppKit
import SwiftData
import SwiftUI

struct ContentView: View {
    private static let defaultWindowTitle = "OpenNOW"

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LoginAccount.lastLoginAt, order: .reverse) private var accounts: [LoginAccount]
    @Query(sort: \LoginSession.issuedAt, order: .reverse) private var sessions: [LoginSession]
    @Query private var devices: [LoginDeviceRegistration]

    @StateObject private var viewModel = LoginViewModel()
    @State private var windowTitle = Self.defaultWindowTitle

    var body: some View {
        LoginView(viewModel: viewModel, accounts: accounts) { title in
            windowTitle = title ?? Self.defaultWindowTitle
        }
            .frame(minWidth: 980, minHeight: 660)
            .frame(idealWidth: 1200, idealHeight: 760)
            .ignoresSafeArea()
            .background(HiddenTitlebarConfigurator(title: windowTitle))
            .task {
                syncViewModel()
                viewModel.bootstrap()
                drainOpenedFiles()
            }
            .onChange(of: accounts.count) { _, _ in syncViewModel() }
            .onChange(of: sessions.count) { _, _ in syncViewModel() }
            .onChange(of: devices.count) { _, _ in syncViewModel() }
            .onOpenURL { url in viewModel.handleOAuthCallback(url) }
            .onReceive(NotificationCenter.default.publisher(for: .openNOWDidOpenFile)) { notification in
                guard let url = notification.object as? URL else { return }
                viewModel.handleOpenedFile(url)
            }
    }

    private func drainOpenedFiles() {
        for url in OpenNOWFileOpenCoordinator.shared.drainPendingFileURLs() {
            viewModel.handleOpenedFile(url)
        }
    }

    private func syncViewModel() {
        viewModel.update(modelContext: modelContext, accounts: accounts, sessions: sessions, devices: devices)
    }
}

private struct HiddenTitlebarConfigurator: NSViewRepresentable {
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
            window.isMovableByWindowBackground = true
            window.isOpaque = false
            window.backgroundColor = .clear
            if window.toolbar != nil {
                window.toolbar = nil
            }
            if #available(macOS 11.0, *) {
                window.titlebarSeparatorStyle = .none
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

#Preview {
    ContentView()
        .modelContainer(for: [LoginAccount.self, LoginSession.self, LoginDeviceRegistration.self, CatalogImageCacheEntry.self], inMemory: true)
}
