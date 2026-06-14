//  LoginFormView.swift
//  OpenNOW
//
//  Created by Jayian on 6/14/26.
//

import SwiftUI

struct LoginFormView: View {
    @ObservedObject var viewModel: LoginViewModel
    let accounts: [LoginAccount]
    var focusedField: FocusState<LoginField?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Connect NVIDIA")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("OpenNOW uses the production Jarvis OAuth flow from the vendor client. Passwords never enter this app.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !accounts.isEmpty {
                RememberedAccountsView(viewModel: viewModel, accounts: accounts)
            }

            VStack(alignment: .leading, spacing: 14) {
                Picker("Provider", selection: $viewModel.selectedProvider) {
                    ForEach(LoginProvider.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                .pickerStyle(.segmented)

                TextField("Email hint (optional)", text: $viewModel.email)
                    .textFieldStyle(LoginTextFieldStyle(isFocused: focusedField.wrappedValue == .email))
                    .focused(focusedField, equals: .email)

                Toggle("Remember this account on this Mac", isOn: $viewModel.rememberSession)
                Toggle("I agree to NVIDIA account terms and OpenNOW session storage", isOn: $viewModel.acceptedTerms)
            }
            .toggleStyle(.checkbox)
            .font(.callout)

            Button(action: viewModel.launchOAuth) {
                HStack {
                    if viewModel.isLaunchingOAuth {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "safari.fill")
                    }
                    Text(viewModel.hasPendingOAuth ? "Reopen NVIDIA sign-in" : "Continue with NVIDIA")
                    Spacer()
                    Image(systemName: "arrow.up.forward.app.fill")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryLoginButtonStyle())
            .disabled(!viewModel.canLaunchOAuth)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: viewModel.hasPendingOAuth ? "link.badge.plus" : "link.badge.plus.fill")
                        .foregroundStyle(viewModel.hasPendingOAuth ? Color.openNowGreen : .secondary)
                    Text(viewModel.hasPendingOAuth ? "Waiting for OAuth callback" : "Browser authorization not started")
                        .font(.headline)
                    Spacer()
                }

                TextField("Paste callback URL or code query if macOS does not return automatically", text: $viewModel.oauthCallbackText, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(LoginTextFieldStyle(isFocused: focusedField.wrappedValue == .callback))
                    .focused(focusedField, equals: .callback)
                    .disabled(!viewModel.hasPendingOAuth || viewModel.isAuthenticating)

                Button(action: viewModel.completeOAuthWithCallbackText) {
                    HStack {
                        if viewModel.isAuthenticating {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "checkmark.seal.fill")
                        }
                        Text("Complete sign-in")
                        Spacer()
                        Text("JARVIS_Get_Session_Token")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryLoginButtonStyle())
                .disabled(!viewModel.canCompleteOAuth)
            }
            .padding(16)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            }

            VStack(alignment: .leading, spacing: 8) {
                if !viewModel.validationMessage.isEmpty {
                    Label(viewModel.validationMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if !viewModel.successMessage.isEmpty {
                    Label(viewModel.successMessage, systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Color.openNowGreen)
                }
                if !viewModel.currentAuthorizationURL.isEmpty {
                    Text(viewModel.currentAuthorizationURL)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            .font(.callout)
            .frame(minHeight: 58, alignment: .topLeading)

            Spacer()

            HStack {
                Label(viewModel.primaryDevice.displayName, systemImage: "macbook.and.iphone")
                Spacer()
                Text("Device ID feeds Jarvis OAuth")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(38)
        .frame(width: 440, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 34, topTrailingRadius: 34, style: .continuous))
    }
}
