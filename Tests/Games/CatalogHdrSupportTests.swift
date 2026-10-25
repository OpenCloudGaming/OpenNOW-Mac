//  The catalog's per-edition HDR answer: what the vendor's own feature list says, what a missing
//  list leaves unknown, and what survives the cache and a same-store merge.

import Foundation
import Testing
@testable import OpenNOW

@Suite struct CatalogHdrSupportTests {
    private let service = OPNGameService()

    @Test func anEditionThatEnablesHdrDeclaresIt() {
        #expect(service.parseCatalogHdrSupport([["key": "HDR_ENABLED", "value": true]]) == .supported)
        #expect(service.parseCatalogHdrSupport([["key": "HDR_ENABLED", "value": "true"]]) == .supported)
        #expect(service.parseCatalogHdrSupport([["key": "HDR_ENABLED", "value": "false"], ["key": "RTX_ENABLED", "value": true]]) == .unsupported)
    }

    @Test func anEditionThatNamesAnHdrVersionDeclaresIt() {
        #expect(service.parseCatalogHdrSupport([["key": "SUPPORTED_HDR_VERSION", "value": "HDR10"]]) == .supported)
        #expect(service.parseCatalogHdrSupport([["key": "SUPPORTED_HDR_VERSION", "values": ["HDR10", "DOLBY_VISION"]]]) == .supported)
        #expect(service.parseCatalogHdrSupport([["key": "SUPPORTED_HDR_VERSION", "values": []]]) == .unsupported)
        #expect(service.parseCatalogHdrSupport([["key": "SUPPORTED_HDR_VERSION", "value": ""]]) == .unsupported)
    }

    @Test func aFeatureListWithoutHdrIsAnEditionWithoutIt() {
        #expect(service.parseCatalogHdrSupport([["key": "RAY_TRACING", "value": "SUPPORTED"]]) == .unsupported)
        #expect(service.parseCatalogHdrSupport([]) == .unsupported)
    }

    @Test func aMissingFeatureListLeavesHdrUnknown() {
        #expect(service.parseCatalogHdrSupport(nil) == .unknown)
        #expect(service.parseCatalogHdrSupport(NSNull()) == .unknown)
        #expect(service.parseCatalogHdrSupport("hdr") == .unknown)
    }

    @Test func theCachedCatalogKeepsTheHdrAnswer() {
        let cache = OPNGameDataCache.shared
        var listedWithoutHdr = OPNGameVariant()
        listedWithoutHdr.id = "123"
        listedWithoutHdr.catalogHdrSupport = .unsupported
        #expect(cache.gameVariant(cache.variantDictionary(listedWithoutHdr)).catalogHdrSupport == .unsupported)

        var neverListed = OPNGameVariant()
        neverListed.id = "456"
        #expect(cache.gameVariant(cache.variantDictionary(neverListed)).catalogHdrSupport == .unknown)
    }

    @Test func aSameStoreMergeFillsInAnUnknownAnswer() {
        var target = OPNGameVariant()
        target.id = "1"
        target.appStore = "STEAM"
        var source = OPNGameVariant()
        source.id = "1"
        source.appStore = "STEAM"
        source.catalogHdrSupport = .unsupported

        #expect(service.mergeVariantFromSameStore(target: &target, source: source))
        #expect(target.catalogHdrSupport == .unsupported)
    }
}
