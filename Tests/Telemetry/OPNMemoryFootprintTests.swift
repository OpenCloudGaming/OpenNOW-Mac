import Foundation
import Testing
@testable import OpenNOW

/// The milestone series is only worth something if the number behind it is real. `task_info` reports
/// how many fields it filled; a count that never reached `phys_footprint` leaves the zero the struct
/// was initialised with, which a baseline would read as a suspiciously small launch footprint.
@Test func footprintIsAPlausibleProcessSize() throws {
    let bytes = try #require(OPNMemoryFootprint.currentBytes())

    #expect(bytes > 1_048_576)
    #expect(bytes < 1_099_511_627_776)
}

/// And it has to move. A reader that returned a constant would still pass the check above.
@Test func footprintGrowsWithATouchedAllocation() throws {
    let before = try #require(OPNMemoryFootprint.currentBytes())

    var allocation = [UInt8](repeating: 0, count: 64 * 1_048_576)
    for index in stride(from: 0, to: allocation.count, by: 4096) {
        allocation[index] = 0xAB
    }

    let after = try #require(OPNMemoryFootprint.currentBytes())

    #expect(allocation[0] == 0xAB)
    #expect(after > before)
}

/// The tokens are what a reader greps the diagnostics log for and what the baseline document
/// records, so a rename here orphans both.
@Test func everyMilestoneHasAStableLogToken() {
    #expect(OPNMemoryMilestone.allCases.map(\.rawValue) == [
        "pre-main",
        "first-frame",
        "catalog-visible",
        "stream-connected",
    ])
}
