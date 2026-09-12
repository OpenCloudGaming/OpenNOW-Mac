//  The account dropdown hung off the catalog top bar: the saved-account list, the per-account
//  Sign Out and Forget actions, and the in-place Forget confirmation.
//

import SwiftUI

struct CatalogAccountDropdownOverlay: View {
    let viewModel: CatalogViewModel
    let accounts: [LoginAccount]
    let signedOutAccountEmails: Set<String>
    @Binding var isPresented: Bool
    let topInset: CGFloat
    let onSwitch: (LoginAccount) -> Void
    let onAddAccount: () -> Void
    let onSignOut: (LoginAccount) -> Void
    let onForget: (LoginAccount) -> Void
    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                if isPresented {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { isPresented = false }

                    // Grows out of the avatar it hangs from instead of fading in place. Anchored
                    // top-trailing so the corner under the button stays put while it opens.
                    CatalogAccountDropdownPanel(viewModel: viewModel, accounts: accounts, signedOutAccountEmails: signedOutAccountEmails, isPresented: $isPresented, onSwitch: onSwitch, onAddAccount: onAddAccount, onSignOut: onSignOut, onForget: onForget)
                        .opnTransition(.scale(scale: 0.94, anchor: .topTrailing).combined(with: .opacity))
                        .padding(.top, CatalogVendorLayout.appBarHeight(scale: uiScale) + topInset)
                        .padding(.trailing, 22)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .opnMotion(OpenNOWDesign.Motion.panel, value: isPresented)
        .allowsHitTesting(isPresented)
        .onExitCommand(perform: isPresented ? { isPresented = false } : nil)
    }
}

struct CatalogAccountDropdownPanel: View {
    let viewModel: CatalogViewModel
    let accounts: [LoginAccount]
    let signedOutAccountEmails: Set<String>
    @Binding var isPresented: Bool
    let onSwitch: (LoginAccount) -> Void
    let onAddAccount: () -> Void
    let onSignOut: (LoginAccount) -> Void
    let onForget: (LoginAccount) -> Void
    @Environment(\.opnUIScale) private var uiScale
    @State private var pendingForget: LoginAccount?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: OpenNOWDesign.Spacing.small(scale: uiScale)) {
                CatalogAccountAvatar(account: viewModel.account, size: 44 * uiScale)
                VStack(alignment: .leading, spacing: 3 * uiScale) {
                    Text(viewModel.account.displayName)
                        .catalogFont(size: 15, weight: .medium)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(viewModel.subscriptionStatus.membershipTier.uppercased())
                        .catalogFont(size: 10, weight: .bold)
                        .tracking(0.6)
                        .foregroundStyle(.black.opacity(0.86))
                        .padding(.horizontal, OpenNOWDesign.Spacing.xSmall(scale: uiScale))
                        .frame(height: OpenNOWDesign.Spacing.card(scale: uiScale))
                        .background(OpenNOWDesign.accent)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, OpenNOWDesign.Spacing.contentVertical(scale: uiScale))
            .padding(.vertical, OpenNOWDesign.Spacing.contentVertical(scale: uiScale))

            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(height: 1)

            if let pendingForget {
                CatalogAccountForgetConfirmationView(
                    account: pendingForget,
                    isActiveAccount: pendingForget === viewModel.account,
                    onCancel: { self.pendingForget = nil },
                    onConfirm: {
                        isPresented = false
                        onForget(pendingForget)
                    }
                )
                // Registered only while the confirm body is up, so it wins over the overlay's own
                // Escape handler (Escape cancels the confirm instead of closing the whole dropdown).
                .onExitCommand(perform: { self.pendingForget = nil })
            } else {
                VStack(alignment: .leading, spacing: OpenNOWDesign.Spacing.xxSmall(scale: uiScale)) {
                    Text("ACCOUNTS")
                        .catalogFont(size: 10, weight: .bold)
                        .tracking(1.1)
                        .foregroundStyle(.white.opacity(0.42))
                        .padding(.horizontal, OpenNOWDesign.Spacing.small(scale: uiScale))
                        .padding(.vertical, 5 * uiScale)
                    ForEach(accounts) { account in
                        let isActive = account === viewModel.account
                        // A signed-out account still has a row here, but nothing to restore: say so
                        // rather than let the switch fail with a message no one sees.
                        let needsSignIn = !isActive && signedOutAccountEmails.contains(account.email)
                        var trailingActions: [CatalogAccountDropdownRowAction] {
                            var actions: [CatalogAccountDropdownRowAction] = []
                            if !signedOutAccountEmails.contains(account.email) {
                                actions.append(CatalogAccountDropdownRowAction(systemImage: "power", accessibilityLabel: "Sign out of \(account.displayName)", isDestructive: false) {
                                    isPresented = false
                                    onSignOut(account)
                                })
                            }
                            actions.append(CatalogAccountDropdownRowAction(systemImage: "xmark.circle", accessibilityLabel: "Forget \(account.displayName)", isDestructive: true) {
                                pendingForget = account
                            })
                            return actions
                        }
                        CatalogAccountDropdownRow(
                            title: account.displayName,
                            subtitle: isActive ? "Signed in" : (needsSignIn ? "Signed out — sign in again" : nil),
                            systemImage: isActive ? "checkmark" : (needsSignIn ? "person.crop.circle.badge.exclamationmark" : "person"),
                            isActive: isActive,
                            role: nil,
                            trailingActions: trailingActions
                        ) {
                            isPresented = false
                            if !isActive {
                                onSwitch(account)
                            }
                        }
                    }
                    // Signing in an extra account never signs the current one out, so this belongs in
                    // the account list rather than behind Sign Out.
                    CatalogAccountDropdownRow(
                        title: "Add Account",
                        subtitle: "Sign in without signing out",
                        systemImage: "plus",
                        isActive: false,
                        role: nil
                    ) {
                        isPresented = false
                        onAddAccount()
                    }
                }
                .padding(.horizontal, OpenNOWDesign.Spacing.section(scale: uiScale))
                .padding(.top, OpenNOWDesign.Spacing.section(scale: uiScale))
                .padding(.bottom, OpenNOWDesign.Spacing.small(scale: uiScale))
            }
        }
        .frame(width: CatalogVendorLayout.accountMenuWidth(scale: uiScale), alignment: .topLeading)
        .background(OpenNOWDesign.Surface.overlay.opacity(0.985))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(OpenNOWDesign.accent)
                .frame(height: 2)
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(width: 1)
        }
        .shadow(color: .black.opacity(0.58), radius: 28, x: 14, y: 20)
    }
}

