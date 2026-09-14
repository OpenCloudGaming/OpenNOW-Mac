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
                    SignInModal(viewModel: viewModel, accounts: accounts, availableSize: proxy.size, onClose: closeSignIn)
                        // Inset lives outside the panel's own background so it never paints it.
                        .padding(OPNDesign.Spacing.pageHorizontal)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background {
                            OPNDesign.Surface.scrim
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
                    .background(OPNDesign.Surface.scrim)
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
            VendorResourceImage(name: "login-wall-background", fileExtension: "png")
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
                .fill(OPNDesign.Fixed.accent)
                .frame(width: 8)
                .frame(maxHeight: .infinity)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .background(OPNDesign.Fixed.surfaceDeep)
    }

    private func marketingColumn(metrics: VendorLoginWallMetrics, headlineSize: CGFloat, logoWidth: CGFloat, logoHeight: CGFloat, showsBullets: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VendorResourceImage(name: "logo-isolated", fileExtension: "svg")
                .scaledToFit()
                .frame(width: logoWidth, height: logoHeight)
                .padding(.bottom, OPNDesign.Spacing.large)

            VStack(alignment: .leading, spacing: 0) {
                Text("OPENNOW")
                    .font(.uiSans(size: 11, weight: .bold))
                    .foregroundStyle(OPNDesign.Fixed.accent)
                    .tracking(1.4)
                    .padding(.bottom, OPNDesign.Spacing.xxSmall)

                Text("Get In. Game On.")
                    .font(.uiSans(size: headlineSize, weight: .bold))
                    .foregroundStyle(OPNDesign.Fixed.ink(0.96))
                    .lineLimit(1)
                    .padding(.bottom, OPNDesign.Spacing.medium)

                if showsBullets {
                    VStack(alignment: .leading, spacing: OPNDesign.Spacing.small) {
                        VendorContentString(text: "GeForce RTX performance on any device")
                        VendorContentString(text: "Connect to top PC game stores")
                        VendorContentString(text: "Stream thousands of supported titles")
                        VendorContentString(text: "Play hundreds of free-to-play favorites instantly")
                    }
                }
            }
            .padding(.bottom, OPNDesign.Spacing.xxxLarge)

            Button(action: openSignIn) {
                Text("GET IN")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(VendorGetInButtonStyle(size: .large, isOnFixedDarkSurface: true))
            .frame(maxWidth: 260)
            .accessibilityHint("Opens the GeForce NOW sign-in window")
        }
        .padding(.vertical, OPNDesign.Spacing.medium)
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
        guard viewModel.acceptedTerms else {
            viewModel.presentTermsOfUseIfNeeded()
            return
        }
        isShowingSignIn = true
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

private struct VendorContentString: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: OPNDesign.Spacing.medium) {
            Circle()
                .fill(OPNDesign.accent)
                .frame(width: 8, height: 8)
                .padding(.top, OPNDesign.Spacing.xxSmall)
            Text(text)
                .font(.uiSans(size: 14, weight: .regular))
                .foregroundStyle(OPNDesign.Fixed.ink(0.72))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct TermsOfUseDialog: View {
    @ObservedObject var viewModel: LoginViewModel
    var onAccept: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(OPNDesign.accent)
                .frame(height: 2)
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: OPNDesign.Spacing.medium) {
                HStack(spacing: OPNDesign.Spacing.small) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.uiSans(size: 20, weight: .bold))
                        .foregroundStyle(OPNDesign.accentInk)
                    Text("GeForce NOW Terms of Use")
                        .font(.uiSans(size: 20, weight: .bold))
                        .foregroundStyle(OPNDesign.Text.primary)
                }

                Text("OpenNOW is not affiliated with, endorsed by, or sponsored by NVIDIA. NVIDIA and GeForce NOW are trademarks of NVIDIA Corporation. You must use your own GeForce NOW account and comply with the GeForce NOW Terms of Use.")
                    .font(.uiSans(size: 13, weight: .regular))
                    .foregroundStyle(OPNDesign.Text.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                if let touURL = URL(string: "https://www.nvidia.com/en-us/geforce-now/terms-of-use/") {
                    HStack(spacing: OPNDesign.Spacing.xSmall) {
                        Image(systemName: "link")
                            .font(.uiSans(size: 11, weight: .bold))
                            .foregroundStyle(OPNDesign.accentInk)
                        Link("Read the full GeForce NOW Terms of Use", destination: touURL)
                            .font(.uiSans(size: 13, weight: .bold))
                            .foregroundStyle(OPNDesign.accentInk)
                    }
                }
            }
            .padding(OPNDesign.Spacing.card)

            HStack {
                Button("Decline", action: viewModel.declineTermsOfUse)
                    .buttonStyle(VendorTermsDeclineButtonStyle())
                Spacer(minLength: OPNDesign.Spacing.small)
                Button("Accept & Continue", action: onAccept)
                    .buttonStyle(VendorGetInButtonStyle())
            }
            .padding(.horizontal, OPNDesign.Spacing.card)
            .padding(.bottom, OPNDesign.Spacing.card)
        }
        .frame(width: 460)
        .background(OPNDesign.Surface.panel)
        .overlay { Rectangle().stroke(OPNDesign.Stroke.regular, lineWidth: 1) }
        .shadow(color: .black.opacity(0.58), radius: 28, y: 20)
        .onExitCommand(perform: viewModel.declineTermsOfUse)
    }
}

private struct VendorTermsDeclineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.uiSans(size: 13, weight: .bold))
            .foregroundStyle(OPNDesign.Text.primary)
            .padding(.horizontal, OPNDesign.Spacing.medium)
            .frame(height: 36)
            .background(configuration.isPressed ? OPNDesign.Stroke.regular : OPNDesign.Stroke.subtle)
            .overlay { Rectangle().stroke(OPNDesign.Stroke.regular, lineWidth: 1) }
    }
}
