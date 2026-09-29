//  Catalog availability: the vendor's per-variant status (available / maintenance / patching) is
//  kept apart from library ownership, classified, and surfaced as the offline notice.
//

import Testing
import Foundation
@testable import OpenNOW

/// Round-trips a Swift dictionary through JSON so nested values arrive as `NSDictionary` / `NSArray`,
/// the shapes `parseGameItem` inspects.
private func parseFixture(_ dictionary: [String: Any]) -> OPNGameInfo {
    let data = (try? JSONSerialization.data(withJSONObject: dictionary)) ?? Data()
    let raw = (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary ?? NSDictionary()
    return OPNGameService.shared.parseGameItem(raw)
}

@Test func vendorAvailabilityVocabularyMapsToCatalogAvailability() {
    #expect(CatalogAvailability.classify(catalogStatus: "AVAILABLE", stateDetailsSubType: "") == .available)
    #expect(CatalogAvailability.classify(catalogStatus: "SERVER_MAINTENANCE", stateDetailsSubType: "GFN_DEVELOPER_MAINTENANCE") == .maintenance)
    #expect(CatalogAvailability.classify(catalogStatus: "MAINTENANCE", stateDetailsSubType: "") == .maintenance)
    #expect(CatalogAvailability.classify(catalogStatus: "", stateDetailsSubType: "GFN_DEVELOPER_MAINTENANCE") == .maintenance)
    #expect(CatalogAvailability.classify(catalogStatus: "PATCHING", stateDetailsSubType: "PATCHING_AUTO") == .patching)
    #expect(CatalogAvailability.classify(catalogStatus: "UNAVAILABLE", stateDetailsSubType: "") == .unavailable)
    #expect(CatalogAvailability.classify(catalogStatus: "", stateDetailsSubType: "") == .available)
}

@Test func parserStoresMaintenanceApartFromLibraryOwnership() {
    let game = parseFixture(catalogGraphQLGame(
        id: "witcher-remastered",
        libraryStatus: "MANUAL",
        librarySelected: true,
        gfnStatus: "SERVER_MAINTENANCE",
        gfnStateDetails: ["subType": "GFN_DEVELOPER_MAINTENANCE"]
    ))
    let variant = game.variants.first

    #expect(variant?.catalogStatus == "SERVER_MAINTENANCE")
    #expect(variant?.catalogStateDetailsSubType == "GFN_DEVELOPER_MAINTENANCE")
    #expect(variant?.catalogAvailability == .maintenance)
    // The ownership signal is untouched: the library status still lands in `serviceStatus`.
    #expect(variant?.serviceStatus == "MANUAL")
}

@Test func catalogObjectPreservesAvailabilityAcrossBridging() {
    var variant = OPNGameVariant(id: "v", appStore: "STEAM")
    variant.catalogStatus = "SERVER_MAINTENANCE"
    variant.catalogStateDetailsSubType = "GFN_DEVELOPER_MAINTENANCE"
    var game = OPNGameInfo()
    game.id = "g"
    game.variants = [variant]

    let object = OPNCatalogGameObject(game: game)
    #expect(object.variants.first?.catalogAvailability == .maintenance)
    #expect(object.catalogAvailability == .maintenance)
    #expect(object.swiftValue.variants.first?.catalogAvailability == .maintenance)
}

@Test func catalogCachePreservesAvailabilityAcrossReload() {
    var variant = OPNGameVariant(id: "v", appStore: "STEAM")
    variant.catalogStatus = "SERVER_MAINTENANCE"
    variant.catalogStateDetailsSubType = "GFN_DEVELOPER_MAINTENANCE"

    let restored = OPNGameDataCache.shared.gameVariant(OPNGameDataCache.shared.variantDictionary(variant))
    #expect(restored.catalogStatus == "SERVER_MAINTENANCE")
    #expect(restored.catalogStateDetailsSubType == "GFN_DEVELOPER_MAINTENANCE")
    #expect(restored.catalogAvailability == .maintenance)
}

@Test func offlineAvailabilityReplacesThePlayMessageWithNotice() {
    var context = GameDetailAccessContext()
    context.selectedPlatformHasAccess = true
    context.availability = .maintenance

    #expect(GameDetailPresentation.showsAvailabilityNotice(context.availability))
    #expect(GameDetailPresentation.availabilityNoticeTitle(.maintenance) == "Offline")
    #expect(GameDetailPresentation.availabilityNoticeBody(.maintenance).localizedCaseInsensitiveContains("maintenance"))
    #expect(GameDetailPresentation.primaryActionTitle(game: OPNCatalogGameObject(), context: context) == "PLAY")

    #expect(!GameDetailPresentation.showsAvailabilityNotice(.patching))
    #expect(!GameDetailPresentation.showsAvailabilityNotice(.available))
    #expect(GameDetailPresentation.availabilityNoticeTitle(.unavailable) == "Unavailable")
}

@Test func theWatchControlIsOfferedForMaintenanceOnly() {
    #expect(GameDetailPresentation.showsWatchControl(.maintenance))
    #expect(GameDetailPresentation.showsWatchControl(.available) == false)
    #expect(GameDetailPresentation.showsWatchControl(.patching) == false)
    #expect(GameDetailPresentation.showsWatchControl(.unavailable) == false,
            "withdrawal carries no promise of returning, so there is nothing to watch")
}

