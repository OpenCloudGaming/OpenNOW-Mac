//  The SDR note is shown once per game: the history is what keeps a title somebody plays daily
//  from repeating it at every launch, and it is bounded so it cannot grow without end.

import Foundation
import Testing
@testable import OpenNOW

@Suite struct OPNHdrDowngradeNoticeTests {
    private let shownKey = "OpenNOW.Stream.HdrNoticeShownGames"

    @Test func theNoteIsShownOncePerGame() {
        withPreservedPreferences([shownKey]) {
            removePreferenceValue(shownKey)

            #expect(OPNHdrDowngradeNotice.hasBeenShown(forGame: "doom-eternal") == false)
            OPNHdrDowngradeNotice.recordShown(forGame: "doom-eternal")

            #expect(OPNHdrDowngradeNotice.hasBeenShown(forGame: "doom-eternal"))
            #expect(OPNHdrDowngradeNotice.hasBeenShown(forGame: "quake") == false)
        }
    }

    @Test func aSessionWithNoGameIdentityNeverShowsTheNote() {
        withPreservedPreferences([shownKey]) {
            removePreferenceValue(shownKey)

            #expect(OPNHdrDowngradeNotice.hasBeenShown(forGame: ""))
            OPNHdrDowngradeNotice.recordShown(forGame: "")
            #expect(OPNStreamPreferences.loadHdrNoticeShownGames().isEmpty)
        }
    }

    @Test func theHistoryKeepsTheNewestTwoHundredDistinctGames() {
        let identities = (0..<205).map { "game-\($0)" } + ["game-7", "", String(repeating: "x", count: 257)]

        let kept = OPNHdrDowngradeNotice.normalized(identities)

        #expect(kept.count == OPNHdrDowngradeNotice.maximumRememberedGames)
        #expect(kept.first == "game-5")
        #expect(kept.last == "game-7")
        #expect(kept.filter { $0 == "game-7" }.count == 1)
        #expect(kept.contains("game-4") == false)
        #expect(kept.contains("") == false)
    }

    @Test func theHistorySurvivesAReload() {
        withPreservedPreferences([shownKey]) {
            removePreferenceValue(shownKey)

            OPNHdrDowngradeNotice.recordShown(forGame: "first")
            OPNHdrDowngradeNotice.recordShown(forGame: "second")

            #expect(OPNStreamPreferences.loadHdrNoticeShownGames() == ["first", "second"])
        }
    }
}
