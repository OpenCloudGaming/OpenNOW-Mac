//  The Detach New Session window: one more account streaming beside the ones already running.
//
//  Browse and launch from an account-owned catalog without activating it in the main window.
//  Explicit account-management actions use the main window's login flow.

import AppKit
import SwiftData
import SwiftUI

struct DetachedSessionView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \LoginAccount.lastLoginAt, order: .reverse) private var accounts: [LoginAccount]
    @Query(sort: \LoginSession.issuedAt, order: .reverse) private var sessions: [LoginSession]
    @AppStorage(OPNInterfacePreferences.uiScaleKey) private var uiScale = OPNInterfacePreferences.defaultUIScale
    @AppStorage(OPNThemePreferences.accentColorKey) private var accentColorRawValue = OPNThemePreferences.AccentColor.cloudGreen.rawValue
    @AppStorage(OPNThemePreferences.appearanceKey) private var appearanceRawValue = OPNThemePreferences.Appearance.dark.rawValue
    @EnvironmentObject private var systemAppearance: OPNSystemAppearance
    @ObservedObject private var devices = ControllerMappingDevices.shared
    @State private var viewModel = DetachedSessionViewModel()
    @State private var windowTitle = "Detached Session"
    // swiftlint:disable:next view_constructs_service -- window-owned UI state, not a service; DESIGN.md Confirmation Modal
    @StateObject private var confirmation = OPNConfirmationPresentation()
    // swiftlint:disable:next view_constructs_service -- window-owned UI state, not a service; DESIGN.md Report an Issue Modal
    @StateObject private var reportIssue = OPNReportIssuePresentation()
    @State private var windowReference = DetachedSessionWindowReference()

    private let registry = OPNGameSessionRegistry.shared

    private var rows: [DetachedAccountRow] {
        DetachedSessionModel.rows(candidates: candidates, ownedAccountIDs: Set(registry.sessions.map(\.accountID)))
    }

    private var candidates: [DetachedAccountCandidate] {
        accounts.map { account in
            DetachedAccountCandidate(
                email: account.email,
                displayName: account.displayName,
                membershipTier: account.membershipTier,
                accountID: account.resolveStableAccountID(),
                hasSavedSession: savedSession(for: account) != nil
            )
        }
    }

    private func savedSession(for account: LoginAccount) -> LoginSession? {
        sessions.first { $0.accountEmail == account.email && !$0.accessToken.isEmpty }
    }

    private var preferredColorScheme: ColorScheme? {
        switch OPNThemePreferences.Appearance(rawValue: appearanceRawValue) ?? .dark {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }

    var body: some View {
        let _ = OPNDesign.applyTheme(
            accent: OPNThemePreferences.AccentColor(rawValue: accentColorRawValue) ?? .cloudGreen,
            appearance: OPNThemePreferences.Appearance(rawValue: appearanceRawValue) ?? .dark,
            systemColorScheme: systemAppearance.colorScheme
        )
        Group {
            switch viewModel.phase {
            case .setup:
                setup
            case .catalog(let email):
                catalog(for: email)
            }
        }
        .modifier(DetachedSessionModalHost(confirmation: confirmation, reportIssue: reportIssue))
        .frame(minWidth: 640, minHeight: 480)
        .ignoresSafeArea()
        .background(OPNDesign.Surface.app)
        .background(DetachedSessionWindowConfigurator(title: windowTitle, reference: windowReference))
        .background(OPNInterfaceScaleDensityBooster(scale: uiScale))
        .environment(\.opnUIScale, uiScale)
        .opnObservingCornerStyle()
        .opnObservingLiquidGlass()
        .preferredColorScheme(preferredColorScheme)
        .onAppear { devices.refresh() }
        .onChange(of: viewModel.phase) { _, phase in
            guard phase == .setup else { return }
            windowTitle = "Detached Session"
        }
        .onDisappear {
            viewModel.discardPendingSelection()
            confirmation.dismiss()
        }
    }

    private func requestMainAccountAction(_ request: OPNMainAccountActions.Request) {
        OPNMainWindowAccountHandoff.shared.begin(from: windowReference.window)
        if OPNMainWindow.needsPresentation {
            OPNDockIconController.showDockIcon()
            openWindow(id: OPNMainWindow.identifier)
        }
        OPNMainAccountActions.shared.request(request)
    }

    private func requestAccountMutation(_ account: LoginAccount, request: (OPNMainAccountActions.Target) -> OPNMainAccountActions.Request) {
        guard let storedAccounts = try? modelContext.fetch(FetchDescriptor<LoginAccount>()),
              let currentAccount = storedAccounts.first(where: { $0 === account }),
              !modelContext.deletedModelsArray.contains(where: { $0 === account }) else {
            confirmation.present(
                .init(eyebrow: "ACCOUNT", title: "Account action unavailable",
                      message: "This saved account changed or was removed. Choose the account again before continuing.",
                      actions: [OPNConfirmationAction("BACK") { [weak confirmation = confirmation] in confirmation?.dismiss() }]),
                onDismiss: viewModel.backToSetup
            )
            return
        }
        requestMainAccountAction(request(.init(account: currentAccount)))
    }

    private var selectedAccount: LoginAccount? {
        guard let email = viewModel.selectedEmail else { return nil }
        return accounts.first { $0.email == email }
    }

    // MARK: - Setup

    private var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OPNDesign.Spacing.large(scale: uiScale)) {
                header
                accountSection
                controllerSection
                footer
            }
            .padding(.horizontal, OPNDesign.Spacing.pageHorizontal(scale: uiScale))
            .padding(.top, OPNDesign.Spacing.xxLarge(scale: uiScale))
            .padding(.bottom, OPNDesign.Spacing.xLarge(scale: uiScale))
            .frame(maxWidth: 720 * uiScale)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: OPNDesign.Spacing.xSmall(scale: uiScale)) {
            Text("DETACH NEW SESSION")
                .font(.settingsFont(size: 11 * uiScale, weight: .bold))
                .foregroundStyle(OPNDesign.accentInk)
            Text("Stream with another account")
                .font(.settingsFont(size: 24 * uiScale, weight: .bold))
                .foregroundStyle(OPNDesign.Text.primary)
            Text("This window streams for the account you pick, beside the games already running. Each account plays its own session.")
                .font(.settingsFont(size: 13 * uiScale))
                .foregroundStyle(OPNDesign.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: OPNDesign.Spacing.small(scale: uiScale)) {
            sectionTitle("1  Account")
            if rows.isEmpty {
                note("No saved accounts yet. Add one to start.")
            }
            ForEach(rows) { row in
                accountRow(row)
            }
            Button {
                requestMainAccountAction(.addAccount)
            } label: {
                Label("Add account…", systemImage: "person.badge.plus")
            }
            .buttonStyle(OPNModalSecondaryButtonStyle(uiScale: uiScale))
            .help("Signs in another account in the main window without signing out the others.")
        }
    }

    private func accountRow(_ row: DetachedAccountRow) -> some View {
        let isSelected = viewModel.selectedEmail == row.email
        return Button {
            guard row.availability.isSelectable else { return }
            viewModel.selectedEmail = row.email
        } label: {
            HStack(spacing: OPNDesign.Spacing.small(scale: uiScale)) {
                VStack(alignment: .leading, spacing: OPNDesign.Spacing.xxSmall(scale: uiScale)) {
                    Text(row.displayName.isEmpty ? row.email : row.displayName)
                        .font(.settingsFont(size: 14 * uiScale, weight: .bold))
                        .foregroundStyle(OPNDesign.Text.primary)
                        .lineLimit(1)
                    Text("\(row.email) · \(row.availability.detail)")
                        .font(.settingsFont(size: 11 * uiScale))
                        .foregroundStyle(OPNDesign.Text.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(OPNDesign.accentInk)
                }
            }
            .padding(OPNDesign.Spacing.small(scale: uiScale))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OPNCornerShape(role: .card, scale: uiScale).fill(OPNDesign.Surface.panel))
            .overlay {
                OPNCornerShape(role: .card, scale: uiScale)
                    .strokeBorder(isSelected ? OPNDesign.accent : OPNDesign.Stroke.subtle, lineWidth: isSelected ? 2 : 1)
            }
            .opacity(row.availability.isSelectable ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!row.availability.isSelectable)
        .accessibilityLabel(row.displayName)
        .accessibilityValue(row.availability.detail)
    }

    private var controllerSection: some View {
        VStack(alignment: .leading, spacing: OPNDesign.Spacing.small(scale: uiScale)) {
            sectionTitle("2  Controllers")
            if devices.orderedDevices.isEmpty {
                note("No controllers connected. Connect one and it appears here.")
            }
            ForEach(devices.orderedDevices) { device in
                controllerRow(device)
            }
            if !devices.orderedDevices.isEmpty {
                handOffRow
            }
        }
    }

    private func controllerRow(_ device: ControllerMappingDevice) -> some View {
        HStack(spacing: OPNDesign.Spacing.small(scale: uiScale)) {
            VStack(alignment: .leading, spacing: OPNDesign.Spacing.xxSmall(scale: uiScale)) {
                Text(device.name)
                    .font(.settingsFont(size: 14 * uiScale, weight: .bold))
                    .foregroundStyle(OPNDesign.Text.primary)
                    .lineLimit(1)
                Text(viewModel.isControllerEnabled(device.id) ? "Plays in this stream" : "Disabled in this stream")
                    .font(.settingsFont(size: 11 * uiScale))
                    .foregroundStyle(OPNDesign.Text.tertiary)
            }
            Spacer(minLength: 0)
            Text("Disable in this stream")
                .font(.settingsFont(size: 11 * uiScale))
                .foregroundStyle(OPNDesign.Text.secondary)
            Toggle(
                isOn: Binding(
                    get: { !viewModel.isControllerEnabled(device.id) },
                    set: { viewModel.setController(device.id, enabled: !$0) }
                ),
                uiScale: uiScale
            )
            .accessibilityLabel("Disable \(device.name) in this stream")
        }
        .padding(OPNDesign.Spacing.small(scale: uiScale))
        .background(OPNCornerShape(role: .card, scale: uiScale).fill(OPNDesign.Surface.panel))
        .overlay { OPNCornerShape(role: .card, scale: uiScale).strokeBorder(OPNDesign.Stroke.subtle, lineWidth: 1) }
    }

    private var handOffRow: some View {
        HStack(spacing: OPNDesign.Spacing.small(scale: uiScale)) {
            VStack(alignment: .leading, spacing: OPNDesign.Spacing.xxSmall(scale: uiScale)) {
                Text("Take these controllers from the other streams")
                    .font(.settingsFont(size: 13 * uiScale, weight: .bold))
                    .foregroundStyle(OPNDesign.Text.primary)
                Text("One tap sets a controller per player. Turn it back on from each stream's Controllers panel.")
                    .font(.settingsFont(size: 11 * uiScale))
                    .foregroundStyle(OPNDesign.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Toggle(isOn: Binding(get: { viewModel.takesPadsFromOtherStreams }, set: { viewModel.takesPadsFromOtherStreams = $0 }), uiScale: uiScale)
                .accessibilityLabel("Take these controllers from the other streams")
        }
        .padding(OPNDesign.Spacing.small(scale: uiScale))
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("CHOOSE A GAME") {
                guard let account = selectedAccount, let accountID = account.resolveStableAccountID(),
                      let row = rows.first(where: { $0.email == account.email }) else { return }
                viewModel.confirm(row: row, accountID: accountID)
            }
            .buttonStyle(VendorGetInButtonStyle(uiScale: uiScale))
            .disabled(selectedAccount == nil)
            .opacity(selectedAccount == nil ? 0.46 : 1)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.settingsFont(size: 11 * uiScale, weight: .bold))
            .foregroundStyle(OPNDesign.Text.secondary)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.settingsFont(size: 12 * uiScale))
            .foregroundStyle(OPNDesign.Text.tertiary)
    }

    // MARK: - Catalog

    @ViewBuilder
    private func catalog(for email: String) -> some View {
        if let account = accounts.first(where: { $0.email == email }), let session = savedSession(for: account) {
            CatalogView(
                account: account,
                session: session,
                accounts: accounts,
                signedOutAccountEmails: Set(accounts.filter { savedSession(for: $0) == nil }.map(\.email)),
                pendingGameShortcut: .constant(nil),
                onSwitch: switchDetachedAccount,
                onAddAccount: { requestMainAccountAction(.addAccount) },
                onPresentAccountChooser: viewModel.backToSetup,
                onSignOut: { requestAccountMutation($0, request: OPNMainAccountActions.Request.signOut) },
                onForget: { requestAccountMutation($0, request: OPNMainAccountActions.Request.forget) },
                onRefreshAuth: { await DetachedSessionRefresher(modelContext: modelContext).refresh(account: account, session: session) },
                onWindowTitleChange: { windowTitle = $0 ?? account.displayName },
                isDetached: true
            )
            .id(session.id)
            .onAppear { windowTitle = account.displayName }
        } else {
            VStack(spacing: OPNDesign.Spacing.medium(scale: uiScale)) {
                note("This account has no saved session. Sign in again from the main window.")
                Button("SIGN IN AGAIN") {
                    guard let account = accounts.first(where: { $0.email == email }) else {
                        viewModel.backToSetup()
                        return
                    }
                    requestMainAccountAction(.reauthenticate(.init(account: account)))
                }
                .buttonStyle(VendorGetInButtonStyle(uiScale: uiScale))
                Button("BACK", action: viewModel.backToSetup)
                    .buttonStyle(OPNModalSecondaryButtonStyle(uiScale: uiScale))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func switchDetachedAccount(_ account: LoginAccount) {
        viewModel.backToSetup()
        windowTitle = "Detached Session"
        guard let storedAccounts = try? modelContext.fetch(FetchDescriptor<LoginAccount>()),
              let currentAccount = storedAccounts.first(where: { $0 === account }),
              let row = rows.first(where: { $0.email == currentAccount.email }) else { return }
        guard savedSession(for: currentAccount) != nil else {
            requestMainAccountAction(.reauthenticate(.init(account: currentAccount)))
            return
        }
        guard row.availability.isSelectable, let accountID = currentAccount.storedAccountID else { return }
        viewModel.confirm(row: row, accountID: accountID)
    }
}

struct DetachedSessionModalHost: ViewModifier {
    @ObservedObject var confirmation: OPNConfirmationPresentation
    @ObservedObject var reportIssue: OPNReportIssuePresentation

    func body(content: Content) -> some View {
        ZStack {
            content
            OPNReportIssueOverlay(presentation: reportIssue)
                .zIndex(92)
            OPNConfirmationOverlay(presentation: confirmation)
                .zIndex(95)
        }
        .environment(\.opnConfirmationPresentation, confirmation)
        .environment(\.opnReportIssuePresentation, reportIssue)
        .focusedSceneValue(\.opnReportIssuePresentation, reportIssue)
    }
}

@MainActor
private final class DetachedSessionWindowReference {
    weak var window: NSWindow?
}

/// A detached window is an ordinary titled window with the catalog's transparent titlebar, raised
/// above the borderless stream windows that cover the screens it is opened from.
private struct DetachedSessionWindowConfigurator: NSViewRepresentable {
    let title: String
    let reference: DetachedSessionWindowReference

    func makeNSView(context: Context) -> ConfigurationView {
        let view = ConfigurationView(frame: .zero)
        view.reference = reference
        return view
    }

    func updateNSView(_ view: ConfigurationView, context: Context) {
        view.title = title
        view.apply()
    }

    static func dismantleNSView(_ view: ConfigurationView, coordinator: ()) {
        view.unbind()
    }

    final class ConfigurationView: NSView {
        var title = ""
        weak var reference: DetachedSessionWindowReference?
        private var levelObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reference?.window = window
            guard window != nil else {
                unbind()
                return
            }
            apply()
            // The level only matters when a stream window takes or gives up the covering level, and
            // the stream windows say so. Reading it then keeps this window reachable without a timer.
            if levelObserver == nil {
                // swiftlint:disable:next view_owns_long_lived_effect -- removed when the view leaves its window; an NSView has no SwiftUI lifetime to tie it to
                levelObserver = NotificationCenter.default.addObserver(
                    forName: OPNStreamBorderless.coveringStateDidChange, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.applyLevel() }
                }
            }
        }

        func unbind() {
            if let levelObserver { NotificationCenter.default.removeObserver(levelObserver) }
            levelObserver = nil
            reference?.window = nil
        }

        func apply() {
            guard let window else { return }
            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isOpaque = true
            window.backgroundColor = .black
            applyLevel()
            if window.title != title { window.title = title }
        }

        private func applyLevel() {
            guard let window else { return }
            let hasCoveringStream = OPNStreamWindowPresenter.shared.windows.values.contains { $0.layoutState.isBorderless }
            let level = hasCoveringStream ? OPNStreamBorderless.aboveCoveringLevel : NSWindow.Level.normal
            if window.level != level { window.level = level }
        }
    }
}

enum OPNDetachedSessionScene {
    static let id = "detached-session"
}
