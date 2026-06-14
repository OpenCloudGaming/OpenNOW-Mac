//
//  SignedInDashboardView.swift
//  OpenNOW
//
//  Created by Jayian on 6/14/26.
//

import SwiftUI

struct SignedInDashboardView: View {
    let account: LoginAccount
    let session: LoginSession
    let accounts: [LoginAccount]
    let onSwitch: (LoginAccount) -> Void
    let onSignOut: () -> Void
    let onForget: (LoginAccount) -> Void

    var body: some View {
        VStack(spacing: 22) {
            HStack {
                HStack(spacing: 16) {
                    AccountAvatar(name: account.displayName, size: 58)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Ready to play")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                        Text("\(account.displayName) signed in with \(account.providerName)")
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Sign Out", action: onSignOut)
                    .buttonStyle(SecondaryLoginButtonStyle(compact: true))
            }

            HStack(spacing: 16) {
                SessionMetric(title: "Membership", value: account.membershipTier, symbol: "crown.fill")
                SessionMetric(title: "Auth", value: account.authStatus.replacingOccurrences(of: "_", with: " "), symbol: "checkmark.shield.fill")
                SessionMetric(title: "Client Token", value: session.clientTokenExpiresAt.formatted(date: .omitted, time: .shortened), symbol: "timer")
                SessionMetric(title: "Session", value: session.expiresAt.formatted(date: .abbreviated, time: .shortened), symbol: "calendar.badge.clock")
            }

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Session details")
                        .font(.title2.bold())
                    DetailRow(label: "Email", value: account.email)
                    DetailRow(label: "Provider ID", value: account.providerIdpId)
                    DetailRow(label: "Device ID", value: session.deviceId)
                    DetailRow(label: "Auth method", value: session.authMethod)
                    DetailRow(label: "Offline continue", value: session.canContinueOffline ? "Enabled" : "Disabled")
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))

                VStack(alignment: .leading, spacing: 14) {
                    Text("Account switcher")
                        .font(.title2.bold())
                    ForEach(accounts) { switchAccount in
                        HStack(spacing: 12) {
                            AccountAvatar(name: switchAccount.displayName, size: 38)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(switchAccount.displayName)
                                Text(switchAccount.email)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if switchAccount.email == account.email {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.openNowGreen)
                            } else {
                                Button("Use") { onSwitch(switchAccount) }
                                    .buttonStyle(.bordered)
                            }
                            Button(role: .destructive) {
                                onForget(switchAccount)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(12)
                        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
                .padding(24)
                .frame(width: 360, alignment: .topLeading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            }

            Spacer()
        }
        .padding(34)
        .frame(maxWidth: 1040, maxHeight: 660)
        .background(.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 34, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.32), radius: 34, x: 0, y: 22)
        .padding(28)
    }
}
