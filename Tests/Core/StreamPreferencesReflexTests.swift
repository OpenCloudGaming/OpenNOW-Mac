import Testing
@testable import OpenNOW

@Test func reflexDefaultsOnAndPersists() {
    let key = "OpenNOW.Stream.ReflexEnabled"
    let previous = OPNAppPreferenceStorage.standard.object(forKey: key)
    defer {
        if let previous {
            OPNAppPreferenceStorage.standard.set(previous, forKey: key)
        } else {
            OPNAppPreferenceStorage.standard.removeObject(forKey: key)
        }
    }

    OPNAppPreferenceStorage.standard.removeObject(forKey: key)
    #expect(OPNStreamPreferences.loadProfile().enableReflex)

    OPNStreamPreferences.saveReflexEnabled(false)
    #expect(!OPNStreamPreferences.loadProfile().enableReflex)

    OPNStreamPreferences.saveReflexEnabled(true)
    #expect(OPNStreamPreferences.loadProfile().enableReflex)
}
