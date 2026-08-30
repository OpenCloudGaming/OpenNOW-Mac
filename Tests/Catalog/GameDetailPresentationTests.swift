import Testing
import Foundation
@testable import OpenNOW

// Detail-panel copy, extracted from GameDetailPanel in the MVVM migration. It was `private` inside
// a View, so none of these branches could be reached without rendering a panel.

private func makeGame(
    title: String = "Test Game",
    shortDescription: String = "",
    longDescription: String = "",
    description: String = "",
    genres: [String] = [],
    nvidiaTech: [String] = [],
    featureLabels: [String] = [],
    skuTags: [String] = [],
    ratingCategoryTitle: String = "",
    ratingDescriptors: [String] = [],
    ratingInteractiveElements: [String] = [],
    contentRatings: [String] = [],
    supportedControls: [String] = [],
    maxLocalPlayers: Int = 0,
    maxOnlinePlayers: Int = 0,
    releaseDate: String = ""
) -> OPNCatalogGameObject {
    var info = OPNGameInfo()
    info.title = title
    info.shortDescription = shortDescription
    info.longDescription = longDescription
    info.description = description
    info.genres = genres
    info.nvidiaTech = nvidiaTech
    info.featureLabels = featureLabels
    info.skuTags = skuTags
    info.ratingCategoryTitle = ratingCategoryTitle
    info.ratingDescriptors = ratingDescriptors
    info.ratingInteractiveElements = ratingInteractiveElements
    info.contentRatings = contentRatings
    info.supportedControls = supportedControls
    info.maxLocalPlayers = maxLocalPlayers
    info.maxOnlinePlayers = maxOnlinePlayers
    info.releaseDate = releaseDate
    return OPNCatalogGameObject(game: info)
}

@Test @MainActor func appendUniqueTrimsAndDeduplicatesCaseInsensitively() {
    var values: [String] = []
    GameDetailPresentation.appendUnique("  Action  ", to: &values)
    GameDetailPresentation.appendUnique("action", to: &values)
    GameDetailPresentation.appendUnique("", to: &values)
    GameDetailPresentation.appendUnique("   ", to: &values)
    GameDetailPresentation.appendUnique("RPG", to: &values)

    #expect(values == ["Action", "RPG"])
}

@Test @MainActor func technologyLabelsRecogniseReflexAndRtxSpellings() {
    #expect(GameDetailPresentation.supportedTechnologyLabel("NVIDIA_REFLEX") == "Reflex")
    #expect(GameDetailPresentation.supportedTechnologyLabel("ray tracing") == "RTX")
    #expect(GameDetailPresentation.supportedTechnologyLabel("RayTracing") == "RTX")
    #expect(GameDetailPresentation.supportedTechnologyLabel("RTX ON") == "RTX")
    #expect(GameDetailPresentation.supportedTechnologyLabel("DLSS") == nil, "only Reflex and RTX are surfaced")
}

@Test @MainActor func technologyLabelsDeduplicateAcrossAllThreeSourceFields() {
    let game = makeGame(nvidiaTech: ["rtx"], featureLabels: ["Ray Tracing"], skuTags: ["nvidia_reflex", "rtx"])

    #expect(GameDetailPresentation.supportedTechnologyLabels(game: game) == ["RTX", "Reflex"])
}

@Test @MainActor func capabilityLabelsFallBackToCloudReady() {
    #expect(GameDetailPresentation.capabilityLabels(game: makeGame()) == ["Cloud Ready"])
}

@Test @MainActor func reflexIsTheOnlyLockedFeature() {
    #expect(GameDetailPresentation.featureIsLocked("Reflex"))
    #expect(GameDetailPresentation.featureIsLocked("RTX") == false)
    #expect(GameDetailPresentation.featureMessage("Reflex") == "Upgrade your membership to unlock")
    #expect(GameDetailPresentation.featureMessage("RTX").hasPrefix("Ready"))
}

@Test @MainActor func descriptionsFallBackInOrder() {
    let none = makeGame()
    #expect(GameDetailPresentation.shortDescription(game: none) == "Play instantly through GeForce NOW cloud streaming.")

    let short = makeGame(shortDescription: "  A short one  ")
    #expect(GameDetailPresentation.shortDescription(game: short) == "A short one")

    let long = makeGame(shortDescription: "Short", longDescription: "The long one")
    #expect(GameDetailPresentation.longDescription(game: long) == "The long one")

    // Falls through to the plain description, unless that just repeats the short one.
    let duplicated = makeGame(shortDescription: "Same text", description: "Same text")
    #expect(GameDetailPresentation.longDescription(game: duplicated) == "")
}

@Test @MainActor func esrbRatingsShortenToTheirBadgeLetters() {
    #expect(GameDetailPresentation.esrbShortRating("Everyone 10+") == "E10")
    #expect(GameDetailPresentation.esrbShortRating("Everyone") == "E")
    #expect(GameDetailPresentation.esrbShortRating("Teen") == "T")
    #expect(GameDetailPresentation.esrbShortRating("Mature 17+") == "M")
    #expect(GameDetailPresentation.esrbShortRating("Adults Only") == "A")
    #expect(GameDetailPresentation.esrbShortRating("PEGI 12") == "P", "anything unrecognised keeps its first letter")
    #expect(GameDetailPresentation.esrbShortRating("") == "")
}

@Test @MainActor func ratingDescriptorsStripBoardNamesAndCapAtThree() {
    let game = makeGame(ratingDescriptors: ["Violence", "ESRB", "Blood", "Language", "Drug Reference"])

    #expect(GameDetailPresentation.ratingDescriptors(game: game) == ["Violence", "Blood", "Language"])
}

