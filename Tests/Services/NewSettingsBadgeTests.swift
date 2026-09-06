import Foundation
import Testing
@testable import OpenNOW

/// The NEW tag expires by version and by use, with no removal list to maintain.
@Suite struct NewSettingsBadgeTests {
    @Test func theTagShowsThroughItsOwnReleaseAndHidesAfter() {
        #expect(OpenNOWNewSettings.isNew(introducedIn: "0.6.0", currentVersion: "0.0.0", acknowledged: false))
        #expect(OpenNOWNewSettings.isNew(introducedIn: "0.6.0", currentVersion: "0.5.0", acknowledged: false))
        #expect(OpenNOWNewSettings.isNew(introducedIn: "0.6.0", currentVersion: "0.6.0", acknowledged: false))
        #expect(OpenNOWNewSettings.isNew(introducedIn: "0.6.0", currentVersion: "0.6", acknowledged: false))
        #expect(!OpenNOWNewSettings.isNew(introducedIn: "0.6.0", currentVersion: "0.6.1", acknowledged: false))
        #expect(!OpenNOWNewSettings.isNew(introducedIn: "0.6.0", currentVersion: "0.7.0", acknowledged: false))
        #expect(!OpenNOWNewSettings.isNew(introducedIn: "0.6.0", currentVersion: "1.0.0", acknowledged: false))
    }

    @Test func usingTheSettingRetiresTheTag() {
        #expect(!OpenNOWNewSettings.isNew(introducedIn: "0.6.0", currentVersion: "0.6.0", acknowledged: true))
    }

    @Test func versionsCompareNumericallyNotLexically() {
        #expect(OpenNOWNewSettings.compareVersions("0.10.0", "0.9.0") == .orderedDescending)
        #expect(OpenNOWNewSettings.compareVersions("1.0.0-beta.1", "1.0.0") == .orderedSame)
        #expect(OpenNOWNewSettings.compareVersions("0.6", "0.6.0") == .orderedSame)
    }

    @Test func everyNewRowNamesARelease() {
        for row in OpenNOWNewSettings.Row.allCases {
            #expect(OpenNOWNewSettings.compareVersions(row.introducedIn, "0.0.0") == .orderedDescending, "\(row)")
        }
    }
}
