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
        GeometryReader { proxy in
            let contentLeading = min(max(500, proxy.size.width * 0.54), max(500, proxy.size.width - 420))

            ZStack(alignment: .leading) {
                GFNHeroArtwork()
                    .frame(width: proxy.size.width, height: proxy.size.height)

                Rectangle()
                    .fill(Color.black.opacity(0.54))

                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.98), location: 0.00),
                        .init(color: .black.opacity(0.94), location: 0.18),
                        .init(color: .black.opacity(0.70), location: 0.40),
                        .init(color: .black.opacity(0.36), location: 0.66),
                        .init(color: .black.opacity(0.08), location: 0.94),
                        .init(color: .clear, location: 1.00),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )

                VStack(alignment: .leading, spacing: 0) {
                    GFNWordmark()

                    Spacer()

                    VStack(alignment: .leading, spacing: 16) {
                        Text("GeForce NOW")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(.white)
                            .tracking(0.2)
                        Text("Connect your NVIDIA account to continue")
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(Color.gfnTextSecondary)
                            .lineSpacing(3)
                    }
                    .frame(width: 400, alignment: .leading)

                    Spacer()

                    VStack(alignment: .leading, spacing: 10) {
                        LoginStatCard(title: "Auth", value: viewModel.authStatusSummary)
                        LoginStatCard(title: "NES", value: viewModel.nesAuthorizationSummary)
                    }
                    .frame(width: 400)

                    Spacer()
                        .frame(height: 32)

                    Text("Powered by OpenNOW native streaming")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color.gfnTextTertiary)
                }
                .padding(.top, 48)
                .padding(.bottom, 32)
                .padding(.leading, contentLeading)
                .opacity(proxy.size.width > 820 ? 1 : 0)
            }
        }
        .ignoresSafeArea()
    }
}
