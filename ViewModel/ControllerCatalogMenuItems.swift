//  The choices controller mode can offer: detail-panel actions, the actions menu, and the search
//  overlay's sort/filter picker. Moved out of the view so the controller view model can decide
//  which are available and what confirming one does, without a rendered catalog.
//
//  `title` and `icon` stay on these types: they are one string per case with no layout attached,
//  and splitting them into a parallel view-side table would only invite the two to drift.
//

import Foundation

/// The panels of the game page's body, stepped through with LB/RB.
enum ControllerGameDetailPage: CaseIterable {
    case about
    case screenshots
    case details

    var title: String {
        switch self {
        case .about: return "ABOUT THIS GAME"
        case .screenshots: return "SCREENSHOTS"
        case .details: return "DETAILS"
        }
    }

    /// Stops at the ends rather than wrapping: paging past the last panel back to the first reads
    /// as a jump rather than a step. Takes the available pages because Screenshots is only offered
    /// for games that ship any.
    func stepped(by offset: Int, in pages: [Self]) -> Self {
        guard let currentIndex = pages.firstIndex(of: self) else { return pages.first ?? self }
        let targetIndex = min(max(currentIndex + offset, 0), pages.count - 1)
        return pages[targetIndex]
    }
}

/// Which row of the game page the d-pad is driving. Left/right acts within the row, up/down moves
/// between them, so Play stays one press away while the screenshot strip is being browsed.
enum ControllerGameDetailFocusRow {
    case actions
    case content
}

/// The detail page offers three focus stops - play, favorite and more - and keeps every secondary
/// action behind `more`. A gamepad walks a flat list one step at a time, so putting seven equally
/// weighted buttons in that list made the one action anybody came for cost as many presses as
/// "Visit Store". `close` is gone with them: B already backs out of the page.
enum ControllerDetailAction: Equatable {
    case primary
    case favorite
    case more
    case store
    case ownership
    case share
    case shortcut
    case visitStore

    @MainActor func title(game: OPNCatalogGameObject, selectedVariant: OPNCatalogGameVariantObject?, viewModel: CatalogViewModel) -> String {
        switch self {
        case .primary:
            if game.isLaunchPatching || selectedVariant?.isPatching == true { return viewModel.isQueuedForPatching(game) ? "Queued" : "Queue" }
            if viewModel.selectedPlatformHasAccess(in: game) { return "Play" }
            if selectedVariant != nil { return "Mark Owned" }
            return "Play"
        case .favorite: return viewModel.isFavorite(game) ? "Unfavorite" : "Favorite"
        case .more: return "More"
        case .store: return "Change Store"
        case .ownership:
            if selectedVariant.map({ CatalogViewModel.variantIsOwned($0, in: game) }) == true { return "Unmark Owned" }
            return "Mark Owned"
        case .share: return "Share"
        case .shortcut: return "Add Shortcut"
        case .visitStore: return "Visit Store"
        }
    }

    var icon: String {
        switch self {
        case .primary: return "play.fill"
        case .favorite: return "heart.fill"
        case .more: return "ellipsis"
        case .store: return "bag.fill"
        case .ownership: return "checkmark.seal.fill"
        case .share: return "square.and.arrow.up"
        case .shortcut: return "plus.rectangle.on.rectangle"
        case .visitStore: return "safari.fill"
        }
    }
}
enum ControllerActionMenuItem {
    case refresh
    case clearSearch
    case desktopMode
    case home
    case library
    case favorites
    case recordings
    case settings
    case account(LoginAccount, isActive: Bool, needsSignIn: Bool)
    case addAccount

    var title: String {
        switch self {
        case .refresh: return "Refresh Catalog"
        case .clearSearch: return "Clear Search and Filters"
        case .desktopMode: return "Switch to Desktop Mode"
        case .home: return "Go to Home"
        case .library: return "Go to Library"
        case .favorites: return "Go to Favorites"
        case .recordings: return "Open Recordings"
        case .settings: return "Open Settings"
        case .account(let account, let isActive, let needsSignIn):
            if isActive { return account.displayName }
            return needsSignIn ? "Sign in as \(account.displayName)" : "Switch to \(account.displayName)"
        case .addAccount: return "Add Account"
        }
    }

    var isRefresh: Bool {
        switch self {
        case .refresh: return true
        default: return false
        }
    }

    var icon: String {
        switch self {
        case .refresh: return "arrow.clockwise"
        case .clearSearch: return "line.3.horizontal.decrease.circle"
        case .desktopMode: return "macwindow"
        case .home: return "gamecontroller.fill"
        case .library: return "rectangle.stack.fill"
        case .favorites: return "heart.fill"
        case .recordings: return "play.rectangle.fill"
        case .settings: return "gearshape.fill"
        case .account(_, let isActive, let needsSignIn):
            if isActive { return "checkmark" }
            return needsSignIn ? "person.crop.circle.badge.exclamationmark" : "person.crop.circle"
        case .addAccount: return "person.badge.plus"
        }
    }
}

/// The row list inside the per-account options overlay opened from an `.account` row in the
/// controller actions menu. The caller omits `signOut` for an account with no usable session.
enum ControllerAccountOptionRow: Equatable {
    case signOut
    case forget

    func title(accountDisplayName: String) -> String {
        switch self {
        case .signOut: return "Sign Out of \(accountDisplayName)"
        case .forget: return "Forget \(accountDisplayName)"
        }
    }

    var icon: String {
        switch self {
        case .signOut: return "rectangle.portrait.and.arrow.right"
        case .forget: return "xmark.circle"
        }
    }

    var isDestructive: Bool { self == .forget }
}
struct ControllerSearchPicker: Equatable {
    /// Stands for "no filter from this group". Filter groups are single-choice, so without it a
    /// group could only ever be switched between its options, never turned back off.
    static let clearOptionId = "__opn_filter_none__"

    struct Option: Equatable {
        let id: String
        let label: String
    }

    enum Kind: Equatable {
        case sort
        case filter(groupId: String)
    }

    let title: String
    let kind: Kind
    let options: [Option]
}
enum ControllerSearchBar {
    static let indexKey = "_barIndex"
    static let sortIndex = 0

    static func filterIndex(_ groupIndex: Int) -> Int { groupIndex + 1 }
    static func clearIndex(groupCount: Int) -> Int { groupCount + 1 }

    static func count(groupCount: Int, hasClear: Bool) -> Int {
        1 + groupCount + (hasClear ? 1 : 0)
    }
}
