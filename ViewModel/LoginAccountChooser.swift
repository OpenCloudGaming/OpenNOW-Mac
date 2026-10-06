//  The saved-account chooser's operations, split out of `LoginViewModel` because the class body is
//  at its length limit. The state they drive stays on the class, beside the sign-in state.

import Foundation

extension LoginViewModel {
    /// A fresh launch asks which account to browse with, when the reader asked to be asked and there
    /// is more than one saved account to choose between. Nothing is signed out or re-selected to ask.
    func presentStartupAccountChooser() {
        guard accountChooserReason == nil else { return }
        guard OPNAccountPreferences.shouldAskOnStartup(savedAccountCount: accounts.count) else { return }
        accountChooserReason = .startup
        OPNLog.info(.auth, "Startup account chooser presented accounts=\(accounts.count)")
    }

    /// "Switch account…": the same question, asked on purpose. With nothing saved there is nothing to
    /// switch between, so it goes straight to adding one.
    func presentAccountChooser() {
        guard !accounts.isEmpty else {
            beginAddAccount()
            return
        }
        accountChooserReason = .switchAccount
        OPNLog.info(.auth, "Account chooser opened from the profile menu accounts=\(accounts.count)")
    }

    /// Cancelling never picks for the reader: whatever was selected stays selected.
    func dismissAccountChooser() {
        guard let reason = accountChooserReason else { return }
        accountChooserReason = nil
        OPNLog.info(.auth, "Account chooser dismissed reason=\(reason)")
    }

    func dismissAccountSwitchNotice() {
        accountSwitchNoticeTask?.cancel()
        accountSwitchNoticeTask = nil
        accountSwitchNotice = nil
    }

    /// A switch never touches the games already running, so say whose they still are: without this
    /// the reader cannot tell that they survived the switch.
    func announceRunningGameContinues(with account: LoginAccount) {
        let selectedID = account.resolveStableAccountID()
        let owners = sessionRegistry.sessions
            .filter { $0.accountID != selectedID }
            .map(\.account.displayName)
        guard !owners.isEmpty else {
            dismissAccountSwitchNotice()
            return
        }
        let games = owners.count == 1
            ? "Your current game continues using \(owners[0])."
            : "Your current games continue using \(owners.formatted(.list(type: .and)))."
        accountSwitchNotice = "Browsing now uses \(account.displayName). \(games)"
        accountSwitchNoticeTask?.cancel()
        accountSwitchNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            self?.accountSwitchNotice = nil
            self?.accountSwitchNoticeTask = nil
        }
    }
}
