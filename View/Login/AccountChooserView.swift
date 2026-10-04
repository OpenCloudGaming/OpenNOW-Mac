//  The saved-account chooser.
//
//  One panel for the two moments that ask the same question: a fresh launch, when the reader has
//  asked to be asked which account to browse with, and "Switch account…" from the profile menu. It
//  is raised at the window root, above both the catalog and the login wall, because the question is
//  about which of them should be on screen.
//
//  Choosing runs the same transactional switch every other entry point runs - the login wall's saved
//  rows, the profile dropdown, the controller catalog and the menu bar all end up in
//  `LoginViewModel.activateSavedAccount`. Cancelling picks nothing: the account that was already
//  selected stays selected, and a game that is running keeps running.
//

import SwiftUI

struct AccountChooserOverlay: View {
    let accounts: [LoginAccount]
    let activeEmail: String
    let signedOutAccountEmails: Set<String>
    let reason: AccountChooserReason
    let onChoose: (LoginAccount) -> Void
    let onAddAccount: () -> Void
    let onCancel: () -> Void

    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                OPNDesign.Surface.scrim
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onCancel)

                panel.frame(width: panelWidth(availableWidth: proxy.size.width))
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .opnMotion(OPNDesign.Motion.panel, value: reason)
    }

    /// Wide enough for a name and an address on one row, and never wider than the window allows.
    private func panelWidth(availableWidth: CGFloat) -> CGFloat {
        let pageInset = OPNDesign.Spacing.pageHorizontal(scale: uiScale) * 2
        return max(min(440 * uiScale, availableWidth - pageInset), 280 * uiScale)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(OPNDesign.accent)
                .frame(height: 2)
                .frame(maxWidth: .infinity)

            header

            Rectangle()
                .fill(OPNDesign.Stroke.subtle)
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(accounts) { account in
                    AccountChooserRow(
                        account: account,
                        isActive: account.email == activeEmail,
                        isSignedOut: signedOutAccountEmails.contains(account.email),
                        uiScale: uiScale
                    ) {
                        onChoose(account)
                    }
                }
                Rectangle()
                    .fill(OPNDesign.Stroke.subtle)
                    .frame(height: 1)
                AccountChooserRow(
                    title: "Add Account",
                    subtitle: "Sign in without signing out",
                    systemImage: "plus",
                    isActive: false,
                    isSignedOut: false,
                    uiScale: uiScale,
                    action: onAddAccount
                )
            }

            Rectangle()
                .fill(OPNDesign.Stroke.subtle)
                .frame(height: 1)

            footer
        }
        .background(OPNDesign.Surface.panel)
        .overlay { Rectangle().stroke(OPNDesign.Stroke.regular, lineWidth: 1) }
        .shadow(color: .black.opacity(0.58), radius: 28 * uiScale, y: 20 * uiScale)
        .onExitCommand(perform: onCancel)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: OPNDesign.Spacing.small(scale: uiScale)) {
            VStack(alignment: .leading, spacing: 6 * uiScale) {
                Text(reason == .startup ? "STARTUP ACCOUNT" : "SWITCH ACCOUNT")
                    .font(.uiSans(size: 10 * uiScale, weight: .bold))
                    .foregroundStyle(OPNDesign.accent)
                    .tracking(1.1)
                Text(reason == .startup ? "Which account should OpenNOW browse with?" : "Which account do you want to browse with?")
                    .font(.uiSans(size: 20 * uiScale, weight: .bold))
                    .foregroundStyle(OPNDesign.Text.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(reason == .startup
                    ? "Your saved accounts stay signed in either way. Switching changes what OpenNOW browses; a game that is already running keeps using the account that started it."
                    : "Switching changes what OpenNOW browses. A game that is already running keeps using the account that started it.")
                    .font(.uiSans(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.secondary)
                    .lineSpacing(2 * uiScale)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: OPNDesign.Spacing.xSmall(scale: uiScale))
            OPNModalCloseButton(uiScale: uiScale, action: onCancel)
        }
        .padding(.horizontal, OPNDesign.Spacing.card(scale: uiScale))
        .padding(.vertical, OPNDesign.Spacing.medium(scale: uiScale))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OPNDesign.Surface.appBar)
    }

    private var footer: some View {
        HStack(spacing: OPNDesign.Spacing.small(scale: uiScale)) {
            Spacer(minLength: 0)
            Button("CANCEL", action: onCancel)
                .buttonStyle(OPNModalSecondaryButtonStyle(uiScale: uiScale))
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, OPNDesign.Spacing.card(scale: uiScale))
        .padding(.vertical, OPNDesign.Spacing.small(scale: uiScale))
    }
}

