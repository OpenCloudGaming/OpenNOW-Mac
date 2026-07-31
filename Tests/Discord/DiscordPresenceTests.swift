import Foundation
import Testing
@testable import MacForceNow

@Test func discordArtworkPrefersBoxArtOverOtherTypes() {
    let byType = [
        "KEY_ART": ["https://cdn.example.com/key-art.jpg"],
        "GAME_BOX_ART": ["https://cdn.example.com/box.jpg"],
        "KEY_IMAGE": ["https://cdn.example.com/key-image.jpg"]
    ]
    let url = DiscordArtwork.imageURL(imageUrlsByType: byType, imageUrl: "https://cdn.example.com/flat.jpg", heroImageUrl: "")
    #expect(url == "https://cdn.example.com/box.jpg")
}

@Test func discordArtworkFollowsTypePriorityOrder() {
    let byType = [
        "KEY_ART": ["https://cdn.example.com/key-art.jpg"],
        "KEY_IMAGE": ["https://cdn.example.com/key-image.jpg"]
    ]
    let url = DiscordArtwork.imageURL(imageUrlsByType: byType, imageUrl: "", heroImageUrl: "")
    #expect(url == "https://cdn.example.com/key-image.jpg")
}

@Test func discordArtworkFallsBackToFlatThenHero() {
    let flat = DiscordArtwork.imageURL(imageUrlsByType: [:], imageUrl: "https://cdn.example.com/flat.jpg", heroImageUrl: "https://cdn.example.com/hero.jpg")
    #expect(flat == "https://cdn.example.com/flat.jpg")

    let hero = DiscordArtwork.imageURL(imageUrlsByType: [:], imageUrl: "", heroImageUrl: "https://cdn.example.com/hero.jpg")
    #expect(hero == "https://cdn.example.com/hero.jpg")
}

@Test func discordArtworkSkipsNonHTTPSCandidates() {
    let byType = ["GAME_BOX_ART": ["http://cdn.example.com/insecure.jpg"]]
    let url = DiscordArtwork.imageURL(imageUrlsByType: byType, imageUrl: "https://cdn.example.com/flat.jpg", heroImageUrl: "")
    #expect(url == "https://cdn.example.com/flat.jpg")
}

@Test func discordArtworkReturnsNilWhenNothingUsable() {
    let url = DiscordArtwork.imageURL(imageUrlsByType: ["GAME_BOX_ART": ["ftp://x/y"]], imageUrl: "not a url", heroImageUrl: "http://insecure")
    #expect(url == nil)
}

@Test func discordActivityBuildsNestedAssetsAndTimestamps() throws {
    let activity = DiscordActivity(
        details: "Cyberpunk 2077",
        state: "Streaming via MacForce Now",
        largeImageKey: "https://cdn.example.com/box.jpg",
        largeImageText: "Cyberpunk 2077",
        smallImageKey: "app_icon",
        smallImageText: "MacForce Now",
        startTimestampSeconds: 1_700_000_000
    )
    let json = activity.jsonObject()

    #expect(json["details"] as? String == "Cyberpunk 2077")
    #expect(json["state"] as? String == "Streaming via MacForce Now")
    #expect(json["instance"] as? Bool == false)

    let assets = try #require(json["assets"] as? [String: Any])
    #expect(assets["large_image"] as? String == "https://cdn.example.com/box.jpg")
    #expect(assets["large_text"] as? String == "Cyberpunk 2077")
    #expect(assets["small_image"] as? String == "app_icon")

    let timestamps = try #require(json["timestamps"] as? [String: Any])
    #expect(timestamps["start"] as? Int64 == 1_700_000_000)
}

@Test func discordActivityOmitsEmptyFields() {
    let activity = DiscordActivity(details: "Game", state: "", largeImageKey: nil)
    let json = activity.jsonObject()
    #expect(json["state"] == nil)
    #expect(json["assets"] == nil)
    #expect(json["timestamps"] == nil)
}

@MainActor
@Test func discordRichPresenceDefaultsToEnabled() throws {
    let suite = try #require(UserDefaults(suiteName: "discord.tests.\(UUID().uuidString)"))
    let presence = DiscordRichPresence(defaults: suite)
    #expect(presence.isEnabled == true)

    presence.isEnabled = false
    #expect(presence.isEnabled == false)
    #expect(suite.bool(forKey: DiscordRichPresenceConfig.enabledDefaultsKey) == false)
}
