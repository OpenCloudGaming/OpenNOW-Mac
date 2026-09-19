import Testing
import Foundation
@testable import OpenNOW

@Test func recordingPrependsTheNewestGameAndDropsDuplicates() {
    var recentlyPlayed = CatalogRecentlyPlayed.empty

    recentlyPlayed.record(title: "Cyberpunk 2077", appId: "1093630001", store: "steam", playedAt: Date(timeIntervalSince1970: 1_700_000_000))
    recentlyPlayed.record(title: "Manor Lords", appId: "1093630002", store: "epic", playedAt: Date(timeIntervalSince1970: 1_700_000_100))
    recentlyPlayed.record(title: "Cyberpunk 2077", appId: "1093630001", store: "steam", playedAt: Date(timeIntervalSince1970: 1_700_000_200))

    #expect(recentlyPlayed.games.map(\.title) == ["Cyberpunk 2077", "Manor Lords"])
    #expect(recentlyPlayed.games.first?.playedAt == Date(timeIntervalSince1970: 1_700_000_200))
}

@Test func artworkSurvivesAMergeFromASourceWithoutIt() {
    var recentlyPlayed = CatalogRecentlyPlayed.empty

    recentlyPlayed.record(title: "Manor Lords", appId: "app-1", store: "steam", playedAt: Date(timeIntervalSince1970: 100), artworkURL: "https://cdn.example/a.png")
    // A newer server row for the same game without art must not drop the art already known.
    recentlyPlayed.merge([CatalogRecentlyPlayedGame(title: "Manor Lords", appId: "app-1", store: "", playedAt: Date(timeIntervalSince1970: 200))])
    #expect(recentlyPlayed.games.first?.artworkURL == "https://cdn.example/a.png")

    // And a row that has art backfills one that does not.
    recentlyPlayed.merge([CatalogRecentlyPlayedGame(title: "Hades", appId: "app-2", store: "", playedAt: Date(timeIntervalSince1970: 50))])
    recentlyPlayed.merge([CatalogRecentlyPlayedGame(title: "Hades", appId: "app-2", store: "", playedAt: Date(timeIntervalSince1970: 40), artworkURL: "https://cdn.example/h.png")])
    #expect(recentlyPlayed.games.first { $0.appId == "app-2" }?.artworkURL == "https://cdn.example/h.png")
}

@Test func duplicatesMatchWithoutTheAppIdWhenTitlesCaseInsensitive() {
    var recentlyPlayed = CatalogRecentlyPlayed.empty

    recentlyPlayed.record(title: "Manor Lords", appId: "1093630001", store: "steam", playedAt: Date(timeIntervalSince1970: 1))
    recentlyPlayed.record(title: "  manor lords ", appId: "", store: "", playedAt: Date(timeIntervalSince1970: 2))

    #expect(recentlyPlayed.games.count == 1)
    #expect(recentlyPlayed.games.first?.appId == "")
}

@Test func entriesWithoutATitleOrAppIdAreIgnored() {
    var recentlyPlayed = CatalogRecentlyPlayed.empty

    recentlyPlayed.record(title: "   ", appId: "", store: "steam", playedAt: Date())

    #expect(recentlyPlayed == .empty)
}

@Test func theRailCapsAtTwelveGamesWithTheOldestFallingOff() {
    var recentlyPlayed = CatalogRecentlyPlayed.empty

    for index in 0..<20 {
        recentlyPlayed.record(title: "Game \(index)", appId: "id-\(index)", store: "steam", playedAt: Date(timeIntervalSince1970: Double(index)))
    }

    #expect(recentlyPlayed.games.count == CatalogRecentlyPlayed.maximumGameCount)
    #expect(recentlyPlayed.games.first?.title == "Game 19")
    #expect(recentlyPlayed.games.last?.title == "Game 8")
}