/// One trailing icon button on a `CatalogAccountDropdownRow`, e.g. Sign Out or Forget. Each is its
/// own tap target so pressing it never also fires the row's own action.
struct CatalogAccountDropdownRowAction: Identifiable {
    let id = UUID()
    let systemImage: String
    let accessibilityLabel: String
    let isDestructive: Bool
    let action: () -> Void
}

struct CatalogAccountDropdownRow: View {
    let title: String
    let subtitle: String?
    let systemImage: String?
    let isActive: Bool
    let role: ButtonRole?
    var trailingActions: [CatalogAccountDropdownRowAction] = []
    let action: () -> Void
    @Environment(\.opnUIScale) private var uiScale
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: OpenNOWDesign.Spacing.small(scale: uiScale)) {
                    if let systemImage {
                        ZStack {
                            Rectangle()
                                .fill(isActive ? OpenNOWDesign.accent : Color.white.opacity(isHovering ? 0.16 : 0.08))
                            Image(systemName: systemImage)
                                .catalogFont(size: 13, weight: .bold)
                                .foregroundStyle(iconColor)
                        }
                        .frame(width: 30 * uiScale, height: 30 * uiScale)
                    }
                    VStack(alignment: .leading, spacing: 2 * uiScale) {
                        Text(title)
                            .catalogFont(size: 14, weight: .bold)
                            .foregroundStyle(titleColor)
                            .lineLimit(1)
                        if let subtitle {
                            Text(subtitle)
                                .catalogFont(size: 11, weight: .medium)
                                .foregroundStyle(.white.opacity(0.52))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, OpenNOWDesign.Spacing.xSmall(scale: uiScale))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.opnPressable)
            .accessibilityLabel(title)
            // The icon buttons below only exist while the pointer is over the row, so VoiceOver
            // would never reach them. They are published here instead, and hidden there.
            .accessibilityActions {
                ForEach(trailingActions) { rowAction in
                    Button(rowAction.accessibilityLabel, action: rowAction.action)
                }
            }

            if isHovering, !trailingActions.isEmpty {
                HStack(spacing: OpenNOWDesign.Spacing.xxSmall(scale: uiScale)) {
                    ForEach(trailingActions) { rowAction in
                        CatalogAccountDropdownRowActionButton(rowAction: rowAction)
                    }
                }
                .padding(.trailing, OpenNOWDesign.Spacing.xSmall(scale: uiScale))
                .accessibilityHidden(true)
            } else {
                Color.clear.frame(width: OpenNOWDesign.Spacing.controlRow(scale: uiScale) - OpenNOWDesign.Spacing.xSmall(scale: uiScale))
            }
        }
        .frame(height: 42 * uiScale)
        .background(rowBackground)
        .onHover { isHovering = $0 }
        .opnMotion(OpenNOWDesign.Motion.hover, value: isHovering)
    }

    private var rowBackground: Color {
        if isActive { return OpenNOWDesign.accent.opacity(0.095) }
        return Color.white.opacity(isHovering ? 0.085 : 0)
    }

    private var titleColor: Color {
        if role == .destructive { return OpenNOWDesign.Semantic.destructive }
        return isActive ? .white : .white.opacity(isHovering ? 0.96 : 0.82)
    }

    private var iconColor: Color {
        if role == .destructive { return OpenNOWDesign.Semantic.destructive }
        return isActive ? .black : .white.opacity(isHovering ? 0.96 : 0.82)
    }
}

