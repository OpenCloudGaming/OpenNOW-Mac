//
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
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Welcome back")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("Choose a provider, continue with a remembered account, or launch browser OAuth.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            if !accounts.isEmpty {
                RememberedAccountsView(viewModel: viewModel, accounts: accounts)
            }

            VStack(spacing: 14) {
                Picker("Provider", selection: $viewModel.selectedProvider) {
                    ForEach(LoginProvider.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                .pickerStyle(.segmented)

                TextField("Email address", text: $viewModel.email)
                    .textFieldStyle(LoginTextFieldStyle(isFocused: focusedField.wrappedValue == .email))
                    .focused(focusedField, equals: .email)

                SecureField("Password", text: $viewModel.password)
                    .textFieldStyle(LoginTextFieldStyle(isFocused: focusedField.wrappedValue == .password))
                    .focused(focusedField, equals: .password)
                    .onSubmit(viewModel.signInWithPassword)
            }

            VStack(spacing: 12) {
                Toggle("Remember this account on this Mac", isOn: $viewModel.rememberSession)
                Toggle("I agree to the NVIDIA account terms and OpenNOW session storage", isOn: $viewModel.acceptedTerms)
            }
            .toggleStyle(.checkbox)
            .font(.callout)

            VStack(spacing: 12) {
                Button(action: viewModel.signInWithPassword) {
                    Label("Continue", systemImage: "arrow.right.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryLoginButtonStyle())
                .disabled(!viewModel.canSubmitPassword)

                Button(action: viewModel.launchOAuth) {
                    HStack {
                        if viewModel.isLaunchingOAuth {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "safari.fill")
                        }
                        Text("Sign in with NVIDIA OAuth")
                        Spacer()
                        Image(systemName: "arrow.up.forward.app.fill")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryLoginButtonStyle())
                .disabled(viewModel.isLaunchingOAuth || !viewModel.acceptedTerms)
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
            }
            .font(.callout)
            .frame(minHeight: 46, alignment: .topLeading)

            Spacer()

            HStack {
                Label(viewModel.primaryDevice.displayName, systemImage: "macbook.and.iphone")
                Spacer()
                Text("Device ID saved in SwiftData")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(38)
        .frame(width: 430, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 34, topTrailingRadius: 34, style: .continuous))
    }
}
