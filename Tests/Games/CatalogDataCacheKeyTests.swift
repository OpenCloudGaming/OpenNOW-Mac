import Foundation
import Testing
@testable import OpenNOW

// Cache keys are hashes of a serialized dictionary. Swift dictionary iteration order is
// randomized per instance, so a key built without sorted serialization differs between
// two identical requests — which made every panel and catalog cache read miss.
@Test func catalogCacheKeyIsStableAcrossIdenticalRequests() {
    let cache = OPNGameDataCache.shared
    var keys = Set<String>()
    for _ in 0..<64 {
        keys.insert(cache.catalogKey(
            accountIdentifier: "account-1",
            searchQuery: "",
            sortId: "a_to_z",
            filterIds: ["my_library", "free_to_play"],
            fetchCount: 200,
            locale: "en_US",
            providerStreamingBaseUrl: "https://prod.example.test/",
            vpcId: "NP-AMS-07"
        ))
    }
    #expect(keys.count == 1)
}

@Test func catalogCacheKeyChangesWithInputs() {
    let cache = OPNGameDataCache.shared
    let base = cache.catalogKey(
        accountIdentifier: "account-1",
        searchQuery: "",
        sortId: "a_to_z",
        filterIds: [],
        fetchCount: 200,
        locale: "en_US",
        providerStreamingBaseUrl: "https://prod.example.test/",
        vpcId: "NP-AMS-07"
    )
    let otherVpc = cache.catalogKey(
        accountIdentifier: "account-1",
        searchQuery: "",
        sortId: "a_to_z",
        filterIds: [],
        fetchCount: 200,
        locale: "en_US",
        providerStreamingBaseUrl: "https://prod.example.test/",
        vpcId: "NP-AMS-08"
    )
    #expect(base != otherVpc)
}

@Test func panelCacheRoundTripsWithARepeatedKey() async {
    let cache = OPNGameDataCache.shared
    let accountIdentifier = "panel-key-test-\(UUID().uuidString)"
    var panel = OPNPanelResult()
    panel.id = "MAIN"
    panel.title = "Main"
    var section = OPNPanelSection()
    section.id = "section-1"
    section.title = "Featured"
    panel.sections = [section]

    cache.savePanelsAsync(
        kind: "main",
        accountIdentifier: accountIdentifier,
        vpcId: "NP-AMS-07",
        locale: "en_US",
        panels: [panel]
    )

    // A second identical request must resolve to the same file the save used.
    let loaded: [OPNPanelResult]? = await withCheckedContinuation { continuation in
        cache.loadPanelsAsync(
            kind: "main",
            accountIdentifier: accountIdentifier,
            vpcId: "NP-AMS-07",
            locale: "en_US",
            maxAgeSeconds: 60 * 60
        ) { panels in
            continuation.resume(returning: panels)
        }
    }

    #expect(loaded?.count == 1)
    #expect(loaded?.first?.sections.first?.title == "Featured")
}
