import Foundation
import Testing
@testable import OpenNOW

@Suite(.serialized) struct UpdatePreferencesChannelTests {
    private let key = OPNUpdatePreferences.updateChannelKey

    private func withPreservedChannel(_ body: () -> Void) {
        let defaults = OPNAppPreferenceStorage.standard
        let existing = defaults.string(forKey: key)
        defer {
            if let existing {
                defaults.set(existing, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        body()
    }

    @Test func unsetChannelDefaultsToStable() {
        withPreservedChannel {
            OPNAppPreferenceStorage.standard.removeObject(forKey: key)
            #expect(OPNUpdatePreferences.updateChannel == .stable)
        }
    }

    @Test func channelRoundTripsThroughStorage() {
        withPreservedChannel {
            OPNUpdatePreferences.updateChannel = .beta
            #expect(OPNUpdatePreferences.updateChannel == .beta)
            #expect(OPNAppPreferenceStorage.standard.string(forKey: key) == "beta")

            OPNUpdatePreferences.updateChannel = .stable
            #expect(OPNUpdatePreferences.updateChannel == .stable)
        }
    }

    @Test func invalidStoredValueFallsBackToStable() {
        withPreservedChannel {
            OPNAppPreferenceStorage.standard.set("nightly", forKey: key)
            #expect(OPNUpdatePreferences.updateChannel == .stable)
        }
    }

    @Test func lastUpdateCheckDateRoundTripsThroughStorage() {
        let defaults = OPNAppPreferenceStorage.standard
        let key = OPNUpdatePreferences.lastUpdateCheckDateKey
        let existing = defaults.object(forKey: key)
        defer {
            if let existing {
                defaults.set(existing, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.removeObject(forKey: key)
        #expect(OPNUpdatePreferences.lastUpdateCheckDate == nil)

        let date = Date(timeIntervalSince1970: 1_900_000_000)
        OPNUpdatePreferences.lastUpdateCheckDate = date
        #expect(OPNUpdatePreferences.lastUpdateCheckDate == date)
        #expect(defaults.double(forKey: key) == date.timeIntervalSince1970)

        OPNUpdatePreferences.lastUpdateCheckDate = nil
        #expect(OPNUpdatePreferences.lastUpdateCheckDate == nil)
        #expect(defaults.object(forKey: key) == nil)
    }
}
