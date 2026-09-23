import Foundation
import Testing
@testable import OpenNOW

@Suite(.serialized) struct StreamStatsHUDSettingsTests {
    private func withPreservedDefaults(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let keys = [OPNStreamStatsHUDSettings.detailLevelKey, OPNStreamStatsHUDSettings.positionKey]
        let existing = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in existing {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        body()
    }

    @Test func unsetPreferencesKeepTheFullPanelInItsUsualCorner() {
        withPreservedDefaults {
            UserDefaults.standard.removeObject(forKey: OPNStreamStatsHUDSettings.detailLevelKey)
            UserDefaults.standard.removeObject(forKey: OPNStreamStatsHUDSettings.positionKey)
            #expect(OPNStreamStatsHUDSettings.detailLevel == .advanced)
            #expect(OPNStreamStatsHUDSettings.position == .topTrailing)
        }
    }

    @Test func everyDetailLevelRoundTrips() {
        withPreservedDefaults {
            for level in StreamStatsDetailLevel.allCases {
                OPNStreamStatsHUDSettings.detailLevel = level
                #expect(OPNStreamStatsHUDSettings.detailLevel == level)
            }
        }
    }

    @Test func everyPositionRoundTrips() {
        withPreservedDefaults {
            for position in StreamStatsHUDPosition.allCases {
                OPNStreamStatsHUDSettings.position = position
                #expect(OPNStreamStatsHUDSettings.position == position)
            }
        }
    }

    @Test func unknownStoredValuesFallBackToTheDefaults() {
        withPreservedDefaults {
            UserDefaults.standard.set("bogus", forKey: OPNStreamStatsHUDSettings.detailLevelKey)
            UserDefaults.standard.set("bogus", forKey: OPNStreamStatsHUDSettings.positionKey)
            #expect(OPNStreamStatsHUDSettings.detailLevel == .advanced)
            #expect(OPNStreamStatsHUDSettings.position == .topTrailing)
        }
    }

    @Test func pickerValuesRoundTripThroughTheirIndex() {
        for level in StreamStatsDetailLevel.allCases {
            #expect(StreamStatsDetailLevel.pickerCase(at: level.pickerValue) == level)
        }
        for position in StreamStatsHUDPosition.allCases {
            #expect(StreamStatsHUDPosition.pickerCase(at: position.pickerValue) == position)
        }
        #expect(StreamStatsDetailLevel.pickerCase(at: 99) == .advanced)
        #expect(StreamStatsHUDPosition.pickerCase(at: -1) == .topTrailing)
    }

    @Test func onlyLeadingCornersSitBesideTheSidebar() {
        #expect(StreamStatsHUDPosition.topLeading.isLeading)
        #expect(StreamStatsHUDPosition.bottomLeading.isLeading)
        #expect(!StreamStatsHUDPosition.topTrailing.isLeading)
        #expect(!StreamStatsHUDPosition.bottomTrailing.isLeading)
    }
}
