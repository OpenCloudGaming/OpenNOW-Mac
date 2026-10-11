//  The Detach New Session window: one more account streaming beside the ones already running.
//
//  Pick an account, choose the controllers this stream leaves out, then browse and launch from the
//  account's own catalog. It never touches the main window's active account: the catalog is built
//  for the chosen account explicitly and launches through the shared game session registry.

import AppKit
import SwiftData
import SwiftUI

struct DetachedSessionView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LoginAccount.lastLoginAt, order: .reverse) private var accounts: [LoginAccount]
    @Query(sort: \LoginSession.issuedAt, order: .reverse) private var sessions: [LoginSession]
    @AppStorage(OPNInterfacePreferences.uiScaleKey) private var uiScale = OPNInterfacePreferences.defaultUIScale
    @AppStorage(OPNThemePreferences.accentColorKey) private var accentColorRawValue = OPNThemePreferences.AccentColor.cloudGreen.rawValue
    @AppStorage(OPNThemePreferences.appearanceKey) private var appearanceRawValue = OPNThemePreferences.Appearance.dark.rawValue
    @EnvironmentObject private var systemAppearance: OPNSystemAppearance
    @ObservedObject private var devices = ControllerMappingDevices.shared
    @State private var viewModel = DetachedSessionViewModel()
    @State private var windowTitle = "Detached Session"

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
        .frame(minWidth: 640, minHeight: 480)
        .ignoresSafeArea()
        .background(OPNDesign.Surface.app)
        .background(DetachedSessionWindowConfigurator(title: windowTitle))
        .environment(\.opnUIScale, uiScale)
        .opnObservingCornerStyle()
        .opnObservingLiquidGlass()
        .preferredColorScheme(preferredColorScheme)
        .onAppear { devices.refresh() }
        .onDisappear { viewModel.discardPendingSelection(for: selectedAccount?.storedAccountID) }
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
                OPNMainWindow.reveal()
                OPNMenuBarSessionModel.shared.requestAddAccount()
                OPNMainWindow.bringForward()
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
                accounts: [account],
                signedOutAccountEmails: [],
                pendingGameShortcut: .constant(nil),
                onSwitch: { _ in },
                onAddAccount: {
                    OPNMainWindow.reveal()
                    OPNMenuBarSessionModel.shared.requestAddAccount()
                    OPNMainWindow.bringForward()
                },
                onPresentAccountChooser: {},
                onSignOut: { _ in },
                onForget: { _ in },
                onRefreshAuth: { await DetachedSessionRefresher(modelContext: modelContext).refresh(account: account, session: session) },
                onWindowTitleChange: { windowTitle = $0 ?? account.displayName },
                isDetached: true
            )
            .id(session.id)
            .onAppear { windowTitle = account.displayName }
        } else {
            VStack(spacing: OPNDesign.Spacing.medium(scale: uiScale)) {
                note("This account has no saved session. Sign in again from the main window.")
                Button("BACK") { viewModel.backToSetup(accountID: selectedAccount?.storedAccountID) }
                    .buttonStyle(OPNModalSecondaryButtonStyle(uiScale: uiScale))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A detached window is an ordinary titled window with the catalog's transparent titlebar, raised
/// above the borderless stream windows that cover the screens it is opened from.
private struct DetachedSessionWindowConfigurator: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> ConfigurationView {
        ConfigurationView(frame: .zero)
    }

    func updateNSView(_ view: ConfigurationView, context: Context) {
        view.title = title
        view.apply()
    }

    final class ConfigurationView: NSView {
        var title = ""

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
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
            window.level = OPNStreamBorderless.aboveCoveringLevel
            if window.title != title { window.title = title }
        }
    }
}

enum OPNDetachedSessionScene {
    static let id = "detached-session"
}
