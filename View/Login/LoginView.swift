import Combine
import SwiftUI

struct LoginView: View {
    @ObservedObject var viewModel: LoginViewModel
    let accounts: [LoginAccount]
    let onWindowTitleChange: (String?) -> Void

    @AppStorage(OPNInterfacePreferences.uiScaleKey) private var uiScale = OPNInterfacePreferences.defaultUIScale
    @AppStorage(OPNThemePreferences.appearanceKey) private var appearanceRawValue = OPNThemePreferences.Appearance.dark.rawValue

    /// Sign-in cannot reach Settings, but it inherits the appearance chosen in a previous session -
    /// and its own labels come from that palette, so forcing dark here would paint them into it.
    private var preferredColorScheme: ColorScheme? {
        switch OPNThemePreferences.Appearance(rawValue: appearanceRawValue) ?? .dark {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }
    @FocusState private var focusedField: LoginField?

    var body: some View {
        ZStack {
            LoginBackdrop()
            // A pending re-sign-in hands the window back to the login wall even though a session
            // is still active: the account being switched to has no tokens left to restore.
            if viewModel.signInRequest == nil, let activeAccount = viewModel.activeAccount, let activeSession = viewModel.activeSession {
                CatalogView(
                    account: activeAccount,
                    session: activeSession,
                    accounts: accounts,
                    signedOutAccountEmails: viewModel.signedOutAccountEmails,
                    pendingGameShortcut: $viewModel.pendingGameShortcut,
                    onSwitch: viewModel.activateAccount,
                    onAddAccount: viewModel.beginAddAccount,
                    onSignOut: { account in viewModel.signOut(account) },
                    onForget: viewModel.forgetAccount,
                    onRefreshAuth: viewModel.refreshActiveSession,
                    onWindowTitleChange: onWindowTitleChange
                )
                .id(activeSession.id)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                loginWindow
                    .padding(.top, 10)
                    .opnInterfaceScale(uiScale)
                    .environment(\.opnUIScale, 1)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if viewModel.isLaunchingOAuth || viewModel.isAuthenticating {
                VendorSplashLoadingView(message: "Connecting to GeForce NOW", onCancel: viewModel.cancelPendingLogin)
                    .transition(.opacity)
                    .zIndex(10)
                    .onExitCommand(perform: viewModel.cancelPendingLogin)
            }
        }
        .onChange(of: viewModel.requestedFocus) { _, field in focusedField = field }
        .onChange(of: viewModel.activeSession?.id) { _, _ in onWindowTitleChange(nil) }
        .preferredColorScheme(preferredColorScheme)
    }

    private var loginWindow: some View {
        ZStack(alignment: .leading) {
            LoginMarketingView(viewModel: viewModel)
            LoginFormView(viewModel: viewModel, accounts: accounts, focusedField: $focusedField)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