@Test func recentlyPlayedRoundTripsThroughStorageAndAreScopedPerAccount() {
    let account = "recently-played-test-\(UUID().uuidString)"
    let otherAccount = "recently-played-test-\(UUID().uuidString)"
    defer {
        OPNAppPreferenceStorage.standard.removeObject(forKey: "OpenNOW.Catalog.RecentlyPlayed.\(account)")
        OPNAppPreferenceStorage.standard.removeObject(forKey: "OpenNOW.Catalog.RecentlyPlayed.\(otherAccount)")
    }

    #expect(CatalogRecentlyPlayed.load(accountIdentifier: account) == .empty)

    var recentlyPlayed = CatalogRecentlyPlayed.empty
    recentlyPlayed.record(title: "Manor Lords", appId: "1093630002", store: "epic", playedAt: Date(timeIntervalSince1970: 1_700_000_000))
    recentlyPlayed.save(accountIdentifier: account)

    #expect(CatalogRecentlyPlayed.load(accountIdentifier: account) == recentlyPlayed)
    #expect(CatalogRecentlyPlayed.load(accountIdentifier: otherAccount) == .empty)
}

@Test func mergeKeepsTheNewestTimestampForTheSameGame() {
    var recentlyPlayed = CatalogRecentlyPlayed.empty
    recentlyPlayed.record(title: "Manor Lords", appId: "app-1", store: "steam", playedAt: Date(timeIntervalSince1970: 1_000))
    recentlyPlayed.record(title: "Manor Lords", appId: "app-1", store: "epic", playedAt: Date(timeIntervalSince1970: 500))

    #expect(recentlyPlayed.games.count == 1)
    #expect(recentlyPlayed.games.first?.playedAt == Date(timeIntervalSince1970: 1_000))
    #expect(recentlyPlayed.games.first?.store == "steam")

    recentlyPlayed.merge([CatalogRecentlyPlayedGame(title: "Manor Lords", appId: "app-1", store: "epic", playedAt: Date(timeIntervalSince1970: 2_000))])
    #expect(recentlyPlayed.games.first?.playedAt == Date(timeIntervalSince1970: 2_000))
    #expect(recentlyPlayed.games.first?.store == "epic")
}

@Test func mergeSortsServerHistoryNewestFirstBesideLocalSessions() {
    var recentlyPlayed = CatalogRecentlyPlayed.empty
    recentlyPlayed.record(title: "Played Just Now", appId: "app-1", store: "steam", playedAt: Date(timeIntervalSince1970: 9_000))

    recentlyPlayed.merge([
        CatalogRecentlyPlayedGame(title: "Played Yesterday", appId: "app-2", store: "", playedAt: Date(timeIntervalSince1970: 5_000)),
        CatalogRecentlyPlayedGame(title: "Played Last Week", appId: "app-3", store: "", playedAt: Date(timeIntervalSince1970: 1_000)),
    ])

    #expect(recentlyPlayed.games.map(\.title) == ["Played Just Now", "Played Yesterday", "Played Last Week"])
}

@Test func mergeDropsEntriesOlderThanTheCap() {
    var recentlyPlayed = CatalogRecentlyPlayed.empty
    let stale = (0..<CatalogRecentlyPlayed.maximumGameCount).map { index in
        CatalogRecentlyPlayedGame(title: "Game \(index)", appId: "id-\(index)", store: "", playedAt: Date(timeIntervalSince1970: Double(index)))
    }
    recentlyPlayed.merge(stale)
    recentlyPlayed.merge([CatalogRecentlyPlayedGame(title: "Newest", appId: "id-new", store: "", playedAt: Date(timeIntervalSince1970: 10_000))])

    #expect(recentlyPlayed.games.count == CatalogRecentlyPlayed.maximumGameCount)
    #expect(recentlyPlayed.games.first?.title == "Newest")
    #expect(recentlyPlayed.games.last?.title == "Game 1")
}

@Test func playedDateParsesEveryVendorTimestampShape() {
    let offset = CatalogRecentlyPlayed.playedDate(from: "2026-09-07T20:49:52.000+02:00")
    #expect(offset == ISO8601DateFormatter().date(from: "2026-09-07T18:49:52Z"))

    let bare = CatalogRecentlyPlayed.playedDate(from: "2026-09-07T18:49:52.000")
    #expect(bare == ISO8601DateFormatter().date(from: "2026-09-07T18:49:52Z"))

    let day = CatalogRecentlyPlayed.playedDate(from: "2026-01-01")
    #expect(day?.timeIntervalSince1970 == 1_767_225_600)

    #expect(CatalogRecentlyPlayed.playedDate(from: "") == nil)
    #expect(CatalogRecentlyPlayed.playedDate(from: "not a timestamp") == nil)
}
