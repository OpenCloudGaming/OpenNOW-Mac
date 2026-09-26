import Testing
@testable import OpenNOW

@Test func displaySleepPreventionDefaultsOnAndPersists() {
    withExclusivePreferenceDomain {
        let key = "OpenNOW.Stream.PreventDisplaySleepWhileStreaming"
        let previous = OPNAppPreferenceStorage.standard.object(forKey: key)
        defer {
            if previous == nil {
                OPNAppPreferenceStorage.standard.removeObject(forKey: key)
            }
            if let previous {
                OPNAppPreferenceStorage.standard.set(previous, forKey: key)
            }
        }

        OPNAppPreferenceStorage.standard.removeObject(forKey: key)
        #expect(OPNStreamPreferences.loadProfile().preventDisplaySleepWhileStreaming)

        OPNStreamPreferences.savePreventDisplaySleepWhileStreaming(false)
        #expect(!OPNStreamPreferences.loadProfile().preventDisplaySleepWhileStreaming)

        OPNStreamPreferences.savePreventDisplaySleepWhileStreaming(true)
        #expect(OPNStreamPreferences.loadProfile().preventDisplaySleepWhileStreaming)
    }
}
