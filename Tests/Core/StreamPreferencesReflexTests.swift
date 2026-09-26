import Testing
@testable import OpenNOW

@Test func reflexDefaultsOnAndPersists() {
    withExclusivePreferenceDomain {
        let key = "OpenNOW.Stream.ReflexEnabled"
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
        #expect(OPNStreamPreferences.loadProfile().enableReflex)

        OPNStreamPreferences.saveReflexEnabled(false)
        #expect(!OPNStreamPreferences.loadProfile().enableReflex)

        OPNStreamPreferences.saveReflexEnabled(true)
        #expect(OPNStreamPreferences.loadProfile().enableReflex)
    }
}
