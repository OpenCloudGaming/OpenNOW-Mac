import Foundation
import Testing
@testable import OpenNOW

@Suite(.serialized) struct UpdatePreferencesChannelTests {
    private let key = OpenNOWUpdatePreferences.updateChannelKey

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
            #expect(OpenNOWUpdatePreferences.updateChannel == .stable)
        }
    }

    @Test func channelRoundTripsThroughStorage() {
        withPreservedChannel {
            OpenNOWUpdatePreferences.updateChannel = .beta
            #expect(OpenNOWUpdatePreferences.updateChannel == .beta)
            #expect(OPNAppPreferenceStorage.standard.string(forKey: key) == "beta")

            OpenNOWUpdatePreferences.updateChannel = .stable
            #expect(OpenNOWUpdatePreferences.updateChannel == .stable)
        }
    }

    @Test func invalidStoredValueFallsBackToStable() {
        withPreservedChannel {
            OPNAppPreferenceStorage.standard.set("nightly", forKey: key)
            #expect(OpenNOWUpdatePreferences.updateChannel == .stable)
        }
    }
}
