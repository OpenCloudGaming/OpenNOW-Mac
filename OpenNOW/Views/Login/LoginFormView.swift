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
                .opacity(0.22)

            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black.opacity(0.98), location: 0.34),
                    .init(color: .black.opacity(0.90), location: 0.68),
                    .init(color: .black.opacity(0.56), location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            VendorResourceImage(name: "nv-gfn-logo_v3", fileExtension: "png")
                .scaledToFit()
                .frame(width: 174, height: 52)
                .position(x: metrics.contentLeft + 87, y: 52)

            VStack(alignment: .leading, spacing: 0) {
                Spacer()

                VStack(alignment: .leading, spacing: 0) {
                    Text("GeForce NOW")
                        .font(.nvidiaSans(size: 36, weight: .bold))
                        .foregroundStyle(.white)
                        .tracking(-0.2)
                        .lineLimit(1)
                        .padding(.bottom, 22)

                    VStack(alignment: .leading, spacing: 18) {
                        VendorContentString(text: "Instantly play the most demanding PC games and seamlessly play across your devices.")
                        VendorContentString(text: "Your GeForce NOW library, memberships, and cloud saves stay connected through NVIDIA sign-in.")
                        VendorContentString(text: "No downloads. No updates. Jump straight into RTX-powered cloud gaming.")
                    }
                }
                .padding(.bottom, 34)

                Button(action: startVendorLogin) {
                    Text(viewModel.hasPendingOAuth ? "REOPEN" : "GET IN")
                }
                .buttonStyle(VendorGetInButtonStyle())
                .disabled(viewModel.isLaunchingOAuth || viewModel.isAuthenticating)
                .accessibilityHint("Opens NVIDIA authentication in your browser")
                .padding(.bottom, 32)

                if !viewModel.validationMessage.isEmpty || !viewModel.successMessage.isEmpty {
                    Text(viewModel.validationMessage.isEmpty ? viewModel.successMessage : viewModel.validationMessage)
                        .font(.nvidiaSans(size: 13, weight: .regular))
                        .foregroundStyle(viewModel.validationMessage.isEmpty ? Color.openNowGreen : .orange)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                        .padding(.bottom, 14)
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
                    .font(.nvidiaSans(size: 12, weight: .regular))
                    .foregroundStyle(Color.gfnTextSecondary)
                    .lineLimit(1)
            }
            .position(x: metrics.contentLeft + ((metrics.panelWidth - metrics.contentLeft - metrics.contentRight) / 2), y: metrics.height - 34)

            LinearGradient(
                colors: [.clear, .black.opacity(0.78)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 24)
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
        panelWidth = min(min(max(rawPanelWidth, 410), max(size.width * 0.58, 410)), max(size.width, 320))
        contentLeft = min(24 + sideSpacing, max(panelWidth * 0.10, 18))
        contentRight = min(44, max(panelWidth * 0.10, 24))
        contentBottom = 48
    }
}

private struct VendorContentString: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Circle()
                .fill(Color.openNowGreen)
                .frame(width: 7, height: 7)
                .padding(.top, 6)
            Text(text)
                .font(.nvidiaSans(size: 15, weight: .regular))
                .foregroundStyle(.white.opacity(0.78))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
