import Testing
@testable import OpenNOW

@Test func displaySleepPreventionDefaultsOnAndPersists() {
    let key = "OpenNOW.Stream.PreventDisplaySleepWhileStreaming"
    let previous = OPNAppPreferenceStorage.standard.object(forKey: key)
    defer {
        if let previous {
            OPNAppPreferenceStorage.standard.set(previous, forKey: key)
        } else {
            OPNAppPreferenceStorage.standard.removeObject(forKey: key)
        }
    }

    OPNAppPreferenceStorage.standard.removeObject(forKey: key)
    #expect(OPNStreamPreferences.loadProfile().preventDisplaySleepWhileStreaming)

    OPNStreamPreferences.savePreventDisplaySleepWhileStreaming(false)
    #expect(!OPNStreamPreferences.loadProfile().preventDisplaySleepWhileStreaming)

    OPNStreamPreferences.savePreventDisplaySleepWhileStreaming(true)
    #expect(OPNStreamPreferences.loadProfile().preventDisplaySleepWhileStreaming)
}
