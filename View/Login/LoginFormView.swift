import Combine
import SwiftUI

struct LoginFormView: View {
    @ObservedObject var viewModel: LoginViewModel
    let accounts: [LoginAccount]
    var focusedField: FocusState<LoginField?>.Binding

    @State private var isShowingSignIn = false

    var body: some View {
        GeometryReader { proxy in
            let metrics = VendorLoginWallMetrics(size: proxy.size)

            ZStack(alignment: .leading) {
                leftPanel(metrics: metrics)
                    .frame(width: metrics.panelWidth, height: proxy.size.height)

                if isShowingSignIn {
                    SignInModal(viewModel: viewModel, availableSize: proxy.size, onClose: closeSignIn)
                        // Inset lives outside the panel's own background so it never paints it.
                        .padding(OpenNOWDesign.Spacing.pageHorizontal)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background {
                            OpenNOWDesign.Surface.scrim
                                .contentShape(Rectangle())
                                .onTapGesture { closeSignIn() }
                        }
                        .transition(.opacity)
                }

                if viewModel.isShowingTermsOfUse {
                    TermsOfUseDialog(
                        viewModel: viewModel,
                        onAccept: {
                            viewModel.acceptTermsOfUse()
                            isShowingSignIn = true
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(OpenNOWDesign.Surface.scrim)
                    .transition(.opacity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
        .animation(.snappy, value: isShowingSignIn)
        .animation(.snappy, value: viewModel.isShowingTermsOfUse)
        // A switch to a signed-out account lands here with the wall behind it; open the sign-in
        // panel straight away rather than making the user find GET IN again.
        .onAppear { if viewModel.signInRequest != nil { isShowingSignIn = true } }
        .onChange(of: viewModel.signInRequest) { _, request in
            if request != nil { isShowingSignIn = true }
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

            ViewThatFits(in: .vertical) {
                marketingColumn(metrics: metrics, headlineSize: 34, logoWidth: 156, logoHeight: 88, showsBullets: true)
                marketingColumn(metrics: metrics, headlineSize: 30, logoWidth: 140, logoHeight: 79, showsBullets: false)
                marketingColumn(metrics: metrics, headlineSize: 26, logoWidth: 124, logoHeight: 70, showsBullets: false)
            }
            .frame(width: metrics.panelWidth, height: metrics.height)

            Rectangle()
                .fill(OpenNOWDesign.accent)
                .frame(width: 8)
                .frame(maxHeight: .infinity)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .background(.black)
    }

    private func marketingColumn(metrics: VendorLoginWallMetrics, headlineSize: CGFloat, logoWidth: CGFloat, logoHeight: CGFloat, showsBullets: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VendorResourceImage(name: "logo-isolated", fileExtension: "svg")
                .scaledToFit()
                .frame(width: logoWidth, height: logoHeight)
                .padding(.bottom, OpenNOWDesign.Spacing.large)

            VStack(alignment: .leading, spacing: 0) {
                Text("OPENNOW")
                    .font(.nvidiaSans(size: 11, weight: .bold))
                    .foregroundStyle(OpenNOWDesign.accent)
                    .tracking(1.4)
                    .padding(.bottom, OpenNOWDesign.Spacing.xxSmall)

                Text("Get In. Game On.")
                    .font(.nvidiaSans(size: headlineSize, weight: .bold))
                    .foregroundStyle(OpenNOWDesign.Text.primary)
                    .lineLimit(1)
                    .padding(.bottom, OpenNOWDesign.Spacing.medium)

                if showsBullets {
                    VStack(alignment: .leading, spacing: OpenNOWDesign.Spacing.small) {
                        VendorContentString(text: "GeForce RTX performance on any device")
                        VendorContentString(text: "Connect to top PC game stores")
                        VendorContentString(text: "Stream thousands of supported titles")
                        VendorContentString(text: "Play hundreds of free-to-play favorites instantly")
                    }
                }
            }
            .padding(.bottom, OpenNOWDesign.Spacing.xxxLarge)

            Button(action: openSignIn) {
                Text("GET IN")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(VendorGetInButtonStyle(size: .large))
            .frame(maxWidth: 260)
            .accessibilityHint("Opens the GeForce NOW sign-in window")
        }
        .padding(.vertical, OpenNOWDesign.Spacing.medium)
        .padding(.leading, metrics.contentLeft)
        .padding(.trailing, metrics.contentRight)
        .frame(width: metrics.panelWidth, alignment: .leading)
    }

    /// Closing the panel also drops a pending re-sign-in, which is what returns the window to the
    /// account that is still signed in.
    private func closeSignIn() {
        isShowingSignIn = false
        viewModel.cancelReauthentication()
    }

    private func openSignIn() {
        viewModel.rememberSession = true
        if viewModel.acceptedTerms {
            isShowingSignIn = true
        } else {
            viewModel.presentTermsOfUseIfNeeded()
        }
    }
}

private struct VendorLoginWallMetrics {
    let height: CGFloat
    let panelWidth: CGFloat
    let contentLeft: CGFloat
    let contentRight: CGFloat

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
    }
}

private struct ProviderCard: View {
    let provider: LoginProvider
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: OpenNOWDesign.Spacing.small) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.title)
                        .font(.nvidiaSans(size: 14, weight: .bold))
                        .foregroundStyle(OpenNOWDesign.Text.primary)
                        .lineLimit(1)
                    if !provider.loginProviderCode.isEmpty {
                        Text(provider.loginProviderCode)
                            .font(.nvidiaSans(size: 11, weight: .regular))
                            .foregroundStyle(OpenNOWDesign.Text.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: OpenNOWDesign.Spacing.small)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.nvidiaSans(size: 12, weight: .bold))
                        .foregroundStyle(OpenNOWDesign.accent)
                }
            }
            .padding(.horizontal, OpenNOWDesign.Spacing.controlRow)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .background(Color.white.opacity(isHovering ? 0.16 : 0.08))
            .overlay {
                Rectangle()
                    .stroke(isSelected ? OpenNOWDesign.accent : (isHovering ? OpenNOWDesign.Stroke.strong : OpenNOWDesign.Stroke.regular), lineWidth: isSelected ? 2 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct VendorContentString: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: OpenNOWDesign.Spacing.medium) {
            Circle()
                .fill(OpenNOWDesign.accent)
                .frame(width: 8, height: 8)
                .padding(.top, OpenNOWDesign.Spacing.xxSmall)
            Text(text)
                .font(.nvidiaSans(size: 14, weight: .regular))
                .foregroundStyle(OpenNOWDesign.Text.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SignInModal: View {
    @ObservedObject var viewModel: LoginViewModel
    let availableSize: CGSize
    let onClose: () -> Void

    private var panelWidth: CGFloat {
        max(min(520, availableSize.width - OpenNOWDesign.Spacing.pageHorizontal * 2), 280)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(OpenNOWDesign.accent)
                .frame(height: 2)
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: OpenNOWDesign.Spacing.medium) {
                HStack(alignment: .top) {
                    Text(modalTitle)
                        .font(.nvidiaSans(size: 20, weight: .bold))
                        .foregroundStyle(OpenNOWDesign.Text.primary)
                    Spacer(minLength: OpenNOWDesign.Spacing.small)
                    ModalCloseButton(action: onClose)
                }

                ViewThatFits(in: .vertical) {
                    formContent
                    ScrollView(.vertical) { formContent }
                }
            }
            .padding(OpenNOWDesign.Spacing.xLarge)
        }
        // Height stays intrinsic. A finite `maxHeight` here would not cap the panel — it takes the
        // proposed height clamped to the max, and the parent proposes the whole window — so the
        // background and border painted a full-height panel with the content centred in it.
        // Overflow is already handled by the `ViewThatFits` above, whose ScrollView branch expands.
        .frame(width: panelWidth)
        .background(OpenNOWDesign.Surface.panel)
        .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.regular, lineWidth: 1) }
        .shadow(color: .black.opacity(0.58), radius: 28, y: 20)
        .onExitCommand(perform: onClose)
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

    private var formContent: some View {
        VStack(alignment: .leading, spacing: OpenNOWDesign.Spacing.medium) {
            if let banner = signInRequestBanner {
                VStack(alignment: .leading, spacing: OpenNOWDesign.Spacing.xxSmall) {
                    Text(banner.label)
                        .font(.nvidiaSans(size: 11, weight: .bold))
                        .foregroundStyle(OpenNOWDesign.accent)
                        .tracking(0.8)
                    Text(banner.message)
                        .font(.nvidiaSans(size: 13, weight: .regular))
                        .foregroundStyle(OpenNOWDesign.Text.secondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if viewModel.canCancelReauthentication {
                        Button("Keep using the current account", action: onClose)
                            .buttonStyle(.plain)
                            .font(.nvidiaSans(size: 12, weight: .bold))
                            .foregroundStyle(OpenNOWDesign.accent)
                    }
                }
                .padding(OpenNOWDesign.Spacing.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.06))
                .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.regular, lineWidth: 1) }
            }

            VStack(alignment: .leading, spacing: OpenNOWDesign.Spacing.xSmall) {
                Text("SERVICE PROVIDER")
                    .font(.nvidiaSans(size: 11, weight: .bold))
                    .foregroundStyle(OpenNOWDesign.Text.tertiary)
                    .tracking(0.8)

                VStack(spacing: OpenNOWDesign.Spacing.xSmall) {
                    ForEach(viewModel.providers) { provider in
                        ProviderCard(
                            provider: provider,
                            isSelected: provider.id == viewModel.selectedProvider.id
                        ) { viewModel.selectProvider(provider) }
                        .disabled(viewModel.isLoadingProviders || viewModel.isLaunchingOAuth || viewModel.isAuthenticating)
                    }
                }

                if viewModel.isLoadingProviders {
                    Text("Loading provider list...")
                        .font(.nvidiaSans(size: 12, weight: .regular))
                        .foregroundStyle(OpenNOWDesign.Text.tertiary)
                }
            }

            Button {
                viewModel.rememberSession = true
                viewModel.launchOAuth()
            } label: {
                Text(viewModel.hasPendingOAuth ? "REOPEN" : "GET IN")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(VendorGetInButtonStyle())
            .disabled(viewModel.isLaunchingOAuth || viewModel.isAuthenticating)
            .accessibilityHint("Opens \(viewModel.selectedProvider.title) authentication in your browser")

            Button {
                viewModel.rememberSession = true
                viewModel.launchDeviceCodeOAuth()
            } label: {
                Text("BROWSER SIGN-IN")
                    .font(.nvidiaSans(size: 12, weight: .bold))
                    .foregroundStyle(OpenNOWDesign.accent)
                    .tracking(0.8)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isLaunchingOAuth || viewModel.isAuthenticating)
            .accessibilityHint("Opens NVIDIA browser authentication")

            if !viewModel.deviceCodeUserCode.isEmpty {
                VStack(alignment: .leading, spacing: OpenNOWDesign.Spacing.xSmall) {
                    Text("ENTER THIS CODE IN YOUR BROWSER")
                        .font(.nvidiaSans(size: 11, weight: .bold))
                        .foregroundStyle(OpenNOWDesign.Text.tertiary)
                        .tracking(0.8)
                    Text(viewModel.deviceCodeUserCode)
                        .font(.nvidiaSans(size: 22, weight: .bold))
                        .monospacedDigit()
                        .tracking(1.6)
                        .foregroundStyle(OpenNOWDesign.Text.primary)
                    Text(viewModel.deviceCodeVerificationURI)
                        .font(.nvidiaSans(size: 12, weight: .regular))
                        .foregroundStyle(OpenNOWDesign.Text.secondary)
                        .lineLimit(2)
                }
            }

            if !viewModel.validationMessage.isEmpty || !viewModel.successMessage.isEmpty {
                Text(viewModel.validationMessage.isEmpty ? viewModel.successMessage : viewModel.validationMessage)
                    .font(.nvidiaSans(size: 13, weight: .regular))
                    .foregroundStyle(viewModel.validationMessage.isEmpty ? OpenNOWDesign.accent : .orange)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ModalCloseButton: View {
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.nvidiaSans(size: 11, weight: .bold))
                .foregroundStyle(isHovering ? OpenNOWDesign.Text.primary : OpenNOWDesign.Text.secondary)
                .frame(width: 28, height: 28)
                .background(isHovering ? Color.white.opacity(0.08) : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("Close")
    }
}

private struct TermsOfUseDialog: View {
    @ObservedObject var viewModel: LoginViewModel
    var onAccept: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(OpenNOWDesign.accent)
                .frame(height: 2)
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: OpenNOWDesign.Spacing.medium) {
                HStack(spacing: OpenNOWDesign.Spacing.small) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.nvidiaSans(size: 20, weight: .bold))
                        .foregroundStyle(OpenNOWDesign.accent)
                    Text("GeForce NOW Terms of Use")
                        .font(.nvidiaSans(size: 20, weight: .bold))
                        .foregroundStyle(OpenNOWDesign.Text.primary)
                }

                Text("OpenNOW is not affiliated with, endorsed by, or sponsored by NVIDIA. NVIDIA and GeForce NOW are trademarks of NVIDIA Corporation. You must use your own GeForce NOW account and comply with the GeForce NOW Terms of Use.")
                    .font(.nvidiaSans(size: 13, weight: .regular))
                    .foregroundStyle(OpenNOWDesign.Text.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                if let touURL = URL(string: "https://www.nvidia.com/en-us/geforce-now/terms-of-use/") {
                    HStack(spacing: OpenNOWDesign.Spacing.xSmall) {
                        Image(systemName: "link")
                            .font(.nvidiaSans(size: 11, weight: .bold))
                            .foregroundStyle(OpenNOWDesign.accent)
                        Link("Read the full GeForce NOW Terms of Use", destination: touURL)
                            .font(.nvidiaSans(size: 13, weight: .bold))
                            .foregroundStyle(OpenNOWDesign.accent)
                    }
                }
            }
            .padding(OpenNOWDesign.Spacing.card)

            HStack {
                Button("Decline", action: viewModel.declineTermsOfUse)
                    .buttonStyle(VendorTermsDeclineButtonStyle())
                Spacer(minLength: OpenNOWDesign.Spacing.small)
                Button("Accept & Continue", action: onAccept)
                    .buttonStyle(VendorGetInButtonStyle())
            }
            .padding(.horizontal, OpenNOWDesign.Spacing.card)
            .padding(.bottom, OpenNOWDesign.Spacing.card)
        }
        .frame(width: 460)
        .background(OpenNOWDesign.Surface.panel)
        .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.regular, lineWidth: 1) }
        .shadow(color: .black.opacity(0.58), radius: 28, y: 20)
        .onExitCommand(perform: viewModel.declineTermsOfUse)
    }
}

private struct VendorTermsDeclineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.nvidiaSans(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, OpenNOWDesign.Spacing.medium)
            .frame(height: 36)
            .background(Color.white.opacity(configuration.isPressed ? 0.16 : 0.08))
            .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.regular, lineWidth: 1) }
    }
}
