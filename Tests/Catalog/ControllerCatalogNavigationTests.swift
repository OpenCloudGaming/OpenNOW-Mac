import Testing
import Foundation
@testable import OpenNOW

@Test @MainActor func navigationFocusMovesWithinBoundsAndDropsToSearch() {
    let model = ControllerCatalogViewModel()

    #expect(model.moveFocus(.left, navigationItemCount: 4) == .none)
    #expect(model.selectedNavigationIndex == 0)

    _ = model.moveFocus(.right, navigationItemCount: 4)
    _ = model.moveFocus(.right, navigationItemCount: 4)
    #expect(model.selectedNavigationIndex == 2)

    _ = model.moveFocus(.right, navigationItemCount: 4)
    _ = model.moveFocus(.right, navigationItemCount: 4)
    #expect(model.selectedNavigationIndex == 3)

    #expect(model.moveFocus(.up, navigationItemCount: 4) == .none)
    #expect(model.focusArea == .header)

    _ = model.moveFocus(.down, navigationItemCount: 4)
    #expect(model.focusArea == .navigation)

    _ = model.moveFocus(.down, navigationItemCount: 4)
    #expect(model.focusArea == .search)
}

@Test @MainActor func headerFocusOnlyLeavesDownwards() {
    let model = ControllerCatalogViewModel()
    model.focusArea = .header

    for direction: ControllerInputDirection in [.up, .left, .right] {
        #expect(model.moveFocus(direction, navigationItemCount: 4) == .none)
        #expect(model.focusArea == .header, "the header holds one control, so only down leaves it")
    }

    _ = model.moveFocus(.down, navigationItemCount: 4)
    #expect(model.focusArea == .navigation)
}

@Test @MainActor func navigationSelectionStaysAtZeroWhenThereAreNoItems() {
    let model = ControllerCatalogViewModel()

    _ = model.moveFocus(.right, navigationItemCount: 0)

    #expect(model.selectedNavigationIndex == 0)
}

@Test @MainActor func searchFocusMovesBetweenNavigationAndContentOnly() {
    let model = ControllerCatalogViewModel()
    model.focusArea = .search

    #expect(model.moveFocus(.left, navigationItemCount: 4) == .none)
    #expect(model.focusArea == .search)

    _ = model.moveFocus(.down, navigationItemCount: 4)
    #expect(model.focusArea == .content)

    model.focusArea = .search
    _ = model.moveFocus(.up, navigationItemCount: 4)
    #expect(model.focusArea == .navigation)
}

@Test @MainActor func contentFocusDelegatesGameAndRailMovementToTheView() {
    let model = ControllerCatalogViewModel()
    model.focusArea = .content

    #expect(model.moveFocus(.left, navigationItemCount: 4) == .moveGame(delta: -1))
    #expect(model.moveFocus(.right, navigationItemCount: 4) == .moveGame(delta: 1))
    #expect(model.moveFocus(.down, navigationItemCount: 4) == .moveRail(delta: 1))
    #expect(model.focusArea == .content)
}

@Test @MainActor func movingUpFromTheFirstRailReturnsFocusToSearchInsteadOfScrolling() {
    let model = ControllerCatalogViewModel()
    model.focusArea = .content
    model.selectedRailIndex = 0

    #expect(model.moveFocus(.up, navigationItemCount: 4) == .none)
    #expect(model.focusArea == .search)

    model.focusArea = .content
    model.selectedRailIndex = 2
    #expect(model.moveFocus(.up, navigationItemCount: 4) == .moveRail(delta: -1))
    #expect(model.focusArea == .content)
}

@Test @MainActor func railMovementClampsToTheSectionCount() {
    let model = ControllerCatalogViewModel()

    model.moveRail(delta: -1, sectionCount: 3)
    #expect(model.selectedRailIndex == 0)

    model.moveRail(delta: 1, sectionCount: 3)
    model.moveRail(delta: 1, sectionCount: 3)
    model.moveRail(delta: 1, sectionCount: 3)
    #expect(model.selectedRailIndex == 2)
}

@Test @MainActor func railMovementIsIgnoredWhenThereAreNoSections() {
    let model = ControllerCatalogViewModel()
    model.selectedRailIndex = 4

    model.moveRail(delta: 1, sectionCount: 0)

    #expect(model.selectedRailIndex == 4)
}

@Test @MainActor func overlayIndicesClampToTheirOwnItemCounts() {
    let model = ControllerCatalogViewModel()

    model.moveActionMenuIndex(delta: 5, itemCount: 3)
    #expect(model.actionMenuIndex == 2)
    model.moveActionMenuIndex(delta: -9, itemCount: 3)
    #expect(model.actionMenuIndex == 0)

    model.moveSearchRowIndex(delta: 4, rowCount: 2)
    #expect(model.searchRowIndex == 1)

    model.moveDetailActionIndex(delta: 3, actionCount: 0)
    #expect(model.detailActionIndex == 0)
}

@Test @MainActor func hasControllerOverlayReflectsAnyRaisedOverlay() {
    let model = ControllerCatalogViewModel()
    #expect(model.hasControllerOverlay == false)

    model.isSearchVisible = true
    #expect(model.hasControllerOverlay == true)

    model.isSearchVisible = false
    model.isDetailVisible = true
    #expect(model.hasControllerOverlay == true)

    model.isDetailVisible = false
    model.isActionMenuVisible = true
    #expect(model.hasControllerOverlay == true)
}

@Test @MainActor func perSectionGameSelectionIsClampedAndKeptSeparate() {
    let model = ControllerCatalogViewModel()
    let first = CatalogSectionModel(id: "a", title: "A", games: [], kind: .catalog)
    let second = CatalogSectionModel(id: "b", title: "B", games: [], kind: .catalog)

    model.setSelectedGameIndex(9, for: first, gameCount: 4)
    model.setSelectedGameIndex(1, for: second, gameCount: 4)

    #expect(model.selectedGameIndex(for: first, gameCount: 4) == 3)
    #expect(model.selectedGameIndex(for: second, gameCount: 4) == 1)
    #expect(model.selectedGameIndex(for: first, gameCount: 0) == 0)

    model.setSelectedGameIndex(-3, for: first, gameCount: 4)
    #expect(model.selectedGameIndex(for: first, gameCount: 4) == 0)
}

@Test @MainActor func clampRailSelectionNeverGoesNegativeForAnEmptyCatalog() {
    let model = ControllerCatalogViewModel()
    model.selectedRailIndex = 7

    model.clampRailSelection(sectionCount: 0)

    #expect(model.selectedRailIndex == 0)
}