/// A single trailing icon button revealed on row hover (see `CatalogAccountDropdownRow`). Kept as
/// its own view so its hover/press feedback is independent of the row's.
private struct CatalogAccountDropdownRowActionButton: View {
    let rowAction: CatalogAccountDropdownRowAction
    @Environment(\.opnUIScale) private var uiScale
    @State private var isHovering = false

    var body: some View {
        Button(action: rowAction.action) {
            Image(systemName: rowAction.systemImage)
                .catalogFont(size: 12, weight: .bold)
                .foregroundStyle(tintColor)
                .frame(width: 26 * uiScale, height: 26 * uiScale)
                .background(Color.white.opacity(isHovering ? 0.16 : 0.08))
                .contentShape(Rectangle())
        }
        .buttonStyle(.opnPressable)
        .onHover { isHovering = $0 }
        .opnMotion(OpenNOWDesign.Motion.hover, value: isHovering)
        .accessibilityLabel(rowAction.accessibilityLabel)
    }

    private var tintColor: Color {
        if rowAction.isDestructive { return OpenNOWDesign.Semantic.destructive }
        return .white.opacity(isHovering ? 0.96 : 0.72)
    }
}

/// Replaces the dropdown panel's account list in place once Forget is pressed on a row — no sheet,
/// no second popover, per the agreed design.
private struct CatalogAccountForgetConfirmationView: View {
    let account: LoginAccount
    let isActiveAccount: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        VStack(alignment: .leading, spacing: OpenNOWDesign.Spacing.card(scale: uiScale)) {
            VStack(alignment: .leading, spacing: 6 * uiScale) {
                Text("Forget \(account.displayName)?")
                    .catalogFont(size: 15, weight: .bold)
                    .foregroundStyle(.white)
                Text(bodyText)
                    .catalogFont(size: 12, weight: .medium)
                    .foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: OpenNOWDesign.Spacing.small(scale: uiScale)) {
                CatalogAccountConfirmButton(title: "Cancel", isDestructive: false, action: onCancel)
                CatalogAccountConfirmButton(title: "Forget Account", isDestructive: true, action: onConfirm)
            }
        }
        .padding(OpenNOWDesign.Spacing.section(scale: uiScale))
    }

    private var bodyText: String {
        let base = "Removes the saved sign-in from this Mac."
        guard isActiveAccount else { return base }
        return base + " You'll be signed out, and you'll need your password next time."
    }
}

private struct CatalogAccountConfirmButton: View {
    let title: String
    let isDestructive: Bool
    let action: () -> Void
    @Environment(\.opnUIScale) private var uiScale
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .catalogFont(size: 12, weight: .bold)
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity)
                .frame(height: 34 * uiScale)
                .background(background)
        }
        .buttonStyle(.opnPressable)
        .onHover { isHovering = $0 }
        .opnMotion(OpenNOWDesign.Motion.hover, value: isHovering)
        .accessibilityLabel(title)
    }

    private var foreground: Color {
        isDestructive ? .white : .white.opacity(isHovering ? 0.96 : 0.82)
    }

    private var background: Color {
        if isDestructive { return OpenNOWDesign.Semantic.destructive.opacity(isHovering ? 0.90 : 0.78) }
        return Color.white.opacity(isHovering ? 0.16 : 0.08)
    }
}
