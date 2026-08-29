import Testing
import Foundation
@testable import OpenNOW

private func makeGame(uuid: String = "", id: String = "", launchAppId: String = "", variantIds: [String] = []) -> OPNCatalogGameObject {
    var info = OPNGameInfo()
    info.uuid = uuid
    info.id = id
    info.launchAppId = launchAppId
    info.variants = variantIds.map { variantId in
        var variant = OPNGameVariant()
        variant.id = variantId
        return variant
    }
    return OPNCatalogGameObject(game: info)
}

private func patchStatus(appId: String, isPatching: Bool, variantPatching: [String: Bool] = [:], primary: [String: String] = [:], secondary: [String: String] = [:]) -> OPNAppPatchStatus {
    var status = OPNAppPatchStatus()
    status.appId = appId
    status.isPatching = isPatching
    status.variantPatchingById = variantPatching
    status.primaryTextByVariantId = primary
    status.secondaryTextByVariantId = secondary
    return status
}

@Test func patchStatusAppIdPrefersUuidThenIdThenLaunchAppId() {
    #expect(CatalogPatchStatusLogic.patchStatusAppId(makeGame(uuid: "u", id: "i", launchAppId: "l")) == "u")
    #expect(CatalogPatchStatusLogic.patchStatusAppId(makeGame(id: "i", launchAppId: "l")) == "i")
    #expect(CatalogPatchStatusLogic.patchStatusAppId(makeGame(launchAppId: "l")) == "l")
    #expect(CatalogPatchStatusLogic.patchStatusAppId(makeGame()) == nil)
}

@Test func patchStatusLookupMatchesAnyIdentifier() {
    let game = makeGame(id: "game-id", launchAppId: "123")
    let statuses = ["123": patchStatus(appId: "123", isPatching: true)]

    #expect(CatalogPatchStatusLogic.patchStatus(for: game, statuses: statuses)?.appId == "123")
    #expect(CatalogPatchStatusLogic.patchStatus(for: makeGame(id: "other"), statuses: statuses) == nil)
}

@Test func isPatchingIsTrueWhenAnyVariantIsPatching() {
    let game = makeGame(id: "g", variantIds: ["v1", "v2"])
    #expect(CatalogPatchStatusLogic.isPatching(game) == false)

    game.variants[1].isPatching = true
    #expect(CatalogPatchStatusLogic.isPatching(game) == true)
}

@Test func applyingStatusPropagatesVariantTextOntoTheGame() {
    let game = makeGame(uuid: "u", variantIds: ["v1", "v2"])
    let status = patchStatus(
        appId: "u",
        isPatching: false,
        variantPatching: ["v1": true, "v2": false],
        primary: ["v1": "Patching 40%"],
        secondary: ["v1": "12 minutes left"]
    )

    CatalogPatchStatusLogic.applyPatchingStatus(status, to: game)

    #expect(game.variants[0].isPatching == true)
    #expect(game.variants[0].patchStatusPrimaryText == "Patching 40%")
    #expect(game.variants[0].patchStatusSecondaryText == "12 minutes left")
    #expect(game.variants[1].isPatching == false)
    #expect(game.isPatching == true)
    #expect(game.patchStatusPrimaryText == "Patching 40%")
    #expect(game.patchStatusSecondaryText == "12 minutes left")
}

@Test func applyingAClearedStatusWipesPatchText() {
    let game = makeGame(uuid: "u", variantIds: ["v1"])
    CatalogPatchStatusLogic.applyPatchingStatus(
        patchStatus(appId: "u", isPatching: true, variantPatching: ["v1": true], primary: ["v1": "Patching"]),
        to: game
    )
    #expect(game.isPatching == true)

    CatalogPatchStatusLogic.applyPatchingStatus(
        patchStatus(appId: "u", isPatching: false, variantPatching: ["v1": false]),
        to: game
    )

    #expect(game.variants[0].isPatching == false)
    #expect(game.variants[0].patchStatusPrimaryText == "")
    #expect(game.isPatching == false)
    #expect(game.patchStatusPrimaryText == "")
}

@Test func applyingStatusFallsBackToPatchingLabelWhenTextIsMissing() {
    let game = makeGame(uuid: "u", variantIds: ["v1"])

    CatalogPatchStatusLogic.applyPatchingStatus(patchStatus(appId: "u", isPatching: true), to: game)

    #expect(game.isPatching == true)
    #expect(game.patchStatusPrimaryText == "Patching")
}

@Test func mergeKeepsPatchingTrueAndPrefersIncomingText() {
    var target = [
        "123": patchStatus(appId: "123", isPatching: true, variantPatching: ["v1": true], primary: ["v1": "old"])
    ]
    let source = [
        "123": patchStatus(appId: "123", isPatching: false, variantPatching: ["v2": true], primary: ["v1": "new"]),
        "456": patchStatus(appId: "456", isPatching: true)
    ]

    CatalogPatchStatusLogic.mergePatchStatuses(source, into: &target)

    #expect(target["123"]?.isPatching == true)
    #expect(target["123"]?.variantPatchingById == ["v1": true, "v2": true])
    #expect(target["123"]?.primaryTextByVariantId["v1"] == "new")
    #expect(target["456"]?.isPatching == true)
}

@Test func updatingGamesSkipsUnmatchedEntries() {
    let matched = makeGame(uuid: "u", variantIds: ["v1"])
    let unmatched = makeGame(uuid: "other", variantIds: ["v1"])
    var games = [matched, unmatched]

    CatalogPatchStatusLogic.updatePatchingStatuses(
        in: &games,
        statuses: ["u": patchStatus(appId: "u", isPatching: true, variantPatching: ["v1": true], primary: ["v1": "Patching"])]
    )

    #expect(matched.isPatching == true)
    #expect(unmatched.isPatching == false)
}
