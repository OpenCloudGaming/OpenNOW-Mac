//  The saved-account chooser, raised at the window root for the two moments that ask the same
//  question: a fresh launch, and the profile menu's "Switch account…".

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
                    accountRow(account)
                }
                Rectangle()
                    .fill(OPNDesign.Stroke.subtle)
                    .frame(height: 1)
                AccountChooserRow(
                    title: "Add Account",
                    subtitle: "Sign in without signing out",
                    emphasis: .normal,
                    avatarEmail: nil,
                    systemImage: "plus",
                    isBrowsing: false,
                    uiScale: uiScale,
                    action: onAddAccount
                )
            }

            Rectangle()
                .fill(OPNDesign.Stroke.subtle)
                .frame(height: 1)

            footer
        }
        // Clipped so the full-width accent bar follows the panel's own corners instead of poking
        // past them; the border and shadow are drawn outside the clip.
        .opnCornerClip(role: .panel, scale: uiScale)
        .background(OPNCornerShape(role: .panel, scale: uiScale).fill(OPNDesign.Surface.panel))
        .overlay { OPNCornerShape(role: .panel, scale: uiScale).strokeBorder(OPNDesign.Stroke.regular, lineWidth: 1) }
        .shadow(color: .black.opacity(0.58), radius: 28 * uiScale, y: 20 * uiScale)
        .onExitCommand(perform: onCancel)
    }

    private func accountRow(_ account: LoginAccount) -> some View {
        let isSignedOut = signedOutAccountEmails.contains(account.email)
        return AccountChooserRow(
            title: account.displayName,
            subtitle: isSignedOut ? "Signed out. Sign in again." : account.email,
            emphasis: isSignedOut ? .warning : .normal,
            avatarEmail: account.email,
            systemImage: "",
            isBrowsing: account.email == activeEmail,
            uiScale: uiScale,
            action: { onChoose(account) }
        )
    }

    private var header: some View {
        HStack(alignment: .top, spacing: OPNDesign.Spacing.small(scale: uiScale)) {
            VStack(alignment: .leading, spacing: 6 * uiScale) {
                Text(eyebrow)
                    .font(.uiSans(size: 10 * uiScale, weight: .bold))
                    .foregroundStyle(OPNDesign.accent)
                    .tracking(1.1)
                Text(headline)
                    .font(.uiSans(size: 20 * uiScale, weight: .bold))
                    .foregroundStyle(OPNDesign.Text.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(explanation)
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

    private var eyebrow: String {
        switch reason {
        case .startup: return "STARTUP ACCOUNT"
        case .switchAccount: return "SWITCH ACCOUNT"
        }
    }

    private var headline: String {
        switch reason {
        case .startup: return "Which account should OpenNOW browse with?"
        case .switchAccount: return "Which account do you want to browse with?"
        }
    }

    /// Both moments promise the same thing, so neither may read as a sign-out.
    private var explanation: String {
        switch reason {
        case .startup:
            return "Your saved accounts stay signed in either way. Switching changes what OpenNOW browses; a game that is already running keeps using the account that started it."
        case .switchAccount:
            return "Switching changes what OpenNOW browses. A game that is already running keeps using the account that started it."
        }
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

/// One row of the chooser: a saved account with its avatar, or the Add Account action.
private struct AccountChooserRow: View {
    enum Emphasis {
        case normal
        case warning
    }

    let title: String
    let subtitle: String?
    let emphasis: Emphasis
    let avatarEmail: String?
    let systemImage: String
    let isBrowsing: Bool
    let uiScale: CGFloat
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: OPNDesign.Spacing.small(scale: uiScale)) {
                leading
                VStack(alignment: .leading, spacing: 2 * uiScale) {
                    Text(title)
                        .font(.uiSans(size: 14 * uiScale, weight: .bold))
                        .foregroundStyle(OPNDesign.Text.primary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.uiSans(size: 11 * uiScale, weight: .medium))
                            .foregroundStyle(subtitleColor)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if isBrowsing {
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
            .background(OPNCornerShape(role: .card, scale: uiScale).fill(OPNDesign.Fill.neutral(isHovering ? 0.085 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .opnMotion(OPNDesign.Motion.hover, value: isHovering)
        .accessibilityLabel(title)
    }

    @ViewBuilder private var leading: some View {
        if let avatarEmail {
            CatalogAccountAvatar(email: avatarEmail, size: 36 * uiScale)
        } else {
            ZStack {
                OPNCornerShape(role: .tile, scale: uiScale).fill(OPNDesign.Fill.neutral(0.08))
                Image(systemName: systemImage)
                    .font(.uiSans(size: 14 * uiScale, weight: .bold))
                    .foregroundStyle(OPNDesign.Text.secondary)
            }
            .frame(width: 36 * uiScale, height: 36 * uiScale)
        }
    }

    private var subtitleColor: Color {
        emphasis == .warning ? OPNDesign.Semantic.warning : OPNDesign.Text.tertiary
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
            .background(OPNCornerShape(role: .card, scale: uiScale).fill(OPNDesign.Surface.overlay.opacity(0.985)))
            .overlay(alignment: .leading) { Rectangle().fill(OPNDesign.accent).frame(width: 3 * uiScale) }
            // The leading accent rule is contained by the banner's own shape so it cannot poke past
            // the rounded corners; the border and shadow sit outside the clip.
            .opnCornerClip(role: .card, scale: uiScale)
            .overlay { OPNCornerShape(role: .card, scale: uiScale).strokeBorder(OPNDesign.Stroke.regular, lineWidth: 1) }
            .shadow(color: .black.opacity(0.5), radius: 24 * uiScale, y: 14 * uiScale)
            .padding(.bottom, OPNDesign.Spacing.large(scale: uiScale))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}