@Test @MainActor func ratingDescriptorsFallBackToGenresWhenNothingSurvives() {
    let game = makeGame(genres: ["action", "adventure", "rpg"], ratingDescriptors: ["PEGI", "USK"])

    #expect(GameDetailPresentation.ratingDescriptors(game: game) == ["Action", "Adventure"])
}

@Test @MainActor func controlLabelsNormaliseVendorSpellings() {
    #expect(GameDetailPresentation.readableControlLabel("KEYBOARD_MOUSE") == "Keyboard & Mouse")
    #expect(GameDetailPresentation.readableControlLabel("GAMEPAD_PARTIAL") == "Partial Gamepad")
    #expect(GameDetailPresentation.readableControlLabel("gamepad") == "Gamepad")
    #expect(GameDetailPresentation.readableControlLabel("touchscreen") == "Touchscreen")
    #expect(GameDetailPresentation.readableControlLabel("racing_wheel") == "Wheel")
    #expect(GameDetailPresentation.readableControlLabel("HOTAS") == "Flight Controls")
    #expect(GameDetailPresentation.readableControlLabel("something else") == "Something Else")
}

@Test @MainActor func inputLinePrefersTheVariantsControlsAndDeduplicates() {
    let game = makeGame(supportedControls: ["GAMEPAD"])

    // No variant: falls back to the game's own list.
    #expect(GameDetailPresentation.inputLine(game: game, selectedVariant: nil) == "Gamepad")

    // Two spellings of the same thing collapse to one label.
    let both = makeGame(supportedControls: ["KEYBOARD_MOUSE", "mouse", "gamepad"])
    #expect(GameDetailPresentation.inputLine(game: both, selectedVariant: nil) == "Keyboard & Mouse, Gamepad")
}

@Test @MainActor func playerLineCoversEveryLocalAndOnlineCombination() {
    #expect(GameDetailPresentation.playerLine(game: makeGame()) == "")
    #expect(GameDetailPresentation.playerLine(game: makeGame(maxLocalPlayers: 1)) == "Single player")
    #expect(GameDetailPresentation.playerLine(game: makeGame(maxLocalPlayers: 4)) == "1-4 local players")
    #expect(GameDetailPresentation.playerLine(game: makeGame(maxOnlinePlayers: 16)) == "Single player, online multiplayer")
    #expect(GameDetailPresentation.playerLine(game: makeGame(maxLocalPlayers: 2, maxOnlinePlayers: 16)) == "1-2 local, online multiplayer")
}

@Test @MainActor func releaseDateLineFormatsIso8601AndPassesAnythingElseThrough() {
    #expect(GameDetailPresentation.releaseDateLine(game: makeGame(releaseDate: "   ")) == "")
    #expect(GameDetailPresentation.releaseDateLine(game: makeGame(releaseDate: "Coming soon")) == "Coming soon")

    let formatted = GameDetailPresentation.releaseDateLine(game: makeGame(releaseDate: "2024-04-26T00:00:00Z"))
    #expect(formatted.contains("2024"))
    #expect(formatted != "2024-04-26T00:00:00Z", "a parseable date is reformatted, not echoed")
}

@Test @MainActor func primaryActionTitleFollowsPatchingThenAccessThenOwnership() {
    let game = makeGame()

    var context = GameDetailAccessContext()
    #expect(GameDetailPresentation.primaryActionTitle(game: game, context: context) == "PLAY")

    context.hasSelectedVariant = true
    #expect(GameDetailPresentation.primaryActionTitle(game: game, context: context) == "MARK OWNED")

    context.selectedPlatformHasAccess = true
    #expect(GameDetailPresentation.primaryActionTitle(game: game, context: context) == "PLAY")

    context.isSelectedVariantPatching = true
    #expect(GameDetailPresentation.primaryActionTitle(game: game, context: context) == "QUEUE")

    context.isQueuedForPatching = true
    #expect(GameDetailPresentation.primaryActionTitle(game: game, context: context) == "QUEUED")
}

@Test @MainActor func accessBodyExplainsWhicheverThingIsBlockingPlay() {
    let game = makeGame()

    var context = GameDetailAccessContext()
    #expect(GameDetailPresentation.accessBody(game: game, context: context).hasPrefix("Access requires a GeForce NOW membership"))

    context.ownershipStoreName = "Steam"
    #expect(GameDetailPresentation.accessBody(game: game, context: context) == "Game ownership required on Steam to play.")

    context.subscriptionOptionTitle = "Ubisoft+"
    #expect(GameDetailPresentation.accessBody(game: game, context: context) == "Access unlocked through your Ubisoft+ subscription.",
            "a subscription outranks the ownership prompt")

    context.isSelectedVariantOwned = true
    #expect(GameDetailPresentation.accessBody(game: game, context: context).hasPrefix("Access unlocked with your membership"))

    context.isSelectedVariantPatching = true
    context.isQueuedForPatching = true
    #expect(GameDetailPresentation.accessBody(game: game, context: context).hasPrefix("Queued to launch automatically"),
            "patching outranks everything else")
}

@Test @MainActor func storePickerSuccessCopyDegradesWithoutAnAccount() {
    #expect(CatalogStorePresentation.successAccountTitle(storeName: "Steam", account: nil) == "Steam")
    #expect(CatalogStorePresentation.successAccountSubtitle(storeName: "Steam", account: nil) == "Your game store is selected.")
    #expect(CatalogStorePresentation.successSyncText(account: nil) == "Manual ownership selected")
}