/// One row of the chooser: the account's avatar and name, what state it is in, and which one is
/// currently browsing. A signed-out row is still listed - it is what the reader picked last time -
/// and choosing it starts the sign-in it needs rather than failing.
private struct AccountChooserRow: View {
    var title: String = ""
    var subtitle: String = ""
    var systemImage: String = ""
    let account: LoginAccount?
    let isActive: Bool
    let isSignedOut: Bool
    let uiScale: CGFloat
    let action: () -> Void

    @State private var isHovering = false

    init(account: LoginAccount, isActive: Bool, isSignedOut: Bool, uiScale: CGFloat, action: @escaping () -> Void) {
        self.account = account
        self.isActive = isActive
        self.isSignedOut = isSignedOut
        self.uiScale = uiScale
        self.action = action
    }

    init(title: String, subtitle: String, systemImage: String, isActive: Bool, isSignedOut: Bool, uiScale: CGFloat, action: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        account = nil
        self.isActive = isActive
        self.isSignedOut = isSignedOut
        self.uiScale = uiScale
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: OPNDesign.Spacing.small(scale: uiScale)) {
                leading
                VStack(alignment: .leading, spacing: 2 * uiScale) {
                    Text(rowTitle)
                        .font(.uiSans(size: 14 * uiScale, weight: .bold))
                        .foregroundStyle(OPNDesign.Text.primary)
                        .lineLimit(1)
                    if let rowSubtitle {
                        Text(rowSubtitle)
                            .font(.uiSans(size: 11 * uiScale, weight: .medium))
                            .foregroundStyle(isSignedOut ? OPNDesign.Semantic.warning : OPNDesign.Text.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if isActive {
                    Text("BROWSING")
                        .font(.uiSans(size: 10 * uiScale, weight: .bold))
                        .foregroundStyle(OPNDesign.onAccent)
                        .tracking(0.8)
                        .padding(.horizontal, OPNDesign.Spacing.xSmall(scale: uiScale))
                        .frame(height: OPNDesign.Spacing.card(scale: uiScale))
                        .background(OPNDesign.accent)
                }
            }
            .padding(.horizontal, OPNDesign.Spacing.card(scale: uiScale))
            .frame(height: 58 * uiScale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OPNDesign.Fill.neutral(isHovering ? 0.085 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .opnMotion(OPNDesign.Motion.hover, value: isHovering)
        .accessibilityLabel(rowTitle)
    }

    @ViewBuilder private var leading: some View {
        if let account {
            CatalogAccountAvatar(account: account, size: 36 * uiScale)
        } else {
            ZStack {
                Rectangle().fill(OPNDesign.Fill.neutral(0.08))
                Image(systemName: systemImage)
                    .font(.uiSans(size: 14 * uiScale, weight: .bold))
                    .foregroundStyle(OPNDesign.Text.secondary)
            }
            .frame(width: 36 * uiScale, height: 36 * uiScale)
        }
    }

    private var rowTitle: String {
        account?.displayName ?? title
    }

    private var rowSubtitle: String? {
        guard let account else { return subtitle.isEmpty ? nil : subtitle }
        if isSignedOut { return "Signed out. Sign in again." }
        if isActive { return account.email }
        return account.email
    }
}

/// The transient line a switch leaves behind when a game keeps running on another account.
struct AccountSwitchNoticeBanner: View {
    let message: String
    let dismiss: () -> Void

    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: OPNDesign.Spacing.small(scale: uiScale)) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.uiSans(size: 14 * uiScale, weight: .bold))
                    .foregroundStyle(OPNDesign.accent)
                Text(message)
                    .font(.uiSans(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: OPNDesign.Spacing.xSmall(scale: uiScale))
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.uiSans(size: 11 * uiScale, weight: .bold))
                        .foregroundStyle(OPNDesign.Text.secondary)
                        .frame(width: 24 * uiScale, height: 24 * uiScale)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, OPNDesign.Spacing.card(scale: uiScale))
            .padding(.vertical, OPNDesign.Spacing.small(scale: uiScale))
            .frame(maxWidth: 560 * uiScale, alignment: .leading)
            .background(OPNDesign.Surface.overlay.opacity(0.985))
            .overlay(alignment: .leading) { Rectangle().fill(OPNDesign.accent).frame(width: 3 * uiScale) }
            .overlay { Rectangle().stroke(OPNDesign.Stroke.regular, lineWidth: 1) }
            .shadow(color: .black.opacity(0.5), radius: 24 * uiScale, y: 14 * uiScale)
            .padding(.bottom, OPNDesign.Spacing.large(scale: uiScale))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(true)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}
