//  The launch loading screen's artwork: the only image on the stream-start path that used to be
//  decoded at full resolution. What these pin is that the frame the session warms is the frame the
//  screen shows, and that the URL is the vendor's own - the cache keys its entry by URL, so a
//  rewritten one misses the warmed entry and decodes the launch's largest frame twice.
//

import Foundation
import Testing
@testable import OpenNOW

struct StreamLaunchArtworkTests {
    /// The session warms from the game's own screenshot list at `begin`; the screen reads its frame
    /// off the metadata the resolved launch plan carries. Same id, same list, one URL.
    @Test func theFrameTheSessionWarmsIsTheFrameTheScreenShows() {
        let id = UUID()
        let candidates = [
            "https://img.nvidiagrid.net/a.jpg;f=webp;w=1200",
            "https://img.nvidiagrid.net/b.jpg;f=webp;w=720"
        ]
        let configuration = StreamLaunchConfiguration(
            id: id,
            title: "Game",
            applicationID: "100",
            accessToken: "t",
            accountLinked: true,
            selectedStore: "STEAM",
            metadata: ["loadingScreenshotUrls": candidates.joined(separator: "\n")]
        )

        let warmed = StreamLaunchArtwork.selectedURL(candidates: candidates, seed: id)
        #expect(warmed != nil)
        #expect(configuration.loadingArtworkURL == warmed)
    }

    /// The rung the catalog asked for is replaced rather than appended to, so the download matches the
    /// decode instead of fetching the 1200-wide rung, and the URL stays one the CDN serves.
    @Test func theVendorRungIsReplacedWithTheDecodeRung() {
        let parsed = "https://img.nvidiagrid.net/shot.jpg;f=webp;w=1200"
        let url = StreamLaunchArtwork.selectedURL(candidates: [parsed], seed: UUID())
        #expect(url?.absoluteString == "https://img.nvidiagrid.net/shot.jpg;f=webp;w=256")
    }

    @Test func aURLWithoutACDNRungIsUsedAsItStands() {
        let url = StreamLaunchArtwork.selectedURL(candidates: ["https://example.com/art.png"], seed: UUID())
        #expect(url?.absoluteString == "https://example.com/art.png")
    }

    @Test func paddingAroundAVendorURLIsIgnored() {
        let url = StreamLaunchArtwork.selectedURL(candidates: ["  https://img.nvidiagrid.net/a.jpg  "], seed: UUID())
        #expect(url?.absoluteString == "https://img.nvidiagrid.net/a.jpg")
    }

    /// A relative or non-HTTP candidate cannot be fetched, and picking one would leave the screen black
    /// while a fetchable candidate sat behind it.
    @Test func aCandidateTheCacheCannotFetchIsSkipped() {
        let candidates = [
            "/screenshots/shot.jpg",
            "ftp://img.nvidiagrid.net/shot.jpg",
            "https://img.nvidiagrid.net/shot.jpg;f=webp;w=1200"
        ]
        let url = StreamLaunchArtwork.selectedURL(candidates: candidates, seed: UUID())
        #expect(url?.absoluteString == "https://img.nvidiagrid.net/shot.jpg;f=webp;w=256")
    }

    @Test func theSameSeedPicksTheSameFrameEveryTime() {
        let seed = UUID()
        let candidates = [
            "https://img.nvidiagrid.net/a.jpg;f=webp;w=1200",
            "https://img.nvidiagrid.net/b.jpg;f=webp;w=720",
            "https://img.nvidiagrid.net/c.jpg;f=webp;w=1920"
        ]
        let first = StreamLaunchArtwork.selectedURL(candidates: candidates, seed: seed)
        #expect(first != nil)
        #expect(first == StreamLaunchArtwork.selectedURL(candidates: candidates, seed: seed))
    }

    @Test func noUsableCandidateMeansNoArtwork() {
        #expect(StreamLaunchArtwork.selectedURL(candidates: [], seed: UUID()) == nil)
        #expect(StreamLaunchArtwork.selectedURL(candidates: ["", "   ", "/relative.jpg"], seed: UUID()) == nil)
    }

    @Test func aLaunchWithNoScreenshotsHasNoArtwork() {
        let configuration = StreamLaunchConfiguration(
            title: "Game",
            applicationID: "100",
            accessToken: "t",
            accountLinked: true,
            selectedStore: "STEAM"
        )
        #expect(configuration.loadingArtworkURL == nil)
    }
}

/// The list the loading screen picks from is the one `launchMetadata` ships to the vendor, so it is
/// defined once: two definitions would warm a frame that never appears.
@Suite @MainActor struct LaunchLoadingScreenshotListTests {
    @Test func theListFollowsTheVendorsPreferenceOrder() {
        let game = makeGame(
            imageUrlsByType: ["SCREENSHOTS": ["https://img.nvidiagrid.net/shot.jpg;f=webp;w=1200"]],
            screenshotUrls: ["https://img.nvidiagrid.net/shot-2.jpg;f=webp;w=720"],
            heroImageUrl: "https://img.nvidiagrid.net/hero.jpg;f=webp;w=1920"
        )
        #expect(OPNGameLaunchBridge.loadingScreenshotURLs(for: game) == [
            "https://img.nvidiagrid.net/shot.jpg;f=webp;w=1200",
            "https://img.nvidiagrid.net/shot-2.jpg;f=webp;w=720",
            "https://img.nvidiagrid.net/hero.jpg;f=webp;w=1920"
        ])
    }

    @Test func aScreenshotOfferedTwiceAppearsOnce() {
        let game = makeGame(
            imageUrlsByType: ["SCREENSHOTS": ["https://img.nvidiagrid.net/shot.jpg;f=webp;w=1200"]],
            screenshotUrls: ["https://img.nvidiagrid.net/shot.jpg;f=webp;w=1200"]
        )
        #expect(OPNGameLaunchBridge.loadingScreenshotURLs(for: game) == ["https://img.nvidiagrid.net/shot.jpg;f=webp;w=1200"])
    }

    @Test func aGameWithNoArtworkOffersNoCandidates() {
        #expect(OPNGameLaunchBridge.loadingScreenshotURLs(for: makeGame()).isEmpty)
    }
}

/// The shape `OPNGameService+Parsing` stores: every URL already carries the CDN's rung, which is why
/// the launch artwork must not append one of its own.
private func makeGame(
    imageUrlsByType: [String: [String]] = [:],
    screenshotUrls: [String] = [],
    heroImageUrl: String = ""
) -> OPNCatalogGameObject {
    var info = OPNGameInfo()
    info.imageUrlsByType = imageUrlsByType
    info.screenshotUrls = screenshotUrls
    info.heroImageUrl = heroImageUrl
    return OPNCatalogGameObject(game: info)
}
