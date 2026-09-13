import Testing
import Foundation
@testable import OpenNOW

private func makeGame(imageUrlsByType: [String: [String]] = [:]) -> OPNCatalogGameObject {
    var info = OPNGameInfo()
    info.imageUrlsByType = imageUrlsByType
    return OPNCatalogGameObject(game: info)
}

@Test func aPosterTileAsksForBoxArtBeforeAnythingElse() {
    let game = makeGame(imageUrlsByType: [
        "GAME_BOX_ART": ["https://example.com/box-art.jpg"],
        "TV_BANNER": ["https://example.com/tv-banner.jpg"],
        "HERO_IMAGE": ["https://example.com/hero.jpg"]
    ])

    #expect(game.bestPosterImageURL == "https://example.com/box-art.jpg")
    #expect(game.hasPosterArtwork)
}

@Test func aTitleWithNoBoxArtFallsBackToTheWideTileArtAndSaysSo() {
    let game = makeGame(imageUrlsByType: [
        "TV_BANNER": ["https://example.com/tv-banner.jpg"],
        "HERO_IMAGE": ["https://example.com/hero.jpg"]
    ])

    // No portrait asset shipped, so the tile centre-crops the landscape art instead.
    #expect(game.bestPosterImageURL == game.bestTileImageURL)
    #expect(game.hasPosterArtwork == false)
}

@Test func theStorePickerPosterStillPrefersBoxArtOverKeyArt() {
    let withBoth = makeGame(imageUrlsByType: [
        "BOX_ART": ["https://example.com/box-art.jpg"],
        "KEY_ART": ["https://example.com/key-art.jpg"]
    ])
    #expect(withBoth.bestStorePickerPosterURL == "https://example.com/box-art.jpg")

    let keyArtOnly = makeGame(imageUrlsByType: ["KEY_ART": ["https://example.com/key-art.jpg"]])
    #expect(keyArtOnly.bestStorePickerPosterURL == "https://example.com/key-art.jpg")
}

@Test func aTitleWithoutBoxArtStillGetsAPosterFromKeyArt() {
    let game = makeGame(imageUrlsByType: [
        "KEY_ART": ["https://example.com/key-art.jpg"],
        "HERO_IMAGE": ["https://example.com/hero.jpg"]
    ])

    #expect(game.bestPosterImageURL == "https://example.com/key-art.jpg")
    #expect(game.hasPosterArtwork)
}