@Test func theNoticeCopySpeaksToTheWatchState() {
    let idle = GameDetailPresentation.availabilityNoticeBody(.maintenance, isWatching: false, isAtWatchLimit: false)
    let watching = GameDetailPresentation.availabilityNoticeBody(.maintenance, isWatching: true, isAtWatchLimit: false)
    let capped = GameDetailPresentation.availabilityNoticeBody(.maintenance, isWatching: false, isAtWatchLimit: true)

    #expect(idle.localizedCaseInsensitiveContains("maintenance"))
    #expect(watching.localizedCaseInsensitiveContains("watching"))
    #expect(watching.localizedCaseInsensitiveContains("playable"))
    #expect(capped.localizedCaseInsensitiveContains("maximum"))
    // The cap is stated, and where to relieve it.
    #expect(capped.localizedCaseInsensitiveContains("Settings"))
    // No copy implies a schedule; the vendor publishes no maintenance ETA.
    for message in [idle, watching, capped] {
        #expect(!message.localizedCaseInsensitiveContains("scheduled"))
    }
}

@Test func theWatchActionReadsItsState() {
    #expect(GameDetailPresentation.watchActionTitle(isWatching: false) == "WATCH")
    #expect(GameDetailPresentation.watchActionTitle(isWatching: true) == "WATCHING")
    #expect(GameDetailPresentation.watchActionAccessibilityLabel(isWatching: true).localizedCaseInsensitiveContains("stop"))
}

@Test func cardPrimaryActionLaunchesAnOwnedAvailableTitle() {
    var game = OPNGameInfo()
    game.id = "owned"
    game.isInLibrary = true

    let action = OPNCatalogGameObject(game: game).cardPrimaryAction(isQueuedForPatching: false)
    #expect(action == .launch)
    #expect(action.isEnabled)
    #expect(!action.isDimmed)
}

@Test func cardPrimaryActionMarksAnUnownedTitleAsOwned() {
    var game = OPNGameInfo()
    game.id = "not-owned"
    game.variants = [OPNGameVariant(id: "v", appStore: "STEAM")]

    let action = OPNCatalogGameObject(game: game).cardPrimaryAction(isQueuedForPatching: false)
    #expect(action == .markOwned)
    #expect(action.isEnabled)
}

@Test func cardPrimaryActionQueuesAPatchingTitle() {
    var game = OPNGameInfo()
    game.id = "patching"
    game.isPatching = true
    let object = OPNCatalogGameObject(game: game)

    #expect(object.cardPrimaryAction(isQueuedForPatching: false) == .queueForPatching(isQueued: false))
    #expect(object.cardPrimaryAction(isQueuedForPatching: false).isEnabled)
    #expect(object.cardPrimaryAction(isQueuedForPatching: true) == .queueForPatching(isQueued: true))
    #expect(!object.cardPrimaryAction(isQueuedForPatching: true).isEnabled)
}

@Test func takenDownOwnedTitleDisablesTheCardLaunchInsteadOfErroring() {
    var variant = OPNGameVariant(id: "v", appStore: "STEAM")
    variant.catalogStatus = "SERVER_MAINTENANCE"
    variant.catalogStateDetailsSubType = "GFN_DEVELOPER_MAINTENANCE"
    var game = OPNGameInfo()
    game.id = "owned-maintenance"
    game.isInLibrary = true
    game.variants = [variant]

    let action = OPNCatalogGameObject(game: game).cardPrimaryAction(isQueuedForPatching: false)
    #expect(action == .unavailable(.maintenance))
    #expect(action.title == "OFFLINE")
    #expect(!action.isEnabled)
    #expect(action.isDimmed)
}

@Test func unavailableOwnedTitleReportsUnavailableOnTheCard() {
    var variant = OPNGameVariant(id: "v", appStore: "STEAM")
    variant.catalogStatus = "UNAVAILABLE"
    var game = OPNGameInfo()
    game.id = "owned-unavailable"
    game.isInLibrary = true
    game.variants = [variant]

    let action = OPNCatalogGameObject(game: game).cardPrimaryAction(isQueuedForPatching: false)
    #expect(action == .unavailable(.unavailable))
    #expect(action.title == "UNAVAILABLE")
    #expect(!action.isEnabled)
}
