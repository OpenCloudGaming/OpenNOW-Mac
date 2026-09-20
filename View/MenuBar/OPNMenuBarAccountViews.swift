import SwiftUI

/// The account card at the top of the status item's popover: who is signed in, and — when more than
/// one account is saved — a dropdown that switches between them.
///
/// The switch belongs to the window, because it re-points the auth session the whole app shares. A
/// switch is handed to a window that is already on screen and otherwise parked by
/// `OPNMenuBarSessionModel`, so choosing an account never pulls OpenNOW forward or opens it. Add
/// Account still presents the window, because the sign-in that follows happens there.
struct OPNMenuBarAccountSection: View {
    @ObservedObject var session: OPNMenuBarSessionModel
    let onPresentMainWindow: () -> Void
    /// Whether the account list starts open. The popover leaves it closed; a snapshot render opens it
    /// to show the dropdown without a click.
    let startsExpanded: Bool

    @State private var isExpanded: Bool

    init(session: OPNMenuBarSessionModel, startsExpanded: Bool = false, onPresentMainWindow: @escaping () -> Void) {
        self.session = session
        self.startsExpanded = startsExpanded
        self.onPresentMainWindow = onPresentMainWindow
        _isExpanded = State(initialValue: startsExpanded)
    }

    var body: some View {
        if let active = session.activeAccount {
            VStack(alignment: .leading, spacing: 8) {
                header(active)
                if isExpanded {
                    accountList
                }
            }
            .opnMenuBarCard()
        }
    }

    private func header(_ active: OPNMenuBarAccount) -> some View {
        Group {
            if session.accounts.count > 1 {
                Button { toggle() } label: {
                    headerContent(active, showsChevron: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Signed in as \(active.displayName)")
                .accessibilityHint("Shows the other accounts")
            } else {
                headerContent(active, showsChevron: false)
            }
        }
    }

    private func headerContent(_ active: OPNMenuBarAccount, showsChevron: Bool) -> some View {
        HStack(spacing: 9) {
            CatalogAccountAvatar(email: active.email, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(active.displayName)
                    .font(.opnUI(size: 13, weight: .bold))
                    .foregroundStyle(OPNDesign.Text.primary)
                    .lineLimit(1)
                Text(subtitle(for: active))
                    .font(.opnUI(size: 10.5, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.opnUI(size: 10, weight: .bold))
                    .foregroundStyle(OPNDesign.Text.secondary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .opnMotion(OPNDesign.Motion.toggle, value: isExpanded)
            }
        }
        .contentShape(Rectangle())
    }

    private var accountList: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(session.accounts) { account in
                accountRow(account)
            }
            addAccountRow
        }
    }

    private func accountRow(_ account: OPNMenuBarAccount) -> some View {
        Button { switchTo(account) } label: {
            HStack(spacing: 8) {
                Image(systemName: account.isActive ? "checkmark" : (account.isSignedOut ? "person.crop.circle.badge.exclamationmark" : "person"))
                    .font(.opnUI(size: 11, weight: .bold))
                    .foregroundStyle(account.isActive ? OPNDesign.accent : OPNDesign.Text.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.displayName)
                        .font(.opnUI(size: 12, weight: .semibold))
                        .foregroundStyle(account.isSignedOut ? OPNDesign.Text.secondary : OPNDesign.Text.primary)
                        .lineLimit(1)
                    if account.isSignedOut {
                        Text("Signed out — sign in again")
                            .font(.opnUI(size: 10, weight: .medium))
                            .foregroundStyle(OPNDesign.Text.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(account.isActive)
        .opnMenuBarRow()
        .accessibilityLabel(account.isActive ? "\(account.displayName), signed in" : "Switch to \(account.displayName)")
    }

    private var addAccountRow: some View {
        Button { addAccount() } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.opnUI(size: 11, weight: .bold))
                    .foregroundStyle(OPNDesign.Text.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Add Account")
                        .font(.opnUI(size: 12, weight: .semibold))
                        .foregroundStyle(OPNDesign.Text.primary)
                        .lineLimit(1)
                    Text("Sign in without signing out")
                        .font(.opnUI(size: 10, weight: .medium))
                        .foregroundStyle(OPNDesign.Text.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opnMenuBarRow()
        .accessibilityLabel("Add account")
    }

    private func subtitle(for account: OPNMenuBarAccount) -> String {
        if account.isSignedOut { return "Signed out — sign in again" }
        return account.membershipTier.isEmpty ? account.email : account.membershipTier
    }

    private func toggle() {
        guard session.accounts.count > 1 else { return }
        withAnimation(OPNDesign.Motion.toggle) { isExpanded.toggle() }
    }

    /// Switches without disturbing the app: a window already on screen performs the switch where it
    /// is, and with no window the request is parked for the next one rather than bringing OpenNOW
    /// forward or opening it from the menu bar.
    private func switchTo(_ account: OPNMenuBarAccount) {
        guard !account.isActive else { return }
        isExpanded = false
        session.requestAccountSwitch(account)
    }

    private func addAccount() {
        isExpanded = false
        onPresentMainWindow()
        session.requestAddAccount()
    }
}
