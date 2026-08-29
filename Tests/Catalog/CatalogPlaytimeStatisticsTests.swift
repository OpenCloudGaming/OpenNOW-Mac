import Testing
import Foundation
@testable import OpenNOW

@Test func recordingASessionAccumulatesTotalsAndTrimsTheTitle() {
    var statistics = CatalogPlaytimeStatistics.empty
    let endedAt = Date(timeIntervalSince1970: 1_700_000_000)

    statistics.record(title: "  Cyberpunk 2077 ", durationSeconds: 600, endedAt: endedAt)

    #expect(statistics.totalSeconds == 600)
    #expect(statistics.sessionCount == 1)
    #expect(statistics.lastSessionSeconds == 600)
    #expect(statistics.longestSessionSeconds == 600)
    #expect(statistics.lastPlayedTitle == "Cyberpunk 2077")
    #expect(statistics.lastPlayedAt == endedAt)
}

@Test func longestSessionKeepsTheMaximumWhileLastSessionTracksTheNewest() {
    var statistics = CatalogPlaytimeStatistics.empty
    statistics.record(title: "A", durationSeconds: 900, endedAt: Date(timeIntervalSince1970: 1))
    statistics.record(title: "B", durationSeconds: 120, endedAt: Date(timeIntervalSince1970: 2))

    #expect(statistics.totalSeconds == 1020)
    #expect(statistics.sessionCount == 2)
    #expect(statistics.longestSessionSeconds == 900)
    #expect(statistics.lastSessionSeconds == 120)
    #expect(statistics.lastPlayedTitle == "B")
}

@Test func zeroNegativeAndNonFiniteDurationsAreIgnored() {
    var statistics = CatalogPlaytimeStatistics.empty
    statistics.record(title: "A", durationSeconds: 0, endedAt: Date())
    statistics.record(title: "B", durationSeconds: -30, endedAt: Date())
    statistics.record(title: "C", durationSeconds: .nan, endedAt: Date())
    statistics.record(title: "D", durationSeconds: .infinity, endedAt: Date())

    #expect(statistics == .empty)
}

@Test func averageSessionSecondsIsZeroBeforeAnySessionIsRecorded() {
    #expect(CatalogPlaytimeStatistics.empty.averageSessionSeconds == 0)

    var statistics = CatalogPlaytimeStatistics.empty
    statistics.record(title: "A", durationSeconds: 300, endedAt: Date())
    statistics.record(title: "B", durationSeconds: 100, endedAt: Date())

    #expect(statistics.averageSessionSeconds == 200)
}

@Test func statisticsRoundTripThroughStorageAndAreScopedPerAccount() {
    let account = "playtime-test-\(UUID().uuidString)"
    let otherAccount = "playtime-test-\(UUID().uuidString)"
    defer {
        OPNAppPreferenceStorage.standard.removeObject(forKey: "OpenNOW.Catalog.PlaytimeStatistics.\(account)")
        OPNAppPreferenceStorage.standard.removeObject(forKey: "OpenNOW.Catalog.PlaytimeStatistics.\(otherAccount)")
    }

    #expect(CatalogPlaytimeStatistics.load(accountIdentifier: account) == .empty)

    var statistics = CatalogPlaytimeStatistics.empty
    statistics.record(title: "Manor Lords", durationSeconds: 450, endedAt: Date(timeIntervalSince1970: 1_700_000_000))
    statistics.save(accountIdentifier: account)

    #expect(CatalogPlaytimeStatistics.load(accountIdentifier: account) == statistics)
    #expect(CatalogPlaytimeStatistics.load(accountIdentifier: otherAccount) == .empty)
}
