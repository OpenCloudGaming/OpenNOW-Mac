import AppKit
import Foundation
import Testing
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

    // The row is play and more, nothing else: every secondary action lives behind `more`, so a
    // gamepad reaches Play in one press rather than walking past Share to get there.
    #expect(actions == [.primary, .more])

    let more = model.detailMoreActions(for: single)
    #expect(more.first == .favorite)
    #expect(more.contains(.store) == false, "a single-variant game has no store to change")
    #expect(more.contains(.share))
    #expect(more.contains(.visitStore))
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

@Test func itMapsArrowKeysDespiteAppKitTaggingThemAsFunctionAndNumericPad() {
    // AppKit sets both flags on every arrow event; testing the whole device-independent mask
    // rejected all four and left keyboard navigation dead while Esc and Return still worked.
    let arrowFlags: NSEvent.ModifierFlags = [.function, .numericPad]

    #expect(ControllerKeyboardCommandMap.command(keyCode: 126, modifierFlags: arrowFlags) == .move(.up))
    #expect(ControllerKeyboardCommandMap.command(keyCode: 125, modifierFlags: arrowFlags) == .move(.down))
    #expect(ControllerKeyboardCommandMap.command(keyCode: 123, modifierFlags: arrowFlags) == .move(.left))
    #expect(ControllerKeyboardCommandMap.command(keyCode: 124, modifierFlags: arrowFlags) == .move(.right))
}

@Test func itIgnoresKeysHeldWithAChordModifier() {
    #expect(ControllerKeyboardCommandMap.command(keyCode: 123, modifierFlags: [.command]) == nil)
    #expect(ControllerKeyboardCommandMap.command(keyCode: 36, modifierFlags: [.option]) == nil)
}

@Test @MainActor func itOffersAScreenshotsPageOnlyWhenTheGameShipsMoreThanOneImage() {
    let model = ControllerCatalogViewModel()
    var info = OPNGameInfo()
    info.title = "One"
    let game = OPNCatalogGameObject(game: info)

    // A game with nothing to show must not get a tab that opens an empty panel.
    #expect(model.detailPages(for: game).contains(.screenshots) == false)
    #expect(model.detailPages(for: game) == [.about, .details])
}

@Test func itStopsPagingAtTheEndsRatherThanWrapping() {
    let pages: [ControllerGameDetailPage] = [.about, .screenshots, .details]

    #expect(ControllerGameDetailPage.about.stepped(by: -1, in: pages) == .about)
    #expect(ControllerGameDetailPage.about.stepped(by: 1, in: pages) == .screenshots)
    #expect(ControllerGameDetailPage.details.stepped(by: 1, in: pages) == .details)
    // A page missing from the available list falls back to the first rather than staying stranded.
    #expect(ControllerGameDetailPage.screenshots.stepped(by: 1, in: [.about, .details]) == .about)
}
