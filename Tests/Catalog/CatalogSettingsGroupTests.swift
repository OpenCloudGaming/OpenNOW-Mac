import Testing
import Foundation
@testable import OpenNOW

// The settings tab list, and which of its pages carry their own chrome.

@Test func everySettingsGroupIsVisible() {
    // Remote Co-Op used to be filtered out until its alpha was opted into. Nothing is conditional
    // now, and the tab bar and the pad's navigation read the same list.
    #expect(CatalogSettingsGroup.visibleCases() == CatalogSettingsGroup.allCases)
}

@Test func onlyTheEmptyPageSuppressesTheHeader() {
    // An empty-state page names itself, so the standard header above it would be a second title.
    // Every other page has content that the header introduces.
    let suppressing = CatalogSettingsGroup.allCases.filter(\.isEmptyStatePage)

    #expect(suppressing == [.experimental])
}

@Test func everySettingsGroupNamesItself() {
    for group in CatalogSettingsGroup.allCases {
        #expect(!group.title.isEmpty, "\(group.rawValue) has no title")
        #expect(!group.subtitle.isEmpty, "\(group.rawValue) has no subtitle")
        #expect(!group.icon.isEmpty, "\(group.rawValue) has no icon")
    }
}

/// The tab bar's beta list is data, not a chain of `==` in the view body, so a group cannot be
/// tagged in one place and forgotten in another.
@Test func networkAndRemoteCoOpCarryTheBetaTag() {
    #expect(SettingsTabBar.betaGroups.contains(.network))
    #expect(SettingsTabBar.betaGroups.contains(.remoteCoOp))
    #expect(!SettingsTabBar.betaGroups.contains(.account))
}

/// A long service sentence belongs in the access line, not in a chip beside the title.
@Test func capabilityChipsDropSentenceLengthPlayabilityText() {
    #expect(GameDetailPresentation.capabilityChipCharacterLimit < "Access unlocked with your membership. Game ownership required to play.".count)
}
