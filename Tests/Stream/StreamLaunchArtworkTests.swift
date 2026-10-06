//  The launch loading screen's artwork: the only image on the stream-start path that used to be
//  fetched and decoded at full resolution, and then blurred to near-invisibility. What these pin is
//  that the rung it is fetched at, the rung it is decoded at and the frame the session warms are all
//  the same one - the cache keys its entry by URL and its load by rung, so any disagreement is a
//  second fetch and a second decode of the launch's largest frame.
//

import Foundation
import Testing
@testable import OpenNOW

struct StreamLaunchArtworkTests {
    @Test func theRungTheCDNIsAskedForIsTheRungTheDecodeAsksFor() {
        #expect(StreamLaunchArtwork.decodePixelSize == CGFloat(StreamLaunchArtwork.requestWidth))
    }

    @Test func theCDNRungIsBakedIntoTheURLSoTheDownloadIsAThumbnailToo() {
        let url = StreamLaunchArtwork.url(from: "https://img.nvidiagrid.net/screenshot.jpg")
        #expect(url?.absoluteString == "https://img.nvidiagrid.net/screenshot.jpg;f=webp;w=\(StreamLaunchArtwork.requestWidth)")
    }

    @Test func aHostTheCDNDoesNotResizeIsFetchedAsItStands() {
        let url = StreamLaunchArtwork.url(from: "https://example.com/art.png")
        #expect(url?.absoluteString == "https://example.com/art.png")
    }

    @Test func noCandidatesMeansNoArtwork() {
        #expect(StreamLaunchArtwork.url(candidates: [], seed: UUID()) == nil)
        #expect(StreamLaunchArtwork.url(candidates: ["", "   "], seed: UUID()) == nil)
    }

    @Test func theSameSeedPicksTheSameFrameEveryTime() {
        let seed = UUID()
        let candidates = ["https://img.nvidiagrid.net/a.jpg", "https://img.nvidiagrid.net/b.jpg", "https://img.nvidiagrid.net/c.jpg"]
        let first = StreamLaunchArtwork.url(candidates: candidates, seed: seed)
        #expect(first != nil)
        #expect(first == StreamLaunchArtwork.url(candidates: candidates, seed: seed))
    }

    /// The session warms from the game's own screenshot list at `begin`; the screen reads its frame
    /// off the metadata the resolved launch plan carries. Same session id, same list, so the two have
    /// to land on the same URL or the warm decode is thrown away and the artwork is paid for twice.
    @Test func theFrameTheSessionWarmsIsTheFrameTheScreenShows() {
        let id = UUID()
        let candidates = ["https://img.nvidiagrid.net/a.jpg", "https://img.nvidiagrid.net/b.jpg"]
        let configuration = StreamLaunchConfiguration(
            id: id,
            title: "Game",
            applicationID: "100",
            accessToken: "t",
            accountLinked: true,
            selectedStore: "STEAM",
            metadata: ["loadingScreenshotUrls": candidates.joined(separator: "\n")]
        )

        let warmed = StreamLaunchArtwork.url(candidates: candidates, seed: id)
        #expect(warmed != nil)
        #expect(configuration.loadingArtworkURL == warmed)
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
/// defined once: two definitions would let the session warm a frame that never appears.
@Suite @MainActor struct LaunchLoadingScreenshotListTests {
    @Test func screenshotsComeFirstAndDuplicatesAreDropped() {
        var info = OPNGameInfo()
        info.imageUrlsByType = ["SCREENSHOTS": ["https://img.nvidiagrid.net/shot.jpg"]]
        info.screenshotUrls = ["https://img.nvidiagrid.net/shot.jpg", "https://img.nvidiagrid.net/shot-2.jpg"]
        info.heroImageUrl = "https://img.nvidiagrid.net/hero.jpg"

        #expect(OPNGameLaunchBridge.loadingScreenshotURLs(for: OPNCatalogGameObject(game: info)) == [
            "https://img.nvidiagrid.net/shot.jpg",
            "https://img.nvidiagrid.net/shot-2.jpg",
            "https://img.nvidiagrid.net/hero.jpg"
        ])
    }

    @Test func aGameWithNoArtworkOffersNoCandidates() {
        #expect(OPNGameLaunchBridge.loadingScreenshotURLs(for: OPNCatalogGameObject(game: OPNGameInfo())).isEmpty)
    }
}
