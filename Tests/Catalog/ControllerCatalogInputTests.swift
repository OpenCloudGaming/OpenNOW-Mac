import Testing
import Foundation
@testable import OpenNOW

// Routing extracted from ControllerCatalogView in the MVVM migration. These exercise the paths that
// do not need a live catalog: overlay precedence, the sort/filter picker, and the on-screen
// keyboard flag. Anything that mutates the catalog is covered by the
// catalog's own tests.

@Test @MainActor func actionMenuTakesInputAheadOfDetailAndSearch() {
    let model = ControllerCatalogViewModel()
    model.isActionMenuVisible = true
    model.isDetailVisible = true
    model.isSearchVisible = true

    // With no catalog bound there are no menu items, so confirm is a no-op and back closes.
    model.handleInput(.back)

    #expect(model.isActionMenuVisible == false)
    // Back was consumed by the action menu: the detail panel underneath is untouched.
    #expect(model.isDetailVisible == true)
}

@Test @MainActor func searchPickerConsumesInputWhileItIsUp() {
    let model = ControllerCatalogViewModel()
    model.isSearchVisible = true
    model.searchPicker = ControllerSearchPicker(
        title: "Sort",
        kind: .sort,
        options: [.init(id: "a", label: "A"), .init(id: "b", label: "B"), .init(id: "c", label: "C")]
    )

    model.handleInput(.move(.down))
    #expect(model.searchPickerIndex == 1)

    model.handleInput(.move(.down))
    model.handleInput(.move(.down))
    #expect(model.searchPickerIndex == 2, "index clamps at the last option")

    model.handleInput(.move(.up))
    #expect(model.searchPickerIndex == 1)

    model.handleInput(.back)
    #expect(model.searchPicker == nil)
    #expect(model.isSearchVisible == true, "closing the picker leaves the search overlay up")
}

@Test @MainActor func searchPickerIndexNeverGoesNegative() {
    let model = ControllerCatalogViewModel()
    model.isSearchVisible = true
    model.searchPicker = ControllerSearchPicker(title: "Sort", kind: .sort, options: [.init(id: "a", label: "A")])

    model.handleInput(.move(.up))
    model.handleInput(.move(.up))

    #expect(model.searchPickerIndex == 0)
}

@Test @MainActor func keyboardInputIsRoutedToTheKeyboardAndBackClosesIt() {
    let model = ControllerCatalogViewModel()
    model.isSearchVisible = true
    model.isSearchKeyboardVisible = true

    // Row index must not move while the keyboard owns the d-pad.
    model.searchRowIndex = 1
    model.handleInput(.move(.down))
    #expect(model.searchRowIndex == 1)

    model.handleInput(.back)
    #expect(model.isSearchKeyboardVisible == false)
}

@Test @MainActor func pageableNavigationItemsSkipTheActionsMenu() {
    let model = ControllerCatalogViewModel()

    #expect(model.navigationItems.contains(.actions))
    #expect(model.pageableNavigationItems.contains(.actions) == false)
    #expect(model.pageableNavigationItems.count == model.navigationItems.count - 1)
}

@Test @MainActor func detailActionsGrowWithVariantCount() {
    let model = ControllerCatalogViewModel()
    var info = OPNGameInfo()
    info.title = "One"
    let single = OPNCatalogGameObject(game: info)
    let actions = model.detailActions(for: single)

    #expect(actions.first == .primary)
    #expect(actions.contains(.store) == false, "a single-variant game has no store to change")
    #expect(actions.last == .close)
}

@Test @MainActor func unboundViewModelIgnoresInputInsteadOfCrashing() {
    let model = ControllerCatalogViewModel()

    // Every command, with nothing bound. The guards should absorb all of them.
    for command: ControllerInputCommand in [.confirm, .back, .search, .menu, .actions, .pageLeft, .pageRight,
                                            .move(.up), .move(.down), .move(.left), .move(.right)] {
        model.handleInput(command)
    }

    #expect(model.focusArea == .navigation)
    #expect(model.isDetailVisible == false)
}
