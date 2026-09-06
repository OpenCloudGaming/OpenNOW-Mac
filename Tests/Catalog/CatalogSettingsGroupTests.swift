import Testing
import Foundation
@testable import OpenNOW

// The settings tab list, and which of its pages carry their own chrome.

@Test func everySettingsGroupIsVisible() {
    // Remote Co-Op used to be filtered out until its alpha was opted into. Nothing is conditional
    // now, and the tab bar and the pad's navigation read the same list.
    #expect(CatalogSettingsGroup.visibleCases() == CatalogSettingsGroup.allCases)
}

@Test func theTabsAreTheSevenConcernsAndNothingElse() {
    // One destination per concern. A tab that only ever showed an empty state trained people to
    // ignore it, and a tab per vendor subsystem split HDR, audio and input across three places.
    #expect(CatalogSettingsGroup.allCases == [.account, .video, .audio, .input, .network, .remoteCoOp, .general])
}

@Test func everySettingsGroupNamesItself() {
    for group in CatalogSettingsGroup.allCases {
        #expect(!group.title.isEmpty, "\(group.rawValue) has no title")
        #expect(!group.subtitle.isEmpty, "\(group.rawValue) has no subtitle")
        #expect(!group.icon.isEmpty, "\(group.rawValue) has no icon")
    }
}

/// The destination list's beta set is data, not a chain of `==` in the view body, so a group cannot
/// be tagged in one place and forgotten in another. A destination wears the tag only when every card
/// on it is beta; anything narrower is a card badge.
@MainActor @Test func onlyAWhollyBetaDestinationCarriesTheTag() {
    #expect(SettingsTabBar.betaGroups.contains(.remoteCoOp))
    #expect(!SettingsTabBar.betaGroups.contains(.network))
    #expect(!SettingsTabBar.betaGroups.contains(.account))
}

/// The section bar is only useful if its chips name cards that exist, and a page with one section
/// hides the bar entirely.
@MainActor @Test func everyMultiSectionDestinationNamesItsSections() {
    let sectioned: [(CatalogSettingsGroup, [SettingsSection])] = [
        (.account, AccountSettingsGroup.sections),
        (.video, VideoSettingsGroup.sections),
        (.audio, AudioSettingsPage.sections),
        (.input, InputSettingsGroup.sections),
        (.network, NetworkSettingsGroup.sections),
        (.general, GeneralSettingsGroup.sections),
    ]
    for (group, sections) in sectioned {
        #expect(sections.count > 1, "\(group.rawValue) has no section map")
        #expect(Set(sections.map(\.id)).count == sections.count, "\(group.rawValue) repeats a section id")
        for section in sections {
            #expect(!section.title.isEmpty, "\(group.rawValue) has an unnamed section")
        }
    }
}

/// The reader is in the last section whose top has gone past the viewport, not the nearest one.
@MainActor @Test func theActiveSectionIsTheLastOneScrolledPast() {
    let sections = [SettingsSection("a", "A"), SettingsSection("b", "B"), SettingsSection("c", "C")]
    let marks = [
        SettingsSectionMark(id: "a", minY: -420),
        SettingsSectionMark(id: "b", minY: -60),
        SettingsSectionMark(id: "c", minY: 380),
    ]
    #expect(SettingsContent.activeSection(marks: marks, sections: sections) == "b")

    // At rest nothing has been scrolled past, so the first section is the active one.
    let atRest = [
        SettingsSectionMark(id: "a", minY: 0),
        SettingsSectionMark(id: "b", minY: 300),
    ]
    #expect(SettingsContent.activeSection(marks: atRest, sections: sections) == "a")
}

/// Switching to Custom must not itself rewrite the values, or the edit that triggered the switch
/// would be overwritten by the preset it was escaping.
@MainActor @Test func theCustomProfileWritesNoPresetValues() {
    #expect(OPNStreamPreferences.streamingQualityPreset(for: CatalogViewModel.customStreamingProfileIndex) == nil)
    // Every named preset does write values, which is why an edit under one has to leave it first.
    for index in 1..<OPNStreamPreferences.streamingQualityProfileOptions.count {
        #expect(OPNStreamPreferences.streamingQualityPreset(for: index) != nil, "preset \(index) writes nothing")
    }
}

/// Two columns are a wide-window affordance, and never one a gamepad has to walk.
@Test func twoColumnsNeedRealWidthForTheReadersInterfaceScale() {
    #expect(SettingsLayoutMetrics.allowsTwoColumns(contentWidth: 1400, uiScale: 1.0))
    #expect(!SettingsLayoutMetrics.allowsTwoColumns(contentWidth: 900, uiScale: 1.0))
    // The same 1400pt window at a 1.5 interface scale is a 933pt page: one column.
    #expect(!SettingsLayoutMetrics.allowsTwoColumns(contentWidth: 1400, uiScale: 1.5))
    #expect(SettingsLayoutMetrics.allowsTwoColumns(contentWidth: 2400, uiScale: 1.5))
    #expect(!SettingsLayoutMetrics.allowsTwoColumns(contentWidth: 640, uiScale: 1.0))
    // A zero or negative scale must not divide its way into a two-column layout.
    #expect(!SettingsLayoutMetrics.allowsTwoColumns(contentWidth: 4000, uiScale: 0))
}

/// The threshold describes the width the cards get, not the width of the window around them.
@Test func theColumnThresholdExcludesThePagePadding() {
    let padding = SettingsLayoutMetrics.pageHorizontalPadding * 2
    let exact = SettingsLayoutMetrics.twoColumnMinimumWidth + padding
    #expect(SettingsLayoutMetrics.allowsTwoColumns(contentWidth: exact, uiScale: 1.0))
    #expect(!SettingsLayoutMetrics.allowsTwoColumns(contentWidth: exact - 1, uiScale: 1.0))
    // A page wide enough for two columns is never also narrow enough to stack its rows.
    #expect(SettingsLayoutMetrics.twoColumnMinimumWidth > SettingsLayoutMetrics.narrowRowWidth)
}

/// A long service sentence belongs in the access line, not in a chip beside the title.
@Test func capabilityChipsDropSentenceLengthPlayabilityText() {
    #expect(GameDetailPresentation.capabilityChipCharacterLimit < "Access unlocked with your membership. Game ownership required to play.".count)
}
