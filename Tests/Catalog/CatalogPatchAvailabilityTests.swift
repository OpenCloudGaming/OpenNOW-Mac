//  Availability classification from the patch-status poll payload: the same fetch that answers
//  "is this patching?" also answers "is this available, down for maintenance, or withdrawn?" — and
//  the patching semantics it already carried are unchanged.

import Foundation
import Testing
@testable import OpenNOW

private func patchStatuses(_ json: [[String: Any]]) -> [String: OPNAppPatchStatus] {
    let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    let raw = (try? JSONSerialization.jsonObject(with: data)) as? [NSDictionary] ?? []
    return OPNGameService.shared.parseAppPatchStatuses(raw)
}

private func app(id: String, status: String, subType: String? = nil, endTime: String? = nil) -> [String: Any] {
    var gfn: [String: Any] = ["status": status, "library": ["status": "AVAILABLE"]]
    var stateDetails: [String: Any] = [:]
    if let subType { stateDetails["subType"] = subType }
    if let endTime { stateDetails["endTime"] = endTime }
    if !stateDetails.isEmpty { gfn["stateDetails"] = stateDetails }
    return [
        "id": id,
        "variants": [["id": "\(id)-v", "gfn": gfn]],
    ]
}

@Test func maintenancePayloadClassifiesAsMaintenanceWithoutPatching() {
    let statuses = patchStatuses([app(id: "witcher", status: "SERVER_MAINTENANCE", subType: "GFN_DEVELOPER_MAINTENANCE")])
    let status = statuses["witcher"]
    #expect(status?.availability == .maintenance)
    #expect(status?.availabilityById["witcher-v"] == .maintenance)
    // Existing patching semantics are untouched: maintenance is not a patch.
    #expect(status?.isPatching == false)
    #expect(status?.variantPatchingById["witcher-v"] == false)
}

@Test func patchingPayloadKeepsPatchingAndReportsPatching() {
    let statuses = patchStatuses([app(id: "fortnite", status: "PATCHING", subType: "PATCHING_AUTO")])
    #expect(statuses["fortnite"]?.isPatching == true)
    #expect(statuses["fortnite"]?.availability == .patching)
}

@Test func aPatchRecordPastItsCompletionTimeReleasesTheTitle() {
    let statuses = patchStatuses([app(id: "mw4", status: "PATCHING", subType: "PATCHING_AUTO", endTime: "2020-01-01T00:00:00.000Z")])
    let status = statuses["mw4"]

    #expect(status?.isPatching == false)
    #expect(status?.variantPatchingById["mw4-v"] == false)
    #expect(status?.availability == .available)
}

@Test func aPatchEstimateReadsAsALocalCompletionTimeRatherThanTheVendorString() {
    let endTime = vendorTimestamp(secondsFromNow: 3_600)
    let statuses = patchStatuses([app(id: "fresh", status: "PATCHING", subType: "PATCHING_AUTO", endTime: endTime)])
    let text = statuses["fresh"]?.secondaryTextByVariantId["fresh-v"] ?? ""

    #expect(text.hasPrefix("Estimated completion: "))
    #expect(!text.contains(endTime))
}

@Test func availableAndUnavailableAreClassified() {
    let statuses = patchStatuses([
        app(id: "up", status: "AVAILABLE"),
        app(id: "gone", status: "UNAVAILABLE"),
    ])
    #expect(statuses["up"]?.availability == .available)
    #expect(statuses["gone"]?.availability == .unavailable)
}

@Test func anUnknownTokenFallsBackToAvailable() {
    let statuses = patchStatuses([app(id: "odd", status: "SOMETHING_WE_HAD_NOT_SEEN")])
    #expect(statuses["odd"]?.availability == .available)
}

@Test func aPayloadWithNoStatusSaysNothingRatherThanAvailable() {
    // No status and no state details is "no data", not a silent `available` that a maintenance watch
    // would read as the title coming back.
    let statuses = patchStatuses([["id": "silent", "variants": [["id": "silent-v", "gfn": ["library": ["status": "AVAILABLE"]]]]]])
    #expect(statuses["silent"]?.availability == nil)
    #expect(statuses["silent"]?.availabilityById.isEmpty == true)
}

@Test func aTitleRollsUpByTheSameRuleAsTheCatalogObject() {
    let mixed = patchStatuses([[
        "id": "mixed",
        "variants": [
            ["id": "a", "gfn": ["status": "SERVER_MAINTENANCE"]],
            ["id": "b", "gfn": ["status": "AVAILABLE"]],
        ],
    ]])
    #expect(mixed["mixed"]?.availability == .maintenance)
}

@Test func mergingKeepsAvailabilityFromBothFetches() {
    var target: [String: OPNAppPatchStatus] = [:]
    CatalogPatchStatusLogic.mergePatchStatuses(patchStatuses([app(id: "a", status: "SERVER_MAINTENANCE")]), into: &target)
    CatalogPatchStatusLogic.mergePatchStatuses(patchStatuses([app(id: "a", status: "AVAILABLE")]), into: &target)
    #expect(target["a"]?.availability == .available)
    #expect(target["a"]?.availabilityById["a-v"] == .available)
}

@Test func applyingAPollLayersOverTheCatalogSnapshotWithoutChangingIt() {
    var variant = OPNGameVariant(id: "v", appStore: "STEAM")
    variant.catalogStatus = "SERVER_MAINTENANCE"
    variant.catalogStateDetailsSubType = "GFN_DEVELOPER_MAINTENANCE"
    var info = OPNGameInfo()
    info.id = "g"
    info.variants = [variant]
    let game = OPNCatalogGameObject(game: info)
    #expect(game.catalogAvailability == .maintenance)

    var status = OPNAppPatchStatus(appId: "g")
    status.availabilityById = ["v": .available]
    status.availability = .available
    CatalogPatchStatusLogic.applyPatchingStatus(status, to: game)

    #expect(game.variants.first?.catalogAvailability == .available)
    #expect(game.catalogAvailability == .available)
    // The catalog snapshot's own fields are untouched: availability was layered, not rewritten.
    #expect(game.variants.first?.catalogStatus == "SERVER_MAINTENANCE")
}
