//  LoginFormView.swift
//  OpenNOW
//
//  Created by Jayian on 6/14/26.
//

import Combine
import SwiftUI

struct LoginFormView: View {
    @ObservedObject var viewModel: LoginViewModel
    let accounts: [LoginAccount]
    var focusedField: FocusState<LoginField?>.Binding

    var body: some View {
        GeometryReader { proxy in
            let metrics = VendorLoginWallMetrics(size: proxy.size)

            ZStack(alignment: .leading) {
                leftPanel(metrics: metrics)
                    .frame(width: metrics.panelWidth, height: proxy.size.height)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
    }

    private func leftPanel(metrics: VendorLoginWallMetrics) -> some View {
        ZStack(alignment: .topLeading) {
            VendorResourceImage(name: "LoginWallContentBackground", fileExtension: "png")
                .scaledToFill()
                .frame(width: metrics.panelWidth, height: metrics.height)
                .clipped()
                .opacity(0.30)

            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black.opacity(0.95), location: 0.28),
                    .init(color: .black.opacity(0.85), location: 0.60),
                    .init(color: .black.opacity(0.60), location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            VendorResourceImage(name: "nv-gfn-logo_v3", fileExtension: "png")
                .scaledToFit()
                .frame(width: 186, height: 56)
                .position(x: metrics.contentLeft + 93, y: 52)

            VStack(alignment: .leading, spacing: 0) {
                Spacer()

                VStack(alignment: .leading, spacing: 0) {
                    Text("OpenNOW Mac")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.openNowGreen)
                        .tracking(1.4)
                        .padding(.bottom, 10)

                    Text("GeForce NOW")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white)
                        .lineSpacing(0)
                        .padding(.bottom, 10)

                    Text("Launch your cloud gaming library from a focused macOS client.")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 24)

                    VStack(alignment: .leading, spacing: 16) {
                        VendorBullet(text: "Play your games instantly across devices.")
                        VendorBullet(text: "No downloads. No updates. Just jump in.")
                        VendorBullet(text: "Stream with RTX performance from the cloud.")
                    }
                }
                .padding(.bottom, 32)

                Button(action: startVendorLogin) {
                    Text(viewModel.hasPendingOAuth ? "REOPEN SIGN-IN" : "SIGN IN WITH NVIDIA")
                }
                .buttonStyle(VendorGetInButtonStyle())
                .disabled(viewModel.isLaunchingOAuth || viewModel.isAuthenticating)
                .accessibilityHint("Opens NVIDIA authentication in your browser")
                .padding(.bottom, 32)

                Text("OpenNOW stores local session metadata on this Mac and uses NVIDIA OAuth for account access.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.gfnTextTertiary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 18)

                if !viewModel.validationMessage.isEmpty || !viewModel.successMessage.isEmpty {
                    Text(viewModel.validationMessage.isEmpty ? viewModel.successMessage : viewModel.validationMessage)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(viewModel.validationMessage.isEmpty ? Color.openNowGreen : .orange)
                        .padding(.bottom, 16)
                }

                Spacer()
            }
            .padding(.top, 88)
            .padding(.leading, metrics.contentLeft)
            .padding(.trailing, metrics.contentRight)
            .padding(.bottom, metrics.contentBottom)
            .frame(width: metrics.panelWidth, alignment: .leading)

            VStack(alignment: .leading, spacing: 0) {
                Text("OpenNOW Mac")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Color.gfnTextSecondary)
                    .lineLimit(1)
            }
            .position(x: metrics.contentLeft + ((metrics.panelWidth - metrics.contentLeft - metrics.contentRight) / 2), y: metrics.height - 34)

            Rectangle()
                .fill(Color.openNowGreen)
                .frame(width: 8)
                .frame(maxHeight: .infinity)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .background(.black)
    }

    private func startVendorLogin() {
        viewModel.selectedProvider = .nvidia
        viewModel.rememberSession = true
        viewModel.acceptedTerms = true
        viewModel.launchOAuth()
    }
}

private struct VendorLoginWallMetrics {
    let height: CGFloat
    let panelWidth: CGFloat
    let contentLeft: CGFloat
    let contentRight: CGFloat
    let contentBottom: CGFloat

    init(size: CGSize) {
        height = size.height
        let columnCount: CGFloat
        let gutter: CGFloat
        let sideSpacing: CGFloat

        if size.width >= 960 {
            columnCount = 12
            gutter = size.width >= 1440 ? 16 : 8
            sideSpacing = 24
        } else if size.width >= 720 {
            columnCount = 8
            gutter = 8
            sideSpacing = 16
        } else if size.width >= 480 {
            columnCount = 6
            gutter = 8
            sideSpacing = 16
        } else {
            columnCount = 4
            gutter = 8
            sideSpacing = 16
        }

        let columnSize = (size.width - (2 * sideSpacing) - (gutter * (columnCount - 1))) / columnCount
        let panelColumnCount: CGFloat = size.width >= 1200 ? 4 : 5
        let rawPanelWidth = (panelColumnCount * columnSize) + ((panelColumnCount - 1) * gutter) + sideSpacing
        panelWidth = min(max(rawPanelWidth, 360), max(size.width * 0.62, 360))
        contentLeft = 24 + sideSpacing
        contentRight = 40
        contentBottom = 48
    }
}

private struct VendorBullet: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Circle()
                .fill(Color.openNowGreen)
                .frame(width: 8, height: 8)
                .padding(.top, 4)
            Text(text)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Color.gfnTextSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
