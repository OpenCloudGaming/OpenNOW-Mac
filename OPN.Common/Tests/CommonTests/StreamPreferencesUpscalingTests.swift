import Foundation
import Testing
@testable import Common

@Suite(.serialized) struct StreamPreferencesUpscalingTests {
    private let preferenceDomain = "io.github.opencloudgaming.opennow"
    private let upscalingModeIndexKey = "OpenNOW.Stream.UpscalingModeIndex"
    private let upscalingSharpnessKey = "OpenNOW.Stream.UpscalingSharpness"

    @Test func exposesOnlyOffAndMetalFXUpscalingModes() {
        #expect(OPNStreamPreferences.upscalingModeOptions.map(\.label) == ["Off", "MetalFX"])
        #expect(OPNStreamPreferences.upscalingModeOptions.map(\.value) == [0, 3])
    }

    @Test func defaultsUpscalingOffWithClarityTen() {
        withPreservedPreferences([upscalingModeIndexKey, upscalingSharpnessKey]) {
            removePreferenceValue(upscalingModeIndexKey)
            removePreferenceValue(upscalingSharpnessKey)

            let profile = OPNStreamPreferences.loadProfile()

            #expect(profile.upscalingModeIndex == 0)
            #expect(profile.upscalingMode == 0)
            #expect(profile.upscalingModeOption.label == "Off")
            #expect(profile.upscalingSharpness == 10)
        }
    }

    @Test func mapsLegacyUpscalingIndicesToMetalFX() {
        withPreservedPreferences([upscalingModeIndexKey]) {
            for legacyIndex in 1...4 {
                OPNAppPreferenceStorage.standard.set(legacyIndex, forKey: upscalingModeIndexKey)

                let profile = OPNStreamPreferences.loadProfile()

                #expect(profile.upscalingModeIndex == 1)
                #expect(profile.upscalingMode == 3)
                #expect(profile.upscalingModeOption.label == "MetalFX")
            }
        }
    }

    @Test func mapsUnknownUpscalingIndicesToOff() {
        withPreservedPreferences([upscalingModeIndexKey]) {
            for invalidIndex in [-1, 5, 99] {
                OPNAppPreferenceStorage.standard.set(invalidIndex, forKey: upscalingModeIndexKey)

                let profile = OPNStreamPreferences.loadProfile()

                #expect(profile.upscalingModeIndex == 0)
                #expect(profile.upscalingMode == 0)
                #expect(profile.upscalingModeOption.label == "Off")
            }
        }
    }

    private func withPreservedPreferences(_ keys: [String], _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let previousValues = keys.map { ($0, defaults.object(forKey: $0)) }
        let previousDomain = defaults.persistentDomain(forName: preferenceDomain)
        defer {
            for (key, value) in previousValues {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
            if let previousDomain {
                defaults.setPersistentDomain(previousDomain, forName: preferenceDomain)
            } else {
                defaults.removePersistentDomain(forName: preferenceDomain)
            }
            defaults.synchronize()
        }
        body()
    }

    private func removePreferenceValue(_ key: String) {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: key)
        var domain = defaults.persistentDomain(forName: preferenceDomain) ?? [:]
        domain.removeValue(forKey: key)
        defaults.setPersistentDomain(domain, forName: preferenceDomain)
        defaults.synchronize()
    }
}
