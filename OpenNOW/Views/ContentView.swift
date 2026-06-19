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
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LoginAccount.lastLoginAt, order: .reverse) private var accounts: [LoginAccount]
    @Query(sort: \LoginSession.issuedAt, order: .reverse) private var sessions: [LoginSession]
    @Query private var devices: [LoginDeviceRegistration]

    @StateObject private var viewModel = LoginViewModel()

    var body: some View {
        LoginView(viewModel: viewModel, accounts: accounts)
            .frame(minWidth: 980, minHeight: 660)
            .background(OpaqueTitlebarConfigurator())
            .task {
                syncViewModel()
                viewModel.bootstrap()
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

    private func syncViewModel() {
        viewModel.update(modelContext: modelContext, accounts: accounts, sessions: sessions, devices: devices)
    }
}

private struct OpaqueTitlebarConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { configure(window: view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(window: view.window) }
    }

    private func configure(window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = false
        window.backgroundColor = NSColor(red: 45 / 255, green: 45 / 255, blue: 45 / 255, alpha: 1)
        window.toolbarStyle = .unified
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [LoginAccount.self, LoginSession.self, LoginDeviceRegistration.self, CatalogImageCacheEntry.self], inMemory: true)
}
