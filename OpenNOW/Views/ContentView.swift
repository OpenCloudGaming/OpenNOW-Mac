//
//  ContentView.swift
//  OpenNOW
//
//  Created by Jayian on 6/14/26.
//

import Combine
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
            .task {
                syncViewModel()
                viewModel.bootstrap()
            }
            .onChange(of: accounts.count) { _, _ in syncViewModel() }
            .onChange(of: sessions.count) { _, _ in syncViewModel() }
            .onChange(of: devices.count) { _, _ in syncViewModel() }
            .onOpenURL { url in viewModel.handleOAuthCallback(url) }
            .animation(.snappy(duration: 0.28), value: viewModel.activeSession?.id)
    }

    private func syncViewModel() {
        viewModel.update(modelContext: modelContext, accounts: accounts, sessions: sessions, devices: devices)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [LoginAccount.self, LoginSession.self, LoginDeviceRegistration.self], inMemory: true)
}
