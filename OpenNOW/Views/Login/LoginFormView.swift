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

            VendorResourceImage(name: "logo-isolated", fileExtension: "svg")
                .scaledToFit()
                .frame(width: 156, height: 88)
                .position(x: metrics.contentLeft + 78, y: 68)

            VStack(alignment: .leading, spacing: 0) {
                Spacer()

                VStack(alignment: .leading, spacing: 0) {
                    Text("Get In. Game On.")
                        .font(.nvidiaSans(size: 34, weight: .bold))
                        .foregroundStyle(.white)
                        .tracking(0)
                        .lineLimit(1)
                        .frame(height: 48, alignment: .leading)
                        .padding(.bottom, 24)

                    VStack(alignment: .leading, spacing: 16) {
                        VendorContentString(text: "GeForce RTX performance on any device")
                        VendorContentString(text: "Connect to top PC game stores")
                        VendorContentString(text: "Stream thousands of supported titles")
                        VendorContentString(text: "Play hundreds of free-to-play favorites instantly")
                    }
                }
                .padding(.bottom, 34)

                providerPicker
                    .padding(.bottom, 18)

                Button(action: startVendorLogin) {
                    Text(viewModel.hasPendingOAuth ? "REOPEN" : "GET IN")
                }
                .buttonStyle(VendorGetInButtonStyle())
                .disabled(viewModel.isLaunchingOAuth || viewModel.isAuthenticating)
                .accessibilityHint("Opens \(viewModel.selectedProvider.title) authentication in your browser")
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
                Text(appVersionText)
                    .font(.nvidiaSans(size: 14, weight: .regular))
                    .foregroundStyle(Color.gfnTextSecondary)
                    .lineLimit(1)
            }
            .frame(width: max(metrics.panelWidth - metrics.contentLeft - metrics.contentRight, 0), alignment: .leading)
            .position(x: metrics.contentLeft + ((metrics.panelWidth - metrics.contentLeft - metrics.contentRight) / 2), y: metrics.height - 36)

            Rectangle()
                .fill(Color.openNowGreen)
                .frame(width: 8)
                .frame(maxHeight: .infinity)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .background(.black)
    }

    private var providerPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SERVICE PROVIDER")
                .font(.nvidiaSans(size: 11, weight: .bold))
                .foregroundStyle(Color.gfnTextTertiary)
                .tracking(0.8)

            Menu {
                ForEach(viewModel.providers) { provider in
                    Button(provider.title) {
                        viewModel.selectProvider(provider)
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(viewModel.selectedProvider.title)
                            .font(.nvidiaSans(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if !viewModel.selectedProvider.loginProviderCode.isEmpty {
                            Text(viewModel.selectedProvider.loginProviderCode)
                                .font(.nvidiaSans(size: 11, weight: .regular))
                                .foregroundStyle(Color.gfnTextTertiary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 12)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.openNowGreen)
                }
                .frame(maxWidth: 260, alignment: .leading)
            }
            .buttonStyle(VendorProviderPickerButtonStyle())
            .disabled(viewModel.isLoadingProviders || viewModel.isLaunchingOAuth || viewModel.isAuthenticating)

            if viewModel.isLoadingProviders {
                Text("Loading provider list...")
                    .font(.nvidiaSans(size: 12, weight: .regular))
                    .foregroundStyle(Color.gfnTextTertiary)
            }
        }
    }

    private func startVendorLogin() {
        viewModel.rememberSession = true
        viewModel.acceptedTerms = true
        viewModel.launchOAuth()
    }

    private var appVersionText: String {
        let dictionary = Bundle.main.infoDictionary ?? [:]
        let version = (dictionary["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let build = (dictionary["CFBundleVersion"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !version.isEmpty, !build.isEmpty { return "\(version).\(build)" }
        if !version.isEmpty { return version }
        if !build.isEmpty { return build }
        return "Unknown"
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
        panelWidth = min(rawPanelWidth, max(size.width, 320))
        contentLeft = 24 + sideSpacing
        contentRight = 40
        contentBottom = 48
    }
}

private struct VendorContentString: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Circle()
                .fill(Color.openNowGreen)
                .frame(width: 8, height: 8)
                .padding(.top, 4)
            Text(text)
                .font(.nvidiaSans(size: 14, weight: .regular))
                .foregroundStyle(Color.gfnTextSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
