import Testing
import Foundation
@testable import OpenNOW

// The settings tab list, and which of its pages carry their own chrome.

@Test func everySettingsDestinationIsDrawn() {
    // Nothing is conditional. Labs is drawn with nothing on trial so it is somewhere people can
    // learn to look, and the rail and the pad read the same list - iterating `allCases` in one place
    // and a filtered list in the other is what let the pad land on a tab that was not drawn.
    #expect(CatalogSettingsGroup.visibleCases() == CatalogSettingsGroup.allCases)
}

/// Only a page that is nothing but an empty state may suppress the page header, because it names
/// itself and two titles would compete.
@MainActor @Test func onlyAnEmptyLabsSuppressesTheHeader() {
    let suppressing = CatalogSettingsGroup.allCases.filter(\.isEmptyStatePage)
    #expect(suppressing == (OpenNOWLabs.hasFlags ? [] : [.labs]))
}

/// A flag has to say what it turns on and when it went on trial, or nobody can judge whether to
/// risk it or whether it has been forgotten.
@MainActor @Test func everyLabsFlagIntroducesItself() {
    for flag in OpenNOWLabs.flags {
        #expect(!flag.id.isEmpty)
        #expect(!flag.title.isEmpty, "\(flag.id) has no title")
        #expect(!flag.summary.isEmpty, "\(flag.id) does not say what it does")
        #expect(!flag.since.isEmpty, "\(flag.id) does not say when it went on trial")
        #expect(flag.storageKey.hasPrefix("OpenNOW.Labs."), "\(flag.id) stores itself outside the Labs namespace")
    }
    #expect(Set(OpenNOWLabs.flags.map(\.id)).count == OpenNOWLabs.flags.count, "two flags share an id")
    // A retired flag reads as off rather than trapping.
    #expect(!OpenNOWLabs.isEnabled(id: "a-flag-that-was-removed"))
}

@Test func theTabsAreTheSevenConcernsAndNothingElse() {
    // One destination per concern. A tab that only ever showed an empty state trained people to
    // ignore it, and a tab per vendor subsystem split HDR, audio and input across three places.
    #expect(CatalogSettingsGroup.allCases == [.account, .video, .audio, .input, .recording, .network, .remoteCoOp, .general, .labs])
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

/// Nothing draws the sections any more, but a search result still scrolls to one and names it, so
/// every destination's map has to stay honest.
@MainActor @Test func everyDestinationNamesTheCardsASearchCanLandOn() {
    let sectioned: [(CatalogSettingsGroup, [SettingsSection])] = [
        (.account, AccountSettingsGroup.sections),
        (.video, VideoSettingsGroup.sections),
        (.audio, AudioSettingsPage.sections),
        (.input, InputSettingsGroup.sections),
        (.recording, RecordingSettingsGroup.sections),
        (.network, NetworkSettingsGroup.sections),
        (.general, GeneralSettingsGroup.sections),
        // Labs carries one section, so its bar is hidden; it is checked by the flag test instead.
    ]
    for (group, sections) in sectioned {
        #expect(sections.count > 1, "\(group.rawValue) has no section map")
        #expect(Set(sections.map(\.id)).count == sections.count, "\(group.rawValue) repeats a section id")
        for section in sections {
            #expect(!section.title.isEmpty, "\(group.rawValue) has an unnamed section")
        }
    }
}

/// Two columns are a wide-window affordance, and never one a gamepad has to walk.
@Test func twoColumnsNeedRealWidthForTheReadersInterfaceScale() {
    #expect(SettingsLayoutMetrics.allowsTwoColumns(cardWidth: 1400, uiScale: 1.0))
    #expect(!SettingsLayoutMetrics.allowsTwoColumns(cardWidth: 900, uiScale: 1.0))
    // The same 1400pt window at a 1.5 interface scale is a 933pt page: one column.
    #expect(!SettingsLayoutMetrics.allowsTwoColumns(cardWidth: 1400, uiScale: 1.5))
    #expect(SettingsLayoutMetrics.allowsTwoColumns(cardWidth: 2400, uiScale: 1.5))
    #expect(!SettingsLayoutMetrics.allowsTwoColumns(cardWidth: 640, uiScale: 1.0))
    // A zero or negative scale must not divide its way into a two-column layout.
    #expect(!SettingsLayoutMetrics.allowsTwoColumns(cardWidth: 4000, uiScale: 0))
}

/// The threshold describes the width a card gets, and a page wide enough to split is never also
/// narrow enough to stack its own rows.
@Test func theColumnThresholdDescribesCardWidth() {
    let exact = SettingsLayoutMetrics.twoColumnMinimumWidth
    #expect(SettingsLayoutMetrics.allowsTwoColumns(cardWidth: exact, uiScale: 1.0))
    #expect(!SettingsLayoutMetrics.allowsTwoColumns(cardWidth: exact - 1, uiScale: 1.0))
    #expect(!SettingsLayoutMetrics.usesNarrowRows(cardWidth: exact, uiScale: 1.0))
    #expect(SettingsLayoutMetrics.twoColumnMinimumWidth > SettingsLayoutMetrics.narrowRowWidth)
}

/// Nothing measured yet must not read as narrow, or the first frame of every page would stack every
/// row and then reflow once the width arrives.
@MainActor @Test func nothingMeasuredYetIsNotNarrow() {
    #expect(!SettingsLayoutMetrics.usesNarrowRows(cardWidth: 0, uiScale: 1.0))
    #expect(!SettingsLayoutMetrics.usesNarrowRows(cardWidth: 800, uiScale: 0))
    // A genuinely narrow container still stacks.
    #expect(SettingsLayoutMetrics.usesNarrowRows(cardWidth: 400, uiScale: 1.0))
}

/// A long service sentence belongs in the access line, not in a chip beside the title.
@Test func capabilityChipsDropSentenceLengthPlayabilityText() {
    #expect(GameDetailPresentation.capabilityChipCharacterLimit < "Access unlocked with your membership. Game ownership required to play.".count)
}
