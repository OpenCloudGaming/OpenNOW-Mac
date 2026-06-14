//
//  LoginMarketingView.swift
//  OpenNOW
//
//  Created by Jayian on 6/14/26.
//

import SwiftUI

struct LoginMarketingView: View {
    @ObservedObject var viewModel: LoginViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 12) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 52, height: 52)
                    .background(Color.openNowGreen, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenNOW")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text("Cloud play, native control")
                        .foregroundStyle(.white.opacity(0.58))
                        .font(.callout)
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 14) {
                Text("Sign in to your streaming command center.")
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
                Text("Jarvis OAuth metadata, NES authorization state, and local account continuity are persisted through SwiftData so the frontend can survive restarts cleanly.")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.68))
                    .lineSpacing(3)
            }

            HStack(spacing: 12) {
                LoginStatCard(title: "Auth", value: viewModel.authStatusSummary)
                LoginStatCard(title: "NES", value: viewModel.nesAuthorizationSummary)
            }

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 12) {
                LoginChecklistItem(icon: "lock.shield.fill", title: "No password persistence", detail: "Credentials are validated for the UI flow and discarded immediately.")
                LoginChecklistItem(icon: "externaldrive.connected.to.line.below.fill", title: "SwiftData sessions", detail: "Remembered accounts, device IDs, and active sessions live in the model container.")
                LoginChecklistItem(icon: "safari.fill", title: "OAuth ready", detail: "The provider button launches a Jarvis-compatible authorization URL.")
            }
        }
        .foregroundStyle(.white)
        .padding(42)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            ZStack(alignment: .bottomTrailing) {
                LinearGradient(colors: [.black.opacity(0.84), .black.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle()
                    .fill(Color.openNowGreen.opacity(0.18))
                    .frame(width: 280, height: 280)
                    .blur(radius: 34)
                    .offset(x: 86, y: 76)
                AngularGradient(colors: [.clear, .openNowGreen.opacity(0.28), .clear, .mint.opacity(0.18), .clear], center: .center)
                    .frame(width: 420, height: 420)
                    .blur(radius: 24)
                    .offset(x: 110, y: 90)
            }
        }
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 34, bottomLeadingRadius: 34, bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous))
    }
}
