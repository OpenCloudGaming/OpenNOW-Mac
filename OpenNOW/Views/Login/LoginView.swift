//
//  LoginView.swift
//  OpenNOW
//
//  Created by Jayian on 6/14/26.
//

import Combine
import SwiftUI

struct LoginView: View {
    @ObservedObject var viewModel: LoginViewModel
    let accounts: [LoginAccount]
    let onWindowTitleChange: (String?) -> Void

    @FocusState private var focusedField: LoginField?

    var body: some View {
        ZStack {
            LoginBackdrop()
            if let activeAccount = viewModel.activeAccount, let activeSession = viewModel.activeSession {
                CatalogView(
                    account: activeAccount,
                    session: activeSession,
                    accounts: accounts,
                    pendingGameShortcut: $viewModel.pendingGameShortcut,
                    onSwitch: viewModel.activateAccount,
                    onSignOut: viewModel.signOut,
                    onForget: viewModel.forgetAccount,
                    onRefreshAuth: viewModel.refreshActiveSession,
                    onWindowTitleChange: onWindowTitleChange
                )
                .id(activeSession.id)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                loginWindow
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if viewModel.isLaunchingOAuth || viewModel.isAuthenticating {
                VendorSplashLoadingView(message: "Connecting to GeForce NOW")
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .onChange(of: viewModel.requestedFocus) { _, field in focusedField = field }
        .onChange(of: viewModel.activeSession?.id) { _, _ in onWindowTitleChange(nil) }
        .preferredColorScheme(.dark)
    }

    private var loginWindow: some View {
        ZStack(alignment: .leading) {
            LoginMarketingView(viewModel: viewModel)
            LoginFormView(viewModel: viewModel, accounts: accounts, focusedField: $focusedField)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
