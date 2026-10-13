import Foundation
import Testing
@testable import OpenNOW

/// The main window's own pages, asked for from outside it. The app menu's Settings item and ⌘, both
/// arrive as `showMainPage(.settings)`, so what that request does to the page and its selected
/// group is the shortcut's observable behaviour.
@Suite @MainActor struct CatalogWindowPageRoutingTests {
    @Test func aSettingsRequestOpensTheSettingsPageOnAccount() {
        let model = makeCatalogViewModelForTesting()

        model.showMainPage(.settings)

        #expect(model.selectedMainPage == .settings)
        #expect(model.selectedSettingsGroup == .account)
    }

    @Test func aSettingsRequestLeavesTheOpenGroupAlone() {
        let model = makeCatalogViewModelForTesting()
        model.showSettings(.input)

        model.showMainPage(.settings)

        // Focused, not restarted: ⌘, with Settings already open must not send the reader back to the
        // first page of the sidebar.
        #expect(model.selectedMainPage == .settings)
        #expect(model.selectedSettingsGroup == .input)
    }

    @Test func theOtherWindowPagesStillRoute() {
        let model = makeCatalogViewModelForTesting()

        model.showMainPage(.recordings)
        #expect(model.selectedMainPage == .recordings)

        model.showMainPage(.home)
        #expect(model.selectedMainPage == .games)
    }
}
