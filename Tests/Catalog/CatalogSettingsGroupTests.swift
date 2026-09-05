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

/// The 16:9 prompt is asked once per title: an answer, either way, has to stop the asking, and a
/// declined title must keep the resolution the user picked.
@Test @MainActor func sixteenNineChoiceIsRememberedPerTitle() {
    let appId = "test-16-9-\(UUID().uuidString)"
    defer { OPNStreamPreferences.forgetSixteenNineChoice(appId); OPNStreamPreferences.rememberTitleStreamsSixteenNineContent(appId, false) }
    #expect(OPNStreamPreferences.sixteenNineChoice(appId) == nil)
    OPNStreamPreferences.saveSixteenNineChoice(appId, streamsAtSixteenNine: false)
    #expect(OPNStreamPreferences.sixteenNineChoice(appId) == false)
    // Answered, so the launch must not ask again.
    OPNStreamPreferences.rememberTitleStreamsSixteenNineContent(appId, true)
    #expect(OPNStreamPreferences.sixteenNineDowngrade(forGame: appId) == nil)
    OPNStreamPreferences.saveSixteenNineChoice(appId, streamsAtSixteenNine: true)
    #expect(OPNStreamPreferences.sixteenNineChoice(appId) == true)
    OPNStreamPreferences.forgetSixteenNineChoice(appId)
    #expect(OPNStreamPreferences.sixteenNineChoice(appId) == nil)
}

@Test @MainActor func aTitleNeverSeenRenderingSixteenNineIsNeverAskedAbout() {
    #expect(OPNStreamPreferences.sixteenNineDowngrade(forGame: "test-16-9-unseen-\(UUID().uuidString)") == nil)
}

/// The settings list has to show a detected title with no answer yet, and forgetting one must drop
/// both the detection and the answer so the next session measures it again.
@Test @MainActor func knownSixteenNineTitlesListsDetectionsAndForgetsBoth() {
    let appId = "test-16-9-list-\(UUID().uuidString)"
    defer { OPNStreamPreferences.forgetSixteenNineTitle(appId) }
    OPNStreamPreferences.rememberTitleStreamsSixteenNineContent(appId, true)
    #expect(OPNStreamPreferences.knownSixteenNineTitles().contains { $0.appId == appId && $0.choice == nil })
    OPNStreamPreferences.saveSixteenNineChoice(appId, streamsAtSixteenNine: false)
    #expect(OPNStreamPreferences.knownSixteenNineTitles().contains { $0.appId == appId && $0.choice == false })
    OPNStreamPreferences.forgetSixteenNineTitle(appId)
    #expect(!OPNStreamPreferences.knownSixteenNineTitles().contains { $0.appId == appId })
    #expect(OPNStreamPreferences.sixteenNineChoice(appId) == nil)
}

/// A long service sentence belongs in the access line, not in a chip beside the title.
@Test func capabilityChipsDropSentenceLengthPlayabilityText() {
    #expect(GameDetailPresentation.capabilityChipCharacterLimit < "Access unlocked with your membership. Game ownership required to play.".count)
}
