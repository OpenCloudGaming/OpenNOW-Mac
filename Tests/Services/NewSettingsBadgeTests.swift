import Foundation
import Testing
@testable import OpenNOW

/// The NEW tag expires by version and by use, with no removal list to maintain.
@Suite struct NewSettingsBadgeTests {
    @Test func theTagShowsThroughItsOwnReleaseAndHidesAfter() {
        #expect(OPNNewSettings.isNew(introducedIn: "0.6.0", currentVersion: "0.0.0", acknowledged: false))
        #expect(OPNNewSettings.isNew(introducedIn: "0.6.0", currentVersion: "0.5.0", acknowledged: false))
        #expect(OPNNewSettings.isNew(introducedIn: "0.6.0", currentVersion: "0.6.0", acknowledged: false))
        #expect(OPNNewSettings.isNew(introducedIn: "0.6.0", currentVersion: "0.6", acknowledged: false))
        #expect(!OPNNewSettings.isNew(introducedIn: "0.6.0", currentVersion: "0.6.1", acknowledged: false))
        #expect(!OPNNewSettings.isNew(introducedIn: "0.6.0", currentVersion: "0.7.0", acknowledged: false))
        #expect(!OPNNewSettings.isNew(introducedIn: "0.6.0", currentVersion: "1.0.0", acknowledged: false))
    }

    @Test func usingTheSettingRetiresTheTag() {
        #expect(!OPNNewSettings.isNew(introducedIn: "0.6.0", currentVersion: "0.6.0", acknowledged: true))
    }

    @Test func versionsCompareNumericallyNotLexically() {
        #expect(OPNNewSettings.compareVersions("0.10.0", "0.9.0") == .orderedDescending)
        #expect(OPNNewSettings.compareVersions("1.0.0-beta.1", "1.0.0") == .orderedSame)
        #expect(OPNNewSettings.compareVersions("0.6", "0.6.0") == .orderedSame)
    }

    @Test func everyNewRowNamesARelease() {
        for row in OPNNewSettings.Row.allCases {
            #expect(OPNNewSettings.compareVersions(row.introducedIn, "0.0.0") == .orderedDescending, "\(row)")
        }
    }

    /// Registered provisionally at the release it is planned for: the anchor is the first stable
    /// release that actually contains Liquid Glass, and a beta is judged on its stable base version.
    @Test func liquidGlassIsRegisteredProvisionallyAtThePlannedRelease() {
        let introducedIn = OPNNewSettings.Row.liquidGlass.introducedIn
        #expect(introducedIn == "0.16.0")
        #expect(OPNNewSettings.isNew(introducedIn: introducedIn, currentVersion: "0.15.0", acknowledged: false))
        #expect(OPNNewSettings.isNew(introducedIn: introducedIn, currentVersion: "0.16.0-beta.1", acknowledged: false))
        #expect(OPNNewSettings.isNew(introducedIn: introducedIn, currentVersion: "0.16.0", acknowledged: false))
        // Expires on the next release, a patch included, without a removal list to maintain.
        #expect(!OPNNewSettings.isNew(introducedIn: introducedIn, currentVersion: "0.16.1", acknowledged: false))
        // Changing the setting retires the tag, and the acknowledgement survives a version bump.
        #expect(!OPNNewSettings.isNew(introducedIn: introducedIn, currentVersion: "0.16.0", acknowledged: true))
    }
}
