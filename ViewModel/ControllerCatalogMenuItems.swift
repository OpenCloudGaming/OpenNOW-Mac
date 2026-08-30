//
//  ControllerCatalogMenuItems.swift
//  OpenNOW
//
//  The choices controller mode can offer: detail-panel actions, the actions menu, and the search
//  overlay's sort/filter picker. Moved out of the view so the controller view model can decide
//  which are available and what confirming one does, without a rendered catalog.
//
//  `title` and `icon` stay on these types: they are one string per case with no layout attached,
//  and splitting them into a parallel view-side table would only invite the two to drift.
//

import Foundation

enum ControllerDetailAction: Equatable {
    case primary
    case favorite
    case store
    case ownership
    case share
    case shortcut
    case visitStore
    case close

    @MainActor func title(game: OPNCatalogGameObject, selectedVariant: OPNCatalogGameVariantObject?, viewModel: CatalogViewModel) -> String {
        switch self {
        case .primary:
            if game.isLaunchPatching || selectedVariant?.isPatching == true { return viewModel.isQueuedForPatching(game) ? "Queued" : "Queue" }
            if viewModel.selectedPlatformHasAccess(in: game) { return "Play" }
            if selectedVariant != nil { return "Mark Owned" }
            return "Play"
        case .favorite: return viewModel.isFavorite(game) ? "Unfavorite" : "Favorite"
        case .store: return "Change Store"
        case .ownership:
            if selectedVariant.map({ CatalogViewModel.variantIsOwned($0, in: game) }) == true { return "Unmark Owned" }
            return "Mark Owned"
        case .share: return "Share"
        case .shortcut: return "Add Shortcut"
        case .visitStore: return "Visit Store"
        case .close: return "Close"
        }
    }

    var icon: String {
        switch self {
        case .primary: return "play.fill"
        case .favorite: return "heart.fill"
        case .store: return "bag.fill"
        case .ownership: return "checkmark.seal.fill"
        case .share: return "square.and.arrow.up"
        case .shortcut: return "plus.rectangle.on.rectangle"
        case .visitStore: return "safari.fill"
        case .close: return "xmark"
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
    case switchAccount(LoginAccount, needsSignIn: Bool)
    case addAccount
    case signOut

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
        case .switchAccount(let account, let needsSignIn):
            return needsSignIn ? "Sign in as \(account.displayName)" : "Switch to \(account.displayName)"
        case .addAccount: return "Add Account"
        case .signOut: return "Sign Out"
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
        case .switchAccount: return "person.crop.circle"
        case .addAccount: return "person.badge.plus"
        case .signOut: return "rectangle.portrait.and.arrow.right"
        }
    }
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
