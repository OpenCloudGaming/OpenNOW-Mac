//  The saved-account chooser: when a fresh launch asks which account to browse with, and what the
//  profile menu's "Switch account…" does. Split out of `LoginViewModel` because the class body is
//  already at its length limit; the state it drives stays on the class, next to the sign-in state it
//  is a sibling of.
//

import Foundation

extension LoginViewModel {
    /// A fresh launch asks which account to browse with, when the reader asked to be asked and there
    /// is more than one saved account to choose between.
    ///
    /// Nothing is signed out, refreshed or re-selected to ask: the account that was already active
    /// stays active behind the panel, so cancelling leaves the reader exactly where they would have
    /// been without the preference on.
    func presentAccountChooserForStartupIfNeeded() {
        guard accountChooserReason == nil else { return }
        guard OPNAccountPreferences.asksOnStartup(savedAccountCount: accounts.count) else { return }
        accountChooserReason = .startup
        OPNLog.info(.auth, "Startup account chooser presented accounts=\(accounts.count)")
    }

    /// "Switch account…": the same question, asked on purpose. With nothing saved there is nothing
    /// to switch between, so it goes straight to adding one.
    func presentAccountChooser() {
        guard !accounts.isEmpty else {
            beginAddAccount()
            return
        }
        accountChooserReason = .switchAccount
        OPNLog.info(.auth, "Account chooser opened from the profile menu accounts=\(accounts.count)")
    }

    /// Cancelling never picks for the reader: whatever was selected stays selected, and a running
    /// game is untouched.
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

    /// A switch never touches the game already running, so say whose it still is. Without this the
    /// reader has no way to tell that the game survived the switch.
    func announceRunningGameContinues(with account: LoginAccount) {
        guard let owned = sessionRegistry.current,
              owned.accountID != account.resolveStableAccountID() else {
            dismissAccountSwitchNotice()
            return
        }
        accountSwitchNotice = "Browsing now uses \(account.displayName). Your current game continues using \(owned.account.displayName)."
        accountSwitchNoticeTask?.cancel()
        accountSwitchNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            self?.accountSwitchNotice = nil
            self?.accountSwitchNoticeTask = nil
        }
    }
}
