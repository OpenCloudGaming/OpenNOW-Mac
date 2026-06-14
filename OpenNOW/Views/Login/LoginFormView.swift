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
        VStack(alignment: .leading, spacing: 0) {
            Text("Sign in")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.white)
                .padding(.top, 48)

            VStack(alignment: .leading, spacing: 16) {
                Text("Use your NVIDIA account to sync your library and start streaming games.")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Color.gfnTextSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                if !accounts.isEmpty {
                    RememberedAccountsView(viewModel: viewModel, accounts: accounts)
                        .padding(.top, 6)
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Text("Provider")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.gfnTextSecondary)

                        ForEach(LoginProvider.allCases) { provider in
                            Button {
                                viewModel.selectedProvider = provider
                            } label: {
                                Text(provider.title.uppercased())
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(viewModel.selectedProvider == provider ? .black : .white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(viewModel.selectedProvider == provider ? Color.openNowGreen : Color.white.opacity(0.08))
                                    .overlay {
                                        Rectangle()
                                            .stroke(viewModel.selectedProvider == provider ? Color.openNowGreen : Color.gfnStroke, lineWidth: 1)
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    TextField("Email hint (optional)", text: $viewModel.email)
                        .textFieldStyle(LoginTextFieldStyle(isFocused: focusedField.wrappedValue == .email))
                        .focused(focusedField, equals: .email)

                    Toggle("Remember this account", isOn: $viewModel.rememberSession)
                    Toggle("I agree to NVIDIA terms and local session storage", isOn: $viewModel.acceptedTerms)
                }
                .toggleStyle(.checkbox)
                .tint(Color.openNowGreen)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.gfnTextSecondary)

                Button(action: viewModel.launchOAuth) {
                    HStack {
                        if viewModel.isLaunchingOAuth {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "safari.fill")
                        }
                        Text(viewModel.hasPendingOAuth ? "REOPEN NVIDIA SIGN-IN" : "CONTINUE WITH NVIDIA")
                        Spacer()
                        Image(systemName: "arrow.up.forward.app.fill")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryLoginButtonStyle())
                .disabled(!viewModel.canLaunchOAuth)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: viewModel.hasPendingOAuth ? "link.badge.plus" : "link.badge.plus.fill")
                            .foregroundStyle(viewModel.hasPendingOAuth ? Color.openNowGreen : .secondary)
                        Text(viewModel.hasPendingOAuth ? "Waiting for OAuth callback" : "Browser authorization not started")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
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
                            Text("COMPLETE SIGN-IN")
                            Spacer()
                            Text("JARVIS")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.gfnTextTertiary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SecondaryLoginButtonStyle())
                    .disabled(!viewModel.canCompleteOAuth)
                }
                .padding(16)
                .background(Color.gfnPanel.opacity(0.88))
                .overlay {
                    Rectangle()
                        .stroke(Color.gfnStroke, lineWidth: 1)
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
                            .foregroundStyle(Color.gfnTextTertiary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
                .font(.callout)
                .frame(minHeight: 58, alignment: .topLeading)
            }
            .padding(.top, 24)

            Spacer()

            VStack(alignment: .leading, spacing: 10) {
                LoginStatCard(title: "Auth", value: viewModel.authStatusSummary)
                LoginStatCard(title: "NES", value: viewModel.nesAuthorizationSummary)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "macbook.and.iphone")
                    Text(viewModel.primaryDevice.displayName)
                }
                Text("Device ID feeds Jarvis OAuth")
            }
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(Color.gfnTextTertiary)
        }
        .padding(.leading, 40)
        .padding(.trailing, 0)
        .padding(.bottom, 32)
        .frame(width: 440, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }
}
