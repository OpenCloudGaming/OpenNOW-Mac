//  The completion time a patch record carries is the only freshness signal the vendor gives: a
//  record past its own ETA must stop asserting patching instead of blocking a playable title.

import Foundation
import Testing
@testable import OpenNOW

private func instant(_ iso: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: iso) ?? Date(timeIntervalSince1970: 0)
}

@Test func aCompletionTimeInThePastIsElapsed() {
    #expect(CatalogPatchRecord.isElapsed(endTime: "2026-10-21T17:43:11.000Z", now: instant("2026-10-21T18:00:00.000Z")))
}

@Test func aCompletionTimeStillAheadIsNotElapsed() {
    #expect(!CatalogPatchRecord.isElapsed(endTime: "2026-10-21T18:12:00.000Z", now: instant("2026-10-21T18:00:00.000Z")))
}

@Test func aMissingOrUnreadableCompletionTimeIsNoSignal() {
    #expect(!CatalogPatchRecord.isElapsed(endTime: ""))
    #expect(!CatalogPatchRecord.isElapsed(endTime: "not a timestamp"))
}

@Test func theCompletionTimeReadsAsALocalDateRatherThanTheVendorString() {
    let text = CatalogPatchRecord.completionText(endTime: "2026-10-21T17:43:11.000Z")

    #expect(!text.isEmpty)
    #expect(!text.contains("T17:43:11"))
    #expect(CatalogPatchRecord.completionText(endTime: "not a timestamp").isEmpty)
}
