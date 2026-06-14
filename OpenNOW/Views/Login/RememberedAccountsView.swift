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
                Text("Remembered accounts".uppercased())
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.gfnTextTertiary)
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
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundStyle(.white)
                                        Text(account.email)
                                            .font(.system(size: 12, weight: .regular))
                                            .foregroundStyle(Color.gfnTextTertiary)
                                    }
                                    Spacer()
                                    Text(account.membershipTier)
                                        .font(.system(size: 11, weight: .bold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .foregroundStyle(.black)
                                        .background(Color.openNowGreen)
                                }
                            }
                            .buttonStyle(.plain)

                            Button("Use") {
                                viewModel.activateAccount(account)
                            }
                            .buttonStyle(SecondaryLoginButtonStyle(compact: true))
                            .disabled(viewModel.isAuthenticating)
                        }
                        .padding(10)
                        .background(Color.white.opacity(0.08))
                        .overlay {
                            Rectangle()
                                .stroke(Color.gfnStroke, lineWidth: 1)
                        }
                    }
                }
            }
        }
    }
}
