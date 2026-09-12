//  The per-account options overlay reached from an account row in the controller actions menu:
//  its Sign Out and Forget rows, and the Forget confirmation that replaces them.
//

import Foundation

@MainActor
extension ControllerCatalogViewModel {

    // MARK: - Account options overlay

    func openAccountOptions(for account: LoginAccount) {
        accountOptionsTarget = account
        accountOptionsStage = .options
        accountOptionsRowIndex = 0
        accountOptionsConfirmIndex = 0
    }

    func closeAccountOptions() {
        accountOptionsTarget = nil
        accountOptionsStage = .options
    }

    func handleAccountOptionsInput(_ command: ControllerInputCommand) {
        guard let account = accountOptionsTarget else { return }
        switch accountOptionsStage {
        case .options: handleAccountOptionsListInput(command, account: account)
        case .confirmForget: handleAccountOptionsConfirmInput(command, account: account)
        }
    }

    private func handleAccountOptionsListInput(_ command: ControllerInputCommand, account: LoginAccount) {
        let rows = accountOptionRows(for: account)
        switch command {
        case .move(.up): accountOptionsRowIndex = max(accountOptionsRowIndex - 1, 0)
        case .move(.down): accountOptionsRowIndex = min(accountOptionsRowIndex + 1, max(rows.count - 1, 0))
        case .confirm:
            guard rows.indices.contains(accountOptionsRowIndex) else { return }
            selectAccountOptionRow(rows[accountOptionsRowIndex], account: account)
        case .back, .menu, .actions: closeAccountOptions()
        default: break
        }
    }

    /// Cancel is index 0, kept the resting focus - forgetting an account is destructive and should
    /// never be one accidental confirm press away from opening the overlay.
    private func handleAccountOptionsConfirmInput(_ command: ControllerInputCommand, account: LoginAccount) {
        switch command {
        case .move(.left): accountOptionsConfirmIndex = 0
        case .move(.right): accountOptionsConfirmIndex = 1
        case .confirm: selectAccountOptionsConfirm(accountOptionsConfirmIndex, account: account)
        case .back: accountOptionsStage = .options
        default: break
        }
    }

    /// Shared with the overlay's own row/button taps, so a pad confirm and a mouse click land on
    /// exactly the same behavior.
    func selectAccountOptionRow(_ row: ControllerAccountOptionRow, account: LoginAccount) {
        switch row {
        case .signOut:
            closeAccountOptions()
            closeActionMenu()
            host.onSignOut(account)
        case .forget:
            accountOptionsStage = .confirmForget
            accountOptionsConfirmIndex = 0
        }
    }

    func selectAccountOptionsConfirm(_ index: Int, account: LoginAccount) {
        guard index == 1 else {
            accountOptionsStage = .options
            return
        }
        closeAccountOptions()
        closeActionMenu()
        host.onForget(account)
    }
}
