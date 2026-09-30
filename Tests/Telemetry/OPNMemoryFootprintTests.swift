import Foundation
import Testing
@testable import OpenNOW

/// A read that never reached `phys_footprint` reports the zero the struct was initialised with, which
/// a baseline would record as a suspiciously small launch footprint.
@Test func reportsAPlausibleProcessFootprint() throws {
    let bytes = try #require(OPNMemoryFootprint.physicalFootprintBytes())

    #expect(bytes > 1024 * 1024)
    #expect(bytes < 1024 * 1024 * 1024 * 1024)
}

/// A reader that returned a constant would pass the check above.
@Test func footprintGrowsWhenMemoryIsTouched() throws {
    let before = try #require(OPNMemoryFootprint.physicalFootprintBytes())

    let touched = [UInt8](repeating: 0xAB, count: 64 * 1024 * 1024)
    let after = try #require(withExtendedLifetime(touched) { OPNMemoryFootprint.physicalFootprintBytes() })

    #expect(after > before)
}

/// The tokens are what a reader greps the diagnostics log for and what the baseline document records.
@Test func namesEveryMilestoneWithAStableToken() {
    #expect(OPNMemoryMilestone.allCases.map(\.rawValue) == [
        "pre-main",
        "first-frame",
        "catalog-visible",
        "stream-connected",
    ])
}
