//
//  LoginView.swift
//  OpenNOW
//
//  Created by Jayian on 6/14/26.
//

import SwiftUI

struct LoginView: View {
    @ObservedObject var viewModel: LoginViewModel
    let accounts: [LoginAccount]

    @FocusState private var focusedField: LoginField?

    var body: some View {
        ZStack {
            LoginBackdrop()
            if let activeAccount = viewModel.activeAccount, let activeSession = viewModel.activeSession {
                SignedInDashboardView(
                    account: activeAccount,
                    session: activeSession,
                    accounts: accounts,
                    onSwitch: viewModel.activateAccount,
                    onSignOut: viewModel.signOut,
                    onForget: viewModel.forgetAccount
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                loginWindow
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .onChange(of: viewModel.requestedFocus) { _, field in focusedField = field }
    }

    private var loginWindow: some View {
        HStack(spacing: 0) {
            LoginMarketingView(viewModel: viewModel)
            LoginFormView(viewModel: viewModel, accounts: accounts, focusedField: $focusedField)
        }
        .frame(maxWidth: 1040, maxHeight: 660)
        .background(.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 34, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.36), radius: 36, x: 0, y: 24)
        .padding(28)
    }
}
