import Testing
@testable import OpenNOW

/// The saved output UID round-trips through the profile serialization, and an empty choice is the
/// absence of a preference rather than a device named "".
@Test func outputDevicePreferenceRoundTrips() {
    withExclusivePreferenceDomain {
        let key = "OpenNOW.Stream.OutputDeviceId"
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
        #expect(OPNStreamPreferences.loadProfile().outputDeviceId.isEmpty, "Default Device is the absence of a choice")

        OPNStreamPreferences.saveOutputDeviceId("BuiltInSpeakerDevice")
        #expect(OPNStreamPreferences.loadProfile().outputDeviceId == "BuiltInSpeakerDevice")

        // Through the profile serialization the iCloud sync and game profiles share.
        let profile = OPNStreamPreferences.loadProfile()
        let dictionary = OPNStreamPreferences.dictionary(from: profile, enabled: true)
        #expect(dictionary[key] as? String == "BuiltInSpeakerDevice")

        OPNStreamPreferences.saveOutputDeviceId("")
        #expect(OPNStreamPreferences.loadProfile().outputDeviceId.isEmpty)
        #expect(OPNAppPreferenceStorage.standard.object(forKey: key) == nil, "clearing the choice removes the key")
    }
}
