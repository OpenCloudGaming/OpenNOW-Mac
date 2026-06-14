//
//  RememberedAccountsView.swift
//  OpenNOW
//
//  Created by Jayian on 6/14/26.
//

import SwiftUI

struct RememberedAccountsView: View {
    @ObservedObject var viewModel: LoginViewModel
    let accounts: [LoginAccount]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Remembered accounts")
                    .font(.headline)
                Spacer()
                Button(viewModel.isShowingAccountPicker ? "Hide" : "Show") {
                    viewModel.toggleAccountPicker()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.openNowGreen)
            }

            if viewModel.isShowingAccountPicker {
                VStack(spacing: 8) {
                    ForEach(accounts.prefix(4)) { account in
                        HStack(spacing: 12) {
                            Button {
                                viewModel.selectRememberedAccount(account)
                            } label: {
                                HStack(spacing: 12) {
                                    AccountAvatar(name: account.displayName)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(account.displayName)
                                            .foregroundStyle(.primary)
                                        Text(account.email)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(account.membershipTier)
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.openNowGreen.opacity(0.14), in: Capsule())
                                }
                            }
                            .buttonStyle(.plain)

                            Button("Use") {
                                viewModel.activateAccount(account)
                            }
                            .buttonStyle(.bordered)
                            .disabled(viewModel.isAuthenticating)
                        }
                        .padding(10)
                        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
        }
    }
}
