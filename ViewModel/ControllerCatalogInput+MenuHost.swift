//  The action-menu rows that leave the menu for something only the host owns: desktop mode and the
//  account rows. Kept beside the input routing but out of its file, which is at its length budget.
//

import Foundation

@MainActor
extension ControllerCatalogViewModel {

    func handleActionMenuHostItem(_ item: ControllerActionMenuItem) {
        switch item {
        case .desktopMode:
            host.onExitControllerMode()
        case .account(let account, let isActive, _):
            // The active row has nowhere to go - confirming it just closes the menu, same as
            // clicking the active row in the desktop dropdown.
            guard !isActive else { return }
            host.onSwitch(account)
        case .addAccount:
            host.onAddAccount()
        default:
            break
        }
    }
}
