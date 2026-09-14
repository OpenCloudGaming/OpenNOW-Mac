import SwiftUI

private enum SignInTab: String, CaseIterable, Identifiable {
    case browser = "Browser"
    case qrCode = "QR Code"

    var id: String { rawValue }
}

struct SignInModal: View {
    @ObservedObject var viewModel: LoginViewModel
    let accounts: [LoginAccount]
    let availableSize: CGSize
    let onClose: () -> Void

    @State private var selectedTab: SignInTab = .browser
    @State private var isProviderMenuPresented = false

    private var panelWidth: CGFloat {
        max(min(520, availableSize.width - OPNDesign.Spacing.pageHorizontal * 2), 280)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(OPNDesign.accent)
                .frame(height: 2)
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: OPNDesign.Spacing.medium) {
                HStack(alignment: .top) {
                    Text(modalTitle)
                        .font(.uiSans(size: 20, weight: .bold))
                        .foregroundStyle(OPNDesign.Text.primary)
                    Spacer(minLength: OPNDesign.Spacing.small)
                    ModalCloseButton(action: onClose)
                }

                methodSwitcher

                ViewThatFits(in: .vertical) {
                    modalTabContent
                    ScrollView(.vertical) { modalTabContent }
                }
            }
            .padding(OPNDesign.Spacing.xLarge)
        }
        // Height stays intrinsic up to the window's. Without the cap a ScrollView child reports its
        // full content height as its ideal size, so ViewThatFits picks it and the modal then paints
        // past the window edge — the cut-off QR. At the cap the modal stops resizing and the
        // content scrolls instead.
        .frame(width: panelWidth)
        .frame(maxHeight: max(availableSize.height - OPNDesign.Spacing.pageHorizontal * 2, 320))
        .background(OPNDesign.Surface.panel)
        .overlay { Rectangle().stroke(OPNDesign.Stroke.regular, lineWidth: 1) }
        .shadow(color: .black.opacity(0.58), radius: 28, y: 20)
        .onExitCommand(perform: onClose)
        .onAppear {
            if selectedTab == .qrCode, viewModel.deviceCodeUserCode.isEmpty, !viewModel.isRequestingDeviceCode {
                viewModel.rememberSession = true
                viewModel.launchDeviceCodeThroughTermsGate()
            }
        }
    }

    private var modalTitle: String {
        switch viewModel.signInRequest {
        case .reauthenticate: return "Sign in to switch account"
        case .addAccount: return "Add another account"
        case nil: return "Sign in to GeForce NOW"
        }
    }

    /// Explains why the wall is up over a session that is still signed in, and offers the way back.
    private var signInRequestBanner: (label: String, message: String)? {
        switch viewModel.signInRequest {
        case .reauthenticate:
            guard let account = viewModel.reauthAccount else { return nil }
            return ("SWITCHING ACCOUNT", "\(account.displayName) is signed out, so its saved session is gone. Sign in again to switch to it.")
        case .addAccount:
            return ("ADDING ACCOUNT", "Sign in with the account you want to add. The account you are already signed in to stays saved and switchable.")
        case nil:
            return nil
        }
    }

    private var methodSwitcher: some View {
        HStack(spacing: 0) {
            ForEach(SignInTab.allCases) { tab in
                let isSelected = selectedTab == tab
                Button {
                    selectedTab = tab
                    if tab == .qrCode, viewModel.deviceCodeUserCode.isEmpty, !viewModel.isRequestingDeviceCode {
                        viewModel.rememberSession = true
                        viewModel.launchDeviceCodeThroughTermsGate()
                    }
                } label: {
                    HStack(spacing: OPNDesign.Spacing.xSmall) {
                        Image(systemName: tab == .qrCode ? "qrcode" : "globe")
                            .font(.uiSans(size: 11, weight: .bold))
                        Text(tab.rawValue.uppercased())
                            .font(.uiSans(size: 11, weight: .bold))
                            .tracking(0.8)
                    }
                    .foregroundStyle(isSelected ? OPNDesign.onAccent : OPNDesign.Text.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background(isSelected ? OPNDesign.accent : OPNDesign.Fill.neutral(0.06))
                    .overlay {
                        Rectangle()
                            .stroke(isSelected ? OPNDesign.accent : OPNDesign.Stroke.regular, lineWidth: 1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    private var modalTabContent: some View {
        VStack(alignment: .leading, spacing: OPNDesign.Spacing.medium) {
            if let banner = signInRequestBanner {
                requestBannerView(banner)
            }

            if !accounts.isEmpty {
                savedAccountsSection
            }

            switch selectedTab {
            case .qrCode:
                qrCodeContent
            case .browser:
                browserContent
            }
        }
    }

    private func requestBannerView(_ banner: (label: String, message: String)) -> some View {
        VStack(alignment: .leading, spacing: OPNDesign.Spacing.xxSmall) {
            Text(banner.label)
                .font(.uiSans(size: 11, weight: .bold))
                .foregroundStyle(OPNDesign.accentInk)
                .tracking(0.8)
            Text(banner.message)
                .font(.uiSans(size: 13, weight: .regular))
                .foregroundStyle(OPNDesign.Text.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            if viewModel.canCancelReauthentication {
                Button("Keep using the current account", action: onClose)
                    .buttonStyle(.plain)
                    .font(.uiSans(size: 12, weight: .bold))
                    .foregroundStyle(OPNDesign.accentInk)
            }
        }
        .padding(OPNDesign.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OPNDesign.Stroke.subtle)
        .overlay { Rectangle().stroke(OPNDesign.Stroke.regular, lineWidth: 1) }
    }

    private var qrCodeContent: some View {
        VStack(alignment: .leading, spacing: OPNDesign.Spacing.medium) {
            serviceProviderHeader

            providerDropdown {
                viewModel.rememberSession = true
                viewModel.launchDeviceCodeThroughTermsGate()
            }

            if !viewModel.deviceCodeUserCode.isEmpty {
                VStack(spacing: OPNDesign.Spacing.small) {
                    DeviceCodeQRView(payload: viewModel.deviceCodeVerificationURI)
                        .frame(width: 156, height: 156)

                    VStack(spacing: 4) {
                        Text("SCAN WITH PHONE OR ENTER CODE")
                            .font(.uiSans(size: 11, weight: .bold))
                            .foregroundStyle(OPNDesign.Text.tertiary)
                            .tracking(0.8)

                        Text(viewModel.deviceCodeUserCode)
                            .font(.uiSans(size: 24, weight: .bold))
                            .monospacedDigit()
                            .tracking(2.0)
                            .foregroundStyle(OPNDesign.Text.primary)

                        if let url = URL(string: viewModel.deviceCodeVerificationURI) {
                            Link(destination: url) {
                                Text(viewModel.deviceCodeVerificationURI)
                                    .font(.uiSans(size: 11, weight: .regular))
                                    .foregroundStyle(OPNDesign.accentInk)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                            }
                        }
                    }

                    Button {
                        viewModel.rememberSession = true
                        viewModel.launchDeviceCodeThroughTermsGate()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("GET NEW CODE")
                        }
                        .font(.uiSans(size: 11, weight: .bold))
                        .foregroundStyle(OPNDesign.Text.secondary)
                        .tracking(0.6)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isRequestingDeviceCode || viewModel.isAuthenticating)
                }
                .frame(maxWidth: .infinity)
            } else {
                Button {
                    viewModel.rememberSession = true
                    viewModel.launchDeviceCodeThroughTermsGate()
                } label: {
                    HStack(spacing: 4) {
                        if viewModel.isRequestingDeviceCode {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(viewModel.isRequestingDeviceCode ? "GETTING CODE..." : "GET QR CODE")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(VendorGetInButtonStyle())
                .disabled(viewModel.isRequestingDeviceCode || viewModel.isAuthenticating)
            }

            if !viewModel.validationMessage.isEmpty || !viewModel.successMessage.isEmpty {
                statusMessageView
            }
        }
    }

    private var browserContent: some View {
        VStack(alignment: .leading, spacing: OPNDesign.Spacing.medium) {
            serviceProviderHeader

            providerDropdown()

            if viewModel.isLoadingProviders {
                Text("Loading provider list...")
                    .font(.uiSans(size: 12, weight: .regular))
                    .foregroundStyle(OPNDesign.Text.tertiary)
            }

            Button {
                viewModel.rememberSession = true
                viewModel.launchOAuthThroughTermsGate()
            } label: {
                Text(viewModel.hasPendingOAuth ? "REOPEN" : "GET IN")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(VendorGetInButtonStyle())
            .disabled(viewModel.isLaunchingOAuth || viewModel.isAuthenticating)
            .accessibilityHint("Opens \(viewModel.selectedProvider.title) authentication in your browser")

            if !viewModel.validationMessage.isEmpty || !viewModel.successMessage.isEmpty {
                statusMessageView
            }
        }
    }

    private var statusMessageView: some View {
        Text(viewModel.validationMessage.isEmpty ? viewModel.successMessage : viewModel.validationMessage)
            .font(.uiSans(size: 13, weight: .regular))
            .foregroundStyle(viewModel.validationMessage.isEmpty ? OPNDesign.accentInk : OPNDesign.Semantic.warning)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var savedAccountsSection: some View {
        VStack(alignment: .leading, spacing: OPNDesign.Spacing.xSmall) {
            Text("SAVED ACCOUNTS")
                .font(.uiSans(size: 11, weight: .bold))
                .foregroundStyle(OPNDesign.Text.tertiary)
                .tracking(0.8)

            VStack(spacing: OPNDesign.Spacing.xSmall) {
                ForEach(accounts) { account in
                    SavedAccountCard(
                        account: account,
                        needsSignIn: viewModel.signedOutAccountEmails.contains(account.email)
                    ) { viewModel.activateSavedAccount(account) }
                    .disabled(viewModel.isLaunchingOAuth || viewModel.isAuthenticating)
                }
            }
        }
    }

    private func providerDropdown(afterSelect: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isProviderMenuPresented.toggle()
            } label: {
                HStack(spacing: 8) {
                    Text(viewModel.selectedProvider.title)
                        .font(.uiSans(size: 13, weight: .bold))
                        .foregroundStyle(OPNDesign.Text.primary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: isProviderMenuPresented ? "chevron.up" : "chevron.down")
                        .font(.uiSans(size: 10, weight: .bold))
                        .foregroundStyle(OPNDesign.Text.secondary)
                }
                .padding(.horizontal, OPNDesign.Spacing.controlRow)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(OPNDesign.Fill.neutral(0.08))
                .overlay { Rectangle().stroke(OPNDesign.Stroke.regular, lineWidth: 1) }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isLaunchingOAuth || viewModel.isAuthenticating || viewModel.isRequestingDeviceCode)
            .accessibilityLabel("Service provider, \(viewModel.selectedProvider.title)")

            if isProviderMenuPresented {
                OPNDropdownPanel(
                    items: viewModel.providers.map { provider in
                        OPNDropdownItem(
                            id: provider.id,
                            title: provider.title,
                            isSelected: provider.id == viewModel.selectedProvider.id
                        ) {
                            viewModel.selectProvider(provider)
                            isProviderMenuPresented = false
                            afterSelect?()
                        }
                    }
                )
                .padding(.top, OPNDesign.Spacing.xxSmall)
            }
        }
    }

    private var serviceProviderHeader: some View {
        Text("SERVICE PROVIDER")
            .font(.uiSans(size: 11, weight: .bold))
            .foregroundStyle(OPNDesign.Text.tertiary)
            .tracking(0.8)
    }
}

/// One saved account on the login wall. Signing out ends a session but keeps the account row, so a
/// listed account is not necessarily one this build can still restore — the trailing label says
/// which, and both branches start something: a restore, or a fresh sign-in for that account.
private struct SavedAccountCard: View {
    let account: LoginAccount
    let needsSignIn: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: OPNDesign.Spacing.small) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayName.isEmpty ? account.email : account.displayName)
                        .font(.uiSans(size: 14, weight: .bold))
                        .foregroundStyle(OPNDesign.Text.primary)
                        .lineLimit(1)
                    Text(account.email)
                        .font(.uiSans(size: 11, weight: .regular))
                        .foregroundStyle(OPNDesign.Text.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: OPNDesign.Spacing.small)

                Text(needsSignIn ? "SIGN IN AGAIN" : "CONTINUE")
                    .font(.uiSans(size: 11, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(needsSignIn ? OPNDesign.Text.secondary : OPNDesign.accentInk)
            }
            .padding(.horizontal, OPNDesign.Spacing.controlRow)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .background(isHovering ? OPNDesign.Stroke.regular : OPNDesign.Stroke.subtle)
            .overlay {
                Rectangle()
                    .stroke(isHovering ? OPNDesign.Stroke.strong : OPNDesign.Stroke.regular, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityHint(needsSignIn ? "Signs in again to use \(account.email)" : "Continues as \(account.email)")
    }
}

private struct ModalCloseButton: View {
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.uiSans(size: 11, weight: .bold))
                .foregroundStyle(isHovering ? OPNDesign.Text.primary : OPNDesign.Text.secondary)
                .frame(width: 28, height: 28)
                .background(isHovering ? OPNDesign.Stroke.subtle : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("Close")
    }
}
